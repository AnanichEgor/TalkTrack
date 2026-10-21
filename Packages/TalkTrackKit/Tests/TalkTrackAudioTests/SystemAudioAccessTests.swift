import Foundation
import Testing
@testable import TalkTrackAudio

/// Delivers scripted blocks from a timer, like the check tap's IOProc.
private final class FakeProbe: SystemAudioAccessProbe, @unchecked Sendable {
    enum Signal { case tone, zeros, nothing }
    private let lock = NSLock()
    private let signal: Signal
    private let startDelay: TimeInterval
    private let stopDelay: TimeInterval
    private let startError: Error?
    private var timer: DispatchSourceTimer?
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var running = false

    init(_ signal: Signal, startDelay: TimeInterval = 0, stopDelay: TimeInterval = 0, startError: Error? = nil) {
        self.signal = signal; self.startDelay = startDelay; self.stopDelay = stopDelay; self.startError = startError
    }

    func start(deliver: @escaping @Sendable (UnsafeBufferPointer<Float>) -> Void) throws {
        lock.withLock { starts += 1 }
        if startDelay > 0 { Thread.sleep(forTimeInterval: startDelay) }
        if let startError { throw startError }
        lock.withLock { running = true }
        guard signal != .nothing else { return }
        let samples: [Float] = (0..<480).map { signal == .tone ? 1e-4 * sin(Float($0) * 0.13) : 0 }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "fake-probe"))
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(10))
        timer.setEventHandler { samples.withUnsafeBufferPointer { deliver($0) } }
        timer.resume()
        lock.withLock { self.timer = timer }
    }

    func stop() throws {
        if stopDelay > 0 { Thread.sleep(forTimeInterval: stopDelay) }
        lock.withLock { timer?.cancel(); timer = nil; running = false; stops += 1 }
    }
    var counts: (starts: Int, stops: Int, running: Bool) { lock.withLock { (starts, stops, running) } }
}

private final class ProbeFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeProbe] = []
    private let next: () -> FakeProbe
    init(_ next: @escaping () -> FakeProbe) { self.next = next }
    func make() -> any SystemAudioAccessProbe { let probe = next(); lock.withLock { made.append(probe) }; return probe }
    var probes: [FakeProbe] { lock.withLock { made } }
}

private func fastTiming() -> SystemAudioAccess.Timing {
    var timing = SystemAudioAccess.Timing()
    timing.start = .milliseconds(300); timing.listen = .milliseconds(600)
    timing.zeroSpan = .milliseconds(200); timing.teardown = .milliseconds(300); timing.poll = .milliseconds(5)
    return timing
}

@Suite struct SystemAudioAccessTests {
    @Test func checkToneIsAllowedEvenWithNothingElsePlaying() async {
        let factory = ProbeFactory { FakeProbe(.tone) }
        let access = SystemAudioAccess(timing: fastTiming(), makeProbe: factory.make)
        let report = await access.check()
        #expect(report.state == .allowed)
        #expect(report.peak > 0 && report.peak <= 1e-4)
        #expect(report.firstBufferSeconds != nil && report.teardownSeconds != nil)
        #expect(factory.probes.first?.counts.running == false)
    }

    @Test func exactZerosForTheZeroSpanAreDenied() async {
        let factory = ProbeFactory { FakeProbe(.zeros) }
        let access = SystemAudioAccess(timing: fastTiming(), makeProbe: factory.make)
        let report = await access.check()
        #expect(report.state == .denied)
        #expect(report.buffers > 1 && report.peak == 0)
        #expect(factory.probes.first?.counts.stops == 1)
    }

    @Test func noCallbacksAreUndetermined() async {
        let factory = ProbeFactory { FakeProbe(.nothing) }
        let report = await SystemAudioAccess(timing: fastTiming(), makeProbe: factory.make).check()
        #expect(report.state == .undetermined)
        #expect(report.buffers == 0 && report.detail != nil)
    }

    @Test func allowedIsCachedForTheLaunchButDeniedIsCheckedAgain() async {
        let allowedFactory = ProbeFactory { FakeProbe(.tone) }
        let access = SystemAudioAccess(timing: fastTiming(), makeProbe: allowedFactory.make)
        #expect(await access.check().state == .allowed)
        let second = await access.check()
        #expect(second.state == .allowed && second.cached)
        #expect(allowedFactory.probes.count == 1)
        #expect(await access.isAllowed)

        let deniedFactory = ProbeFactory { FakeProbe(.zeros) }
        let denied = SystemAudioAccess(timing: fastTiming(), makeProbe: deniedFactory.make)
        #expect(await denied.check().state == .denied)
        #expect(await denied.check().state == .denied)
        #expect(deniedFactory.probes.count == 2)
        #expect(await !denied.isAllowed)
    }

    @Test func concurrentChecksShareOneProbe() async {
        let factory = ProbeFactory { FakeProbe(.tone) }
        let access = SystemAudioAccess(timing: fastTiming(), makeProbe: factory.make)
        async let first = access.check(), second = access.check()
        let states = await [first.state, second.state]
        #expect(states == [.allowed, .allowed])
        #expect(factory.probes.count == 1)
    }

    @Test func startBlockedByAnOpenPromptIsUndeterminedAndStopsItselfLater() async throws {
        let factory = ProbeFactory { FakeProbe(.tone, startDelay: 0.6) }
        let access = SystemAudioAccess(timing: fastTiming(), makeProbe: factory.make)
        let began = ContinuousClock.now
        let report = await access.check()
        #expect(ContinuousClock.now - began < .milliseconds(550))
        #expect(report.state == .undetermined && report.startSeconds == nil)
        #expect(report.detail?.contains("did not finish") == true)
        let probe = try #require(factory.probes.first)
        for _ in 0..<200 where probe.counts.stops == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(probe.counts.stops == 1 && !probe.counts.running)
        #expect(await !access.isAllowed)
    }

    @Test func failedStartIsUndeterminedWithItsReason() async {
        let error = AudioCaptureError(source: .system, operation: "Cannot play the access check tone", status: nil)
        let factory = ProbeFactory { FakeProbe(.tone, startError: error) }
        let report = await SystemAudioAccess(timing: fastTiming(), makeProbe: factory.make).check()
        #expect(report.state == .undetermined)
        #expect(report.detail?.contains("access check tone") == true)
    }

    @Test func hungTeardownKeepsTheResultAndIsReported() async {
        let factory = ProbeFactory { FakeProbe(.tone, stopDelay: 0.6) }
        let report = await SystemAudioAccess(timing: fastTiming(), makeProbe: factory.make).check()
        #expect(report.state == .allowed && report.teardownTimedOut)
    }
}
