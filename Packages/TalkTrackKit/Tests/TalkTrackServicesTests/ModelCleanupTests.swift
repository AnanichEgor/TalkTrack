import Darwin
import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// clean-models-folder: removal of Models-folder content outside the catalog.
@Suite struct ModelCleanupTests {
    /// The fixture download manifest under another repository.
    static func variant(_ repository: String, id: String) throws -> ModelManifest {
        let (base, _) = try ModelDownloadTests.fixture()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        let revision = base.revision
        json["repository"] = repository
        json["id"] = id
        json["evidenceURL"] = "https://huggingface.co/api/models/\(repository)/revision/\(revision)?blobs=true"
        var license = try #require(json["license"] as? [String: Any])
        license["modelCardURL"] = "https://huggingface.co/\(repository)/blob/\(revision)/README.md"
        json["license"] = license
        return try JSONDecoder().decode(ModelManifest.self, from: JSONSerialization.data(withJSONObject: json))
    }

    struct Tree {
        let folder: TemporaryFolder
        let root: URL
        let files: ModelDownloadFiles
        let selected: ModelManifest, unselected: ModelManifest, resumable: ModelManifest, legacy: ModelManifest
        let bodies: [String: Data]
        let outside: URL
        let heldLock: Int32
        let heldLockName: String

