import Darwin
import Foundation
import os
import TalkTrackAudio
import TalkTrackDomain

/// What the Models folder keeps (clean-models-folder D1): installations of the
/// active catalog, legacy installations that unfinished jobs still name,
/// staging of active manifests, and the lock files of every catalog path.
public struct ModelFolderKeepSet: Equatable, Sendable {
    public let activeInstallations: Set<String>
    public let legacyInstallations: Set<String>
    /// `.downloads/<fingerprint>` names of active manifests.
    public let activeStaging: Set<String>
    /// `.locks/<sha256(path)>` names of every active and legacy path.
    public let lockNames: Set<String>
    /// Legacy installations an unfinished job names; they stay.
    public let pinnedLegacy: Set<String>

    public init(active: [ModelManifest], legacy: [ModelManifest], pinned: some Sequence<RelativePath>) throws {
        activeInstallations = Set(try active.map { try $0.installationPath.value })
        legacyInstallations = Set(try legacy.map { try $0.installationPath.value })
        activeStaging = Set(try active.map { try SessionStore.fingerprint($0) })
        lockNames = Set(activeInstallations.union(legacyInstallations).map(ModelDownloadFiles.lockName))
        let named = Set(pinned.map { $0.value.lowercased() })
        pinnedLegacy = legacyInstallations.filter { named.contains($0.lowercased()) }
    }

    /// Installation folders that stay, compared without case (APFS default).
    var keptInstallations: Set<String> { Set(activeInstallations.union(pinnedLegacy).map { $0.lowercased() }) }
}

extension ModelCatalog {
    /// The keep set of this catalog; `directories` are the model folders of
    /// unfinished jobs (`SessionStore.modelDirectoriesOfUnfinishedJobs()`).
    public func folderKeepSet(pinning directories: some Sequence<RelativePath>) throws -> ModelFolderKeepSet {
        try ModelFolderKeepSet(active: models, legacy: legacyModels, pinned: directories)
    }
}

/// What one cleanup pass did. Paths are relative to the Models folder.
public struct ModelCleanupReport: Equatable, Sendable {
    public var removed: [String] = []
    public var freedBytes: Int64 = 0
    /// Legacy installations kept for unfinished jobs.
    public var keptLegacy: [String] = []
    /// Held by another operation or process, or staging written within the last hour.
    public var skippedBusy: [String] = []
    public var failed: [String] = []
    public var milliseconds = 0

    public init() {}
}

extension ModelDownloadFiles {
    static let modelsLog = Logger(subsystem: CaptureLog.subsystem, category: "models")
    static let trashName = ".trash"
    /// Staging changed more recently than this may belong to another process's download.
    static let recentStaging: TimeInterval = 3600

    /// One pass over the Models folder, then removal of what it moved aside, and
    /// the `models` log line (clean-models-folder D2, D5). Never throws.
    public func cleanUp(keeping keep: ModelFolderKeepSet) async -> ModelCleanupReport {
        let start = ContinuousClock.now
        var report = ModelCleanupReport()
        do { report = try removeUnused(keeping: keep) }
        catch { Self.modelsLog.error("model cleanup failed error=\(String(describing: error), privacy: .public)") }
        // Deleting runs outside the actor: downloads and leases are not held up.
        // It also runs after a failed pass, so nothing moved aside stays.
        let root = rootURL
        await Task.detached(priority: .utility) { try? Self.emptyTrash(root: root) }.value
        report.milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
        for path in report.removed { Self.modelsLog.log("model cleanup removed \(path, privacy: .public)") }
        for path in report.skippedBusy { Self.modelsLog.log("model cleanup skipped \(path, privacy: .public)") }
        for path in report.failed { Self.modelsLog.error("model cleanup could not remove \(path, privacy: .public)") }
        Self.modelsLog.log("""
            model cleanup removed=\(report.removed.count, privacy: .public) freed=\(report.freedBytes, privacy: .public) \
            kept-legacy=\(report.keptLegacy.count, privacy: .public) skipped-busy=\(report.skippedBusy.count, privacy: .public) \
            ms=\(report.milliseconds, privacy: .public)
            """)
        return report
    }

