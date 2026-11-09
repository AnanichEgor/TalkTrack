import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

private func span(_ start: Double, _ end: Double) throws -> MediaInterval {
    try MediaInterval(start: MediaTime(seconds: start), end: MediaTime(seconds: end))
}

/// Removes the fixture's earlier final transcript, so the recording has only its draft.
func removeFinalHead(_ fixture: FinalFixture) throws {
    try publicationDB(fixture.library).execute("DELETE FROM heads WHERE kind='transcript' AND meeting_id=? AND scope=?",
        [.text(fixture.recording.meetingID.uuidString), .text(fixture.recording.id.uuidString)])
}

/// A draft row of a final fixture's recording.
func fixtureRow(_ fixture: FinalFixture, _ start: Double, _ end: Double, voices: [ProvisionalSpeaker],
                track: AudioTrack = .system, id: UUID = UUID()) throws -> LiveUtterance {
    let interval = try span(start, end)
    return LiveUtterance(id: id, recordingID: fixture.recording.id, day: fixture.recording.days[0], track: track,
                         context: interval, interval: interval,
                         wallClockStart: fixture.recording.startedAt.addingTimeInterval(start),
                         speakers: voices, text: "Draft", detectedLanguage: "English")
}

/// Publishes a final transcript over a saved draft in which `placed` names the
/// voice of nearly all the speech and `unplaced` only a sliver of it, too little
/// to name a final block. The fixture must have only its draft.
func publishDraft(_ fixture: FinalFixture, placed: String, unplaced: String) async throws {
    let store = fixture.store, meetingID = fixture.recording.meetingID
    let long = try fixtureRow(fixture, 0, 2.8, voices: [ProvisionalSpeaker(id: UUID(), number: 1)])
    let sliver = try fixtureRow(fixture, 2.8, 3, voices: [ProvisionalSpeaker(id: UUID(), number: 2)])
    try await store.saveLiveDraft(LiveDraft(meetingID: meetingID, recordingID: fixture.recording.id, utterances: [long, sliver], complete: true))
    try await store.nameDraftVoice(meetingID: meetingID, utterance: long, name: placed)
    try await store.nameDraftReply(meetingID: meetingID, utterance: sliver, name: unplaced)
    _ = try await stageFinal(fixture)
    _ = try await store.publishFinalTranscript(jobID: fixture.job.id)
}

@Suite struct LiveNamingTests {
    @MainActor @Test func theStatusRowListsNamesThatWereNotPlaced() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        try removeFinalHead(fixture)
        try await publishDraft(fixture, placed: "Petr", unplaced: "Olga")

