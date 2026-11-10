import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// compact-library-storage group 1: processing state is kept only while usable.
@Suite struct StorageRetentionTests {
    private func count(_ db: SQLiteConnection, _ kind: String, _ recording: UUID) throws -> Int {
        try db.integer("SELECT count(*) FROM records WHERE kind='\(kind)' AND scope='\(recording.uuidString)'")
    }

    private func published(_ folder: TemporaryFolder) async throws -> (FinalFixture, FinalTranscriptPublication) {
        let fixture = try await finalFixture(folder, seconds: 6)
        let text = "Alex will not pay 42 rubles tomorrow and Maria will check 17 items today"
        try await fixture.store.saveFinalCheckpoint(try resegment(try await stageFinal(fixture, text: text), split: true), stage: .validating)
        return (fixture, try await fixture.store.publishFinalTranscript(jobID: fixture.job.id))
    }

    @Test func repeatedApplyNamesKeepOneCheckpointRevisionAndPublication() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let (fixture, _) = try await published(folder)
        let meetingID = fixture.recording.meetingID, recording = fixture.recording.id
        let db = try publicationDB(fixture.library)
        var last: FinalTranscriptPublication?
        for _ in 0..<10 { last = try #require(try await fixture.store.applyNames(meetingID: meetingID).first) }
        #expect(try count(db, "finalCheckpoint", recording) == 1)
        #expect(try count(db, "transcript", recording) == 1)
        #expect(try count(db, "finalPublication", recording) == 1)
        #expect(try db.integer("SELECT count(*) FROM heads WHERE kind='finalPublication'") == 1)
        // The kept checkpoint is the current one: names can be applied again, and the
        // workspace's unrecovered-window count still reads it.
        #expect(try await fixture.store.namesApplicableRecordings(meetingID: meetingID) == [recording])
        #expect(try await fixture.store.finalCheckpoint(jobID: try #require(last).job.id) != nil)
        #expect(try await fixture.store.transcript(meetingID: meetingID, recordingID: recording)?.id == last?.id)
        try await fixture.store.close()
    }

