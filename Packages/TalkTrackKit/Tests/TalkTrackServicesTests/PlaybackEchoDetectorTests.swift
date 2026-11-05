import Foundation
import Synchronization
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// detect-loudspeaker-echo tasks 1.1–1.2: correlation, decimation, classification.
@Suite struct PlaybackEchoDetectorTests {
    /// Deterministic speech-like noise: low-passed noise with a syllable envelope.
    static func speech(_ count: Int, seed: UInt64, amplitude: Float = 0.3) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        var previous: Float = 0
        return (0..<count).map { i in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let white = Float(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1
            previous = 0.7 * previous + 0.3 * white
            let envelope = 0.5 + 0.5 * sin(Float(i) * 2 * .pi * 4 / 16_000)
            return amplitude * previous * envelope
        }
    }

    static func delayed(_ x: [Float], by delay: Int, gain: Float) -> [Float] {
        (0..<x.count).map { $0 >= delay ? gain * x[$0 - delay] : 0 }
    }

    static func add(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 + $1 } }

    /// System window and microphone segment as `measure` expects them.
    static func pair(_ system: [Float], _ microphone: [Float], at w: Int = 1_000) -> ([Float], [Float]) {
        (Array(system[w..<(w + PlaybackEchoCorrelator.window)]),
         Array(microphone[(w + PlaybackEchoCorrelator.minimumLag)..<(w + PlaybackEchoCorrelator.minimumLag + PlaybackEchoCorrelator.microphoneLength)]))
    }

    @Test func findsDelayedAttenuatedEcho() {
        let n = 60_000
        let system = Self.speech(n, seed: 1)
        // −14 dB echo 90 ms late, plus the room and the user's own quiet noise.
        let microphone = Self.add(Self.delayed(system, by: 1_440, gain: 0.2), Self.speech(n, seed: 2, amplitude: 0.03))
        let (s, m) = Self.pair(system, microphone)
        let result = PlaybackEchoCorrelator().measure(system: s, microphone: m)
        #expect(!result.silent)
        #expect(result.peak > 0.2)
        #expect(abs(Double(result.lagSamples) / 16 - 90) <= 5)
    }

    @Test func independentAudioHasNoPeak() {
        let n = 60_000
        let (s, m) = Self.pair(Self.speech(n, seed: 3), Self.speech(n, seed: 4, amplitude: 0.05))
        let result = PlaybackEchoCorrelator().measure(system: s, microphone: m)
        #expect(!result.silent)
        #expect(result.peak < 0.05)
    }

    @Test func quietSystemIsSilent() {
        let n = 60_000
        let (s, m) = Self.pair([Float](repeating: 0, count: n), Self.speech(n, seed: 5))
        #expect(PlaybackEchoCorrelator().measure(system: s, microphone: m).silent)
    }

    @Test func decimatorKeepsTheGridAcrossChunks() {
        let input = (0..<9_600).map { sin(Float($0) * 2 * .pi * 300 / 48_000) }
        var whole = EchoDecimator()
        let one = whole.append(input, start: 4_800)!
        var parts = EchoDecimator()
        var joined: [Float] = []
        var first: Int64?
        for offset in stride(from: 0, to: input.count, by: 700) {
            let piece = Array(input[offset..<min(input.count, offset + 700)])
            if let out = parts.append(piece, start: 4_800 + UInt64(offset)) {
                if first == nil { first = out.start }
                joined += out.samples
            }
        }
        #expect(one.start == 1_605 && first == one.start)   // ceil((4800 + 15) / 3)
        #expect(joined.count == one.samples.count)
        #expect(zip(joined, one.samples).allSatisfy { abs($0 - $1) < 1e-5 })
        // A 300 Hz tone passes the 7 kHz low-pass unchanged.
        let peak = one.samples.map(abs).max()!
        #expect(abs(peak - 1) < 0.01)
    }

    static func measurement(_ i: Int, peak: Float, lag: Double = 90, silent: Bool = false) -> EchoMeasurement {
        EchoMeasurement(start: Int64(i) * 1_500_000, end: Int64(i) * 1_500_000 + 3_000_000,
                        peak: peak, lagMilliseconds: lag, silent: silent)
    }

    @Test func loudspeakerSequenceSwitchesQuickly() {
        var c = PlaybackEchoClassifier()
        var switchedAt: Int?
        for i in 0..<20 {
            if c.add(Self.measurement(i, peak: 0.25, lag: 90 + Double(i % 3) * 5)), switchedAt == nil { switchedAt = i }
        }
        #expect(c.state == .loudspeaker)
        #expect(switchedAt.map { $0 < 10 } == true)
        let stretches = c.stretches()
        #expect(stretches.count == 1 && stretches[0].state == .loudspeaker)
        #expect(stretches[0].active.start == .zero)
        #expect(stretches[0].lagMilliseconds == 95)
    }

    @Test func headsetNeverBecomesLoudspeaker() {
        var c = PlaybackEchoClassifier()
        // Four isolated strong windows on one lag, as in the real headset recording.
        let strong: Set<Int> = [30, 31, 33, 34]
        for i in 0..<200 {
            _ = c.add(Self.measurement(i, peak: strong.contains(i) ? 0.12 : 0.015, lag: strong.contains(i) ? 240 : Double(i % 400)))
            #expect(c.state != .loudspeaker)
        }
        #expect(c.state == .headset)
        #expect(c.stretches().allSatisfy { $0.state == .headset })
    }

    @Test func earlyStrayWindowsInAHeadsetDoNotDecide() {
        // The real headset recording: 3 strong windows on 240 ms among its first 6.
        var c = PlaybackEchoClassifier()
        let peaks: [Float] = [0.12, 0.02, 0.13, 0.015, 0.12, 0.01, 0.02, 0.01, 0.015, 0.01]
        for (i, p) in peaks.enumerated() { _ = c.add(Self.measurement(i, peak: p, lag: p > 0.1 ? 240 : Double(i * 37))) }
        #expect(!c.stretches().contains { $0.state == .loudspeaker })
    }

    @Test func silentWindowsDoNotDecide() {
        var c = PlaybackEchoClassifier()
        for i in 0..<40 { _ = c.add(Self.measurement(i, peak: 0, silent: true)) }
        #expect(c.state == .unknown && c.stretches().isEmpty)
    }

    @Test func switchFromLoudspeakerToHeadsetGivesTwoStretches() throws {
        var c = PlaybackEchoClassifier()
        for i in 0..<40 { _ = c.add(Self.measurement(i, peak: 0.28)) }
        for i in 40..<100 { _ = c.add(Self.measurement(i, peak: 0.01)) }
        let stretches = c.stretches()
        #expect(stretches.map(\.state) == [.loudspeaker, .headset])
        #expect(stretches[0].active.end == stretches[1].active.start)
        // The headset stretch begins after the last echo window, never inside the echo.
        #expect(stretches[1].active.start >= (try MediaTime(seconds: 40 * 1.5)))
        #expect(stretches.state(at: try MediaTime(seconds: 10)) == .loudspeaker)
        #expect(stretches.state(at: try MediaTime(seconds: 120)) == .headset)
    }

    @Test func bluetoothHeadsetAfterADeviceChangeIsAHeadset() throws {
        // The user's switch (2026-11-05): loudspeakers, a device change, then a
        // Bluetooth headset whose echo canceller converges over the first windows
        // and leaves residual peaks of 0.10–0.16 in 25% of the windows.
        var c = PlaybackEchoClassifier()
        for i in 0..<30 { _ = c.add(Self.measurement(i, peak: 0.22, lag: 110)) }
        c.interrupt()
        let after: [Float] = [0.562, 0.495, 0.102, 0.028, 0.025, 0.157, 0.007, 0.006, 0.004, 0.008,
                              0.025, 0.050, 0.035, 0.028, 0.012, 0.101, 0.102, 0.073, 0.003, 0.030,
                              0.020, 0.015, 0.011, 0.104, 0.025, 0.009]
        for (n, p) in after.enumerated() { _ = c.add(Self.measurement(34 + n, peak: p, lag: 225)) }
        #expect(c.state == .headset)
        let stretches = c.stretches()
        #expect(stretches.map(\.state) == [.loudspeaker, .headset])
        // The settling windows (first 6 s after the change) are never inside the headset stretch.
        #expect(stretches[1].active.start >= (try MediaTime(seconds: 34 * 1.5 + 6)))
    }

    @Test func settlingWindowsAreIgnoredAfterAnInterrupt() {
        var c = PlaybackEchoClassifier()
        c.interrupt()
        // Strong windows only during the first 6 s after the change: no decision from them.
        for i in 0..<4 { _ = c.add(Self.measurement(i, peak: 0.5)) }
        for i in 4..<11 { _ = c.add(Self.measurement(i, peak: 0.5)) }
        #expect(c.state == .unknown)  // 7 counted windows, fewer than the 8 required
        _ = c.add(Self.measurement(11, peak: 0.5))
        #expect(c.state == .loudspeaker)
        #expect(c.stretches().first?.active.start == (try? MediaTime(seconds: 4 * 1.5)))
    }

    @Test func moderateEchoIsNeitherHeadsetNorLoudspeaker() {
        // Median well above a headset's but too few strong windows for loudspeakers.
        var c = PlaybackEchoClassifier()
        for i in 0..<60 { _ = c.add(Self.measurement(i, peak: i % 2 == 0 ? 0.12 : 0.07)) }
        #expect(c.state == .unknown)
    }

    @Test func interruptClosesTheStretch() {
        var c = PlaybackEchoClassifier()
        for i in 0..<20 { _ = c.add(Self.measurement(i, peak: 0.3)) }
        c.interrupt()
        #expect(c.state == .unknown)
        #expect(c.stretches().count == 1)
    }

    /// Feeds 48 kHz audio through the live monitor in 32 ms packets.
    static func feed(_ monitor: PlaybackEchoMonitor, system: [Float], microphone: [Float], from start: UInt64 = 0) {
        let packet = 1_536
        for offset in stride(from: 0, to: system.count, by: packet) {
            let end = min(system.count, offset + packet)
            monitor.append(.system, samples: Array(system[offset..<end]), start: start + UInt64(offset))
            monitor.append(.microphone, samples: Array(microphone[offset..<end]), start: start + UInt64(offset))
        }
    }

    /// 48 kHz speech-like audio: the 16 kHz generator upsampled by repetition.
    static func speech48(_ seconds: Double, seed: UInt64, amplitude: Float = 0.3) -> [Float] {
        speech(Int(seconds * 16_000), seed: seed, amplitude: amplitude).flatMap { [$0, $0, $0] }
    }

    @Test func monitorDetectsLoudspeakersAndHeadset() async {
        let system = Self.speech48(30, seed: 7)
        let echo = Self.add(Self.delayed(system, by: 4_800, gain: 0.2), Self.speech48(30, seed: 8, amplitude: 0.02))
        let changes = Mutex<[PlaybackEchoState]>([])
        let monitor = PlaybackEchoMonitor(maximumBacklog: .max, onChange: { state in changes.withLock { $0.append(state) } })
        Self.feed(monitor, system: system, microphone: echo)
        await monitor.waitUntilIdle()
        #expect(monitor.status.state == .loudspeaker)
        #expect(changes.withLock { $0 } == [.loudspeaker])

        // The user puts on a headset: a device change, then no echo.
        monitor.interrupt()
        #expect(monitor.status.state == .unknown)
        let later = Self.speech48(40, seed: 9)
        Self.feed(monitor, system: later, microphone: Self.speech48(40, seed: 10, amplitude: 0.05), from: UInt64(system.count) + 48_000)
        await monitor.waitUntilIdle()
        #expect(monitor.status.state == .headset)
        #expect(monitor.stretches().map(\.state) == [.loudspeaker, .headset])
    }

    @Test func backlogSkipsOldWindows() async {
        // Fed far faster than real time, a capture monitor analyzes only recent windows.
        let monitor = PlaybackEchoMonitor(maximumBacklog: 1)
        let a = Self.speech48(40, seed: 13)
        Self.feed(monitor, system: a, microphone: a)
        await monitor.waitUntilIdle()
        #expect(monitor.status.skipped > 0)
        #expect(monitor.status.measured + monitor.status.skipped == 25, "\(monitor.status)")
    }

    @Test func noMeasurementSpansAGap() async {
        // Echo before and after a gap, but the microphone resumes later than the
        // system track: a window across the gap would pair unrelated audio.
        let monitor = PlaybackEchoMonitor(maximumBacklog: .max)
        let a = Self.speech48(4, seed: 11)
        Self.feed(monitor, system: a, microphone: Self.delayed(a, by: 4_800, gain: 0.2))
        await monitor.waitUntilIdle()   // Pause discards windows not yet analyzed.
        monitor.pause()
        let b = Self.speech48(4, seed: 12)
        Self.feed(monitor, system: b, microphone: Self.delayed(b, by: 4_800, gain: 0.2), from: UInt64(a.count))
        await monitor.waitUntilIdle()
        // Each 4 s section fits exactly one 3 s window plus the lag margin.
        #expect(monitor.status.measured == 2, "\(monitor.status)")
    }
}
