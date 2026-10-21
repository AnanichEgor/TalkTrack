import Foundation

public enum InferenceSchedulingError: Error, Equatable {
    case captureAlreadyRequested, invalidCaptureLease
    case interactiveAlreadyRequested, invalidInteractiveLease
    /// Interactive work (dictation) is refused while a meeting is captured.
    case captureActive
}

/// One serial lane for heavy model work. Operations must await GPU completion
/// and release per-operation model capabilities before returning, including
/// cancellation. The app runtime may retain its small live cohort for an active
/// capture lease; it joins that cohort's unloading before endCapture admission.
///
/// An interactive lease (dictation) preempts background work without failing
/// it: the active background operation is cancelled and queued again at the
/// head, so its caller only waits longer and at most one model call repeats.
public actor InferenceScheduler {
    public struct CaptureLease: Sendable, Equatable {
        fileprivate let id: UUID
    }
    public struct InteractiveLease: Sendable, Equatable {
        fileprivate let id: UUID
    }
    public enum Priority: Sendable, Equatable {
        case background
        case capture(CaptureLease)
        case interactive(InteractiveLease)
    }
    private struct Pending {
        let id: UUID
        let priority: Priority
        let start: @Sendable () -> Task<Void, Never>
        let cancel: @Sendable () -> Void
    }
    private var queue: [Pending] = []
    private var active: (pending: Pending, task: Task<Void, Never>)?
    /// Active background operations this scheduler cancelled to restart later.
    private var preempted: Set<UUID> = []
    private var capture: CaptureLease?
    private var interactive: InteractiveLease?
    private var captureWaiter: CheckedContinuation<CaptureLease, any Error>?

    public init() {}

    public func run<T: Sendable>(priority: Priority = .background,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        let value: T = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if case .capture(let lease) = priority, capture != lease {
                throw InferenceSchedulingError.invalidCaptureLease
            }
            if case .interactive(let lease) = priority, interactive != lease {
                throw InferenceSchedulingError.invalidInteractiveLease
            }
            return try await withCheckedThrowingContinuation { continuation in
                queue.append(Pending(id: id, priority: priority, start: {
                    Task {
                        let result: Result<T, any Error>
                        do {
                            try Task.checkCancellation()
                            result = .success(try await operation())
                        } catch { result = .failure(error) }
                        switch await self.finished(id, failed: (try? result.get()) == nil, cancelled: Task.isCancelled) {
                        case .deliver: continuation.resume(with: result)
                        case .cancelled: continuation.resume(throwing: CancellationError())
                        case .restart: break
                        }
                    }
                }, cancel: { continuation.resume(throwing: CancellationError()) }))
                pump()
            }
        } onCancel: { Task { await self.cancel(id) } }
        try Task.checkCancellation()
        return value
    }

    /// Stops admitting background work immediately and waits for the active
    /// operation's cancellation cleanup. Audio writers need not await this;
    /// only live inference requires the returned lease.
    public func beginCapture() async throws -> CaptureLease {
        guard capture == nil else { throw InferenceSchedulingError.captureAlreadyRequested }
        // A meeting starting during dictation ends the dictation's lease.
        if let interactive { try? endInteractive(interactive) }
        // Capture keeps its meaning: the active operation's caller sees the cancellation.
        preempted.removeAll()
        let lease = CaptureLease(id: UUID())
        capture = lease
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if active == nil { return lease }
            return try await withCheckedThrowingContinuation { continuation in
                captureWaiter = continuation
                active?.task.cancel()
            }
        } onCancel: { Task { await self.cancelCapture(lease) } }
    }

    public func endCapture(_ lease: CaptureLease) throws {
        guard capture == lease else { throw InferenceSchedulingError.invalidCaptureLease }
        capture = nil
        captureWaiter?.resume(throwing: CancellationError())
        captureWaiter = nil
        // Never admit a stale live request after capture has ended.
        let stale = queue.filter { $0.priority == .capture(lease) }
        queue.removeAll { $0.priority == .capture(lease) }
        stale.forEach { $0.cancel() }
        if active?.pending.priority == .capture(lease) { active?.task.cancel() }
        pump()
    }

    /// Admits only this lease's operations until it ends. The active
    /// background operation is restarted afterwards, never failed. Returns at
    /// once; the lease's first operation runs when the lane is free.
    public func beginInteractive() throws -> InteractiveLease {
        guard capture == nil else { throw InferenceSchedulingError.captureActive }
        guard interactive == nil else { throw InferenceSchedulingError.interactiveAlreadyRequested }
        let lease = InteractiveLease(id: UUID())
        interactive = lease
        if let active, active.pending.priority == .background {
            preempted.insert(active.pending.id)
            active.task.cancel()
        }
        return lease
    }

    public func endInteractive(_ lease: InteractiveLease) throws {
        guard interactive == lease else { throw InferenceSchedulingError.invalidInteractiveLease }
        interactive = nil
        let stale = queue.filter { $0.priority == .interactive(lease) }
        queue.removeAll { $0.priority == .interactive(lease) }
        stale.forEach { $0.cancel() }
        if active?.pending.priority == .interactive(lease) { active?.task.cancel() }
        pump()
    }

    public var hasInteractiveLease: Bool { interactive != nil }

    private func cancelCapture(_ lease: CaptureLease) {
        guard capture == lease else { return }
        try? endCapture(lease)
    }

    private func cancel(_ id: UUID) {
        if active?.pending.id == id {
            // The caller's own cancellation is final, not a restart.
            preempted.remove(id)
            active?.task.cancel()
            return
        }
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).cancel()
        }
    }

    private enum Outcome { case deliver, cancelled, restart }

    /// What the caller receives. A preempted operation that failed (normally
    /// by the cancellation) is queued again at the head instead; one that
    /// finished anyway keeps its result. Other cancelled successes are dropped.
    private func finished(_ id: UUID, failed: Bool, cancelled: Bool) -> Outcome {
        let outcome: Outcome
        if preempted.remove(id) != nil { outcome = failed ? .restart : .deliver }
        else { outcome = cancelled && !failed ? .cancelled : .deliver }
        guard let current = active, current.pending.id == id else { return outcome }
        active = nil
        if outcome == .restart { queue.insert(current.pending, at: 0) }
        if let waiter = captureWaiter, let lease = capture {
            captureWaiter = nil
            waiter.resume(returning: lease)
        }
        pump()
        return outcome
    }

    private func pump() {
        guard active == nil else { return }
        let index: Int?
        if let capture {
            index = queue.firstIndex { $0.priority == .capture(capture) }
        } else if let interactive {
            index = queue.firstIndex { $0.priority == .interactive(interactive) }
        } else { index = queue.isEmpty ? nil : 0 }
        guard let index else { return }
        let next = queue.remove(at: index)
        active = (next, next.start())
    }
}