        let presentation = MeetingTranscriptPresentation(store: fixture.store, meetingID: fixture.recording.meetingID)
        await presentation.refresh()
        let entry = try #require(presentation.draftNamingMessages.first)
        #expect(entry.message == "Named 1 reply from the draft. Not placed: Olga.")
        // Remember Voices… offers only people who named a reply.
        #expect(entry.people == ["Petr"])
        try await fixture.store.close()
    }

    @Test func replyAndVoiceNamesAreSavedRemovedUndoneAndSurviveRelaunch() async throws {
        let f = try await DraftFixture.make()
        defer { f.remove() }
        let petr = ProvisionalSpeaker(id: UUID(), number: 3), anna = ProvisionalSpeaker(id: UUID(), number: 4)
        let first = try f.row(0, 3, voices: [petr]), mixed = try f.row(3, 6, voices: [petr, anna])
        let mine = try f.row(6, 8, track: .microphone)
        try await f.store.saveLiveDraft(f.draft([first, mixed, mine], complete: false))

        // Microphone rows are never named; a mixed row only as a reply.
        await #expect(throws: SpeakerRenameError.microphone) {
            try await f.store.nameDraftReply(meetingID: f.meeting.id, utterance: mine, name: "Me")
        }
        await #expect(throws: LiveDraftError.unavailable) {
            try await f.store.nameDraftVoice(meetingID: f.meeting.id, utterance: mixed, name: "Petr")
        }
        await #expect(throws: SpeakerRenameError.invalidName) {
            try await f.store.nameDraftVoice(meetingID: f.meeting.id, utterance: first, name: "  ")
        }

        let before = try await f.store.namingHeads(meetingID: f.meeting.id)
        let named = try await f.store.nameDraftVoice(meetingID: f.meeting.id, utterance: first, name: "Petr")
        #expect(named.liveNames.map(\.name) == ["Petr"] && named.liveNames[0].liveSpeakerID == petr.id)
        // Undo right after the Save restores the heads before it.
        let undone = try await f.store.undoNaming(before, generation: named.meeting.generation)
        #expect(undone.liveNames.isEmpty)

        try await f.store.nameDraftVoice(meetingID: f.meeting.id, utterance: first, name: "Petr")
        try await f.store.nameDraftReply(meetingID: f.meeting.id, utterance: mixed, name: "Anna")
        // Naming the same voice again replaces its name.
        try await f.store.nameDraftVoice(meetingID: f.meeting.id, utterance: first, name: "Pyotr")
        #expect(try await f.store.liveNames(meetingID: f.meeting.id).map(\.name).sorted() == ["Anna", "Pyotr"])
        try await f.store.removeDraftName(meetingID: f.meeting.id, recordingID: f.recording.id, kind: .reply, target: mixed.id)
        await #expect(throws: SpeakerRenameError.changed) {
            try await f.store.removeDraftName(meetingID: f.meeting.id, recordingID: f.recording.id, kind: .reply, target: mixed.id)
        }
        try await f.store.nameDraftReply(meetingID: f.meeting.id, utterance: mixed, name: "Anna")
        try await f.store.close()

        let reopened = try await SessionStore.open(f.library)
        let names = try await reopened.liveNames(meetingID: f.meeting.id)
        #expect(names.map(\.name).sorted() == ["Anna", "Pyotr"])
        #expect(try await reopened.namedSpeech(meetingID: f.meeting.id).map(\.name).sorted() == ["Anna", "Pyotr"])
        try await reopened.close()
    }

    @Test func aReplyNameInsideANamedVoiceCountsForThatPerson() async throws {
        let f = try await DraftFixture.make()
        defer { f.remove() }
        let voice = ProvisionalSpeaker(id: UUID(), number: 3)
        let rows = [try f.row(0, 3, voices: [voice]), try f.row(3, 6, voices: [voice]), try f.row(6, 9, voices: [voice])]
        try await f.store.saveLiveDraft(f.draft(rows, complete: false))
        try await f.store.nameDraftVoice(meetingID: f.meeting.id, utterance: rows[0], name: "Petr")
        try await f.store.nameDraftReply(meetingID: f.meeting.id, utterance: rows[1], name: "Ivan")
        let named = try await f.store.namedSpeech(meetingID: f.meeting.id)
        #expect(named.first { $0.person == "ivan" }?.intervals == [try span(3, 6)])
        #expect(named.first { $0.person == "petr" }?.intervals == [try span(0, 3), try span(6, 9)])
        // A later row of the named voice counts too once the draft is saved.
        let later = try f.row(9, 12, voices: [voice])
        try await f.store.saveLiveDraft(f.draft(rows + [later], complete: true))
        #expect(try await f.store.namedSpeech(meetingID: f.meeting.id).first { $0.person == "petr" }?.intervals.last == (try span(9, 12)))
        // The draft shows names on rows: reply first, then the voice.
        let snapshot = try await f.store.meetingTranscript(meetingID: f.meeting.id)
        let labels = LiveDraftRows.rows(drafts: snapshot.drafts, names: snapshot.liveNames).map(\.label)
        #expect(labels == ["Petr", "Ivan", "Petr", "Petr"])
        try await f.store.close()
    }

    /// Ten draft voices, five of them named: each named voice's final blocks get
    /// the name, a block mixing two named people (one over a fifth) stays unnamed,
    /// and a name covering no final block is reported as not placed.
    @Test func tenVoicesFiveNamedMixedBlocksStayUnnamedAndUnplacedNamesAreReported() async throws {
        let f = try await DraftFixture.make(seconds: 60)
        defer { f.remove() }
        let voices = (1...10).map { ProvisionalSpeaker(id: UUID(), number: UInt($0)) }
        let rows = try voices.enumerated().map { index, voice in try f.row(Double(index) * 3, Double(index + 1) * 3, voices: [voice]) }
        try await f.store.saveLiveDraft(f.draft(rows))
        let names = ["Anna", "Boris", "Clara", "Dmitry", "Elena"]
        for (index, name) in names.enumerated() {
            try await f.store.nameDraftVoice(meetingID: f.meeting.id, utterance: rows[index], name: name)
        }
        // Olga named a row the final transcript has no block for (after 30 s).
        let late = try f.row(40, 42, voices: [ProvisionalSpeaker(id: UUID(), number: 11)])
        try await f.store.nameDraftReply(meetingID: f.meeting.id, utterance: late, name: "Olga")

        let day = f.recording.days[0].id
        func segment(_ start: Double, _ end: Double) throws -> TranscriptSegment {
            TranscriptSegment(recordingID: f.recording.id, dayID: day, track: .system, interval: try span(start, end),
                              wallClockStart: f.recording.startedAt.addingTimeInterval(start),
                              speaker: .system(daySpeakerID: UUID()), originalText: "Final")
        }
        // Final blocks follow the draft rows, except one spanning Anna and Boris (1.5 s each).
        var segments: [TranscriptSegment] = []
        for index in 2..<10 { segments.append(try segment(Double(index) * 3, Double(index + 1) * 3)) }
        segments.insert(try segment(1.5, 4.5), at: 0)
        segments.insert(try segment(0, 1.4), at: 0)
        let revision = TranscriptRevision(recordingID: f.recording.id, sourceGeneration: f.recording.generation, kind: .final,
                                          segments: segments, modelRevisions: [])
        let named = try await f.store.namedSpeech(meetingID: f.meeting.id).filter { $0.recordingID == f.recording.id }
        let summary = try #require(try await f.store.consumeDraftNames(meetingID: f.meeting.id, recordingID: f.recording.id,
                                                                         revision: revision, named: named, at: Date()))
        let anchors = try await f.store.fragmentAnchors(meetingID: f.meeting.id)
        let byStart = Dictionary(anchors.map { ($0.interval.start.seconds, $0.name) }, uniquingKeysWith: { a, _ in a })
        #expect(byStart == [0: "Anna", 6: "Clara", 9: "Dmitry", 12: "Elena"])
        // Boris's only block was mixed with Anna's speech, so his name is not placed.
        #expect(summary.namedReplies == 4 && summary.unplaced == ["Boris", "Olga"] && summary.placed == ["Anna", "Clara", "Dmitry", "Elena"])
        // Consumed: draft names and the draft are retired.
        #expect(try await f.store.liveNames(meetingID: f.meeting.id).isEmpty)
        #expect(try await f.store.liveDrafts(meetingID: f.meeting.id).isEmpty)
        try await f.store.close()
    }

    @Test func draftNamesCarryIntoTheFinalTranscriptAndAReprocessKeepsThem() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        try removeFinalHead(fixture)
        let store = fixture.store, meetingID = fixture.recording.meetingID
        let voice = ProvisionalSpeaker(id: UUID(), number: 2)
        let row = try fixtureRow(fixture, 0, 3, voices: [voice])
        try await store.saveLiveDraft(LiveDraft(meetingID: meetingID, recordingID: fixture.recording.id, utterances: [row], complete: true))
        try await store.nameDraftVoice(meetingID: meetingID, utterance: row, name: "Petr")
        let profilesBefore = try await store.speakerAssignments(meetingID: meetingID)

        _ = try await stageFinal(fixture)
        let publication = try await store.publishFinalTranscript(jobID: fixture.job.id)
        #expect(publication.draftNaming?.namedReplies == 1 && publication.draftNaming?.unplaced == [])
        let snapshot = try await store.meetingTranscript(meetingID: meetingID)
        #expect(snapshot.drafts.isEmpty && snapshot.liveNames.isEmpty)
        #expect(snapshot.draftNaming[fixture.recording.id]?.placed == ["Petr"])
        let system = snapshot.items.compactMap { item -> TranscriptBlock? in
            if case .speech(let block) = item, block.speaker != .microphone { block } else { nil }
        }
        #expect(!system.isEmpty && system.allSatisfy { $0.speakerLabel == "Petr" && $0.isNamedFragment })
        // No manual voice name was created by the draft name.
        #expect(try await store.speakerAssignments(meetingID: meetingID).filter { $0.origin == .manual } == profilesBefore.filter { $0.origin == .manual })

        // Reprocessing uses the fragment names, not the consumed draft names.
        let job = try await nextFinalJob(fixture)
        _ = try await stageFinal(fixture, job: job)
        let again = try await store.publishFinalTranscript(jobID: job.id)
        #expect(again.draftNaming == nil)
        let reprocessed = try await store.meetingTranscript(meetingID: meetingID)
        #expect(reprocessed.items.contains { if case .speech(let block) = $0 { block.speakerLabel == "Petr" } else { false } })
        try await store.close()
    }

    @Test func aFailedRunKeepsTheDraftAndItsNamesForTheNextRun() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        try removeFinalHead(fixture)
        let store = fixture.store, meetingID = fixture.recording.meetingID
        let row = try fixtureRow(fixture, 0, 3, voices: [ProvisionalSpeaker(id: UUID(), number: 1)])
        try await store.saveLiveDraft(LiveDraft(meetingID: meetingID, recordingID: fixture.recording.id, utterances: [row], complete: true))
        try await store.nameDraftReply(meetingID: meetingID, utterance: row, name: "Olga")
        // Alignment fails: the job fails, the draft and its name stay.
        let probe = FinalProbe(); await probe.configure(fail: true)
        await #expect(throws: (any Error).self) {
            try await FinalTranscriptionPipeline(store: store, library: fixture.library, inference: probe).runAndPublish(jobID: fixture.job.id)
        }
        #expect(try await store.job(fixture.job.id).stage == .failed)
        #expect(try await store.liveDrafts(meetingID: meetingID).count == 1)
        #expect(try await store.liveNames(meetingID: meetingID).map(\.name) == ["Olga"])
        // Cancelled processing keeps them too; a later successful run receives the name.
        _ = try await store.cancelFinalTranscription(meetingID: meetingID)
        #expect(try await store.liveDrafts(meetingID: meetingID).count == 1)
        let job = try await nextFinalJob(fixture)
        _ = try await stageFinal(fixture, job: job)
        let publication = try await store.publishFinalTranscript(jobID: job.id)
        #expect(publication.draftNaming?.placed == ["Olga"])
        try await store.close()
    }

    @Test func aFinishedRecordingRefusesDraftNames() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let row = try fixtureRow(fixture, 0, 3, voices: [ProvisionalSpeaker(id: UUID(), number: 1)])
        await #expect(throws: LiveDraftError.finalized) {
            try await fixture.store.nameDraftReply(meetingID: fixture.recording.meetingID, utterance: row, name: "Late")
        }
        // A draft saved after the final transcript is ignored.
        try await fixture.store.saveLiveDraft(LiveDraft(meetingID: fixture.recording.meetingID, recordingID: fixture.recording.id,
                                                        utterances: [row], complete: true))
        #expect(try await fixture.store.liveDrafts(meetingID: fixture.recording.meetingID).isEmpty)
        try await fixture.store.close()
    }

    /// Draft names never teach saved voices; Remember Voices… opens the usual
    /// fragment confirmation for the person's named replies.
    @MainActor @Test func draftNamesTeachSavedVoicesOnlyThroughRememberVoices() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let home = try TemporaryFolder(); defer { home.remove() }
        let profiles = VoiceProfileStore(home: home.url)
        let fixture = try await finalFixture(folder)
        try removeFinalHead(fixture)
        let store = fixture.store, meetingID = fixture.recording.meetingID
        let row = try fixtureRow(fixture, 0, 3, voices: [ProvisionalSpeaker(id: UUID(), number: 1)])
        try await store.saveLiveDraft(LiveDraft(meetingID: meetingID, recordingID: fixture.recording.id, utterances: [row], complete: true))
        try await store.nameDraftVoice(meetingID: meetingID, utterance: row, name: "Petr")
        _ = try await stageFinal(fixture)
        _ = try await store.publishFinalTranscript(jobID: fixture.job.id)
        #expect(try await profiles.profiles().isEmpty)

        let presentation = MeetingTranscriptPresentation(store: store, meetingID: meetingID)
        await presentation.refresh()
        let message = try #require(presentation.draftNamingMessages.first)
        #expect(message.message == "Named 1 reply from the draft." && message.people == ["Petr"])
        await presentation.beginRememberDraftVoice(recordingID: fixture.recording.id, name: "Petr")
        #expect(presentation.renameTarget != nil && presentation.scope == .reply && presentation.rememberVoice)
        #expect(presentation.draftName == "Petr")
        let ids = try #require(presentation.fragmentSegmentIDs)
        let confirmed = try await store.nameFragmentWithConfirmation(meetingID: meetingID, recordingID: fixture.recording.id,
                                                                     segmentIDs: ids, name: "Petr")
        #expect(confirmed.confirmation.fragments.map(\.name) == ["Petr"])
        #expect(try await profiles.profiles().isEmpty)
        presentation.cancelRename()
        try await store.close()
    }
}