        func keep(pinned: Bool) throws -> ModelFolderKeepSet {
            try ModelFolderKeepSet(active: [selected, unselected, resumable], legacy: [legacy],
                                   pinned: pinned ? [legacy.installationPath] : [])
        }
        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(url(path).path, &info) == 0
        }
        func write(_ path: String, _ text: String = "x") throws {
            try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url(path))
        }
        func names(_ path: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url(path).path)) ?? []).sorted()
        }
    }

    static let oldRevision = String(repeating: "a", count: 40)
    static let candidateRevision = String(repeating: "b", count: 40)

    /// Installed, unselected, partial and legacy models plus every kind of leftover.
    static func tree() async throws -> Tree {
        let folder = try TemporaryFolder()
        let root = folder.url.appendingPathComponent("Models")
        let files = ModelDownloadFiles(testRoot: root)
        let (selected, bodies) = try ModelDownloadTests.fixture()
        let unselected = try variant("fixture-owner/unselected", id: "fixture-unselected")
        let resumable = try variant("fixture-owner/resumable", id: "fixture-resumable")
        let legacy = try variant("legacy-owner/legacy", id: "fixture-legacy")
        let coordinator = ModelDownloadCoordinator(files: files, transport: FixtureModelTransport(content: bodies))
        for manifest in [selected, unselected, legacy] { try await coordinator.download(manifest) { _, _ in } }
        // A partial download of an active model, paused after half of the weights.
        let paused = FixtureModelTransport(content: bodies, behavior: .paused)
        let pausing = ModelDownloadCoordinator(files: files, transport: paused)
        let task = Task { try await pausing.download(resumable) { _, _ in } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await paused.pausedAfterWrite), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await pausing.cancelAndWait(resumable)
        _ = try? await task.value

        let outside = folder.url.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: outside.appendingPathComponent("file.txt"))
        let tree = Tree(folder: folder, root: root, files: files, selected: selected, unselected: unselected,
                        resumable: resumable, legacy: legacy, bodies: bodies, outside: outside,
                        heldLock: -1, heldLockName: "")
        let selectedPath = try selected.installationPath.value
        let repository = selectedPath.split(separator: "/").prefix(2).joined(separator: "/")
        try tree.write("\(repository)/\(oldRevision)/model.safetensors", "old revision")
        try tree.write("candidate-owner/candidate-model/\(candidateRevision)/model.safetensors", "candidate")
        try FileManager.default.createDirectory(at: tree.url(".downloads/\(try SessionStore.fingerprint(unselected))"),
                                                withIntermediateDirectories: true)
        try tree.write(".downloads/\(String(repeating: "d", count: 64))/abc.part", "orphan partial")
        try tree.write(".locks/\(String(repeating: "e", count: 64))", "")
        let heldName = String(repeating: "f", count: 64)
        try tree.write(".locks/\(heldName)", "")
        try tree.write(".DS_Store")
        try tree.write("\(selectedPath)/.DS_Store")
        try tree.write("notes.txt", "unknown")
        try FileManager.default.createSymbolicLink(at: tree.url("link"), withDestinationURL: outside)
        try tree.write(".trash/left-behind/file", "from an interrupted deletion")
        // Another process holds this lock file.
        let held = open(tree.url(".locks/\(heldName)").path, O_RDONLY)
        #expect(flock(held, LOCK_EX | LOCK_NB) == 0)
        return Tree(folder: folder, root: root, files: files, selected: selected, unselected: unselected,
                    resumable: resumable, legacy: legacy, bodies: bodies, outside: outside,
                    heldLock: held, heldLockName: heldName)
    }

    /// Staging written by other processes is protected for an hour; tests look two hours ahead.
    static let later = Date().addingTimeInterval(7200)

    @Test(arguments: [true, false])
    func onePassRemovesExactlyTheLeftovers(pinned: Bool) async throws {
        let tree = try await Self.tree()
        defer { close(tree.heldLock); tree.folder.remove() }
        let stagingBefore = tree.names(".downloads")
        let resumableStaging = try SessionStore.fingerprint(tree.resumable)
        #expect(stagingBefore.contains(resumableStaging))
        let selectedPath = try tree.selected.installationPath.value
        let repository = selectedPath.split(separator: "/").prefix(2).joined(separator: "/")
        let legacyPath = try tree.legacy.installationPath.value

        let report = try await tree.files.removeUnused(keeping: tree.keep(pinned: pinned), now: Self.later)
        var expected: Set<String> = [
            "\(repository)/\(Self.oldRevision)",
            "candidate-owner/candidate-model/\(Self.candidateRevision)", "candidate-owner/candidate-model", "candidate-owner",
            ".locks/\(String(repeating: "e", count: 64))",
            ".DS_Store", "\(selectedPath)/.DS_Store", "notes.txt", "link",
        ]
        for name in stagingBefore where name != resumableStaging { expected.insert(".downloads/\(name)") }
        if !pinned { expected.formUnion([legacyPath, "legacy-owner/legacy", "legacy-owner"]) }
        #expect(Set(report.removed) == expected)
        #expect(report.removed.count == expected.count)
        #expect(report.skippedBusy == [".locks/\(tree.heldLockName)"])
        #expect(report.keptLegacy == (pinned ? [legacyPath] : []))
        #expect(report.failed.isEmpty)
        #expect(report.freedBytes > 0)

        for manifest in [tree.selected, tree.unselected] { #expect(try await tree.files.isReady(manifest)) }
        #expect(try await tree.files.isReady(tree.legacy) == pinned)
        // Lock files of every catalog path stay, also of a removed legacy model.
        for manifest in [tree.selected, tree.unselected, tree.legacy] {
            #expect(tree.exists(".locks/\(ModelDownloadFiles.lockName(try manifest.installationPath.value))"))
        }
        // The kept installation validates again without Finder metadata.
        let lease = try await tree.files.acquireLocalModel(tree.selected)
        _ = try await lease.validatedURL()
        await lease.release()
        // The link went, never its target.
        #expect(try Data(contentsOf: tree.outside.appendingPathComponent("file.txt")) == Data("keep me".utf8))
        // Everything moved aside is in .trash until deleted, the leftover included.
        let emptied: Set<String> = ["candidate-owner/candidate-model", "candidate-owner", "legacy-owner/legacy", "legacy-owner"]
        // Empty folders and lock files are deleted at once; the rest waits in .trash.
        #expect(tree.names(".trash").count == expected.subtracting(emptied).filter { !$0.hasPrefix(".locks/") }.count + 1)
        try ModelDownloadFiles.emptyTrash(root: tree.root)
        #expect(!tree.exists(".trash"))

        // The partial download resumes where it stopped.
        let transport = FixtureModelTransport(content: tree.bodies)
        try await ModelDownloadCoordinator(files: tree.files, transport: transport).download(tree.resumable) { _, _ in }
        #expect(await transport.requests.contains { $0.url?.lastPathComponent == "model.safetensors"
            && $0.value(forHTTPHeaderField: "Range") != nil })
        #expect(try await tree.files.isReady(tree.resumable))

        // A second pass finds nothing new; the released lock goes on the next one.
        let again = try await tree.files.removeUnused(keeping: tree.keep(pinned: pinned), now: Self.later)
        #expect(again.removed.allSatisfy { $0.hasPrefix(".downloads/") })
        #expect(again.skippedBusy == [".locks/\(tree.heldLockName)"])
        close(tree.heldLock)
        let released = try await tree.files.removeUnused(keeping: tree.keep(pinned: pinned), now: Self.later)
        #expect(released.removed == [".locks/\(tree.heldLockName)"])
        let quiet = try await tree.files.removeUnused(keeping: tree.keep(pinned: pinned), now: Self.later)
        #expect(quiet.removed.isEmpty && quiet.skippedBusy.isEmpty)
    }

    @Test func recentStagingAndCleanUpLogPath() async throws {
        let tree = try await Self.tree()
        defer { close(tree.heldLock); tree.folder.remove() }
        // Just written: possibly another process's download.
        let report = await tree.files.cleanUp(keeping: try tree.keep(pinned: false))
        #expect(report.skippedBusy.contains(".downloads/\(String(repeating: "d", count: 64))"))
        #expect(tree.exists(".downloads/\(String(repeating: "d", count: 64))/abc.part"))
        #expect(report.removed.contains("notes.txt"))
        #expect(!tree.exists(".trash"))
        #expect(!tree.exists("notes.txt"))
    }

    /// D5: one item that cannot be handled never stops the pass or strands `.trash`.
    @Test func anUnreadableFolderDoesNotStopThePass() async throws {
        let tree = try await Self.tree()
        let locked = tree.url("locked-owner"), lockedRepo = tree.url("mlx-community/unreadable")
        try tree.write("locked-owner/repo/\(Self.candidateRevision)/model.safetensors", "candidate")
        try tree.write("mlx-community/unreadable/\(Self.candidateRevision)/model.safetensors", "candidate")
        chmod(locked.path, 0)
        chmod(lockedRepo.path, 0)
        defer {
            chmod(locked.path, 0o700); chmod(lockedRepo.path, 0o700)
            close(tree.heldLock); tree.folder.remove()
        }
        // .trash in the way as a file, and Finder metadata in a kept installation.
        try FileManager.default.removeItem(at: tree.url(".trash"))
        try tree.write(".trash", "not a folder")
        let report = await tree.files.cleanUp(keeping: try tree.keep(pinned: false))
        for path in ["notes.txt", "link", ".DS_Store", "candidate-owner"] { #expect(report.removed.contains(path)) }
        for path in ["locked-owner", "mlx-community/unreadable"] {
            #expect(report.removed.contains(path) || report.failed.contains(path))
        }
        #expect(!tree.exists(".trash") || tree.names(".trash").isEmpty)
        for manifest in [tree.selected, tree.unselected] { #expect(try await tree.files.isReady(manifest)) }
    }

    @Test func anInterruptedDeletionIsFinishedByTheNextPass() async throws {
        let tree = try await Self.tree()
        defer { close(tree.heldLock); tree.folder.remove() }
        let report = try await tree.files.removeUnused(keeping: tree.keep(pinned: false), now: Self.later)
        let moved = tree.names(".trash")
        #expect(moved.count > 2)
        struct Quit: Error {}
        var deleted = 0
        #expect(throws: Quit.self) {
            try ModelDownloadFiles.emptyTrash(root: tree.root) { _ in deleted += 1; throw Quit() }
        }
        #expect(deleted == 1 && tree.names(".trash").count == moved.count - 1)
        // Models stay ready whatever is left in .trash.
        #expect(try await tree.files.isReady(tree.selected))
        #expect(try await tree.files.isReady(tree.unselected))
        #expect(!report.removed.isEmpty)
        // Next launch: a new file service on the same root empties .trash.
        let next = ModelDownloadFiles(testRoot: tree.root)
        let again = await next.cleanUp(keeping: try tree.keep(pinned: false))
        #expect(again.removed.allSatisfy { $0.hasPrefix(".downloads/") || $0 == ".DS_Store" })
        #expect(!tree.exists(".trash"))
        #expect(try await next.isReady(tree.selected))
    }

    @Test func anInstallationAnotherProcessUsesIsSkippedUntilReleased() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let root = folder.url.appendingPathComponent("Models")
        let (manifest, bodies) = try ModelDownloadTests.fixture()
        let candidate = try Self.variant("candidate-owner/candidate-model", id: "fixture-candidate")
        // "Another process": a separate file service holding a lease on the candidate.
        let other = ModelDownloadFiles(testRoot: root)
        try await ModelDownloadCoordinator(files: other, transport: FixtureModelTransport(content: bodies)).download(candidate) { _, _ in }
        let lease = try await other.acquireLocalModel(candidate)
        let files = ModelDownloadFiles(testRoot: root)
        let keep = try ModelFolderKeepSet(active: [manifest], legacy: [], pinned: [])
        let path = try candidate.installationPath.value
        let busy = try await files.removeUnused(keeping: keep, now: Self.later)
        #expect(busy.skippedBusy.contains(path))
        #expect(!busy.removed.contains(path))
        _ = try await lease.validatedURL()
        await lease.release()
        let released = try await files.removeUnused(keeping: keep, now: Self.later)
        #expect(released.removed.contains(path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".locks/\(ModelDownloadFiles.lockName(path))").path))
        #expect(try await !other.isReady(candidate))
    }

    @Test func aRunningDownloadIsLeftAlone() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let root = folder.url.appendingPathComponent("Models")
        let (manifest, bodies) = try ModelDownloadTests.fixture()
        let files = ModelDownloadFiles(testRoot: root)
        let transport = FixtureModelTransport(content: bodies, behavior: .paused)
        let coordinator = ModelDownloadCoordinator(files: files, transport: transport)
        let task = Task { try await coordinator.download(manifest) { _, _ in } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await transport.pausedAfterWrite), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let staging = try SessionStore.fingerprint(manifest), path = try manifest.installationPath.value
        // Active in the catalog, and also when a fixture catalog no longer lists it.
        for keep in [try ModelFolderKeepSet(active: [manifest], legacy: [], pinned: []),
                     try ModelFolderKeepSet(active: [], legacy: [], pinned: [])] {
            let report = try await files.removeUnused(keeping: keep, now: Self.later)
            #expect(!report.removed.contains { $0.hasPrefix(path) || $0.contains(staging) })
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".downloads/\(staging)").path))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        }
        await transport.setBehavior(.normal)
        try await coordinator.cancelAndWait(manifest)
        _ = try? await task.value
        // Removal and a new download issued during a pass wait for it and work as before.
        let keep = try ModelFolderKeepSet(active: [manifest], legacy: [], pinned: [])
        async let pass = files.removeUnused(keeping: keep, now: Self.later)
        async let download: Void = coordinator.download(manifest) { _, _ in }
        _ = try await (pass, download)
        #expect(try await files.isReady(manifest))
        async let second = files.removeUnused(keeping: keep, now: Self.later)
        async let removal: Void = files.remove(manifest)
        _ = try await (second, removal)
        #expect(try await !files.isReady(manifest))
    }

    @Test func unfinishedJobsNameTheirModelFolders() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let store = try await SessionStore.open(OwnedLibrary().open(root: folder.url))
        func snapshot(_ name: String) throws -> ModelSnapshot {
            ModelSnapshot(role: .summary, repository: "owner/\(name)", revision: String(repeating: "c", count: 40),
                          directory: try RelativePath("owner/\(name)/\(String(repeating: "c", count: 40))"), preprocessingVersion: "p1")
        }
        let server = ModelSnapshot(role: .summary, repository: "https://example.invalid/v1", revision: "model",
                                   directory: try RelativePath("text-server"), preprocessingVersion: TextServer.protocolVersion)
        let stages: [JobStage] = [.failed, .interrupted, .waitingForModels, .queued, .completed, .cancelled]
        var expected = Set<RelativePath>()
        for stage in stages {
            let meeting = try await store.createMeeting(MeetingDraft(title: stage.rawValue))
            var job = try await store.enqueue(kind: .summary, meetingID: meeting.id, settings: ProcessingSettings(),
                                              models: [snapshot(stage.rawValue), server])
            job.stage = stage
            try await store.saveJob(job)
            if stage != .completed && stage != .cancelled { expected.insert(try snapshot(stage.rawValue).directory) }
        }
        #expect(try await store.modelDirectoriesOfUnfinishedJobs() == expected)
        try await store.close()
    }
}
