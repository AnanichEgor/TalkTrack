import Darwin
import Dispatch
import Foundation
import TalkTrackAudio
import TalkTrackDomain

public enum AudioWindowReadError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration
    case missingCaptureTiming(UUID)
    case invalidMetadata(UUID)
    case damagedChunk(recordingID: UUID, chunkID: UUID)
    case invalidRelativeTime
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Audio windows must be bounded to thirty seconds with a smaller overlap."
        case .missingCaptureTiming(let id): "Recording \(id) has no captured timing metadata."
        case .invalidMetadata(let id): "Recording \(id) has inconsistent audio window metadata."
        case let .damagedChunk(recordingID, chunkID): "Recording \(recordingID) has damaged or changed audio chunk \(chunkID)."
        case .invalidRelativeTime: "The processing timestamp is outside the window's source audio."
        }
    }
    public var recoverySuggestion: String? {
        "Keep the original recording files. Restore session folder access or recover the recording, then retry processing."
    }
}

public struct AudioWindowConfiguration: Sendable {
    public let sourceFrames: UInt32
    public let overlapFrames: UInt32
    public let minimumModelFrames: Int
    public static let standard = Self(sourceFrames: 480_000, overlapFrames: 48_000, minimumModelFrames: 1600, unchecked: ())

    public init(sourceFrames: UInt32 = 480_000, overlapFrames: UInt32 = 48_000, minimumModelFrames: Int = 1600) throws {
        guard sourceFrames > 0, sourceFrames <= AudioWindowResampler.maximumSourceFrames,
              overlapFrames < sourceFrames, (0...16_000).contains(minimumModelFrames) else {
            throw AudioWindowReadError.invalidConfiguration
        }
        self.init(sourceFrames: sourceFrames, overlapFrames: overlapFrames, minimumModelFrames: minimumModelFrames, unchecked: ())
    }
    private init(sourceFrames: UInt32, overlapFrames: UInt32, minimumModelFrames: Int, unchecked: Void) {
        self.sourceFrames = sourceFrames; self.overlapFrames = overlapFrames; self.minimumModelFrames = minimumModelFrames
    }
}

public struct AudioWindowProjection: Equatable, Sendable {
    public let recordingID: UUID
    public let track: AudioTrack
    public let dayID: UUID
    public let active: MediaInterval
    public let wallClockStart: Date
    public let wallClockEnd: Date
}

public struct RecordingAudioWindow: Sendable {
    public static let sampleRate: UInt32 = 16_000
    public let meetingID: UUID
    public let recordingID: UUID
    public let track: AudioTrack
    public let day: RecordingDay
    public let sourceFrames: Range<UInt64>
    public let active: MediaInterval
    /// Disjoint publication regions partition all source audio. Context outside
    /// this interval participates in inference, but is not published twice.
    public let owned: MediaInterval
    public let wallClockStart: Date
    public let samples: [Float]
    public let validSampleFrames: Int

    /// Model timestamps are relative to this window, not to its file/chunk.
    /// Permit the fractional final resampled frame but exclude all model padding.
    public func project(relative: MediaInterval) throws -> AudioWindowProjection {
        let validEnd = try MediaTime(seconds: Double(validSampleFrames) / Double(Self.sampleRate))
        guard relative.duration > .zero, relative.start < active.duration, relative.end <= validEnd else {
            throw AudioWindowReadError.invalidRelativeTime
        }
        let end = min(relative.end, active.duration)
        guard end > relative.start else { throw AudioWindowReadError.invalidRelativeTime }
        return AudioWindowProjection(recordingID: recordingID, track: track, dayID: day.id,
            active: try MediaInterval(start: MediaTime(microseconds: active.start.microseconds + relative.start.microseconds),
                                      end: MediaTime(microseconds: active.start.microseconds + end.microseconds)),
            wallClockStart: wallClockStart.addingTimeInterval(relative.start.seconds),
            wallClockEnd: wallClockStart.addingTimeInterval(end.seconds))
    }

    /// Identical aligned utterances in overlapping windows have exactly one
    /// owner. Text/word reconciliation remains the live/final pipeline's job.
    public func owns(_ projection: AudioWindowProjection) -> Bool {
        guard projection.recordingID == recordingID, projection.track == track,
              projection.dayID == day.id, projection.active.duration > .zero else { return false }
        let midpoint = projection.active.start.microseconds + projection.active.duration.microseconds / 2
        return midpoint >= owned.start.microseconds && midpoint < owned.end.microseconds
    }
}

public struct RecordingAudioGap: Equatable, Sendable {
    public let meetingID: UUID
    public let recordingID: UUID
    public let track: AudioTrack
    public let day: RecordingDay
    public let active: MediaInterval
    public let wallClockStart: Date
    public let reason: String
}

