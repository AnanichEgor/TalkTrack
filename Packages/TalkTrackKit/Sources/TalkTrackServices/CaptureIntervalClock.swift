import AVFoundation
import Foundation
import TalkTrackDomain

public enum CaptureClockError: Error, Equatable, Sendable {
    case alreadyRunning, notRunning, invalidAnchor, timeOverflow
}

/// Checkpoints include the open interval up to the requested host tick. They
/// never include a pause or infer elapsed time from callback delivery latency.
public struct CaptureTimingSnapshot: Equatable, Sendable {
    public let activeFrameCount: UInt64
    public let activeDuration: MediaTime
    public let days: [RecordingDay]
    public let intervals: [CaptureInterval]
}

/// Shared monotonic clock for both tracks. The native coordinator must drain
/// accepted packets before close(), and open a new anchor before Resume.
/// Source sample counters and the computer's later time zone cannot redefine
/// this recording's active time or an already captured calendar day.
public struct CaptureIntervalClock: Sendable {
    private struct Anchor: Sendable {
        let host: UInt64
        let wall: Date
        let zone: String
    }
    private var anchor: Anchor?
    private var lastClosedHost: UInt64?
    private var lastCheckpointHost: UInt64?
    private var frames: UInt64 = 0
    private var duration: MediaTime = .zero
    private var intervals: [CaptureInterval] = []
    private var days: [RecordingDay] = []
    public init() {}

    public mutating func begin(hostTime: UInt64, wallClock: Date, timeZoneIdentifier: String) throws {
        guard anchor == nil else { throw CaptureClockError.alreadyRunning }
        guard wallClock.timeIntervalSince1970.isFinite,
              TimeZone(identifier: timeZoneIdentifier) != nil,
              lastClosedHost.map({ hostTime >= $0 }) ?? true else { throw CaptureClockError.invalidAnchor }
        let candidate = try RecordingDay(capturedAt: wallClock, timeZoneIdentifier: timeZoneIdentifier)
        if !days.contains(where: { $0.localDate == candidate.localDate && $0.timeZoneIdentifier == candidate.timeZoneIdentifier
            && $0.utcOffsetSeconds == candidate.utcOffsetSeconds }) { days.append(candidate) }
        anchor = Anchor(host: hostTime, wall: wallClock, zone: timeZoneIdentifier)
    }

    /// Rounded once to the stored 48 kHz frame grid. Every source uses the same
    /// origin; a delayed first packet therefore retains its actual offset.
    public func activeFrame(at hostTime: UInt64) throws -> UInt64 {
        guard let anchor else { throw CaptureClockError.notRunning }
        guard hostTime >= anchor.host else { throw CaptureClockError.invalidAnchor }
        let elapsed = AVAudioTime.seconds(forHostTime: hostTime - anchor.host)
        let delta = (elapsed * 48_000).rounded()
        guard delta.isFinite, delta >= 0, delta < Double(UInt64.max) else { throw CaptureClockError.timeOverflow }
        let sum = frames.addingReportingOverflow(UInt64(delta))
        guard !sum.overflow else { throw CaptureClockError.timeOverflow }
        _ = try Self.time(sum.partialValue)
        return sum.partialValue
    }

    public mutating func checkpoint(at hostTime: UInt64) throws -> CaptureTimingSnapshot {
        var copy = self
        let result = try copy.close(at: hostTime)
        // Publish stable day IDs without closing or advancing the open origin.
        days = result.days
        lastCheckpointHost = hostTime
        return result
    }

    /// Compute on a copy so a bad anchor cannot partially mutate the clock.
    @discardableResult public mutating func close(at hostTime: UInt64) throws -> CaptureTimingSnapshot {
        var copy = self
        let result = try copy.closeImpl(at: hostTime)
        self = copy
        return result
    }

    public var closedSnapshot: CaptureTimingSnapshot {
        CaptureTimingSnapshot(activeFrameCount: frames, activeDuration: duration,
                              days: days, intervals: intervals)
    }

    private mutating func closeImpl(at hostTime: UInt64) throws -> CaptureTimingSnapshot {
        guard let anchor else { throw CaptureClockError.notRunning }
        guard lastCheckpointHost.map({ hostTime >= $0 }) ?? true else { throw CaptureClockError.invalidAnchor }
        let endFrame = try activeFrame(at: hostTime)
        let duration = Double(endFrame - frames) / 48_000
        let wallEnd = anchor.wall.addingTimeInterval(duration)
        guard wallEnd.timeIntervalSince1970.isFinite,
              let zone = TimeZone(identifier: anchor.zone) else { throw CaptureClockError.invalidAnchor }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var wall = anchor.wall, startFrame = frames
        while startFrame < endFrame {
            let candidate = try RecordingDay(capturedAt: wall, timeZoneIdentifier: anchor.zone)
            let day = days.first { $0.localDate == candidate.localDate && $0.timeZoneIdentifier == candidate.timeZoneIdentifier
                && $0.utcOffsetSeconds == candidate.utcOffsetSeconds } ?? candidate
            if !days.contains(where: { $0.id == day.id }) { days.append(day) }
            guard let dayEnd = calendar.dateInterval(of: .day, for: wall)?.end, dayEnd > wall else {
                throw CaptureClockError.invalidAnchor
            }
            // A DST transition also needs a new frozen UTC offset, even when
            // it occurs within the same local calendar day.
            var boundary = min(dayEnd, wallEnd)
            if let transition = zone.nextDaylightSavingTimeTransition(after: wall), transition > wall {
                boundary = min(boundary, transition)
            }
            let relative = ((boundary.timeIntervalSince(anchor.wall)) * 48_000).rounded()
            guard relative.isFinite, relative >= 0, relative < Double(UInt64.max) else { throw CaptureClockError.timeOverflow }
            let sum = frames.addingReportingOverflow(UInt64(relative))
            guard !sum.overflow else { throw CaptureClockError.timeOverflow }
            let boundaryFrame = min(endFrame, sum.partialValue)
            guard boundaryFrame > startFrame else { throw CaptureClockError.invalidAnchor }
            let hostDelta = AVAudioTime.hostTime(forSeconds: Double(startFrame - frames) / 48_000)
            let host = anchor.host.addingReportingOverflow(hostDelta)
            guard !host.overflow else { throw CaptureClockError.timeOverflow }
            intervals.append(CaptureInterval(active: try MediaInterval(start: Self.time(startFrame), end: Self.time(boundaryFrame)),
                wallClockStart: wall, hostTimeStart: host.partialValue, dayID: day.id))
            startFrame = boundaryFrame
            wall = boundary
        }
        frames = endFrame
        self.duration = try Self.time(frames)
        lastClosedHost = hostTime
        lastCheckpointHost = nil
        self.anchor = nil
        return closedSnapshot
    }

    private static func time(_ frames: UInt64) throws -> MediaTime {
        let seconds = frames / 48_000, rest = frames % 48_000
        let fraction = (rest * 1_000_000 + 24_000) / 48_000
        guard seconds <= UInt64(Int64.max) / 1_000_000 else { throw CaptureClockError.timeOverflow }
        let value = seconds * 1_000_000 + fraction
        guard value <= UInt64(Int64.max) else { throw CaptureClockError.timeOverflow }
        return try MediaTime(microseconds: Int64(value))
    }
}
