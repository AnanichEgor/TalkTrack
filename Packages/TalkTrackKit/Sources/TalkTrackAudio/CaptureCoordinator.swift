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

/// How Stop or Pause ended (design D3).
public enum CaptureStopReport: Sendable {
    case stopped
    /// A source's cleanup failed or timed out in its driver; audio until then is kept.
    case failed(AudioCaptureError)
    /// These sources were still stopping at the deadline. The packet gate is closed;
    /// their late completion clears the state.
    case abandoned([CaptureSource])
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
/// Stop and Pause wait at most `stopDeadline` for that: then the packet gate is
/// closed, the pending sources are reported abandoned and the capture stays failed
/// (cleanup required) until the late shutdown completes.
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
    private let stopDeadline: Duration
    private var shutdownPending: Set<CaptureSource> = []
    private var shutdownStarted = ContinuousClock.now
    /// Sources whose stop was abandoned at the deadline and has not returned yet.
    public private(set) var abandonedSources: [CaptureSource] = []

    /// `restarted` runs after a restartable source has stopped and drained its
    /// old packets, before it starts again: the sink can mark the discontinuity.
    /// One device switch can post several changes, so only more than
    /// `restartLimit` restarts within `restartWindow` count as a failing loop.
    /// `failed` reports a source lost during Recording after both drivers have
    /// stopped and drained, so the owner can finalize the recording.
    public init(microphone: CaptureDriver, system: CaptureDriver,
                restartLimit: Int = 5, restartWindow: Duration = .seconds(30),
                stopDeadline: Duration = .seconds(10),
                receive: @escaping @Sendable (AudioPacket) -> Void,
                restarted: (@Sendable (CaptureSource, String) -> Void)? = nil,
                failed: (@Sendable (AudioCaptureError) -> Void)? = nil) {
        precondition(microphone.source == .microphone && system.source == .system && restartLimit >= 0 && stopDeadline > .zero)
        drivers = [microphone, system]; self.receive = receive; stopped = failed; self.stopDeadline = stopDeadline
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
        let capture = MicrophoneCapture()
        return CaptureCoordinator(microphone: CaptureDriver(source: .microphone,
            start: { try await capture.start(deviceID: try microphone(), receive: $0, failure: $1) },
            stop: { try await capture.stop() }), system: nativeSystemDriver(),
            receive: receive, restarted: restarted, failed: failed)
    }

    /// System audio through a Core Audio process tap (System Audio Recording Only).
    static func nativeSystemDriver() -> CaptureDriver {
        let system = ProcessTapCapture()
        return CaptureDriver(source: .system, start: { try await system.start(receive: $0, failure: $1) },
                             stop: { try await system.stop() })
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
        try await CaptureLog.timed("coordinator.start", run: run) {
            try await withTaskCancellationHandler {
                try await completion.value()
                try Task.checkCancellation()
            } onCancel: {
                completion.resolve(.failure(CancellationError()))
                Task { await self.cancel(run) }
            }
        }
    }

    /// Throws the cleanup or abandonment error when the sources did not stop cleanly.
    public func pause() async throws {
        guard phase == .recording else {
            throw AudioCaptureError(source: .system, operation: "Only an active recording can be paused", status: nil)
        }
        switch await finish(beginShutdown(to: .paused), operation: "coordinator.pause") {
        case .stopped: return
        case .failed(let error): throw error
        case .abandoned: throw lastError ?? AudioCaptureError(source: .microphone, operation: "Capture did not stop", status: nil)
        }
    }

    /// Returns within `stopDeadline` (plus scheduling), even when a driver never returns.
    @discardableResult
    public func stop() async -> CaptureStopReport {
        guard phase != .idle else { return .stopped }
        // An abandoned shutdown is still running; waiting again would only add a deadline.
        if !abandonedSources.isEmpty { return .abandoned(abandonedSources) }
        return await finish(beginShutdown(to: .idle), operation: "coordinator.stop")
    }

    /// Races the shutdown against the deadline; abandons the pending sources if it wins.
    private func finish(_ shutdown: Task<Void, Never>, operation: String) async -> CaptureStopReport {
        let run = generation, start = ContinuousClock.now
        CaptureLog.capture.log("\(operation, privacy: .public) begin run=\(CaptureLog.id(run), privacy: .public)")
        let done = CaptureReply<Bool>()
        let waiter = Task { await shutdown.value; done.resolve(.success(true)) }
        let timer = Task { [stopDeadline] in
            do { try await Task.sleep(for: stopDeadline) } catch { return }
            done.resolve(.success(false))
        }
        let finished = (try? await done.value()) ?? false
        timer.cancel(); waiter.cancel()
        if !finished { abandon(run) }
        let report: CaptureStopReport = if !abandonedSources.isEmpty { .abandoned(abandonedSources) }
            else if cleanupRequired, let lastError { .failed(lastError) }
            else { .stopped }
        let outcome = switch report {
        case .stopped: "stopped"
        case .failed: "failed"
        case .abandoned(let sources): "abandoned sources=" + sources.map(\.rawValue).joined(separator: ",")
        }
        CaptureLog.capture.log("\(operation, privacy: .public) end run=\(CaptureLog.id(run), privacy: .public) ms=\(CaptureLog.milliseconds(since: start), privacy: .public) outcome=\(outcome, privacy: .public)")
        return report
    }