    /// Moves everything outside `keep` into `.trash` (clean-models-folder D1–D3).
    /// Installed and resumable catalog models stay; within them only `.DS_Store`
    /// goes. Symbolic links are moved, never followed. An installation whose
    /// operation lock someone holds is skipped until the next pass.
    func removeUnused(keeping keep: ModelFolderKeepSet, now: Date = Date()) throws -> ModelCleanupReport {
        let root = try root()
        // A file in the way of .trash is a leftover like any other.
        if root.exists(Self.trashName) && Self.kind(Self.trashName, in: root) != S_IFDIR { unlinkat(root.fd, Self.trashName, 0) }
        let trash = try root.createDirectory(Self.trashName)
        var report = ModelCleanupReport()
        let kept = keep.keptInstallations
        let ancestors = Set(kept.flatMap { path -> [String] in
            let parts = path.split(separator: "/")
            return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
        })
        let busyPaths = Set(active.keys.map { $0.lowercased() })
        let busyStaging = Set(active.values.map(\.fingerprint))

        func move(_ name: String, from parent: DirectoryHandle, path: String) {
            let bytes = Self.byteCount(name, in: parent)
            guard renameat(parent.fd, name, trash.fd, UUID().uuidString) == 0 else {
                report.failed.append(path)
                return
            }
            report.removed.append(path)
            report.freedBytes += bytes
        }

        func removeIfEmpty(_ name: String, in parent: DirectoryHandle, path: String) {
            if unlinkat(parent.fd, name, AT_REMOVEDIR) == 0 { report.removed.append(path) }
        }

        /// Finder metadata inside a kept installation makes a later repair fail.
        func sweepFinderFiles(_ directory: DirectoryHandle, path: String) {
            guard let names = try? directory.names() else { report.failed.append(path); return }
            for name in names {
                let child = path + "/" + name
                switch Self.kind(name, in: directory) {
                case S_IFREG where name == ".DS_Store": move(name, from: directory, path: child)
                case S_IFDIR:
                    guard let sub = try? directory.directory(name) else { report.failed.append(child); continue }
                    sweepFinderFiles(sub, path: child)
                default: continue
                }
            }
        }

        /// A folder that may hold other folders to keep or lock: cleaned entry by
        /// entry. When it cannot be read, it goes whole unless something kept is inside.
        func descend(_ name: String, in parent: DirectoryHandle, path: String, depth: Int) {
            do { try clean(parent.directory(name), path: path, depth: depth) }
            catch {
                if ancestors.contains(path.lowercased()) { report.failed.append(path) }
                else { move(name, from: parent, path: path) }
                return
            }
            removeIfEmpty(name, in: parent, path: path)
        }

        func clean(_ directory: DirectoryHandle, path: String, depth: Int) throws {
            for name in try directory.names() {
                let child = path + "/" + name, key = child.lowercased()
                let isDirectory = Self.kind(name, in: directory) == S_IFDIR
                if isDirectory && kept.contains(key) {
                    if keep.pinnedLegacy.contains(where: { $0.lowercased() == key }) { report.keptLegacy.append(child) }
                    if let installed = try? directory.directory(name) { sweepFinderFiles(installed, path: child) }
                    else { report.failed.append(child) }
                } else if !isDirectory {
                    move(name, from: directory, path: child)
                } else if ancestors.contains(key) || depth < 2 {
                    descend(name, in: directory, path: child, depth: depth + 1)
                } else if busyPaths.contains(key) {
                    report.skippedBusy.append(child)
                } else {
                    // An installation outside the catalog; another process may be using it.
                    guard let lock = try? operationLock(path: child) else {
                        report.skippedBusy.append(child)
                        continue
                    }
                    move(name, from: directory, path: child)
                    let lockName = Self.lockName(child)
                    if !keep.lockNames.contains(lockName), let locks = try? root.directory(".locks") {
                        unlinkat(locks.fd, lockName, 0)
                    }
                    try? lock.close()
                }
            }
        }

        for name in try root.names() {
            switch name {
            case Self.trashName, ".locks":
                continue
            case ".downloads" where Self.kind(name, in: root) == S_IFDIR:
                guard let staging = try? root.directory(name), let entries = try? staging.names() else {
                    report.failed.append(name)
                    continue
                }
                for entry in entries {
                    let path = name + "/" + entry
                    let isDirectory = Self.kind(entry, in: staging) == S_IFDIR
                    if busyStaging.contains(entry) { continue }
                    // A resumable download; an unreadable one is left for the user to see.
                    if isDirectory && keep.activeStaging.contains(entry),
                       (try? staging.directory(entry).names().isEmpty) != true { continue }
                    if Self.newestChange(entry, in: staging) > now.addingTimeInterval(-Self.recentStaging) {
                        report.skippedBusy.append(path)
                        continue
                    }
                    move(entry, from: staging, path: path)
                }
            default:
                if Self.kind(name, in: root) == S_IFDIR && !name.hasPrefix(".") {
                    descend(name, in: root, path: name, depth: 1)
                } else {
                    move(name, from: root, path: name)
                }
            }
        }

        // Lock files last: those of installations removed above are already gone.
        if Self.kind(".locks", in: root) == S_IFDIR {
            guard let locks = try? root.directory(".locks"), let names = try? locks.names() else {
                report.failed.append(".locks")
                if !report.removed.isEmpty { fsync(trash.fd) }
                return report
            }
            for name in names where !keep.lockNames.contains(name) {
                let path = ".locks/" + name
                guard Self.kind(name, in: locks) == S_IFREG else { move(name, from: locks, path: path); continue }
                let descriptor = openat(locks.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard descriptor >= 0 else { report.failed.append(path); continue }
                defer { close(descriptor) }
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { report.skippedBusy.append(path); continue }
                if unlinkat(locks.fd, name, 0) == 0 { report.removed.append(path) } else { report.failed.append(path) }
            }
        } else if root.exists(".locks") {
            move(".locks", from: root, path: ".locks")
        }
        if !report.removed.isEmpty { fsync(trash.fd) }
        return report
    }

    /// Deletes what passes moved into `.trash`, including what an interrupted
    /// deletion left. Needs no actor: nothing else uses `.trash`.
    /// `afterEach` lets tests stop after one item.
    static func emptyTrash(root: URL, afterEach: (String) throws -> Void = { _ in }) throws {
        let rootHandle: DirectoryHandle
        do { rootHandle = try DirectoryHandle.openAbsolute(root) } catch { return }
        guard kind(trashName, in: rootHandle) == S_IFDIR else { return }
        let trash = try rootHandle.directory(trashName)
        for name in try trash.names() {
            do { try deleteTree(name, in: trash) }
            catch { modelsLog.error("model cleanup could not delete \(name, privacy: .public)") }
            try afterEach(name)
        }
        unlinkat(rootHandle.fd, trashName, AT_REMOVEDIR)
    }

    /// Like `removeTree`, but folders the user made unreadable are opened up
    /// first: everything in `.trash` is TalkTrack's to delete. Never follows links.
    static func deleteTree(_ name: String, in directory: DirectoryHandle) throws {
        if kind(name, in: directory) == S_IFDIR {
            fchmodat(directory.fd, name, 0o700, AT_SYMLINK_NOFOLLOW)
            let child = try directory.directory(name)
            for entry in try child.names() { try deleteTree(entry, in: child) }
            guard unlinkat(directory.fd, name, AT_REMOVEDIR) == 0 else {
                throw LibraryError.io(operation: "delete an unused model folder", code: errno)
            }
        } else if unlinkat(directory.fd, name, 0) != 0 && errno != ENOENT {
            throw LibraryError.io(operation: "delete an unused model file", code: errno)
        }
    }

    static func kind(_ name: String, in directory: DirectoryHandle) -> mode_t {
        var info = stat()
        guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return 0 }
        return info.st_mode & S_IFMT
    }

    /// Logical bytes of regular files, without following links.
    static func byteCount(_ name: String, in directory: DirectoryHandle) -> Int64 {
        var info = stat()
        guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return 0 }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return Int64(info.st_size)
        case S_IFDIR:
            guard let child = try? directory.directory(name), let names = try? child.names() else { return 0 }
            return names.reduce(0) { $0 + byteCount($1, in: child) }
        default: return 0
        }
    }

    /// The newest modification of an entry or anything inside it.
    static func newestChange(_ name: String, in directory: DirectoryHandle) -> Date {
        var info = stat()
        guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return .distantPast }
        var newest = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        if info.st_mode & S_IFMT == S_IFDIR, let child = try? directory.directory(name), let names = try? child.names() {
            for entry in names { newest = max(newest, newestChange(entry, in: child)) }
        }
        return newest
    }
}
