import Foundation

/// A HAL call that did not return in time, or a worker still stuck in one.
public enum HALWorkerError: Error, LocalizedError, Equatable, Sendable {
    /// The call is abandoned; the worker thread may still be running it.
    case timedOut(operation: String, seconds: Double)
    /// An earlier call is still hung; the worker refuses new work until it returns.
    case busy(hungOperation: String)

    public var errorDescription: String? {
        switch self {
        case let .timedOut(operation, seconds):
            "\(operation) did not finish within \(seconds.formatted(.number.precision(.fractionLength(0...1)))) s"
        case let .busy(operation):
            "\(operation) has not returned yet; restart TalkTrack if this persists"
        }
    }
}

/// Runs blocking Core Audio HAL calls on one dedicated thread (design D2). An
/// unanswered privacy prompt can block `AudioDeviceStart` for ~30 s and hang
/// teardown, so callers await each call with a timeout instead of occupying an
/// actor's executor. A call that times out is abandoned: its objects stay with
/// the worker, and the worker refuses new calls until that call has returned.
/// Calls queued behind a hung call that time out before starting never run.
public final class HALWorker: @unchecked Sendable {
    private let state: State

    public init(name: String = "local.talktrack.hal") {
        state = State()
        let thread = Thread { [state] in state.loop() }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit { state.close() }

    /// The operation a timed-out call is still blocked in, if any.
    public var hungOperation: String? { state.hungOperation }

    public func run<T: Sendable>(_ operation: String, timeout: Duration,
                                 _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let reply = CaptureReply<T>()
        let token = try state.submit(operation) { reply.resolve(Result { try body() }) }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let timer = Task.detached { [state] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, state.abandon(token) else { return }
            reply.resolve(.failure(HALWorkerError.timedOut(operation: operation, seconds: seconds)))
        }
        defer { timer.cancel() }
        return try await reply.value()
    }

    private final class State: @unchecked Sendable {
        private struct Job { let token: UUID; let operation: String; let body: () -> Void }
        private let condition = NSCondition()
        private var queue: [Job] = []
        private var running: (token: UUID, operation: String)?
        private var hung: (token: UUID, operation: String)?
        private var closed = false

        var hungOperation: String? { condition.withLock { hung?.operation } }

        func submit(_ operation: String, _ body: @escaping () -> Void) throws -> UUID {
            try condition.withLock {
                if let hung { throw HALWorkerError.busy(hungOperation: hung.operation) }
                let token = UUID()
                queue.append(Job(token: token, operation: operation, body: body))
                condition.signal()
                return token
            }
        }

        /// Returns false when the call already finished; its reply is then resolved.
        func abandon(_ token: UUID) -> Bool {
            condition.withLock {
                if let index = queue.firstIndex(where: { $0.token == token }) {
                    queue.remove(at: index); return true
                }
                guard let running, running.token == token else { return false }
                if hung == nil { hung = running }
                return true
            }
        }

        func close() { condition.withLock { closed = true; condition.signal() } }

        func loop() {
            while true {
                condition.lock()
                while queue.isEmpty && !closed { condition.wait() }
                if queue.isEmpty { condition.unlock(); return }
                let job = queue.removeFirst()
                running = (job.token, job.operation)
                condition.unlock()
                job.body()
                condition.withLock {
                    running = nil
                    if hung?.token == job.token { hung = nil }
                }
            }
        }
    }
}
