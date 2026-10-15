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
}
