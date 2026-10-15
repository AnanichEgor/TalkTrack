import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// Task 7.6: a four-day EN/RU meeting with committed final heads, day voices,
/// one confirmed name and notes, built from `Fixtures/Summary`. With
/// `TALKTRACK_TEXT_ACCEPTANCE_FIXTURE=<file>` the temporary library is kept and
/// its path written there for `scripts/test-text-acceptance.sh`.
@Suite struct TextAcceptanceFixtureTests {
    static let notes = "Budget for the launch campaign is 18,000 EUR, not 25,000.\nAsk legal about the new privacy text."

    @Test func exportMultiDayMeeting() async throws {
        let folder = try TemporaryFolder()
        let export = ProcessInfo.processInfo.environment["TALKTRACK_TEXT_ACCEPTANCE_FIXTURE"]
        defer { if export == nil { folder.remove() } }
        let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Fixtures/Summary").standardizedFileURL
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let physical = "/" + DirectoryHandle.physicalComponents(library.directory).dropFirst().joined(separator: "/")
        let db = try SQLiteConnection(path: physical + "/Library.sqlite3")
        let meeting = try await store.createMeeting(MeetingDraft(title: "Mobile app launch check-ins",
                                                                 description: "Weekly check before the 3.0 release"))
        var named: DaySpeaker?
        let days = Int(ProcessInfo.processInfo.environment["TALKTRACK_TEXT_ACCEPTANCE_DAYS"] ?? "") ?? 4
        for (index, name) in ["english", "russian", "english", "russian"].prefix(days).enumerated() {
            let file = try JSONSerialization.jsonObject(with: Data(contentsOf: samples.appendingPathComponent("\(name).json"))) as! [String: Any]
            let first = ISO8601DateFormatter().date(from: file["startedAt"] as! String)!
            let start = first.addingTimeInterval(Double(index) * 2 * 86_400)
            let lines = file["lines"] as! [[Any]]
            var recording = try Recording(meetingID: meeting.id, startedAt: start, timeZoneIdentifier: file["timeZone"] as! String)
            let duration = (lines.last![0] as! NSNumber).doubleValue + 10
            recording.state = .complete; recording.activeDuration = try MediaTime(seconds: duration)
            recording.endedAt = start.addingTimeInterval(duration)
            try await store.saveRecording(recording)
            let day = recording.days[0].id
            let voices = ["voice1": DaySpeaker(meetingID: meeting.id, dayID: day, number: 1),
                          "voice2": DaySpeaker(meetingID: meeting.id, dayID: day, number: 2)]
            for speaker in voices.values {
                try db.execute("INSERT INTO records VALUES ('daySpeaker',?,?,?,?)", [
                    .text(speaker.id.uuidString), .text(meeting.id.uuidString), .text(day.uuidString), .blob(DomainCodec.encode(speaker))])
            }
            if index == 0 { named = voices["voice2"] }
            let segments = try lines.map { line in
                let offset = (line[0] as! NSNumber).doubleValue, who = line[1] as! String, text = line[2] as! String
                return TranscriptSegment(recordingID: recording.id, dayID: day, track: who == "you" ? .microphone : .system,
                    interval: try MediaInterval(start: MediaTime(seconds: offset), end: MediaTime(seconds: offset + 4)),
                    wallClockStart: start.addingTimeInterval(offset),
                    speaker: who == "you" ? .microphone : .system(daySpeakerID: voices[who]!.id), originalText: text)
            }
            let job = try await store.enqueue(kind: .finalTranscription, meetingID: meeting.id, recordingID: recording.id,
                settings: ProcessingSettings(), models: [])
            try await store.publishTranscript(TranscriptRevision(recordingID: recording.id, sourceGeneration: recording.generation,
                kind: .final, segments: segments, modelRevisions: []), jobID: job.id)
        }
        try await store.confirmSpeakerName(meetingID: meeting.id, speakerID: try #require(named).id, name: "Priya")
        try await store.commitNotes(NotesRevision(meetingID: meeting.id, text: Self.notes))

        let transcript = try await store.meetingTranscript(meetingID: meeting.id).items.map(\.text)
        #expect(transcript.filter { $0.contains("resumption") }.count == days - 1)
        #expect(transcript.contains { $0.contains(": Priya - ") })
        #expect(transcript.contains { $0.contains(": You - ") })
        try await store.requireSummarySource(meetingID: meeting.id)
        try await store.requireTranslationSource(meetingID: meeting.id)
        if let export { try folder.url.path.write(toFile: export, atomically: true, encoding: .utf8) }
        try await store.close()
    }
}
