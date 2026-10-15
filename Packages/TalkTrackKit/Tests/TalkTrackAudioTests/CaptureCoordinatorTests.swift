import Foundation
import Testing
@testable import TalkTrackAudio

private actor CaptureLatch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let all = waiters; waiters = []; all.forEach { $0.resume() } }
}

private actor FakeCapture {
    let source: CaptureSource
    let startupGate: CaptureLatch?
    let stopGate: CaptureLatch?
    var shouldFail: Bool
    private(set) var starts = 0
    private(set) var entered = false
    private(set) var active = false
    private(set) var stops = 0
    private var sinks: [@Sendable (AudioPacket) -> Void] = []
    private var failures: [@Sendable (AudioCaptureError) -> Void] = []

    init(_ source: CaptureSource, startupGate: CaptureLatch? = nil,
         stopGate: CaptureLatch? = nil, fail: Bool = false) {
        self.source = source; self.startupGate = startupGate; self.stopGate = stopGate; shouldFail = fail
    }
    nonisolated func driver() -> CaptureDriver {
        CaptureDriver(source: source, start: { try await self.start($0, $1) }, stop: { await self.stop() })
    }
    private func start(_ receive: @escaping @Sendable (AudioPacket) -> Void,
                       _ failure: @escaping @Sendable (AudioCaptureError) -> Void) async throws {
        entered = true; starts += 1
        await startupGate?.wait() // Deliberately ignores cancellation, like a stalled native call.
        if shouldFail { throw AudioCaptureError(source: source, operation: "Injected startup failure", status: nil) }
        active = true; sinks.append(receive); failures.append(failure)
    }
    private func stop() async { await stopGate?.wait(); active = false; stops += 1 }
    func emit(run: Int) {
        sinks[run](AudioPacket(source: source, sampleRate: 48000, hostTime: 1, sampleTime: 0, samples: [0]))
    }
    func fail(run: Int) {
        failures[run](AudioCaptureError(source: source, operation: "Device disappeared", status: nil))
    }
    func routeChange(run: Int) {
        failures[run](AudioCaptureError(source: source, operation: "Route changed", status: nil, restartable: true))
    }
    func failNextStart() { shouldFail = true }
}

private final class PacketCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func append(_ packet: AudioPacket) { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private actor RetryCleanupCapture {
    private(set) var active = false
    private(set) var stops = 0
    private var receive: (@Sendable (AudioPacket) -> Void)?
    nonisolated func driver() -> CaptureDriver {
        CaptureDriver(source: .system, start: { receive, _ in await self.start(receive) },
                      stop: { try await self.stop() })
    }
    private func start(_ receive: @escaping @Sendable (AudioPacket) -> Void) { active = true; self.receive = receive }
    private func stop() throws {
        stops += 1
        if stops == 1 { throw AudioCaptureError(source: .system, operation: "Injected cleanup failure; retry Stop", status: -1) }
        // Represents the final packet drained by a native driver's worker.
        receive?(AudioPacket(source: .system, sampleRate: 48000, hostTime: 2, sampleTime: 1, samples: [1]))
        active = false
    }
}

private actor FinalPacketDriver {
    private var receive: (@Sendable (AudioPacket) -> Void)?
    nonisolated func driver() -> CaptureDriver {
        CaptureDriver(source: .system, start: { receive, _ in await self.set(receive) }, stop: { await self.emit() })
    }
    private func set(_ receive: @escaping @Sendable (AudioPacket) -> Void) { self.receive = receive }
    func emit() { receive?(AudioPacket(source: .system, sampleRate: 48000, hostTime: 1, sampleTime: 0, samples: [0])) }
}

private final class RestartLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ source: CaptureSource, _ reason: String) { lock.withLock { items.append("\(source.rawValue): \(reason)") } }
    var values: [String] { lock.withLock { items } }
}

