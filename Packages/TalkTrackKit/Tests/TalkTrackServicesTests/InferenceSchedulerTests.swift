import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

private actor SchedulerGate {
    var opened = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let all = waiters; waiters = []; all.forEach { $0.resume() } }
}
private actor SchedulerEvents {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

@Suite struct InferenceSchedulerTests {
    @Test func captureWaitsForCleanupAndDefersBackground() async throws {
        let scheduler = InferenceScheduler(), started = SchedulerGate(), cleanup = SchedulerGate()
        let events = SchedulerEvents()
        let text = Task {
            try await scheduler.run {
                await events.add("text loaded")
                await started.open()
                do { try await Task.sleep(for: .seconds(30)) }
                catch {
                    await events.add("cancel observed")
                    await cleanup.wait()
                    await events.add("model unloaded")
                    throw error
                }
            }
        }
        await started.wait()
        let capture = Task { try await scheduler.beginCapture() }
        // Let cancellation arrive; cleanup remains deliberately suspended.
        while !(await events.values.contains("cancel observed")) { await Task.yield() }
        let background = Task { try await scheduler.run { await events.add("background") } }
        #expect(await events.values == ["text loaded", "cancel observed"])
        await cleanup.open()
        let lease = try await capture.value
        do { try await text.value; Issue.record("Expected cancellation") } catch is CancellationError { }
        try await scheduler.run(priority: .capture(lease)) { await events.add("live") }
        #expect(await events.values == ["text loaded", "cancel observed", "model unloaded", "live"])
        try await scheduler.endCapture(lease)
        try await background.value
        #expect(await events.values.last == "background")
    }

    @Test func cancelledQueuedWorkNeverRunsAndFailureReleasesLane() async throws {
        let scheduler = InferenceScheduler(), started = SchedulerGate(), release = SchedulerGate()
        let first = Task { try await scheduler.run { await started.open(); await release.wait() } }
        await started.wait()
        let cancelled = Task { try await scheduler.run { _ = Issue.record("Cancelled queued operation ran") } }
        cancelled.cancel()
        do { try await cancelled.value; Issue.record("Expected cancellation") } catch is CancellationError { }
        await release.open()
        try await first.value
        do { try await scheduler.run { throw CocoaError(.fileReadUnknown) } }
        catch is CocoaError { }
        #expect(try await scheduler.run { 42 } == 42)
    }

    @Test func snapshotIsFrozenAndMaintenanceWaitsForModelRelease() async throws {
        let scheduler = InferenceScheduler(), started = SchedulerGate(), release = SchedulerGate()
        let events = SchedulerEvents()
        var settings = ProcessingSettings(summaryLanguage: .russian)
        let snapshot = settings
        let work = Task { try await scheduler.run { [snapshot] in
            await events.add("acquire")
            await started.open()
            await release.wait()
            #expect(snapshot.summaryLanguage == .russian)
            await events.add("release")
        } }
        await started.wait()
        settings.summaryLanguage = .english
        let deletion = Task { try await scheduler.run { await events.add("delete") } }
        #expect(await events.values == ["acquire"])
        await release.open()
        try await work.value; try await deletion.value
        #expect(await events.values == ["acquire", "release", "delete"])
        #expect(settings.summaryLanguage == .english)
    }

    @Test func endedCaptureLeaseCannotSubmitAndCancellationRestoresQueue() async throws {
        let scheduler = InferenceScheduler()
        let lease = try await scheduler.beginCapture()
        do { _ = try await scheduler.beginCapture(); Issue.record("Duplicate capture") }
        catch InferenceSchedulingError.captureAlreadyRequested { }
        try await scheduler.endCapture(lease)
        do { try await scheduler.run(priority: .capture(lease)) {}; Issue.record("Stale lease") }
        catch InferenceSchedulingError.invalidCaptureLease { }
        #expect(try await scheduler.run { 7 } == 7)
    }

    @Test func interactiveLeaseRestartsBackgroundWithoutFailingIt() async throws {
        let scheduler = InferenceScheduler(), started = SchedulerGate(), events = SchedulerEvents()
        let attempts = SchedulerEvents()
        let summary = Task {
            try await scheduler.run { () -> String in
                await attempts.add("attempt")
                if await attempts.values.count == 1 {
                    await started.open()
                    try await Task.sleep(for: .seconds(30))
                }
                await events.add("summary done")
                return "summary"
            }
        }
        await started.wait()
        let lease = try await scheduler.beginInteractive()
        let queuedBackground = Task { try await scheduler.run { await events.add("other background") } }
        try await scheduler.run(priority: .interactive(lease)) { await events.add("dictation") }
        #expect(await events.values == ["dictation"])
        try await scheduler.endInteractive(lease)
        // The preempted step runs again first and its caller gets the result.
        #expect(try await summary.value == "summary")
        try await queuedBackground.value
        #expect(await events.values == ["dictation", "summary done", "other background"])
        #expect(await attempts.values.count == 2)
    }

    @Test func preemptedSuccessIsDeliveredOnce() async throws {
        let scheduler = InferenceScheduler(), started = SchedulerGate(), release = SchedulerGate()
        let attempts = SchedulerEvents()
        // An operation that ignores cancellation and succeeds is not repeated.
        let work = Task { try await scheduler.run { () -> Int in
            await attempts.add("attempt"); await started.open(); await release.wait(); return 1
        } }
        await started.wait()
        let lease = try await scheduler.beginInteractive()
        await release.open()
        #expect(try await work.value == 1)
        try await scheduler.endInteractive(lease)
        #expect(await attempts.values.count == 1)
    }

    @Test func callerCancellationOfPreemptedWorkIsFinal() async throws {
        let scheduler = InferenceScheduler(), started = SchedulerGate()
        let work = Task { try await scheduler.run { await started.open(); try await Task.sleep(for: .seconds(30)) } }
        await started.wait()
        let lease = try await scheduler.beginInteractive()
        work.cancel()
        do { try await work.value; Issue.record("Expected cancellation") } catch is CancellationError { }
        try await scheduler.endInteractive(lease)
        #expect(try await scheduler.run { 3 } == 3)
    }

    @Test func interactiveIsRefusedDuringCaptureAndEndedByCapture() async throws {
        let scheduler = InferenceScheduler()
        let capture = try await scheduler.beginCapture()
        await #expect(throws: InferenceSchedulingError.captureActive) { try await scheduler.beginInteractive() }
        try await scheduler.endCapture(capture)

        let lease = try await scheduler.beginInteractive()
        await #expect(throws: InferenceSchedulingError.interactiveAlreadyRequested) { try await scheduler.beginInteractive() }
        let meeting = try await scheduler.beginCapture()
        #expect(await !scheduler.hasInteractiveLease)
        do { try await scheduler.run(priority: .interactive(lease)) {}; Issue.record("Stale lease") }
        catch InferenceSchedulingError.invalidInteractiveLease { }
        await #expect(throws: InferenceSchedulingError.invalidInteractiveLease) { try await scheduler.endInteractive(lease) }
        try await scheduler.endCapture(meeting)
    }

    @Test func captureDuringInteractiveCancelsItsWork() async throws {
        let scheduler = InferenceScheduler(), started = SchedulerGate()
        let lease = try await scheduler.beginInteractive()
        let dictation = Task { try await scheduler.run(priority: .interactive(lease)) {
            await started.open(); try await Task.sleep(for: .seconds(30))
        } }
        await started.wait()
        let meeting = try await scheduler.beginCapture()
        do { try await dictation.value; Issue.record("Expected cancellation") } catch is CancellationError { }
        try await scheduler.run(priority: .capture(meeting)) {}
        try await scheduler.endCapture(meeting)
    }

    @Test func captureStillInterruptsBackgroundPreemptedByDictation() async throws {
        let scheduler = InferenceScheduler(), started = SchedulerGate()
        let work = Task { try await scheduler.run { await started.open(); try await Task.sleep(for: .seconds(30)) } }
        await started.wait()
        _ = try await scheduler.beginInteractive()
        let meeting = try await scheduler.beginCapture()
        // The meeting path keeps its meaning: the running step's caller is cancelled.
        do { try await work.value; Issue.record("Expected cancellation") } catch is CancellationError { }
        try await scheduler.endCapture(meeting)
    }
}
