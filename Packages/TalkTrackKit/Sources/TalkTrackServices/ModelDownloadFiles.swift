import CryptoKit
import Darwin
import Foundation
import TalkTrackDomain

public enum ModelDownloadError: Error, Equatable, LocalizedError, Sendable {
    case busy
    case insufficientSpace
    case invalidResponse
    case changedEntity
    case httpStatus(Int)
    case incompletePreparation
    case invalidLease
    case notReady

    public var errorDescription: String? {
        switch self {
        case .busy: "This model is already being changed. Wait or cancel its active operation."
        case .insufficientSpace: "Not enough free space for this model and a 512 MB reserve. Free space and retry."
        case .invalidResponse: "The model server returned an invalid range or file length. Retry the download."
        case .changedEntity: "The server's file version changed. Restarting this partial file is required."
        case .httpStatus(let status): "Model download failed with HTTP \(status). Check access and retry."
        case .incompletePreparation: "Model preparation did not produce all required local files. Repair or retry the installation."
        case .invalidLease: "The model operation is no longer active. Retry with a new operation."
        case .notReady: "This model is not ready. Download or repair it before processing."
        }
    }
}

struct ModelDownloadTicket: Sendable {
    let id: UUID
    let manifest: ModelManifest
    let fingerprint: String
}

struct PartialModelFile: Sendable {
    let byteCount: Int64
    let etag: String?
}

