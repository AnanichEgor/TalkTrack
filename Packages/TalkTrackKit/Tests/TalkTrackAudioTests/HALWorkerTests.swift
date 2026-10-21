import Foundation
import Testing
@testable import TalkTrackAudio

/// A gate a worker call blocks on, like a HAL call waiting for a privacy prompt.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open() { semaphore.signal() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite struct HALWorkerTests {
    @Test func returnsValuesAndErrorsOffTheCallerThread() async throws {
        let worker = HALWorker()
        let thread = try await worker.run("Read", timeout: .seconds(2)) { Thread.current.name }
        #expect(thread == "local.talktrack.hal")
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            try await worker.run("Fail", timeout: .seconds(2)) { throw Failure() }
        }
        #expect(worker.hungOperation == nil)
    }

    @Test func hungCallTimesOutAndRefusesLaterCallsUntilItReturns() async throws {
        let worker = HALWorker(), gate = Gate()
        let started = ContinuousClock.now
        await #expect(throws: HALWorkerError.timedOut(operation: "Start system tap", seconds: 0.1)) {
            try await worker.run("Start system tap", timeout: .milliseconds(100)) { gate.wait() }
        }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(worker.hungOperation == "Start system tap")
        await #expect(throws: HALWorkerError.busy(hungOperation: "Start system tap")) {
            try await worker.run("Stop system tap", timeout: .seconds(1)) {}
        }

        gate.open()
        for _ in 0..<200 where worker.hungOperation != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(worker.hungOperation == nil)
        #expect(try await worker.run("Stop system tap", timeout: .seconds(1)) { 7 } == 7)
    }

    @Test func callQueuedBehindAHungCallNeverRunsAfterItsTimeout() async throws {
        let worker = HALWorker(), gate = Gate(), ran = Counter()
        async let first: Void = worker.run("Start", timeout: .seconds(5)) { gate.wait() }
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: HALWorkerError.timedOut(operation: "Queued", seconds: 0.1)) {
            try await worker.run("Queued", timeout: .milliseconds(100)) { ran.increment() }
        }
        gate.open()
        try await first
        _ = try await worker.run("After", timeout: .seconds(1)) {}
        #expect(ran.count == 0)
        #expect(worker.hungOperation == nil)
    }

    @Test func callFinishingJustBeforeItsTimeoutSucceeds() async throws {
        let worker = HALWorker()
        for _ in 0..<20 {
            let value = try await worker.run("Quick", timeout: .milliseconds(20)) { 1 }
            #expect(value == 1)
        }
        #expect(worker.hungOperation == nil)
    }
}
