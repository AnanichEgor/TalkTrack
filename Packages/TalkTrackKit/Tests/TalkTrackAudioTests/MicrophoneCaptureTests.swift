@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import TalkTrackAudio

private final class MicLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPackets: [AudioPacket] = []
    private var storedErrors: [AudioCaptureError] = []
    func receive(_ packet: AudioPacket) { lock.withLock { storedPackets.append(packet) } }
    func fail(_ error: AudioCaptureError) { lock.withLock { storedErrors.append(error) } }
    var packets: [AudioPacket] { lock.withLock { storedPackets } }
}

/// Calls the tap from a timer with mono float buffers, like `AVAudioEngine`.
/// Delays block the worker thread, as a stalled engine call would.
private final class FakeMicSession: MicrophoneEngineSession, @unchecked Sendable {
    private let lock = NSLock()
    private let startDelay: TimeInterval, stopDelay: TimeInterval
    private var timer: DispatchSourceTimer?
    private var stopCount = 0
    init(startDelay: TimeInterval = 0, stopDelay: TimeInterval = 0) { self.startDelay = startDelay; self.stopDelay = stopDelay }
    func prepare(deviceID: AudioObjectID?) throws -> Double { 48_000 }
    func start(_ io: @escaping MicrophoneIO, configurationChanged: @escaping @Sendable () -> Void) throws {
        if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "fake-mic"))
        timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(10))
        timer.setEventHandler {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buffer.frameLength = 480
            for frame in 0..<480 { buffer.floatChannelData![0][frame] = 0.25 }
            io(buffer, AVAudioTime(hostTime: mach_absolute_time()))
        }
        timer.resume()
        lock.withLock { self.timer = timer }
    }
    func stop() {
        if stopDelay > 0 { Thread.sleep(forTimeInterval: stopDelay) }
        lock.withLock { timer?.cancel(); timer = nil; stopCount += 1 }
    }
    var stops: Int { lock.withLock { stopCount } }
    var running: Bool { lock.withLock { timer != nil } }
}

private final class MicSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [FakeMicSession]
    init(_ sessions: [FakeMicSession]) { remaining = sessions }
    func next() -> any MicrophoneEngineSession { lock.withLock { remaining.removeFirst() } }
}

private func fastTiming() -> MicrophoneCapture.Timing {
    var timing = MicrophoneCapture.Timing()
    timing.start = .milliseconds(200); timing.stop = .milliseconds(200)
    return timing
}

private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
}

@Suite struct MicrophoneCaptureTests {
    private func capture(_ worker: HALWorker, _ sessions: MicSessions) -> MicrophoneCapture {
        MicrophoneCapture(worker: worker, timing: fastTiming(), authorization: { .authorized }) { sessions.next() }
    }

    @Test func deliversPacketsThroughTheWorkerAndStops() async throws {
        let session = FakeMicSession(), log = MicLog()
        let capture = capture(HALWorker(), MicSessions([session]))
        try await capture.start(receive: log.receive, failure: log.fail)
        try await waitUntil { log.packets.count >= 2 }
        try await capture.stop()
        #expect(log.packets.first?.source == .microphone && log.packets.first?.samples.count == 480)
        #expect(session.stops == 1 && !session.running)
    }

    @Test func hungStartReportsAMicrophoneErrorAndReleasesTheLateEngine() async throws {
        let worker = HALWorker(), slow = FakeMicSession(startDelay: 0.5)
        let capture = capture(worker, MicSessions([slow, FakeMicSession()]))
        let clock = ContinuousClock(), began = clock.now
        do {
            try await capture.start(receive: { _ in }, failure: { _ in })
            Issue.record("start should time out")
        } catch let error as AudioCaptureError {
            #expect(error.source == .microphone && error.operation.contains("did not finish"))
        }
        #expect(clock.now - began < .milliseconds(450))
        await #expect(throws: AudioCaptureError.self) { try await capture.start(receive: { _ in }, failure: { _ in }) }
        // The start that returns after its timeout stops its own engine.
        try await waitUntil { slow.stops == 1 && worker.hungOperation == nil }
        #expect(slow.stops == 1 && !slow.running)
        try await capture.start(receive: { _ in }, failure: { _ in })
        try await capture.stop()
    }

    @Test func hungStopKeepsAcceptedAudioRefusesTheNextStartAndRecovers() async throws {
        let worker = HALWorker(), session = FakeMicSession(stopDelay: 0.5), log = MicLog()
        let capture = capture(worker, MicSessions([session, FakeMicSession()]))
        try await capture.start(receive: log.receive, failure: log.fail)
        try await waitUntil { log.packets.count >= 2 }
        let clock = ContinuousClock(), began = clock.now
        do {
            try await capture.stop()
            Issue.record("stop should time out")
        } catch let error as AudioCaptureError {
            #expect(error.source == .microphone)
            #expect(error.operation.contains("recording was saved") && error.recovery == .restartTalkTrack)
            #expect(error.recoverySuggestion == "Restart TalkTrack before recording again.")
        }
        #expect(clock.now - began < .milliseconds(450))
        let kept = log.packets.count
        #expect(kept >= 2)
        do {
            try await capture.start(receive: { _ in }, failure: { _ in })
            Issue.record("start should be refused while the stop is hung")
        } catch let error as AudioCaptureError {
            #expect(error.source == .microphone && error.operation.contains("has not returned") && error.recovery == .restartTalkTrack)
        }

        try await waitUntil { session.stops == 1 && worker.hungOperation == nil }
        try await Task.sleep(for: .milliseconds(30))
        #expect(log.packets.count == kept) // the finished handoff accepted nothing after Stop
        try await capture.start(receive: { _ in }, failure: { _ in })
        try await capture.stop()
    }
}
