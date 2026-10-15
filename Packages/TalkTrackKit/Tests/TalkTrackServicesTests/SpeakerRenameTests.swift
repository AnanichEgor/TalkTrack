import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

private struct RenameFixture {
    let library: OpenedLibrary
    let store: SessionStore
    let meetings: [Meeting]
    let recordings: [Recording]
    let revisions: [TranscriptRevision]
    let speakers: [DaySpeaker]
    let db: SQLiteConnection

    func target() async throws -> SpeakerRenameTarget {
        try await store.speakerRenameTarget(meetingID: meetings[0].id, recordingID: recordings[1].id,
            segmentID: revisions[1].segments[0].id)
    }
}

/// Synthetic committed heads, with deliberately shared same-day identity and
/// separate same-number identities elsewhere. No inference or audio is needed
/// to test display metadata; publication/model gates have their own suites.
private func renameFixture(_ root: URL) async throws -> RenameFixture {
    let library = try await OwnedLibrary().open(root: root)
    let store = try await SessionStore.open(library)
    let physical = "/" + DirectoryHandle.physicalComponents(library.directory).dropFirst().joined(separator: "/")
    let db = try SQLiteConnection(path: physical + "/Library.sqlite3")
    let meetings = try await [store.createMeeting(MeetingDraft(title: "Product planning")),
                              store.createMeeting(MeetingDraft(title: "Other meeting"))]
    let dates = ["2026-09-25T09:00:00Z", "2026-09-28T09:00:00Z", "2026-09-28T15:00:00Z", "2026-09-28T09:00:00Z"]
    var recordings: [Recording] = []
    for (index, value) in dates.enumerated() {
        var recording = try Recording(meetingID: meetings[index == 3 ? 1 : 0].id,
            startedAt: ISO8601DateFormatter().date(from: value)!, timeZoneIdentifier: "Europe/London")
        recording.state = .complete; recording.activeDuration = try MediaTime(seconds: 12)
        recording.endedAt = recording.startedAt.addingTimeInterval(12)
        try await store.saveRecording(recording); recordings.append(recording)
    }
    let speakers = [
        DaySpeaker(meetingID: meetings[0].id, dayID: recordings[0].days[0].id, number: 1),
        DaySpeaker(meetingID: meetings[0].id, dayID: recordings[1].days[0].id, number: 1,
            recordingDayIDs: [recordings[2].days[0].id]),
        DaySpeaker(meetingID: meetings[0].id, dayID: recordings[1].days[0].id, number: 2),
        DaySpeaker(meetingID: meetings[1].id, dayID: recordings[3].days[0].id, number: 1)
    ]
    for speaker in speakers {
        try db.execute("INSERT INTO records VALUES ('daySpeaker',?,?,?,?)", [
            .text(speaker.id.uuidString), .text(speaker.meetingID.uuidString), .text(speaker.dayID.uuidString), .blob(DomainCodec.encode(speaker))])
    }
    var revisions: [TranscriptRevision] = []
    for (index, recording) in recordings.enumerated() {
        let speaker = speakers[[0, 1, 1, 3][index]]
        func segment(_ track: AudioTrack, _ start: Double, _ text: String, _ identity: DaySpeaker) throws -> TranscriptSegment {
            TranscriptSegment(recordingID: recording.id, dayID: recording.days[0].id, track: track,
                interval: try MediaInterval(start: MediaTime(seconds: start), end: MediaTime(seconds: start + 1)),
                wallClockStart: recording.startedAt.addingTimeInterval(start), speaker: .system(daySpeakerID: identity.id),
                originalText: text, correctedText: text.replacingOccurrences(of: "tomorow", with: "tomorrow"))
        }
        var segments = try [segment(.system, 0, "Voice1 says Alex will not pay 42 rubles tomorow.", speaker),
                            segment(.system, 4, "Алекс не изменит сумму 42. Voice1.", speaker),
                            segment(.microphone, 7, "Voice1 is in my original text.", speaker)]
        if index == 1 { segments.append(try segment(.system, 10, "Another uncertain voice.", speakers[2])) }
        let revision = TranscriptRevision(recordingID: recording.id, sourceGeneration: recording.generation,
            kind: .final, segments: segments, modelRevisions: [])
        let job = try await store.enqueue(kind: .finalTranscription, meetingID: recording.meetingID,
            recordingID: recording.id, settings: ProcessingSettings(), models: [])
        try await store.publishTranscript(revision, jobID: job.id)
        revisions.append(revision)
    }
    return RenameFixture(library: library, store: store, meetings: meetings, recordings: recordings,
        revisions: revisions, speakers: speakers, db: db)
}

