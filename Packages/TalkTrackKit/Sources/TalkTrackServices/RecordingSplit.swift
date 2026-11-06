import Darwin
import Foundation
import TalkTrackDomain

/// What a split made: the part before the cut keeps the recording's id, the
/// part from it is a new recording. Parts without a current final transcript
/// should be queued for transcription.
public struct RecordingSplitResult: Equatable, Sendable {
    public let first: Recording
    public let second: Recording
    public let needsTranscription: Bool
}

public enum RecordingSplitError: Error, Equatable, LocalizedError, Sendable {
    case missing, capturing, busy, tooShort, unsupported

    public var errorDescription: String? {
        switch self {
        case .missing: "This recording is unavailable."
        case .capturing: "This recording is still being recorded."
        case .busy: "This recording is still being processed."
        case .tooShort: "Each part must be at least one second long."
        case .unsupported: "This recording's audio cannot be split."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .missing, .unsupported: nil
        case .capturing: "Stop the recording before splitting it."
        case .busy: "Wait until processing finishes, or cancel it, then split again."
        case .tooShort: "Choose a point further from the start or end."
        }
    }
}

/// A committed split: where `source` was cut and which recording took the
/// rest. Kept after the files are finished, so saved-voice samples confirmed
/// before the split still find their speech (design D4 of split-recording).
struct RecordingSplitRecord: Codable, Equatable, Sendable {
    let source: UUID
    let part: UUID
    let meetingID: UUID
    let at: MediaTime
    var finished: Bool
}

/// The two recordings a cut produces (pure; design D1 of split-recording).
struct RecordingCut {
    let first: Recording
    let second: Recording

    static let minimumPart: Int64 = 1_000_000

