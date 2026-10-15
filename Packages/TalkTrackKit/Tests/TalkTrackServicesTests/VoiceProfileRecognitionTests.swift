import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

private enum RecognitionFixtureError: Error { case injected }

/// Constants here test mechanics only; they are never shipped as calibration.
func recognitionTestCalibration(similarity: Double = 0.95, margin: Double = 0.1) throws -> VoiceRecognitionCalibration {
    let (segmentation, embedding) = try clusteringModels()
    return VoiceRecognitionCalibration(version: "synthetic-mechanics-only-v1", reportSHA256: String(repeating: "a", count: 64),
        matcherVersion: VoiceProfileMatcher.version, segmentation: segmentation, embedding: embedding,
        preprocessingVersion: VoiceEnrollmentPolicy.preprocessing, enrollmentPolicyVersion: VoiceEnrollmentPolicy.version,
        minimumSimilarity: similarity, minimumMargin: margin)
}

actor RecognitionInference: SystemSpeakerInference {
    var vector = clusterVector(0)
    var switchAfter: Int?
    var embeddings = 0, activities = 0
    var held = false, started = false, mixed = false, fail = false
    func setVector(_ value: [Float]) { vector = value }
    func setSwitch(_ value: Int) { switchAfter = value }
    func hold() { held = true }
    func release() { held = false }
    func setMixed() { mixed = true }
    func setFailure() { fail = true }
    func speakerActivity(_ model: ModelSnapshot, samples: [Float]) async throws -> [SpeakerWindowActivity] {
        activities += 1; started = true
        while held { try await Task.sleep(for: .milliseconds(5)) }
        if fail { throw RecognitionFixtureError.injected }
        let interval = try clusterRange(0, Double(samples.count) / 16_000)
        return [SpeakerWindowActivity(slot: 1, relative: interval)] + (mixed ? [SpeakerWindowActivity(slot: 2, relative: interval)] : [])
    }
    func speakerEmbedding(_ model: ModelSnapshot, samples: [Float]) async throws -> SpeakerWindowEmbedding {
        embeddings += 1
        return SpeakerWindowEmbedding(values: switchAfter.map { embeddings > $0 ? clusterVector(1) : vector } ?? vector, model: model)
    }
}

