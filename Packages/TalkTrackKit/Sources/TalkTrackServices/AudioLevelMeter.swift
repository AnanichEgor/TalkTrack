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
        /// The system track has delivered only exact zeros for a long stretch while
        /// the microphone heard speech: access may have been revoked (design D6).
        public var systemSilentWhileSpeaking = false
    }

    private struct State {
        var level: [CaptureSource: Float] = [:]
        var updated: [CaptureSource: Date] = [:]
        var seconds: [CaptureSource: Double] = [:]
        /// Seconds of exact-zero system audio since its last non-zero sample.
        var systemZeroRun: Double = 0
        /// Microphone speech seconds within that run.
        var speechDuringZeroRun: Double = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let now: @Sendable () -> Date
    private let silentHintAfter: Double
    /// Microphone packets at or above this normalized level (−45 dBFS) count as speech.
    static let speechLevel: Float = 0.25
    /// Speech needed within the silent stretch before the hint appears.
    static let speechNeeded: Double = 10

    public init(now: @escaping @Sendable () -> Date = Date.init, silentHintAfter: Double = 600) {
        self.now = now; self.silentHintAfter = silentHintAfter
    }

    /// A new recording starts from zero; a resumed one keeps counting.
    public func reset() { state.withLock { $0 = State() } }

    public func record(_ packet: AudioPacket) {
        guard !packet.samples.isEmpty, packet.sampleRate > 0 else { return }
        var rms: Float = 0, peak: Float = 0
        packet.samples.withUnsafeBufferPointer {
            vDSP_rmsqv($0.baseAddress!, 1, &rms, vDSP_Length($0.count))
            vDSP_maxmgv($0.baseAddress!, 1, &peak, vDSP_Length($0.count))
        }
        let silent = peak == 0, value = Self.normalized(rms), time = now()
        let duration = Double(packet.samples.count) / packet.sampleRate
        state.withLock {
            switch packet.source {
            case .system:
                if silent { $0.systemZeroRun += duration } else { $0.systemZeroRun = 0; $0.speechDuringZeroRun = 0 }
            case .microphone:
                if value >= Self.speechLevel { $0.speechDuringZeroRun += duration }
            }
            let old = $0.level[packet.source] ?? 0
            // Fast attack, slow release, so speech reads as a steady pulse.
            $0.level[packet.source] = value >= old ? value : old * 0.85 + value * 0.15
            $0.updated[packet.source] = time
            $0.seconds[packet.source, default: 0] += duration
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
                           seconds: state.seconds.values.max() ?? 0,
                           systemSilentWhileSpeaking: state.systemZeroRun >= silentHintAfter
                               && state.speechDuringZeroRun >= Self.speechNeeded)
        }
    }

    static func normalized(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 60) / 60))
    }
}