    init(_ recording: Recording, at cut: MediaTime, partID: UUID) throws {
        guard cut.microseconds >= Self.minimumPart,
              recording.activeDuration.microseconds - cut.microseconds >= Self.minimumPart else {
            throw RecordingSplitError.tooShort
        }
        // Every chunk interval must cover its whole valid chunk (the writer's invariant).
        let chunks = Dictionary(uniqueKeysWithValues: recording.chunks.map { ($0.id, $0) })
        var covered = Set<UUID>()
        for interval in recording.trackIntervals {
            guard case let .chunk(id, first, count) = interval.content else { continue }
            guard let chunk = chunks[id], first == chunk.leadingTrimFrames,
                  count == chunk.decodedFrameCount - chunk.leadingTrimFrames - chunk.trailingTrimFrames,
                  interval.active == chunk.active, covered.insert(id).inserted else { throw RecordingSplitError.unsupported }
        }
        guard covered.count == chunks.count, !recording.captureIntervals.isEmpty else { throw RecordingSplitError.unsupported }
        let T = cut.microseconds
        func time(_ microseconds: Int64) throws -> MediaTime { try MediaTime(microseconds: microseconds) }
        func interval(_ start: Int64, _ end: Int64) throws -> MediaInterval { try MediaInterval(start: time(start), end: time(end)) }

        // Capture intervals and days.
        var firstCaptures: [CaptureInterval] = [], secondCaptures: [CaptureInterval] = []
        var wallAtCut: Date?, zoneAtCut = recording.timeZoneIdentifier
        for capture in recording.captureIntervals {
            let s = capture.active.start.microseconds, e = capture.active.end.microseconds
            if s < T {
                firstCaptures.append(CaptureInterval(active: try interval(s, min(e, T)), wallClockStart: capture.wallClockStart,
                                                     hostTimeStart: capture.hostTimeStart, dayID: capture.dayID))
            }
            if e > T {
                let start = max(s, T), offset = start - s
                let wall = capture.wallClockStart.addingTimeInterval(Double(offset) / 1_000_000)
                if secondCaptures.isEmpty {
                    wallAtCut = wall
                    zoneAtCut = recording.days.first { $0.id == capture.dayID }?.timeZoneIdentifier ?? zoneAtCut
                }
                secondCaptures.append(CaptureInterval(active: try interval(start - T, e - T), wallClockStart: wall,
                    hostTimeStart: try Self.addingHostMicroseconds(capture.hostTimeStart, offset), dayID: capture.dayID))
            }
        }
        guard let wallAtCut, let lastFirst = firstCaptures.last, !secondCaptures.isEmpty else { throw RecordingSplitError.unsupported }
        func days(_ captures: [CaptureInterval]) -> [RecordingDay] {
            let used = Set(captures.map(\.dayID))
            return recording.days.filter { used.contains($0.id) }
        }

        // Chunks: before, after, or cut by trims.
        var firstChunks: [TrackChunk] = [], secondChunks: [TrackChunk] = []
        let prefix = "Meetings/\(recording.meetingID)/Recordings/\(partID)"
        for chunk in recording.chunks {
            let s = chunk.active.start.microseconds, e = chunk.active.end.microseconds
            let rate = UInt64(chunk.sampleRate)
            let valid = chunk.decodedFrameCount - chunk.leadingTrimFrames - chunk.trailingTrimFrames
            if e <= T { firstChunks.append(chunk); continue }
            var keptBefore: UInt64 = 0, skippedBefore: UInt64 = 0
            if s < T {
                let exact = UInt64(T - s) * rate
                keptBefore = min(valid, exact / 1_000_000)
                skippedBefore = min(valid, (exact + 999_999) / 1_000_000)
                if keptBefore > 0 {
                    firstChunks.append(try TrackChunk(id: chunk.id, track: chunk.track, file: chunk.file,
                        active: try interval(s, s + Self.frameTime(keptBefore, rate: chunk.sampleRate)),
                        sampleRate: chunk.sampleRate, decodedFrameCount: chunk.decodedFrameCount,
                        leadingTrimFrames: chunk.leadingTrimFrames,
                        trailingTrimFrames: chunk.decodedFrameCount - chunk.leadingTrimFrames - keptBefore,
                        hostTimeStart: chunk.hostTimeStart))
                }
            }
            let rest = valid - skippedBefore
            guard rest > 0 else { continue }
            let end = e - T, start = max(0, end - Self.frameTime(rest, rate: chunk.sampleRate))
            secondChunks.append(try TrackChunk(id: chunk.id, track: chunk.track,
                file: RelativePath("\(prefix)/\(chunk.track.rawValue)/\(chunk.id).m4a"),
                active: try interval(start, end), sampleRate: chunk.sampleRate, decodedFrameCount: chunk.decodedFrameCount,
                leadingTrimFrames: chunk.leadingTrimFrames + skippedBefore, trailingTrimFrames: chunk.trailingTrimFrames,
                hostTimeStart: chunk.hostTimeStart))
        }

        // Gaps are clipped and shifted; chunk intervals follow their chunks.
        func intervals(_ chunks: [TrackChunk], gaps: [TrackInterval]) -> [TrackInterval] {
            (gaps + chunks.map {
                TrackInterval(track: $0.track, active: $0.active, content: .chunk(id: $0.id, firstDecodedFrame: $0.leadingTrimFrames,
                    frameCount: $0.decodedFrameCount - $0.leadingTrimFrames - $0.trailingTrimFrames))
            }).sorted { ($0.track.rawValue, $0.active.start.microseconds) < ($1.track.rawValue, $1.active.start.microseconds) }
        }
        var firstGaps: [TrackInterval] = [], secondGaps: [TrackInterval] = []
        for gap in recording.trackIntervals {
            guard case .gap = gap.content else { continue }
            let s = gap.active.start.microseconds, e = gap.active.end.microseconds
            if s < T, min(e, T) > s { firstGaps.append(TrackInterval(track: gap.track, active: try interval(s, min(e, T)), content: gap.content)) }
            if e > T, e > max(s, T) { secondGaps.append(TrackInterval(track: gap.track, active: try interval(max(s, T) - T, e - T), content: gap.content)) }
        }
        func echo(_ stretches: [PlaybackEchoStretch]?, from: Int64, to: Int64) throws -> [PlaybackEchoStretch]? {
            guard let stretches else { return nil }
            return try stretches.compactMap { stretch in
                let s = max(stretch.active.start.microseconds, from), e = min(stretch.active.end.microseconds, to)
                guard e > s else { return nil }
                return PlaybackEchoStretch(active: try interval(s - from, e - from), state: stretch.state, peak: stretch.peak,
                                           lagMilliseconds: stretch.lagMilliseconds)
            }
        }

        var first = recording
        first.activeDuration = cut
        first.endedAt = lastFirst.wallClockStart.addingTimeInterval(lastFirst.active.duration.seconds)
        first.days = days(firstCaptures)
        first.captureIntervals = firstCaptures
        first.chunks = firstChunks
        first.trackIntervals = intervals(firstChunks, gaps: firstGaps)
        first.playbackEcho = try echo(recording.playbackEcho, from: 0, to: T)
        first.generation += 1

        var second = try Recording(id: partID, meetingID: recording.meetingID, startedAt: wallAtCut, timeZoneIdentifier: zoneAtCut)
        second.state = recording.state
        second.endedAt = recording.endedAt
        second.activeDuration = try time(recording.activeDuration.microseconds - T)
        second.days = days(secondCaptures)
        second.captureIntervals = secondCaptures
        second.chunks = secondChunks
        second.trackIntervals = intervals(secondChunks, gaps: secondGaps)
        second.playbackEcho = try echo(recording.playbackEcho, from: T, to: recording.activeDuration.microseconds)
        second.generation = 1
        // Both parts must form a valid timeline on their own.
        _ = try MeetingTimeline(meetingID: recording.meetingID, recordings: [first])
        _ = try MeetingTimeline(meetingID: recording.meetingID, recordings: [second])
        self.first = first; self.second = second
    }

