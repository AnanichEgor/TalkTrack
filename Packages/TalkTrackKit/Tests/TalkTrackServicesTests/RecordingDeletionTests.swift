import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// A meeting with three transcribed, summarized and translated recordings.
/// Recordings 2 and 3 share a capture day, and with it its voice; every voice is named.
private struct DeletionFixture {
    let library: OpenedLibrary
    let store: SessionStore
    let meeting: Meeting
    let recordings: [Recording]
    let speakers: [DaySpeaker]
    let translationModel = ModelSnapshot(role: .translation, repository: "test", revision: "1",
                                         directory: try! RelativePath("test/1"), preprocessingVersion: "1")
    var settings: ProcessingSettings { ProcessingSettings(contextLimit: .tokens4K, templateVersion: IndexedTranslation.version) }

    static func make(_ root: URL, dates: [String] = ["2026-09-25T09:00:00Z", "2026-09-28T09:00:00Z", "2026-09-28T15:00:00Z"],
                     translate: Bool = true) async throws -> Self {
        let library = try await OwnedLibrary().open(root: root)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Planning", description: "Three calls"))
        let physical = "/" + DirectoryHandle.physicalComponents(library.directory).dropFirst().joined(separator: "/")
        let db = try SQLiteConnection(path: physical + "/Library.sqlite3")
        var recordings: [Recording] = []
        for value in dates {
            var recording = try Recording(meetingID: meeting.id, startedAt: ISO8601DateFormatter().date(from: value)!,
                                          timeZoneIdentifier: "UTC")
            if let previous = recordings.last, previous.days[0].localDate == recording.days[0].localDate { recording.days = previous.days }
            recording.state = .complete; recording.activeDuration = try MediaTime(seconds: 12)
            recording.endedAt = recording.startedAt.addingTimeInterval(12)
            try await store.saveRecording(recording); recordings.append(recording)
            // Its audio folder, which deletion removes.
            let folder = library.directory.appendingPathComponent("Meetings/\(meeting.id)/Recordings/\(recording.id)/system")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("audio".utf8).write(to: folder.appendingPathComponent("chunk.m4a"))
        }
        // One voice per capture day.
        var speakers: [DaySpeaker] = []
        for recording in recordings where !speakers.contains(where: { $0.dayID == recording.days[0].id }) {
            speakers.append(DaySpeaker(meetingID: meeting.id, dayID: recording.days[0].id, number: 1))
        }
        for speaker in speakers {
            try db.execute("INSERT INTO records VALUES ('daySpeaker',?,?,?,?)", [
                .text(speaker.id.uuidString), .text(meeting.id.uuidString), .text(speaker.dayID.uuidString), .blob(DomainCodec.encode(speaker))])
        }
        var revisions: [TranscriptRevision] = []
        for (index, recording) in recordings.enumerated() {
            let speaker = speakers.first { $0.recordingDayIDs.contains(recording.days[0].id) }!
            let segments = [
                TranscriptSegment(recordingID: recording.id, dayID: recording.days[0].id, track: .system,
                    interval: try MediaInterval(start: .zero, end: MediaTime(seconds: 3)), wallClockStart: recording.startedAt,
                    speaker: .system(daySpeakerID: speaker.id), originalText: "Call \(index + 1) opens."),
                TranscriptSegment(recordingID: recording.id, dayID: recording.days[0].id, track: .microphone,
                    interval: try MediaInterval(start: MediaTime(seconds: 5), end: MediaTime(seconds: 7)),
                    wallClockStart: recording.startedAt.addingTimeInterval(5), speaker: .microphone, originalText: "Reply \(index + 1).")
            ]
            let revision = TranscriptRevision(recordingID: recording.id, sourceGeneration: recording.generation,
                                              kind: .final, segments: segments, modelRevisions: [])
            let job = try await store.enqueue(kind: .finalTranscription, meetingID: meeting.id, recordingID: recording.id,
                                              settings: ProcessingSettings(), models: [])
            try await store.publishTranscript(revision, jobID: job.id)
            revisions.append(revision)
        }
        for (index, speaker) in speakers.enumerated() {
            let recording = recordings.first { speaker.recordingDayIDs.contains($0.days[0].id) }!
            let revision = revisions.first { $0.recordingID == recording.id }!
            let target = try await store.speakerRenameTarget(meetingID: meeting.id, recordingID: recording.id,
                                                             segmentID: revision.segments[0].id)
            _ = try await store.renameSpeaker(target, name: ["Anna", "Boris", "Clara"][index])
        }
        let summaryModel = try ModelCatalog.bundled().model(for: .summary).snapshot(for: .summary)
        for recording in recordings {
            let job = try await store.enqueueSummary(meetingID: meeting.id, recordingID: recording.id,
                                                     settings: ProcessingSettings(contextLimit: .tokens4K), model: summaryModel)
            try await SummaryJobPipeline(store: store, inference: SummaryJobInference()).run(jobID: job.id)
        }
        let fixture = Self(library: library, store: store, meeting: meeting, recordings: recordings, speakers: speakers)
        if translate {
            let job = try await store.enqueueTranslation(meetingID: meeting.id, settings: fixture.settings, model: fixture.translationModel)
            try await TranslationJobPipeline(store: store, inference: TranslationTestInference()).run(jobID: job.id)
        }
        return fixture
    }

