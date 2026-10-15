import CryptoKit
import Darwin
import Foundation

/// The active library's root, saved as `LibraryLocation.json` in
/// Application Support/TalkTrack. Without it the default root is used.
public struct LibraryLocationStore: Sendable {
    public static let fileName = "LibraryLocation.json"
    public static var defaultSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TalkTrack", isDirectory: true)
    }
    public let support: URL

    public init(support: URL = Self.defaultSupport) { self.support = support }

    public func load() throws -> LibraryLocation? {
        guard FileManager.default.fileExists(atPath: support.path) else { return nil }
        let directory = try DirectoryHandle.openAbsolute(support.resolvingSymlinksInPath())
        guard directory.exists(Self.fileName) else { return nil }
        do { return try JSONDecoder().decode(LibraryLocation.self, from: directory.read(Self.fileName, maximum: 1 << 20)) }
        catch let error as LibraryError { throw error }
        catch { throw LibraryError.unavailable("library location record") }
    }

    public func save(_ location: LibraryLocation) throws {
        try supportDirectory().replace(Self.fileName, data: Self.encoder.encode(location))
    }

    func supportDirectory() throws -> DirectoryHandle {
        do { try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true) }
        catch { throw LibraryError.io(operation: "create the application support folder", code: EACCES) }
        return try DirectoryHandle.openAbsolute(support.resolvingSymlinksInPath())
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// The durable record of one move, in Application Support/TalkTrack/Migrations.
/// It names both roots, the staging folder and every owned item, so relaunch
/// can tell which copy is authoritative and remove only TalkTrack's own files.
public struct LibraryMigrationJournal: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// The source is authoritative; the staging copy may be incomplete.
        case copying
        /// Every file of the staging copy was verified; it may already be renamed.
        case verified
        /// The destination is authoritative; old owned files are being removed.
        case committed
    }

    public struct Entry: Codable, Equatable, Sendable {
        /// Relative to `.talktrack-library`, components separated by "/".
        public let path: String
        public let directory: Bool
        public let size: Int64
        public let modified: Double
        public var sha256: String?
    }

    public let id: UUID
    public let libraryID: UUID
    public let sourceRoot: String
    public let destinationRoot: String
    /// The staging folder's name inside the destination root.
    public let staging: String
    /// Volume UUIDs, so an empty mount point left by a disconnected disk is
    /// never mistaken for the folder itself.
    public var sourceVolume: String?
    public var destinationVolume: String?
    public let startedAt: Date
    public var phase: Phase
    public var entries: [Entry]
}

public enum LibraryMigrationError: Error, Equatable, LocalizedError, Sendable {
    case recording
    case sameFolder
    case nested
    case protectedFolder
    case destinationHasLibrary
    case destinationUnavailable(String)
    case notWritable(String)
    case insufficientSpace(needed: Int64, available: Int64)
    case unexpectedItem(String)
    case databaseBusy
    case changedDuringMove(String)
    case verificationFailed(String)
    case cancelled
    case unfinishedMove(String)