    /// Frames to microseconds, rounded as `MeetingTimeline` rounds them.
    static func frameTime(_ frames: UInt64, rate: UInt32) -> Int64 {
        let rate = UInt64(rate)
        return Int64(frames / rate * 1_000_000 + (frames % rate * 1_000_000 + rate / 2) / rate)
    }

    static func addingHostMicroseconds(_ anchor: UInt64, _ microseconds: Int64) throws -> UInt64 {
        var base = mach_timebase_info_data_t()
        guard mach_timebase_info(&base) == KERN_SUCCESS, base.numer > 0 else { throw RecordingSplitError.unsupported }
        let ticks = (Double(microseconds) * 1_000 * Double(base.denom) / Double(base.numer)).rounded()
        guard ticks >= 0, ticks < Double(UInt64.max), !anchor.addingReportingOverflow(UInt64(ticks)).overflow else {
            throw RecordingSplitError.unsupported
        }
        return anchor + UInt64(ticks)
    }
}

extension SessionStore {
    /// Splits one stopped recording at `cut` (its active time) into two
    /// recordings of the same meeting (split-recording D1–D3). The part before
    /// keeps the recording's id; the part from `cut` is a new recording. Text,
    /// names and named replies are divided by time without a model; the audio is
    /// cut exactly, the chunk under the cut is shared by a cloned file. Files
    /// of the new part are staged first, rows commit in one transaction, then
    /// the files are finished (again at the next launch after a failure).
    @discardableResult
    public func splitRecording(_ recordingID: UUID, meetingID: UUID, at cut: MediaTime,
                               date: Date = Date()) throws -> RecordingSplitResult {
        guard let recording = try recordings(meetingID: meetingID).first(where: { $0.id == recordingID }) else {
            throw RecordingSplitError.missing
        }
        guard [.complete, .interrupted].contains(recording.state) else { throw RecordingSplitError.capturing }
        let plan = try RecordingCut(recording, at: cut, partID: UUID())
        try stageSplitPart(original: recording, part: plan.second)
        let result: RecordingSplitResult
        do {
            result = try db.transaction { try writeSplit(recording, plan: plan, at: cut, date: date) }
        } catch {
            try? removeSplitStaging(meetingID: meetingID, partID: plan.second.id)
            throw error
        }
        voiceGroups = [:]; replyClusters = [:]
        // Committed; anything left is finished at the next launch.
        if let record: RecordingSplitRecord = try? record(.recordingSplit, id: plan.second.id) { try? finishSplit(record) }
        return result
    }

