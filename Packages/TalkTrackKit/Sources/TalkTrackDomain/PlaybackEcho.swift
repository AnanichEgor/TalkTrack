import Foundation

/// Whether the microphone hears the system audio played through loudspeakers.
/// `unknown` until enough of the other participants has been heard to decide.
public enum PlaybackEchoState: String, Codable, Sendable {
    case unknown, loudspeaker, headset
}

/// A stretch of a recording's active time classified during capture. Only
/// `loudspeaker` and `headset` are stored; time outside every stretch is unknown.
public struct PlaybackEchoStretch: Codable, Equatable, Sendable {
    public let active: MediaInterval
    public let state: PlaybackEchoState
    /// Median correlation peak of the stretch's measurements (0…1).
    public let peak: Float
    /// Median delay of the echo behind the system audio; nil without echo.
    public let lagMilliseconds: Double?

    public init(active: MediaInterval, state: PlaybackEchoState, peak: Float, lagMilliseconds: Double?) {
        self.active = active; self.state = state; self.peak = peak; self.lagMilliseconds = lagMilliseconds
    }
}

extension Array where Element == PlaybackEchoStretch {
    /// The classification at an active time; unknown outside every stretch.
    public func state(at time: MediaTime) -> PlaybackEchoState {
        first { $0.active.start <= time && time < $0.active.end }?.state ?? .unknown
    }

    /// True when the whole interval lies inside `headset` stretches.
    public func isHeadset(_ interval: MediaInterval) -> Bool {
        var cursor = interval.start
        for stretch in sorted(by: { $0.active.start < $1.active.start }) where stretch.state == .headset {
            guard stretch.active.end > cursor else { continue }
            guard stretch.active.start <= cursor else { return false }
            cursor = stretch.active.end
            if cursor >= interval.end { return true }
        }
        return cursor >= interval.end
    }
}