    @Test func confirmedNamesSurviveReprocessingAndApplyNamesAfterPruning() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let (fixture, first) = try await published(folder)
        let meetingID = fixture.recording.meetingID
        let identity = try #require(first.speakers.first)
        let confirmed = try await fixture.store.confirmSpeakerName(meetingID: meetingID, speakerID: identity.id, name: "Alex")
        let text = "Alex will not pay 42 rubles tomorrow and Maria will check 17 items today"
        for step in 0..<3 {
            if step == 1 { _ = try await fixture.store.applyNames(meetingID: meetingID) }
            let job = try await nextFinalJob(fixture)
            try await fixture.store.saveFinalCheckpoint(try resegment(try await stageFinal(fixture, job: job, text: text), split: true), stage: .validating)
            let result = try await fixture.store.publishFinalTranscript(jobID: job.id)
            #expect(result.speakers.contains { $0.id == identity.id })
            #expect(try await fixture.store.speakerAssignments(meetingID: meetingID).contains(confirmed))
        }
        let db = try publicationDB(fixture.library)
        #expect(try count(db, "transcript", fixture.recording.id) == 1)
        try await fixture.store.close()
    }

    /// D1 rule 4: the first publication holding a bank that a manual assignment
    /// (head or not) names stays, as `confirmedVoiceAnchors` scans in that order.
    @Test func theFirstHolderOfANamedVoiceBankStays() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let (fixture, first) = try await published(folder)
        let meetingID = fixture.recording.meetingID
        let bank = try #require(first.voiceEvidence.first)
        let interval = try MediaInterval(start: .zero, end: MediaTime(seconds: 1))
        let assignment = SpeakerAssignment(meetingID: meetingID, dayID: try #require(fixture.recording.days.first).id,
            daySpeakerID: bank.speakerID, name: "Alex", origin: .manual,
            evidence: [SpeechEvidence(recordingID: fixture.recording.id, interval: interval, embeddingFingerprint: try bank.fingerprint)])
        let db = try publicationDB(fixture.library)
        try db.execute("INSERT INTO records(kind,id,meeting_id,scope,payload) VALUES ('assignment',?,?,?,?)",
            [.text(assignment.id.uuidString), .text(meetingID.uuidString), .text(bank.speakerID.uuidString), .blob(DomainCodec.encode(assignment))])
        for _ in 0..<3 { _ = try await fixture.store.applyNames(meetingID: meetingID) }
        #expect(try await fixture.store.finalPublication(revisionID: first.id) == first)
        #expect(try count(db, "finalPublication", fixture.recording.id) == 2)
        #expect(try count(db, "transcript", fixture.recording.id) == 1)
        try await fixture.store.close()
    }

    /// Undo restores assignment heads only, so pruned revisions do not affect it.
    @Test func undoNamingAfterApplyNamesRestoresTheEarlierNames() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let (fixture, first) = try await published(folder)
        let meetingID = fixture.recording.meetingID
        let identity = try #require(first.speakers.first)
        let before = try await fixture.store.namingHeads(meetingID: meetingID)
        _ = try await fixture.store.confirmSpeakerName(meetingID: meetingID, speakerID: identity.id, name: "Alex")
        _ = try await fixture.store.applyNames(meetingID: meetingID)
        let generation = try await fixture.store.meeting(meetingID).generation
        let undone = try await fixture.store.undoNaming(before, generation: generation)
        #expect(!undone.assignments.contains { $0.name == "Alex" })
        try await fixture.store.close()
    }

    @Test func anInterruptedNewerJobKeepsItsCheckpointUntilItPublishes() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let (fixture, first) = try await published(folder)
        let db = try publicationDB(fixture.library)
        let retried = try await nextFinalJob(fixture)
        _ = try await stageFinal(fixture, job: retried)
        try await fixture.store.updateJob(retried.id, stage: .interrupted)
        let cancelled = try await nextFinalJob(fixture)
        try await fixture.store.updateJob(cancelled.id, stage: .cancelled)
        try await fixture.store.pruneLibrary()
        #expect(try await fixture.store.finalCheckpoint(jobID: first.job.id) != nil)
        #expect(try await fixture.store.finalCheckpoint(jobID: retried.id) != nil)
        _ = try await fixture.store.retryJob(retried.id)
        let probe = FinalProbe(); await probe.configure(microphoneText: "Sure, I will send it tomorow")
        let result = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
            .runAndPublish(jobID: retried.id)
        #expect(result.job.id == retried.id)
        #expect(try await fixture.store.finalCheckpoint(jobID: first.job.id) == nil)
        #expect(try count(db, "finalCheckpoint", fixture.recording.id) == 1)
        #expect(try count(db, "transcript", fixture.recording.id) == 1)
        try await fixture.store.close()
    }

    @Test func aFailedApplyNamesDeletesItsCopy() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let (fixture, first) = try await published(folder)
        let db = try publicationDB(fixture.library)
        try db.execute("CREATE TRIGGER fail_publish BEFORE INSERT ON records WHEN NEW.kind='finalPublication' BEGIN SELECT RAISE(ABORT, 'injected'); END")
        await #expect(throws: (any Error).self) { try await fixture.store.applyNames(meetingID: fixture.recording.meetingID) }
        try db.execute("DROP TRIGGER fail_publish")
        #expect(try count(db, "finalCheckpoint", fixture.recording.id) == 1)
        #expect(try await fixture.store.finalCheckpoint(jobID: first.job.id) != nil)
        #expect(try await fixture.store.namesApplicableRecordings(meetingID: fixture.recording.meetingID) == [fixture.recording.id])
        try await fixture.store.close()
    }

    @Test func aReadyCheckpointHasNoSystemLevelsAndStillPublishesFromValidating() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, quietMicrophone: true)
        let staged = try await stageFinal(fixture)
        #expect(staged.readyForPublication && staged.systemLevels == nil)
        _ = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        #expect(try await fixture.store.job(fixture.job.id).stage == .completed)
        try await fixture.store.close()
    }

    /// Group 2: a library written before this change is pruned when opened,
    /// and looks the same afterwards.
    @Test func openingPrunesAnOlderLibraryWithoutChangingWhatItShows() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let (fixture, first) = try await published(folder)
        let meetingID = fixture.recording.meetingID, recording = fixture.recording.id
        let db = try publicationDB(fixture.library)
        // What an older build left: copied checkpoints, earlier revisions, an orphaned draft.
        let checkpoint = try #require(try await fixture.store.finalCheckpoint(jobID: first.job.id))
        let revision = try #require(try await fixture.store.transcriptRevision(first.id))
        for _ in 0..<3 {
            let old = try await nextFinalJob(fixture)
            // Superseded runs of an older build; a failed later job would still be retryable and kept.
            try await fixture.store.updateJob(old.id, stage: .cancelled)
            try db.execute("INSERT INTO records(kind,id,meeting_id,scope,payload) VALUES ('finalCheckpoint',?,?,?,?)",
                [.text(old.id.uuidString), .text(meetingID.uuidString), .text(recording.uuidString), .blob(DomainCodec.encode(checkpoint))])
            let copy = TranscriptRevision(recordingID: recording, sourceGeneration: revision.sourceGeneration, kind: .final,
                segments: revision.segments, modelRevisions: revision.modelRevisions)
            try db.execute("INSERT INTO records(kind,id,meeting_id,scope,payload) VALUES ('transcript',?,?,?,?)",
                [.text(copy.id.uuidString), .text(meetingID.uuidString), .text(recording.uuidString), .blob(DomainCodec.encode(copy))])
        }
        let draft = LiveDraft(meetingID: meetingID, recordingID: recording, utterances: [], complete: true)
        try db.execute("INSERT INTO records(kind,id,meeting_id,scope,payload) VALUES ('liveDraft',?,?,?,?)",
            [.text(UUID().uuidString), .text(meetingID.uuidString), .text(recording.uuidString), .blob(DomainCodec.encode(draft))])
        let shown = try await fixture.store.meetingTranscript(meetingID: meetingID)
        #expect(try count(db, "finalCheckpoint", recording) == 4)
        try await fixture.store.close()

        let reopened = try await SessionStore.open(fixture.library)
        #expect(try count(db, "finalCheckpoint", recording) == 1)
        #expect(try count(db, "transcript", recording) == 1)
        #expect(try db.integer("SELECT count(*) FROM records WHERE kind='liveDraft'") == 0)
        #expect(try await reopened.meetingTranscript(meetingID: meetingID) == shown)
        #expect(try await reopened.namesApplicableRecordings(meetingID: meetingID) == [recording])
        // Opening again finds nothing more to prune.
        #expect(try await reopened.compactDatabase().pruned.isEmpty)
        try await reopened.close()
    }

    private func freedPages(_ fixture: FinalFixture, megabytes: Int) throws {
        let db = try publicationDB(fixture.library)
        let blob = Data(repeating: 7, count: 1 << 20)
        for _ in 0..<megabytes {
            try db.execute("INSERT INTO records(kind,id,meeting_id,scope,payload) VALUES ('junk',?,?,'',?)",
                [.text(UUID().uuidString), .text(fixture.recording.meetingID.uuidString), .blob(blob)])
        }
        try db.execute("DELETE FROM records WHERE kind='junk'")
        _ = try db.rows("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func fileSize(_ fixture: FinalFixture) throws -> Int64 {
        let url = fixture.library.directory.appendingPathComponent("Library.sqlite3")
        return Int64(try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
    }

    @Test func vacuumRunsOnlyWhenTheFreedSpaceIsWorthIt() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let (fixture, _) = try await published(folder)
        try freedPages(fixture, megabytes: 4)
        let roomy = VacuumPolicy(minimumFreeBytes: 1 << 20, minimumFreeRatio: 0.25, availableBytes: { _ in Int64.max })
        // Below the size threshold: nothing happens.
        var skipped = roomy; skipped.minimumFreeBytes = 64 << 20
        #expect(await fixture.store.compactDatabase(policy: skipped).vacuumed == false)
        // Too little disk space: nothing happens.
        var full = roomy; full.availableBytes = { _ in 1024 }
        #expect(await fixture.store.compactDatabase(policy: full).vacuumed == false)
        let before = try fileSize(fixture)
        let result = await fixture.store.compactDatabase(policy: roomy)
        #expect(result.vacuumed && result.bytesAfter < result.bytesBefore)
        #expect(try fileSize(fixture) < before)
        #expect(try await fixture.store.transcript(meetingID: fixture.recording.meetingID, recordingID: fixture.recording.id) != nil)
        try await fixture.store.close()
    }

    @Test func aFailedVacuumStillOpensTheLibrary() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let (fixture, _) = try await published(folder)
        try freedPages(fixture, megabytes: 4)
        let roomy = VacuumPolicy(minimumFreeBytes: 1 << 20, minimumFreeRatio: 0.25, availableBytes: { _ in Int64.max })
        var failing = roomy
        failing.willVacuum = { throw StoreError.database("disk full") }
        let result = await fixture.store.compactDatabase(policy: failing)
        #expect(!result.vacuumed && result.failure != nil)
        #expect(try await fixture.store.transcript(meetingID: fixture.recording.meetingID, recordingID: fixture.recording.id) != nil)
        // A later attempt succeeds.
        let retried = await fixture.store.compactDatabase(policy: roomy)
        #expect(retried.vacuumed, "\(retried)")
        try await fixture.store.close()
    }
}
