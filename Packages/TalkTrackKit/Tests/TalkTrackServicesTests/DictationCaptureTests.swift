import CoreAudio
import Foundation
import os
import Testing
import TalkTrackAudio
@testable import TalkTrackServices

/// Delivers packets the test pushes, as the audio executor would.
private final class FakeMicrophone: DictationMicrophoneDriver, Sendable {
    private struct State {
        var receive: (@Sendable (AudioPacket) -> Void)?
        var failure: (@Sendable (AudioCaptureError) -> Void)?
        var device: AudioObjectID??
        var stops = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func start(deviceID: AudioObjectID?, receive: @escaping @Sendable (AudioPacket) -> Void,
               failure: @escaping @Sendable (AudioCaptureError) -> Void) async throws {
        state.withLock { $0.receive = receive; $0.failure = failure; $0.device = .some(deviceID) }
    }
    func stop() async { state.withLock { $0.receive = nil; $0.stops += 1 } }

    var stops: Int { state.withLock { $0.stops } }
    var device: AudioObjectID?? { state.withLock { $0.device } }

    /// `seconds` of audio at `level` amplitude in 1024-frame packets at 48 kHz.
    func push(seconds: Double, level: Float) {
        let receive = state.withLock { $0.receive }
        var remaining = Int(seconds * 48_000)
        while remaining > 0 {
            let count = min(1024, remaining)
            receive?(AudioPacket(source: .microphone, sampleRate: 48_000, hostTime: 0, sampleTime: 0,
                                 samples: (0..<count).map { level * sin(Float($0) * 0.2) }))
            remaining -= count
        }
    }
    func fail() { state.withLock { $0.failure }?(AudioCaptureError(source: .microphone, operation: "gone", status: nil)) }
}

@Suite struct DictationCaptureTests {
    @Test func tailStopsWhenSpeechEnds() async throws {
        let driver = FakeMicrophone(), microphone = DictationMicrophone(driver: driver, resolveDevice: { 42 })
        try await microphone.start(maximumSeconds: 120) {}
        #expect(driver.device == .some(42))
        driver.push(seconds: 1, level: 0.3)
        #expect(microphone.level() > 0)
        let finish = Task { await microphone.finish() }
        // The last word continues for 150 ms after release, then silence.
        while !microphone.isReleased { await Task.yield() }
        driver.push(seconds: 0.15, level: 0.3)
        driver.push(seconds: 0.2, level: 0)
        let capture = await finish.value
        #expect(abs(capture.spokenSeconds - 1) < 0.03)
        // The spoken tail is kept, the stop comes once the new audio is quiet.
        #expect(capture.tailSeconds >= 0.15 + DictationTail.windowSeconds - 0.03)
        #expect(capture.tailSeconds < 0.15 + 0.1)
        #expect(abs(Double(capture.samples.count) / 16_000 - capture.spokenSeconds - capture.tailSeconds) < 0.01)
        #expect(driver.stops == 1)
    }

    @Test func tailKeepsAtLeast80Milliseconds() {
        let quiet = ArraySlice([Float](repeating: 0, count: 48_000 / 20))
        #expect(!DictationTail.isComplete(quiet, sampleRate: 48_000))
        #expect(DictationTail.isComplete(ArraySlice([Float](repeating: 0, count: 48_000 / 10)), sampleRate: 48_000))
    }

    @Test func midWordReleaseKeeps400Milliseconds() async throws {
        let driver = FakeMicrophone(), microphone = DictationMicrophone(driver: driver, resolveDevice: { nil })
        try await microphone.start(maximumSeconds: 120) {}
        driver.push(seconds: 0.5, level: 0.3)
        let finish = Task { await microphone.finish() }
        while !microphone.isReleased { await Task.yield() }
        driver.push(seconds: 1, level: 0.3)
        let capture = await finish.value
        #expect(abs(capture.tailSeconds - DictationTail.maximumSeconds) < 0.03)
    }

    @Test func noPacketsAfterReleaseStillFinishes() async throws {
        let driver = FakeMicrophone(), microphone = DictationMicrophone(driver: driver, resolveDevice: { nil })
        try await microphone.start(maximumSeconds: 120) {}
        driver.push(seconds: 0.5, level: 0.3)
        let started = ContinuousClock.now
        let capture = await microphone.finish()
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(abs(capture.spokenSeconds - 0.5) < 0.03 && capture.tailSeconds == 0)
    }

    @Test func maximumLengthStopsOnce() async throws {
        let driver = FakeMicrophone(), microphone = DictationMicrophone(driver: driver, resolveDevice: { nil })
        let calls = OSAllocatedUnfairLock(initialState: 0)
        try await microphone.start(maximumSeconds: 30) { calls.withLock { $0 += 1 } }
        driver.push(seconds: 31, level: 0.3)
        #expect(calls.withLock { $0 } == 1)
        let capture = await microphone.finish()
        #expect(capture.reachedLimit)
        #expect(abs(capture.spokenSeconds - 30) < 0.001 && capture.tailSeconds == 0)
        #expect(abs(Double(capture.samples.count) - 30 * 16_000) < 50)
    }

    @Test func accidentalTapIsShorterThanTheMinimum() async throws {
        let driver = FakeMicrophone(), microphone = DictationMicrophone(driver: driver, resolveDevice: { nil })
        try await microphone.start(maximumSeconds: 120) {}
        driver.push(seconds: 0.1, level: 0.3)
        let capture = await microphone.finish()
        #expect(capture.spokenSeconds < DictationMicrophone.minimumSeconds)
    }

    @Test func disconnectedMicrophoneIsNamed() async {
        let driver = FakeMicrophone()
        let microphone = DictationMicrophone(driver: driver, resolveDevice: {
            throw AudioCaptureError(source: .microphone, operation: "The selected microphone \u{201C}USB Mic\u{201D} is not connected",
                                    status: nil, recovery: .selectedMicrophone)
        })
        do { try await microphone.start(maximumSeconds: 120) {}; Issue.record("Expected refusal") }
        catch { #expect(error.localizedDescription.contains("USB Mic")) }
        #expect(driver.device == nil)
    }

    @Test func deviceFailureEndsTheRecording() async throws {
        let driver = FakeMicrophone(), microphone = DictationMicrophone(driver: driver, resolveDevice: { nil })
        try await microphone.start(maximumSeconds: 120) {}
        driver.push(seconds: 0.5, level: 0.3)
        driver.fail()
        let capture = await microphone.finish()
        #expect(capture.deviceFailed && capture.tailSeconds == 0)
    }

    @Test func cancelDiscardsAudio() async throws {
        let driver = FakeMicrophone(), microphone = DictationMicrophone(driver: driver, resolveDevice: { nil })
        try await microphone.start(maximumSeconds: 120) {}
        driver.push(seconds: 0.5, level: 0.3)
        await microphone.cancel()
        #expect(driver.stops == 1)
        #expect(await microphone.finish().samples.isEmpty)
    }
}
