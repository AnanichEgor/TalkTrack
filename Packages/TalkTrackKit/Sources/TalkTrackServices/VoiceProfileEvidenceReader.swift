import Dispatch
import Foundation
import TalkTrackDomain

private final class VoiceEvidenceExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "local.talktrack.voice-evidence", qos: .userInitiated)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

struct EvidenceClip: Sendable {
    let recording: Recording; let revision: TranscriptRevision; let day: UUID; let interval: MediaInterval; let pcm: [Float]; let stretch: Int
}

/// Selection constants (background-voice-learning 2.4). Validation compares
/// them with a full read; the app always uses `standard`.
@_spi(Validation) public struct VoiceLearningTuning: Sendable {
    /// Best candidates per stretch segmented first; `Int.max` reads everything first.
    public var firstPassCandidates: Int
    public var outlierMargin: Double
    public var noveltyFloor: Double
    public static let standard = VoiceLearningTuning(firstPassCandidates: VoiceProfileEvidenceReader.firstPassCandidates,
        outlierMargin: VoiceProfileEvidenceReader.outlierMargin, noveltyFloor: VoiceProfileEvidenceReader.noveltyFloor)
    public init(firstPassCandidates: Int, outlierMargin: Double, noveltyFloor: Double) {
        self.firstPassCandidates = firstPassCandidates; self.outlierMargin = outlierMargin; self.noveltyFloor = noveltyFloor
    }
}

struct VoiceProfileEvidence: Equatable, Sendable {
    let segmentation: ModelSnapshot
    let embedding: ModelSnapshot
    let samples: [VoiceProfileSample]
}

