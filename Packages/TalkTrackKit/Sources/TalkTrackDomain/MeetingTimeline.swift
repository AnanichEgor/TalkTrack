import Foundation

public enum TimelineError: Error, Equatable, Sendable {
    case inconsistentMetadata(recordingID: UUID)
    case missingChunk(recordingID: UUID, chunkID: UUID)
    case unknownRecording(UUID)
    case unknownChunk(UUID)
    case positionOutOfRange
    case durationOverflow
}

public struct TimelineRecording: Equatable, Sendable {
    public let recordingID: UUID
    public let global: MediaInterval
}

public struct CapturedTimelineTime: Equatable, Sendable {
    public let wallClock: Date
    public let day: RecordingDay
    public let hostTimeStart: UInt64
    public let intervalOffset: MediaTime
}

public struct TimelineAudioPosition: Equatable, Sendable {
    public let chunkID: UUID
    public let file: RelativePath
    public let decodedFrame: UInt64
    public let remainingFrames: UInt64
    public let sampleRate: UInt32
    public let activeInterval: MediaInterval
}

public enum TimelineTrackPosition: Equatable, Sendable {
    case audio(TimelineAudioPosition)
    case gap(active: MediaInterval, reason: String)
}

public struct TimelinePlaybackPosition: Equatable, Sendable {
    public let recordingID: UUID
    public let globalTime: MediaTime
    public let activeTime: MediaTime
    /// Nil for legacy audio with no captured wall-clock metadata. Never guess
    /// a timestamp from startedAt when pauses may have occurred.
    public let capturedTime: CapturedTimelineTime?
    public let system: TimelineTrackPosition
    public let microphone: TimelineTrackPosition
}

public enum TimelinePosition: Equatable, Sendable {
    case empty
    case end
    case recording(TimelinePlaybackPosition)
}

/// Pure, immutable prefix-sum index. No filesystem access or concatenation.
/// Half-open intervals select the next recording/chunk at exact boundaries.
/// Unavailable source ranges keep their positions on the timeline.
public struct MeetingTimeline: Sendable {
    private struct IndexedRecording: Sendable {
        let recording: Recording
        let global: MediaInterval
        let captures: [CaptureInterval]
        let tracks: [AudioTrack: [TrackInterval]]
        let chunks: [UUID: TrackChunk]
        let days: [UUID: RecordingDay]
    }
    public let meetingID: UUID
    public let totalDuration: MediaTime
    public let recordings: [TimelineRecording]
    private let index: [IndexedRecording]
    private let byID: [UUID: Int]

