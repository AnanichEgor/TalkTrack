import Accelerate
import Foundation
import os
import TalkTrackAudio

/// Input levels and captured duration of the active recording, for display only.
/// Capture callbacks write it without waiting; the interface polls `read()`.
public final class AudioLevelMeter: Sendable {
    public struct Reading: Equatable, Sendable {
        /// 0 (−60 dBFS or silence) to 1 (full scale), per source.
        public var microphone: Float = 0
        public var system: Float = 0
        /// Audio captured by this recording, excluding pauses.
        public var seconds: Double = 0
    }

    private struct State {
        var level: [CaptureSource: Float] = [:]
        var updated: [CaptureSource: Date] = [:]
        var seconds: [CaptureSource: Double] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    /// A new recording starts from zero; a resumed one keeps counting.
    public func reset() { state.withLock { $0 = State() } }

    public func record(_ packet: AudioPacket) {
        guard !packet.samples.isEmpty, packet.sampleRate > 0 else { return }
        var rms: Float = 0
        packet.samples.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &rms, vDSP_Length($0.count)) }
        let value = Self.normalized(rms), time = now()
        state.withLock {
            let old = $0.level[packet.source] ?? 0
            // Fast attack, slow release, so speech reads as a steady pulse.
            $0.level[packet.source] = value >= old ? value : old * 0.85 + value * 0.15
            $0.updated[packet.source] = time
            $0.seconds[packet.source, default: 0] += Double(packet.samples.count) / packet.sampleRate
        }
    }

    public func read() -> Reading {
        let time = now()
        return state.withLock { state in
            // A source that stopped delivering (pause, failure) reads as silent.
            func level(_ source: CaptureSource) -> Float {
                guard let updated = state.updated[source], time.timeIntervalSince(updated) < 0.5 else { return 0 }
                return state.level[source] ?? 0
            }
            return Reading(microphone: level(.microphone), system: level(.system),
                           seconds: state.seconds.values.max() ?? 0)
        }
    }

    static func normalized(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 60) / 60))
    }
}