/// Enrollment and recognition use exactly the same bounded, exclusive source
/// speech and signal gates. Only their callers decide whether a name may change.
actor VoiceProfileEvidenceReader {
    private nonisolated let executor = VoiceEvidenceExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let inference: any SystemSpeakerInference
    init(inference: any SystemSpeakerInference) { self.inference = inference }

    /// `selection`: per recording, only this speech counts as the speaker's
    /// (named fragments); otherwise every segment of `speakerID` does.
    func read(library: OpenedLibrary, speakerID: UUID, recordings: [Recording],
              revisions: [TranscriptRevision], selection: [UUID: [MediaInterval]]? = nil,
              correction: Bool = false, bank: [VoiceProfileSample]? = nil,
              filterOutliers: Bool = false, tuning: VoiceLearningTuning = .standard) async throws -> VoiceProfileEvidence {
        guard !recordings.isEmpty, recordings.count == revisions.count,
              Set(recordings.map(\.id)).count == recordings.count,
              recordings.allSatisfy({ recording in revisions.contains { $0.recordingID == recording.id &&
                  $0.sourceGeneration == recording.generation && $0.kind == .final } }) else {
            throw VoiceEnrollmentError.changed
        }
        // Different final model/preprocessing snapshots must never be pooled.
        let models = try revisions.map { revision -> (ModelSnapshot, ModelSnapshot) in
            let segmenters = revision.modelRevisions.filter { $0.role == .segmentation }
            let embedders = revision.modelRevisions.filter { $0.role == .embedding }
            guard segmenters.count == 1, embedders.count == 1 else { throw VoiceEnrollmentError.incompatibleModels }
            return (segmenters[0], embedders[0])
        }
        guard let (segmentation, embedding) = models.first,
              models.allSatisfy({ $0.0 == segmentation && $0.1 == embedding }) else { throw VoiceEnrollmentError.incompatibleModels }
        func selected(_ revision: TranscriptRevision) throws -> (mine: [MediaInterval], other: [MediaInterval]) {
            let system = revision.segments.filter { $0.track == .system }
            if let chosen = selection?[revision.recordingID] {
                let mine = try Self.union(chosen)
                return (mine, SpeakerIntervals.subtract(system.map(\.interval), removing: mine))
            }
            return (system.filter { $0.speaker == .system(daySpeakerID: speakerID) }.map(\.interval),
                    system.filter { $0.speaker != .system(daySpeakerID: speakerID) }.map(\.interval))
        }
        // Samples come from the whole of the speaker's speech, not its start
        // (user request, 2026-10-14): the speech time is divided into equal
        // stretches and each keeps its best clean clips; a quiet or noisy
        // beginning no longer fills the saved voice.
        let stretches = VoiceEnrollmentPolicy.maximumSamples
        var total: Int64 = 0
        for revision in revisions { total += try Self.union(try selected(revision).mine).reduce(0) { $0 + $1.duration.microseconds } }
        guard total > 0 else { throw VoiceEnrollmentError.insufficientSpeech }

        // D3: candidates come free from the transcript. Only the windows of the
        // best two per stretch are segmented first; the rest only when short.
        struct Source { let recording: Recording; let revision: TranscriptRevision; let mine: [MediaInterval]; let other: [MediaInterval]; let before: Int64 }
        var sources: [Source] = [], before: Int64 = 0
        for recording in recordings {
            let revision = revisions.first { $0.recordingID == recording.id }!
            let (mine, other) = try selected(revision)
            let speech = try Self.union(mine)
            sources.append(Source(recording: recording, revision: revision, mine: mine, other: other, before: before))
            before += speech.reduce(0) { $0 + $1.duration.microseconds }
        }
        func stretch(of source: Source, at time: MediaTime) -> Int {
            let speech = (try? Self.union(source.mine)) ?? []
            let position = source.before + speech.reduce(0) { $0 + max(0, min($1.end.microseconds, time.microseconds) - $1.start.microseconds) }
            return min(stretches - 1, Int(position * Int64(stretches) / total))
        }
        var firstPass: [UUID: [MediaInterval]] = [:]
        var ranked: [[(recording: UUID, interval: MediaInterval, score: Double)]] = Array(repeating: [], count: stretches)
        for source in sources {
            for candidate in try Self.candidates(mine: source.mine, other: source.other) {
                ranked[stretch(of: source, at: candidate.start)].append((source.recording.id, candidate, Self.quality(candidate)))
            }
        }
        for list in ranked {
            for item in list.sorted(by: { $0.score > $1.score }).prefix(tuning.firstPassCandidates) {
                firstPass[item.recording, default: []].append(item.interval)
            }
        }

        typealias Clip = EvidenceClip
        var kept: [[Clip]] = Array(repeating: [], count: stretches)
        var analyzed: [UUID: Set<Int64>] = [:]
        var windowsAnalyzed = 0
        let hasCandidates = ranked.map { !$0.isEmpty }
        // Pass 0: the best candidates' windows. Pass 1: every other window of
        // the speech, in time order, until there is enough clean speech.
        for pass in 0..<2 {
            if pass == 1 && Self.enough(kept, hasCandidates: hasCandidates, correction: correction) { break }
            for source in sources {
                if pass == 1 && Self.enough(kept, hasCandidates: hasCandidates, correction: correction) { break }
                let targets = pass == 0 ? (firstPass[source.recording.id] ?? []) : source.mine
                guard !targets.isEmpty else { continue }
                let reader = try await RecordingAudioWindowReader.open(library: library, recording: source.recording, track: .system)
                do {
                    while let event = try await reader.next() {
                        try Task.checkCancellation()
                        guard case .audio(let window) = event else { continue }
                        guard !SpeakerIntervals.intersection(targets, [window.owned]).isEmpty,
                              !(analyzed[source.recording.id]?.contains(window.owned.start.microseconds) ?? false) else { continue }
                        if pass == 1 && Self.enough(kept, hasCandidates: hasCandidates, correction: correction) { break }
                        analyzed[source.recording.id, default: []].insert(window.owned.start.microseconds)
                        windowsAnalyzed += 1
                        let activity = try await inference.speakerActivity(segmentation, samples: window.samples)
                        let intervals = try Self.cleanIntervals(window: window, activity: activity, selected: source.mine, other: source.other)
                        for interval in intervals {
                            try Task.checkCancellation()
                            // Guard transitions, round inward, exclude padding.
                            let start = interval.start.microseconds - window.active.start.microseconds + 50_000
                            let end = interval.end.microseconds - window.active.start.microseconds - 50_000
                            let first = Int((start * 16_000 + 999_999) / 1_000_000)
                            let last = min(window.validSampleFrames, Int(end * 16_000 / 1_000_000))
                            guard last - first >= 16_000 else { continue }
                            let relative = try MediaInterval(start: MediaTime(seconds: Double(first) / 16_000), end: MediaTime(seconds: Double(last) / 16_000))
                            let active = try window.project(relative: relative).active
                            let index = stretch(of: source, at: active.start)
                            // Each stretch keeps its three longest clips.
                            guard kept[index].count < Self.clipsPerStretch || active.duration > kept[index].map(\.interval.duration).min()! else { continue }
                            let pcm = Array(window.samples[first..<last])
                            guard Self.suitablePCM(pcm) else { continue }
                            kept[index].append(Clip(recording: source.recording, revision: source.revision, day: window.day.id,
                                                    interval: active, pcm: pcm, stretch: index))
                            kept[index].sort { $0.interval.duration > $1.interval.duration }
                            if kept[index].count > Self.clipsPerStretch { kept[index].removeLast() }
                        }
                    }
                    await reader.close()
                } catch { await reader.close(); throw error }
            }
        }
        lastWindowsAnalyzed = windowsAnalyzed
        lastClipSeconds = kept.flatMap { $0 }.reduce(0) { $0 + $1.interval.duration.seconds }

        // D4: embed the best clip of each stretch, then spares, at most 16.
        var toEmbed = kept.compactMap(\.first)
        let spare = kept.flatMap { $0.dropFirst() }.sorted { $0.interval.duration > $1.interval.duration }
        toEmbed += spare.prefix(max(0, Self.maximumEmbedded - toEmbed.count))
        var embedded: [(clip: Clip, sample: VoiceProfileSample)] = []
        for clip in toEmbed {
            try Task.checkCancellation()
            let result = try await inference.speakerEmbedding(embedding, samples: clip.pcm)
            guard result.model == embedding, VoiceEnrollmentPolicy.validVector(result.values) else { throw VoiceEnrollmentError.incompatibleModels }
            embedded.append((clip, VoiceProfileSample(recordingID: clip.recording.id, transcriptRevisionID: clip.revision.id, dayID: clip.day,
                interval: clip.interval, vector: result.values)))
        }
        lastEmbedded = embedded.map(\.sample)
        if filterOutliers {
            let keptSamples = Self.withoutOutliers(embedded.map(\.sample), margin: tuning.outlierMargin)
            embedded = embedded.filter { item in keptSamples.contains(item.sample) }
        }
        var samples: [VoiceProfileSample]
        if let bank, !bank.isEmpty {
            samples = Self.selectAgainstBank(embedded.map(\.sample), bank: bank, correction: correction, floor: tuning.noveltyFloor)
        } else {
            // One per stretch (longest), then the longest spares.
            var chosen: [VoiceProfileSample] = [], used = Set<Int>()
            for item in embedded where used.insert(item.clip.stretch).inserted { chosen.append(item.sample) }
            for item in embedded where !chosen.contains(item.sample) && chosen.count < stretches { chosen.append(item.sample) }
            samples = Array(chosen.prefix(stretches))
        }
        samples.sort { a, b in
            let ra = recordings.first { $0.id == a.recordingID }!, rb = recordings.first { $0.id == b.recordingID }!
            return (ra.startedAt, a.interval.start) < (rb.startedAt, b.interval.start)
        }
        // A correction adds to a voice that already has enough speech.
        guard samples.count >= (correction ? 1 : 2), correction ||
              samples.reduce(0, { $0 + $1.interval.duration.microseconds }) >= VoiceEnrollmentPolicy.minimumMicroseconds else {
            throw VoiceEnrollmentError.insufficientSpeech
        }
        return VoiceProfileEvidence(segmentation: segmentation, embedding: embedding, samples: samples)
    }

    static func enough(_ kept: [[EvidenceClip]], hasCandidates: [Bool], correction: Bool) -> Bool {
        let clips = kept.flatMap { $0 }
        return clips.count >= (correction ? 1 : 2) && (correction ||
            clips.reduce(0, { $0 + $1.interval.duration.microseconds }) >= VoiceEnrollmentPolicy.minimumMicroseconds)
            && kept.indices.allSatisfy { !kept[$0].isEmpty || !hasCandidates[$0] }
    }

    /// Windows segmented by the last `read`, for tests and validation.
    private(set) var lastWindowsAnalyzed = 0
    /// Clean clip seconds kept and every embedded clip (before outliers) of the last `read`.
    private(set) var lastClipSeconds = 0.0
    private(set) var lastEmbedded: [VoiceProfileSample] = []

    // MARK: Selection (background-voice-learning D3/D4)

    /// Best candidates per stretch whose windows the first pass segments.
    static let firstPassCandidates = 2
    static let clipsPerStretch = 3
    static let maximumEmbedded = 16
    /// Speech this close to another speaker's segment is not a candidate.
    static let neighbourGuard: Int64 = 500_000
    /// A clip this far below the set's median similarity is someone else (2.4).
    static let outlierMargin = 0.15
    /// A clip this close to the bank adds nothing new (2.4).
    static let noveltyFloor = 0.08

    /// The person's speech minus the surroundings of other speakers, in pieces
    /// long enough for one guarded sample.
    static func candidates(mine: [MediaInterval], other: [MediaInterval]) throws -> [MediaInterval] {
        let padded = try other.map { interval in
            try MediaInterval(start: MediaTime(microseconds: max(0, interval.start.microseconds - neighbourGuard)),
                              end: MediaTime(microseconds: interval.end.microseconds + neighbourGuard))
        }
        // A long monologue becomes several candidates, so its stretches compete
        // on their own and one candidate never covers the whole speech.
        var pieces: [MediaInterval] = []
        for interval in try union(SpeakerIntervals.subtract(try union(mine), removing: padded)) {
            var start = interval.start.microseconds
            while interval.end.microseconds - start >= 1_100_000 {
                let end = min(interval.end.microseconds, start + candidateLength)
                pieces.append(try MediaInterval(start: MediaTime(microseconds: start), end: MediaTime(microseconds: end)))
                start = end
            }
        }
        return pieces
    }
    static let candidateLength: Int64 = 8_000_000

    /// Longer is better up to eight seconds; beyond that the window cuts it anyway.
    static func quality(_ interval: MediaInterval) -> Double { min(interval.duration.seconds, 8) }

    /// Drops clips much less similar to the rest than the set is to itself.
    static func withoutOutliers(_ samples: [VoiceProfileSample], margin: Double = outlierMargin) -> [VoiceProfileSample] {
        guard samples.count >= 3 else { return samples }
        let typical = samples.map { sample in
            median(samples.filter { $0 != sample }.map { VoiceProfileMatcher.cosine(sample.vector, $0.vector) })
        }
        let overall = median(typical)
        return zip(samples, typical).filter { $0.1 >= overall - margin }.map(\.0)
    }

    /// Farthest-point selection with the bank already chosen: each step takes the
    /// clip least like everything kept so far. Stops once nothing new is left and
    /// the confirmation has its minimum (two samples and ten seconds, or one
    /// sample for a correction).
    static func selectAgainstBank(_ candidates: [VoiceProfileSample], bank: [VoiceProfileSample], correction: Bool,
                                  floor: Double = noveltyFloor) -> [VoiceProfileSample] {
        var chosen: [VoiceProfileSample] = [], rest = candidates
        func minimumMet() -> Bool {
            chosen.count >= (correction ? 1 : 2) && (correction ||
                chosen.reduce(0, { $0 + $1.interval.duration.microseconds }) >= VoiceEnrollmentPolicy.minimumMicroseconds)
        }
        while !rest.isEmpty, chosen.count < VoiceEnrollmentPolicy.maximumSamples {
            let reference = bank + chosen
            let novelty = rest.map { sample in 1 - (reference.map { VoiceProfileMatcher.cosine(sample.vector, $0.vector) }.max() ?? -1) }
            var pick = 0
            for index in novelty.indices where novelty[index] > novelty[pick] ||
                (novelty[index] == novelty[pick] && rest[index].interval.duration > rest[pick].interval.duration) { pick = index }
            if novelty[pick] < floor && minimumMet() { break }
            chosen.append(rest.remove(at: pick))
        }
        return chosen
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return -1 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    static func suitablePCM(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { return false }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        let clipped = samples.filter { abs($0) >= 0.999 }.count
        // Basic signal gates, not a calibrated SNR or identity confidence score.
        return power >= 0.00001 && Double(clipped) / Double(samples.count) <= 0.01
    }

    static func cleanIntervals(window: RecordingAudioWindow, activity: [SpeakerWindowActivity],
                               selected: [MediaInterval], other: [MediaInterval]) throws -> [MediaInterval] {
        guard activity.count <= 1800, window.track == .system else { throw SpeakerClusteringError.invalidInput }
        var slots: [Int: [MediaInterval]] = [:]
        let end = try MediaTime(seconds: Double(window.validSampleFrames) / 16_000)
        let paddedEnd = try MediaTime(seconds: Double(window.samples.count) / 16_000)
        for item in activity {
            guard (1...3).contains(item.slot), item.relative.duration > .zero, item.relative.end <= paddedEnd else { throw SpeakerClusteringError.invalidInput }
            guard item.relative.start < min(end, window.active.duration) else { continue }
            let clipped = try MediaInterval(start: item.relative.start, end: min(item.relative.end, end, window.active.duration))
            slots[item.slot, default: []].append(try window.project(relative: clipped).active)
        }
        var clean: [MediaInterval] = []
        for (slot, speech) in slots {
            let competing = slots.filter { $0.key != slot }.flatMap(\.value) + other
            let selectedSpeech = SpeakerIntervals.intersection(SpeakerIntervals.subtract(speech, removing: competing),
                SpeakerIntervals.intersection(selected, [window.owned]))
            clean += try union(selectedSpeech)
        }
        // Keep slot transitions separate, even when adjacent: combining them
        // would bypass transition guards and could embed two different voices.
        return clean.sorted { $0.start < $1.start }
    }

    static func union(_ intervals: [MediaInterval]) throws -> [MediaInterval] {
        // Union duplicates within one slot before counting durations;
        // overlapping transcript segments cannot manufacture extra evidence.
        var result: [MediaInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = try MediaInterval(start: last.start, end: max(last.end, interval.end))
            } else { result.append(interval) }
        }
        return result
    }
}