    public init(meetingID: UUID, recordings: [Recording]) throws {
        self.meetingID = meetingID
        var indexed: [IndexedRecording] = [], offsets: [TimelineRecording] = [], ids: [UUID: Int] = [:]
        var total: Int64 = 0
        for recording in recordings.sorted(by: {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }) {
            guard recording.meetingID == meetingID, ids[recording.id] == nil,
                  recording.startedAt.timeIntervalSince1970.isFinite,
                  Set(recording.days.map(\.id)).count == recording.days.count,
                  Set(recording.chunks.map(\.id)).count == recording.chunks.count else {
                throw TimelineError.inconsistentMetadata(recordingID: recording.id)
            }
            let end = total.addingReportingOverflow(recording.activeDuration.microseconds)
            guard !end.overflow else { throw TimelineError.durationOverflow }
            let range = try MediaInterval(start: MediaTime(microseconds: total), end: MediaTime(microseconds: end.partialValue))
            let days = Dictionary(uniqueKeysWithValues: recording.days.map { ($0.id, $0) })
            let chunks = Dictionary(uniqueKeysWithValues: recording.chunks.map { ($0.id, $0) })
            for chunk in recording.chunks {
                guard chunk.active.end <= recording.activeDuration,
                      abs(chunk.active.duration.microseconds - (try Self.frameTime(chunk.decodedFrameCount - chunk.leadingTrimFrames - chunk.trailingTrimFrames,
                                                                  rate: chunk.sampleRate)).microseconds) <= 1 else {
                    throw TimelineError.inconsistentMetadata(recordingID: recording.id)
                }
            }
            let captures = recording.captureIntervals.sorted { $0.active.start < $1.active.start }
            var last = MediaTime.zero
            for capture in captures {
                guard capture.active.start == last, capture.active.end > last,
                      capture.active.end <= recording.activeDuration, days[capture.dayID] != nil,
                      capture.wallClockStart.timeIntervalSince1970.isFinite else {
                    throw TimelineError.inconsistentMetadata(recordingID: recording.id)
                }
                last = capture.active.end
            }
            if !captures.isEmpty, last != recording.activeDuration {
                throw TimelineError.inconsistentMetadata(recordingID: recording.id)
            }
            var tracks: [AudioTrack: [TrackInterval]] = [:]
            for track in AudioTrack.allCases {
                var intervals = recording.trackIntervals.filter { $0.track == track }
                if intervals.isEmpty {
                    intervals = recording.chunks.filter { $0.track == track }.map {
                        TrackInterval(track: track, active: $0.active,
                            content: .chunk(id: $0.id, firstDecodedFrame: $0.leadingTrimFrames,
                                frameCount: $0.decodedFrameCount - $0.leadingTrimFrames - $0.trailingTrimFrames))
                    }
                }
                intervals.sort { $0.active.start < $1.active.start }
                var covered: [TrackInterval] = [], cursor = MediaTime.zero
                for interval in intervals {
                    guard interval.active.start >= cursor, interval.active.end > interval.active.start,
                          interval.active.end <= recording.activeDuration else {
                        throw TimelineError.inconsistentMetadata(recordingID: recording.id)
                    }
                    if case let .chunk(id, first, count) = interval.content {
                        guard let chunk = chunks[id] else { throw TimelineError.missingChunk(recordingID: recording.id, chunkID: id) }
                        let validEnd = chunk.decodedFrameCount - chunk.trailingTrimFrames
                        guard chunk.track == track, first >= chunk.leadingTrimFrames, first <= validEnd,
                              count > 0, count <= validEnd - first,
                              interval.active.start >= chunk.active.start, interval.active.end <= chunk.active.end,
                              abs(interval.active.duration.microseconds - (try Self.frameTime(count, rate: chunk.sampleRate)).microseconds) <= 1,
                              abs(interval.active.start.microseconds - chunk.active.start.microseconds
                                  - (try Self.frameTime(first - chunk.leadingTrimFrames, rate: chunk.sampleRate)).microseconds) <= 1 else {
                            throw TimelineError.inconsistentMetadata(recordingID: recording.id)
                        }
                    }
                    if cursor < interval.active.start {
                        covered.append(TrackInterval(track: track, active: try MediaInterval(start: cursor, end: interval.active.start),
                            content: .gap(reason: "No captured audio for this source")))
                    }
                    covered.append(interval)
                    cursor = interval.active.end
                }
                if cursor < recording.activeDuration {
                    covered.append(TrackInterval(track: track, active: try MediaInterval(start: cursor, end: recording.activeDuration),
                        content: .gap(reason: "No captured audio for this source")))
                }
                tracks[track] = covered
            }
            ids[recording.id] = indexed.count
            indexed.append(IndexedRecording(recording: recording, global: range, captures: captures,
                                            tracks: tracks, chunks: chunks, days: days))
            offsets.append(TimelineRecording(recordingID: recording.id, global: range))
            total = end.partialValue
        }
        index = indexed; byID = ids; self.recordings = offsets
        totalDuration = try MediaTime(microseconds: total)
    }

    public func position(at time: MediaTime) throws -> TimelinePosition {
        guard time <= totalDuration else { throw TimelineError.positionOutOfRange }
        if totalDuration == .zero { return .empty }
        if time == totalDuration { return .end }
        let i = Self.firstEnding(after: time, in: index, end: { $0.global.end })
        let entry = index[i]
        let local = try MediaTime(microseconds: time.microseconds - entry.global.start.microseconds)
        let captureIndex = Self.firstEnding(after: local, in: entry.captures, end: { $0.active.end })
        var captured: CapturedTimelineTime?
        if captureIndex < entry.captures.count {
            let interval = entry.captures[captureIndex]
            let offset = try MediaTime(microseconds: local.microseconds - interval.active.start.microseconds)
            captured = CapturedTimelineTime(wallClock: interval.wallClockStart.addingTimeInterval(offset.seconds),
                day: entry.days[interval.dayID]!, hostTimeStart: interval.hostTimeStart, intervalOffset: offset)
        }
        return .recording(TimelinePlaybackPosition(recordingID: entry.recording.id, globalTime: time, activeTime: local,
            capturedTime: captured, system: try trackPosition(.system, at: local, in: entry),
            microphone: try trackPosition(.microphone, at: local, in: entry)))
    }

    /// A local end is allowed: its global position naturally resolves to the
    /// next recording (or .end). Zero-duration recordings never consume time.
    public func globalTime(recordingID: UUID, activeTime: MediaTime) throws -> MediaTime {
        let entry = try recording(recordingID)
        guard activeTime <= entry.recording.activeDuration else { throw TimelineError.positionOutOfRange }
        return try MediaTime(microseconds: entry.global.start.microseconds + activeTime.microseconds)
    }