private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock(), limit = clock.now.advanced(by: .seconds(3))
    while !(await condition()) {
        guard clock.now < limit else { Issue.record("Timed out waiting for capture state"); throw CancellationError() }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@Suite struct CaptureCoordinatorTests {
    @Test func failedCleanupIsVisibleBlocksRestartAndCanBeRetried() async throws {
        let mic = FakeCapture(.microphone), system = RetryCleanupCapture(), packets = PacketCount()
        let coordinator = CaptureCoordinator(microphone: mic.driver(), system: system.driver(), receive: packets.append)
        try await coordinator.start()
        await coordinator.stop()
        #expect(await coordinator.phase == .failed)
        #expect(await coordinator.lastError?.operation.contains("cleanup failure") == true)
        #expect(await system.active)
        do { try await coordinator.start(); Issue.record("Restart accepted while cleanup was incomplete") }
        catch is AudioCaptureError { }
        await coordinator.stop()
        #expect(await coordinator.phase == .idle)
        #expect(await system.active == false)
        #expect(await system.stops == 2)
    }

    @Test func stopDrainsAcceptedPacketsBeforeClosingTheRunGate() async throws {
        let mic = FakeCapture(.microphone), count = PacketCount()
        // Use an injected driver whose Stop drains through the supplied sink.
        let log = FinalPacketDriver()
        let coordinator = CaptureCoordinator(microphone: mic.driver(), system: log.driver(), receive: count.append)
        try await coordinator.start()
        await coordinator.stop()
        #expect(count.value == 1)
        await log.emit()
        #expect(count.value == 1)
    }
    @Test func partialStartupFailureStopsBothSources() async throws {
        let gate = CaptureLatch(), mic = FakeCapture(.microphone, startupGate: nil)
        let system = FakeCapture(.system, startupGate: gate, fail: true)
        let coordinator = CaptureCoordinator(microphone: mic.driver(), system: system.driver(), receive: { _ in })
        let start = Task { try await coordinator.start() }
        try await eventually { await mic.active }
        #expect(await coordinator.phase == .preparing)
        await gate.release()
        do { try await start.value; Issue.record("Expected failure") }
        catch let error as AudioCaptureError { #expect(error.source == .system) }
        try await eventually { await coordinator.phase == .failed }
        #expect(await mic.active == false); #expect(await system.active == false)
        #expect(await mic.stops == 1); #expect(await system.stops == 1)
    }

    @Test func timeoutReportsPromptlyAndRetiresOtherTrackBeforeStalledStart() async throws {
        let gate = CaptureLatch(), mic = FakeCapture(.microphone, startupGate: nil)
        let system = FakeCapture(.system, startupGate: gate)
        let coordinator = CaptureCoordinator(microphone: mic.driver(), system: system.driver(), receive: { _ in })
        do { try await coordinator.start(timeout: .milliseconds(40)); Issue.record("Expected timeout") }
        catch let error as AudioCaptureError { #expect(error.source == .system); #expect(error.operation.contains("timed out")) }
        #expect(await coordinator.phase == .stopping)
        try await eventually { await mic.stops == 1 }
        #expect(await system.stops == 0)
        do { try await coordinator.start(); Issue.record("Overlapping start accepted") } catch is AudioCaptureError { }
        await gate.release()
        try await eventually { await coordinator.phase == .failed }
        #expect(await system.active == false); #expect(await system.stops == 1)
    }

    @Test func rapidStopJoinsLateStartAndConcurrentStopsShareCleanup() async throws {
        let gate = CaptureLatch(), mic = FakeCapture(.microphone, startupGate: nil)
        let system = FakeCapture(.system, startupGate: gate)
        let coordinator = CaptureCoordinator(microphone: mic.driver(), system: system.driver(), receive: { _ in })
        let start = Task { try await coordinator.start() }
        try await eventually { await system.entered }
        let first = Task { await coordinator.stop() }
        try await eventually { await coordinator.phase == .stopping }
        let second = Task { await coordinator.stop() }
        do { try await start.value; Issue.record("Expected cancellation") } catch is CancellationError { }
        await gate.release()
        await first.value; await second.value
        #expect(await coordinator.phase == .idle)
        #expect(await system.active == false); #expect(await mic.active == false)
        #expect(await system.stops == 1); #expect(await mic.stops == 1)
    }

    @Test func callerCancellationCannotStartHiddenCaptureLater() async throws {
        let gate = CaptureLatch(), mic = FakeCapture(.microphone, startupGate: gate)
        let system = FakeCapture(.system)
        let coordinator = CaptureCoordinator(microphone: mic.driver(), system: system.driver(), receive: { _ in })
        let start = Task { try await coordinator.start() }
        try await eventually { await mic.entered }
        start.cancel()
        do { try await start.value; Issue.record("Expected cancellation") } catch is CancellationError { }
        try await eventually { await coordinator.phase == .stopping }
        await gate.release()
        await coordinator.stop()
        #expect(await mic.active == false); #expect(await system.active == false)
    }

    @Test func routeChangeRestartsOnlyThatSourceAndKeepsRecording() async throws {
        let mic = FakeCapture(.microphone), system = FakeCapture(.system), packets = PacketCount()
        let notes = RestartLog()
        let coordinator = CaptureCoordinator(microphone: mic.driver(), system: system.driver(), restartLimit: 2,
                                             receive: packets.append, restarted: notes.add)
        try await coordinator.start()
        await mic.routeChange(run: 0)
        try await eventually {
            let counts = await coordinator.restartCounts
            return await mic.starts == 2 && counts[.microphone] == 1
        }
        try await eventually { await mic.active }
        #expect(await coordinator.phase == .recording)
        #expect(await mic.stops == 1); #expect(await system.stops == 0); #expect(await system.starts == 1)
        #expect(notes.values == ["microphone: Route changed"])
        // The new run delivers through the same recording gate.
        await mic.emit(run: 1); await system.emit(run: 0)
        #expect(packets.value == 2)
        // A second route change restarts again within the limit.
        await mic.routeChange(run: 1)
        try await eventually { await mic.starts == 3 }
        try await eventually { await mic.active }
        // Exceeding the limit fails the recording and stops both sources.
        await mic.routeChange(run: 2)
        try await eventually { await coordinator.phase == .failed }
        #expect(await coordinator.lastError?.operation == "Route changed")
        #expect(await mic.active == false); #expect(await system.active == false)
        await coordinator.stop()
        // A new run resets the restart budget.
        try await coordinator.start()
        #expect(await coordinator.restartCounts.isEmpty)
        await coordinator.stop()
    }

    @Test func restartsSpreadOverTimeStayWithinTheBudget() async throws {
        let mic = FakeCapture(.microphone), system = FakeCapture(.system)
        let coordinator = CaptureCoordinator(microphone: mic.driver(), system: system.driver(), restartLimit: 1,
                                             restartWindow: .milliseconds(50), receive: { _ in })
        try await coordinator.start()
        for run in 0..<3 {
            await mic.routeChange(run: run)
            try await eventually { await mic.starts == run + 2 }
            try await eventually { await mic.active }
            try await Task.sleep(for: .milliseconds(80))
        }
        #expect(await coordinator.phase == .recording)
        #expect(await coordinator.restartCounts[.microphone] == 3)
        await coordinator.stop()
    }

    @Test func failedRestartFailsRecordingAndPauseJoinsRestart() async throws {
        let gate = CaptureLatch(), mic = FakeCapture(.microphone), system = FakeCapture(.system)
        let coordinator = CaptureCoordinator(microphone: mic.driver(), system: system.driver(), receive: { _ in })
        try await coordinator.start()
        await mic.failNextStart()
        await mic.routeChange(run: 0)
        try await eventually { await coordinator.phase == .failed }
        #expect(await coordinator.lastError?.source == .microphone)
        #expect(await coordinator.lastError?.operation.contains("Cannot restart after a device change") == true)
        #expect(await system.active == false)
        await coordinator.stop()

        let slow = FakeCapture(.microphone, startupGate: gate), other = FakeCapture(.system)
        let second = CaptureCoordinator(microphone: slow.driver(), system: other.driver(), receive: { _ in })
        let start = Task { try await second.start() }
        await gate.release(); try await start.value
        // Pause during a restart waits for it, then stops the restarted driver.
        await slow.routeChange(run: 0)
        try await second.pause()
        #expect(await second.phase == .paused)
        #expect(await slow.active == false); #expect(await other.active == false)
    }

    @Test func pauseResumeRejectsLatePacketsAndStaleFailures() async throws {
        let mic = FakeCapture(.microphone), system = FakeCapture(.system), packets = PacketCount()
        let coordinator = CaptureCoordinator(microphone: mic.driver(), system: system.driver(), receive: packets.append)
        try await coordinator.start()
        await mic.emit(run: 0); await system.emit(run: 0)
        #expect(packets.value == 2)
        try await coordinator.pause()
        #expect(await coordinator.phase == .paused)
        #expect(await mic.active == false); #expect(await system.active == false)
        await mic.emit(run: 0)
        #expect(packets.value == 2)
        try await coordinator.start()
        await mic.emit(run: 0); await mic.fail(run: 0)
        await mic.emit(run: 1)
        #expect(packets.value == 3)
        #expect(await coordinator.phase == .recording)
        await system.fail(run: 1)
        try await eventually { await coordinator.phase == .failed }
        #expect(await coordinator.lastError?.source == .system)
        #expect(await mic.active == false); #expect(await system.active == false)
        await coordinator.stop(); await coordinator.stop()
        #expect(await coordinator.phase == .idle)
    }

    @Test func stoppingStateLastsUntilDriverCleanupCompletes() async throws {
        let gate = CaptureLatch(), mic = FakeCapture(.microphone, stopGate: gate)
        let system = FakeCapture(.system)
        let coordinator = CaptureCoordinator(microphone: mic.driver(), system: system.driver(), receive: { _ in })
        try await coordinator.start()
        let pause = Task { try await coordinator.pause() }
        try await eventually { await coordinator.phase == .stopping }
        let stop = Task { await coordinator.stop() }
        try await eventually { await system.stops == 1 }
        #expect(await mic.active)
        await gate.release()
        try await pause.value; await stop.value
        #expect(await coordinator.phase == .idle)
        #expect(await mic.stops == 1)
    }

    @Test func permissionReplyIgnoresLateAnswersAndCancellationBeforeWait() async throws {
        let reply = CaptureReply<Bool>()
        reply.resolve(.failure(CancellationError()))
        reply.resolve(.success(true))
        do { _ = try await reply.value(); Issue.record("Late permission answer won") }
        catch is CancellationError { }
        let normal = CaptureReply<Bool>()
        let waiter = Task { try await normal.value() }
        normal.resolve(.success(false)); normal.resolve(.success(true))
        #expect(try await waiter.value == false)
    }
}
