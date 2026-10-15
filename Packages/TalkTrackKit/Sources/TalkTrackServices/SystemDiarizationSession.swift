import Dispatch
import Foundation
import TalkTrackDomain

public struct DiarizedSystemSegment: Codable, Equatable, Sendable {
    public let recordingID: UUID
    public let dayID: UUID
    public let speakerID: UUID
    public let number: UInt
    public let active: MediaInterval
    public let wallClockStart: Date
}
public struct SystemDiarizationResult: Sendable {
    public let recordingID: UUID
    public let processed: MediaInterval
    public let segments: [DiarizedSystemSegment]
}
public enum SystemDiarizationEvent: Sendable {
    case speech(SystemDiarizationResult)
    case gap(RecordingAudioGap)
}

private final class DiarizationExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "local.talktrack.diarization", qos: .userInitiated)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

/// One instance per meeting processing job, reused for its recordings in
/// capture order. Only clean system speech can contribute voice evidence.
public actor SystemDiarizationSession {
    private nonisolated let executor = DiarizationExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let inference: any SystemSpeakerInference
    private let meetingID: UUID
    private let segmentation: ModelSnapshot
    private let embedding: ModelSnapshot
    private var clustering: SystemSpeakerClustering
    private var busy = false

    public init(meetingID: UUID, segmentation: ModelSnapshot, embedding: ModelSnapshot,
                inference: any SystemSpeakerInference, policy: SpeakerClusteringPolicy = .standard, checkpoint: Data? = nil) throws {
        self.meetingID = meetingID; self.inference = inference; self.segmentation = segmentation; self.embedding = embedding
        if let checkpoint {
            clustering = try SystemSpeakerClustering(restoring: checkpoint, meetingID: meetingID,
                segmentation: segmentation, embedding: embedding, policy: policy)
        } else { clustering = try SystemSpeakerClustering(meetingID: meetingID, segmentation: segmentation, embedding: embedding, policy: policy) }
    }
    public var speakers: [DaySpeaker] { clustering.speakers }
    public var retainedVectorCount: Int { clustering.retainedVectorCount }
    public func checkpoint() throws -> Data {
        guard !busy else { throw SpeakerClusteringError.busy }
        return try clustering.checkpoint()
    }

    public func process(_ window: RecordingAudioWindow) async throws -> SystemDiarizationResult {
        guard !busy else { throw SpeakerClusteringError.busy }
        guard window.meetingID == meetingID, window.track == .system, (1600...160_000).contains(window.samples.count),
              (1...window.samples.count).contains(window.validSampleFrames), window.active.duration > .zero,
              window.active.duration.seconds <= 10.000001,
              window.samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw SpeakerClusteringError.invalidInput }
        try Task.checkCancellation()
        busy = true
        defer { busy = false }
        let raw = try await inference.speakerActivity(segmentation, samples: window.samples)
        try Task.checkCancellation()
        guard raw.count <= 1800 else { throw SpeakerClusteringError.invalidInput }
        var activity: [Int: [MediaInterval]] = [:]
        let inputEnd = try MediaTime(seconds: Double(window.samples.count) / 16_000)
        let sourceEnd = min(window.active.duration, try MediaTime(seconds: Double(window.validSampleFrames) / 16_000))
        for item in raw {
            guard (1...3).contains(item.slot), item.relative.duration > .zero,
                  item.relative.end <= inputEnd else { throw SpeakerClusteringError.invalidInput }
            let end = min(item.relative.end, sourceEnd)
            if item.relative.start < end {
                let relative = try MediaInterval(start: item.relative.start, end: end)
                activity[item.slot, default: []].append(try window.project(relative: relative).active)
            }
        }
        for slot in activity.keys {
            let ordered = activity[slot]!.sorted { $0.start < $1.start }
            var previous = window.active.start
            for range in ordered {
                guard range.start >= previous else { throw SpeakerClusteringError.invalidInput }
                previous = range.end
            }
            activity[slot] = ordered
        }
        var observations: [SpeakerClusteringObservation] = []
        for slot in activity.keys.sorted() {
            try Task.checkCancellation()
            let ranges = activity[slot]!
            let otherSpeech = activity.filter { $0.key != slot }.flatMap(\.value)
            let clean = SpeakerIntervals.intersection(SpeakerIntervals.subtract(ranges, removing: otherSpeech), [window.owned])
            // Guard transitions and window edges. Never pad, concatenate mixed
            // speech, or embed simultaneous activity to manufacture evidence.
            let longest = clean.max { $0.duration < $1.duration }
            var vector: SpeakerWindowEmbedding?, evidence: [MediaInterval] = []
            if let longest, longest.duration.microseconds >= 1_100_000 {
                let start = longest.start.microseconds - window.active.start.microseconds + 50_000
                let end = longest.end.microseconds - window.active.start.microseconds - 50_000
                let first = Int((start * 16_000 + 999_999) / 1_000_000)
                let last = min(window.validSampleFrames, Int(end * 16_000 / 1_000_000))
                if last - first >= 16_000 {
                    let relative = try MediaInterval(start: MediaTime(seconds: Double(first) / 16_000), end: MediaTime(seconds: Double(last) / 16_000))
                    evidence = [try window.project(relative: relative).active]
                    vector = try await inference.speakerEmbedding(embedding, samples: Array(window.samples[first..<last]))
                    try Task.checkCancellation()
                }
            }
            observations.append(SpeakerClusteringObservation(slot: slot, activity: ranges, cleanSpeech: evidence, embedding: vector))
        }
        // Stage clustering and projection together. An inference, validation or
        // cancellation failure never advances identities or the checkpoint.
        var candidate = clustering
        let assigned = try candidate.process(recordingID: window.recordingID, day: window.day,
            context: window.active, owned: window.owned, observations: observations)
        let segments = assigned.map { segment in
            DiarizedSystemSegment(recordingID: window.recordingID, dayID: window.day.id, speakerID: segment.speakerID,
                number: segment.number, active: segment.active,
                wallClockStart: window.wallClockStart.addingTimeInterval(segment.active.start.seconds - window.active.start.seconds))
        }
        try Task.checkCancellation()
        clustering = candidate
        return SystemDiarizationResult(recordingID: window.recordingID, processed: window.owned, segments: segments)
    }

    public func process(_ gap: RecordingAudioGap) throws {
        guard !busy else { throw SpeakerClusteringError.busy }
        guard gap.meetingID == meetingID, gap.track == .system else { throw SpeakerClusteringError.invalidInput }
        try clustering.gap(recordingID: gap.recordingID, day: gap.day, active: gap.active)
    }
}

