import Darwin
import Foundation
import TalkTrackDomain

public enum LibraryError: Error, Equatable, LocalizedError, Sendable {
    case unavailable(String)
    case unsafePath(String)
    case unmarkedLibrary
    case wrongIdentity
    case unsupportedVersion(Int)
    case staleBookmark
    case io(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let path): "Library folder is unavailable: \(path). Reconnect the disk or restore folder access."
        case .unsafePath(let path): "Unsafe library path: \(path). Choose a real folder outside Models and other libraries."
        case .unmarkedLibrary: "This folder contains unrecognized library data. Choose another folder or recover the original manifest."
        case .wrongIdentity: "This is a different TalkTrack library. Restore access to the configured library."
        case .unsupportedVersion(let version): "Library format \(version) requires a newer version of TalkTrack."
        case .staleBookmark: "Folder access needs renewal. Select the original session folder again."
        case .io(let operation, let code): "Could not \(operation) (system error \(code)). Check disk space and folder permissions, then retry."
        }
    }
}

public struct LibraryManifest: Codable, Equatable, Sendable {
    public let application: String
    public let formatVersion: Int
    public let libraryID: UUID
    public let createdAt: Date

    init(id: UUID) {
        application = "TalkTrack"
        formatVersion = 1
        libraryID = id
        createdAt = Date()
    }
}

public struct LibraryLocation: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let rootBookmark: Data
    /// The root's path when the bookmark was made, for messages and to tell
    /// which side of an interrupted move is authoritative.
    public let rootPath: String?

    public init(libraryID: UUID, rootBookmark: Data, rootPath: String? = nil) {
        self.libraryID = libraryID
        self.rootBookmark = rootBookmark
        self.rootPath = rootPath
    }
}

public struct OpenedLibrary: Sendable {
    public let root: URL
    public let directory: URL
    public let manifest: LibraryManifest
    /// Opened from a bookmark macOS reported as stale (the folder was moved or
    /// renamed) after checking the library's identity; save `makeLocation()`.
    public var bookmarkWasStale = false

    public func makeLocation() throws -> LibraryLocation {
        LibraryLocation(libraryID: manifest.libraryID,
            rootBookmark: try root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
            rootPath: root.path)
    }
}