    private func writeSplit(_ original: Recording, plan: RecordingCut, at cut: MediaTime, date: Date) throws -> RecordingSplitResult {
        let meetingID = original.meetingID, T = cut.microseconds
        guard let current: Recording = try record(.recording, id: original.id), current == original else { throw StoreError.staleSource }
        let jobs = try self.jobs(meetingID: meetingID)
        let unfinished: (ProcessingJob) -> Bool = { ![.completed, .failed, .interrupted, .cancelled].contains($0.stage) }
        guard !jobs.contains(where: { unfinished($0) && $0.snapshot.recordingID == original.id }) else { throw RecordingSplitError.busy }
        let before = try sourceSnapshot(meetingID: meetingID)
        let first = plan.first, second = plan.second
        let a = original.id.uuidString, b = second.id.uuidString
        func interval(_ start: Int64, _ end: Int64) throws -> MediaInterval {
            try MediaInterval(start: MediaTime(microseconds: max(0, start)), end: MediaTime(microseconds: max(0, max(start, end))))
        }
        func shifted(_ value: MediaInterval) throws -> MediaInterval {
            try interval(max(value.start.microseconds, T) - T, value.end.microseconds - T)
        }
        func clipped(_ value: MediaInterval) throws -> MediaInterval {
            try interval(value.start.microseconds, min(value.end.microseconds, T))
        }

        // 1. The recordings.
        try put(.recording, id: first.id, meetingID: meetingID, scope: a, value: first)
        try put(.recording, id: second.id, meetingID: meetingID, scope: b, value: second)

        // 2. Text by time; segment ids stay, so names, fragments and translations follow.
        let shownText = try transcript(meetingID: meetingID, recordingID: original.id)
        let needsTranscription = !(shownText?.kind == .final && shownText?.sourceGeneration == original.generation)
        var revisions: (first: TranscriptRevision, second: TranscriptRevision)?
        var secondSegments = Set<UUID>()
        if let shownText {
            var early: [TranscriptSegment] = [], late: [TranscriptSegment] = []
            for segment in shownText.segments {
                if segment.interval.start.microseconds < T {
                    early.append(TranscriptSegment(id: segment.id, recordingID: first.id, dayID: segment.dayID, track: segment.track,
                        interval: try clipped(segment.interval), wallClockStart: segment.wallClockStart, speaker: segment.speaker,
                        originalText: segment.originalText, correctedText: segment.correctedText,
                        alignmentModelRevision: segment.alignmentModelRevision))
                } else {
                    late.append(TranscriptSegment(id: segment.id, recordingID: second.id, dayID: segment.dayID, track: segment.track,
                        interval: try shifted(segment.interval), wallClockStart: segment.wallClockStart, speaker: segment.speaker,
                        originalText: segment.originalText, correctedText: segment.correctedText,
                        alignmentModelRevision: segment.alignmentModelRevision))
                    secondSegments.insert(segment.id)
                }
            }
            let firstRevision = TranscriptRevision(recordingID: first.id, sourceGeneration: needsTranscription ? shownText.sourceGeneration : first.generation,
                kind: shownText.kind, segments: early, modelRevisions: shownText.modelRevisions, createdAt: date)
            let secondRevision = TranscriptRevision(recordingID: second.id, sourceGeneration: needsTranscription ? 0 : second.generation,
                kind: shownText.kind, segments: late, modelRevisions: shownText.modelRevisions, createdAt: date)
            try put(.transcript, id: firstRevision.id, meetingID: meetingID, scope: a, value: firstRevision)
            try put(.transcript, id: secondRevision.id, meetingID: meetingID, scope: b, value: secondRevision)
            try setHead(.transcript, meetingID: meetingID, scope: a, id: firstRevision.id)
            try setHead(.transcript, meetingID: meetingID, scope: b, id: secondRevision.id)
            revisions = (firstRevision, secondRevision)
        }

        // 3. Named fragments follow their block, else their start.
        for anchor in try fragmentAnchors(meetingID: meetingID) where anchor.recordingID == original.id {
            guard secondSegments.contains(anchor.segmentID) || (shownText?.segments.contains { $0.id == anchor.segmentID } != true
                                                                && anchor.interval.start.microseconds >= T) else { continue }
            let moved = FragmentAnchor(id: anchor.id, meetingID: meetingID, recordingID: second.id, dayID: anchor.dayID,
                segmentID: anchor.segmentID, interval: try shifted(anchor.interval), name: anchor.name,
                createdAt: anchor.createdAt, voiceID: anchor.voiceID)
            try db.execute("UPDATE records SET payload=? WHERE kind='fragmentAnchor' AND id=?",
                           [.blob(DomainCodec.encode(moved)), .text(anchor.id.uuidString)])
        }

        // 4. Name evidence of every assignment revision, divided by time.
        var rewritten: [UUID: SpeakerAssignment] = [:]
        let stored: [SpeakerAssignment] = try records(.assignment, meetingID: meetingID)
        for assignment in stored where assignment.evidence.contains(where: { $0.recordingID == original.id && $0.interval.end.microseconds > T }) {
            let evidence = try assignment.evidence.map { item -> SpeechEvidence in
                guard item.recordingID == original.id else { return item }
                return item.interval.start.microseconds < T
                    ? SpeechEvidence(recordingID: first.id, interval: try clipped(item.interval), embeddingFingerprint: item.embeddingFingerprint)
                    : SpeechEvidence(recordingID: second.id, interval: try shifted(item.interval), embeddingFingerprint: item.embeddingFingerprint)
            }
            let value = SpeakerAssignment(id: assignment.id, meetingID: meetingID, dayID: assignment.dayID, daySpeakerID: assignment.daySpeakerID,
                name: assignment.name, origin: assignment.origin, evidence: evidence, createdAt: assignment.createdAt)
            rewritten[value.id] = value
            try db.execute("UPDATE records SET payload=? WHERE kind='assignment' AND id=?", [.blob(DomainCodec.encode(value)), .text(value.id.uuidString)])
        }

        // 5. The saved draft and its names.
        if let draft: LiveDraft = try record(.liveDraft, id: original.id) {
            func utterance(_ u: LiveUtterance, _ id: UUID, _ map: (MediaInterval) throws -> MediaInterval) throws -> LiveUtterance {
                LiveUtterance(id: u.id, recordingID: id, day: u.day, track: u.track, context: try map(u.context), interval: try map(u.interval),
                              wallClockStart: u.wallClockStart, speakers: u.speakers, text: u.text, detectedLanguage: u.detectedLanguage)
            }
            let early = try draft.utterances.filter { $0.interval.start.microseconds < T }.map { try utterance($0, first.id, clipped) }
            let late = try draft.utterances.filter { $0.interval.start.microseconds >= T }.map { try utterance($0, second.id, shifted) }
            try put(.liveDraft, id: original.id, meetingID: meetingID, scope: a,
                    value: LiveDraft(id: original.id, meetingID: meetingID, recordingID: first.id, utterances: early, savedAt: draft.savedAt, complete: draft.complete))
            try put(.liveDraft, id: second.id, meetingID: meetingID, scope: b,
                    value: LiveDraft(id: second.id, meetingID: meetingID, recordingID: second.id, utterances: late, savedAt: draft.savedAt, complete: draft.complete))
            let shown: LiveDraft? = try head(.liveDraft, meetingID: meetingID, scope: a)
            if shown != nil { try setHead(.liveDraft, meetingID: meetingID, scope: b, id: second.id) }
            let lateIDs = Set(late.map(\.id))
            for name in try liveNames(meetingID: meetingID) where name.recordingID == original.id {
                let moves = name.kind == .reply && name.utteranceID.map(lateIDs.contains) == true
                guard moves || name.kind == .voice else { continue }
                let copy = LiveName(id: UUID(), meetingID: meetingID, recordingID: second.id, dayID: name.dayID, kind: name.kind,
                    utteranceID: name.utteranceID, liveSpeakerID: name.liveSpeakerID,
                    intervals: try name.intervals.map(shifted), name: name.name, createdAt: name.createdAt)
                try put(.liveName, id: copy.id, meetingID: meetingID, scope: b, value: copy)
                try setHead(.liveName, meetingID: meetingID, scope: copy.scope, id: copy.id)
                if moves {
                    try db.execute("DELETE FROM heads WHERE meeting_id=? AND kind='liveName' AND scope=?",
                                   [.text(meetingID.uuidString), .text(name.scope)])
                }
            }
        }

        // 6. Unfinished translations cannot publish over the new parts.
        for var job in jobs where job.snapshot.kind == .translation && unfinished(job) {
            job.stage = .cancelled; job.lastError = "A recording of this meeting was split."
            try saveJob(job)
        }

        // A current final transcript stays current in the new part: it gets a
        // completed transcription job like the original's (status and queue read jobs).
        if !needsTranscription, let done = jobs.last(where: { $0.snapshot.kind == .finalTranscription
            && $0.snapshot.recordingID == original.id && $0.stage == .completed }) {
            let source = try sourceSnapshot(meetingID: meetingID)
            try saveJob(ProcessingJob(snapshot: ProcessingJobSnapshot(kind: .finalTranscription, recordingID: second.id,
                source: source, settings: done.snapshot.settings, models: done.snapshot.models, createdAt: date), stage: .completed))
        }

        // 7. The split record, then the meeting.
        try put(.recordingSplit, id: second.id, meetingID: meetingID, scope: "split",
                value: RecordingSplitRecord(source: original.id, part: second.id, meetingID: meetingID, at: MediaTime(microseconds: T), finished: false))
        var owner = try meeting(meetingID)
        owner.generation += 1
        owner.latestRecordingStartedAt = max(owner.latestRecordingStartedAt ?? .distantPast, second.startedAt)
        try update(owner)

        // 8. The translation stays exactly as current as it was.
        if let revisions { try splitTranslation(meetingID: meetingID, original: original, first: first, second: second,
                                                revisions: revisions, previous: shownText!, assignments: rewritten, before: before) }
        _ = try meetingTranscript(meetingID: meetingID)
        return RecordingSplitResult(first: first, second: second, needsTranscription: needsTranscription)
    }

