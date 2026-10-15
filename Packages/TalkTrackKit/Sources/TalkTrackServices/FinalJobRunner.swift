import Foundation
import TalkTrackDomain

public enum FinalJobRunnerEvent: Sendable, Equatable {
    case started(jobID: UUID, meetingID: UUID)
    /// `error` is nil after a successful publication. The job's stored stage
    /// (failed, interrupted, waitingForModels) carries the durable outcome.
    case finished(jobID: UUID, meetingID: UUID, error: String?)
}

/// Runs the configured durable job kinds one at a time, oldest first. Jobs left
/// `failed`, `interrupted` or `waitingForModels` wait for an explicit retry.
public actor FinalJobRunner {
    public nonisolated let events: AsyncStream<FinalJobRunnerEvent>
    public private(set) var currentJobID: UUID?
    private let store: SessionStore
    private let kinds: [JobKind]
    private var captureActive = false
    private let process: @Sendable (UUID) async throws -> Void
    private let continuation: AsyncStream<FinalJobRunnerEvent>.Continuation
    private var loop: Task<Void, Never>?
    private var rescan = false
    private var current: (meetingID: UUID, task: Task<Void, any Error>)?
    /// Jobs left `queued` by a run (e.g. refused as busy); skipped until the next retry.
    private var skipped: Set<UUID> = []
    /// Set by `shutDown()`: no further job starts in this process.
    private var stopped = false

    public init(store: SessionStore, kinds: [JobKind] = [.finalTranscription], process: @escaping @Sendable (UUID) async throws -> Void) {
        self.store = store; self.kinds = kinds; self.process = process
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// The application processor: stage, then publish atomically.
    public static func pipeline(_ pipeline: FinalTranscriptionPipeline) -> @Sendable (UUID) async throws -> Void {
        { _ = try await pipeline.runAndPublish(jobID: $0) }
    }

    /// Looks for queued work. Safe to call at any time and repeatedly.
    public func wake() {
        guard !stopped else { return }
        guard loop == nil else { rescan = true; return }
        loop = Task { await self.drain() }
    }

    /// Returns a job to `queued` and processes it. The store revalidates its source.
    public func retry(jobID: UUID) async throws {
        _ = try await store.retryJob(jobID)
        skipped.remove(jobID)
        wake()
    }

    /// Cancels the running job if it belongs to the meeting and waits for it to
    /// stop, so the meeting can be deleted without a concurrent writer.
    public func cancel(meetingID: UUID) async {
        guard let current, current.meetingID == meetingID else { return }
        current.task.cancel()
        _ = await current.task.result
    }

    /// Cancel one request without invalidating other work or source snapshots.
    public func cancel(jobID: UUID) async throws {
        let job = try await store.job(jobID)
        if currentJobID == jobID, let current {
            current.task.cancel()
            _ = await current.task.result
        } else if job.stage == .queued {
            try await store.updateJob(jobID, stage: .interrupted,
                error: "Generation was cancelled. Retry when ready.")
        }
    }

    /// Capture pauses the whole queue and interrupts a running text job, including
    /// the gaps between its model calls. Final transcription uses runtime priority.
    public func setCaptureActive(_ active: Bool) async {
        captureActive = active
        if active, let id = currentJobID, let job = try? await store.job(id), job.snapshot.kind != .finalTranscription {
            try? await cancel(jobID: id)
        }
        if !active { wake() }
    }

    private func nextJob() async throws -> ProcessingJob? {
        var jobs: [ProcessingJob] = []
        for kind in kinds { jobs += try await store.queuedJobs(kind: kind) }
        return jobs.filter { !skipped.contains($0.id) }.min {
            $0.snapshot.createdAt == $1.snapshot.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.snapshot.createdAt < $1.snapshot.createdAt
        }
    }

    /// Waits until no job is running or queued (tests and shutdown).
    public func idle() async { while let loop { await loop.value } }

    /// For quitting: no further job starts, and the running one is cancelled.
    /// Returns that job; it keeps its completed stages. Does not wait, so the
    /// caller can bound the wait with `isRunning`.
    public func shutDown() -> UUID? {
        stopped = true
        current?.task.cancel()
        return currentJobID
    }

    public var isRunning: Bool { current != nil }

    private func drain() async {
        repeat {
            rescan = false
            while !stopped, !captureActive, let job = try? await nextJob() {
                guard !stopped, !captureActive else { break }
                let meetingID = job.snapshot.source.meetingID
                let task = Task<Void, any Error> { [process] in try await process(job.id) }
                current = (meetingID, task); currentJobID = job.id
                continuation.yield(.started(jobID: job.id, meetingID: meetingID))
                let result = await task.result
                current = nil; currentJobID = nil
                var message: String?
                if case .failure(let error) = result {
                    message = error is CancellationError ? "Processing was cancelled." : error.localizedDescription
                }
                // Never pick the same unchanged job again in this pass.
                if (try? await store.job(job.id).stage) == .queued { skipped.insert(job.id) }
                continuation.yield(.finished(jobID: job.id, meetingID: meetingID, error: message))
            }
        } while rescan
        loop = nil
    }
}
