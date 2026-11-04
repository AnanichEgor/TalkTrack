import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// A meeting with one stopped recording and no final transcript.
struct DraftFixture {
    let folder: TemporaryFolder
    let library: OpenedLibrary
    let store: SessionStore
    let meeting: Meeting
    let recording: Recording

    static func make(seconds: Double = 30) async throws -> Self {
        let folder = try TemporaryFolder()
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Call with strangers"))
        var recording = try Recording(meetingID: meeting.id, startedAt: ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!,
                                      timeZoneIdentifier: "UTC")
        recording.state = .complete; recording.activeDuration = try MediaTime(seconds: seconds)
        recording.endedAt = recording.startedAt.addingTimeInterval(seconds)
        try await store.saveRecording(recording)
        return DraftFixture(folder: folder, library: library, store: store, meeting: meeting, recording: recording)
    }

    /// A draft row from `start` to `end` seconds; no voices for the microphone.
    func row(_ start: Double, _ end: Double, voices: [ProvisionalSpeaker] = [], track: AudioTrack = .system,
             text: String = "Draft speech", id: UUID = UUID()) throws -> LiveUtterance {
        let interval = try MediaInterval(start: MediaTime(seconds: start), end: MediaTime(seconds: end))
        return LiveUtterance(id: id, recordingID: recording.id, day: recording.days[0], track: track, context: interval,
                             interval: interval, wallClockStart: recording.startedAt.addingTimeInterval(start),
                             speakers: track == .microphone ? [] : voices, text: text, detectedLanguage: "English")
    }

    func draft(_ rows: [LiveUtterance], complete: Bool = true) -> LiveDraft {
        LiveDraft(meetingID: meeting.id, recordingID: recording.id, utterances: rows, complete: complete)
    }

    func remove() { folder.remove() }
}

func count(_ db: SQLiteConnection, _ sql: String) throws -> Int64 {
    guard case .integer(let value)? = try db.rows(sql).first?.first else { return -1 }
    return value
}

@Suite struct LiveDraftStoreTests {
    @Test func aDraftRoundTripsSurvivesReopeningAndIsNotReplacedByAnOlderSave() async throws {
        let f = try await DraftFixture.make()
        defer { f.remove() }
        let voice = ProvisionalSpeaker(id: UUID(), number: 3)
        let rows = [try f.row(0, 3, voices: [voice], text: "Hello everyone"),
                    try f.row(3, 6, voices: [voice, ProvisionalSpeaker(id: UUID(), number: 4)], text: "Both talk"),
                    try f.row(4, 5, track: .microphone, text: "Hi")]
        let generation = try await f.store.meeting(f.meeting.id).generation
        try await f.store.saveLiveDraft(f.draft(Array(rows.prefix(1)), complete: false))
        try await f.store.saveLiveDraft(f.draft(rows, complete: false))
        // Saving a draft never changes the meeting generation.
        #expect(try await f.store.meeting(f.meeting.id).generation == generation)
        let saved = try #require(try await f.store.liveDrafts(meetingID: f.meeting.id).first)
        #expect(saved.utterances == rows && !saved.complete)
        #expect(saved.utterances[1].speakerLabel == "Voice3 / Voice4" && saved.utterances[2].speakerLabel == "You")

        try await f.store.saveLiveDraft(f.draft(rows, complete: true))
        // A late incomplete save cannot replace the complete draft.
        try await f.store.saveLiveDraft(f.draft(Array(rows.prefix(1)), complete: false))
        try await f.store.close()

        let reopened = try await SessionStore.open(f.library)
        let snapshot = try await reopened.meetingTranscript(meetingID: f.meeting.id)
        #expect(snapshot.drafts.count == 1 && snapshot.drafts[0].utterances == rows && snapshot.drafts[0].complete)
        // Only one record per recording, however often it was saved.
        let db = try publicationDB(f.library)
        #expect(try count(db, "SELECT COUNT(*) FROM records WHERE kind='liveDraft'") == 1)
        try await reopened.close()
    }

    @Test func theBridgeSavesOnlyWhenRowsChanged() async throws {
        let f = try await DraftFixture.make()
        defer { f.remove() }
        let date = f.recording.startedAt, boundary = UUID()
        let recorded = BridgeRecorded(), store = f.store
        let bridge = LiveCaptureBridge(host: bridgeHost(BridgeInference(), recorded), options: LiveTranscriptionOptions(language: .english),
                                       saveInterval: .milliseconds(20), save: { draft in
            recorded.draft(draft); try? await store.saveLiveDraft(draft)
        })
        await bridge.begin()
        let session = try #require(await bridge.attach(meetingID: f.meeting.id, recordingID: f.recording.id))
        try await Task.sleep(for: .milliseconds(80))
        // No rows yet: nothing is written.
        #expect(recorded.drafts.isEmpty)
        for offset in stride(from: 0, to: 144_000, by: 4800) {
            bridge.mailbox.offer(LiveCaptureFragment(track: .system, samples: Array(repeating: 0.05, count: 4800),
                activeStartFrame: UInt64(offset), day: f.recording.days[0],
                wallClockStart: date.addingTimeInterval(Double(offset) / 48_000), boundaryID: boundary))
            try await Task.sleep(for: .milliseconds(1))
        }
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while await session.publishedCount == 0 || recorded.drafts.isEmpty, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        let afterFirst = recorded.drafts.count
        try await Task.sleep(for: .milliseconds(150))
        // Several intervals passed with unchanged rows: no further writes.
        #expect(afterFirst == 1 && recorded.drafts.count == 1)
        await bridge.finish()
        #expect(recorded.drafts.count == 2 && recorded.drafts.last?.complete == true)
        #expect(try await f.store.liveDrafts(meetingID: f.meeting.id).first?.complete == true)
        try await f.store.close()
    }

    @Test func deletingTheRecordingOrTheMeetingDeletesItsDraftAndDraftNames() async throws {
        let f = try await DraftFixture.make()
        defer { f.remove() }
        let voice = ProvisionalSpeaker(id: UUID(), number: 1)
        let row = try f.row(0, 3, voices: [voice])
        try await f.store.saveLiveDraft(f.draft([row]))
        try await f.store.nameDraftVoice(meetingID: f.meeting.id, utterance: row, name: "Petr")
        try await f.store.nameDraftReply(meetingID: f.meeting.id, utterance: row, name: "Ivan")
        #expect(try await f.store.liveNames(meetingID: f.meeting.id).count == 2)
        try await f.store.deleteRecording(meetingID: f.meeting.id, recordingID: f.recording.id)
        #expect(try await f.store.liveDrafts(meetingID: f.meeting.id).isEmpty)
        #expect(try await f.store.liveNames(meetingID: f.meeting.id).isEmpty)
        let db = try publicationDB(f.library)
        #expect(try count(db, "SELECT COUNT(*) FROM records WHERE kind IN ('liveDraft','liveName')") == 0)
        #expect(try count(db, "SELECT COUNT(*) FROM heads WHERE kind IN ('liveDraft','liveName')") == 0)

        let other = try await DraftFixture.make()
        defer { other.remove() }
        try await other.store.saveLiveDraft(other.draft([try other.row(0, 3, voices: [voice])]))
        try await other.store.nameDraftVoice(meetingID: other.meeting.id, utterance: try other.row(0, 3, voices: [voice]), name: "Anna")
        try await other.store.deleteMeeting(other.meeting.id)
        let otherDB = try publicationDB(other.library)
        #expect(try count(otherDB, "SELECT COUNT(*) FROM records WHERE kind IN ('liveDraft','liveName')") == 0)
        try await f.store.close(); try await other.store.close()
    }
}
