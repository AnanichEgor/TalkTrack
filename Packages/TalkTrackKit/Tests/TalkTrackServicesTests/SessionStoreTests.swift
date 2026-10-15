import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

@Suite struct SessionStoreTests {
    @Test func reopenSearchAndDeterministicRecordingOrder() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let date = Date(timeIntervalSince1970: 1000)
        let old = try await store.createMeeting(MeetingDraft(title: "Старая ВСТРЕЧА", description: "Обсуждение бюджета"), at: date)
        let new = try await store.createMeeting(MeetingDraft(title: "New Meeting"), at: date.addingTimeInterval(1))
        let recording = try Recording(meetingID: old.id, startedAt: date.addingTimeInterval(2), timeZoneIdentifier: "Europe/London")
        try await store.saveRecording(recording)
        try await store.renameMeeting(new.id, title: "Renamed")
        #expect(try await store.meetings().map(\.id) == [old.id, new.id])
        #expect(try await store.meetings(search: "старая встреча").map(\.id) == [old.id])
        #expect(try await store.meetings(search: "БЮДЖЕТА").map(\.id) == [old.id])
        try await store.close()
        let reopened = try await SessionStore.open(library)
        #expect(try await reopened.meeting(new.id).title == "Renamed")
        #expect(try await reopened.recordings(meetingID: old.id) == [recording])
        #expect(try await reopened.meetings().map(\.id) == [old.id, new.id])
        let sameDate = try await reopened.createMeeting(MeetingDraft(title: "Tie"), at: date.addingTimeInterval(2))
        // Stable secondary order: creation date then UUID, independent of fetch order.
        #expect(try await reopened.meetings().map(\.id) == [sameDate.id, old.id, new.id])
        try await reopened.close()
    }

    @Test func deletionRejectsLateWritesAndOnlyRemovesOwnedMeeting() async throws {
        let folder = try TemporaryFolder()
        let outside = try TemporaryFolder()
        defer { folder.remove(); outside.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let removed = try await store.createMeeting(MeetingDraft(title: "Removed"))
        let kept = try await store.createMeeting(MeetingDraft(title: "Kept"))
        let recording = try Recording(meetingID: removed.id, timeZoneIdentifier: "UTC")
        try await store.saveRecording(recording)
        let owned = library.directory.appendingPathComponent("Meetings/\(removed.id)")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let sentinel = outside.url.appendingPathComponent("keep.txt")
        let bytes = Data("Do not touch".utf8)
        try bytes.write(to: sentinel)
        try bytes.write(to: folder.url.appendingPathComponent("repository.txt"))
        try FileManager.default.createSymbolicLink(at: owned.appendingPathComponent("external"), withDestinationURL: outside.url)
        try await store.deleteMeeting(removed.id)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(try Data(contentsOf: folder.url.appendingPathComponent("repository.txt")) == bytes)
        await #expect(throws: StoreError.missingMeeting) { try await store.saveRecording(recording) }
        await #expect(throws: StoreError.missingMeeting) { try await store.createMeeting(MeetingDraft(title: "Late"), id: removed.id) }
        #expect(try await store.meetings().map(\.id) == [kept.id])
        try await store.close()
        let reopened = try await SessionStore.open(library)
        await #expect(throws: StoreError.missingMeeting) { try await reopened.saveRecording(recording) }
        try await reopened.close()
    }

    @Test func transactionRollsBackRecordingWhenMeetingUpdateFails() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Original"))
        let physical = "/" + DirectoryHandle.physicalComponents(library.directory).dropFirst().joined(separator: "/")
        let fixture = try SQLiteConnection(path: physical + "/Library.sqlite3")
        try fixture.execute("CREATE TRIGGER fail_update BEFORE UPDATE ON meetings BEGIN SELECT RAISE(ABORT, 'injected disk failure'); END")
        let recording = try Recording(meetingID: meeting.id, timeZoneIdentifier: "UTC")
        await #expect(throws: StoreError.self) { try await store.saveRecording(recording) }
        #expect(try await store.recordings(meetingID: meeting.id).isEmpty)
        #expect(try await store.meeting(meeting.id) == meeting)
        try fixture.execute("DROP TRIGGER fail_update")
        try await store.saveRecording(recording)
        #expect(try await store.recordings(meetingID: meeting.id) == [recording])
        try await store.close()
    }
}