    /// Validated source coverage, including implicit missing-source gaps. File
    /// readers and playback share the same positions rather than rebuilding a
    /// shorter timeline from whichever files happen to be available.
    public func trackIntervals(recordingID: UUID, track: AudioTrack) throws -> [TrackInterval] {
        try recording(recordingID).tracks[track] ?? []
    }

    /// Raw decoded-frame coordinates include any persisted leading trim. An
    /// excluded priming/padding frame is not a seekable source position.
    public func globalTime(recordingID: UUID, track: AudioTrack, chunkID: UUID, decodedFrame: UInt64) throws -> MediaTime {
        let entry = try recording(recordingID)
        guard entry.chunks[chunkID] != nil else { throw TimelineError.unknownChunk(chunkID) }
        for interval in entry.tracks[track] ?? [] {
            if case let .chunk(id, first, count) = interval.content, id == chunkID,
               decodedFrame >= first, decodedFrame - first < count {
                let offset = try Self.frameTime(decodedFrame - first, rate: entry.chunks[id]!.sampleRate)
                let local = min(interval.active.end, try MediaTime(microseconds: interval.active.start.microseconds + offset.microseconds))
                return try globalTime(recordingID: recordingID, activeTime: local)
            }
        }
        throw TimelineError.positionOutOfRange
    }

    /// Clock adjustments can make wall time ambiguous. Return every captured
    /// match; a wall time during a pause has none, instead of seeking into silence.
    public func globalTimes(recordingID: UUID, wallClock: Date) throws -> [MediaTime] {
        guard wallClock.timeIntervalSince1970.isFinite else { throw TimelineError.positionOutOfRange }
        let entry = try recording(recordingID)
        return try entry.captures.compactMap { interval in
            let seconds = wallClock.timeIntervalSince(interval.wallClockStart)
            guard seconds >= 0, seconds < interval.active.duration.seconds else { return nil }
            let offset = try MediaTime(seconds: seconds)
            guard offset < interval.active.duration else { return nil }
            return try globalTime(recordingID: recordingID,
                activeTime: MediaTime(microseconds: interval.active.start.microseconds + offset.microseconds))
        }
    }

    private func recording(_ id: UUID) throws -> IndexedRecording {
        guard let i = byID[id] else { throw TimelineError.unknownRecording(id) }
        return index[i]
    }

    private func trackPosition(_ track: AudioTrack, at time: MediaTime, in entry: IndexedRecording) throws -> TimelineTrackPosition {
        let intervals = entry.tracks[track]!
        let interval = intervals[Self.firstEnding(after: time, in: intervals, end: { $0.active.end })]
        switch interval.content {
        case let .gap(reason): return .gap(active: interval.active, reason: reason)
        case let .chunk(id, first, count):
            let chunk = entry.chunks[id]!
            let delta = UInt64(time.microseconds - interval.active.start.microseconds)
            // Round to the nearest frame: MediaTime stores rounded integer
            // microseconds, so floor alone sends frame-derived seeks backwards.
            let product = delta.multipliedFullWidth(by: UInt64(chunk.sampleRate))
            guard product.high < 1_000_000 else { throw TimelineError.durationOverflow }
            let division = UInt64(1_000_000).dividingFullWidth(product)
            let rounded = division.quotient.addingReportingOverflow(division.remainder >= 500_000 ? 1 : 0)
            guard !rounded.overflow else { throw TimelineError.durationOverflow }
            let offset = min(count - 1, rounded.partialValue)
            return .audio(TimelineAudioPosition(chunkID: id, file: chunk.file, decodedFrame: first + offset,
                remainingFrames: count - offset, sampleRate: chunk.sampleRate, activeInterval: interval.active))
        }
    }

    private static func firstEnding<T>(after time: MediaTime, in items: [T], end: (T) -> MediaTime) -> Int {
        var low = 0, high = items.count
        while low < high {
            let mid = low + (high - low) / 2
            if end(items[mid]) <= time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func frameTime(_ frames: UInt64, rate: UInt32) throws -> MediaTime {
        let rate = UInt64(rate), seconds = frames / rate, remainder = frames % rate
        guard seconds <= UInt64(Int64.max) / 1_000_000 else { throw TimelineError.durationOverflow }
        let fraction = (remainder * 1_000_000 + rate / 2) / rate
        let microseconds = seconds * 1_000_000 + fraction
        guard microseconds <= UInt64(Int64.max) else { throw TimelineError.durationOverflow }
        return try MediaTime(microseconds: Int64(microseconds))
    }
}
