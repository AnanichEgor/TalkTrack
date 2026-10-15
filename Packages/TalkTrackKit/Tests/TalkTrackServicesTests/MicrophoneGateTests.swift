import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// Task 5.8: the microphone is recognized only where it is louder than the
/// system track at the same active time.
@Suite struct MicrophoneGateTests {
    static func tone(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 0.3) }
    }

    @Test func keepsWordsMostlyInLouderFrames() throws {
        // System: 1 s of loud speech, then 1 s of silence.
        var levels: [Float] = []
        MicrophoneGate.record(Self.tone(1, amplitude: 0.5) + Array(repeating: 0, count: 16_000), start: .zero, into: &levels)
        #expect(levels.count == 20)
        // Microphone: quieter echo of the first second, then the user's own speech.
        let louder = MicrophoneGate.louderFrames(Self.tone(1, amplitude: 0.1) + Self.tone(1, amplitude: 0.3), start: .zero, system: levels)
        #expect(louder == Set(9...20))   // frames 10–19 plus one hangover frame each side
        let word = { (a: Double, b: Double) in try MediaInterval(start: MediaTime(seconds: a), end: MediaTime(seconds: b)) }
        #expect(!MicrophoneGate.keep(try word(0.2, 0.6), louder: louder))   // echo
        #expect(MicrophoneGate.keep(try word(1.2, 1.5), louder: louder))    // own speech
        #expect(MicrophoneGate.keep(try word(0.85, 1.15), louder: louder))  // edge word, mostly louder
        #expect(!MicrophoneGate.keep(try word(0.3, 0.95), louder: louder))  // mostly echo
    }

    @Test func echoOnlyWindowHasNoLouderFrames() {
        var levels: [Float] = []
        MicrophoneGate.record(Self.tone(2, amplitude: 0.5), start: .zero, into: &levels)
        #expect(MicrophoneGate.louderFrames(Self.tone(2, amplitude: 0.2), start: .zero, system: levels).isEmpty)
        #expect(MicrophoneGate.louderFrames(Array(repeating: 0, count: 32_000), start: .zero, system: []).isEmpty)
    }

    @Test func gridFollowsAbsoluteActiveTimeAcrossWindows() throws {
        // A window starting at 9.05 s shares frames with the previous window's grid.
        var levels: [Float] = []
        let start = try MediaTime(microseconds: 9_050_000)
        MicrophoneGate.record(Self.tone(0.15, amplitude: 0.5), start: start, into: &levels)
        #expect(levels.count == 92 && levels[90] > 0 && levels[91] > 0 && levels[89] == 0)
        // No system level for later frames: any microphone sound there is kept.
        let later = try MediaTime(seconds: 20)
        #expect(!MicrophoneGate.louderFrames(Self.tone(0.5, amplitude: 0.01), start: later, system: levels).isEmpty)
    }
}