/// Fixtures call checkpoint/close before this copy. Never use a main-file-only
/// copy for an active library: committed transactions may still be in its WAL.
func copyCheckpointedRenameLibrary(_ library: OpenedLibrary, to root: URL) async throws -> OpenedLibrary {
    let destination = root.appendingPathComponent(OwnedLibrary.directoryName)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    for name in ["manifest.json", "Library.sqlite3", "Meetings"] {
        try FileManager.default.copyItem(at: library.directory.appendingPathComponent(name), to: destination.appendingPathComponent(name))
    }
    return try await OwnedLibrary().open(root: root, allowCreate: false)
}

private func labels(_ snapshot: MeetingTranscriptSnapshot, recordingID: UUID) -> [String] {
    snapshot.items.compactMap {
        guard case .speech(let block) = $0, block.recordingID == recordingID else { return nil }
        return block.speakerLabel
    }
}

@Suite struct SpeakerRenameTests {
    @Test func checkpointedRenamedLibraryReopensWithoutSidecars() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        func closedLibrary() async throws -> (OpenedLibrary, MeetingTranscriptSnapshot) {
            let f = try await renameFixture(folder.url)
            let snapshot = try await f.store.renameSpeaker(f.target(), name: "Alex")
            try await f.store.close()
            return (f.library, snapshot)
        }
        let (library, snapshot) = try await closedLibrary()
        let copyFolder = try TemporaryFolder(); defer { copyFolder.remove() }
        let copied = try await copyCheckpointedRenameLibrary(library, to: copyFolder.url)
        #expect(!FileManager.default.fileExists(atPath: copied.directory.appendingPathComponent("Library.sqlite3-wal").path))
        let store = try await SessionStore.open(copied)
        #expect(try await store.meetingTranscript(meetingID: snapshot.meeting.id) == snapshot)
        try await store.close()
    }

    @Test func nativeFixtureHasSeparateDaysMeetingsAndPermanentMicrophone() async throws {
        let folder = try TemporaryFolder()
        let export = ProcessInfo.processInfo.environment["TALKTRACK_SPEAKER_RENAME_FIXTURE"]
        defer { if export == nil { folder.remove() } }
        let fixture = try await renameFixture(folder.url)
        let snapshot = try await fixture.store.meetingTranscript(meetingID: fixture.meetings[0].id)
        #expect(snapshot.revisions == fixture.revisions.prefix(3).map { $0 })
        #expect(labels(snapshot, recordingID: fixture.recordings[1].id) == ["Voice1", "Voice1", "You", "Voice2"])
        #expect(try await fixture.target().day.localDate == "2026-09-28")
        try await fixture.store.close()
        if let export {
            struct Export: Encodable { let root: String; let meetingIDs: [UUID] }
            let url = URL(fileURLWithPath: export)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Export(root: folder.url.path, meetingIDs: fixture.meetings.map(\.id))).write(to: url, options: .atomic)
        }
    }

    @Test func renameAllMatchingDayRowsAcrossRecordingsWithoutChangingTextOrOtherScopes() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await renameFixture(folder.url)
        let other = try await f.store.meetingTranscript(meetingID: f.meetings[1].id)
        let before = try await f.store.meetingTranscript(meetingID: f.meetings[0].id)
        let target = try await f.target()
        #expect(target.label == "Voice1" && target.meetingTitle == "Product planning")
        #expect(target.name == nil && target.day.timeZoneIdentifier == "Europe/London")
        let after = try await f.store.renameSpeaker(target, name: "  Alex  ")
        #expect(labels(after, recordingID: f.recordings[0].id) == ["Voice1", "Voice1", "You"])
        #expect(labels(after, recordingID: f.recordings[1].id) == ["Alex", "Alex", "You", "Voice2"])
        #expect(labels(after, recordingID: f.recordings[2].id) == ["Alex", "Alex", "You"])
        #expect(after.revisions == before.revisions && after.recordings == before.recordings)
        #expect(after.assignments.count == 1 && after.assignments[0].origin == .manual)
        #expect(Set(after.assignments[0].evidence.map(\.recordingID)) == Set([f.recordings[1].id, f.recordings[2].id]))
        #expect(try await f.store.meetingTranscript(meetingID: f.meetings[1].id) == other)
        #expect(after.meeting.generation == before.meeting.generation + 1)
        try await f.store.close()
        let reopened = try await SessionStore.open(f.library)
        #expect(try await reopened.meetingTranscript(meetingID: f.meetings[0].id) == after)
        try await reopened.close()
    }

    @Test func clearingNamesRestoresVoiceLabelsKeepsHistoryAndOtherMeetings() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await renameFixture(folder.url)
        let named = try await f.store.renameSpeaker(f.target(), name: "Alex")
        let otherSpeaker = try #require(try await f.store.meetingTranscript(meetingID: f.meetings[1].id).speakers.first)
        try await f.store.confirmSpeakerName(meetingID: f.meetings[1].id, speakerID: otherSpeaker.id, name: "Kim")
        let other = try await f.store.meetingTranscript(meetingID: f.meetings[1].id)
        let cleared = try await f.store.clearSpeakerNames(meetingID: f.meetings[0].id)
        #expect(cleared.assignments.isEmpty)
        #expect(labels(cleared, recordingID: f.recordings[1].id) == ["Voice1", "Voice1", "You", "Voice2"])
        #expect(cleared.revisions == named.revisions && cleared.meeting.generation == named.meeting.generation + 1)
        #expect(try await f.store.speakerAssignment(named.assignments[0].id) == named.assignments[0])
        #expect(try await f.store.meetingTranscript(meetingID: f.meetings[1].id) == other)
        // Nothing to clear leaves the meeting untouched.
        #expect(try await f.store.clearSpeakerNames(meetingID: f.meetings[0].id) == cleared)
        let renamed = try await f.store.renameSpeaker(f.target(), name: "Sam")
        #expect(labels(renamed, recordingID: f.recordings[1].id) == ["Sam", "Sam", "You", "Voice2"])
        try await f.store.close()
    }

    @Test func microphoneForeignMeetingAndUnpublishedSelectionAreRefused() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await renameFixture(folder.url)
        await #expect(throws: SpeakerRenameError.microphone) {
            try await f.store.speakerRenameTarget(meetingID: f.meetings[0].id, recordingID: f.recordings[1].id,
                segmentID: f.revisions[1].segments[2].id)
        }
        await #expect(throws: SpeakerRenameError.unavailable) {
            try await f.store.speakerRenameTarget(meetingID: f.meetings[1].id, recordingID: f.recordings[1].id,
                segmentID: f.revisions[1].segments[0].id)
        }
        await #expect(throws: SpeakerRenameError.unavailable) {
            try await f.store.speakerRenameTarget(meetingID: f.meetings[0].id, recordingID: f.recordings[1].id, segmentID: UUID())
        }
        await #expect(throws: StoreError.invalidResult) {
            try await f.store.confirmSpeakerName(meetingID: f.meetings[1].id, speakerID: f.speakers[1].id, name: "Alex")
        }
        #expect(try await f.store.speakerAssignments(meetingID: f.meetings[0].id).isEmpty)
        try await f.store.close()
    }

    @Test func provisionalHeadCannotOfferAConfirmedRenameEvenWithAnOldIdentityUUID() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await renameFixture(folder.url), old = f.revisions[1]
        let live = TranscriptRevision(id: old.id, recordingID: old.recordingID, sourceGeneration: old.sourceGeneration,
            kind: .live, segments: old.segments, modelRevisions: [])
        try f.db.execute("UPDATE records SET payload=? WHERE kind='transcript' AND id=?", [.blob(DomainCodec.encode(live)), .text(old.id.uuidString)])
        await #expect(throws: SpeakerRenameError.unavailable) {
            try await f.store.speakerRenameTarget(meetingID: f.meetings[0].id, recordingID: old.recordingID, segmentID: old.segments[0].id)
        }
        #expect(try await f.store.speakerAssignments(meetingID: f.meetings[0].id).isEmpty)
        try await f.store.close()
    }

    @Test(arguments: ["", "   ", "Alex\n", "Alex\rSmith", "Alex\u{2028}Smith", "Alex\tSmith", "Alex\0Smith", String(repeating: "a", count: 201)])
    func invalidNamesCannotCommit(_ name: String) async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await renameFixture(folder.url)
        let before = try await f.store.meetingTranscript(meetingID: f.meetings[0].id), target = try await f.target()
        await #expect(throws: SpeakerRenameError.invalidName) { try await f.store.renameSpeaker(target, name: name) }
        #expect(try await f.store.meetingTranscript(meetingID: f.meetings[0].id) == before)
        try await f.store.close()
    }

    @Test func concurrentRenameRetainsHistoryAndRejectsOldDialog() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await renameFixture(folder.url), target = try await f.target()
        let first = try await f.store.confirmSpeakerName(meetingID: target.meetingID, speakerID: target.speakerID, name: "Alex")
        await #expect(throws: SpeakerRenameError.changed) { try await f.store.renameSpeaker(target, name: "Stale") }
        let second = try await f.store.renameSpeaker(f.target(), name: "Алексей")
        #expect(second.assignments[0].name == "Алексей")
        #expect(try await f.store.speakerAssignment(first.id) == first)
        #expect(second.revisions == f.revisions.prefix(3).map { $0 })
        try await f.store.close()
    }

    @Test func replacementOrDeletedMeetingCannotReceiveStaleDialog() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await renameFixture(folder.url), target = try await f.target()
        let old = f.revisions[1]
        let next = TranscriptRevision(recordingID: old.recordingID, sourceGeneration: old.sourceGeneration,
            kind: .final, segments: old.segments, modelRevisions: [])
        let job = try await f.store.enqueue(kind: .finalTranscription, meetingID: target.meetingID,
            recordingID: old.recordingID, settings: ProcessingSettings(), models: [])
        try await f.store.publishTranscript(next, jobID: job.id)
        await #expect(throws: SpeakerRenameError.changed) { try await f.store.renameSpeaker(target, name: "Alex") }
        let current = try await f.target()
        try await f.store.deleteMeeting(target.meetingID)
        await #expect(throws: StoreError.missingMeeting) { try await f.store.renameSpeaker(current, name: "Alex") }
        try await f.store.close()
    }

    @Test @MainActor func failedSaveRetainsDraftAndTranscriptThenRetriesAtomically() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await renameFixture(folder.url)
        let presentation = MeetingTranscriptPresentation(store: f.store, meetingID: f.meetings[0].id)
        await presentation.refresh()
        await presentation.beginRename(recordingID: f.recordings[1].id, segmentID: f.revisions[1].segments[0].id)
        #expect(!presentation.canSave)
        presentation.draftName = "Alex"
        let before = presentation.snapshot
        try f.db.execute("CREATE TRIGGER fail_rename BEFORE UPDATE ON meetings BEGIN SELECT RAISE(ABORT, 'injected rename failure'); END")
        await presentation.saveRename()
        #expect(presentation.snapshot == before && presentation.draftName == "Alex")
        #expect(presentation.renameTarget != nil && presentation.renameError?.contains("injected rename failure") == true)
        #expect(presentation.errorMessage == presentation.renameError)
        #expect(presentation.canSave && !presentation.isBusy)
        #expect(try await f.store.speakerAssignments(meetingID: f.meetings[0].id).isEmpty)
        #expect(try f.db.integer("SELECT count(*) FROM records WHERE kind='assignment'") == 0)
        try f.db.execute("DROP TRIGGER fail_rename")
        await presentation.saveRename()
        #expect(presentation.renameTarget == nil && presentation.renameError == nil && presentation.draftName.isEmpty)
        #expect(presentation.errorMessage == nil)
        #expect(presentation.snapshot?.assignments[0].name == "Alex")
        try await f.store.close()
    }

    @Test @MainActor func cancelNeverWritesAndMicSelectionNeverOpensDialog() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await renameFixture(folder.url)
        let p = MeetingTranscriptPresentation(store: f.store, meetingID: f.meetings[0].id)
        await p.refresh()
        let before = p.snapshot
        await p.beginRename(recordingID: f.recordings[1].id, segmentID: f.revisions[1].segments[2].id)
        #expect(p.renameTarget == nil && p.errorMessage?.contains("You") == true)
        await p.beginRename(recordingID: f.recordings[1].id, segmentID: f.revisions[1].segments[0].id)
        p.draftName = "Discard this draft"; p.cancelRename()
        await p.saveRename()
        #expect(p.snapshot == before && p.renameTarget == nil && p.draftName.isEmpty)
        #expect(try await f.store.speakerAssignments(meetingID: f.meetings[0].id).isEmpty)
        try await f.store.close()
    }
}
