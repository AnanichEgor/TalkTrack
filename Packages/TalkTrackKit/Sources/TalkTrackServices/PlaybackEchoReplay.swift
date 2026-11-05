import Foundation
import Synchronization
import TalkTrackDomain

/// Offline replay of loudspeaker detection over a stored recording (task 1.3):
/// the same monitor as capture, fed from verified committed AAC in active-time
/// order, plus a control whose microphone is shifted so it cannot contain echo.
/// Reads only; never writes the recording.
public enum PlaybackEchoReplay {
    public struct Summary: Codable, Equatable, Sendable {
        public var measured = 0
        public var nonSilent = 0
        public var strong = 0
        public var medianPeak: Float = 0
        public var p90Peak: Float = 0
        /// Strong measurements per 5 ms lag bin, most frequent first (at most 5).
        public var lags: [String] = []
        public var stretches: [PlaybackEchoStretch] = []
        /// Every measurement in order: `<start s> <peak|silent> <lag ms>`.
        public var timeline: [String] = []
    }

    public struct Report: Codable, Equatable, Sendable {
        public let recordingID: UUID
        public let activeSeconds: Double
        public let real: Summary
        public let control: Summary
        public let controlShiftSeconds: Double
        public let elapsedSeconds: Double
    }

    public static func run(library: OpenedLibrary, recording: Recording, controlShiftSeconds: Double = 37) async throws -> Report {
        let started = Date()
        let chunks = CommittedAudioChunks(library: library)
        let owned = try chunks.ownedDirectory()
        let real = Collector(), control = Collector()
        let monitor = PlaybackEchoMonitor(recordingID: recording.id, maximumBacklog: .max, onMeasurement: real.add)
        let shifted = PlaybackEchoMonitor(maximumBacklog: .max, onMeasurement: control.add)
        let shift = UInt64(controlShiftSeconds * 48_000)
        let ordered = recording.chunks.sorted { ($0.active.start, $0.track.rawValue) < ($1.active.start, $1.track.rawValue) }
        // Capture interrupts the monitor at every gap; replay does the same where
        // a track's chunks are not contiguous.
        var trackEnd: [AudioTrack: Int64] = [:]
        for chunk in ordered {
            if let end = trackEnd[chunk.track], end != chunk.active.start.microseconds {
                await monitor.waitUntilIdle()
                monitor.interrupt()
            }
            trackEnd[chunk.track] = chunk.active.end.microseconds
            var samples: [Float] = []
            try chunks.decode(chunk, of: recording, selected: chunk.leadingTrimFrames..<(chunk.decodedFrameCount - chunk.trailingTrimFrames),
                              owned: owned, checkCancellation: { try Task.checkCancellation() }, into: &samples)
            let start = UInt64(chunk.active.start.microseconds) * 48 / 1_000
            monitor.append(chunk.track, samples: samples, start: start)
            if chunk.track == .system { shifted.append(.system, samples: samples, start: start) }
            else if start >= shift { shifted.append(.microphone, samples: samples, start: start - shift) }
            if chunk.track == .microphone {
                await monitor.waitUntilIdle(); await shifted.waitUntilIdle()
            }
        }
        await monitor.waitUntilIdle(); await shifted.waitUntilIdle()
        return Report(recordingID: recording.id, activeSeconds: recording.activeDuration.seconds,
                      real: real.summary(monitor.stretches()), control: control.summary(shifted.stretches()),
                      controlShiftSeconds: controlShiftSeconds, elapsedSeconds: Date().timeIntervalSince(started))
    }

    private final class Collector: Sendable {
        private let all = Mutex<[EchoMeasurement]>([])
        func add(_ m: EchoMeasurement) { all.withLock { $0.append(m) } }

        func summary(_ stretches: [PlaybackEchoStretch]) -> Summary {
            let list = all.withLock { $0 }
            let active = list.filter { !$0.silent }
            let peaks = active.map(\.peak).sorted()
            let strong = active.filter { $0.peak > PlaybackEchoClassifier.strongPeak }
            var bins: [Int: Int] = [:]
            for m in strong { bins[Int((m.lagMilliseconds / 5).rounded()) * 5, default: 0] += 1 }
            return Summary(measured: list.count, nonSilent: active.count, strong: strong.count,
                           medianPeak: peaks.isEmpty ? 0 : peaks[peaks.count / 2],
                           p90Peak: peaks.isEmpty ? 0 : peaks[min(peaks.count - 1, peaks.count * 9 / 10)],
                           lags: bins.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }.prefix(5).map { "\($0.key) ms ×\($0.value)" },
                           stretches: stretches,
                           timeline: list.map { m in
                               String(format: "%.1f %@ %.0f", Double(m.start) / 1e6,
                                      m.silent ? "silent" : String(format: "%.3f", m.peak), m.lagMilliseconds)
                           })
        }
    }
}