    private func splitTranslation(meetingID: UUID, original: Recording, first: Recording, second: Recording,
                                  revisions: (first: TranscriptRevision, second: TranscriptRevision), previous: TranscriptRevision,
                                  assignments: [UUID: SpeakerAssignment], before: SourceSnapshot) throws {
        guard let output: GeneratedOutput = try head(.translation, meetingID: meetingID),
              let source: TranslationSource = try record(.translationSource, id: output.job.id),
              source.recordings.contains(where: { $0.id == original.id }) else { return }
        let old = output.job.source
        let wasCurrent = old.recordingGenerations == before.recordingGenerations && old.transcriptRevisionIDs == before.transcriptRevisionIDs
        let after = try sourceSnapshot(meetingID: meetingID)
        var generations = old.recordingGenerations, revisionIDs = old.transcriptRevisionIDs
        if wasCurrent {
            generations = after.recordingGenerations; revisionIDs = after.transcriptRevisionIDs
        } else {
            generations[second.id] = second.generation
            if let i = revisionIDs.firstIndex(of: previous.id) { revisionIDs.insert(revisions.second.id, at: i + 1) }
        }
        let frozenRevision = source.revisions.first { $0.recordingID == original.id }
        let parts: [TranscriptRevision] = frozenRevision?.id == previous.id ? [revisions.first, revisions.second] : []
        let job = ProcessingJobSnapshot(kind: output.job.kind, recordingID: output.job.recordingID,
            source: SourceSnapshot(meetingID: meetingID, meetingGeneration: old.meetingGeneration,
                cancellationGeneration: old.cancellationGeneration, recordingGenerations: generations,
                transcriptRevisionIDs: revisionIDs, notesRevisionID: old.notesRevisionID),
            settings: output.job.settings, models: output.job.models, createdAt: output.job.createdAt)
        let recordings = source.recordings.flatMap { $0.id == original.id ? [first, second] : [$0] }
        let frozen = parts.isEmpty ? source.revisions : source.revisions.flatMap { $0.recordingID == original.id ? parts : [$0] }
        let split = TranslationSource(job: job, recordings: recordings, revisions: frozen, speakers: source.speakers,
                                      assignments: source.assignments.map { assignments[$0.id] ?? $0 })
        let text = try split.items(translations: output.translatedSegments).map(\.text).joined(separator: "\n\n")
        let result = GeneratedOutput(kind: .translation, job: job, text: text, translatedSegments: output.translatedSegments,
                                     createdAt: output.createdAt)
        try put(.translationSource, id: job.id, meetingID: meetingID, value: split)
        try put(.translation, id: result.id, meetingID: meetingID, value: result)
        try setHead(.translation, meetingID: meetingID, id: result.id)
    }