    private func abandon(_ run: UUID) {
        guard generation == run, shutdown != nil, abandonedSources.isEmpty else { return }
        let sources = shutdownPending.sorted { $0.rawValue < $1.rawValue }
        // Every driver returned; didStop is about to run.
        guard let first = sources.first else { return }
        // Late packets must not reach a recording that is being finished.
        packetGate?.close(); packetGate = nil
        abandonedSources = sources; cleanupRequired = true; phase = .failed; reportStop = false
        let names = sources.map { $0 == .microphone ? "microphone" : "system audio" }.joined(separator: " and ")
        lastError = AudioCaptureError(source: first, operation:
            "The \(names) did not stop within \(stopDeadline.seconds.formatted(.number.precision(.fractionLength(0...1)))) s; the recording was saved with the audio received so far",
            status: nil, recovery: .restartTalkTrack)
        CaptureLog.capture.error("coordinator.shutdown abandoned run=\(CaptureLog.id(run), privacy: .public) ms=\(CaptureLog.milliseconds(since: self.shutdownStarted), privacy: .public) sources=\(sources.map(\.rawValue).joined(separator: ","), privacy: .public)")
    }

    private func sourceStopped(_ run: UUID, source: CaptureSource) {
        guard generation == run else { return }
        shutdownPending.remove(source)
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
        CaptureLog.capture.log("coordinator.restart begin run=\(CaptureLog.id(run), privacy: .public) source=\(source.rawValue, privacy: .public) count=\(self.restarts[source, default: 0], privacy: .public)")
        starts[index] = Task.detached { [self] in
            let began = ContinuousClock.now
            do {
                _ = await previous.result
                try await driver.stop()
                notify?(source, error.operation)
                try Task.checkCancellation()
                try await driver.start({ gate.receive($0) }, Self.failureHandler(self, run: run))
                try Task.checkCancellation()
                CaptureLog.capture.log("coordinator.restart end run=\(CaptureLog.id(run), privacy: .public) source=\(source.rawValue, privacy: .public) ms=\(CaptureLog.milliseconds(since: began), privacy: .public)")
            } catch {
                CaptureLog.failure("coordinator.restart", run: run, ms: CaptureLog.milliseconds(since: began), error: error)
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
        let restartable = (error as? AudioCaptureError)?.restartable == true
        CaptureLog.capture.log("coordinator.sourceFailed run=\(CaptureLog.id(run), privacy: .public) source=\(source.rawValue, privacy: .public) phase=\(self.phase.rawValue, privacy: .public) restartable=\(restartable, privacy: .public) status=\((error as? AudioCaptureError)?.status.map { String($0) } ?? "-", privacy: .public) error=\(String(describing: error), privacy: .private)")
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
        shutdownPending = Set(drivers.map(\.source)); shutdownStarted = .now
        CaptureLog.capture.log("coordinator.shutdown begin run=\(CaptureLog.id(run), privacy: .public) to=\(next.rawValue, privacy: .public)")
        let task = Task.detached { [drivers] in
            let errors = await withTaskGroup(of: AudioCaptureError?.self) { group in
                for (index, driver) in drivers.enumerated() {
                    group.addTask {
                        if index < operations.count { _ = await operations[index].result }
                        defer { Task { await self.sourceStopped(run, source: driver.source) } }
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
        starts = []; pending = []; shutdown = nil; shutdownPending = []
        // A shutdown abandoned at the deadline completed late: the owner has already
        // finished the recording, so the capture becomes idle, or stays failed on error.
        let late = !abandonedSources.isEmpty
        abandonedSources = []
        cleanupRequired = error != nil
        if let error { lastError = error; phase = .failed }
        else { phase = late ? .idle : destination }
        let outcome = error == nil ? (late ? "late" : "stopped") : "failed"
        CaptureLog.capture.log("coordinator.shutdown end run=\(CaptureLog.id(run), privacy: .public) ms=\(CaptureLog.milliseconds(since: self.shutdownStarted), privacy: .public) outcome=\(outcome, privacy: .public) status=\(error?.status.map { String($0) } ?? "-", privacy: .public)")
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
