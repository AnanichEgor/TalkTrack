import Foundation
import Testing
import TalkTrackAudio
@testable import TalkTrackServices

@Suite struct AudioLevelMeterTests {
    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }

    private func packet(_ source: CaptureSource, amplitude: Float, seconds: Double = 0.1) -> AudioPacket {
        AudioPacket(source: source, sampleRate: 48_000, hostTime: 0, sampleTime: 0,
                    samples: [Float](repeating: amplitude, count: Int(48_000 * seconds)))
    }

    @Test func levelsPerSourceElapsedTimeAndSilenceAfterPause() {
        let clock = Clock()
        let meter = AudioLevelMeter(now: { clock.now })
        #expect(meter.read() == .init())
        meter.record(packet(.microphone, amplitude: 1))
        meter.record(packet(.system, amplitude: 0.001))  // −60 dBFS
        var reading = meter.read()
        #expect(reading.microphone == 1 && reading.system == 0)
        #expect(abs(reading.seconds - 0.1) < 1e-9)
        meter.record(packet(.microphone, amplitude: 0.0316))  // −30 dBFS decays, not drops
        reading = meter.read()
        #expect(reading.microphone > 0.5 && reading.microphone < 1)
        #expect(abs(reading.seconds - 0.2) < 1e-9)
        // A paused recording delivers nothing: levels fall silent, time stays.
        clock.now += 1
        reading = meter.read()
        #expect(reading.microphone == 0 && abs(reading.seconds - 0.2) < 1e-9)
        meter.reset()
        #expect(meter.read() == .init())
    }
}
