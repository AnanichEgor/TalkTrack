@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import TalkTrackAudio

private final class TapLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPackets: [AudioPacket] = []
    private var storedErrors: [AudioCaptureError] = []
    func receive(_ packet: AudioPacket) { lock.withLock { storedPackets.append(packet) } }
    func fail(_ error: AudioCaptureError) { lock.withLock { storedErrors.append(error) } }
    var packets: [AudioPacket] { lock.withLock { storedPackets } }
    var errors: [AudioCaptureError] { lock.withLock { storedErrors } }
}

/// Calls the IOProc from a timer with stereo float blocks, like the aggregate device.
private final class FakeTapSession: SystemTapSession, @unchecked Sendable {
    private let lock = NSLock()
    private let startDelay: TimeInterval, stopDelay: TimeInterval
    private let prepareError: Error?
    private let validHostTime: Bool
    private var timer: DispatchSourceTimer?
    private var stopCount = 0
    init(startDelay: TimeInterval = 0, stopDelay: TimeInterval = 0, prepareError: Error? = nil, validHostTime: Bool = true) {
        self.startDelay = startDelay; self.stopDelay = stopDelay; self.prepareError = prepareError; self.validHostTime = validHostTime
    }
    func prepare() throws -> Double {
        if let prepareError { throw prepareError }
        return 44_100
    }
    func start(_ io: @escaping SystemTapIO, routeChanged: @escaping @Sendable (String) -> Void) throws {
        if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
        let valid = validHostTime
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "fake-tap"))
        timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(10))
        timer.setEventHandler {
            let frames = 441
            var samples = [Float](repeating: 0, count: frames * 2)
            for frame in 0..<frames { samples[frame * 2] = 0.5; samples[frame * 2 + 1] = 0.25 }
            samples.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                    mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                var time = AudioTimeStamp()
                time.mHostTime = valid ? mach_absolute_time() : 0
                time.mSampleTime = 1_000
                time.mFlags = valid ? [.hostTimeValid, .sampleTimeValid] : [.sampleTimeValid]
                io(&list, &time)
            }
        }
        timer.resume()
        lock.withLock { self.timer = timer }
    }
    func stop() throws {
        if stopDelay > 0 { Thread.sleep(forTimeInterval: stopDelay) }
        lock.withLock { timer?.cancel(); timer = nil; stopCount += 1 }
    }
    var stops: Int { lock.withLock { stopCount } }
    var running: Bool { lock.withLock { timer != nil } }
}

private final class SessionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [FakeTapSession]
    init(_ sessions: [FakeTapSession]) { remaining = sessions }
    func next() -> any SystemTapSession { lock.withLock { remaining.removeFirst() } }
}

private func fastTiming() -> ProcessTapCapture.Timing {
    var timing = ProcessTapCapture.Timing()
    timing.prepare = .milliseconds(300); timing.start = .milliseconds(200); timing.teardown = .milliseconds(200)
    return timing
}

private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
}

@Suite struct ProcessTapCaptureTests {
    @Test func deliversMonoPacketsWithHostTimeAndStops() async throws {
        let session = FakeTapSession(), log = TapLog()
        let capture = ProcessTapCapture(worker: HALWorker(), timing: fastTiming()) { session }
        try await capture.start(receive: log.receive, failure: log.fail)
        try await waitUntil { log.packets.count >= 3 }
        try await capture.stop()
        let packet = try #require(log.packets.first)
        #expect(packet.source == .system && packet.sampleRate == 44_100)
        #expect(packet.samples.count == 441 && packet.hostTime > 0 && packet.sampleTime == 1_000)
        #expect(packet.samples.allSatisfy { abs($0 - 0.375) < 1e-6 })
        #expect(log.errors.isEmpty && !session.running && session.stops == 1)
    }

