import Foundation
import TalkTrackAudio
import TalkTrackDomain

/// Background removal of the padding in chunk files written before the
/// encoder change (compact-library-storage D7). One recording at a time on a
/// utility queue; it waits while `isBusy` (capture, import, final
/// transcription) and gives a recording up as soon as anything reads it.
/// Recordings a full pass finished carry `.compacted` and are not scanned
/// again.
public final class AudioCompaction: @unchecked Sendable {
    public struct Pass: Equatable, Sendable {
        public var recordings = 0
        public var compacted = 0
        public var savedBytes: Int64 = 0
        /// Recordings left for a later pass: busy, in use or interrupted.
        public var deferred = 0
        public var failed = 0
        public var timings = CompactionTimings()
    }

    private let library: OpenedLibrary
    private let store: SessionStore
    private let isBusy: @Sendable () async -> Bool
    private let access: RecordingAccess
    private let queue = DispatchQueue(label: "local.talktrack.audio-compaction", qos: .utility)
    private let lock = NSLock()
    private var paused = false
    private var stopping = false
    private var task: Task<Void, Never>?
    var startDelay: Duration = .seconds(20)
    var retryDelay: Duration = .seconds(120)
    var pollInterval: Duration = .seconds(2)
    /// Tests: observes each step of every chunk.
    var hook: @Sendable (UUID, CompactionStep) throws -> Void = { _, _ in }

    public init(library: OpenedLibrary, store: SessionStore, access: RecordingAccess = .shared,
                isBusy: @escaping @Sendable () async -> Bool) {
        self.library = library; self.store = store; self.access = access; self.isBusy = isBusy
    }

    /// Starts passes after a short delay; they repeat while recordings were deferred.
    public func start() {
        lock.withLock {
            guard task == nil else { return }
            task = Task.detached(priority: .utility) { [weak self] in await self?.run() }
        }
    }

    /// Stops between chunks and returns once nothing is being written.
    public func stop() async {
        let running = lock.withLock { () -> Task<Void, Never>? in
            stopping = true
            defer { task = nil }
            return task
        }
        running?.cancel()
        await running?.value
    }

    private func run() async {
        try? await Task.sleep(for: startDelay)
        while !Task.isCancelled {
            // Capture, import or transcription first; compaction waits for a quiet moment.
            while !Task.isCancelled, await isBusy() { try? await Task.sleep(for: pollInterval) }
            let pass = await runOnce()
            guard pass.deferred > 0 else { return }
            try? await Task.sleep(for: retryDelay)
        }
    }

    /// One pass now, for fixtures on library copies.
    @_spi(Diagnostics) public func runPass() async -> Pass { await runOnce() }

    /// One pass over every finished recording that is not marked done.
    @discardableResult
    func runOnce() async -> Pass {
        var pass = Pass()
        let recordings = (try? await candidates()) ?? []
        for (index, recording) in recordings.enumerated() {
            // Busy again: the rest waits for the next pass.
            let busy = await isBusy()
            if busy || Task.isCancelled || lock.withLock({ stopping }) {
                pass.deferred += recordings.count - index
                break
            }
            lock.withLock { paused = false }
            // Something starting mid-recording stops it at the next chunk.
            let monitor = Task { [isBusy, pollInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: pollInterval)
                    if Task.isCancelled { return }
                    if await isBusy() { self.lock.withLock { self.paused = true } }
                }
            }
            let start = ContinuousClock.now
            let outcome = await compact(recording)
            monitor.cancel()
            let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
            switch outcome {
            case nil:
                continue
            case .success(let result)?:
                pass.recordings += 1
                pass.compacted += result.compacted
                pass.savedBytes += result.savedBytes
                pass.timings = pass.timings + result.timings
                if result.busy || result.stopped { pass.deferred += 1 }
                SessionStore.storageLog.log("""
                    audio compaction recording=\(recording.id.uuidString, privacy: .public) \
                    compacted=\(result.compacted, privacy: .public) skipped=\(result.skipped, privacy: .public) \
                    refused=\(result.refused, privacy: .public) damaged=\(result.damaged, privacy: .public) \
                    saved=\(result.savedBytes, privacy: .public) busy=\(result.busy, privacy: .public) \
                    stopped=\(result.stopped, privacy: .public) ms=\(ms, privacy: .public) \
                    \(result.timings.logLine, privacy: .public)
                    """)
            case .failure(let error)?:
                pass.failed += 1
                SessionStore.storageLog.error("""
                    audio compaction failed recording=\(recording.id.uuidString, privacy: .public) \
                    error=\(String(describing: error), privacy: .private)
                    """)
            }
        }
        return pass
    }

    private var isPaused: Bool { lock.withLock { paused || stopping } }

    /// nil when the recording needs nothing (no folder, or already done).
    private func compact(_ recording: Recording) async -> Result<RecordingCompactionResult, Error>? {
        let library = library, access = access, hook = hook
        return await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let folder = try DirectoryHandle.openAbsolute(library.directory).directory("Meetings")
                        .directory(recording.meetingID.uuidString).directory("Recordings").directory(recording.id.uuidString)
                    guard !folder.exists(ChunkCompaction.finished) else { return continuation.resume(returning: nil) }
                    let result = try ChunkCompaction.compact(recording: folder, id: recording.id,
                                                             library: library.manifest.libraryID, access: access,
                                                             shouldStop: { self.isPaused },
                                                             hook: { try hook(recording.id, $0) })
                    continuation.resume(returning: .success(result))
                } catch LibraryError.unavailable {
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    /// Finished recordings, newest meetings last so older libraries shrink first.
    private func candidates() async throws -> [Recording] {
        var result: [Recording] = []
        for meeting in try await store.meetings().reversed() {
            result += try await store.recordings(meetingID: meeting.id).filter { [.complete, .interrupted].contains($0.state) }
        }
        return result
    }
}

extension CompactionTimings {
    /// `scan= read= rewrite= write= verify= publish= manifest=` in milliseconds.
    public var logLine: String {
        func ms(_ d: Duration) -> Int { Int(d / .milliseconds(1)) }
        return "scan=\(ms(scan)) read=\(ms(read)) rewrite=\(ms(rewrite)) write=\(ms(write)) " +
            "verify=\(ms(verify)) publish=\(ms(publish)) manifest=\(ms(manifest))"
    }
}
