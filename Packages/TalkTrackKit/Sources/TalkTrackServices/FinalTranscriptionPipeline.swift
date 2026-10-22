import Dispatch
import Foundation
import TalkTrackDomain

private final class FinalPipelineExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "local.talktrack.final-transcription", qos: .userInitiated)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

/// Produces a complete durable staging result. Publishing and reconciling
/// confirmed names is a separate transaction; failures never mutate visible text.
public actor FinalTranscriptionPipeline {
    private nonisolated let executor = FinalPipelineExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let store: SessionStore
    private let library: OpenedLibrary
    private let inference: any FinalTranscriptionInference
    private var busy = false
    public static let requiredRoles: [ModelRole] = [.finalASR, .alignment, .segmentation, .embedding, .spelling]

    /// Missing roles that block this job; without spelling correction the
    /// text model is snapshotted but never loaded.
    public static func blocking(_ missing: [ModelRole], settings: ProcessingSettings) -> [ModelRole] {
        settings.spellingCorrection ? missing : missing.filter { $0 != .spelling }
    }

    private let checkpointInterval: Duration

    public init(store: SessionStore, library: OpenedLibrary, inference: any FinalTranscriptionInference) {
        self.init(store: store, library: library, inference: inference, checkpointInterval: Self.checkpointInterval)
    }

    init(store: SessionStore, library: OpenedLibrary, inference: any FinalTranscriptionInference, checkpointInterval: Duration) {
        self.store = store; self.library = library; self.inference = inference; self.checkpointInterval = checkpointInterval
    }

    /// Application processing entry point. Staging remains independently
    /// inspectable/retryable; publication consumes only its validated result.
    public func runAndPublish(jobID: UUID) async throws -> FinalTranscriptPublication {
        if try await store.job(jobID).stage == .completed {
            return try await store.publishFinalTranscript(jobID: jobID)
        }
        _ = try await run(jobID: jobID)
        try Task.checkCancellation()
        return try await store.publishFinalTranscript(jobID: jobID)
    }

    public func run(jobID: UUID) async throws -> FinalTranscriptionCheckpoint {
        guard !busy else { throw FinalTranscriptionError.busy }
        busy = true
        defer { busy = false }
        let lease = try await store.acquireFinalJob(jobID)
        do {
            let result = try await process(jobID: jobID)
            await store.releaseFinalJob(jobID, lease: lease)
            return result
        }
        catch {
            var error = error
            let stage: JobStage
            if case FinalTranscriptionError.missingModels = error { stage = .waitingForModels }
            else if error is CancellationError { stage = .interrupted }
            else if let missing = await removedModels(jobID: jobID) {
                // A model removed in Settings while the job used it waits for
                // a download instead of failing on the load error.
                error = FinalTranscriptionError.missingModels(missing); stage = .waitingForModels
            }
            else { stage = .failed }
            // A deleted/cancelled/source-stale job is already authoritative.
            // Never revive it while reporting a downstream error.
            try? await store.updateJob(jobID, stage: stage, error: error.localizedDescription)
            await store.releaseFinalJob(jobID, lease: lease)
            throw error
        }
    }

    private func removedModels(jobID: UUID) async -> [ModelRole]? {
        guard let job = try? await store.job(jobID),
              let missing = try? await inference.unavailableFinalModels(job.snapshot.models) else { return nil }
        let blocking = Self.blocking(missing, settings: job.snapshot.settings)
        return blocking.isEmpty ? nil : blocking
    }

    /// The English or Russian language of the first speech of at least three
    /// words after `after` windows of `track`, then on the other track (a short
    /// "Uh huh" is no more reliable than the opening); a shorter detection only
    /// when nothing longer is found. At most `limit` windows are recognized.
    /// Deterministic, so a resumed job decides alike.
    private func laterLanguage(recording: Recording, track: AudioTrack, after: Int, model: ModelSnapshot,
                               limit: Int = 8) async throws -> MeetingLanguage? {
        var probed = 0
        var weak: MeetingLanguage?
        for (candidate, skip) in [(track, after), (track == .system ? AudioTrack.microphone : .system, 0)] {
            let reader = try await RecordingAudioWindowReader.open(library: library, recording: recording, track: candidate)
            defer { Task { await reader.close() } }
            var position = 0
            while probed < limit, let event = try await reader.next() {
                try Task.checkCancellation()
                position += 1
                guard position > skip, case .audio(let window) = event else { continue }
                probed += 1
                let detected = try await inference.finalText(model, samples: window.samples, language: .auto)
                guard !detected.text.isEmpty, [.english, .russian].contains(detected.language) else { continue }
                if detected.text.split(whereSeparator: \.isWhitespace).count >= 3 { return detected.language }
                weak = weak ?? detected.language
            }
        }
        return weak
    }

    private func process(jobID: UUID) async throws -> FinalTranscriptionCheckpoint {
        try Task.checkCancellation()
        let job = try await store.job(jobID)
        guard job.snapshot.kind == .finalTranscription, let id = job.snapshot.recordingID,
              [.queued, .decoding, .transcribing, .aligning, .diarizing, .correcting, .validating].contains(job.stage),
              job.snapshot.models.count == Self.requiredRoles.count,
              Set(job.snapshot.models.map(\.role)) == Set(Self.requiredRoles),
              let recording = try await store.recordings(meetingID: job.snapshot.source.meetingID).first(where: { $0.id == id }),
              [RecordingState.complete, .interrupted].contains(recording.state),
              job.snapshot.source.recordingGenerations[id] == recording.generation else {
            throw FinalTranscriptionError.invalidJob
        }
        let models = Dictionary(uniqueKeysWithValues: job.snapshot.models.map { ($0.role, $0) })
        let fingerprint = try SessionStore.fingerprint(recording)
        var checkpoint = try await store.finalCheckpoint(jobID: jobID) ?? FinalTranscriptionCheckpoint(
            version: 1, correctionPromptVersion: IndexedSpellingCorrection.promptVersion,
            job: job.snapshot, recordingFingerprint: fingerprint, windows: [],
            completedTracks: [], speakerCheckpoint: nil, correctionBatches: [], readyForPublication: false)
        if checkpoint.correctionPromptVersion != IndexedSpellingCorrection.promptVersion {
            // A job checkpointed by an earlier correction prompt keeps its
            // recognition, alignment and speakers and redoes correction only.
            var windows = checkpoint.windows
            for i in windows.indices { for j in (windows[i].blocks ?? []).indices { windows[i].blocks![j].correctedText = nil } }
            checkpoint = FinalTranscriptionCheckpoint(version: checkpoint.version,
                correctionPromptVersion: IndexedSpellingCorrection.promptVersion, job: checkpoint.job,
                recordingFingerprint: checkpoint.recordingFingerprint, windows: windows,
                completedTracks: checkpoint.completedTracks, speakerCheckpoint: checkpoint.speakerCheckpoint,
                correctionBatches: [], readyForPublication: false)
        }
        guard checkpoint.version == 1, checkpoint.job == job.snapshot,
              checkpoint.correctionPromptVersion == IndexedSpellingCorrection.promptVersion,
              checkpoint.recordingFingerprint == fingerprint,
              Set(checkpoint.windows.map(\.id)).count == checkpoint.windows.count,
              Set(checkpoint.completedTracks).count == checkpoint.completedTracks.count else {
            throw FinalTranscriptionError.invalidCheckpoint
        }
        checkpoint.readyForPublication = false
        // Recheck deletion/generation/cancellation even for a ready artifact.
        try await store.saveFinalCheckpoint(checkpoint, stage: .decoding)
        let missing = Self.blocking(try await inference.unavailableFinalModels(job.snapshot.models), settings: job.snapshot.settings)
        guard missing.isEmpty else { throw FinalTranscriptionError.missingModels(missing) }
        let diarization = try SystemDiarizationSession(meetingID: recording.meetingID,
            segmentation: models[.segmentation]!, embedding: models[.embedding]!,
            inference: inference, checkpoint: checkpoint.speakerCheckpoint)
        // One native ten-second PCM window exists at a time. A resumed job
        // revalidates the AAC receipts but skips already-checkpointed inference.
        var saved = ContinuousClock.now
        for track in AudioTrack.allCases {
            let reader = try await RecordingAudioWindowReader.open(library: library, recording: recording, track: track)
            do {
                var eventIndex = 0
                while let event = try await reader.next() {
                    try Task.checkCancellation()
                    let candidate = makeWindow(event)
                    let existing = checkpoint.windows.indices.filter { checkpoint.windows[$0].track == track }
                    let index: Int
                    if eventIndex < existing.count {
                        index = existing[eventIndex]
                        guard sameSource(checkpoint.windows[index], candidate) else { throw FinalTranscriptionError.invalidCheckpoint }
                    } else {
                        checkpoint.windows.append(candidate); index = checkpoint.windows.count - 1
                        try await persist(checkpoint, since: &saved, stage: .decoding)
                    }
                    eventIndex += 1
                    // System audio is primary: its levels gate the microphone. Also
                    // measured for windows a resumed job skips, which are read anyway.
                    if track == .system, case .audio(let window) = event {
                        var levels = checkpoint.systemLevels ?? []
                        MicrophoneGate.record(window.samples, start: window.active.start, into: &levels)
                        checkpoint.systemLevels = levels
                    }
                    if checkpoint.windows[index].complete { continue }
                    switch event {
                    case .gap(let gap):
                        if track == .system {
                            try await diarization.process(gap)
                            checkpoint.speakerCheckpoint = try await diarization.checkpoint()
                        }
                        checkpoint.windows[index].blocks = []
                    case .audio(let window):
                        let louder = track == .microphone ? checkpoint.systemLevels.map {
                            MicrophoneGate.louderFrames(window.samples, start: window.active.start, system: $0)
                        } : nil
                        if checkpoint.windows[index].asr == nil, louder?.isEmpty == true {
                            // Nowhere louder than the system track: nothing of the user's to recognize.
                            checkpoint.windows[index].asr = FinalASRText(text: "", language: job.snapshot.settings.meetingLanguage)
                        }
                        if checkpoint.windows[index].asr == nil {
                            try await persist(checkpoint, since: &saved, stage: .transcribing)
                            var text = try await inference.finalText(models[.finalASR]!, samples: window.samples,
                                language: job.snapshot.settings.meetingLanguage)
                            // Auto detection can misidentify short or quiet audio (a 1.8 s
                            // tail was read as Portuguese). Meetings are English or Russian:
                            // transcribe again in the track's established language.
                            if !text.text.isEmpty, ![.english, .russian].contains(text.language) {
                                let earlier = checkpoint.windows[..<index].compactMap { $0.asr }.filter { !$0.text.isEmpty }
                                let sameTrack = checkpoint.windows[..<index].filter { $0.track == track }.compactMap { $0.asr }.filter { !$0.text.isEmpty }
                                var fallback = (sameTrack.last ?? earlier.last)?.language
                                if fallback.map({ ![.english, .russian].contains($0) }) ?? true {
                                    // Nothing recognized yet (a short "Да, да." opening was read
                                    // as Portuguese): take the language of the speech that follows.
                                    fallback = try await laterLanguage(recording: recording, track: track, after: eventIndex,
                                                                       model: models[.finalASR]!)
                                }
                                guard let fallback else { throw FinalTranscriptionError.undetectedLanguage }
                                text = try await inference.finalText(models[.finalASR]!, samples: window.samples, language: fallback)
                            }
                            guard text.text.utf8.count <= 8192,
                                  text.text.isEmpty || [.english, .russian].contains(text.language) else {
                                throw FinalTranscriptionError.invalidAlignment
                            }
                            checkpoint.windows[index].asr = text
                            try await persist(checkpoint, since: &saved, stage: .aligning)
                        }
                        let asr = checkpoint.windows[index].asr!
                        if checkpoint.windows[index].words == nil {
                            let raw = asr.text.isEmpty ? [] : try await inference.finalAlignment(models[.alignment]!,
                                samples: window.samples, text: asr.text, language: asr.language)
                            checkpoint.windows[index].words = try alignedWords(raw, asr: asr, window: window)
                            try await persist(checkpoint, since: &saved, stage: .diarizing)
                        }
                        if checkpoint.windows[index].speakers == nil {
                            if track == .system {
                                // Both together, so a save after an error never pairs these
                                // speakers with the previous window's speaker state.
                                let segments = try await diarization.process(window).segments
                                let state = try await diarization.checkpoint()
                                checkpoint.windows[index].speakers = segments; checkpoint.speakerCheckpoint = state
                            } else { checkpoint.windows[index].speakers = [] }
                            try await persist(checkpoint, since: &saved, stage: .diarizing)
                        }
                        // The window keeps every recognized word; blocks keep the user's.
                        let all = checkpoint.windows[index].words!
                        let words = all.filter { word in louder.map { MicrophoneGate.keep(word.active, louder: $0) } ?? true }
                        if louder != nil { checkpoint.windows[index].gatedWords = all.filter { !words.contains($0) } }
                        checkpoint.windows[index].blocks = try makeBlocks(window, words: words,
                            speakers: checkpoint.windows[index].speakers!, earlier: checkpoint.windows.prefix(index))
                    }
                    checkpoint.windows[index].complete = true
                    try await persist(checkpoint, since: &saved, stage: .decoding)
                }
                guard eventIndex == checkpoint.windows.filter({ $0.track == track }).count else {
                    throw FinalTranscriptionError.invalidCheckpoint
                }
                if !checkpoint.completedTracks.contains(track) { checkpoint.completedTracks.append(track) }
                try await store.saveFinalCheckpoint(checkpoint, stage: .decoding)
                saved = .now
                await reader.close()
            } catch {
                await reader.close()
                // Keep the progress since the last periodic save. A deleted or
                // cancelled job refuses it, which is already authoritative.
                try? await store.saveFinalCheckpoint(checkpoint, stage: .decoding)
                throw error
            }
        }
        try Self.validateCoverage(checkpoint, recording: recording, requireCorrection: false)
        while job.snapshot.settings.spellingCorrection, let first = pendingCorrections(checkpoint).first {
            try Task.checkCancellation()
            let pending = pendingCorrections(checkpoint)
            // Indexed batches cannot straddle a source track/day boundary.
            let origin = checkpoint.windows[first.0].blocks![first.1]
            let selected = Array(pending.prefix(Self.correctionBatchSize).prefix { key in
                let block = checkpoint.windows[key.0].blocks![key.1]
                return block.track == origin.track && block.day == origin.day
            })
            try await store.saveFinalCheckpoint(checkpoint, stage: .correcting)
            let originals = selected.map { key in
                let block = checkpoint.windows[key.0].blocks![key.1]
                return IndexedCorrection(id: block.id, text: block.originalText)
            }
            let corrected = try await correctBatch(originals, model: models[.spelling]!, settings: job.snapshot.settings)
            for (key, result) in zip(selected, corrected.0) { checkpoint.windows[key.0].blocks![key.1].correctedText = result.text }
            checkpoint.correctionBatches += corrected.1
            try await store.saveFinalCheckpoint(checkpoint, stage: .correcting)
        }
        try Task.checkCancellation()
        try Self.validateCoverage(checkpoint, recording: recording, requireCorrection: job.snapshot.settings.spellingCorrection)
        checkpoint.readyForPublication = true
        try await store.saveFinalCheckpoint(checkpoint, stage: .validating)
        return checkpoint
    }

    /// Window progress is saved at most this often. Each save rewrites the
    /// whole checkpoint (about 2 MB for a 22-minute call, most of it speaker
    /// state that changes every window): saving every step took 1526 saves and
    /// about 28 s of a 135 s job. A crash loses at most this much work; errors
    /// and cancellation save at once.
    static let checkpointInterval: Duration = .seconds(5)

    private func persist(_ checkpoint: FinalTranscriptionCheckpoint, since saved: inout ContinuousClock.Instant,
                         stage: JobStage) async throws {
        guard ContinuousClock.now - saved >= checkpointInterval else { return }
        try await store.saveFinalCheckpoint(checkpoint, stage: stage)
        saved = .now
    }

    /// Blocks per correction request. With changed-rows-only output, the
    /// request's fixed cost (system prompt, prefill) matters relatively more.
    static let correctionBatchSize = 4

    private func correctBatch(_ originals: [IndexedCorrection], model: ModelSnapshot,
                              settings: ProcessingSettings) async throws -> ([IndexedCorrection], [FinalCorrectionBatch]) {
        do {
            let output = try await inference.correctIndexed(model, settings: settings, blocks: originals)
            try Task.checkCancellation()
            guard output.contextPlan.role == .spelling, output.contextPlan.selection == settings.contextLimit,
                  output.contextPlan.inputTokens > 0, output.contextPlan.outputTokens > 0,
                  output.contextPlan.inputTokens <= output.contextPlan.contextTokens - output.contextPlan.outputTokens,
                  output.generatedTokens > 0, output.generatedTokens < output.contextPlan.outputTokens else {
                throw FinalTranscriptionError.invalidCorrection
            }
            return (IndexedSpellingCorrection.accept(output.text, originals: originals).corrections,
                [FinalCorrectionBatch(blockIDs: originals.map(\.id), contextPlan: output.contextPlan, generatedTokens: output.generatedTokens)])
        } catch FinalTranscriptionError.correctionBudget {
            guard originals.count > 1 else { throw FinalTranscriptionError.correctionBudget }
            let middle = originals.count / 2
            let first = try await correctBatch(Array(originals[..<middle]), model: model, settings: settings)
            let second = try await correctBatch(Array(originals[middle...]), model: model, settings: settings)
            return (first.0 + second.0, first.1 + second.1)
        }
    }

    private func pendingCorrections(_ checkpoint: FinalTranscriptionCheckpoint) -> [(Int, Int)] {
        checkpoint.windows.indices.flatMap { i in
            (checkpoint.windows[i].blocks ?? []).indices.compactMap { j in
                checkpoint.windows[i].blocks![j].correctedText == nil ? (i, j) : nil
            }
        }
    }

    private func makeWindow(_ event: AudioWindowReadEvent) -> FinalWindowCheckpoint {
        switch event {
        case .audio(let w): FinalWindowCheckpoint(id: UUID(), track: w.track, day: w.day, active: w.active,
            owned: w.owned, wallClockStart: w.wallClockStart, gapReason: nil, complete: false)
        case .gap(let g): FinalWindowCheckpoint(id: UUID(), track: g.track, day: g.day, active: g.active,
            owned: g.active, wallClockStart: g.wallClockStart, gapReason: g.reason, complete: false)
        }
    }
    private func sameSource(_ a: FinalWindowCheckpoint, _ b: FinalWindowCheckpoint) -> Bool {
        a.track == b.track && a.day == b.day && a.active == b.active && a.owned == b.owned &&
        a.wallClockStart == b.wallClockStart && a.gapReason == b.gapReason
    }

    private func alignedWords(_ raw: [FinalAlignmentItem], asr: FinalASRText,
                              window: RecordingAudioWindow) throws -> [FinalAlignedWord] {
        guard raw.count <= 2048,
              IndexedSpellingCorrection.lexicalKey(raw.map(\.text).joined()) == IndexedSpellingCorrection.lexicalKey(asr.text) else {
            throw FinalTranscriptionError.invalidAlignment
        }
        if asr.text.isEmpty { guard raw.isEmpty else { throw FinalTranscriptionError.invalidAlignment }; return [] }
        guard !raw.isEmpty else { throw FinalTranscriptionError.invalidAlignment }
        // The Qwen aligner strips punctuation (including decimal points and
        // minus signs) from its text tokens. Restore the exact ASR surfaces;
        // aligner normalization must never silently change a number or name.
        let surfaces = asr.text.split(whereSeparator: \.isWhitespace).map(String.init).filter {
            !IndexedSpellingCorrection.lexicalKey($0).isEmpty
        }
        guard surfaces.count == raw.count, zip(surfaces, raw).allSatisfy({
            IndexedSpellingCorrection.lexicalKey($0) == IndexedSpellingCorrection.lexicalKey($1.text)
        }) else { throw FinalTranscriptionError.invalidAlignment }
        // The aligner can place final word edges in the model padding after a
        // short last window. Clip them to the source audio; words are kept.
        let sourceEnd = min(window.active.duration,
                            try MediaTime(seconds: Double(window.validSampleFrames) / Double(RecordingAudioWindow.sampleRate)))
        let lastStart = try MediaTime(microseconds: max(0, sourceEnd.microseconds - 1_000))
        var words: [FinalAlignedWord] = [], previousStart = MediaTime.zero, previousEnd = MediaTime.zero
        for (surface, item) in zip(surfaces, raw) {
            guard !IndexedSpellingCorrection.lexicalKey(item.text).isEmpty,
                  item.relative.start >= previousStart,
                  item.relative.end >= previousEnd else { throw FinalTranscriptionError.invalidAlignment }
            // The aligner can also return a zero-length word (observed at a
            // window's first word); give it a minimal 10 ms span in the source.
            let start = min(item.relative.start, lastStart)
            let end = min(max(item.relative.end, try MediaTime(microseconds: start.microseconds + 10_000)), sourceEnd)
            let projected = try window.project(relative: try MediaInterval(start: start, end: end))
            previousStart = item.relative.start; previousEnd = item.relative.end
            words.append(FinalAlignedWord(text: surface, active: projected.active, wallClockStart: projected.wallClockStart))
        }
        return words
    }

    private func makeBlocks(_ window: RecordingAudioWindow, words: [FinalAlignedWord],
                            speakers: [DiarizedSystemSegment], earlier: ArraySlice<FinalWindowCheckpoint>) throws -> [FinalTextBlock] {
        var words = words.filter {
            let midpoint = $0.active.start.microseconds + $0.active.duration.microseconds / 2
            return midpoint >= window.owned.start.microseconds && midpoint < window.owned.end.microseconds
        }
        // Ownership handles exact overlap; this narrow temporal guard also
        // removes an identical boundary word whose alignment jitter crossed it.
        if let previous = earlier.last(where: { $0.track == window.track }), previous.gapReason == nil,
           previous.day == window.day, previous.active.end > window.active.start,
           let old = previous.blocks?.last?.words.last, let next = words.first,
           old.active.end > next.active.start,
           IndexedSpellingCorrection.lexicalKey(old.text) == IndexedSpellingCorrection.lexicalKey(next.text) {
            words.removeFirst()
        }
        var result: [FinalTextBlock] = [], group: [FinalAlignedWord] = [], candidates: [UUID] = []
        func flush() throws {
            guard let first = group.first, let last = group.last else { return }
            result.append(FinalTextBlock(id: UUID(), recordingID: window.recordingID, day: window.day,
                track: window.track, words: group, interval: try MediaInterval(start: first.active.start, end: last.active.end),
                speakerCandidates: candidates, originalText: group.map(\.text).joined(separator: " ")))
            group.removeAll(keepingCapacity: true)
        }
        let activity = speakers.map { ($0.speakerID, $0.active) }
        for word in words {
            let current = window.track == .microphone ? [] : Self.wordSpeakers(word.active, activity).resolved
            if !group.isEmpty, current != candidates || group.count >= 32 ||
                group.map(\.text).joined(separator: " ").utf8.count + word.text.utf8.count > 512 ||
                word.active.start.microseconds - group.last!.active.end.microseconds > 2_000_000 {
                try flush()
            }
            candidates = current; group.append(word)
        }
        try flush()
        return result
    }

    /// A word overlapping two speakers' activity belongs to the one covering
    /// at least this much more of it. Words at a turn change of the user's
    /// two-person test measured 0.9–1.0 for the speaker and 0.03–0.42 for the
    /// other; overlapping speech stayed within 0.3 (0.96/0.95, 1.0/1.0).
    static let wordDominance = 0.3

    /// The speakers active during a word (sorted), and the speaker it belongs
    /// to when one covers it by `wordDominance` more than any other.
    static func wordSpeakers(_ word: MediaInterval, _ activity: [(UUID, MediaInterval)]) -> (all: [UUID], resolved: [UUID]) {
        var covered: [UUID: Int64] = [:]
        for (id, active) in activity where active.start < word.end && word.start < active.end {
            covered[id, default: 0] += min(active.end, word.end).microseconds - max(active.start, word.start).microseconds
        }
        let all = covered.keys.sorted { $0.uuidString < $1.uuidString }
        guard all.count > 1, word.duration.microseconds > 0 else { return (all, all) }
        let shares = covered.map { (id: $0.key, share: Double($0.value) / Double(word.duration.microseconds)) }
            .sorted { $0.share > $1.share }
        return (all, shares[0].share - shares[1].share >= wordDominance ? [shares[0].id] : all)
    }

    static func validateCoverage(_ checkpoint: FinalTranscriptionCheckpoint, recording: Recording,
                                  requireCorrection: Bool = true) throws {
        guard Set(checkpoint.completedTracks) == Set(AudioTrack.allCases),
              checkpoint.completedTracks.count == AudioTrack.allCases.count,
              Set(checkpoint.windows.map(\.id)).count == checkpoint.windows.count else { throw FinalTranscriptionError.incompleteCoverage }
        for track in AudioTrack.allCases {
            var end = MediaTime.zero
            var previous: FinalWindowCheckpoint?
            for window in checkpoint.windows where window.track == track {
                guard window.complete, window.owned.start == end, window.owned.end <= recording.activeDuration,
                      recording.days.contains(window.day), window.active.start <= window.owned.start,
                      window.active.end >= window.owned.end, window.blocks != nil else { throw FinalTranscriptionError.incompleteCoverage }
                end = window.owned.end
                if window.gapReason == nil {
                    guard let asr = window.asr, window.words != nil, window.speakers != nil,
                          asr.text.isEmpty || [.english, .russian].contains(asr.language),
                          IndexedSpellingCorrection.lexicalKey(window.words!.map(\.text).joined()) == IndexedSpellingCorrection.lexicalKey(asr.text),
                          window.words!.allSatisfy({
                              $0.active.duration > .zero && $0.active.start >= window.active.start && $0.active.end <= window.active.end &&
                              abs($0.wallClockStart.timeIntervalSince(window.wallClockStart.addingTimeInterval($0.active.start.seconds - window.active.start.seconds))) < 0.000002
                          }),
                          window.blocks!.flatMap(\.words).allSatisfy({ window.words!.contains($0) }),
                          window.speakers!.allSatisfy({
                              $0.recordingID == recording.id && $0.dayID == window.day.id && $0.number > 0 &&
                              $0.active.duration > .zero && $0.active.start >= window.owned.start && $0.active.end <= window.owned.end &&
                              abs($0.wallClockStart.timeIntervalSince(window.wallClockStart.addingTimeInterval($0.active.start.seconds - window.active.start.seconds))) < 0.000002
                          }),
                          track != .microphone || window.speakers!.isEmpty else {
                        throw FinalTranscriptionError.invalidCheckpoint
                    }
                    let gated = window.gatedWords ?? []
                    guard track == .microphone || gated.isEmpty, gated.allSatisfy(window.words!.contains) else {
                        throw FinalTranscriptionError.invalidCheckpoint
                    }
                    var expected = window.words!.filter {
                        let middle = $0.active.start.microseconds + $0.active.duration.microseconds / 2
                        return middle >= window.owned.start.microseconds && middle < window.owned.end.microseconds && !gated.contains($0)
                    }
                    if let previous, previous.gapReason == nil, previous.day == window.day,
                       previous.active.end > window.active.start,
                       let old = previous.blocks?.last?.words.last, let next = expected.first,
                       old.active.end > next.active.start,
                       IndexedSpellingCorrection.lexicalKey(old.text) == IndexedSpellingCorrection.lexicalKey(next.text) {
                        expected.removeFirst()
                    }
                    guard window.blocks!.flatMap(\.words) == expected else { throw FinalTranscriptionError.incompleteCoverage }
                } else if !window.blocks!.isEmpty { throw FinalTranscriptionError.invalidCheckpoint }
                for block in window.blocks! {
                    guard block.recordingID == recording.id, block.track == track, block.day == window.day,
                          !block.words.isEmpty, block.interval.start == block.words.first!.active.start,
                          block.interval.end == block.words.last!.active.end,
                          block.originalText == block.words.map(\.text).joined(separator: " "),
                          block.words.allSatisfy({ $0.active.duration > .zero && $0.active.start >= window.active.start && $0.active.end <= window.active.end }),
                          track != .microphone || block.speakerCandidates.isEmpty,
                          // Checkpoints from before `wordDominance` keep every active speaker.
                          block.words.allSatisfy({ word in
                              guard track != .microphone else { return true }
                              let speakers = wordSpeakers(word.active, window.speakers!.map { ($0.speakerID, $0.active) })
                              return Set(block.speakerCandidates) == Set(speakers.resolved) || Set(block.speakerCandidates) == Set(speakers.all)
                          }),
                          !requireCorrection || block.correctedText.map({ IndexedSpellingCorrection.safe(block.originalText, $0) }) == true else {
                        throw FinalTranscriptionError.invalidCheckpoint
                    }
                }
                previous = window
            }
            guard end == recording.activeDuration else { throw FinalTranscriptionError.incompleteCoverage }
        }
        guard Set(checkpoint.blocks.map(\.id)).count == checkpoint.blocks.count else { throw FinalTranscriptionError.invalidCheckpoint }
        if requireCorrection {
            let covered = checkpoint.correctionBatches.flatMap(\.blockIDs)
            guard covered.count == checkpoint.blocks.count, Set(covered) == Set(checkpoint.blocks.map(\.id)) else {
                throw FinalTranscriptionError.invalidCheckpoint
            }
            for batch in checkpoint.correctionBatches {
                let plan = batch.contextPlan
                guard !batch.blockIDs.isEmpty, plan.selection == checkpoint.job.settings.contextLimit,
                      plan.role == .spelling, batch.generatedTokens > 0, batch.generatedTokens < plan.outputTokens,
                      plan == (try TextContextPlanner.resolve(selection: plan.selection, role: .spelling,
                          inputTokens: plan.inputTokens, outputTokens: plan.outputTokens)) else {
                    throw FinalTranscriptionError.invalidCheckpoint
                }
                let selected = checkpoint.blocks.filter { batch.blockIDs.contains($0.id) }
                guard let first = selected.first, selected.allSatisfy({ $0.track == first.track && $0.day == first.day }) else {
                    throw FinalTranscriptionError.invalidCheckpoint
                }
            }
        }
    }
}
