import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

@Suite struct SchemaTests {
    @Test func checkpointedWALWithoutSidecarsReopensAndFutureVersionIsUntouched() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Clean close"))
        try await store.close()
        // Copy only after checkpoint/close, to deterministically reproduce the
        // missing-sidecar state observed on actual process exit. Test runners
        // can retain zero-length WAL files longer than the signed application.
        let closedFolder = try TemporaryFolder(); defer { closedFolder.remove() }
        let closed = try await copyCheckpointedRenameLibrary(library, to: closedFolder.url)
        let closedFile = databaseURL(closed)
        #expect(!FileManager.default.fileExists(atPath: closedFile.path + "-wal"))
        let reopened = try await SessionStore.open(closed)
        #expect(try await reopened.meeting(meeting.id) == meeting)
        try await reopened.close()
        // A future version in a checkpointed WAL-mode main file must be
        // refused before SQLite creates even empty sidecars.
        func futureVersion() throws {
            let fixture = try SQLiteConnection(path: closedFile.path)
            try fixture.execute("PRAGMA user_version = 999")
            try fixture.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try futureVersion()
        let futureFolder = try TemporaryFolder(); defer { futureFolder.remove() }
        let future = try await copyCheckpointedRenameLibrary(closed, to: futureFolder.url)
        let futureFile = databaseURL(future)
        #expect(!FileManager.default.fileExists(atPath: futureFile.path + "-wal"))
        let before = try Data(contentsOf: futureFile)
        let entries = try FileManager.default.contentsOfDirectory(atPath: future.directory.path).sorted()
        await #expect(throws: StoreError.unsupportedSchema(999)) { try await SessionStore.open(future) }
        #expect(try Data(contentsOf: futureFile) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: future.directory.path).sorted() == entries)
    }

    @Test func activeWALVersionOverridesOlderMainHeader() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        try await store.close()
        let file = databaseURL(library)
        let fixture = try SQLiteConnection(path: file.path)
        try fixture.execute("PRAGMA wal_autocheckpoint = 0")
        try fixture.execute("PRAGMA user_version = 999")
        let before = try Data(contentsOf: file)
        let directory = try DirectoryHandle.openAbsolute(library.directory)
        #expect(try SQLiteConnection.closedHeader(in: directory).version == 2)
        await #expect(throws: StoreError.unsupportedSchema(999)) { try await SessionStore.open(library) }
        #expect(try Data(contentsOf: file) == before)
        #expect(try fixture.integer("PRAGMA user_version") == 999)
    }

    private func databaseURL(_ library: OpenedLibrary) -> URL {
        let path = "/" + DirectoryHandle.physicalComponents(library.directory).dropFirst().joined(separator: "/")
        return URL(fileURLWithPath: path + "/Library.sqlite3")
    }

    @Test func futureDatabaseIsByteIdenticalAfterRefusal() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        try await store.close()
        let file = databaseURL(library)
        do {
            let fixture = try SQLiteConnection(path: file.path)
            try fixture.execute("PRAGMA journal_mode = DELETE")
            try fixture.execute("PRAGMA user_version = 999")
        }
        let before = try Data(contentsOf: file)
        let entries = try FileManager.default.contentsOfDirectory(atPath: library.directory.path).sorted()
        await #expect(throws: StoreError.unsupportedSchema(999)) { try await SessionStore.open(library) }
        #expect(try Data(contentsOf: file) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.directory.path).sorted() == entries)
    }

    @Test func versionOneUpgradeCreatesReadableBackupAndPreservesData() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Before upgrade"))
        try await store.close()
        let file = databaseURL(library)
        do {
            let fixture = try SQLiteConnection(path: file.path)
            try fixture.execute("DROP TABLE pending_edits")
            try fixture.execute("DROP INDEX records_meeting")
            try fixture.execute("PRAGMA user_version = 1")
        }
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: library.directory.path))
        let upgraded = try await SessionStore.open(library)
        #expect(try await upgraded.meeting(meeting.id) == meeting)
        try await upgraded.checkpoint()
        try await upgraded.close()
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: library.directory.path))
        let backupName = try #require(after.subtracting(before).first { $0.hasSuffix(".backup") })
        let backupPath = "/" + DirectoryHandle.physicalComponents(library.directory).dropFirst().joined(separator: "/") + "/" + backupName
        let backup = try SQLiteConnection(path: backupPath, readOnly: true)
        #expect(try backup.integer("PRAGMA user_version") == 1)
        #expect(try backup.integer("SELECT count(*) FROM meetings") == 1)
        let reopened = try await SessionStore.open(library)
        #expect(try await reopened.meeting(meeting.id) == meeting)
        try await reopened.close()
    }

    @Test func failedUpgradeRollsBackSchemaAndLeavesRecoveryBackup() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Survives migration failure"))
        try await store.close()
        let file = databaseURL(library)
        do {
            let fixture = try SQLiteConnection(path: file.path)
            try fixture.execute("DROP TABLE pending_edits")
            // Keeping the existing index injects failure after CREATE TABLE.
            try fixture.execute("PRAGMA user_version = 1")
        }
        await #expect(throws: StoreError.self) { try await SessionStore.open(library) }
        do {
            let fixture = try SQLiteConnection(path: file.path)
            #expect(try fixture.integer("PRAGMA user_version") == 1)
            #expect(try fixture.integer("SELECT count(*) FROM sqlite_master WHERE name='pending_edits'") == 0)
            #expect(try fixture.integer("SELECT count(*) FROM meetings") == 1)
            try fixture.execute("DROP INDEX records_meeting")
        }
        let reopened = try await SessionStore.open(library)
        #expect(try await reopened.meeting(meeting.id) == meeting)
        try await reopened.close()
    }

    @Test func mismatchedDatabaseIdentityIsRejected() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        try await store.close()
        do {
            let fixture = try SQLiteConnection(path: databaseURL(library).path)
            try fixture.execute("UPDATE metadata SET value=? WHERE key='libraryID'", [.text(UUID().uuidString)])
        }
        await #expect(throws: StoreError.wrongLibrary) { try await SessionStore.open(library) }
    }
}
