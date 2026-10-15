import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

@Suite struct RecoveryTests {
    private func fixtureDB(_ library: OpenedLibrary) throws -> SQLiteConnection {
        let path = "/" + DirectoryHandle.physicalComponents(library.directory).dropFirst().joined(separator: "/")
        return try SQLiteConnection(path: path + "/Library.sqlite3")
    }

    @Test func notesNavigationQuitAndFailedSaveRecovery() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let first = try await store.createMeeting(MeetingDraft(title: "First"))
        let second = try await store.createMeeting(MeetingDraft(title: "Second"))
        let editor = NotesAutosave(store: store, delay: .seconds(3600))
        try await editor.edit(meetingID: first.id, text: "Навигация")
        try await editor.flushForNavigation(leaving: first.id)
        #expect(try await store.notes(meetingID: first.id)?.text == "Навигация")
        try await editor.edit(meetingID: second.id, text: "Перед выходом")
        try await editor.flushForQuit()
        #expect(try await store.notes(meetingID: second.id)?.text == "Перед выходом")
        let fixture = try fixtureDB(library)
        try fixture.execute("CREATE TRIGGER fail_notes BEFORE INSERT ON records WHEN NEW.kind = 'notes' BEGIN SELECT RAISE(ABORT, 'injected save failure'); END")
        try await editor.edit(meetingID: first.id, text: "Восстановить эту правку")
        await #expect(throws: StoreError.self) { try await editor.flushForQuit() }
        #expect(await editor.lastError(meetingID: first.id) != nil)
        #expect(try await store.notes(meetingID: first.id)?.text == "Навигация")
        #expect(try await editor.recover(meetingID: first.id) == "Восстановить эту правку")
        try await store.close()
        try fixture.execute("DROP TRIGGER fail_notes")
        let reopened = try await SessionStore.open(library)
        let restored = NotesAutosave(store: reopened)
        #expect(try await restored.recover(meetingID: first.id) == "Восстановить эту правку")
        try await restored.flushForQuit()
        #expect(try await reopened.notes(meetingID: first.id)?.text == "Восстановить эту правку")
        #expect(try await reopened.pendingNotes(meetingID: first.id) == nil)
        try await reopened.close()
    }

    @Test func failedPendingDatabaseWriteStillHasRecoveryFile() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Recovery"))
        let fixture = try fixtureDB(library)
        try fixture.execute("CREATE TRIGGER fail_pending BEFORE INSERT ON pending_edits BEGIN SELECT RAISE(ABORT, 'injected pending failure'); END")
        let editor = NotesAutosave(store: store)
        await #expect(throws: StoreError.self) { try await editor.edit(meetingID: meeting.id, text: "Recover outside SQLite") }
        try await store.close()
        let reopened = try await SessionStore.open(library)
        #expect(try await reopened.pendingNotes(meetingID: meeting.id)?.text == "Recover outside SQLite")
        try await reopened.close()
    }

    @Test func debounceSavesLatestEdit() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Debounce"))
        let editor = NotesAutosave(store: store, delay: .milliseconds(10))
        try await editor.edit(meetingID: meeting.id, text: "first")
        try await editor.edit(meetingID: meeting.id, text: "latest")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try await store.notes(meetingID: meeting.id)?.text != "latest", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await store.notes(meetingID: meeting.id)?.text == "latest")
        try await store.close()
    }

    @Test func interruptedJobRetainsSnapshotCheckpointAndPreviousOutput() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Jobs"))
        var settings = ProcessingSettings()
        let first = try await store.enqueue(kind: .summary, meetingID: meeting.id, settings: settings, models: [])
        let old = GeneratedOutput(kind: .summary, job: first.snapshot, text: "Usable result")
        try await store.publishOutput(old)
        let interrupted = try await store.enqueue(kind: .summary, meetingID: meeting.id, settings: settings, models: [])
        let checkpoint = try RelativePath("Meetings/\(meeting.id)/Recovery/summary-stage.json")
        try await store.updateJob(interrupted.id, stage: .generating, checkpoint: checkpoint)
        settings.summaryLanguage = .russian
        try await store.close()
        let reopened = try await SessionStore.open(library)
        let recovered = try await reopened.recoverInterruptedJobs()
        #expect(recovered.map(\.id) == [interrupted.id])
        #expect(recovered[0].snapshot == interrupted.snapshot)
        #expect(recovered[0].checkpoint == checkpoint)
        #expect(recovered[0].snapshot.settings.summaryLanguage == .english)
        #expect(try await reopened.output(.summary, meetingID: meeting.id) == old)
        let retry = try await reopened.retryJob(interrupted.id)
        try await reopened.publishOutput(GeneratedOutput(kind: .summary, job: retry.snapshot, text: "Replacement"))
        #expect(try await reopened.job(retry.id).stage == .completed)
        #expect(try await reopened.output(.summary, meetingID: meeting.id)?.text == "Replacement")
        try await reopened.close()
    }

    @Test func sourceRaceIsOutdatedAndProcessingCannotOverwriteNotes() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Source race"))
        let initial = NotesRevision(meetingID: meeting.id, text: "Initial notes")
        try await store.commitNotes(initial)
        let job = try await store.enqueue(kind: .summary, meetingID: meeting.id, settings: ProcessingSettings(), models: [])
        let newer = NotesRevision(meetingID: meeting.id, text: "New notes")
        try await store.commitNotes(newer)
        let output = GeneratedOutput(kind: .summary, job: job.snapshot, text: "From old notes")
        try await store.publishOutput(output)
        #expect(try await store.isOutdated(output, settings: ProcessingSettings()))
        #expect(try await store.notes(meetingID: meeting.id) == newer)
        #expect(output.job.source.notesRevisionID == initial.id)
        try await store.close()
    }

    @Test func atomicPublicationFailureCancellationAndDeletionKeepPriorResult() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Atomic"))
        let first = try await store.enqueue(kind: .summary, meetingID: meeting.id, settings: ProcessingSettings(), models: [])
        let old = GeneratedOutput(kind: .summary, job: first.snapshot, text: "Keep")
        try await store.publishOutput(old)
        let next = try await store.enqueue(kind: .summary, meetingID: meeting.id, settings: ProcessingSettings(), models: [])
        let fixture = try fixtureDB(library)
        try fixture.execute("CREATE TRIGGER fail_publish BEFORE UPDATE ON heads BEGIN SELECT RAISE(ABORT, 'injected publication failure'); END")
        let replacement = GeneratedOutput(kind: .summary, job: next.snapshot, text: "New")
        await #expect(throws: StoreError.self) { try await store.publishOutput(replacement) }
        #expect(try await store.output(.summary, meetingID: meeting.id) == old)
        #expect(try await store.job(next.id).stage == .queued)
        #expect(try fixture.integer("SELECT count(*) FROM records WHERE kind='summary'") == 1)
        try fixture.execute("DROP TRIGGER fail_publish")
        try await store.cancelJobs(meetingID: meeting.id)
        await #expect(throws: StoreError.cancelledJob) { try await store.publishOutput(replacement) }
        #expect(try await store.output(.summary, meetingID: meeting.id) == old)
        let late = try await store.enqueue(kind: .summary, meetingID: meeting.id, settings: ProcessingSettings(), models: [])
        try await store.deleteMeeting(meeting.id)
        await #expect(throws: StoreError.cancelledJob) {
            try await store.publishOutput(GeneratedOutput(kind: .summary, job: late.snapshot, text: "Late"))
        }
        #expect(try await store.meetings().isEmpty)
        try await store.close()
    }

    @Test func finalTranscriptRejectsChangedRecording() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Recording race"))
        var recording = try Recording(meetingID: meeting.id, timeZoneIdentifier: "UTC")
        try await store.saveRecording(recording)
        let initialJob = try await store.enqueue(kind: .finalTranscription, meetingID: meeting.id, recordingID: recording.id,
                                               settings: ProcessingSettings(), models: [])
        let old = TranscriptRevision(recordingID: recording.id, sourceGeneration: 0, kind: .final, segments: [], modelRevisions: [])
        try await store.publishTranscript(old, jobID: initialJob.id)
        let job = try await store.enqueue(kind: .finalTranscription, meetingID: meeting.id, recordingID: recording.id,
                                        settings: ProcessingSettings(), models: [])
        recording.generation += 1
        try await store.saveRecording(recording)
        let new = TranscriptRevision(recordingID: recording.id, sourceGeneration: 0, kind: .final, segments: [], modelRevisions: [])
        await #expect(throws: StoreError.staleSource) { try await store.publishTranscript(new, jobID: job.id) }
        #expect(try await store.transcript(meetingID: meeting.id, recordingID: recording.id) == old)
        try await store.close()
    }

    @Test func fingerprintIgnoresDictionaryInsertionOrder() throws {
        let meeting = UUID(), a = UUID(), b = UUID()
        let first = SourceSnapshot(meetingID: meeting, meetingGeneration: 0, cancellationGeneration: 0,
            recordingGenerations: [a: 1, b: 2], transcriptRevisionIDs: [], notesRevisionID: nil)
        let second = SourceSnapshot(meetingID: meeting, meetingGeneration: 0, cancellationGeneration: 0,
            recordingGenerations: [b: 2, a: 1], transcriptRevisionIDs: [], notesRevisionID: nil)
        #expect(try SessionStore.fingerprint(first) == SessionStore.fingerprint(second))
    }
}