    @Test func invalidHostTimeInterruptsTheRecording() async throws {
        let log = TapLog()
        let capture = ProcessTapCapture(worker: HALWorker(), timing: fastTiming()) { FakeTapSession(validHostTime: false) }
        try await capture.start(receive: log.receive, failure: log.fail)
        try await waitUntil { !log.errors.isEmpty }
        try await capture.stop()
        #expect(log.packets.isEmpty)
        #expect(log.errors.first?.operation.contains("invalid audio or timing") == true)
    }

    @Test func formatCheckAcceptsOnlyFloat32LittleEndian() {
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        #expect(GlobalTapSession.supported(format))
        format.mFormatFlags |= kAudioFormatFlagIsBigEndian
        #expect(!GlobalTapSession.supported(format))
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger; format.mBitsPerChannel = 16
        #expect(!GlobalTapSession.supported(format))
        format = AudioStreamBasicDescription(); format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags = kAudioFormatFlagIsFloat; format.mBitsPerChannel = 32; format.mSampleRate = .nan
        #expect(!GlobalTapSession.supported(format))
    }

    @Test func failedPrepareReportsItAndReleasesTheSession() async throws {
        let problem = AudioCaptureError(source: .system, operation: "Cannot create the system audio tap", status: -50)
        let session = FakeTapSession(prepareError: problem)
        let capture = ProcessTapCapture(worker: HALWorker(), timing: fastTiming()) { session }
        await #expect(throws: AudioCaptureError.self) { try await capture.start(receive: { _ in }, failure: { _ in }) }
        #expect(session.stops == 1)
        try await capture.stop()
    }

    @Test func hungStartFailsInTimeThenStopsItselfAndRefusesStartsMeanwhile() async throws {
        let worker = HALWorker(), slow = FakeTapSession(startDelay: 0.5), log = TapLog()
        let capture = ProcessTapCapture(worker: worker, timing: fastTiming()) { slow }
        let began = ContinuousClock.now
        do {
            try await capture.start(receive: log.receive, failure: log.fail)
            Issue.record("start should time out")
        } catch let error as AudioCaptureError {
            #expect(error.operation.contains("did not finish"))
        }
        #expect(ContinuousClock.now - began < .milliseconds(450))
        try await capture.stop()

        let other = ProcessTapCapture(worker: worker, timing: fastTiming()) { FakeTapSession() }
        do {
            try await other.start(receive: { _ in }, failure: { _ in })
            Issue.record("start should be refused while the worker is hung")
        } catch let error as AudioCaptureError {
            #expect(error.operation.contains("restart TalkTrack"))
        }

        try await waitUntil { slow.stops == 1 && worker.hungOperation == nil }
        #expect(slow.stops == 1 && !slow.running)
        #expect(log.packets.isEmpty)
        try await other.start(receive: { _ in }, failure: { _ in })
        try await other.stop()
    }

    @Test func hungTeardownKeepsAcceptedAudioAndTellsTheUserToRestart() async throws {
        let worker = HALWorker(), session = FakeTapSession(stopDelay: 0.5), log = TapLog()
        let sessions = SessionQueue([session, FakeTapSession()])
        let capture = ProcessTapCapture(worker: worker, timing: fastTiming()) { sessions.next() }
        try await capture.start(receive: log.receive, failure: log.fail)
        try await waitUntil { log.packets.count >= 2 }
        do {
            try await capture.stop()
            Issue.record("stop should time out")
        } catch let error as AudioCaptureError {
            #expect(error.operation.contains("recording was saved") && error.operation.contains("Restart TalkTrack"))
        }
        let kept = log.packets.count
        #expect(kept >= 2)
        try await capture.stop() // nothing left to stop
        await #expect(throws: AudioCaptureError.self) { try await capture.start(receive: { _ in }, failure: { _ in }) }

        try await waitUntil { worker.hungOperation == nil }
        try await Task.sleep(for: .milliseconds(30))
        #expect(log.packets.count == kept) // the closed handoff accepted nothing after Stop
        try await capture.start(receive: { _ in }, failure: { _ in })
        try await capture.stop()
    }
}