public enum AudioWindowReadEvent: Sendable {
    case audio(RecordingAudioWindow)
    case gap(RecordingAudioGap)
}

private final class AudioWindowExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "local.talktrack.audio-window-reader", qos: .userInitiated)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

/// One bounded PCM window per next(), on a dedicated executor. The caller must
/// finish inference/release its window before requesting another. This reads an
/// immutable snapshot of committed AAC chunks; capture's uncommitted PCM is a
/// separate owner. No temporary files or full-recording PCM arrays are created.
public actor RecordingAudioWindowReader {
    private struct Part: Sendable {
        let frames: Range<UInt64>
        let chunk: TrackChunk
        let firstDecodedFrame: UInt64
    }
    private struct Span: Sendable {
        var frames: Range<UInt64>
        let capture: CaptureInterval
        let day: RecordingDay
        var parts: [Part]
        let gapReason: String?
    }
    private nonisolated let executor = AudioWindowExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let library: OpenedLibrary
    private let recording: Recording
    private let track: AudioTrack
    private let configuration: AudioWindowConfiguration
    private var spans: [Span] = []
    private var spanIndex = 0
    private var readStart: UInt64?
    private var ownedStart: UInt64?
    private var completedFrames: UInt64 = 0
    private var totalFrames: UInt64 = 0
    private var closed = false

    private init(library: OpenedLibrary, recording: Recording, track: AudioTrack, configuration: AudioWindowConfiguration) {
        self.library = library; self.recording = recording; self.track = track; self.configuration = configuration
    }

    public static func open(library: OpenedLibrary, recording: Recording, track: AudioTrack,
                            configuration: AudioWindowConfiguration = .standard) async throws -> RecordingAudioWindowReader {
        let reader = RecordingAudioWindowReader(library: library, recording: recording, track: track, configuration: configuration)
        try await reader.prepare()
        return reader
    }

    public var progress: Double { totalFrames == 0 ? 1 : Double(completedFrames) / Double(totalFrames) }
    public func close() { closed = true }

    public func next() throws -> AudioWindowReadEvent? {
        try Task.checkCancellation()
        guard !closed, spanIndex < spans.count else { return nil }
        let span = spans[spanIndex]
        if let reason = span.gapReason {
            let gap = RecordingAudioGap(meetingID: recording.meetingID, recordingID: recording.id, track: track, day: span.day,
                active: try WindowFrames.interval(span.frames), wallClockStart: try wallTime(span.frames.lowerBound, in: span), reason: reason)
            completedFrames = span.frames.upperBound; advanceSpan()
            return .gap(gap)
        }
        let start = readStart ?? span.frames.lowerBound
        let end = start + min(UInt64(configuration.sourceFrames), span.frames.upperBound - start)
        let last = end == span.frames.upperBound
        let nextStart = last ? end : end - UInt64(configuration.overlapFrames)
        let ownershipStart = ownedStart ?? span.frames.lowerBound
        let ownershipEnd = last ? end : nextStart + UInt64(configuration.overlapFrames / 2)
        let source = try read(start..<end, in: span)
        let converted = try AudioWindowResampler.convert48K(source, minimumOutputFrames: configuration.minimumModelFrames)
        let window = RecordingAudioWindow(meetingID: recording.meetingID, recordingID: recording.id, track: track, day: span.day, sourceFrames: start..<end,
            active: try WindowFrames.interval(start..<end), owned: try WindowFrames.interval(ownershipStart..<ownershipEnd),
            wallClockStart: try wallTime(start, in: span), samples: converted.samples, validSampleFrames: converted.validFrameCount)
        // Read, integrity, decode and conversion must all succeed before moving
        // the cursor. Errors and cancellation can retry the same source range.
        try Task.checkCancellation()
        completedFrames = ownershipEnd
        if last { advanceSpan() } else { readStart = nextStart; ownedStart = ownershipEnd }
        return .audio(window)
    }

    private func advanceSpan() { spanIndex += 1; readStart = nil; ownedStart = nil }

    private func prepare() throws {
        try Task.checkCancellation()
        _ = try CommittedAudioChunks(library: library).ownedDirectory()
        let timeline = try MeetingTimeline(meetingID: recording.meetingID, recordings: [recording])
        totalFrames = try WindowFrames.frame(recording.activeDuration)
        guard totalFrames > 0 else { return }
        guard !recording.captureIntervals.isEmpty else { throw AudioWindowReadError.missingCaptureTiming(recording.id) }
        let intervals = try timeline.trackIntervals(recordingID: recording.id, track: track)
        let chunks = Dictionary(uniqueKeysWithValues: recording.chunks.map { ($0.id, $0) })
        var trackIndex = 0
        for capture in recording.captureIntervals.sorted(by: { $0.active.start < $1.active.start }) {
            let day = recording.days.first { $0.id == capture.dayID }!
            let captureStart = try WindowFrames.frame(capture.active.start), captureEnd = try WindowFrames.frame(capture.active.end)
            guard captureEnd > captureStart else { throw AudioWindowReadError.invalidMetadata(recording.id) }
            while trackIndex < intervals.count, intervals[trackIndex].active.end <= capture.active.start { trackIndex += 1 }
            var i = trackIndex
            // Reset merging at every capture anchor, even if active time is
            // contiguous: a resumed wall clock must never be inferred as silence.
            let firstSpan = spans.count
            while i < intervals.count, intervals[i].active.start < capture.active.end {
                try Task.checkCancellation()
                let interval = intervals[i]
                let intervalStart = try WindowFrames.frame(interval.active.start), intervalEnd = try WindowFrames.frame(interval.active.end)
                let start = max(captureStart, intervalStart), end = min(captureEnd, intervalEnd)
                guard end > start else { throw AudioWindowReadError.invalidMetadata(recording.id) }
                switch interval.content {
                case let .gap(reason):
                    spans.append(Span(frames: start..<end, capture: capture, day: day, parts: [], gapReason: reason))
                case let .chunk(id, first, count):
                    let chunk = chunks[id]!
                    guard chunk.sampleRate == 48_000, chunk.decodedFrameCount <= AACChunkEncoder.maximumFrames,
                          count == intervalEnd - intervalStart else { throw AudioWindowReadError.invalidMetadata(recording.id) }
                    let part = Part(frames: start..<end, chunk: chunk, firstDecodedFrame: first + start - intervalStart)
                    if spans.count > firstSpan, spans[spans.count - 1].gapReason == nil, spans[spans.count - 1].frames.upperBound == start {
                        spans[spans.count - 1].parts.append(part)
                        spans[spans.count - 1].frames = spans[spans.count - 1].frames.lowerBound..<end
                    } else { spans.append(Span(frames: start..<end, capture: capture, day: day, parts: [part], gapReason: nil)) }
                }
                i += 1
            }
        }
    }

    private func read(_ range: Range<UInt64>, in span: Span) throws -> [Float] {
        let chunks = CommittedAudioChunks(library: library)
        let owned = try chunks.ownedDirectory()
        var samples: [Float] = []
        samples.reserveCapacity(Int(range.upperBound - range.lowerBound))
        for part in span.parts where part.frames.lowerBound < range.upperBound && range.lowerBound < part.frames.upperBound {
            try Task.checkCancellation()
            let start = max(range.lowerBound, part.frames.lowerBound), end = min(range.upperBound, part.frames.upperBound)
            let first = part.firstDecodedFrame + start - part.frames.lowerBound
            try chunks.decode(part.chunk, of: recording, selected: first..<(first + end - start), owned: owned,
                              checkCancellation: { try Task.checkCancellation() }, into: &samples)
        }
        guard samples.count == Int(range.upperBound - range.lowerBound) else { throw AudioWindowReadError.invalidMetadata(recording.id) }
        return samples
    }

    private func wallTime(_ frame: UInt64, in span: Span) throws -> Date {
        let start = try WindowFrames.frame(span.capture.active.start)
        return span.capture.wallClockStart.addingTimeInterval(Double(frame - start) / 48_000)
    }
}

private enum WindowFrames {
    static func frame(_ time: MediaTime) throws -> UInt64 {
        let value = UInt64(time.microseconds), seconds = value / 1_000_000
        guard seconds <= UInt64.max / 48_000 else { throw AudioWindowReadError.invalidRelativeTime }
        let frame = seconds * 48_000 + ((value % 1_000_000) * 48_000 + 500_000) / 1_000_000
        guard abs((try Self.time(frame)).microseconds - time.microseconds) <= 1 else { throw AudioWindowReadError.invalidRelativeTime }
        return frame
    }
    static func time(_ frame: UInt64) throws -> MediaTime {
        let seconds = frame / 48_000, fraction = ((frame % 48_000) * 1_000_000 + 24_000) / 48_000
        guard seconds <= UInt64(Int64.max) / 1_000_000 else { throw AudioWindowReadError.invalidRelativeTime }
        let value = seconds * 1_000_000 + fraction
        guard value <= UInt64(Int64.max) else { throw AudioWindowReadError.invalidRelativeTime }
        return try MediaTime(microseconds: Int64(value))
    }
    static func interval(_ range: Range<UInt64>) throws -> MediaInterval {
        try MediaInterval(start: time(range.lowerBound), end: time(range.upperBound))
    }
}