/// IO runs on this actor, not the UI executor. The configured bookmark never
/// falls back to a new/default library if access or identity validation fails.
public actor OwnedLibrary {
    public static let directoryName = ".talktrack-library"
    private let modelsRoot: URL
    private var scopedRoot: URL?

    public init(modelsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TalkTrack/Models", isDirectory: true)) {
        self.modelsRoot = modelsRoot.resolvingSymlinksInPath()
    }

    deinit { scopedRoot?.stopAccessingSecurityScopedResource() }

    public func openDefault(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> OpenedLibrary {
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let parent = try DirectoryHandle.openAbsolute(documents)
        if mkdirat(parent.fd, "TalkTrack", 0o700) != 0 && errno != EEXIST {
            throw LibraryError.io(operation: "create the default session folder", code: errno)
        }
        return try open(root: documents.appendingPathComponent("TalkTrack", isDirectory: true))
    }

    public func resume(_ location: LibraryLocation) throws -> OpenedLibrary {
        var stale = false
        let root: URL
        do {
            root = try URL(resolvingBookmarkData: location.rootBookmark,
                options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch { throw LibraryError.unavailable("configured session folder") }
        let accessed = root.startAccessingSecurityScopedResource()
        do {
            // A stale bookmark still resolved to a folder; it is used only if it
            // holds this very library, and the caller then renews the bookmark.
            var result = try open(root: root, expectedID: location.libraryID, allowCreate: false)
            result.bookmarkWasStale = stale
            scopedRoot?.stopAccessingSecurityScopedResource()
            scopedRoot = accessed ? root : nil
            return result
        } catch {
            if accessed { root.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    public func open(root: URL, expectedID: UUID? = nil, allowCreate: Bool = true) throws -> OpenedLibrary {
        guard root.isFileURL else { throw LibraryError.unsafePath(root.absoluteString) }
        let parts = DirectoryHandle.physicalComponents(root)
        let modelParts = DirectoryHandle.physicalComponents(modelsRoot)
        guard !parts.contains(".."), !parts.contains("."), !parts.contains(Self.directoryName),
              !parts.starts(with: modelParts), !modelParts.starts(with: parts) else {
            throw LibraryError.unsafePath(root.path)
        }
        let parent = try DirectoryHandle.openAbsolute(root)
        if !parent.exists(Self.directoryName) {
            guard allowCreate, expectedID == nil else { throw LibraryError.unavailable(root.path) }
            try create(in: parent)
        }
        let owned = try parent.directory(Self.directoryName)
        guard owned.exists("manifest.json") else { throw LibraryError.unmarkedLibrary }
        let bytes = try owned.read("manifest.json", maximum: 65536)
        let manifest: LibraryManifest
        do { manifest = try JSONDecoder().decode(LibraryManifest.self, from: bytes) }
        catch { throw LibraryError.unmarkedLibrary }
        guard manifest.application == "TalkTrack" else { throw LibraryError.unmarkedLibrary }
        guard manifest.formatVersion == 1 else { throw LibraryError.unsupportedVersion(manifest.formatVersion) }
        guard expectedID == nil || manifest.libraryID == expectedID else { throw LibraryError.wrongIdentity }
        _ = try owned.directory("Meetings")
        return OpenedLibrary(root: root, directory: root.appendingPathComponent(Self.directoryName, isDirectory: true), manifest: manifest)
    }

    private func create(in parent: DirectoryHandle) throws {
        let stage = ".talktrack-create-\(UUID().uuidString)"
        guard mkdirat(parent.fd, stage, 0o700) == 0 else {
            throw LibraryError.io(operation: "stage a library", code: errno)
        }
        let directory = try parent.directory(stage)
        // Only these known entries belong to this initialization attempt.
        defer {
            if !directory.published {
                unlinkat(directory.fd, "manifest.json", 0)
                unlinkat(directory.fd, "Meetings", AT_REMOVEDIR)
                unlinkat(parent.fd, stage, AT_REMOVEDIR)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try directory.writeExclusive("manifest.json", data: encoder.encode(LibraryManifest(id: UUID())))
        guard mkdirat(directory.fd, "Meetings", 0o700) == 0, fsync(directory.fd) == 0 else {
            throw LibraryError.io(operation: "prepare a library", code: errno)
        }
        guard renameatx_np(parent.fd, stage, parent.fd, Self.directoryName, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { return } // Validate the concurrent creator's manifest next.
            throw LibraryError.io(operation: "publish a library", code: errno)
        }
        // The staged fd now names the published directory: do not clean its contents.
        directory.published = true
        guard fsync(parent.fd) == 0 else { throw LibraryError.io(operation: "sync the session folder", code: errno) }
    }
}

/// Descriptor-relative traversal prevents parent/leaf symlinks from escaping.
/// Kept internal; every handle is consumed only on its owning service executor.
final class DirectoryHandle {
    let fd: Int32
    var published = false
    init(_ fd: Int32) { self.fd = fd }
    deinit { close(fd) }

    static func openAbsolute(_ url: URL) throws -> DirectoryHandle {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw LibraryError.unsafePath(url.path) }
        let parts = physicalComponents(url)
        guard !parts.contains(".."), !parts.contains(".") else { throw LibraryError.unsafePath(url.path) }
        var handle = DirectoryHandle(Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        for part in parts.dropFirst() { handle = try handle.directory(part) }
        return handle
    }

    static func physicalComponents(_ url: URL) -> [String] {
        var parts = url.pathComponents
        // Foundation returns these immutable macOS system aliases even after
        // resolvingSymlinksInPath(). Expand only these roots; never user links.
        if parts.count > 1 && ["var", "tmp", "etc"].contains(parts[1]) { parts.insert("private", at: 1) }
        return parts
    }

    func exists(_ name: String) -> Bool {
        var info = stat()
        return fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
    }

    func directory(_ name: String) throws -> DirectoryHandle {
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else {
            if errno == ELOOP || errno == ENOTDIR { throw LibraryError.unsafePath(name) }
            throw LibraryError.unavailable(name)
        }
        return DirectoryHandle(child)
    }

    /// Entry names, sorted, without "." and "..".
    func names() throws -> [String] {
        guard let stream = fdopendir(dup(fd)) else { throw LibraryError.io(operation: "read a folder", code: errno) }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    func read(_ name: String, maximum: Int) throws -> Data {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw LibraryError.unsafePath(name) }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximum else { throw LibraryError.unsafePath(name) }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let count = data.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress!.advanced(by: offset), remaining) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LibraryError.io(operation: "read \(name)", code: errno) }
            offset += count
        }
        return data
    }

    func writeExclusive(_ name: String, data: Data) throws {
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw LibraryError.io(operation: "create \(name)", code: errno) }
        defer { close(file) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(file, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LibraryError.io(operation: "write \(name)", code: errno) }
            offset += count
        }
        guard fsync(file) == 0 else { throw LibraryError.io(operation: "sync \(name)", code: errno) }
    }

    func removeTree(_ name: String) throws {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw LibraryError.io(operation: "inspect deleted meeting files", code: errno)
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            let child = try directory(name)
            guard let stream = fdopendir(dup(child.fd)) else { throw LibraryError.io(operation: "read meeting folder", code: errno) }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                let item = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if item != "." && item != ".." { try child.removeTree(item) }
            }
            guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw LibraryError.io(operation: "remove deleted meeting folder", code: errno) }
        } else {
            guard unlinkat(fd, name, 0) == 0 else { throw LibraryError.io(operation: "remove deleted meeting file", code: errno) }
        }
    }

    func createDirectory(_ name: String) throws -> DirectoryHandle {
        guard mkdirat(fd, name, 0o700) == 0 || errno == EEXIST else {
            throw LibraryError.io(operation: "create \(name)", code: errno)
        }
        return try directory(name)
    }

    func replace(_ name: String, data: Data) throws {
        let temporary = ".pending-\(UUID().uuidString)"
        defer { unlinkat(fd, temporary, 0) }
        try writeExclusive(temporary, data: data)
        guard renameat(fd, temporary, fd, name) == 0, fsync(fd) == 0 else {
            throw LibraryError.io(operation: "save \(name)", code: errno)
        }
    }

    func removeFile(_ name: String) throws {
        guard unlinkat(fd, name, 0) == 0 || errno == ENOENT else {
            throw LibraryError.io(operation: "remove \(name)", code: errno)
        }
        guard fsync(fd) == 0 else { throw LibraryError.io(operation: "sync recovery folder", code: errno) }
    }
}
