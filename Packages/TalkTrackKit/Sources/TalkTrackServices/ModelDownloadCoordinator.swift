// Orchestration adapted from Muesli ModelDownloadCoordinator at
// d457aaf94691a73afd2867f5a6ca7fdd203044db, Copyright (c) 2026 Pranav Hari.
// MIT; see ThirdParty/Muesli-LICENSE. TalkTrack uses its own confined file actor,
// SHA-256/Git-blob manifests, bounded streaming and required preparation hook.
import Foundation

public enum ModelDownloadPhase: String, Sendable { case checking, downloading, preparing, ready, paused, failed }

public struct ModelDownloadProgress: Sendable {
    public let phase: ModelDownloadPhase
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let completedFiles: Int
    public let totalFiles: Int
    public let message: String?

    public init(phase: ModelDownloadPhase, completedBytes: Int64, totalBytes: Int64, completedFiles: Int, totalFiles: Int,
                message: String? = nil) {
        self.phase = phase; self.completedBytes = completedBytes; self.totalBytes = totalBytes
        self.completedFiles = completedFiles; self.totalFiles = totalFiles; self.message = message
    }
}

public actor ModelDownloadCoordinator {
    public typealias Preparation = @Sendable (ModelManifest, ModelPreparationContext) async throws -> Void
    private struct Active {
        let fingerprint: String
        let task: Task<Void, Error>
    }
    private let files: ModelDownloadFiles
    private let transport: any ModelDownloadTransport
    private let concurrency: Int
    private var active: [String: Active] = [:]
    private var progress: [String: ModelDownloadProgress] = [:]
    private var bytes: [String: [String: Int64]] = [:]
    private var complete: [String: Set<String>] = [:]

    public init(files: ModelDownloadFiles = ModelDownloadFiles()) {
        self.files = files
        transport = URLSessionModelTransport()
        concurrency = 2
    }
    init(files: ModelDownloadFiles, transport: any ModelDownloadTransport, concurrency: Int = 2) {
        self.files = files
        self.transport = transport
        self.concurrency = max(1, min(4, concurrency))
    }

    public func status(_ manifest: ModelManifest) throws -> ModelDownloadProgress? {
        progress[try manifest.installationPath.value]
    }

    /// Duplicate callers share the same installation job. Cancel a model
    /// explicitly with cancelAndWait before removing any of its files.
    public func download(_ manifest: ModelManifest, prepare: @escaping Preparation) async throws {
        try Task.checkCancellation()
        try manifest.validate()
        let key = try manifest.installationPath.value
        let fingerprint = try SessionStore.fingerprint(manifest)
        if let existing = active[key] {
            guard existing.fingerprint == fingerprint else { throw ModelDownloadError.busy }
            try await existing.task.value
            try Task.checkCancellation()
            return
        }
        let task = Task {
            defer { active[key] = nil }
            do { try await perform(manifest, key: key, prepare: prepare) }
            catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                update(manifest, key: key, phase: cancelled ? .paused : .failed, message: error.localizedDescription)
                throw error
            }
        }
        active[key] = Active(fingerprint: fingerprint, task: task)
        try await task.value
        try Task.checkCancellation()
    }

    public func cancelAndWait(_ manifest: ModelManifest) async throws {
        let key = try manifest.installationPath.value
        guard let job = active[key] else { return }
        job.task.cancel()
        _ = try? await job.task.value
    }

    public func remove(_ manifest: ModelManifest) async throws {
        try await cancelAndWait(manifest)
        try await files.remove(manifest)
        let key = try manifest.installationPath.value
        progress[key] = nil
        bytes[key] = nil
        complete[key] = nil
    }

    private func perform(_ manifest: ModelManifest, key: String, prepare: Preparation) async throws {
        bytes[key] = [:]
        complete[key] = []
        update(manifest, key: key, phase: .checking)
        let ticket = try await files.begin(manifest)
        do {
            var pending: [ModelFile] = []
            for file in manifest.files {
                try Task.checkCancellation()
                if try await files.verifyInstalled(file, ticket: ticket) {
                    bytes[key, default: [:]][file.path.value] = file.byteCount
                    complete[key, default: []].insert(file.path.value)
                } else { pending.append(file) }
            }
            update(manifest, key: key, phase: .downloading)
            while !pending.isEmpty {
                let batch = Array(pending.prefix(concurrency))
                pending.removeFirst(batch.count)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for file in batch {
                        group.addTask { try await self.downloadFile(file, ticket: ticket, key: key) }
                    }
                    do { for try await _ in group {} }
                    catch { group.cancelAll(); throw error }
                }
            }
            try Task.checkCancellation()
            update(manifest, key: key, phase: .preparing)
            try await prepare(manifest, ModelPreparationContext(files: files, ticket: ticket))
            try Task.checkCancellation()
            try await files.publishReady(ticket)
            await files.end(ticket)
            update(manifest, key: key, phase: .ready)
        } catch { await files.end(ticket); throw error }
    }

    private func downloadFile(_ file: ModelFile, ticket: ModelDownloadTicket, key: String) async throws {
        var lastError: (any Error)?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(for: .milliseconds(200 * attempt)) }
            let partial = try await files.partial(file, ticket: ticket)
            // Interrupted after final byte: validate locally before requesting a range.
            if partial.byteCount == file.byteCount && file.byteCount > 0 {
                do {
                    try await files.publishFile(file, ticket: ticket)
                    finished(file, manifest: ticket.manifest, key: key)
                    return
                } catch is ModelCatalogError { /* corrupt partial was removed */ }
            }
            let current = try await files.partial(file, ticket: ticket)
            var request = URLRequest(url: try ticket.manifest.downloadURL(for: file))
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.timeoutInterval = 60
            if current.byteCount > 0 {
                request.setValue("bytes=\(current.byteCount)-", forHTTPHeaderField: "Range")
                request.setValue(current.etag, forHTTPHeaderField: "If-Range")
            }
            let receiver = ModelFileReceiver(file: file, ticket: ticket, files: files, partial: current) { count in
                await self.received(count, file: file, manifest: ticket.manifest, key: key)
            }
            do {
                try await transport.stream(request, response: { try await receiver.response($0) }, data: { try await receiver.append($0) })
                try await receiver.finish()
                try await files.publishFile(file, ticket: ticket)
                finished(file, manifest: ticket.manifest, key: key)
                return
            } catch {
                await receiver.close()
                try Task.checkCancellation()
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if error is ModelCatalogError { throw error }
                if let downloadError = error as? ModelDownloadError {
                    switch downloadError {
                    case .changedEntity, .httpStatus(416): try await files.resetPartial(file, ticket: ticket)
                    case .httpStatus(let status) where status == 429 || status >= 500: break
                    default: throw error
                    }
                } else if !(error is URLError) { throw error }
                lastError = error
            }
        }
        throw lastError ?? ModelDownloadError.invalidResponse
    }

    private func received(_ count: Int64, file: ModelFile, manifest: ModelManifest, key: String) {
        bytes[key, default: [:]][file.path.value] = count
        update(manifest, key: key, phase: .downloading)
    }

    private func finished(_ file: ModelFile, manifest: ModelManifest, key: String) {
        bytes[key, default: [:]][file.path.value] = file.byteCount
        complete[key, default: []].insert(file.path.value)
        update(manifest, key: key, phase: .downloading)
    }

    private func update(_ manifest: ModelManifest, key: String, phase: ModelDownloadPhase, message: String? = nil) {
        progress[key] = ModelDownloadProgress(phase: phase, completedBytes: bytes[key, default: [:]].values.reduce(0, +),
            totalBytes: manifest.downloadByteCount, completedFiles: complete[key, default: []].count,
            totalFiles: manifest.files.count, message: message)
    }
}