/// Pull-based stream with one retained pending window. Failed/cancelled model
/// work can retry that window even though the disk reader has completed its read.
public actor RecordingDiarizationStream {
    private let reader: RecordingAudioWindowReader
    private let session: SystemDiarizationSession
    private var pending: AudioWindowReadEvent?
    private var busy = false, closed = false
    private var completedProgress = 0.0
    public init(reader: RecordingAudioWindowReader, session: SystemDiarizationSession) { self.reader = reader; self.session = session }
    public var progress: Double { completedProgress }
    public func next() async throws -> SystemDiarizationEvent? {
        guard !busy else { throw SpeakerClusteringError.busy }
        try Task.checkCancellation()
        guard !closed else { return nil }
        busy = true
        defer { busy = false }
        if pending == nil { pending = try await reader.next() }
        guard let pending else { completedProgress = 1; return nil }
        let result: SystemDiarizationEvent
        switch pending {
        case .audio(let window): result = .speech(try await session.process(window))
        case .gap(let gap): try await session.process(gap); result = .gap(gap)
        }
        // A cancellation after the session's commit still publishes that exact
        // result; the next call observes cancellation without processing twice.
        self.pending = nil
        completedProgress = await reader.progress
        return result
    }
    public func close() async throws {
        guard !busy else { throw SpeakerClusteringError.busy }
        closed = true; pending = nil
        await reader.close()
    }
}