    // MARK: Files (design D3)

    private func recordingsDirectory(_ meetingID: UUID) throws -> DirectoryHandle {
        try DirectoryHandle.openAbsolute(library.directory).directory("Meetings").createDirectory(meetingID.uuidString)
            .createDirectory("Recordings")
    }

    static func stagingName(_ partID: UUID) -> String { ".split-\(partID.uuidString)" }

    /// Clones every chunk the new part uses into `.split-<part>` with new
    /// receipts and the part's manifest. Nothing refers to it before the commit.
    func stageSplitPart(original: Recording, part: Recording) throws {
        let recordings = try recordingsDirectory(original.meetingID)
        let staging = Self.stagingName(part.id)
        try recordings.removeTree(staging)
        let source = try recordings.directory(original.id.uuidString)
        let target = try recordings.createDirectory(staging)
        var receipts: [StoredAudioChunk] = []
        for chunk in part.chunks {
            let from = try source.directory(chunk.track.rawValue), to = try target.createDirectory(chunk.track.rawValue)
            let name = "\(chunk.id).m4a"
            let old = try DomainCodec.decode(StoredAudioChunk.self, from: from.read("\(chunk.id).json", maximum: 65_536))
            guard old.chunk.id == chunk.id, old.encoding.validFrames == chunk.decodedFrameCount else { throw RecordingSplitError.unsupported }
            try Self.cloneFile(name, from: from, to: to)
            let receipt = StoredAudioChunk(libraryID: library.manifest.libraryID, meetingID: part.meetingID, recordingID: part.id,
                                           chunk: chunk, encoding: old.encoding, byteCount: old.byteCount, sha256: old.sha256)
            try to.writeExclusive("\(chunk.id).json", data: DomainCodec.encode(receipt))
            receipts.append(receipt)
        }
        for track in AudioTrack.allCases where target.exists(track.rawValue) { try target.directory(track.rawValue).syncAudioDirectory() }
        try target.writeExclusive("manifest.json", data: DomainCodec.encode(RecordingAudioManifest(recording: part, audio: receipts)))
        try target.syncAudioDirectory(); try recordings.syncAudioDirectory()
    }

