import CryptoKit
import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// A source root that also holds unrelated files (as the default root holds
/// this repository), a destination with its own unrelated file, and a
/// separate Application Support folder.
struct MoveFixture {
    let base: TemporaryFolder
    let source: URL, destination: URL, support: URL
    let library: OpenedLibrary
    let meetingID: UUID
    let original: [String: String]
    var locations: LibraryLocationStore { LibraryLocationStore(support: support) }

    init() async throws {
        base = try TemporaryFolder()
        source = base.url.appendingPathComponent("Repo", isDirectory: true)
        destination = base.url.appendingPathComponent("Dest", isDirectory: true)
        support = base.url.appendingPathComponent("Support", isDirectory: true)
        for folder in [source, destination, support, source.appendingPathComponent("src")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("# Repository\nне трогать".utf8).write(to: source.appendingPathComponent("prompt.md"))
        try Data("struct App {}".utf8).write(to: source.appendingPathComponent("src/App.swift"))
        try Data("already here".utf8).write(to: destination.appendingPathComponent("keep.txt"))
        library = try await OwnedLibrary(modelsRoot: support.appendingPathComponent("Models")).open(root: source)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Планёрка", description: "Moved"))
        meetingID = meeting.id
        try await store.commitNotes(NotesRevision(meetingID: meeting.id, text: "Заметки остаются"))
        try await store.close()
        let recording = library.directory.appendingPathComponent("Meetings/\(meeting.id)/Recordings/\(UUID())", isDirectory: true)
        for track in ["system", "microphone"] {
            try FileManager.default.createDirectory(at: recording.appendingPathComponent(track), withIntermediateDirectories: true)
            for index in 0..<3 {
                var bytes = Data(count: 900_000 + index * 1000)
                bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
                try bytes.write(to: recording.appendingPathComponent("\(track)/chunk-\(index).m4a"))
                try Data("{\"frames\":\(index)}".utf8).write(to: recording.appendingPathComponent("\(track)/chunk-\(index).json"))
            }
        }
        try Data("{}".utf8).write(to: recording.appendingPathComponent("manifest.json"))
        original = try Self.hashes(library.directory)
    }

    func migrator(space: Int64? = nil, failpoint: @escaping @Sendable (LibraryMigrationStep) throws -> Void = { _ in }) -> LibraryMigrator {
        LibraryMigrator(locations: locations, modelsRoot: support.appendingPathComponent("Models"),
                        availableSpace: { _ in space ?? (1 << 40) }, failpoint: failpoint)
    }

    var sourceOwned: URL { source.appendingPathComponent(OwnedLibrary.directoryName) }
    var destinationOwned: URL { destination.appendingPathComponent(OwnedLibrary.directoryName) }

    /// Unrelated files of both roots are byte-identical.
    func unrelatedUnchanged() throws -> Bool {
        try Data(contentsOf: source.appendingPathComponent("prompt.md")) == Data("# Repository\nне трогать".utf8)
            && Data(contentsOf: source.appendingPathComponent("src/App.swift")) == Data("struct App {}".utf8)
            && Data(contentsOf: destination.appendingPathComponent("keep.txt")) == Data("already here".utf8)
    }

    func listing(_ root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    /// Opens the library the location record names (or the source without
    /// one) and reads the meeting and notes back.
    func authoritativeNotes() async throws -> (URL, String?) {
        let opened: OpenedLibrary
        if let location = try locations.load() { opened = try await OwnedLibrary().resume(location) }
        else { opened = try await OwnedLibrary().open(root: source, expectedID: library.manifest.libraryID, allowCreate: false) }
        let store = try await SessionStore.open(opened)
        let notes = try await store.notes(meetingID: meetingID)?.text
        #expect(try await store.meetings().map(\.title) == ["Планёрка"])
        try await store.close()
        return (opened.root.resolvingSymlinksInPath(), notes)
    }

    static func hashes(_ directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let base = directory.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(atPath: base)
        while let path = enumerator?.nextObject() as? String {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: base + "/" + path, isDirectory: &isDirectory)
            if path.hasSuffix("-wal") || path.hasSuffix("-shm") { continue }
            result[path] = isDirectory.boolValue ? "dir"
                : SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: base + "/" + path))).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    /// True only the first time.
    func fire() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}