private actor ModelFileReceiver {
    private let file: ModelFile
    private let ticket: ModelDownloadTicket
    private let files: ModelDownloadFiles
    private let partial: PartialModelFile
    private let progress: @Sendable (Int64) async -> Void
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var receivedResponse = false

    init(file: ModelFile, ticket: ModelDownloadTicket, files: ModelDownloadFiles, partial: PartialModelFile,
         progress: @escaping @Sendable (Int64) async -> Void) {
        self.file = file; self.ticket = ticket; self.files = files; self.partial = partial; self.progress = progress
    }

    func response(_ response: ModelHTTPResponse) async throws {
        try Task.checkCancellation()
        guard !receivedResponse else { throw ModelDownloadError.invalidResponse }
        guard response.status == 200 || response.status == 206 else { throw ModelDownloadError.httpStatus(response.status) }
        let append = partial.byteCount > 0 && response.status == 206
        if response.status == 206 {
            guard append, let old = partial.etag, response.etag == old else { throw ModelDownloadError.changedEntity }
            guard response.contentRange == "bytes \(partial.byteCount)-\(file.byteCount - 1)/\(file.byteCount)" else {
                throw ModelDownloadError.invalidResponse
            }
        }
        let expected = file.byteCount - (append ? partial.byteCount : 0)
        if let length = response.contentLength, length != expected { throw ModelDownloadError.invalidResponse }
        handle = try await files.writer(file, ticket: ticket, append: append, etag: response.etag)
        written = append ? partial.byteCount : 0
        receivedResponse = true
        await progress(written)
    }

    func append(_ data: Data) async throws {
        try Task.checkCancellation()
        guard receivedResponse, let handle, Int64(data.count) <= file.byteCount - written else { throw ModelDownloadError.invalidResponse }
        try handle.write(contentsOf: data)
        written += Int64(data.count)
        await progress(written)
    }

    func finish() throws {
        try Task.checkCancellation()
        guard receivedResponse, let handle, written == file.byteCount else { throw ModelDownloadError.invalidResponse }
        try handle.synchronize()
        try handle.close()
        self.handle = nil
    }

    func close() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }
}
