import Foundation

public enum CapturePhase: String, Sendable { case idle, preparing, recording, paused, stopping, failed }

/// A driver must serialize native operations. stop() must be idempotent and
/// return only after callbacks have quiesced. A late start is always joined.
public struct CaptureDriver: Sendable {
    public let source: CaptureSource
    public let start: @Sendable (@escaping @Sendable (AudioPacket) -> Void,
        @escaping @Sendable (AudioCaptureError) -> Void) async throws -> Void
    public let stop: @Sendable () async throws -> Void

    public init(source: CaptureSource,
        start: @escaping @Sendable (@escaping @Sendable (AudioPacket) -> Void,
            @escaping @Sendable (AudioCaptureError) -> Void) async throws -> Void,
        stop: @escaping @Sendable () async throws -> Void) {
        self.source = source; self.start = start; self.stop = stop
    }
}

/// Used for both permission and startup completion. Late replies after a
/// timeout/cancellation are harmless; no continuation is resumed twice.
final class CaptureReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var waiters: [CheckedContinuation<Value, Error>] = []

    func resolve(_ value: Result<Value, Error>) {
        let continuations = lock.withLock { () -> [CheckedContinuation<Value, Error>] in
            guard result == nil else { return [] }
            result = value
            defer { waiters = [] }
            return waiters
        }
        continuations.forEach { $0.resume(with: value) }
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock { () -> Result<Value, Error>? in
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

/// Owns both tracks' lifetime independently of inference. Startup failure is
/// reported promptly; the state remains stopping until even a stalled driver's
/// late start has returned and cleanup completed. A new run cannot overlap it.
public actor CaptureCoordinator {
    public private(set) var phase: CapturePhase = .idle
    public private(set) var lastError: AudioCaptureError?
    private let drivers: [CaptureDriver]
    private let receive: @Sendable (AudioPacket) -> Void
    private let restarted: (@Sendable (CaptureSource, String) -> Void)?
    private let stopped: (@Sendable (AudioCaptureError) -> Void)?
    private var reportStop = false
    private let restartLimit: Int
    private let restartWindow: Duration
    private var restarts: [CaptureSource: Int] = [:]
    private var recentRestarts: [CaptureSource: [ContinuousClock.Instant]] = [:]
    /// Restarts completed for each source in the current run (route changes).
    public var restartCounts: [CaptureSource: Int] { restarts }
    private var generation = UUID()
    private var starts: [Task<Void, Error>] = []
    private var pending: Set<CaptureSource> = []
    private var deadline: Task<Void, Never>?
    private var reply: CaptureReply<Void>?
    private var shutdown: Task<Void, Never>?
    private var destination: CapturePhase = .idle
    private var packetGate: CapturePacketGate?
    private var cleanupRequired = false

    /// `restarted` runs after a restartable source has stopped and drained its
    /// old packets, before it starts again: the sink can mark the discontinuity.
    /// One device switch can post several changes, so only more than
    /// `restartLimit` restarts within `restartWindow` count as a failing loop.
    /// `failed` reports a source lost during Recording after both drivers have
    /// stopped and drained, so the owner can finalize the recording.
    public init(microphone: CaptureDriver, system: CaptureDriver,
                restartLimit: Int = 5, restartWindow: Duration = .seconds(30),
                receive: @escaping @Sendable (AudioPacket) -> Void,
                restarted: (@Sendable (CaptureSource, String) -> Void)? = nil,
                failed: (@Sendable (AudioCaptureError) -> Void)? = nil) {
        precondition(microphone.source == .microphone && system.source == .system && restartLimit >= 0)
        drivers = [microphone, system]; self.receive = receive; stopped = failed
        self.restarted = restarted; self.restartLimit = restartLimit; self.restartWindow = restartWindow
    }

    public static func native(deviceID: UInt32? = nil,
                              receive: @escaping @Sendable (AudioPacket) -> Void,
                              restarted: (@Sendable (CaptureSource, String) -> Void)? = nil,
                              failed: (@Sendable (AudioCaptureError) -> Void)? = nil) -> CaptureCoordinator {
        native(microphone: { deviceID }, receive: receive, restarted: restarted, failed: failed)
    }

    /// `microphone` is resolved on every microphone start (first start, resume
    /// and route-change restarts), so a reconnected device gets its new ID.
    public static func native(microphone: @escaping @Sendable () throws -> UInt32?,
                              receive: @escaping @Sendable (AudioPacket) -> Void,
                              restarted: (@Sendable (CaptureSource, String) -> Void)? = nil,
                              failed: (@Sendable (AudioCaptureError) -> Void)? = nil) -> CaptureCoordinator {
        let capture = MicrophoneCapture(), system = SystemAudioCapture()
        return CaptureCoordinator(microphone: CaptureDriver(source: .microphone,
            start: { try await capture.start(deviceID: try microphone(), receive: $0, failure: $1) },
            stop: { await capture.stop() }), system: CaptureDriver(source: .system,
            start: { try await system.start(receive: $0, failure: $1) },
            stop: { try await system.stop() }), receive: receive, restarted: restarted, failed: failed)
    }

    /// Resume uses the same coordinator and a fresh run generation. The durable
    /// recording owner closes/reopens timing intervals around pause/resume.
    public func start(timeout: Duration = .seconds(20)) async throws {
        try Task.checkCancellation()
        guard !cleanupRequired, [.idle, .paused, .failed].contains(phase), timeout > .zero else {
            throw AudioCaptureError(source: .system, operation: "Capture cannot start in the current state", status: nil)
        }
        let run = UUID(), completion = CaptureReply<Void>()
        let gate = CapturePacketGate(receive: receive)
        packetGate = gate
        generation = run; reply = completion; lastError = nil; restarts = [:]; recentRestarts = [:]; reportStop = false
        phase = .preparing; pending = [.microphone, .system]
        starts = drivers.map { driver in
            Task.detached { [self] in
                do {
                    try Task.checkCancellation()
                    try await driver.start({ gate.receive($0) }, Self.failureHandler(self, run: run))
                    try Task.checkCancellation()
                    await self.started(run, source: driver.source)
                } catch {
                    await self.failed(run, error: error, source: driver.source)
                    throw error
                }
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.timedOut(run)
        }
        try await withTaskCancellationHandler {
            try await completion.value()
            try Task.checkCancellation()
        } onCancel: {
            completion.resolve(.failure(CancellationError()))
            Task { await self.cancel(run) }
        }
    }

    public func pause() async throws {
        guard phase == .recording else {
            throw AudioCaptureError(source: .system, operation: "Only an active recording can be paused", status: nil)
        }
        await beginShutdown(to: .paused).value
        if cleanupRequired, let lastError { throw lastError }
    }

    public func stop() async {
        guard phase != .idle else { return }
        await beginShutdown(to: .idle).value
    }

    private func started(_ run: UUID, source: CaptureSource) {
        guard run == generation, phase == .preparing else { return }
        pending.remove(source)
        if pending.isEmpty {
            deadline?.cancel(); deadline = nil; phase = .recording
            reply?.resolve(.success(())); reply = nil
        }
    }

    private nonisolated static func failureHandler(_ owner: CaptureCoordinator,
                                                   run: UUID) -> @Sendable (AudioCaptureError) -> Void {
        { [weak owner] error in Task { await owner?.failed(run, error: error, source: error.source) } }
    }

    /// Only the affected source stops and starts again; the other keeps
    /// recording. The restart task replaces the start task, so a concurrent
    /// Pause/Stop joins it before stopping the driver.
    private func restart(_ run: UUID, source: CaptureSource, error: AudioCaptureError) {
        let index = source == .microphone ? 0 : 1
        let driver = drivers[index], previous = starts[index]
        guard let gate = packetGate else { return }
        let notify = restarted
        restarts[source, default: 0] += 1
        starts[index] = Task.detached { [self] in
            do {
                _ = await previous.result
                try await driver.stop()
                notify?(source, error.operation)
                try Task.checkCancellation()
                try await driver.start({ gate.receive($0) }, Self.failureHandler(self, run: run))
                try Task.checkCancellation()
            } catch {
                await self.failed(run, error: AudioCaptureError(source: source,
                    operation: "Cannot restart after a device change: \((error as? AudioCaptureError)?.operation ?? error.localizedDescription)",
                    status: (error as? AudioCaptureError)?.status), source: source)
                throw error
            }
        }
    }

    private func timedOut(_ run: UUID) {
        guard run == generation, phase == .preparing else { return }
        let source: CaptureSource = pending.contains(.microphone) ? .microphone : .system
        failed(run, error: AudioCaptureError(source: source,
            operation: "Startup timed out; waiting for audio resources to stop", status: nil))
    }

    private func failed(_ run: UUID, error: Error, source: CaptureSource = .system) {
        guard run == generation, [.preparing, .recording].contains(phase) else { return }
        if error is CancellationError { _ = beginShutdown(to: .idle); return }
        if phase == .recording, let problem = error as? AudioCaptureError, problem.restartable {
            let now = ContinuousClock.now
            let recent = recentRestarts[problem.source, default: []].filter { now - $0 < restartWindow }
            recentRestarts[problem.source] = recent
            if recent.count < restartLimit {
                recentRestarts[problem.source]!.append(now)
                restart(run, source: problem.source, error: problem); return
            }
        }
        lastError = (error as? AudioCaptureError) ?? AudioCaptureError(source: source,
            operation: error.localizedDescription, status: nil)
        reportStop = phase == .recording
        reply?.resolve(.failure(lastError!))
        _ = beginShutdown(to: .failed)
    }

    private func cancel(_ run: UUID) {
        guard run == generation, [.preparing, .recording].contains(phase) else { return }
        _ = beginShutdown(to: .idle)
    }

    private func beginShutdown(to next: CapturePhase) -> Task<Void, Never> {
        destination = next
        if let shutdown { return shutdown }
        phase = .stopping
        deadline?.cancel(); deadline = nil
        reply?.resolve(.failure(CancellationError())); reply = nil
        let operations = starts, run = generation
        operations.forEach { $0.cancel() }
        let task = Task.detached { [drivers] in
            let errors = await withTaskGroup(of: AudioCaptureError?.self) { group in
                for (index, driver) in drivers.enumerated() {
                    group.addTask {
                        if index < operations.count { _ = await operations[index].result }
                        do { try await driver.stop(); return nil }
                        catch { return (error as? AudioCaptureError) ?? AudioCaptureError(source: driver.source,
                            operation: "Audio resource cleanup failed: \(error.localizedDescription)", status: nil) }
                    }
                }
                var errors: [AudioCaptureError] = []
                for await error in group { if let error { errors.append(error) } }
                return errors.sorted { $0.source.rawValue < $1.source.rawValue }
            }
            await self.didStop(run, error: errors.first)
        }
        shutdown = task
        return task
    }

    private func didStop(_ run: UUID, error: AudioCaptureError?) {
        guard generation == run else { return }
        // Drivers have stopped producing and drained accepted packets. Closing
        // earlier would discard the last queued audio on Pause/Stop.
        packetGate?.close(); packetGate = nil
        starts = []; pending = []; shutdown = nil
        cleanupRequired = error != nil
        if let error { lastError = error; phase = .failed }
        else { phase = destination }
        if reportStop, let lastError { reportStop = false; stopped?(lastError) }
    }
}

/// The supplied sink must perform bounded handoff only. Holding this short lock
/// makes close a barrier: old-run callbacks cannot enter a new recording sink.
private final class CapturePacketGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private let sink: @Sendable (AudioPacket) -> Void
    init(receive: @escaping @Sendable (AudioPacket) -> Void) { sink = receive }
    func receive(_ packet: AudioPacket) { lock.withLock { if open { sink(packet) } } }
    func close() { lock.withLock { open = false } }
}