@Suite struct LibraryMigrationTests {
    @Test func movesEverythingAndLeavesUnrelatedFiles() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.base.remove() }
        let progress = ProgressLog()
        let outcome = try await fixture.migrator().migrate(source: fixture.library, destination: fixture.destination) { progress.append($0) }
        #expect(outcome.cleanupPending == 0)
        #expect(try MoveFixture.hashes(fixture.destinationOwned) == fixture.original)
        #expect(!FileManager.default.fileExists(atPath: fixture.sourceOwned.path))
        #expect(try fixture.unrelatedUnchanged())
        #expect(try fixture.listing(fixture.source) == ["prompt.md", "src"])
        #expect(try fixture.listing(fixture.destination) == [".talktrack-library", "keep.txt"])
        #expect(try await fixture.migrator().journals().isEmpty)
        let (root, notes) = try await fixture.authoritativeNotes()
        #expect(root == fixture.destination.resolvingSymlinksInPath())
        #expect(notes == "Заметки остаются")
        let stages = progress.values.map(\.stage)
        #expect(stages.contains(.copying) && stages.contains(.verifying) && stages.last == .cleaning)
        #expect(progress.values.filter { $0.stage == .copying }.last?.completedBytes == progress.values.first?.totalBytes)
    }

    @Test func refusesUnsafeDestinationsWithoutChangingEitherRoot() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.base.remove() }
        let other = fixture.base.url.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        _ = try await OwnedLibrary().open(root: other)
        let locked = fixture.base.url.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let cases: [(URL, LibraryMigrationError, Bool)] = [
            (fixture.source, .sameFolder, false),
            (fixture.source.appendingPathComponent("src"), .nested, false),
            (fixture.base.url, .nested, false),
            (fixture.sourceOwned.appendingPathComponent("Meetings"), .nested, false),
            (fixture.support.appendingPathComponent("Models"), .protectedFolder, false),
            (fixture.support, .protectedFolder, false),
            (fixture.support.appendingPathComponent("Migrations"), .protectedFolder, false),
            (other, .destinationHasLibrary, false),
            (locked, .notWritable(locked.path), false),
            (fixture.base.url.appendingPathComponent("Missing"), .destinationUnavailable(fixture.base.url.appendingPathComponent("Missing").path), false),
            (fixture.destination, .recording, true),
        ]
        for (destination, expected, recording) in cases {
            await #expect(throws: expected) {
                try await fixture.migrator().plan(source: fixture.library, destination: destination, recording: recording)
            }
            if !recording {
                await #expect(throws: expected) {
                    _ = try await fixture.migrator().migrate(source: fixture.library, destination: destination)
                }
            }
        }
        await #expect(throws: LibraryMigrationError.self) {
            try await fixture.migrator(space: 1000).plan(source: fixture.library, destination: fixture.destination, recording: false)
        }
        #expect(try MoveFixture.hashes(fixture.sourceOwned) == fixture.original)
        #expect(try fixture.listing(fixture.destination) == ["keep.txt"])
        #expect(try fixture.unrelatedUnchanged())
        #expect(try fixture.locations.load() == nil)
        #expect(try await fixture.migrator().journals().isEmpty)
    }

    @Test func refusesItemsTalkTrackDidNotCreateAndABusyDatabase() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.base.remove() }
        let link = fixture.sourceOwned.appendingPathComponent("Meetings/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source.appendingPathComponent("prompt.md"))
        await #expect(throws: LibraryMigrationError.unexpectedItem("Meetings/link")) {
            try await fixture.migrator().plan(source: fixture.library, destination: fixture.destination, recording: false)
        }
        try FileManager.default.removeItem(at: link)
        let wal = fixture.sourceOwned.appendingPathComponent("Library.sqlite3-wal")
        try Data([1, 2, 3]).write(to: wal)
        await #expect(throws: LibraryMigrationError.databaseBusy) {
            _ = try await fixture.migrator().migrate(source: fixture.library, destination: fixture.destination)
        }
        try FileManager.default.removeItem(at: wal)
        #expect(try fixture.listing(fixture.destination) == ["keep.txt"])
        #expect(try MoveFixture.hashes(fixture.sourceOwned) == fixture.original)
    }

    /// A crash at each boundary leaves exactly one complete authoritative library.
    @Test(arguments: ["journaled", "first file", "middle file", "copied", "verified", "renamed", "pointer", "committed", "cleanup"])
    func terminationAtEveryBoundaryRecovers(_ boundary: String) async throws {
        let fixture = try await MoveFixture()
        defer { fixture.base.remove() }
        let flag = Flag()
        let migrator = fixture.migrator { step in
            let hit: Bool = switch (boundary, step) {
            case ("journaled", .journaled), ("first file", .copied(0)), ("copied", .copiedAll), ("verified", .verified),
                 ("renamed", .renamed), ("pointer", .pointerSaved), ("committed", .committed), ("cleanup", .cleaned): true
            case ("middle file", .copied(let index)): index >= 8
            default: false
            }
            if hit && flag.fire() { throw SimulatedTermination() }
        }
        await #expect(throws: SimulatedTermination.self) {
            _ = try await migrator.migrate(source: fixture.library, destination: fixture.destination)
        }
        #expect(try await fixture.migrator().journals().count == 1)
        let recovered = try await fixture.migrator().recover()
        let switched = ["renamed", "pointer", "committed", "cleanup"].contains(boundary)
        #expect(recovered == [switched ? .completed(destination: LibraryMigrator.path(fixture.destination))
                                       : .discarded(source: LibraryMigrator.path(fixture.source))])
        #expect(try await fixture.migrator().journals().isEmpty)
        let (root, notes) = try await fixture.authoritativeNotes()
        #expect(notes == "Заметки остаются")
        if switched {
            #expect(root == fixture.destination.resolvingSymlinksInPath())
            #expect(try MoveFixture.hashes(fixture.destinationOwned) == fixture.original)
            #expect(try fixture.listing(fixture.source) == ["prompt.md", "src"])
        } else {
            #expect(root == fixture.source.resolvingSymlinksInPath())
            #expect(try MoveFixture.hashes(fixture.sourceOwned) == fixture.original)
            #expect(try fixture.listing(fixture.destination) == ["keep.txt"])
        }
        #expect(try fixture.unrelatedUnchanged())
        // A second relaunch has nothing left to do.
        #expect(try await fixture.migrator().recover().isEmpty)
    }

    @Test func errorsAndCancellationBeforeTheSwitchKeepTheSource() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.base.remove() }
        // Out of space while copying.
        await #expect(throws: LibraryError.io(operation: "copy", code: ENOSPC)) {
            _ = try await fixture.migrator { step in
                // A file inside a recording folder, after some audio was copied.
                if case .copied(let index) = step, index >= 8 { throw LibraryError.io(operation: "copy", code: ENOSPC) }
            }.migrate(source: fixture.library, destination: fixture.destination)
        }
        // Cancelled by the user while copying.
        let cancelled = Task {
            try await fixture.migrator { step in
                if case .copied(0) = step { withUnsafeCurrentTask { $0?.cancel() } }
            }.migrate(source: fixture.library, destination: fixture.destination)
        }
        await #expect(throws: LibraryMigrationError.cancelled) { _ = try await cancelled.value }
        // A file that grows while the move runs.
        let growing = try #require(fixture.original.keys.filter { $0.hasSuffix("chunk-2.m4a") }.sorted().last)
        await #expect(throws: LibraryMigrationError.self) {
            _ = try await fixture.migrator { step in
                if case .copied(0) = step {
                    let handle = try FileHandle(forWritingTo: fixture.sourceOwned.appendingPathComponent(growing))
                    try handle.seekToEnd(); try handle.write(contentsOf: Data([7])); try handle.close()
                }
            }.migrate(source: fixture.library, destination: fixture.destination)
        }
        #expect(try fixture.listing(fixture.destination) == ["keep.txt"])
        #expect(try fixture.locations.load() == nil)
        #expect(try await fixture.migrator().journals().isEmpty)
        #expect(try MoveFixture.hashes(fixture.sourceOwned).count == fixture.original.count)
        #expect(try fixture.unrelatedUnchanged())
    }

    @Test func cleanupKeepsForeignFilesAndIsRetried() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.base.remove() }
        let foreign = fixture.sourceOwned.appendingPathComponent("Meetings/user-file.txt")
        let outcome = try await fixture.migrator { step in
            if step == .committed { try Data("mine".utf8).write(to: foreign) }
        }.migrate(source: fixture.library, destination: fixture.destination)
        #expect(outcome.cleanupPending == 2) // Meetings and .talktrack-library are not empty.
        #expect(try Data(contentsOf: foreign) == Data("mine".utf8))
        #expect(try fixture.listing(fixture.sourceOwned) == ["Meetings"])
        #expect(try await fixture.migrator().recover() == [.cleanupPending(source: LibraryMigrator.path(fixture.source), items: 2)])
        #expect(try await fixture.authoritativeNotes().0 == fixture.destination.resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: foreign)
        #expect(try await fixture.migrator().recover() == [.completed(destination: LibraryMigrator.path(fixture.destination))])
        #expect(try fixture.listing(fixture.source) == ["prompt.md", "src"])
    }

    @Test func unreachableDestinationKeepsTheJournalUntilReconnected() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.base.remove() }
        await #expect(throws: SimulatedTermination.self) {
            _ = try await fixture.migrator { step in
                if case .copied(0) = step { throw SimulatedTermination() }
            }.migrate(source: fixture.library, destination: fixture.destination)
        }
        let away = fixture.base.url.appendingPathComponent("Unplugged")
        try FileManager.default.moveItem(at: fixture.destination, to: away)
        #expect(try await fixture.migrator().recover() == [.destinationUnavailable(LibraryMigrator.path(fixture.destination))])
        #expect(try await fixture.authoritativeNotes().0 == fixture.source.resolvingSymlinksInPath())
        await #expect(throws: LibraryMigrationError.unfinishedMove(LibraryMigrator.path(fixture.destination))) {
            try await fixture.migrator().plan(source: fixture.library, destination: away, recording: false)
        }
        try FileManager.default.moveItem(at: away, to: fixture.destination)
        #expect(try await fixture.migrator().recover() == [.discarded(source: LibraryMigrator.path(fixture.source))])
        #expect(try fixture.listing(fixture.destination) == ["keep.txt"])
    }

    @Test func movesBackAndForth() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.base.remove() }
        _ = try await fixture.migrator().migrate(source: fixture.library, destination: fixture.destination)
        let moved = try await OwnedLibrary().resume(try #require(try fixture.locations.load()))
        _ = try await fixture.migrator().migrate(source: moved, destination: fixture.source)
        #expect(try MoveFixture.hashes(fixture.sourceOwned) == fixture.original)
        #expect(try fixture.listing(fixture.destination) == ["keep.txt"])
        #expect(try await fixture.authoritativeNotes().0 == fixture.source.resolvingSymlinksInPath())
        #expect(try fixture.unrelatedUnchanged())
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LibraryMigrationProgress] = []
    func append(_ value: LibraryMigrationProgress) { lock.withLock { items.append(value) } }
    var values: [LibraryMigrationProgress] { lock.withLock { items } }
}