    func folderExists(_ recording: Recording) -> Bool {
        FileManager.default.fileExists(atPath: library.directory
            .appendingPathComponent("Meetings/\(meeting.id)/Recordings/\(recording.id)").path)
    }

    func translationTexts(_ store: SessionStore? = nil) async throws -> [String] {
        let store = store ?? self.store
        guard let output = try await store.output(.translation, meetingID: meeting.id) else { return [] }
        return try await store.translatedItems(output).map(\.text)
    }
}

@Suite(.serialized) struct RecordingDeletionTests {
    @Test func deletingTheMiddleRecordingKeepsTheOthersAndTrimsTheTranslation() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url, dates: ["2026-09-25T09:00:00Z", "2026-09-26T09:00:00Z", "2026-09-28T09:00:00Z"])
        let (first, middle, last) = (f.recordings[0], f.recordings[1], f.recordings[2])
        let summaries = try await f.store.summaries(meetingID: f.meeting.id)
        let translated = try await f.translationTexts()
        #expect(translated.contains { $0.contains("Call 2 opens.") })
        let notes = try await f.store.notes(meetingID: f.meeting.id)

        try await f.store.deleteRecording(meetingID: f.meeting.id, recordingID: middle.id)

        #expect(try await f.store.recordings(meetingID: f.meeting.id).map(\.id) == [first.id, last.id])
        #expect(try await f.store.transcript(meetingID: f.meeting.id, recordingID: middle.id) == nil)
        #expect(try await f.store.jobs(meetingID: f.meeting.id).allSatisfy { $0.snapshot.recordingID != middle.id })
        // Its day's voice and name are gone; the others keep theirs.
        let speakers = try await f.store.daySpeakers(meetingID: f.meeting.id)
        #expect(Set(speakers.map(\.id)) == [f.speakers[0].id, f.speakers[2].id])
        #expect(Set(try await f.store.speakerAssignments(meetingID: f.meeting.id).compactMap(\.name)) == ["Anna", "Clara"])
        // The other summaries are unchanged and current; its summary is gone.
        let remaining = try await f.store.summaries(meetingID: f.meeting.id)
        #expect(remaining == summaries.filter { $0.key != middle.id })
        for output in remaining.values { #expect(try await f.store.isOutdated(output, settings: output.job.settings) == false) }
        // The translation keeps the other recordings' text without a model, still current.
        let trimmed = try await f.translationTexts()
        #expect(trimmed == translated.filter { !$0.contains("Call 2") && !$0.contains("Reply 2") && !$0.contains("September 26") })
        let output = try #require(try await f.store.output(.translation, meetingID: f.meeting.id))
        #expect(try await f.store.isOutdated(output, settings: output.job.settings) == false)
        // The transcript, notes and files.
        let transcript = try await f.store.meetingTranscript(meetingID: f.meeting.id)
        #expect(!transcript.items.map(\.text).joined().contains("Call 2"))
        #expect(try await f.store.notes(meetingID: f.meeting.id) == notes)
        #expect(!f.folderExists(middle) && f.folderExists(first) && f.folderExists(last))

        // After relaunch it stays deleted and the translation stays trimmed.
        try await f.store.close()
        let reopened = try await SessionStore.open(f.library)
        #expect(try await reopened.recordings(meetingID: f.meeting.id).map(\.id) == [first.id, last.id])
        #expect(try await f.translationTexts(reopened) == trimmed)
        #expect(try await reopened.isDeletedRecording(middle.id))
        try await reopened.close()
    }

    @Test func aRecordingSharingItsDayKeepsTheDaysNames() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url, translate: false)
        // Recordings 2 and 3 share September 28 and its voice "Boris".
        try await f.store.deleteRecording(meetingID: f.meeting.id, recordingID: f.recordings[2].id)
        #expect(Set(try await f.store.daySpeakers(meetingID: f.meeting.id).map(\.id)) == Set(f.speakers.map(\.id)))
        let snapshot = try await f.store.meetingTranscript(meetingID: f.meeting.id)
        let labels = snapshot.items.compactMap { item -> String? in
            if case .speech(let block) = item, block.recordingID == f.recordings[1].id, block.segments[0].track == .system { block.speakerLabel } else { nil }
        }
        #expect(labels == ["Boris"])
    }

    @Test func anAlreadyOutdatedTranslationStaysOutdated() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url)
        // A voice of a remaining recording is renamed after the translation.
        let revision = try #require(try await f.store.transcript(meetingID: f.meeting.id, recordingID: f.recordings[0].id))
        let target = try await f.store.speakerRenameTarget(meetingID: f.meeting.id, recordingID: f.recordings[0].id,
                                                           segmentID: revision.segments[0].id)
        _ = try await f.store.renameSpeaker(target, name: "Alexandra")
        let before = try #require(try await f.store.output(.translation, meetingID: f.meeting.id))
        #expect(try await f.store.isOutdated(before, settings: before.job.settings))
        try await f.store.deleteRecording(meetingID: f.meeting.id, recordingID: f.recordings[2].id)
        let after = try #require(try await f.store.output(.translation, meetingID: f.meeting.id))
        #expect(after.id != before.id)
        #expect(try await f.store.isOutdated(after, settings: after.job.settings))
    }

    @Test func deletingTheLastRecordingKeepsTheMeetingAndNotes() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url, dates: ["2026-09-25T09:00:00Z"])
        try await f.store.commitNotes(NotesRevision(meetingID: f.meeting.id, text: "Keep me"))
        try await f.store.deleteRecording(meetingID: f.meeting.id, recordingID: f.recordings[0].id)
        let meeting = try await f.store.meeting(f.meeting.id)
        #expect(meeting.title == "Planning" && meeting.description == "Three calls")
        #expect(try await f.store.recordings(meetingID: f.meeting.id).isEmpty)
        #expect(try await f.store.output(.translation, meetingID: f.meeting.id) == nil)
        #expect(try await f.store.summaries(meetingID: f.meeting.id).isEmpty)
        #expect(try await f.store.daySpeakers(meetingID: f.meeting.id).isEmpty)
        #expect(try await f.store.meetingTranscript(meetingID: f.meeting.id).items.isEmpty)
        #expect(try await f.store.notes(meetingID: f.meeting.id)?.text == "Keep me")
    }

    @Test func aCapturingRecordingIsRefused() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Live"))
        var recording = try Recording(meetingID: meeting.id, timeZoneIdentifier: "UTC")
        recording.state = .recording
        try await store.saveRecording(recording)
        await #expect(throws: RecordingDeletionError.capturing) {
            try await store.deleteRecording(meetingID: meeting.id, recordingID: recording.id)
        }
        #expect(try await store.recordings(meetingID: meeting.id).map(\.id) == [recording.id])
        await #expect(throws: RecordingDeletionError.missing) {
            try await store.deleteRecording(meetingID: meeting.id, recordingID: UUID())
        }
    }

    @Test func aCrashBeforeFileRemovalIsFinishedAtLaunchAndNothingComesBack() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url, translate: false)
        let deleted = f.recordings[0]
        // The audio folder cannot be removed: the commit succeeds, file cleanup fails.
        let recordingsFolder = f.library.directory.appendingPathComponent("Meetings/\(f.meeting.id)/Recordings")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: recordingsFolder.path)
        try await f.store.deleteRecording(meetingID: f.meeting.id, recordingID: deleted.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordingsFolder.path)
        #expect(f.folderExists(deleted))
        #expect(try await f.store.recordings(meetingID: f.meeting.id).count == 2)
        try await f.store.close()

        let reopened = try await SessionStore.open(f.library)
        #expect(!f.folderExists(deleted) && f.folderExists(f.recordings[1]))
        #expect(try await reopened.isDeletedRecording(deleted.id))
        // A late save of the recording (a recorder or recovery) cannot bring it back.
        await #expect(throws: RecordingDeletionError.missing) { try await reopened.saveRecording(deleted) }
        #expect(try await reopened.recordings(meetingID: f.meeting.id).map(\.id) == [f.recordings[1].id, f.recordings[2].id])
        try await reopened.close()
    }

    @Test func lateResultsOfTheDeletedRecordingCannotRestoreIt() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url, translate: false)
        let deleted = f.recordings[1]
        let current = try #require(try await f.store.transcript(meetingID: f.meeting.id, recordingID: deleted.id))
        // A reprocess, a summary and a translation are queued when it is deleted.
        let summaryModel = try ModelCatalog.bundled().model(for: .summary).snapshot(for: .summary)
        let summary = try await f.store.enqueueSummary(meetingID: f.meeting.id, recordingID: f.recordings[0].id,
                                                       settings: ProcessingSettings(contextLimit: .tokens4K), model: summaryModel)
        let translation = try await f.store.enqueueTranslation(meetingID: f.meeting.id, settings: f.settings, model: f.translationModel)
        let final = try await f.store.enqueue(kind: .finalTranscription, meetingID: f.meeting.id, recordingID: deleted.id,
                                              settings: ProcessingSettings(), models: [])

        try await f.store.deleteRecording(meetingID: f.meeting.id, recordingID: deleted.id)

        // The deleted recording's own job no longer exists; a late publication fails.
        await #expect(throws: StoreError.cancelledJob) { try await f.store.job(final.id) }
        await #expect(throws: (any Error).self) {
            try await f.store.publishTranscript(TranscriptRevision(recordingID: deleted.id, sourceGeneration: deleted.generation,
                kind: .final, segments: current.segments, modelRevisions: []), jobID: final.id)
        }
        // A translation covering it was cancelled and cannot publish.
        #expect(try await f.store.job(translation.id).stage == .cancelled)
        await #expect(throws: (any Error).self) {
            try await TranslationJobPipeline(store: f.store, inference: TranslationTestInference()).run(jobID: translation.id)
        }
        #expect(try await f.store.output(.translation, meetingID: f.meeting.id) == nil)
        // Another recording's summary is not affected.
        try await SummaryJobPipeline(store: f.store, inference: SummaryJobInference()).run(jobID: summary.id)
        #expect(try await f.store.job(summary.id).stage == .completed)
        #expect(try await f.store.transcript(meetingID: f.meeting.id, recordingID: deleted.id) == nil)
        #expect(try await f.store.recordings(meetingID: f.meeting.id).map(\.id) == [f.recordings[0].id, f.recordings[2].id])
    }
}
