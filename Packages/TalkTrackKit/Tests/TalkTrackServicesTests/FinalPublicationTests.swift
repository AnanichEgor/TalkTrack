import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

func publicationDB(_ library: OpenedLibrary) throws -> SQLiteConnection {
    let path = "/" + DirectoryHandle.physicalComponents(library.directory).dropFirst().joined(separator: "/")
    return try SQLiteConnection(path: path + "/Library.sqlite3")
}
func nextFinalJob(_ fixture: FinalFixture, store: SessionStore? = nil) async throws -> ProcessingJob {
    try await (store ?? fixture.store).enqueue(kind: .finalTranscription, meetingID: fixture.recording.meetingID,
        recordingID: fixture.recording.id, settings: fixture.job.snapshot.settings, models: fixture.job.snapshot.models)
}
func stageFinal(_ fixture: FinalFixture, job: ProcessingJob? = nil, store: SessionStore? = nil,
                        text: String? = nil, microphone: String = "Sure, I will send it tomorow") async throws -> FinalTranscriptionCheckpoint {
    // Distinct microphone speech: identical simultaneous text would be an echo.
    let probe = FinalProbe(); await probe.configure(text: text, microphoneText: microphone)
    return try await FinalTranscriptionPipeline(store: store ?? fixture.store, library: fixture.library, inference: probe)
        .run(jobID: job?.id ?? fixture.job.id)
}
func unitVector(_ index: Int) -> [Float] {
    var vector = Array(repeating: Float(0), count: 256); vector[index] = 1; return vector
}

/// Inject source segmentation through the real bounded clustering/checkpoint
/// API, then regroup the original aligned words without changing their timing.
func resegment(_ input: FinalTranscriptionCheckpoint, split: Bool = false,
                       mixed: Bool = false, vectorIndex: Int = 0,
                       firstVector: [Float]? = nil, secondVector: [Float]? = nil) throws -> FinalTranscriptionCheckpoint {
    var checkpoint = input
    let index = try #require(checkpoint.windows.firstIndex { $0.track == .system && $0.gapReason == nil })
    var window = checkpoint.windows[index]
    let models = Dictionary(uniqueKeysWithValues: checkpoint.job.models.map { ($0.role, $0) })
    var clustering = try SystemSpeakerClustering(meetingID: checkpoint.job.source.meetingID,
        segmentation: models[.segmentation]!, embedding: models[.embedding]!)
    let ranges = try split ? [
        MediaInterval(start: window.owned.start, end: MediaTime(seconds: 1.4)),
        MediaInterval(start: MediaTime(seconds: 1.4), end: window.owned.end)
    ] : [window.owned]
    let observations = ranges.enumerated().map { offset, range in
        SpeakerClusteringObservation(slot: offset + 1, activity: [range],
            cleanSpeech: mixed ? [] : [range],
            embedding: mixed ? nil : SpeakerWindowEmbedding(values: (offset == 0 ? firstVector : secondVector) ??
                unitVector(offset + vectorIndex), model: models[.embedding]!))
    } + (mixed ? [SpeakerClusteringObservation(slot: 2, activity: [window.owned])] : [])
    let result = try clustering.process(recordingID: checkpoint.job.recordingID!, day: window.day,
        context: window.active, owned: window.owned, observations: observations)
    window.speakers = result.map {
        DiarizedSystemSegment(recordingID: checkpoint.job.recordingID!, dayID: window.day.id,
            speakerID: $0.speakerID, number: $0.number, active: $0.active,
            wallClockStart: window.wallClockStart.addingTimeInterval($0.active.start.seconds - window.active.start.seconds))
    }
    var groups: [[FinalAlignedWord]] = [], candidates: [[UUID]] = []
    for word in window.words! {
        let ids = Set(window.speakers!.filter {
            $0.active.start < word.active.end && word.active.start < $0.active.end
        }.map(\.speakerID)).sorted { $0.uuidString < $1.uuidString }
        if candidates.last == ids { groups[groups.count - 1].append(word) }
        else { candidates.append(ids); groups.append([word]) }
    }
    window.blocks = try zip(groups, candidates).map { words, ids in
        let text = words.map(\.text).joined(separator: " ")
        return FinalTextBlock(id: UUID(), recordingID: checkpoint.job.recordingID!, day: window.day, track: .system,
            words: words, interval: try MediaInterval(start: words.first!.active.start, end: words.last!.active.end),
            speakerCandidates: ids, originalText: text, correctedText: text)
    }
    checkpoint.windows[index] = window
    checkpoint.speakerCheckpoint = try clustering.checkpoint()
    checkpoint.correctionBatches = try AudioTrack.allCases.compactMap { track in
        let blocks = checkpoint.blocks.filter { $0.track == track }
        guard !blocks.isEmpty else { return nil }
        return FinalCorrectionBatch(blockIDs: blocks.map(\.id),
            contextPlan: try TextContextPlanner.resolve(selection: checkpoint.job.settings.contextLimit,
                role: .spelling, inputTokens: 100), generatedTokens: 50)
    }
    return checkpoint
}

