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
              correction: Bool = false) async throws -> VoiceProfileEvidence {
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
        // stretches and each keeps its longest clean clips; a quiet or noisy
        // beginning no longer fills the saved voice.
        let stretches = VoiceEnrollmentPolicy.maximumSamples
        var total: Int64 = 0
        for revision in revisions { total += try Self.union(try selected(revision).mine).reduce(0) { $0 + $1.duration.microseconds } }
        guard total > 0 else { throw VoiceEnrollmentError.insufficientSpeech }
        struct Clip { let recording: Recording; let revision: TranscriptRevision; let day: UUID; let interval: MediaInterval; let pcm: [Float] }
        var kept: [[Clip]] = Array(repeating: [], count: stretches)
        var before: Int64 = 0
        for recording in recordings {
            let revision = revisions.first { $0.recordingID == recording.id }!
            let (mine, other) = try selected(revision)
            let speech = try Self.union(mine)
            func position(_ time: MediaTime) -> Int64 {
                before + speech.reduce(0) { $0 + max(0, min($1.end.microseconds, time.microseconds) - $1.start.microseconds) }
            }
            let reader = try await RecordingAudioWindowReader.open(library: library, recording: recording, track: .system)
            do {
                while let event = try await reader.next() {
                    try Task.checkCancellation()
                    guard case .audio(let window) = event else { continue }
                    guard !SpeakerIntervals.intersection(mine, [window.owned]).isEmpty else { continue }
                    let activity = try await inference.speakerActivity(segmentation, samples: window.samples)
                    let intervals = try Self.cleanIntervals(window: window, activity: activity, selected: mine, other: other)
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
                        let stretch = min(stretches - 1, Int(position(active.start) * Int64(stretches) / total))
                        // Each stretch keeps its two longest clips; the second fills
                        // a stretch without clean speech.
                        guard kept[stretch].count < 2 || active.duration > kept[stretch].map(\.interval.duration).min()! else { continue }
                        let pcm = Array(window.samples[first..<last])
                        guard Self.suitablePCM(pcm) else { continue }
                        kept[stretch].append(Clip(recording: recording, revision: revision, day: window.day.id, interval: active, pcm: pcm))
                        kept[stretch].sort { $0.interval.duration > $1.interval.duration }
                        if kept[stretch].count > 2 { kept[stretch].removeLast() }
                    }
                }
                await reader.close()
            } catch { await reader.close(); throw error }
            before += speech.reduce(0) { $0 + $1.duration.microseconds }
        }
        var chosen = kept.compactMap(\.first)
        let spare = kept.flatMap { $0.dropFirst() }.sorted { $0.interval.duration > $1.interval.duration }
        chosen += spare.prefix(max(0, stretches - chosen.count))
        chosen.sort { ($0.recording.startedAt, $0.interval.start) < ($1.recording.startedAt, $1.interval.start) }
        var samples: [VoiceProfileSample] = []
        for clip in chosen {
            try Task.checkCancellation()
            let result = try await inference.speakerEmbedding(embedding, samples: clip.pcm)
            guard result.model == embedding, VoiceEnrollmentPolicy.validVector(result.values) else { throw VoiceEnrollmentError.incompatibleModels }
            samples.append(VoiceProfileSample(recordingID: clip.recording.id, transcriptRevisionID: clip.revision.id, dayID: clip.day,
                interval: clip.interval, vector: result.values))
        }
        // A correction adds to a voice that already has enough speech.
        guard samples.count >= (correction ? 1 : 2), correction ||
              samples.reduce(0, { $0 + $1.interval.duration.microseconds }) >= VoiceEnrollmentPolicy.minimumMicroseconds else {
            throw VoiceEnrollmentError.insufficientSpeech
        }
        return VoiceProfileEvidence(segmentation: segmentation, embedding: embedding, samples: samples)
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