    /// A copy-on-write clone where the volume supports it, else a data copy.
    static func cloneFile(_ name: String, from: DirectoryHandle, to: DirectoryHandle) throws {
        if clonefileat(from.fd, name, to.fd, name, 0) == 0 { return }
        guard errno == ENOTSUP || errno == EXDEV else { throw LibraryError.io(operation: "copy audio for the split", code: errno) }
        let input = openat(from.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw LibraryError.io(operation: "open audio for the split", code: errno) }
        defer { Darwin.close(input) }
        let output = openat(to.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw LibraryError.io(operation: "create audio for the split", code: errno) }
        defer { Darwin.close(output) }
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0, fsync(output) == 0 else {
            throw LibraryError.io(operation: "copy audio for the split", code: errno)
        }
    }

    func removeSplitStaging(meetingID: UUID, partID: UUID) throws {
        try recordingsDirectory(meetingID).removeTree(Self.stagingName(partID))
    }

    /// After the commit: the staged folder becomes the part's folder, the
    /// original's cut chunks get receipts matching their trims, chunk files it
    /// no longer uses are removed, and its manifest is rewritten. Idempotent.
    func finishSplit(_ split: RecordingSplitRecord) throws {
        guard !split.finished else { return }
        let recordings = try recordingsDirectory(split.meetingID)
        let staging = Self.stagingName(split.part), part = split.part.uuidString
        if recordings.exists(staging) {
            if recordings.exists(part) { try recordings.removeTree(staging) }
            else {
                guard renameatx_np(recordings.fd, staging, recordings.fd, part, UInt32(RENAME_EXCL)) == 0 else {
                    throw LibraryError.io(operation: "finish the split recording folder", code: errno)
                }
                try recordings.syncAudioDirectory()
            }
        }
        // The original, where it is now (it may have been moved since).
        if let original: Recording = try record(.recording, id: split.source), recordings.exists(part) {
            let folder = try DirectoryHandle.openAbsolute(library.directory).directory("Meetings")
                .directory(original.meetingID.uuidString).directory("Recordings").directory(original.id.uuidString)
            let partFolder = try recordings.directory(part)
            let chunks = Dictionary(uniqueKeysWithValues: original.chunks.map { ($0.id, $0) })
            var receipts: [StoredAudioChunk] = []
            for track in AudioTrack.allCases where folder.exists(track.rawValue) {
                let directory = try folder.directory(track.rawValue)
                for name in try directory.names() where name.hasSuffix(".json") {
                    let receipt = try DomainCodec.decode(StoredAudioChunk.self, from: directory.read(name, maximum: 65_536))
                    let id = receipt.chunk.id
                    if let chunk = chunks[id] {
                        let current = StoredAudioChunk(libraryID: receipt.libraryID, meetingID: original.meetingID, recordingID: original.id,
                            chunk: chunk, encoding: receipt.encoding, byteCount: receipt.byteCount, sha256: receipt.sha256)
                        if current != receipt { try directory.replace(name, data: DomainCodec.encode(current)) }
                        receipts.append(current)
                    } else if partFolder.exists(track.rawValue), try partFolder.directory(track.rawValue).exists("\(id).m4a") {
                        try directory.removeFile("\(id).m4a")
                        try directory.removeFile(name)
                    }
                }
            }
            receipts.sort { ($0.chunk.active.start, $0.chunk.file.value) < ($1.chunk.active.start, $1.chunk.file.value) }
            try folder.replace("manifest.json", data: DomainCodec.encode(RecordingAudioManifest(recording: original, audio: receipts)))
        }
        var done = split; done.finished = true
        try db.execute("UPDATE records SET payload=? WHERE kind='recordingSplit' AND id=?",
                       [.blob(DomainCodec.encode(done)), .text(split.part.uuidString)])
    }

