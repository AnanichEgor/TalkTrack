import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

@Suite(.serialized) struct RecordingMoveTests {
    private func labels(_ store: SessionStore, _ meetingID: UUID) async throws -> [String] {
        try await store.meetingTranscript(meetingID: meetingID).items.compactMap { item in
            if case .speech(let block) = item { "\(block.speakerLabel): \(block.segments.map(\.originalText).joined(separator: " "))" } else { nil }
        }
    }

    private func folderExists(_ f: DeletionFixture, meeting: UUID, recording: UUID) -> Bool {
        FileManager.default.fileExists(atPath: f.library.directory
            .appendingPathComponent("Meetings/\(meeting)/Recordings/\(recording)/system/chunk.m4a").path)
    }

    @Test func movingANamedRecordingToANewMeetingKeepsItsTranscriptNamesAndSummary() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url)
        let moved = f.recordings[0]
        let summary = try await f.store.summary(meetingID: f.meeting.id, recordingID: moved.id)
        let target = try await f.store.createMeeting(MeetingDraft(title: "Retro", description: ""))

        let result = try await f.store.moveRecording(moved.id, from: f.meeting.id, to: target.id)

        #expect(result.recording.meetingID == target.id && !result.needsTranscription)
        #expect(try await f.store.recordings(meetingID: f.meeting.id).map(\.id) == [f.recordings[1].id, f.recordings[2].id])
        #expect(try await f.store.recordings(meetingID: target.id).map(\.id) == [moved.id])
        #expect(try await labels(f.store, target.id) == ["Anna: Call 1 opens.", "You: Reply 1."])
        #expect(try await labels(f.store, f.meeting.id).filter { $0.contains("Call") } == ["Boris: Call 2 opens.", "Boris: Call 3 opens."])
        // The summary comes along; another title makes it Outdated.
        let carried = try #require(try await f.store.summary(meetingID: target.id, recordingID: moved.id))
        #expect(carried.text == summary?.text)
        #expect(try await f.store.isOutdated(carried, settings: ProcessingSettings(contextLimit: .tokens4K)))
        #expect(try await f.store.summaries(meetingID: f.meeting.id)[moved.id] == nil)
        // The source translation no longer has it; the target's has none.
        #expect(try await !f.translationTexts().contains { $0.contains("Call 1 opens.") })
        #expect(try await f.store.output(.translation, meetingID: target.id) == nil)
        // The audio folder moved with it.
        #expect(!folderExists(f, meeting: f.meeting.id, recording: moved.id))
        #expect(folderExists(f, meeting: target.id, recording: moved.id))
        #expect(try await f.store.recordingMeetingID(moved.id) == target.id)

        // Everything survives a relaunch.
        try await f.store.close()
        let reopened = try await SessionStore.open(f.library)
        #expect(try await labels(reopened, target.id) == ["Anna: Call 1 opens.", "You: Reply 1."])
    }

    @Test func aSummaryMovedToAMeetingWithTheSameHeaderStaysCurrent() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url, translate: false)
        let moved = f.recordings[0]
        let settings = ProcessingSettings(contextLimit: .tokens4K)
        let before = try #require(try await f.store.summary(meetingID: f.meeting.id, recordingID: moved.id))
        #expect(try await !f.store.isOutdated(before, settings: settings))
        let target = try await f.store.createMeeting(MeetingDraft(title: "Planning", description: "Three calls"))
        try await f.store.moveRecording(moved.id, from: f.meeting.id, to: target.id)
        let after = try #require(try await f.store.summary(meetingID: target.id, recordingID: moved.id))
        #expect(try await !f.store.isOutdated(after, settings: settings))
        // Its frozen source names the moved voice, which is the target's.
        let source: SummarySource = try #require(try await f.store.record(.summarySource, id: after.job.id))
        #expect(Set(source.speakers.map(\.id)) == Set(try await f.store.daySpeakers(meetingID: target.id).map(\.id)))
    }

    @Test func aVoiceSharedWithAnotherRecordingIsNamedInBothMeetings() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url)
        let target = try await f.store.createMeeting(MeetingDraft(title: "Afternoon", description: ""))

        try await f.store.moveRecording(f.recordings[2].id, from: f.meeting.id, to: target.id)

        #expect(try await labels(f.store, target.id) == ["Boris: Call 3 opens.", "You: Reply 3."])
        #expect(try await labels(f.store, f.meeting.id).filter { $0.contains("Call") } == ["Anna: Call 1 opens.", "Boris: Call 2 opens."])
        let source = Set(try await f.store.daySpeakers(meetingID: f.meeting.id).map(\.id))
        let moved = Set(try await f.store.daySpeakers(meetingID: target.id).map(\.id))
        #expect(source.isDisjoint(with: moved) && moved.count == 1)
        // Clearing names in one meeting leaves the other's.
        _ = try await f.store.clearSpeakerNames(meetingID: target.id)
        #expect(try await labels(f.store, target.id).first == "Voice1: Call 3 opens.")
        #expect(try await labels(f.store, f.meeting.id).contains("Boris: Call 2 opens."))
    }

    @Test func movedVoicesAreNumberedAfterTheTargetsVoicesOfTheSameDate() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url, translate: false)
        let target = try await f.store.createMeeting(MeetingDraft(title: "Afternoon", description: ""))
        try await f.store.moveRecording(f.recordings[1].id, from: f.meeting.id, to: target.id)
        _ = try await f.store.clearSpeakerNames(meetingID: target.id)

        try await f.store.moveRecording(f.recordings[2].id, from: f.meeting.id, to: target.id)

        #expect(try await f.store.daySpeakers(meetingID: target.id).map(\.number).sorted() == [1, 2])
        #expect(try await labels(f.store, target.id).filter { $0.contains("Call") } == ["Voice1: Call 2 opens.", "Boris: Call 3 opens."])
        #expect(try await labels(f.store, f.meeting.id).filter { $0.contains("Call") } == ["Anna: Call 1 opens."])
    }

    @Test func aFolderLeftBehindIsMovedAtTheNextLaunch() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url, translate: false)
        let moved = f.recordings[0]
        let target = try await f.store.createMeeting(MeetingDraft(title: "Retro", description: ""))
        try await f.store.moveRecording(moved.id, from: f.meeting.id, to: target.id)
        // As if the app stopped right after the commit: the folder is still in the source.
        let manager = FileManager.default, meetings = f.library.directory.appendingPathComponent("Meetings")
        try manager.createDirectory(at: meetings.appendingPathComponent("\(f.meeting.id)/Recordings"), withIntermediateDirectories: true)
        try manager.moveItem(at: meetings.appendingPathComponent("\(target.id)/Recordings/\(moved.id)"),
                             to: meetings.appendingPathComponent("\(f.meeting.id)/Recordings/\(moved.id)"))
        try await f.store.close()

        let reopened = try await SessionStore.open(f.library)

        #expect(folderExists(f, meeting: target.id, recording: moved.id))
        #expect(!folderExists(f, meeting: f.meeting.id, recording: moved.id))
        #expect(try await reopened.recordings(meetingID: target.id).map(\.id) == [moved.id])
    }

    @Test func aCapturingRecordingOrTheSameMeetingIsRefused() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url, translate: false)
        var open = try Recording(meetingID: f.meeting.id, startedAt: Date(), timeZoneIdentifier: "UTC")
        open.state = .recording
        try await f.store.saveRecording(open)
        let target = try await f.store.createMeeting(MeetingDraft(title: "Retro", description: ""))
        await #expect(throws: RecordingMoveError.capturing) {
            try await f.store.moveRecording(open.id, from: f.meeting.id, to: target.id)
        }
        await #expect(throws: RecordingMoveError.sameMeeting) {
            try await f.store.moveRecording(f.recordings[0].id, from: f.meeting.id, to: f.meeting.id)
        }
        await #expect(throws: RecordingMoveError.missing) {
            try await f.store.moveRecording(f.recordings[0].id, from: target.id, to: f.meeting.id)
        }
        #expect(try await f.store.recordings(meetingID: f.meeting.id).count == 4)
    }

    @Test func unfinishedWorkIsCancelledAndTheRecordingNeedsTranscription() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url, translate: false)
        var recording = try Recording(meetingID: f.meeting.id, startedAt: Date(), timeZoneIdentifier: "UTC")
        recording.state = .complete; recording.activeDuration = try MediaTime(seconds: 10)
        recording.chunks = [try TrackChunk(track: .system, file: RelativePath("system/a.m4a"),
            active: MediaInterval(start: .zero, end: MediaTime(seconds: 10)), sampleRate: 48_000,
            decodedFrameCount: 480_000, leadingTrimFrames: 0, trailingTrimFrames: 0, hostTimeStart: 0)]
        try await f.store.saveRecording(recording)
        let job = try await f.store.enqueue(kind: .finalTranscription, meetingID: f.meeting.id, recordingID: recording.id,
                                            settings: ProcessingSettings(), models: [])
        let target = try await f.store.createMeeting(MeetingDraft(title: "Retro", description: ""))

        let result = try await f.store.moveRecording(recording.id, from: f.meeting.id, to: target.id)

        #expect(result.needsTranscription)
        #expect(try await f.store.job(job.id).stage == .cancelled)
        #expect(try await f.store.jobs(meetingID: target.id).map(\.id) == [job.id])
        #expect(try await f.store.jobs(meetingID: f.meeting.id).allSatisfy { $0.snapshot.recordingID != recording.id })
        #expect(try await f.store.meetingTranscript(meetingID: target.id).items.count == 1)
    }
}