func waitForRecognition(_ model: RecognitionInference) async throws {
    for _ in 0..<1000 {
        if await model.started { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Recognition did not reach the model boundary")
    throw RecognitionFixtureError.injected
}

private func testSamples(_ vector: [Float]) throws -> [VoiceProfileSample] {
    let recording = UUID(), revision = UUID(), day = UUID()
    return try [clusterRange(0, 6), clusterRange(6, 12)].map {
        VoiceProfileSample(recordingID: recording, transcriptRevisionID: revision, dayID: day, interval: $0, vector: vector)
    }
}

private func testProfile(_ vector: [Float], name: String = "Alex", preprocessing: String = VoiceEnrollmentPolicy.preprocessing) throws -> VoiceRecognitionProfile {
    let id = UUID(), revisionID = UUID(), (segmentation, embedding) = try clusteringModels()
    return VoiceRecognitionProfile(profile: VoiceProfile(id: id, name: name, revisionID: revisionID, updatedAt: Date()),
        revision: VoiceProfileRevision(id: revisionID, profileID: id, previousRevisionID: nil, createdAt: Date(),
            libraryID: UUID(), meetingID: UUID(), daySpeakerID: UUID(), assignmentID: UUID(), segmentation: segmentation,
            embedding: embedding, preprocessingVersion: preprocessing, enrollmentPolicyVersion: VoiceEnrollmentPolicy.version,
            calibrationVersion: nil, samples: try testSamples(vector)))
}

private func testEvidence(_ vector: [Float]) throws -> VoiceProfileEvidence {
    let (segmentation, embedding) = try clusteringModels()
    return VoiceProfileEvidence(segmentation: segmentation, embedding: embedding, samples: try testSamples(vector))
}

func remember(_ f: EnrollmentFixture, profiles: VoiceProfileStore, vector: [Float] = clusterVector(0), name: String = "Alex") async throws -> VoiceProfile {
    let model = RecognitionInference(); await model.setVector(vector)
    return try await VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: model).enroll(f.confirm(name).confirmation, choice: .newProfile)
}

private func replaceRecognitionTranscript(_ f: EnrollmentFixture, segments: [TranscriptSegment]? = nil) async throws -> EnrollmentFixture {
    let revision = TranscriptRevision(recordingID: f.recording.id, sourceGeneration: f.recording.generation, kind: .final,
        segments: segments ?? f.revision.segments, modelRevisions: f.revision.modelRevisions)
    let job = try await f.store.enqueue(kind: .finalTranscription, meetingID: f.meeting.id, recordingID: f.recording.id,
        settings: ProcessingSettings(), models: revision.modelRevisions)
    try await f.store.publishTranscript(revision, jobID: job.id)
    return EnrollmentFixture(library: f.library, store: f.store, meeting: f.meeting, recording: f.recording, revision: revision, speaker: f.speaker, db: f.db)
}

private func coactiveRecognitionFixture(_ root: URL) async throws -> (EnrollmentFixture, DaySpeaker) {
    let f = try await enrollmentFixture(root, seconds: 32)
    let other = DaySpeaker(meetingID: f.meeting.id, dayID: f.speaker.dayID, number: 2)
    try f.db.execute("INSERT INTO records VALUES ('daySpeaker',?,?,?,?)", [.text(other.id.uuidString), .text(other.meetingID.uuidString), .text(other.dayID.uuidString), .blob(DomainCodec.encode(other))])
    let a = TranscriptSegment(recordingID: f.recording.id, dayID: f.speaker.dayID, track: .system,
        interval: try clusterRange(0, 18), wallClockStart: f.recording.startedAt, speaker: .system(daySpeakerID: f.speaker.id), originalText: "A")
    let b = TranscriptSegment(recordingID: f.recording.id, dayID: other.dayID, track: .system,
        interval: try clusterRange(14, 32), wallClockStart: f.recording.startedAt, speaker: .system(daySpeakerID: other.id), originalText: "B")
    return (try await replaceRecognitionTranscript(f, segments: [a, b]), other)
}

@Suite struct VoiceProfileRecognitionTests {
    @Test func similarityMarginAndTiesRequireIndependentEvidence() throws {
        let evidence = try testEvidence(clusterVector(0)), alex = try testProfile(clusterVector(0))
        let calibration = try recognitionTestCalibration()
        let certain = try VoiceProfileMatcher.evaluate(evidence, profiles: [alex, testProfile(clusterVector(1))], calibration: calibration)
        #expect(certain.disposition == .matched && certain.winner == alex && certain.similarity == 1 && certain.margin == 1)
        let tie = try VoiceProfileMatcher.evaluate(evidence, profiles: [alex, testProfile(clusterVector(0))], calibration: calibration)
        #expect(tie.disposition == .ambiguous && tie.winner == nil && tie.margin == 0)
        var close = clusterVector(0); close[0] = 0.999; close[1] = sqrt(1 - close[0] * close[0])
        #expect(try VoiceProfileMatcher.evaluate(evidence, profiles: [alex, testProfile(close)], calibration: calibration).disposition == .ambiguous)
        #expect(try VoiceProfileMatcher.evaluate(testEvidence(clusterVector(2)), profiles: [alex], calibration: calibration).disposition == .belowThreshold)
        // Equality is admitted, and the immediately larger required margin is refused.
        #expect(try VoiceProfileMatcher.evaluate(evidence, profiles: [alex, testProfile(clusterVector(1))], calibration: recognitionTestCalibration(similarity: 1, margin: 1)).disposition == .matched)
        #expect(try VoiceProfileMatcher.evaluate(evidence, profiles: [alex, testProfile(clusterVector(1))], calibration: recognitionTestCalibration(margin: 1.000001)).disposition == .ambiguous)
    }

    @Test func incompatibleAndCorruptCompetitorsCannotInflateConfidence() throws {
        let evidence = try testEvidence(clusterVector(0)), calibration = try recognitionTestCalibration()
        #expect(try VoiceProfileMatcher.evaluate(evidence, profiles: [testProfile(clusterVector(0), preprocessing: "different")], calibration: calibration).disposition == .incompatibleProfiles)
        let corrupt = try testProfile([Float](repeating: 0, count: 256))
        #expect(try VoiceProfileMatcher.evaluate(evidence, profiles: [testProfile(clusterVector(0)), corrupt], calibration: calibration).disposition == .incompatibleProfiles)
        let wrong = VoiceProfileEvidence(segmentation: evidence.embedding, embedding: evidence.segmentation, samples: evidence.samples)
        #expect(try VoiceProfileMatcher.evaluate(wrong, profiles: [testProfile(clusterVector(0))], calibration: calibration).disposition == .incompatibleEvidence)
        let invalid = VoiceProfileEvidence(segmentation: evidence.segmentation, embedding: evidence.embedding, samples: try testSamples([Float.nan]))
        #expect(try VoiceProfileMatcher.evaluate(invalid, profiles: [testProfile(clusterVector(0))], calibration: calibration).disposition == .incompatibleEvidence)
    }

    @Test func durationDuplicatesAndOneGoodVectorCannotManufactureIdentity() throws {
        let evidence = try testEvidence(clusterVector(0)), profile = try testProfile(clusterVector(0)), calibration = try recognitionTestCalibration()
        let duplicate = VoiceProfileEvidence(segmentation: evidence.segmentation, embedding: evidence.embedding, samples: [evidence.samples[0], evidence.samples[0]])
        #expect(try VoiceProfileMatcher.evaluate(duplicate, profiles: [profile], calibration: calibration).disposition == .insufficientSpeech)
        var divergent = evidence.samples
        let s = divergent[1]
        divergent[1] = VoiceProfileSample(recordingID: s.recordingID, transcriptRevisionID: s.transcriptRevisionID, dayID: s.dayID, interval: s.interval, vector: clusterVector(1))
        #expect(try VoiceProfileMatcher.evaluate(VoiceProfileEvidence(segmentation: evidence.segmentation, embedding: evidence.embedding, samples: divergent), profiles: [profile], calibration: calibration).disposition == .belowThreshold)
        #expect(throws: VoiceRecognitionError.invalidCalibration) {
            try VoiceProfileMatcher.evaluate(evidence, profiles: [profile], calibration: recognitionTestCalibration(similarity: .nan))
        }
    }

    @Test func uncalibratedAndDisabledRecognitionLoadNothingAndCreateNoRegistry() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let q = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url), model = RecognitionInference()
        let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: model)
        #expect(try await service.recognize(meetingID: q.meeting.id).decisions.map(\.disposition) == [.uncalibrated])
        #expect(try await service.recognize(meetingID: q.meeting.id, enabled: false).decisions.map(\.disposition) == [.disabled])
        #expect(await model.activities == 0)
        #expect(await model.embeddings == 0)
        #expect(!FileManager.default.fileExists(atPath: profiles.databaseURL.path))
        try await q.store.close()
    }

    @Test func laterMeetingMatchesWithImmutableProofAndNeverRetrains() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let profile = try await remember(f, profiles: profiles)
        let original = try await profiles.revision(profile.revisionID)
        let q = try await enrollmentFixture(root.url, at: Date(timeIntervalSince1970: 1_792_400_400))
        let model = RecognitionInference(), service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: model, calibration: try recognitionTestCalibration())
        let result = try await service.recognize(meetingID: q.meeting.id)
        let assignment = try #require(result.assignments.first), proof = try #require(try await q.store.automaticVoiceMatch(assignmentID: assignment.id))
        #expect(result.decisions.map(\.disposition) == [.matched] && assignment.name == "Alex")
        #expect(assignment.daySpeakerID == q.speaker.id && assignment.dayID != f.speaker.dayID)
        #expect(proof.assignment == assignment && proof.profile == profile && proof.calibration.version == "synthetic-mechanics-only-v1")
        #expect(proof.samples.count >= 2 && proof.samples.allSatisfy { $0.embeddingSHA256.count == 64 && $0.transcriptRevisionID == q.revision.id })
        #expect(proof.profileRevisionSHA256 == (try VoiceProfileMatcher.fingerprint(#require(original))))
        #expect(try await profiles.profiles() == [profile])
        #expect(try await profiles.revision(profile.revisionID) == original)
        #expect(try await q.store.transcript(meetingID: q.meeting.id, recordingID: q.recording.id) == q.revision)
        let calls = await model.embeddings
        #expect(try await service.recognize(meetingID: q.meeting.id).decisions.map(\.disposition) == [.existingAutomaticName])
        #expect(await model.embeddings == calls)
        try await q.store.close()
        let reopened = try await SessionStore.open(q.library)
        #expect(try await reopened.automaticVoiceMatch(assignmentID: assignment.id) == proof)
        #expect(try await reopened.speakerAssignments(meetingID: q.meeting.id) == [assignment])
        try await reopened.close(); try await f.store.close()
    }

    @Test @MainActor func automaticNamesAreExplicitAndManualCorrectionDoesNotTrain() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let profile = try await remember(f, profiles: profiles), q = try await enrollmentFixture(root.url)
        let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: RecognitionInference(), calibration: try recognitionTestCalibration())
        let automatic = try #require(try await service.recognize(meetingID: q.meeting.id).assignments.first)
        let p = MeetingTranscriptPresentation(store: q.store, meetingID: q.meeting.id,
            enrollment: VoiceProfileEnrollment(store: q.store, profiles: profiles, inference: RecognitionInference()))
        await p.beginRename(recordingID: q.recording.id, segmentID: q.revision.segments[0].id)
        #expect(p.renameTarget?.assignmentOrigin == automatic.origin && p.rememberVoice && p.draftName == "Alex")
        // This checks that a correction overrides recognition; remembering is off here.
        p.rememberVoice = false
        p.draftName = "Алексей confirmed"; await p.saveRename()
        #expect(p.snapshot?.assignments.first?.origin == .manual && p.snapshot?.assignments.first?.name == "Алексей confirmed")
        #expect(try await service.recognize(meetingID: q.meeting.id).decisions.map(\.disposition) == [.manualName])
        #expect(try await profiles.profiles() == [profile])
        #expect(try await q.store.speakerAssignment(automatic.id) == automatic)
        #expect(try await q.store.automaticVoiceMatch(assignmentID: automatic.id)?.assignment == automatic)
        let forbidden = VoiceEnrollmentConfirmation(library: q.library, speakerID: q.speaker.id, assignment: automatic, recordings: [q.recording], revisions: [q.revision])
        await #expect(throws: VoiceEnrollmentError.changed) { try await q.store.validateVoiceConfirmation(forbidden) }
        await #expect(throws: VoiceEnrollmentError.insufficientSpeech) {
            try await profiles.enroll(forbidden, choice: .newProfile, segmentation: recognitionTestCalibration().segmentation,
                embedding: recognitionTestCalibration().embedding, samples: testSamples(clusterVector(0)))
        }
        try await q.store.close(); try await f.store.close()
    }

    @Test func manualSaveDuringInferenceAlwaysWins() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        _ = try await remember(f, profiles: profiles)
        let q = try await enrollmentFixture(root.url), model = RecognitionInference(); await model.hold()
        let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: model, calibration: try recognitionTestCalibration())
        let task = Task { [service, meetingID = q.meeting.id] in try await service.recognize(meetingID: meetingID) }
        try await waitForRecognition(model)
        let manual = try await q.confirm("Manual winner").confirmation.assignment
        await model.release()
        let result = try await task.value
        #expect(result.assignments.isEmpty && result.decisions.map(\.disposition) == [.manualName])
        #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id) == [manual])
        #expect(try q.db.integer("SELECT count(*) FROM records WHERE kind='automaticVoiceMatch'") == 0)
        try await q.store.close(); try await f.store.close()
    }

    @Test(arguments: [false, true]) func transcriptReplacementOrCancellationRefusesStaleName(_ cancel: Bool) async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        _ = try await remember(f, profiles: profiles)
        let q = try await enrollmentFixture(root.url), model = RecognitionInference(); await model.hold()
        let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: model, calibration: try recognitionTestCalibration())
        let task = Task { [service, meetingID = q.meeting.id] in try await service.recognize(meetingID: meetingID) }
        try await waitForRecognition(model)
        if cancel { try await q.store.cancelJobs(meetingID: q.meeting.id) }
        else { _ = try await replaceRecognitionTranscript(q) }
        await model.release()
        await #expect(throws: VoiceRecognitionError.changed) { try await task.value }
        #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id).isEmpty)
        try await q.store.close(); try await f.store.close()
    }

    @Test func changedProfileHeadIsRefusedAndRegistryCommitLeaseBlocksTraining() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let old = try await remember(f, profiles: profiles), q = try await enrollmentFixture(root.url), model = RecognitionInference(); await model.hold()
        let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: model, calibration: try recognitionTestCalibration())
        let task = Task { [service, meetingID = q.meeting.id] in try await service.recognize(meetingID: meetingID) }
        try await waitForRecognition(model)
        let confirmation = try await f.confirm().confirmation
        let newer = try await VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: RecognitionInference())
            .enroll(confirmation, choice: .existing(profileID: old.id, revisionID: old.revisionID))
        await model.release()
        await #expect(throws: VoiceRecognitionError.changed) { try await task.value }
        #expect(try await profiles.profiles() == [newer])
        let registry = try await profiles.recognitionProfiles()
        let nextConfirmation = try await f.confirm().confirmation
        _ = try await profiles.withRecognitionSnapshot(registry) {
            await #expect(throws: VoiceRecognitionError.busy) {
                try await profiles.enroll(nextConfirmation, choice: .newProfile, segmentation: recognitionTestCalibration().segmentation,
                    embedding: recognitionTestCalibration().embedding, samples: testSamples(clusterVector(0)))
            }
        }
        #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id).isEmpty)
        try await q.store.close(); try await f.store.close()
    }

    @Test(arguments: [false, true]) func distinctCoactiveVoicesCannotClaimOneProfileButMayMatchDifferentProfiles(_ different: Bool) async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        _ = try await remember(f, profiles: profiles)
        // Another person comes from another day speaker: re-confirming the same
        // speaker under a new name supersedes the earlier confirmation.
        let g = try await enrollmentFixture(root.url)
        if different { _ = try await remember(g, profiles: profiles, vector: clusterVector(1), name: "Blake") }
        let (q, other) = try await coactiveRecognitionFixture(root.url), model = RecognitionInference()
        if different {
            let failing = RecognitionInference()
            // Each coactive speaker yields exactly two clean embeddings, so the
            // first-processed speaker (UUID order) gets Alex and the second Blake.
            await failing.setSwitch(2)
            try q.db.execute("CREATE TRIGGER fail_second_match BEFORE INSERT ON records WHEN NEW.kind='automaticVoiceMatch' AND (SELECT count(*) FROM records WHERE kind='automaticVoiceMatch')>0 BEGIN SELECT RAISE(ABORT,'injected second match'); END")
            let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: failing, calibration: try recognitionTestCalibration())
            await #expect(throws: (any Error).self) { try await service.recognize(meetingID: q.meeting.id) }
            #expect(try q.db.integer("SELECT count(*) FROM records WHERE kind='automaticVoiceMatch'") == 0)
            #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id).isEmpty)
            try q.db.execute("DROP TRIGGER fail_second_match")
            await model.setSwitch(2)
        }
        let result = try await VoiceProfileRecognition(store: q.store, profiles: profiles, inference: model, calibration: recognitionTestCalibration()).recognize(meetingID: q.meeting.id)
        #expect(result.decisions.allSatisfy { $0.disposition == (different ? .matched : .simultaneousConflict) })
        #expect(result.assignments.count == (different ? 2 : 0))
        #expect(Set(result.assignments.compactMap(\.name)).count == (different ? 2 : 0))
        #expect(try await q.store.transcript(meetingID: q.meeting.id, recordingID: q.recording.id) == q.revision)
        try await q.store.close(); try await g.store.close(); try await f.store.close()
    }

    @Test(arguments: [false, true]) func coactiveManualAndExistingAutomaticIdentitiesAreProtected(_ automatic: Bool) async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let profile = try await remember(f, profiles: profiles), (q, other) = try await coactiveRecognitionFixture(root.url)
        let existing: SpeakerAssignment
        if automatic {
            existing = SpeakerAssignment(meetingID: q.meeting.id, dayID: q.speaker.dayID, daySpeakerID: q.speaker.id,
                name: profile.name, origin: .automatic(profileID: profile.id, profileRevision: profile.revisionID,
                    similarity: 1, margin: 2, calibrationVersion: "historical-fixture"), evidence: [])
            try q.db.execute("INSERT INTO records VALUES ('assignment',?,?,?,?)", [.text(existing.id.uuidString), .text(q.meeting.id.uuidString), .text(q.speaker.id.uuidString), .blob(DomainCodec.encode(existing))])
            try q.db.execute("INSERT INTO heads VALUES (?,'assignment',?,?)", [.text(q.meeting.id.uuidString), .text(q.speaker.id.uuidString), .text(existing.id.uuidString)])
        } else { existing = try await q.confirm("Confirmed person").confirmation.assignment }
        let result = try await VoiceProfileRecognition(store: q.store, profiles: profiles, inference: RecognitionInference(), calibration: recognitionTestCalibration()).recognize(meetingID: q.meeting.id)
        #expect(result.assignments.isEmpty)
        #expect(result.decisions.first { $0.speakerID == other.id }?.disposition == .simultaneousConflict)
        #expect(result.decisions.first { $0.speakerID == q.speaker.id }?.disposition == (automatic ? .existingAutomaticName : .manualName))
        #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id) == [existing])
        #expect(try await profiles.profiles() == [profile])
        try await q.store.close(); try await f.store.close()
    }

    @Test(arguments: ["short", "silent", "mixed", "invalid", "error"]) func badOrInsufficientAudioNeverGetsAnAutomaticName(_ mode: String) async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let profile = try await remember(f, profiles: profiles)
        let q = try await enrollmentFixture(root.url, seconds: mode == "short" ? 3 : 24, amplitude: mode == "silent" ? 0 : 0.1)
        let model = RecognitionInference()
        if mode == "mixed" { await model.setMixed() }
        if mode == "invalid" { await model.setVector([Float](repeating: 0, count: 256)) }
        if mode == "error" { await model.setFailure() }
        let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: model, calibration: try recognitionTestCalibration())
        if mode == "error" { await #expect(throws: RecognitionFixtureError.injected) { try await service.recognize(meetingID: q.meeting.id) } }
        else {
            let result = try await service.recognize(meetingID: q.meeting.id)
            #expect(result.assignments.isEmpty && result.decisions.map(\.disposition) == [mode == "invalid" ? .incompatibleEvidence : .insufficientSpeech])
        }
        #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id).isEmpty)
        #expect(try await profiles.profiles() == [profile])
        #expect(try await q.store.transcript(meetingID: q.meeting.id, recordingID: q.recording.id) == q.revision)
        try await q.store.close(); try await f.store.close()
    }

    @Test func cancellationAndBusyLeaveNoNameAndAllowRetry() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        _ = try await remember(f, profiles: profiles)
        let q = try await enrollmentFixture(root.url), model = RecognitionInference(); await model.hold()
        let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: model, calibration: try recognitionTestCalibration())
        let task = Task { [service, meetingID = q.meeting.id] in try await service.recognize(meetingID: meetingID) }
        try await waitForRecognition(model)
        await #expect(throws: VoiceRecognitionError.busy) { try await service.recognize(meetingID: q.meeting.id) }
        task.cancel(); await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id).isEmpty)
        await model.release()
        #expect(try await service.recognize(meetingID: q.meeting.id).assignments.count == 1)
        try await q.store.close(); try await f.store.close()
    }

    @Test func assignmentProofAndHeadRollBackTogetherThenRetry() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        _ = try await remember(f, profiles: profiles)
        let q = try await enrollmentFixture(root.url)
        let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: RecognitionInference(), calibration: try recognitionTestCalibration())
        try q.db.execute("CREATE TRIGGER fail_match BEFORE INSERT ON heads WHEN NEW.kind='assignment' BEGIN SELECT RAISE(ABORT,'injected'); END")
        await #expect(throws: (any Error).self) { try await service.recognize(meetingID: q.meeting.id) }
        #expect(try q.db.integer("SELECT count(*) FROM records WHERE kind='automaticVoiceMatch'") == 0)
        #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id).isEmpty)
        try q.db.execute("DROP TRIGGER fail_match")
        #expect(try await service.recognize(meetingID: q.meeting.id).assignments.count == 1)
        try await q.store.close(); try await f.store.close()
    }

    @Test func incompatibleFinalModelsAndMicrophoneSpeechNeverEnterMatching() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        _ = try await remember(f, profiles: profiles)
        let original = try await enrollmentFixture(root.url), model = RecognitionInference()
        let mic = TranscriptSegment(recordingID: original.recording.id, dayID: original.speaker.dayID, track: .microphone,
            interval: try clusterRange(0, 24), wallClockStart: original.recording.startedAt, speaker: .system(daySpeakerID: original.speaker.id), originalText: "You")
        let q = try await replaceRecognitionTranscript(original, segments: original.revision.segments + [mic])
        let calibration = try recognitionTestCalibration()
        let incompatible = TranscriptRevision(recordingID: q.recording.id, sourceGeneration: q.recording.generation,
            kind: .final, segments: q.revision.segments, modelRevisions: [calibration.segmentation])
        let job = try await q.store.enqueue(kind: .finalTranscription, meetingID: q.meeting.id, recordingID: q.recording.id,
            settings: ProcessingSettings(), models: incompatible.modelRevisions)
        try await q.store.publishTranscript(incompatible, jobID: job.id)
        let result = try await VoiceProfileRecognition(store: q.store, profiles: profiles, inference: model, calibration: calibration).recognize(meetingID: q.meeting.id)
        #expect(result.assignments.isEmpty && result.decisions.map(\.disposition) == [.incompatibleEvidence])
        #expect(await model.activities == 0)
        #expect(try await q.store.meetingTranscript(meetingID: q.meeting.id).items.contains { item in
            if case .speech(let block) = item { return block.speaker == .microphone && block.speakerLabel == "You" }; return false
        })
        try await q.store.close(); try await f.store.close()
    }

    @Test func competingProfilesRetainUnknownAndLeaveRegistryBytesUnchanged() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        _ = try await remember(f, profiles: profiles, name: "Alex")
        let g = try await enrollmentFixture(root.url)
        _ = try await remember(g, profiles: profiles, name: "Blake")
        let before = try Data(contentsOf: profiles.databaseURL)
        let q = try await enrollmentFixture(root.url)
        let result = try await VoiceProfileRecognition(store: q.store, profiles: profiles, inference: RecognitionInference(), calibration: recognitionTestCalibration()).recognize(meetingID: q.meeting.id)
        #expect(result.assignments.isEmpty && result.decisions.map(\.disposition) == [.ambiguous])
        #expect(try Data(contentsOf: profiles.databaseURL) == before)
        #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id).isEmpty)
        try await q.store.close(); try await g.store.close(); try await f.store.close()
    }

    @Test func absentRegistryAndIncompatibleProfilesLoadNoModels() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let q = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url), model = RecognitionInference()
        let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: model, calibration: try recognitionTestCalibration())
        #expect(try await service.recognize(meetingID: q.meeting.id).decisions.map(\.disposition) == [.noProfiles])
        #expect(!FileManager.default.fileExists(atPath: profiles.databaseURL.path))
        let profile = try await remember(q, profiles: profiles)
        let db = try SQLiteConnection(path: "/" + DirectoryHandle.physicalComponents(profiles.databaseURL).dropFirst().joined(separator: "/"))
        let revision = try #require(try await profiles.revision(profile.revisionID))
        let bad = VoiceProfileRevision(id: revision.id, profileID: revision.profileID, previousRevisionID: revision.previousRevisionID,
            createdAt: revision.createdAt, libraryID: revision.libraryID, meetingID: revision.meetingID, daySpeakerID: revision.daySpeakerID,
            assignmentID: revision.assignmentID, segmentation: revision.segmentation, embedding: revision.embedding,
            preprocessingVersion: "incompatible", enrollmentPolicyVersion: revision.enrollmentPolicyVersion, calibrationVersion: nil, samples: revision.samples)
        try db.execute("UPDATE revisions SET payload=? WHERE id=?", [.blob(DomainCodec.encode(bad)), .text(revision.id.uuidString)])
        #expect(try await service.recognize(meetingID: q.meeting.id).decisions.map(\.disposition) == [.incompatibleProfiles])
        #expect(await model.activities == 0)
        try await q.store.close()
    }

    @Test func proofHasNoReusableVectorsAndSurvivesProfileRemoval() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        _ = try await remember(f, profiles: profiles)
        let q = try await enrollmentFixture(root.url)
        let result = try await VoiceProfileRecognition(store: q.store, profiles: profiles, inference: RecognitionInference(), calibration: recognitionTestCalibration()).recognize(meetingID: q.meeting.id)
        let assignment = try #require(result.assignments.first), proof = try #require(try await q.store.automaticVoiceMatch(assignmentID: assignment.id))
        let encoded = String(decoding: try DomainCodec.encode(proof), as: UTF8.self)
        #expect(!encoded.contains("vector") && !encoded.contains("originalText") && !encoded.contains("correctedText"))
        // Simulate future Settings deletion; no production deletion API is
        // introduced before task 6.5. Historical session names are independent.
        let db = try SQLiteConnection(path: "/" + DirectoryHandle.physicalComponents(profiles.databaseURL).dropFirst().joined(separator: "/"))
        try db.transaction { try db.execute("DELETE FROM profiles"); try db.execute("DELETE FROM revisions") }
        #expect(try await profiles.profiles().isEmpty)
        #expect(try await q.store.automaticVoiceMatch(assignmentID: assignment.id) == proof)
        #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id) == [assignment])
        try await q.store.close(); try await f.store.close()
    }

    @Test func meetingDeletionDuringMatchingCannotResurrectNames() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let profile = try await remember(f, profiles: profiles), q = try await enrollmentFixture(root.url), model = RecognitionInference(); await model.hold()
        let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: model, calibration: try recognitionTestCalibration())
        let task = Task { [service, meetingID = q.meeting.id] in try await service.recognize(meetingID: meetingID) }
        try await waitForRecognition(model)
        try await q.store.deleteMeeting(q.meeting.id); await model.release()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try q.db.integer("SELECT count(*) FROM records WHERE kind='automaticVoiceMatch'") == 0)
        #expect(try await profiles.profiles() == [profile])
        try await q.store.close(); try await f.store.close()
    }

    @Test func exportNativeRecognitionFixture() async throws {
        let root = try TemporaryFolder(), export = ProcessInfo.processInfo.environment["TALKTRACK_VOICE_RECOGNITION_FIXTURE"]
        defer { if export == nil { root.remove() } }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url.appendingPathComponent("fixture-home"))
        _ = try await remember(f, profiles: profiles)
        let q = try await enrollmentFixture(root.url)
        let result = try await VoiceProfileRecognition(store: q.store, profiles: profiles, inference: RecognitionInference(), calibration: recognitionTestCalibration()).recognize(meetingID: q.meeting.id)
        #expect(result.assignments.count == 1)
        try await q.store.close(); try await f.store.close()
        if let export {
            struct Config: Encodable { let root: String; let meetingIDs: [UUID]; let syntheticVoiceEvidence: Bool }
            let url = URL(fileURLWithPath: export)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Config(root: root.url.path, meetingIDs: [q.meeting.id, f.meeting.id], syntheticVoiceEvidence: true)).write(to: url, options: .atomic)
        }
    }
}