/// The downloader owns this actor. All paths are relative to the fixed Models
/// root; tests can inject a temporary root via the internal initializer only.
public actor ModelDownloadFiles {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TalkTrack/Models", isDirectory: true)
    }
    private let rootURL: URL
    private let testAvailableBytes: Int64?
    private var rootHandle: DirectoryHandle?
    private var active: [String: ModelDownloadTicket] = [:]
    private var locks: [UUID: FileHandle] = [:]
    private var sealed: Set<UUID> = []
    private let verifier = ModelIntegrityVerifier()

    public init() { rootURL = Self.defaultRoot; testAvailableBytes = nil }
    init(testRoot: URL, availableBytes: Int64? = nil) { rootURL = testRoot; testAvailableBytes = availableBytes }

    private func root() throws -> DirectoryHandle {
        if let rootHandle {
            let current = try DirectoryHandle.openAbsolute(rootURL)
            var a = stat(), b = stat()
            guard fstat(rootHandle.fd, &a) == 0, fstat(current.fd, &b) == 0,
                  a.st_dev == b.st_dev, a.st_ino == b.st_ino else { throw LibraryError.unsafePath(rootURL.path) }
            return rootHandle
        }
        guard rootURL.isFileURL else { throw LibraryError.unsafePath(rootURL.absoluteString) }
        let parts = DirectoryHandle.physicalComponents(rootURL)
        guard !parts.contains(".."), !parts.contains(".") else { throw LibraryError.unsafePath(rootURL.path) }
        var directory = try DirectoryHandle.openAbsolute(URL(fileURLWithPath: "/"))
        for component in parts.dropFirst() { directory = try directory.createDirectory(component) }
        rootHandle = directory
        return directory
    }

    func begin(_ manifest: ModelManifest) throws -> ModelDownloadTicket {
        try manifest.validate()
        let key = try manifest.installationPath.value
        guard active[key] == nil else { throw ModelDownloadError.busy }
        let root = try root()
        let available: Int64
        if let testAvailableBytes { available = testAvailableBytes }
        else {
            var info = statfs()
            guard fstatfs(root.fd, &info) == 0 else { throw LibraryError.io(operation: "check model disk space", code: errno) }
            let bytes = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
            guard !bytes.overflow, bytes.partialValue <= Int64.max else { throw ModelDownloadError.insufficientSpace }
            available = Int64(bytes.partialValue)
        }
        var reserved: Int64 = 512 * 1024 * 1024
        for size in active.values.map({ $0.manifest.downloadByteCount }) + [manifest.downloadByteCount] {
            let sum = reserved.addingReportingOverflow(size)
            guard !sum.overflow else { throw ModelDownloadError.insufficientSpace }
            reserved = sum.partialValue
        }
        guard available >= reserved else { throw ModelDownloadError.insufficientSpace }
        let ticket = ModelDownloadTicket(id: UUID(), manifest: manifest, fingerprint: try SessionStore.fingerprint(manifest))
        let lock = try operationLock(manifest)
        active[key] = ticket
        locks[ticket.id] = lock
        do {
            let installed = try installation(ticket)
            if installed.exists(".talktrack-ready.json") { try installed.removeFile(".talktrack-ready.json") }
            _ = try staging(ticket)
            return ticket
        } catch { end(ticket); throw error }
    }

    func end(_ ticket: ModelDownloadTicket) {
        if let key = try? ticket.manifest.installationPath.value, active[key]?.id == ticket.id {
            active[key] = nil
            sealed.remove(ticket.id)
            if let handle = locks.removeValue(forKey: ticket.id) { try? handle.close() }
        }
    }

    private func operationLock(_ manifest: ModelManifest) throws -> FileHandle {
        let directory = try root().createDirectory(".locks")
        let key = SHA256.hash(data: Data(try manifest.installationPath.value.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let handle = try openFile(key, in: directory, write: true)
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? handle.close()
            throw ModelDownloadError.busy
        }
        return handle
    }

    private func checkWritable(_ ticket: ModelDownloadTicket) throws {
        try check(ticket)
        guard !sealed.contains(ticket.id) else { throw ModelDownloadError.busy }
    }

    private func check(_ ticket: ModelDownloadTicket) throws {
        guard active[try ticket.manifest.installationPath.value]?.id == ticket.id else { throw ModelDownloadError.invalidLease }
    }

    private func descend(_ path: RelativePath, from parent: DirectoryHandle) throws -> DirectoryHandle {
        var current = parent
        for part in path.value.split(separator: "/") { current = try current.createDirectory(String(part)) }
        return current
    }

    private func installation(_ ticket: ModelDownloadTicket) throws -> DirectoryHandle {
        try check(ticket)
        return try descend(ticket.manifest.installationPath, from: root())
    }

    private func staging(_ ticket: ModelDownloadTicket) throws -> DirectoryHandle {
        try check(ticket)
        return try root().createDirectory(".downloads").createDirectory(ticket.fingerprint)
    }

    private func parent(_ file: RelativePath, in directory: DirectoryHandle, create: Bool = true) throws -> (DirectoryHandle, String) {
        let parts = file.value.split(separator: "/").map(String.init)
        var current = directory
        for component in parts.dropLast() { current = try create ? current.createDirectory(component) : current.directory(component) }
        return (current, parts.last!)
    }

    private func fileKey(_ file: ModelFile) -> String {
        SHA256.hash(data: Data(file.path.value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func openFile(_ name: String, in directory: DirectoryHandle, write: Bool = false) throws -> FileHandle {
        let flags = (write ? O_RDWR | O_CREAT : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let descriptor = openat(directory.fd, name, flags, 0o600)
        guard descriptor >= 0 else { throw LibraryError.io(operation: "open model file \(name)", code: errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(descriptor)
            throw LibraryError.unsafePath(name)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func verifyInstalled(_ file: ModelFile, ticket: ModelDownloadTicket) async throws -> Bool {
        try checkWritable(ticket)
        let (directory, name) = try parent(file.path, in: installation(ticket))
        guard directory.exists(name) else { return false }
        let handle = try openFile(name, in: directory)
        defer { try? handle.close() }
        do { try await verifier.verify(file, reading: handle); return true }
        catch is ModelCatalogError {
            try checkWritable(ticket)
            try directory.removeFile(name)
            return false
        }
    }

    func partial(_ file: ModelFile, ticket: ModelDownloadTicket) throws -> PartialModelFile {
        let directory = try staging(ticket), key = fileKey(file)
        guard directory.exists(key + ".part") else { return PartialModelFile(byteCount: 0, etag: nil) }
        let handle = try openFile(key + ".part", in: directory)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= UInt64(file.byteCount) else {
            try resetPartial(file, ticket: ticket)
            return PartialModelFile(byteCount: 0, etag: nil)
        }
        var etag: String?
        if directory.exists(key + ".etag.json") {
            etag = try JSONDecoder().decode(String.self, from: readRegular(key + ".etag.json", in: directory, maximum: 16384))
        }
        // Without a strong validator, do not append to an earlier response.
        if size > 0 && (etag == nil || etag!.hasPrefix("W/")) {
            try resetPartial(file, ticket: ticket)
            return PartialModelFile(byteCount: 0, etag: nil)
        }
        return PartialModelFile(byteCount: Int64(size), etag: etag)
    }

    func resetPartial(_ file: ModelFile, ticket: ModelDownloadTicket) throws {
        try checkWritable(ticket)
        let directory = try staging(ticket), key = fileKey(file)
        try directory.removeFile(key + ".part")
        try directory.removeFile(key + ".etag.json")
    }

    func writer(_ file: ModelFile, ticket: ModelDownloadTicket, append: Bool, etag: String?) throws -> FileHandle {
        try checkWritable(ticket)
        let directory = try staging(ticket), key = fileKey(file)
        let handle = try openFile(key + ".part", in: directory, write: true)
        do {
            if append { _ = try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
            if let etag { try directory.replace(key + ".etag.json", data: JSONEncoder().encode(etag)) }
            else { try directory.removeFile(key + ".etag.json") }
            return handle
        } catch { try? handle.close(); throw error }
    }

    func publishFile(_ file: ModelFile, ticket: ModelDownloadTicket) async throws {
        try checkWritable(ticket)
        let stage = try staging(ticket), key = fileKey(file)
        let handle = try openFile(key + ".part", in: stage)
        defer { try? handle.close() }
        do { try await verifier.verify(file, reading: handle) }
        catch is ModelCatalogError { try resetPartial(file, ticket: ticket); throw ModelCatalogError.digestMismatch(file.path.value) }
        try Task.checkCancellation()
        let (directory, name) = try parent(file.path, in: installation(ticket))
        try checkWritable(ticket)
        if directory.exists(name) { try openFile(name, in: directory).close() }
        guard renameat(stage.fd, key + ".part", directory.fd, name) == 0, fsync(directory.fd) == 0 else {
            throw LibraryError.io(operation: "publish model file", code: errno)
        }
        try stage.removeFile(key + ".etag.json")
    }

    func readForPreparation(_ path: RelativePath, ticket: ModelDownloadTicket) throws -> Data {
        guard ticket.manifest.files.contains(where: { $0.path == path }) else { throw ModelDownloadError.incompletePreparation }
        let (directory, name) = try parent(path, in: existingInstallation(ticket), create: false)
        return try readRegular(name, in: directory, maximum: 64 * 1024 * 1024)
    }

    private struct DerivedRecord: Codable {
        let path: RelativePath
        let byteCount: Int64
        let sha256: String
        let generatorVersion: String
        let manifestFingerprint: String
    }

    func writeGenerated(_ path: RelativePath, data: Data, ticket: ModelDownloadTicket) throws {
        try checkWritable(ticket)
        guard let definition = ticket.manifest.generatedArtifacts.first(where: { $0.path == path }) else {
            throw ModelDownloadError.incompletePreparation
        }
        let installed = try installation(ticket)
        let (directory, name) = try parent(path, in: installed)
        if directory.exists(name) { try openFile(name, in: directory).close() }
        try directory.replace(name, data: data)
        let record = DerivedRecord(path: path, byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            generatorVersion: definition.generatorVersion, manifestFingerprint: ticket.fingerprint)
        try installed.replace(".talktrack-generated-" + name + ".json", data: JSONEncoder().encode(record))
    }

    private func verifyComplete(_ ticket: ModelDownloadTicket) async throws {
        for file in ticket.manifest.files {
            let (directory, name) = try parent(file.path, in: existingInstallation(ticket), create: false)
            let handle = try openFile(name, in: directory)
            defer { try? handle.close() }
            try await verifier.verify(file, reading: handle)
        }
        for generated in ticket.manifest.generatedArtifacts {
            let installed = try existingInstallation(ticket)
            let (directory, name) = try parent(generated.path, in: installed, create: false)
            let recordName = ".talktrack-generated-" + name + ".json"
            guard installed.exists(recordName) else { throw ModelDownloadError.incompletePreparation }
            let record = try JSONDecoder().decode(DerivedRecord.self, from: readRegular(recordName, in: installed, maximum: 65536))
            guard record.path == generated.path, record.manifestFingerprint == ticket.fingerprint,
                  record.generatorVersion == generated.generatorVersion else { throw ModelDownloadError.incompletePreparation }
            let handle = try openFile(name, in: directory)
            defer { try? handle.close() }
            try await verifier.verify(ModelFile(path: generated.path, byteCount: record.byteCount,
                digest: ModelDigest(algorithm: .sha256, value: record.sha256)), reading: handle)
        }
        try Task.checkCancellation()
        try validateTree(ticket)
    }

    func publishReady(_ ticket: ModelDownloadTicket) async throws {
        try await verifyComplete(ticket)
        try existingInstallation(ticket).replace(".talktrack-ready.json", data: JSONEncoder().encode(ticket.fingerprint))
    }

    private func readRegular(_ name: String, in directory: DirectoryHandle, maximum: Int) throws -> Data {
        let handle = try openFile(name, in: directory)
        defer { try? handle.close() }
        let bytes = try handle.seekToEnd()
        guard bytes <= maximum else { throw LibraryError.unsafePath(name) }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: Int(bytes) + 1) ?? Data()
        guard data.count == bytes else { throw LibraryError.unsafePath(name) }
        return data
    }

    private func existingInstallation(_ ticket: ModelDownloadTicket) throws -> DirectoryHandle {
        try check(ticket)
        var directory = try root()
        for component in try ticket.manifest.installationPath.value.split(separator: "/") {
            directory = try directory.directory(String(component))
        }
        return directory
    }

    /// Fail closed for undeclared files: upstream loaders enumerate weights and
    /// optional tokenizer assets, so checking only the expected files is insufficient.
    private func validateTree(_ ticket: ModelDownloadTicket) throws {
        let files = ticket.manifest.files.map(\.path.value) + ticket.manifest.generatedArtifacts.map(\.path.value)
        let records = ticket.manifest.generatedArtifacts.map { ".talktrack-generated-" + $0.path.value + ".json" }
        let allowed = Set(files + records + [".talktrack-ready.json"])
        func walk(_ directory: DirectoryHandle, prefix: String) throws {
            guard let stream = fdopendir(dup(directory.fd)) else { throw LibraryError.unsafePath(prefix) }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let path = prefix + name
                var info = stat()
                guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw LibraryError.unsafePath(path) }
                if info.st_mode & S_IFMT == S_IFDIR {
                    guard allowed.contains(where: { $0.hasPrefix(path + "/") }) else { throw LibraryError.unsafePath(path) }
                    try walk(directory.directory(name), prefix: path + "/")
                } else {
                    guard allowed.contains(path), info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                        throw LibraryError.unsafePath(path)
                    }
                }
            }
        }
        try walk(existingInstallation(ticket), prefix: "")
    }

    /// Keep this lease until inference has materialized and released all model
    /// resources. The filesystem lock also excludes another file-service instance.
    public func acquireLocalModel(_ manifest: ModelManifest) async throws -> ModelLocalDirectory {
        try manifest.validate()
        let key = try manifest.installationPath.value
        guard active[key] == nil else { throw ModelDownloadError.busy }
        let lock = try operationLock(manifest)
        let ticket = ModelDownloadTicket(id: UUID(), manifest: manifest, fingerprint: try SessionStore.fingerprint(manifest))
        active[key] = ticket
        locks[ticket.id] = lock
        do {
            let installed = try existingInstallation(ticket)
            guard installed.exists(".talktrack-ready.json"),
                  try JSONDecoder().decode(String.self, from: readRegular(".talktrack-ready.json", in: installed, maximum: 65536)) == ticket.fingerprint else {
                throw ModelDownloadError.notReady
            }
            return try await localDirectory(ticket)
        } catch { end(ticket); throw error }
    }

    func localDirectory(_ ticket: ModelDownloadTicket) async throws -> ModelLocalDirectory {
        // Seal before awaiting hashing, so a retained preparation context cannot
        // write derived data while a loader borrows this installation.
        try check(ticket)
        sealed.insert(ticket.id)
        try await verifyComplete(ticket)
        return ModelLocalDirectory(files: self, ticket: ticket)
    }

    func localURL(_ ticket: ModelDownloadTicket) async throws -> URL {
        try check(ticket)
        guard sealed.contains(ticket.id) else { throw ModelDownloadError.invalidLease }
        try await verifyComplete(ticket)
        return rootURL.appendingPathComponent(try ticket.manifest.installationPath.value, isDirectory: true)
    }

    /// Readiness without waiting for inference: an installation borrowed by a
    /// running loader (or being written by a download) reports `busy`.
    public func isBusy(_ manifest: ModelManifest) throws -> Bool {
        active[try manifest.installationPath.value] != nil
    }

    public func isReady(_ manifest: ModelManifest) throws -> Bool {
        try manifest.validate()
        guard active[try manifest.installationPath.value] == nil else { return false }
        var directory = try root()
        for part in try manifest.installationPath.value.split(separator: "/") {
            guard directory.exists(String(part)) else { return false }
            directory = try directory.directory(String(part))
        }
        guard directory.exists(".talktrack-ready.json") else { return false }
        return try JSONDecoder().decode(String.self, from: readRegular(".talktrack-ready.json", in: directory, maximum: 65536)) == SessionStore.fingerprint(manifest)
    }

    public func remove(_ manifest: ModelManifest) throws {
        try manifest.validate()
        guard active[try manifest.installationPath.value] == nil else { throw ModelDownloadError.busy }
        let lock = try operationLock(manifest)
        defer { try? lock.close() }
        let root = try root()
        let parts = try manifest.installationPath.value.split(separator: "/").map(String.init)
        var parent: DirectoryHandle? = root
        for part in parts.dropLast() {
            guard let current = parent, current.exists(part) else { parent = nil; break }
            parent = try current.directory(part)
        }
        try parent?.removeTree(parts.last!)
        if root.exists(".downloads") { try root.directory(".downloads").removeTree(SessionStore.fingerprint(manifest)) }
    }
}

public struct ModelPreparationContext: Sendable {
    private let files: ModelDownloadFiles
    private let ticket: ModelDownloadTicket
    init(files: ModelDownloadFiles, ticket: ModelDownloadTicket) { self.files = files; self.ticket = ticket }
    public func read(_ path: RelativePath) async throws -> Data { try await files.readForPreparation(path, ticket: ticket) }
    public func localDirectory() async throws -> ModelLocalDirectory { try await files.localDirectory(ticket) }
    public func writeGenerated(_ path: RelativePath, data: Data) async throws { try await files.writeGenerated(path, data: data, ticket: ticket) }
}

/// Only the file service can construct this capability. There is no initializer
/// accepting a cache URL; use the manifest's installed revision or fail closed.
public struct ModelLocalDirectory: Sendable {
    private let files: ModelDownloadFiles
    private let ticket: ModelDownloadTicket
    fileprivate init(files: ModelDownloadFiles, ticket: ModelDownloadTicket) { self.files = files; self.ticket = ticket }
    public func validatedURL() async throws -> URL { try await files.localURL(ticket) }
    public func release() async { await files.end(ticket) }
}
