import Foundation
import Synchronization
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

private func profileDB(_ store: VoiceProfileStore) throws -> SQLiteConnection {
    try SQLiteConnection(path: "/" + DirectoryHandle.physicalComponents(store.databaseURL).dropFirst().joined(separator: "/"))
}

private func makeIncompatible(_ profile: VoiceProfile, store: VoiceProfileStore) async throws {
    let old = try #require(try await store.revision(profile.revisionID))
    let changed = VoiceProfileRevision(id: old.id, profileID: old.profileID, previousRevisionID: old.previousRevisionID,
        createdAt: old.createdAt, libraryID: old.libraryID, meetingID: old.meetingID, daySpeakerID: old.daySpeakerID,
        assignmentID: old.assignmentID, segmentation: old.segmentation, embedding: old.embedding,
        preprocessingVersion: "old-preprocessing", enrollmentPolicyVersion: old.enrollmentPolicyVersion,
        calibrationVersion: nil, samples: old.samples)
    try profileDB(store).execute("UPDATE revisions SET payload=? WHERE id=?", [.blob(DomainCodec.encode(changed)), .text(old.id.uuidString)])
}

@Suite struct SavedSpeakersTests {
    @Test func renameOnlyChangesFutureAssignmentsAndPreservesEvidence() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let first = try await remember(f, profiles: profiles), old = try await profiles.revision(first.revisionID)
        let q = try await enrollmentFixture(root.url)
        let automatic = try await VoiceProfileRecognition(store: q.store, profiles: profiles, inference: RecognitionInference(), calibration: recognitionTestCalibration()).recognize(meetingID: q.meeting.id)
        let assignment = try #require(automatic.assignments.first), proof = try await q.store.automaticVoiceMatch(assignmentID: assignment.id)
        let renamed = try await profiles.rename(first, name: "  Алексей future  ")
        #expect(renamed.id == first.id && renamed.revisionID == first.revisionID && renamed.name == "Алексей future")
        #expect(try await profiles.revision(first.revisionID) == old)
        #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id) == [assignment])
        #expect(try await q.store.automaticVoiceMatch(assignmentID: assignment.id) == proof)
        #expect(try await f.store.speakerAssignments(meetingID: f.meeting.id)[0].name == "Alex")
        let later = try await enrollmentFixture(root.url)
        let future = try await VoiceProfileRecognition(store: later.store, profiles: profiles, inference: RecognitionInference(), calibration: recognitionTestCalibration()).recognize(meetingID: later.meeting.id)
        #expect(future.assignments.first?.name == "Алексей future")
        #expect(try await VoiceProfileStore(home: root.url).profiles() == [renamed])
        try await later.store.close(); try await q.store.close(); try await f.store.close()
    }

    @Test func deletionRemovesAllVectorsButPreservesNamesProofAndReplayReceipts() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let enrollment = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let first = try await enrollment.enroll(f.confirm().confirmation, choice: .newProfile)
        let confirmation = try await f.confirm().confirmation
        let second = try await enrollment.enroll(confirmation, choice: .existing(profileID: first.id, revisionID: first.revisionID))
        let q = try await enrollmentFixture(root.url)
        let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: RecognitionInference(), calibration: try recognitionTestCalibration())
        let result = try await service.recognize(meetingID: q.meeting.id), assignment = try #require(result.assignments.first)
        let proof = try await q.store.automaticVoiceMatch(assignmentID: assignment.id)
        #expect(try Data(contentsOf: profiles.databaseURL).range(of: Data("\"vector\":[".utf8)) != nil)
        try await profiles.delete(second)
        #expect(try await profiles.profiles().isEmpty)
        #expect(try await profiles.revision(first.revisionID) == nil)
        #expect(try await profiles.revision(second.revisionID) == nil)
        #expect(try await q.store.automaticVoiceMatch(assignmentID: assignment.id) == proof)
        #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id) == [assignment])
        #expect(try await f.store.speakerAssignments(meetingID: f.meeting.id)[0].name == "Alex")
        #expect(try await service.recognize(meetingID: q.meeting.id).decisions.map(\.disposition) == [.noProfiles])
        let db = try profileDB(profiles)
        #expect(try db.integer("SELECT count(*) FROM revisions") == 0)
        #expect(try db.integer("SELECT count(*) FROM enrollment_receipts") == 2)
        #expect(try db.integer("PRAGMA user_version") == 2)
        #expect(try Data(contentsOf: profiles.databaseURL).range(of: Data("\"vector\":[".utf8)) == nil)
        for suffix in ["-journal", "-wal", "-shm"] { #expect(!FileManager.default.fileExists(atPath: profiles.databaseURL.path + suffix)) }
        await #expect(throws: VoiceEnrollmentError.changed) { try await enrollment.enroll(confirmation, choice: .newProfile) }
        #expect(try await VoiceProfileStore(home: root.url).profiles().isEmpty)
        try await q.store.close(); try await f.store.close()
    }

    @Test func staleInvalidAndMissingEditsDoNotChangeProfilesOrCreateStorage() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let profiles = VoiceProfileStore(home: root.url)
        let absent = VoiceProfile(id: UUID(), name: "Absent", revisionID: UUID(), updatedAt: Date())
        await #expect(throws: VoiceProfileSettingsError.changed) { try await profiles.delete(absent) }
        await #expect(throws: VoiceProfileSettingsError.changed) { try await profiles.rename(absent, name: "Renamed") }
        #expect(!FileManager.default.fileExists(atPath: profiles.databaseURL.path))
        let f = try await enrollmentFixture(root.url), first = try await remember(f, profiles: profiles)
        for name in ["", "\nBad", String(repeating: "x", count: 201)] {
            await #expect(throws: SpeakerRenameError.invalidName) { try await profiles.rename(first, name: name) }
        }
        let next = try await profiles.rename(first, name: "Current")
        await #expect(throws: VoiceProfileSettingsError.changed) { try await profiles.delete(first) }
        await #expect(throws: VoiceProfileSettingsError.changed) { try await profiles.rename(first, name: "Stale") }
        #expect(try await profiles.profiles() == [next])
        try await f.store.close()
    }

    @Test func deleteAndRenameFailuresRollBackAllRowsAndRetry() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let first = try await remember(f, profiles: profiles), old = try await profiles.revision(first.revisionID)
        let db = try profileDB(profiles)
        try db.execute("CREATE TRIGGER fail_delete BEFORE DELETE ON profiles BEGIN SELECT RAISE(ABORT,'injected delete'); END")
        await #expect(throws: (any Error).self) { try await profiles.delete(first) }
        #expect(try await profiles.profiles() == [first])
        #expect(try await profiles.revision(first.revisionID) == old)
        try db.execute("DROP TRIGGER fail_delete")
        try db.execute("CREATE TRIGGER fail_rename BEFORE UPDATE ON profiles BEGIN SELECT RAISE(ABORT,'injected rename'); END")
        await #expect(throws: (any Error).self) { try await profiles.rename(first, name: "Changed") }
        #expect(try await profiles.profiles() == [first])
        try db.execute("DROP TRIGGER fail_rename")
        try await profiles.delete(first)
        #expect(try db.integer("SELECT count(*) FROM revisions") == 0)
        try await f.store.close()
    }

    @Test func registryCommitLeaseBlocksMaintenanceAndStaleInferenceCannotPublish() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let first = try await remember(f, profiles: profiles), registry = try await profiles.recognitionProfiles()
        try await profiles.withRecognitionSnapshot(registry) {
            await #expect(throws: VoiceProfileSettingsError.busy) { try await profiles.delete(first) }
            await #expect(throws: VoiceProfileSettingsError.busy) { try await profiles.rename(first, name: "Busy") }
        }
        let q = try await enrollmentFixture(root.url), model = RecognitionInference(); await model.hold()
        let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: model, calibration: try recognitionTestCalibration())
        let task = Task { [service, id = q.meeting.id] in try await service.recognize(meetingID: id) }
        try await waitForRecognition(model)
        try await profiles.delete(first); await model.release()
        await #expect(throws: VoiceRecognitionError.changed) { try await task.value }
        #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id).isEmpty)
        try await q.store.close(); try await f.store.close()
    }

    @Test func disablingRecognitionDuringInferencePreventsNamesAndReenableRetries() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        _ = try await remember(f, profiles: profiles)
        let q = try await enrollmentFixture(root.url), model = RecognitionInference(), flag = Mutex(true)
        await model.hold()
        let service = VoiceProfileRecognition(store: q.store, profiles: profiles, inference: model,
            calibration: try recognitionTestCalibration(), recognitionEnabled: { flag.withLock { $0 } })
        let task = Task { [service, id = q.meeting.id] in try await service.recognize(meetingID: id) }
        try await waitForRecognition(model); flag.withLock { $0 = false }; await model.release()
        #expect(try await task.value.decisions.map(\.disposition) == [.disabled])
        #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id).isEmpty)
        let calls = await model.activities
        #expect(try await service.recognize(meetingID: q.meeting.id).decisions.map(\.disposition) == [.disabled])
        #expect(await model.activities == calls)
        flag.withLock { $0 = true }
        #expect(try await service.recognize(meetingID: q.meeting.id).assignments.count == 1)
        try await q.store.close(); try await f.store.close()
    }

    @Test @MainActor func preferencesPersistSeparatelyAndPresentationRetainsFailedDraft() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let suite = "talktrack-speakers-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(8192, forKey: ProcessingPreferences.contextKey)
        #expect(ProcessingPreferences.voiceRecognitionEnabled(in: defaults))
        let profiles = VoiceProfileStore(home: root.url), p = SavedSpeakersPresentation(store: profiles, defaults: defaults)
        await p.refresh(); #expect(p.voices.isEmpty && p.errorMessage == nil)
        p.recognitionEnabled = false
        #expect(!ProcessingPreferences.voiceRecognitionEnabled(in: try #require(UserDefaults(suiteName: suite))))
        #expect(defaults.integer(forKey: ProcessingPreferences.contextKey) == 8192)
        #expect(!FileManager.default.fileExists(atPath: profiles.databaseURL.path))
        let f = try await enrollmentFixture(root.url), first = try await remember(f, profiles: profiles)
        await p.refresh(); p.beginRename(first); p.draftName = "Draft survives"
        let renamed = try await profiles.rename(first, name: "Concurrent")
        await p.saveRename()
        #expect(p.editing == first && p.draftName == "Draft survives" && p.errorMessage != nil)
        p.cancelRename(); await p.refresh(); #expect(p.voices.map(\.profile) == [renamed])
        p.beginRename(renamed); p.draftName = "Saved"; await p.saveRename()
        #expect(p.editing == nil && p.voices.first?.profile.name == "Saved")
        let current = try #require(p.voices.first?.profile)
        await p.delete(current); #expect(p.voices.isEmpty)
        p.recognitionEnabled = true
        #expect(ProcessingPreferences.voiceRecognitionEnabled(in: defaults))
        try await f.store.close()
    }

    @Test @MainActor func incompatibleRecoveryNeedsExplicitFreshManualConfirmationAndPreservesHistory() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let first = try await remember(f, profiles: profiles)
        try await makeIncompatible(first, store: profiles)
        let old = try await profiles.revision(first.revisionID)
        #expect(try await profiles.savedVoices().first?.needsNewSpeech == true)
        let enrollment = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let confirmation = try await f.confirm().confirmation
        await #expect(throws: VoiceEnrollmentError.incompatibleModels) { try await enrollment.enroll(confirmation, choice: .existing(profileID: first.id, revisionID: first.revisionID)) }
        let p = MeetingTranscriptPresentation(store: f.store, meetingID: f.meeting.id, enrollment: enrollment)
        await p.beginRename(recordingID: f.recording.id, segmentID: f.revision.segments[0].id)
        p.rememberVoice = true; p.selectedProfileID = first.id; p.draftName = "Local corrected"
        #expect(p.selectedProfileNeedsNewSpeech && !p.replaceIncompatibleVoice && !p.canSave)
        p.replaceIncompatibleVoice = true; #expect(p.canSave)
        await p.saveRename()
        let next = try #require(try await profiles.profiles().first)
        #expect(next.id == first.id && next.name == "Alex" && next.revisionID != first.revisionID)
        #expect(try await profiles.revision(first.revisionID) == old)
        let (segmentation, embedding) = try clusteringModels()
        #expect(try await profiles.savedVoices(segmentation: segmentation, embedding: embedding).first?.needsNewSpeech == false)
        #expect(p.snapshot?.assignments.first?.name == "Local corrected")
        #expect(p.snapshot?.revisions == [f.revision])
        let fresh = try await f.confirm().confirmation
        await #expect(throws: VoiceEnrollmentError.changed) { try await enrollment.enroll(fresh, choice: .replaceIncompatible(profileID: next.id, revisionID: next.revisionID)) }
        try await f.store.close()
    }

    @Test func versionOneMigrationPreservesProfilesAndReceiptsAndRemovesBackup() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let first = try await remember(f, profiles: profiles), old = try await profiles.revision(first.revisionID)
        do {
            let db = try profileDB(profiles)
            try db.execute("DROP TABLE enrollment_receipts"); try db.execute("PRAGMA user_version = 1")
        }
        let reopened = VoiceProfileStore(home: root.url)
        #expect(try await reopened.profiles() == [first])
        #expect(try await reopened.revision(first.revisionID) == old)
        #expect(try profileDB(reopened).integer("SELECT count(*) FROM enrollment_receipts") == 1)
        #expect(!FileManager.default.fileExists(atPath: reopened.databaseURL.deletingLastPathComponent().appendingPathComponent("Speakers.v1-backup.sqlite3").path))
        try await reopened.delete(first)
        #expect(try profileDB(reopened).integer("SELECT count(*) FROM enrollment_receipts") == 1)
        try await f.store.close()
    }

    @Test func exportNativeSettingsFixture() async throws {
        let root = try TemporaryFolder(), export = ProcessInfo.processInfo.environment["TALKTRACK_SAVED_SPEAKERS_FIXTURE"]
        defer { if export == nil { root.remove() } }
        let catalog = try ModelCatalog.bundled()
        let models = try [ModelRole.segmentation, .embedding].map { try catalog.model(for: $0).snapshot(for: $0) }
        let f = try await enrollmentFixture(root.url, models: models), home = root.url.appendingPathComponent("fixture-home"), profiles = VoiceProfileStore(home: home)
        _ = try await remember(f, profiles: profiles)
        let incompatible = try await remember(f, profiles: profiles, name: "Needs update")
        try await makeIncompatible(incompatible, store: profiles)
        try await f.store.close()
        if let export {
            let url = URL(fileURLWithPath: export)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(["root": root.url.path, "home": home.path, "suite": "talktrack-saved-speakers-fixture-\(UUID())", "meetingID": f.meeting.id.uuidString]).write(to: url, options: .atomic)
        }
    }

    @Test func deleteOneProfileLeavesOtherBanksAndLocalTranscriptUnchanged() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let first = try await remember(f, profiles: profiles), other = try await remember(f, profiles: profiles, vector: clusterVector(1), name: "Other")
        let evidence = try await profiles.revision(other.revisionID), transcript = try await f.store.meetingTranscript(meetingID: f.meeting.id)
        try await profiles.delete(first)
        #expect(try await profiles.profiles() == [other])
        #expect(try await profiles.revision(other.revisionID) == evidence)
        #expect(try await f.store.meetingTranscript(meetingID: f.meeting.id) == transcript)
        try await f.store.close()
    }

    @Test func failedMigrationRetainsLegacyAndBackupThenRetriesAndCleans() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let first = try await remember(f, profiles: profiles)
        do {
            let db = try profileDB(profiles)
            try db.execute("DROP TABLE enrollment_receipts")
            try db.execute("CREATE TABLE enrollment_receipts (wrong TEXT)")
            try db.execute("PRAGMA user_version = 1")
        }
        await #expect(throws: (any Error).self) { try await profiles.profiles() }
        #expect(try profileDB(profiles).integer("PRAGMA user_version") == 1)
        let backup = profiles.databaseURL.deletingLastPathComponent().appendingPathComponent("Speakers.v1-backup.sqlite3")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        try profileDB(profiles).execute("DROP TABLE enrollment_receipts")
        #expect(try await profiles.profiles() == [first])
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        // Simulate a crash after v2 commit, before the legacy backup cleanup.
        do {
            let db = try SQLiteConnection(path: "/" + DirectoryHandle.physicalComponents(backup).dropFirst().joined(separator: "/"))
            try db.execute("PRAGMA application_id = 1414813264")
            try db.execute("PRAGMA user_version = 1")
            try db.execute("CREATE TABLE placeholder (id TEXT)")
        }
        #expect(try await profiles.profiles() == [first])
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        try await f.store.close()
    }

    @Test func foreignMigrationBackupRefusesMutation() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        _ = try await remember(f, profiles: profiles)
        let before = try Data(contentsOf: profiles.databaseURL)
        let backup = profiles.databaseURL.deletingLastPathComponent().appendingPathComponent("Speakers.v1-backup.sqlite3")
        try Data("unrelated".utf8).write(to: backup)
        await #expect(throws: (any Error).self) { try await profiles.profiles() }
        #expect(try Data(contentsOf: profiles.databaseURL) == before)
        #expect(try Data(contentsOf: backup) == Data("unrelated".utf8))
        try await f.store.close()
    }
}