    /// Launch: finishes committed splits and removes staging folders of splits
    /// that never committed.
    func recoverSplits() throws {
        let splits: [RecordingSplitRecord] = try db.rows("SELECT payload FROM records WHERE kind='recordingSplit'").map {
            guard case .blob(let data) = $0[0] else { throw StoreError.invalidResult }
            return try DomainCodec.decode(RecordingSplitRecord.self, from: data)
        }
        for split in splits where !split.finished { try? finishSplit(split) }
        let known = Set(splits.map(\.part))
        let owned = try DirectoryHandle.openAbsolute(library.directory)
        guard owned.exists("Meetings") else { return }
        let meetings = try owned.directory("Meetings")
        for meeting in try meetings.names() where UUID(uuidString: meeting) != nil {
            guard let folder = try? meetings.directory(meeting), folder.exists("Recordings"),
                  let recordings = try? folder.directory("Recordings") else { continue }
            for name in try recordings.names() where name.hasPrefix(".split-") {
                guard let id = UUID(uuidString: String(name.dropFirst(7))), !known.contains(id) else { continue }
                try? recordings.removeTree(name)
            }
        }
    }

    // MARK: Saved voices (design D4)

    /// The recording and interval that hold `interval` of `recordingID` now,
    /// following splits made since (a later, earlier cut first).
    public func resolveRecordingTime(_ recordingID: UUID, _ interval: MediaInterval) -> (UUID, MediaInterval) {
        let splits: [RecordingSplitRecord] = (try? db.rows("SELECT payload FROM records WHERE kind='recordingSplit'").compactMap {
            guard case .blob(let data) = $0[0] else { return nil }
            return try? DomainCodec.decode(RecordingSplitRecord.self, from: data)
        }) ?? []
        var id = recordingID, current = interval
        for _ in 0..<64 {
            guard let split = splits.filter({ $0.source == id }).sorted(by: { $0.at > $1.at })
                .first(where: { current.start >= $0.at }),
                  let next = try? MediaInterval(start: MediaTime(microseconds: current.start.microseconds - split.at.microseconds),
                                                end: MediaTime(microseconds: current.end.microseconds - split.at.microseconds)) else { break }
            id = split.part; current = next
        }
        return (id, current)
    }
}

extension Recording {
    /// The wall-clock time at `time` of its active timeline, nil outside it.
    public func wallClock(at time: MediaTime) -> Date? {
        guard let capture = captureIntervals.last(where: { $0.active.start <= time }), time <= capture.active.end else { return nil }
        return capture.wallClockStart.addingTimeInterval(Double(time.microseconds - capture.active.start.microseconds) / 1_000_000)
    }

    /// `HH:mm:ss` of `time` in the zone of the recording's day there, for split confirmations.
    public func clockLabel(at time: MediaTime) -> String {
        guard let date = wallClock(at: time) else { return "" }
        let day = captureIntervals.last { $0.active.start <= time }.flatMap { capture in days.first { $0.id == capture.dayID } }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: day?.timeZoneIdentifier ?? timeZoneIdentifier)
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