@Suite struct FinalPublicationTests {
    @Test func atomicReplacementRetainsOtherRecordingNotesHistoryAndFrozenSnapshot() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let store = fixture.store, meetingID = fixture.recording.meetingID
        let other = try Recording(meetingID: meetingID, startedAt: fixture.recording.startedAt.addingTimeInterval(172800), timeZoneIdentifier: "UTC")
        try await store.saveRecording(other)
        let otherJob = try await store.enqueue(kind: .finalTranscription, meetingID: meetingID, recordingID: other.id,
            settings: ProcessingSettings(), models: fixture.job.snapshot.models)
        let otherRevision = TranscriptRevision(recordingID: other.id, sourceGeneration: other.generation,
            kind: .final, segments: [], modelRevisions: fixture.job.snapshot.models)
        try await store.publishTranscript(otherRevision, jobID: otherJob.id)
        let editor = NotesAutosave(store: store)
        try await editor.edit(meetingID: meetingID, text: "Do not overwrite these notes")
        try await editor.flushForQuit()
        try await store.setMeetingLanguage(meetingID, language: .russian)
        let staged = try await stageFinal(fixture)
        let owner = try await store.meeting(meetingID)
        let result = try await store.publishFinalTranscript(jobID: fixture.job.id)
        let revision = try #require(try await store.transcript(meetingID: meetingID, recordingID: fixture.recording.id))
        #expect(revision.id == result.id && revision.kind == .final)
        #expect(revision.segments.map(\.id) == staged.blocks.sorted {
            if $0.interval.start != $1.interval.start { return $0.interval.start < $1.interval.start }
            return $0.track == .system
        }.map(\.id))
        #expect(revision.segments.allSatisfy { $0.correctedText?.contains("tomorrow") == true })
        #expect(revision.segments.filter { $0.track == .microphone }.allSatisfy { $0.speaker == .microphone })
        #expect(result.job == fixture.job.snapshot && result.job.settings.contextLimit == .small)
        #expect(revision.modelRevisions == fixture.job.snapshot.models)
        #expect(try await store.job(fixture.job.id).stage == .completed)
        #expect(try await store.meeting(meetingID).generation == owner.generation + 1)
        #expect(try await store.transcript(meetingID: meetingID, recordingID: other.id) == otherRevision)
        #expect(try await store.transcriptRevision(fixture.previous.id) == fixture.previous)
        #expect(try await store.notes(meetingID: meetingID)?.text == "Do not overwrite these notes")
        try await store.close()
        let reopened = try await SessionStore.open(fixture.library)
        #expect(try await reopened.finalPublication(revisionID: result.id) == result)
        #expect(try await reopened.transcript(meetingID: meetingID, recordingID: fixture.recording.id) == revision)
        #expect(try await reopened.transcriptRevision(fixture.previous.id) == fixture.previous)
        let before = try await reopened.meeting(meetingID)
        #expect(try await reopened.publishFinalTranscript(jobID: fixture.job.id) == result)
        #expect(try await reopened.meeting(meetingID) == before)
        try await reopened.close()
    }

    @Test func runAndPublishUsesTheStagedResult() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, language: .russian, microphoneOnly: true)
        let probe = FinalProbe(); await probe.configure(text: "Алексей не заплатит 42 рубля завтро")
        let result = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
            .runAndPublish(jobID: fixture.job.id)
        let revision = try #require(try await fixture.store.transcriptRevision(result.id))
        #expect(revision.segments[0].correctedText == "Алексей не заплатит 42 рубля завтра")
        #expect(revision.segments[0].speaker == .microphone)
        #expect(result.speakers.isEmpty && result.reviews.isEmpty)
        try await fixture.store.close()
    }

    @Test func latestManualRenameSurvivesRerunWithNewClustersAndChangedBlocks() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        _ = try await stageFinal(fixture)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        let identity = try #require(first.speakers.first)
        let original = try await fixture.store.confirmSpeakerName(meetingID: identity.meetingID, speakerID: identity.id, name: "Alex")
        let job = try await nextFinalJob(fixture)
        let staged = try await stageFinal(fixture, job: job, text: "Alex will not pay 42 rubles tomorrow today")
        #expect(staged.blocks.first { $0.track == .system }?.speakerCandidates != [identity.id])
        let latest = try await fixture.store.confirmSpeakerName(meetingID: identity.meetingID, speakerID: identity.id, name: "Алексей")
        let result = try await fixture.store.publishFinalTranscript(jobID: job.id)
        #expect(result.speakers.map(\.id) == [identity.id])
        #expect(result.assignments == [latest] && latest.id != original.id)
        #expect(result.reviews.isEmpty)
        #expect(result.previousRevisionID == first.id)
        let revision = try #require(try await fixture.store.transcriptRevision(result.id))
        let formatted = try TranscriptFormatter.format(meetingID: identity.meetingID, recordings: [fixture.recording],
            segments: revision.segments, speakers: result.speakers, assignments: result.assignments)
        #expect(formatted.contains { $0.text.contains("Алексей - Alex will not pay 42") })
        #expect(formatted.contains { $0.text.contains("You - Sure, I will send it tomorrow") })
        #expect(try await fixture.store.transcriptRevision(first.id) != nil)
        #expect(try await fixture.store.speakerAssignment(original.id) == original)
        #expect(try await fixture.store.publishFinalTranscript(jobID: fixture.job.id) == first)
        #expect(try await fixture.store.transcript(meetingID: identity.meetingID, recordingID: fixture.recording.id)?.id == result.id)
        try await fixture.store.close()
    }

    /// Reprocessing replaces unnamed voices; numbering restarts at Voice1
    /// instead of continuing after the replaced ones (user request, 2026-10-13).
    @Test func unnamedVoicesKeepNumberingFromOneAcrossReprocessing() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        _ = try await stageFinal(fixture)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        #expect(first.speakers.map(\.number) == [1])
        for _ in 0..<2 {
            let job = try await nextFinalJob(fixture)
            _ = try await stageFinal(fixture, job: job)
            let result = try await fixture.store.publishFinalTranscript(jobID: job.id)
            #expect(result.speakers.map(\.number) == [1])
        }
        #expect(try await fixture.store.daySpeakers(meetingID: fixture.recording.meetingID).count >= 2)
        try await fixture.store.close()
    }

    @Test func aPersistedLiveHeadIsReplacedOnlyAfterCompleteStaging() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let live = TranscriptRevision(recordingID: fixture.recording.id, sourceGeneration: fixture.recording.generation,
            kind: .live, segments: fixture.previous.segments, modelRevisions: fixture.previous.modelRevisions)
        // Capture-to-store wiring is task 4.6. Seed its serialized live head here
        // to exercise publication against the real SQLite snapshot transaction.
        let db = try publicationDB(fixture.library)
        try db.execute("INSERT INTO records(kind,id,meeting_id,scope,payload) VALUES ('transcript',?,?,?,?)",
            [.text(live.id.uuidString), .text(fixture.recording.meetingID.uuidString),
             .text(fixture.recording.id.uuidString), .blob(DomainCodec.encode(live))])
        try db.execute("UPDATE heads SET id=? WHERE meeting_id=? AND kind='transcript' AND scope=?",
            [.text(live.id.uuidString), .text(fixture.recording.meetingID.uuidString), .text(fixture.recording.id.uuidString)])
        let job = try await nextFinalJob(fixture)
        _ = try await stageFinal(fixture, job: job)
        #expect(try await fixture.store.transcript(meetingID: fixture.recording.meetingID, recordingID: fixture.recording.id) == live)
        let result = try await fixture.store.publishFinalTranscript(jobID: job.id)
        let final = try #require(try await fixture.store.transcriptRevision(result.id))
        #expect(result.previousRevisionID == live.id && final.kind == .final)
        #expect(try await fixture.store.transcriptRevision(live.id) == live)
        #expect(try await fixture.store.recordings(meetingID: fixture.recording.meetingID) == [fixture.recording])
        try await fixture.store.close()
    }

    /// The user's name says the whole voice is one person (guided-speaker-labeling):
    /// when processing hears it as two voices, both stay that person's voice.
    @Test func aSplitNamedVoiceStaysOnePersonWithItsConfirmedName() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, seconds: 6)
        let text = "Alex will not pay 42 rubles tomorrow and Maria will check 17 items today"
        _ = try await stageFinal(fixture, text: text)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        let identity = try #require(first.speakers.first)
        let confirmed = try await fixture.store.confirmSpeakerName(meetingID: identity.meetingID, speakerID: identity.id, name: "Alex")
        let job = try await nextFinalJob(fixture)
        let staged = try resegment(try await stageFinal(fixture, job: job, text: text), split: true)
        try await fixture.store.saveFinalCheckpoint(staged, stage: .validating)
        let result = try await fixture.store.publishFinalTranscript(jobID: job.id)
        #expect(result.speakers.map(\.id) == [identity.id] && result.assignments == [confirmed])
        #expect(!result.reviews.contains { $0.previousAssignmentIDs == [confirmed.id] })
        #expect(try await fixture.store.speakerAssignments(meetingID: identity.meetingID) == [confirmed])
        #expect(try await fixture.store.transcriptRevision(first.id) != nil)
        try await fixture.store.close()
    }

    @Test func mergeCannotSpreadEitherConfirmedName() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, seconds: 6)
        let text = "Alex will not pay 42 rubles tomorrow and Maria will check 17 items today"
        let initial = try resegment(try await stageFinal(fixture, text: text), split: true)
        try await fixture.store.saveFinalCheckpoint(initial, stage: .validating)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        #expect(first.speakers.count == 2)
        for (index, speaker) in first.speakers.enumerated() {
            try await fixture.store.confirmSpeakerName(meetingID: speaker.meetingID, speakerID: speaker.id, name: index == 0 ? "Alex" : "Maria")
        }
        let job = try await nextFinalJob(fixture)
        _ = try await stageFinal(fixture, job: job, text: text)
        let result = try await fixture.store.publishFinalTranscript(jobID: job.id)
        // The rerun hears one voice over both people's speech: neither name
        // spreads to it, and the speech stays an unnamed voice.
        #expect(result.assignments.isEmpty && !result.speakers.isEmpty)
        try await fixture.store.close()
    }

    /// A name belongs to the speech the user named, not to a voice vector: a
    /// rerun that hears the same speech with another vector keeps the name.
    @Test func aChangedVoiceVectorKeepsTheNameOnTheNamedSpeech() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        _ = try await stageFinal(fixture)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        let identity = try #require(first.speakers.first)
        let confirmed = try await fixture.store.confirmSpeakerName(meetingID: identity.meetingID, speakerID: identity.id, name: "Alex")
        let job = try await nextFinalJob(fixture)
        let changed = try resegment(try await stageFinal(fixture, job: job), vectorIndex: 1)
        try await fixture.store.saveFinalCheckpoint(changed, stage: .validating)
        let result = try await fixture.store.publishFinalTranscript(jobID: job.id)
        #expect(result.assignments == [confirmed] && result.speakers[0].id == identity.id)
        try await fixture.store.close()
    }

    /// Other speaker models do not change who spoke when: the name stays on
    /// the named speech, and the job keeps its own models.
    @Test func otherPreprocessingKeepsTheNameWithoutChangingJobModels() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        _ = try await stageFinal(fixture)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        let identity = try #require(first.speakers.first)
        let confirmed = try await fixture.store.confirmSpeakerName(meetingID: identity.meetingID, speakerID: identity.id, name: "Alex")
        let changedModels = fixture.job.snapshot.models.map { model in
            model.role == .embedding ? ModelSnapshot(role: model.role, repository: model.repository, revision: model.revision,
                directory: model.directory, preprocessingVersion: "injected-new-preprocessing") : model
        }
        let job = try await fixture.store.enqueue(kind: .finalTranscription, meetingID: identity.meetingID,
            recordingID: fixture.recording.id, settings: fixture.job.snapshot.settings, models: changedModels)
        _ = try await stageFinal(fixture, job: job)
        let result = try await fixture.store.publishFinalTranscript(jobID: job.id)
        #expect(result.assignments == [confirmed])
        #expect(result.job == job.snapshot && result.job.models == changedModels)
        try await fixture.store.close()
    }

    /// The segmentation separated two near-identical voices within one window:
    /// they stay two voices without a merge calibration, and the confirmed name
    /// returns to the speech the user named, not to the similar voice.
    @Test func similarCompetingVoiceInOneWindowStaysApartAndKeepsTheNamedSpeech() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, seconds: 6)
        let text = "Alex will not pay 42 rubles tomorrow and Maria will check 17 items today"
        var similar = unitVector(0); similar[0] = 0.99; similar[1] = sqrt(1 - 0.99 * 0.99)
        let initial = try resegment(try await stageFinal(fixture, text: text), split: true, secondVector: similar)
        try await fixture.store.saveFinalCheckpoint(initial, stage: .validating)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        let identity = first.speakers[0]
        try await fixture.store.confirmSpeakerName(meetingID: identity.meetingID, speakerID: identity.id, name: "Alex")
        let job = try await nextFinalJob(fixture)
        let staged = try resegment(try await stageFinal(fixture, job: job, text: text), split: true, secondVector: similar)
        try await fixture.store.saveFinalCheckpoint(staged, stage: .validating)
        #expect(first.speakers.count == 2)
        let result = try await fixture.store.publishFinalTranscript(jobID: job.id)
        let confirmed = try await fixture.store.speakerAssignments(meetingID: identity.meetingID)
        #expect(result.speakers.count == 2 && result.assignments == confirmed && confirmed.map(\.daySpeakerID) == [identity.id])
        let revision = try #require(try await fixture.store.transcriptRevision(result.id))
        let named = Set(revision.segments.filter { $0.speaker == .system(daySpeakerID: identity.id) }.map(\.originalText))
        let before = try #require(try await fixture.store.transcriptRevision(first.id))
        #expect(named == Set(before.segments.filter { $0.speaker == .system(daySpeakerID: identity.id) }.map(\.originalText)))
        try await fixture.store.close()
    }

    /// The named speech is the speech the user confirmed, so reruns cannot
    /// widen it step by step, whatever each rerun's vectors are.
    @Test func repeatedRerunsKeepTheConfirmedSpeechAndCannotDrift() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        _ = try await stageFinal(fixture)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        let identity = try #require(first.speakers.first)
        let confirmation = try await fixture.store.confirmSpeakerName(meetingID: identity.meetingID, speakerID: identity.id, name: "Alex")
        let named = try await fixture.store.namedSpeech(meetingID: identity.meetingID)
        for cosine: Float in [0.97, 0.94] {
            let job = try await nextFinalJob(fixture)
            var vector = unitVector(0); vector[0] = cosine; vector[1] = sqrt(1 - cosine * cosine)
            let staged = try resegment(try await stageFinal(fixture, job: job), firstVector: vector)
            try await fixture.store.saveFinalCheckpoint(staged, stage: .validating)
            let result = try await fixture.store.publishFinalTranscript(jobID: job.id)
            #expect(result.assignments == [confirmation] && result.speakers[0].id == identity.id)
            #expect(try await fixture.store.namedSpeech(meetingID: identity.meetingID) == named)
        }
        try await fixture.store.close()
    }

    @Test func namesStayWithinTheirCaptureDayWhenTheVoiceRepeatsOnAnotherDay() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, seconds: 6, resumed: true)
        _ = try await stageFinal(fixture)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        #expect(first.speakers.count == 2 && first.speakers.allSatisfy { $0.number == 1 })
        let identity = first.speakers.first { $0.dayID == fixture.recording.days[0].id }!
        let confirmed = try await fixture.store.confirmSpeakerName(meetingID: identity.meetingID, speakerID: identity.id, name: "Alex")
        let job = try await nextFinalJob(fixture)
        _ = try await stageFinal(fixture, job: job)
        let result = try await fixture.store.publishFinalTranscript(jobID: job.id)
        #expect(result.assignments == [confirmed])
        #expect(result.speakers.filter { $0.dayID != identity.dayID }.allSatisfy { $0.id != identity.id })
        #expect(result.reviews.isEmpty)
        try await fixture.store.close()
    }

    /// Without any voice evidence the speech the user named keeps its name;
    /// the microphone never borrows a system name.
    @Test func namedSpeechWithoutVoicesKeepsItsNameAndMicrophoneCannotBorrowIt() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        _ = try await stageFinal(fixture)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        let identity = try #require(first.speakers.first)
        let confirmed = try await fixture.store.confirmSpeakerName(meetingID: identity.meetingID, speakerID: identity.id, name: "Alex")
        let job = try await nextFinalJob(fixture)
        var staged = try await stageFinal(fixture, job: job)
        let index = staged.windows.firstIndex { $0.track == .system }!
        staged.windows[index].speakers = []
        staged.windows[index].blocks = staged.windows[index].blocks!.map { block in
            FinalTextBlock(id: block.id, recordingID: block.recordingID, day: block.day, track: block.track,
                words: block.words, interval: block.interval, speakerCandidates: [], originalText: block.originalText,
                correctedText: block.correctedText)
        }
        try await fixture.store.saveFinalCheckpoint(staged, stage: .validating)
        let result = try await fixture.store.publishFinalTranscript(jobID: job.id)
        #expect(result.assignments == [confirmed] && result.voiceEvidence.isEmpty)
        let revision = try #require(try await fixture.store.transcriptRevision(result.id))
        #expect(revision.segments.filter { $0.track == .system }.allSatisfy { $0.speaker == .system(daySpeakerID: identity.id) })
        #expect(revision.segments.filter { $0.track == .microphone }.allSatisfy { $0.speaker == .microphone })
        await #expect(throws: StoreError.invalidResult) {
            try await fixture.store.confirmSpeakerName(meetingID: identity.meetingID, speakerID: revision.segments.first { $0.track == .microphone }!.id, name: "Me")
        }
        try await fixture.store.close()
    }

    @Test func loudspeakerEchoOnTheMicrophoneIsNotPublishedAsYou() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        // Without headphones the microphone hears the same words as system audio.
        let staged = try await stageFinal(fixture, microphone: "Alex will not pay 42 rubles tomorow")
        let echoes = MicrophoneEcho.blocks(in: staged.blocks)
        #expect(!echoes.isEmpty && echoes == Set(staged.blocks.filter { $0.track == .microphone }.map(\.id)))
        let result = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        let revision = try #require(try await fixture.store.transcriptRevision(result.id))
        #expect(!revision.segments.contains { $0.track == .microphone })
        #expect(revision.segments.contains { $0.track == .system })
        // Own speech over someone else's is kept: few of its words were heard from the system.
        var mixed = staged.blocks.first { $0.track == .microphone }!
        let words = mixed.words.enumerated().map { index, word in
            FinalAlignedWord(text: index < 2 ? word.text : "мой\(index)", active: word.active, wallClockStart: word.wallClockStart)
        }
        mixed = FinalTextBlock(id: mixed.id, recordingID: mixed.recordingID, day: mixed.day, track: .microphone,
            words: words, interval: mixed.interval, speakerCandidates: [], originalText: words.map(\.text).joined(separator: " "))
        #expect(MicrophoneEcho.blocks(in: staged.blocks.filter { $0.track == .system } + [mixed]).isEmpty)
        try await fixture.store.close()
    }

    @Test func mixedSpeechIsPublishedWithoutAForcedIdentity() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let staged = try resegment(try await stageFinal(fixture), mixed: true)
        try await fixture.store.saveFinalCheckpoint(staged, stage: .validating)
        let result = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        #expect(result.speakers.count == 1 && result.voiceEvidence.isEmpty && result.assignments.isEmpty)
        #expect(result.reviews.count == 1 && result.reviews[0].reason == .mixedSpeech)
        #expect(result.reviews[0].speakerIDs == result.speakers.map(\.id))
        try await fixture.store.close()
    }

    @Test func anotherRecordingOnTheSameFrozenDayContinuesNumbersWithoutBorrowingNames() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let first = try await finalFixture(folder)
        _ = try await stageFinal(first)
        let firstPublication = try await first.store.publishFinalTranscript(jobID: first.job.id)
        let identity = try #require(firstPublication.speakers.first)
        try await first.store.confirmSpeakerName(meetingID: identity.meetingID, speakerID: identity.id, name: "Alex")
        let firstHead = try await first.store.transcript(meetingID: identity.meetingID, recordingID: first.recording.id)
        try await first.store.close()
        let second = try await finalFixture(folder, meetingID: identity.meetingID)
        #expect(second.recording.days[0].id != first.recording.days[0].id)
        _ = try await stageFinal(second)
        let result = try await second.store.publishFinalTranscript(jobID: second.job.id)
        #expect(result.speakers[0].number == identity.number + 1)
        #expect(result.speakers[0].id != identity.id && result.assignments.isEmpty)
        #expect(try await second.store.transcript(meetingID: identity.meetingID, recordingID: first.recording.id) == firstHead)
        #expect(try await second.store.speakerAssignments(meetingID: identity.meetingID).first?.name == "Alex")
        try await second.store.close()
    }

    @Test(arguments: ["transcript", "finalPublication", "daySpeaker", "head", "meeting", "job"])
    func eachWriteFailureRollsBackTheEntirePublication(boundary: String) async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        _ = try await stageFinal(fixture)
        let before = try await fixture.store.meeting(fixture.recording.meetingID)
        let db = try publicationDB(fixture.library)
        let trigger: String
        switch boundary {
        case "head": trigger = "BEFORE UPDATE ON heads WHEN NEW.kind='transcript'"
        case "meeting": trigger = "BEFORE UPDATE ON meetings"
        case "job": trigger = "BEFORE UPDATE ON records WHEN NEW.kind='job'"
        default: trigger = "BEFORE INSERT ON records WHEN NEW.kind='" + boundary + "'"
        }
        try db.execute("CREATE TRIGGER fail_publish " + trigger + " BEGIN SELECT RAISE(ABORT, 'injected publication failure'); END")
        await #expect(throws: StoreError.self) { try await fixture.store.publishFinalTranscript(jobID: fixture.job.id) }
        #expect(try await fixture.store.transcript(meetingID: fixture.recording.meetingID, recordingID: fixture.recording.id) == fixture.previous)
        #expect(try await fixture.store.daySpeakers(meetingID: fixture.recording.meetingID).isEmpty)
        #expect(try await fixture.store.job(fixture.job.id).stage == .validating)
        #expect(try await fixture.store.meeting(fixture.recording.meetingID) == before)
        #expect(try db.integer("SELECT count(*) FROM records WHERE kind='finalPublication'") == 0)
        try db.execute("DROP TRIGGER fail_publish")
        _ = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        #expect(try await fixture.store.job(fixture.job.id).stage == .completed)
        try await fixture.store.close()
    }

    @Test func unreadyOrIncompleteStagingCannotPublish() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        await #expect(throws: StoreError.self) { try await fixture.store.publishFinalTranscript(jobID: fixture.job.id) }
        var staged = try await stageFinal(fixture)
        let index = try #require(staged.windows.firstIndex { $0.track == .system })
        staged.windows[index].blocks = []
        let keptIDs = Set(staged.blocks.map(\.id))
        staged.correctionBatches.removeAll { batch in batch.blockIDs.contains { !keptIDs.contains($0) } }
        try await fixture.store.saveFinalCheckpoint(staged, stage: .validating)
        await #expect(throws: FinalTranscriptionError.incompleteCoverage) { try await fixture.store.publishFinalTranscript(jobID: fixture.job.id) }
        #expect(try await fixture.store.transcript(meetingID: fixture.recording.meetingID, recordingID: fixture.recording.id) == fixture.previous)
        try await fixture.store.close()
    }

    @Test func supersedingRevisionAndChangedSourceRejectLatePublication() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        _ = try await stageFinal(fixture)
        let competing = try await nextFinalJob(fixture)
        _ = try await stageFinal(fixture, job: competing)
        let winner = try await fixture.store.publishFinalTranscript(jobID: competing.id)
        await #expect(throws: StoreError.staleSource) { try await fixture.store.publishFinalTranscript(jobID: fixture.job.id) }
        let next = try await nextFinalJob(fixture)
        _ = try await stageFinal(fixture, job: next)
        var source = fixture.recording; source.generation += 1
        try await fixture.store.saveRecording(source)
        await #expect(throws: StoreError.staleSource) { try await fixture.store.publishFinalTranscript(jobID: next.id) }
        #expect(try await fixture.store.transcript(meetingID: source.meetingID, recordingID: source.id)?.id == winner.id)
        try await fixture.store.close()
    }

    @Test func cancellationDeletionAndInterruptedRelaunchCannotBypassValidation() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        _ = try await stageFinal(fixture)
        try await fixture.store.close()
        let reopened = try await SessionStore.open(fixture.library)
        #expect(try await reopened.job(fixture.job.id).stage == .interrupted)
        await #expect(throws: StoreError.cancelledJob) { try await reopened.publishFinalTranscript(jobID: fixture.job.id) }
        _ = try await reopened.retryJob(fixture.job.id)
        _ = try await stageFinal(fixture, store: reopened)
        try await reopened.cancelJobs(meetingID: fixture.recording.meetingID)
        await #expect(throws: StoreError.cancelledJob) { try await reopened.publishFinalTranscript(jobID: fixture.job.id) }
        #expect(try await reopened.transcript(meetingID: fixture.recording.meetingID, recordingID: fixture.recording.id) == fixture.previous)
        try await reopened.deleteMeeting(fixture.recording.meetingID)
        await #expect(throws: StoreError.self) { try await reopened.publishFinalTranscript(jobID: fixture.job.id) }
        try await reopened.close()
    }
}
