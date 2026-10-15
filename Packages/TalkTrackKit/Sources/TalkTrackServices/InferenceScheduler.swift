import Foundation

public enum InferenceSchedulingError: Error, Equatable {
    case captureAlreadyRequested, invalidCaptureLease
}

/// One serial lane for heavy model work. Operations must await GPU completion
/// and release per-operation model capabilities before returning, including
/// cancellation. The app runtime may retain its small live cohort for an active
/// capture lease; it joins that cohort's unloading before endCapture admission.
public actor InferenceScheduler {
    public struct CaptureLease: Sendable, Equatable {
        fileprivate let id: UUID
    }
    public enum Priority: Sendable, Equatable {
        case background
        case capture(CaptureLease)
    }
    private struct Pending {
        let id: UUID
        let priority: Priority
        let start: @Sendable () -> Task<Void, Never>
        let cancel: @Sendable () -> Void
    }
    private var queue: [Pending] = []
    private var active: (id: UUID, priority: Priority, task: Task<Void, Never>)?
    private var capture: CaptureLease?
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
            return try await withCheckedThrowingContinuation { continuation in
                queue.append(Pending(id: id, priority: priority, start: {
                    Task {
                        let result: Result<T, any Error>
                        do {
                            try Task.checkCancellation()
                            let value = try await operation()
                            try Task.checkCancellation()
                            result = .success(value)
                        } catch { result = .failure(error) }
                        await self.finished(id)
                        continuation.resume(with: result)
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
        if active?.priority == .capture(lease) { active?.task.cancel() }
        pump()
    }

    private func cancelCapture(_ lease: CaptureLease) {
        guard capture == lease else { return }
        try? endCapture(lease)
    }

    private func cancel(_ id: UUID) {
        if active?.id == id { active?.task.cancel(); return }
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).cancel()
        }
    }

    private func finished(_ id: UUID) {
        guard active?.id == id else { return }
        active = nil
        if let waiter = captureWaiter, let lease = capture {
            captureWaiter = nil
            waiter.resume(returning: lease)
        }
        pump()
    }

    private func pump() {
        guard active == nil else { return }
        let index: Int?
        if let capture {
            index = queue.firstIndex { $0.priority == .capture(capture) }
        } else { index = queue.isEmpty ? nil : 0 }
        guard let index else { return }
        let next = queue.remove(at: index)
        active = (next.id, next.priority, next.start())
    }
}