    public var errorDescription: String? {
        switch self {
        case .recording: "Stop recording before moving the library."
        case .sameFolder: "The library is already in this folder."
        case .nested: "Choose a folder that is neither inside the current library folder nor contains it."
        case .protectedFolder: "This folder holds TalkTrack's models or settings. Choose another folder."
        case .destinationHasLibrary: "This folder already contains a TalkTrack library. Choose another folder; libraries are never merged or overwritten."
        case .destinationUnavailable(let path): "The folder \(path) is unavailable. Reconnect the disk or choose another folder."
        case .notWritable(let path): "TalkTrack cannot write to \(path). Choose a folder you can write to."
        case .insufficientSpace(let needed, let available):
            "Not enough free space: the move needs \(Self.bytes(needed)), the destination has \(Self.bytes(available))."
        case .unexpectedItem(let path): "The library contains an item TalkTrack did not create (\(path)). Remove it or move it out, then retry."
        case .databaseBusy: "The library database is still in use. Wait for processing to stop, then retry."
        case .changedDuringMove(let path): "Library files changed during the move (\(path)). Retry."
        case .verificationFailed(let path): "The copy could not be verified (\(path)). The destination may be failing or disconnected."
        case .cancelled: "The move was cancelled."
        case .unfinishedMove(let path): "An earlier move left a partial copy in \(path). Reconnect that folder and relaunch TalkTrack so it can be removed."
        }
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

public struct LibraryMigrationPlan: Equatable, Sendable {
    public let sourceRoot: URL
    public let destinationRoot: URL
    public let libraryID: UUID
    public let files: Int
    public let bytes: Int64
    /// Library size plus a margin for the destination's own bookkeeping.
    public let requiredBytes: Int64
    public let availableBytes: Int64?
}

public struct LibraryMigrationProgress: Equatable, Sendable {
    public enum Stage: Equatable, Sendable { case copying, verifying, switching, cleaning }
    public let stage: Stage
    public let completedBytes: Int64
    public let totalBytes: Int64
}

public struct LibraryMigrationOutcome: Equatable, Sendable {
    public let location: LibraryLocation
    public let root: URL
    /// Items left in the old library folder (not created by TalkTrack, or not
    /// removable now). Cleanup is retried at launch; the new library is in use.
    public let cleanupPending: Int
}

/// What relaunch did with a move that did not finish.
public enum LibraryMigrationRecovery: Equatable, Sendable {
    /// Interrupted before the switch: the partial copy was removed; the old root stays.
    case discarded(source: String)
    /// Interrupted after the switch: the new root is in use and the old files are gone.
    case completed(destination: String)
    /// The new root is in use; some old owned items are still there.
    case cleanupPending(source: String, items: Int)
    /// The partial copy's folder is unreachable; the old root stays and the copy remains.
    case destinationUnavailable(String)
    /// The new root is in use; the old folder is unreachable, so its files remain until it is reconnected.
    case sourceUnavailable(String)
}

/// Fault-injection boundaries for tests (`LibraryMigrator.failpoint`).
public enum LibraryMigrationStep: Equatable, Sendable {
    case journaled, copied(Int), copiedAll, verified, renamed, pointerSaved, committed, cleaned(Int)
}

/// Thrown from a failpoint to stop as a crash would: no rollback, no cleanup.
public struct SimulatedTermination: Error, Equatable {
    public init() {}
}

/// Moves the owned `.talktrack-library` to another root: journaled streaming
/// copy with SHA-256, verification of every file and the database, an
/// exclusive rename, then the location switch, then removal of the old owned
/// files only. Nothing outside `.talktrack-library` is ever moved or deleted,
/// and the source stays authoritative until the switch.
///
/// The caller quiesces the library first (no capture, jobs stopped, notes
/// saved, `SessionStore.close()`), and runs `recover()` at launch before
/// opening any library.
public actor LibraryMigrator {
    public static let stagingPrefix = ".talktrack-move-"
    private let locations: LibraryLocationStore
    private let protectedRoots: [[String]]
    private let modelsRoot: URL
    private let availableSpace: @Sendable (URL) -> Int64?
    private let failpoint: @Sendable (LibraryMigrationStep) throws -> Void
    private static let chunk = 1 << 20
    private static let sidecars: Set<String> = ["Library.sqlite3-wal", "Library.sqlite3-shm"]

    public init(locations: LibraryLocationStore = LibraryLocationStore(),
                modelsRoot: URL? = nil,
                availableSpace: @escaping @Sendable (URL) -> Int64? = LibraryMigrator.volumeAvailableBytes,
                failpoint: @escaping @Sendable (LibraryMigrationStep) throws -> Void = { _ in }) {
        self.locations = locations
        let models = (modelsRoot ?? locations.support.appendingPathComponent("Models", isDirectory: true))
        self.modelsRoot = models
        protectedRoots = [Self.components(locations.support), Self.components(models)]
        self.availableSpace = availableSpace
        self.failpoint = failpoint
    }

    /// Space for important data (includes purgeable space); volumes that do
    /// not report it (disk images, some external disks) give plain free space.
    public static let volumeAvailableBytes: @Sendable (URL) -> Int64? = { url in
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    static func volume(_ url: URL) -> String? {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// The folder, if reachable on the volume the journal recorded.
    private static func reachable(_ path: String, volume: String?) -> DirectoryHandle? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let handle = try? DirectoryHandle.openAbsolute(url) else { return nil }
        if let volume, Self.volume(url) != volume { return nil }
        return handle
    }

    // MARK: Validation

    /// Checks a destination without changing anything. Safe while the library is open.
    public func plan(source: OpenedLibrary, destination: URL, recording: Bool) throws -> LibraryMigrationPlan {
        guard !recording else { throw LibraryMigrationError.recording }
        if let journal = try journals().first { throw LibraryMigrationError.unfinishedMove(journal.destinationRoot) }
        let sourceParts = Self.components(source.root), destinationParts = Self.components(destination)
        guard sourceParts != destinationParts else { throw LibraryMigrationError.sameFolder }
        guard !sourceParts.starts(with: destinationParts), !destinationParts.starts(with: sourceParts),
              !destinationParts.contains(OwnedLibrary.directoryName),
              !destinationParts.contains(where: { $0.hasPrefix(Self.stagingPrefix) }) else { throw LibraryMigrationError.nested }
        // Only the owned child is created, so a destination may contain these folders.
        guard !protectedRoots.contains(where: { destinationParts.starts(with: $0) }) else {
            throw LibraryMigrationError.protectedFolder
        }
        let target: DirectoryHandle
        do { target = try DirectoryHandle.openAbsolute(destination.resolvingSymlinksInPath()) }
        catch { throw LibraryMigrationError.destinationUnavailable(destination.path) }
        guard !target.exists(OwnedLibrary.directoryName) else { throw LibraryMigrationError.destinationHasLibrary }
        guard faccessat(target.fd, ".", W_OK, 0) == 0 else { throw LibraryMigrationError.notWritable(destination.path) }
        let entries = try inventory(source.directory)
        let bytes = entries.reduce(Int64(0)) { $0 + $1.size }
        let required = bytes + max(64 << 20, bytes / 20)
        let available = availableSpace(destination)
        if let available, available < required {
            throw LibraryMigrationError.insufficientSpace(needed: required, available: available)
        }
        return LibraryMigrationPlan(sourceRoot: source.root, destinationRoot: destination, libraryID: source.manifest.libraryID,
                                    files: entries.filter { !$0.directory }.count, bytes: bytes,
                                    requiredBytes: required, availableBytes: available)
    }

    // MARK: Move

    /// Moves a quiesced library. Before the switch any error removes the
    /// staging copy and leaves the source authoritative; cancellation is
    /// honoured until then.
    public func migrate(source: OpenedLibrary, destination: URL,
                        progress: @escaping @Sendable (LibraryMigrationProgress) -> Void = { _ in }) async throws -> LibraryMigrationOutcome {
        let plan = try plan(source: source, destination: destination, recording: false)
        let owned = try DirectoryHandle.openAbsolute(source.directory)
        var walInfo = stat()
        if fstatat(owned.fd, "Library.sqlite3-wal", &walInfo, AT_SYMLINK_NOFOLLOW) == 0, walInfo.st_size > 0 {
            throw LibraryMigrationError.databaseBusy
        }
        let id = UUID()
        var journal = LibraryMigrationJournal(
            id: id, libraryID: plan.libraryID, sourceRoot: Self.path(source.root), destinationRoot: Self.path(destination),
            staging: Self.stagingPrefix + id.uuidString, startedAt: Date(), phase: .copying,
            entries: try inventory(source.directory))
        journal.sourceVolume = Self.volume(source.root)
        journal.destinationVolume = Self.volume(destination)
        let total = plan.bytes
        try save(journal)
        try failpoint(.journaled)
        let target = try DirectoryHandle.openAbsolute(destination.resolvingSymlinksInPath())
        do {
            guard mkdirat(target.fd, journal.staging, 0o700) == 0 else {
                throw LibraryError.io(operation: "create the destination folder", code: errno)
            }
            let staging = try target.directory(journal.staging)
            try copy(&journal, from: owned, to: staging, total: total, progress: progress)
            try failpoint(.copiedAll)
            progress(.init(stage: .verifying, completedBytes: 0, totalBytes: total))
            try verify(journal, source: owned, staging: staging, stagingPath: Self.path(destination) + "/" + journal.staging,
                       total: total, progress: progress)
            journal.phase = .verified
            try save(journal)
            try failpoint(.verified)
            try Task.checkCancellation()
        } catch is SimulatedTermination {
            throw SimulatedTermination()
        } catch {
            // A partial copy that cannot be removed now (disconnected disk) keeps
            // its journal, so launch recovery removes it once reachable.
            if (try? discard(journal, in: target)) != nil { try? deleteJournal(journal) }
            if error is CancellationError { throw LibraryMigrationError.cancelled }
            throw error
        }
        progress(.init(stage: .switching, completedBytes: total, totalBytes: total))
        guard renameatx_np(target.fd, journal.staging, target.fd, OwnedLibrary.directoryName, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            try? discard(journal, in: target)
            try? deleteJournal(journal)
            if code == EEXIST { throw LibraryMigrationError.destinationHasLibrary }
            throw LibraryError.io(operation: "switch to the copied library", code: code)
        }
        fsync(target.fd)
        try failpoint(.renamed)
        let location: LibraryLocation
        do {
            let opened = try await OwnedLibrary(modelsRoot: modelsRoot)
                .open(root: destination, expectedID: plan.libraryID, allowCreate: false)
            location = try opened.makeLocation()
            try locations.save(location)
        } catch {
            // Not yet authoritative: put the copy back to staging and remove it.
            if renameatx_np(target.fd, OwnedLibrary.directoryName, target.fd, journal.staging, UInt32(RENAME_EXCL)) == 0 {
                try? discard(journal, in: target)
                try? deleteJournal(journal)
            }
            throw error
        }
        try failpoint(.pointerSaved)
        journal.phase = .committed
        try save(journal)
        try failpoint(.committed)
        progress(.init(stage: .cleaning, completedBytes: total, totalBytes: total))
        let pending = try cleanup(journal) ?? journal.entries.count
        if pending == 0 { try deleteJournal(journal) }
        return LibraryMigrationOutcome(location: location, root: destination, cleanupPending: pending)
    }

    // MARK: Recovery

    /// Resolves every unfinished move. Run before opening the library: the
    /// location record (possibly rewritten here) then names the authoritative root.
    public func recover() async throws -> [LibraryMigrationRecovery] {
        var results: [LibraryMigrationRecovery] = []
        for var journal in try journals() {
            let pointer = try locations.load()
            var committed = journal.phase == .committed
                || (pointer?.libraryID == journal.libraryID && pointer?.rootPath.map { Self.path(URL(fileURLWithPath: $0)) } == journal.destinationRoot)
            let destination = URL(fileURLWithPath: journal.destinationRoot, isDirectory: true)
            let target = Self.reachable(journal.destinationRoot, volume: journal.destinationVolume)
            if !committed, journal.phase == .verified, let target, !target.exists(journal.staging),
               let opened = try? await OwnedLibrary(modelsRoot: modelsRoot).open(root: destination, expectedID: journal.libraryID, allowCreate: false) {
                // Renamed before the location was saved: the copy is complete and verified.
                try locations.save(opened.makeLocation())
                committed = true
            }
            if committed {
                if journal.phase != .committed { journal.phase = .committed; try save(journal) }
                switch try cleanup(journal) {
                case nil: results.append(.sourceUnavailable(journal.sourceRoot))
                case 0?:
                    try deleteJournal(journal)
                    results.append(.completed(destination: journal.destinationRoot))
                case let pending?: results.append(.cleanupPending(source: journal.sourceRoot, items: pending))
                }
            } else if let target {
                try discard(journal, in: target)
                try deleteJournal(journal)
                results.append(.discarded(source: journal.sourceRoot))
            } else {
                results.append(.destinationUnavailable(journal.destinationRoot))
            }
        }
        return results
    }

    /// Unfinished moves, oldest first.
    public func journals() throws -> [LibraryMigrationJournal] {
        guard FileManager.default.fileExists(atPath: locations.support.appendingPathComponent("Migrations").path) else { return [] }
        let directory = try migrationsDirectory()
        return try directory.names().filter { $0.hasSuffix(".json") }.map {
            try JSONDecoder().decode(LibraryMigrationJournal.self, from: directory.read($0, maximum: 256 << 20))
        }.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: Steps

    private func inventory(_ library: URL) throws -> [LibraryMigrationJournal.Entry] {
        var entries: [LibraryMigrationJournal.Entry] = []
        func walk(_ directory: DirectoryHandle, _ prefix: String) throws {
            for name in try directory.names() {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if prefix.isEmpty && Self.sidecars.contains(name) { continue }
                var info = stat()
                guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw LibraryError.io(operation: "read the library", code: errno)
                }
                let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    entries.append(.init(path: path, directory: true, size: 0, modified: 0, sha256: nil))
                    try walk(directory.directory(name), path)
                case S_IFREG:
                    entries.append(.init(path: path, directory: false, size: Int64(info.st_size), modified: modified, sha256: nil))
                default:
                    throw LibraryMigrationError.unexpectedItem(path)
                }
            }
        }
        try walk(DirectoryHandle.openAbsolute(library), "")
        return entries
    }

    private func copy(_ journal: inout LibraryMigrationJournal, from source: DirectoryHandle, to staging: DirectoryHandle,
                      total: Int64, progress: @Sendable (LibraryMigrationProgress) -> Void) throws {
        var sourceParents = ParentCache(root: source), stagingParents = ParentCache(root: staging)
        var done: Int64 = 0, reported: Int64 = 0
        for index in journal.entries.indices {
            let entry = journal.entries[index]
            let (parent, name) = Self.split(entry.path)
            let to = try stagingParents.handle(parent)
            if entry.directory {
                guard mkdirat(to.fd, name, 0o700) == 0 else { throw LibraryError.io(operation: "create \(entry.path)", code: errno) }
                continue
            }
            let from = try sourceParents.handle(parent)
            let input = openat(from.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw LibraryMigrationError.changedDuringMove(entry.path) }
            defer { close(input) }
            let output = openat(to.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw LibraryError.io(operation: "create \(entry.path)", code: errno) }
            defer { close(output) }
            var hash = SHA256(), copied: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: Self.chunk)
            while true {
                if Task.isCancelled { throw CancellationError() }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress!, Self.chunk) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw LibraryError.io(operation: "read \(entry.path)", code: errno) }
                if count == 0 { break }
                hash.update(data: buffer[0..<count])
                try Self.writeAll(output, buffer, count: count, path: entry.path)
                copied += Int64(count); done += Int64(count)
                if done - reported >= 8 << 20 { reported = done; progress(.init(stage: .copying, completedBytes: done, totalBytes: total)) }
            }
            guard copied == entry.size else { throw LibraryMigrationError.changedDuringMove(entry.path) }
            guard fsync(output) == 0 else { throw LibraryError.io(operation: "save \(entry.path)", code: errno) }
            journal.entries[index].sha256 = Self.hex(hash.finalize())
            try failpoint(.copied(index))
        }
        // Make the new directory entries durable, deepest first.
        for entry in journal.entries.reversed() where entry.directory {
            guard fsync(try stagingParents.handle(entry.path).fd) == 0 else { throw LibraryError.io(operation: "save \(entry.path)", code: errno) }
        }
        guard fsync(staging.fd) == 0 else { throw LibraryError.io(operation: "save the copied library", code: errno) }
        progress(.init(stage: .copying, completedBytes: done, totalBytes: total))
    }

    private func verify(_ journal: LibraryMigrationJournal, source: DirectoryHandle, staging: DirectoryHandle, stagingPath: String,
                        total: Int64, progress: @Sendable (LibraryMigrationProgress) -> Void) throws {
        // The source must not have changed while it was copied.
        var sourceParents = ParentCache(root: source)
        for entry in journal.entries where !entry.directory {
            let (parent, name) = Self.split(entry.path)
            var info = stat()
            guard fstatat(try sourceParents.handle(parent).fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  Int64(info.st_size) == entry.size,
                  Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9 == entry.modified else {
                throw LibraryMigrationError.changedDuringMove(entry.path)
            }
        }
        // The copied database opens, is intact and belongs to this library.
        if staging.exists("Library.sqlite3") {
            do {
                let database = try SQLiteConnection(path: Self.physical(stagingPath) + "/Library.sqlite3")
                guard case .text("ok") = try database.rows("PRAGMA integrity_check").first?.first,
                      case .text(let id) = try database.rows("SELECT value FROM metadata WHERE key = 'libraryID'").first?.first,
                      id == journal.libraryID.uuidString else { throw LibraryMigrationError.verificationFailed("Library.sqlite3") }
            } catch let error as LibraryMigrationError { throw error }
            catch { throw LibraryMigrationError.verificationFailed("Library.sqlite3") }
            for sidecar in Self.sidecars { unlinkat(staging.fd, sidecar, 0) }
        }
        let manifest = try JSONDecoder().decode(LibraryManifest.self, from: staging.read("manifest.json", maximum: 65536))
        guard manifest.libraryID == journal.libraryID else { throw LibraryMigrationError.verificationFailed("manifest.json") }
        // Every copied byte is read back from the destination.
        var stagingParents = ParentCache(root: staging)
        var done: Int64 = 0, reported: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        for entry in journal.entries where !entry.directory {
            let (parent, name) = Self.split(entry.path)
            let file = openat(try stagingParents.handle(parent).fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { throw LibraryMigrationError.verificationFailed(entry.path) }
            defer { close(file) }
            var hash = SHA256(), read: Int64 = 0
            while true {
                if Task.isCancelled { throw CancellationError() }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress!, Self.chunk) }
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw LibraryMigrationError.verificationFailed(entry.path) }
                if count == 0 { break }
                hash.update(data: buffer[0..<count])
                read += Int64(count); done += Int64(count)
                if done - reported >= 8 << 20 { reported = done; progress(.init(stage: .verifying, completedBytes: done, totalBytes: total)) }
            }
            guard read == entry.size, Self.hex(hash.finalize()) == entry.sha256 else {
                throw LibraryMigrationError.verificationFailed(entry.path)
            }
        }
        // Nothing else is in the copy.
        var extra: [String] = []
        let known = Set(journal.entries.map(\.path))
        func walk(_ directory: DirectoryHandle, _ prefix: String) throws {
            for name in try directory.names() {
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if !known.contains(path) { extra.append(path); continue }
                var info = stat()
                if fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR {
                    try walk(directory.directory(name), path)
                }
            }
        }
        try walk(staging, "")
        if let first = extra.first { throw LibraryMigrationError.verificationFailed(first) }
    }

    /// Removes the old library's inventoried items, deepest first. Returns how
    /// many could not be removed (e.g. a folder holding a file TalkTrack did
    /// not create, which is kept), or nil when the old folder is unreachable
    /// (a disconnected disk): cleanup is then retried at launch.
    private func cleanup(_ journal: LibraryMigrationJournal) throws -> Int? {
        guard let root = Self.reachable(journal.sourceRoot, volume: journal.sourceVolume) else { return nil }
        guard root.exists(OwnedLibrary.directoryName) else { return 0 }
        let owned = try root.directory(OwnedLibrary.directoryName)
        if let manifest = try? JSONDecoder().decode(LibraryManifest.self, from: owned.read("manifest.json", maximum: 65536)),
           manifest.libraryID != journal.libraryID {
            return journal.entries.count // Not the library that was moved: never touch it.
        }
        var parents = ParentCache(root: owned)
        var pending = 0
        for (index, entry) in journal.entries.enumerated().reversed() {
            let (parent, name) = Self.split(entry.path)
            guard let directory = try? parents.handle(parent) else { continue } // Parent already removed.
            if unlinkat(directory.fd, name, entry.directory ? AT_REMOVEDIR : 0) != 0 && errno != ENOENT { pending += 1 }
            if entry.directory { parents.forget(entry.path) }
            try failpoint(.cleaned(index))
        }
        for sidecar in Self.sidecars { unlinkat(owned.fd, sidecar, 0) }
        if unlinkat(root.fd, OwnedLibrary.directoryName, AT_REMOVEDIR) != 0 && errno != ENOENT { pending += 1 }
        fsync(root.fd)
        return pending
    }

    private func discard(_ journal: LibraryMigrationJournal, in target: DirectoryHandle) throws {
        try target.removeTree(journal.staging)
        fsync(target.fd)
    }

    private func migrationsDirectory() throws -> DirectoryHandle {
        try locations.supportDirectory().createDirectory("Migrations")
    }

    private func save(_ journal: LibraryMigrationJournal) throws {
        try migrationsDirectory().replace("\(journal.id.uuidString).json", data: LibraryLocationStore.encoder.encode(journal))
    }

    private func deleteJournal(_ journal: LibraryMigrationJournal) throws {
        try migrationsDirectory().removeFile("\(journal.id.uuidString).json")
    }

    // MARK: Helpers

    /// Open handles for the current parent folder only, so deep libraries do
    /// not exhaust descriptors.
    private struct ParentCache {
        let root: DirectoryHandle
        var path: String?
        var current: DirectoryHandle?

        init(root: DirectoryHandle) { self.root = root }

        mutating func handle(_ parent: String) throws -> DirectoryHandle {
            if parent.isEmpty { return root }
            if parent == path, let current { return current }
            var handle = root
            for part in parent.split(separator: "/") { handle = try handle.directory(String(part)) }
            path = parent; current = handle
            return handle
        }

        mutating func forget(_ removed: String) {
            if let path, path == removed || path.hasPrefix(removed + "/") { self.path = nil; current = nil }
        }
    }

    private static func split(_ path: String) -> (parent: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    private static func writeAll(_ file: Int32, _ buffer: [UInt8], count: Int, path: String) throws {
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { Darwin.write(file, $0.baseAddress!.advanced(by: offset), count - offset) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw LibraryError.io(operation: "copy \(path)", code: errno) }
            offset += written
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    static func components(_ url: URL) -> [String] { DirectoryHandle.physicalComponents(url.resolvingSymlinksInPath()) }

    /// A canonical absolute path, comparable across `/var` and `/private/var`.
    static func path(_ url: URL) -> String { physical(url.resolvingSymlinksInPath().path) }

    private static func physical(_ path: String) -> String {
        "/" + DirectoryHandle.physicalComponents(URL(fileURLWithPath: path)).dropFirst().joined(separator: "/")
    }
}
