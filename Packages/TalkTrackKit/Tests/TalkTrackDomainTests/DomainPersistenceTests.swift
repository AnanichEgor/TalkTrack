import Foundation
import Testing
import TalkTrackDomain

@Suite struct DomainPersistenceTests {
    private struct Fixture: Codable, Equatable {
        let meeting: Meeting
        let recordings: [Recording]
        let transcript: TranscriptRevision
        let assignment: SpeakerAssignment
        let notes: NotesRevision
        let job: ProcessingJob
        let output: GeneratedOutput
    }

    @Test func resumedMeetingRetainsProvenanceAndSnapshots() throws {
        let date = Date(timeIntervalSince1970: 1_790_726_400)
        let meeting = Meeting(draft: try MeetingDraft(title: "Встреча", language: .russian), createdAt: date)
        var first = try Recording(meetingID: meeting.id, startedAt: date, timeZoneIdentifier: "Europe/London")
        let second = try Recording(meetingID: meeting.id, startedAt: date.addingTimeInterval(3 * 86400),
                                   timeZoneIdentifier: "Asia/Tokyo")
        let interval = try MediaInterval(start: .zero, end: MediaTime(seconds: 10))
        let chunk = try TrackChunk(track: .system, file: RelativePath("Meetings/\(meeting.id)/Recordings/\(first.id)/system/one.m4a"),
            active: interval, sampleRate: 48000, decodedFrameCount: 482112,
            leadingTrimFrames: 2112, trailingTrimFrames: 0, hostTimeStart: 123456789)
        first.chunks = [chunk]
        first.captureIntervals = [CaptureInterval(active: interval, wallClockStart: date,
                                                   hostTimeStart: chunk.hostTimeStart, dayID: first.days[0].id)]
        first.trackIntervals = [TrackInterval(track: .system, active: interval,
            content: .chunk(id: chunk.id, firstDecodedFrame: 2112, frameCount: 480000)),
            TrackInterval(track: .microphone, active: interval, content: .gap(reason: "Device disconnected"))]
        first.activeDuration = interval.duration
        first.state = .interrupted
        let speakerID = UUID()
        let segment = TranscriptSegment(recordingID: first.id, dayID: first.days[0].id, track: .system,
            interval: interval, wallClockStart: date, speaker: .system(daySpeakerID: speakerID),
            originalText: "Не менять 42", correctedText: "Не менять 42.", alignmentModelRevision: "align-1")
        let model = ModelSnapshot(role: .finalASR, repository: "test/model", revision: "revision-1",
                                  directory: try RelativePath("model/revision-1"), preprocessingVersion: "1")
        let transcript = TranscriptRevision(recordingID: first.id, sourceGeneration: first.generation,
            kind: .final, segments: [segment], modelRevisions: [model], createdAt: date)
        let notes = NotesRevision(meetingID: meeting.id, text: "Не обещали срок", createdAt: date)
        let assignment = SpeakerAssignment(meetingID: meeting.id, dayID: first.days[0].id, daySpeakerID: speakerID,
            name: "Алекс", origin: .manual, evidence: [SpeechEvidence(recordingID: first.id, interval: interval)], createdAt: date)
        let source = SourceSnapshot(meetingID: meeting.id, meetingGeneration: 0, cancellationGeneration: 0,
            recordingGenerations: [first.id: 0, second.id: 0], transcriptRevisionIDs: [transcript.id], notesRevisionID: notes.id)
        var settings = ProcessingSettings()
        let snapshot = ProcessingJobSnapshot(kind: .summary, source: source, settings: settings, models: [model], createdAt: date)
        settings.summaryLanguage = .russian
        let job = ProcessingJob(snapshot: snapshot, stage: .interrupted, checkpoint: try RelativePath("Meetings/recovery/stage.json"))
        let output = GeneratedOutput(kind: .summary, job: snapshot, text: "No date committed.", createdAt: date)
        let original = Fixture(meeting: meeting, recordings: [first, second], transcript: transcript,
                               assignment: assignment, notes: notes, job: job, output: output)
        let reopened = try DomainCodec.decode(Fixture.self, from: DomainCodec.encode(original))
        #expect(reopened == original)
        #expect(reopened.job.snapshot.settings.summaryLanguage == .english)
        #expect(reopened.recordings[0].days[0].utcOffsetSeconds == 3600)
        #expect(reopened.recordings[1].days[0].utcOffsetSeconds == 32400)
        #expect(reopened.recordings[0].chunks[0].file == chunk.file)
        #expect(reopened.output.job.source.notesRevisionID == reopened.notes.id)
    }

    @Test(arguments: ["/tmp/audio", "../audio", "a/../b", "a//b", "a/./b", "a\\b", "~/a", "file:/a", "", "a\0b"])
    func persistedPathsCannotEscape(_ path: String) throws {
        let encoded = try JSONEncoder().encode(path)
        #expect(throws: DomainError.self) { try JSONDecoder().decode(RelativePath.self, from: encoded) }
    }

    @Test func rejectsInvalidTimeAndFutureSchema() throws {
        #expect(throws: DomainError.invalidTime) { try MediaTime(seconds: .infinity) }
        #expect(throws: DomainError.invalidTime) { try MediaTime(seconds: Double.greatestFiniteMagnitude) }
        #expect(throws: DomainError.invalidTime) { try JSONDecoder().decode(MediaTime.self, from: Data("-1".utf8)) }
        #expect(throws: DomainError.reversedInterval) {
            try JSONDecoder().decode(MediaInterval.self, from: Data(#"{"start":2,"end":1}"#.utf8))
        }
        #expect(throws: DomainError.unsupportedSchema(2)) {
            try DomainCodec.decode(Meeting.self, from: Data(#"{"schemaVersion":2,"value":{}}"#.utf8))
        }
    }

    @Test func decodingCannotRelabelMicrophone() throws {
        let segment = TranscriptSegment(recordingID: UUID(), dayID: UUID(), track: .system,
            interval: try MediaInterval(start: .zero, end: MediaTime(seconds: 1)), wallClockStart: Date(),
            speaker: .system(daySpeakerID: UUID()), originalText: "Hello")
        let json = String(decoding: try DomainCodec.encode(segment), as: UTF8.self)
            .replacingOccurrences(of: #""track":"system""#, with: #""track":"microphone""#)
        let restored = try DomainCodec.decode(TranscriptSegment.self, from: Data(json.utf8))
        #expect(restored.track == .microphone)
        #expect(restored.speaker == .microphone)
    }

    @Test func trimsCannotOverflowOrExceedDecodedAudio() throws {
        #expect(throws: DomainError.invalidAudioFrames) {
            try TrackChunk(track: .system, file: RelativePath("test.m4a"),
                active: MediaInterval(start: .zero, end: .zero), sampleRate: 48000,
                decodedFrameCount: 100, leadingTrimFrames: UInt64.max, trailingTrimFrames: 1, hostTimeStart: 0)
        }
    }
}
