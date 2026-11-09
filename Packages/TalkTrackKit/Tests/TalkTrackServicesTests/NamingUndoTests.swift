import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// fix-speaker-naming-sheet: Undo of one naming Save, and removed reply names
/// that stop teaching saved voices.
@Suite struct NamingUndoTests {
    private func bank(_ profiles: VoiceProfileStore, _ id: UUID) async throws -> [VoiceProfileSample] {
        try #require(try await profiles.recognitionProfiles().first { $0.profile.id == id }).bank()
    }

    /// 2.1: an extended voice returns to its exact earlier bank, a created voice
    /// is deleted, replay stays refused, and later changes refuse the undo.
    @Test func undoEnrollmentRestoresBankDeletesCreatedVoiceAndRefusesLaterChanges() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), q = try await enrollmentFixture(root.url)
        let profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let other = VoiceProfileEnrollment(store: q.store, profiles: profiles, inference: EnrollmentInference())
        let dima = try await service.enroll(f.confirm("Dima").confirmation, choice: .newProfile)
        let before = try await bank(profiles, dima.id)
        // Yuri's speech saved into Dima by mistake.
        let mistaken = try await q.confirm("Dima")
        let extended = try await other.enroll(mistaken.confirmation, choice: .existing(profileID: dima.id, revisionID: dima.revisionID))
        #expect(try await bank(profiles, dima.id) != before)
        try await profiles.undoEnrollment(created: extended, previous: dima)
        #expect(try await profiles.profiles() == [dima])
        #expect(try await bank(profiles, dima.id) == before)
        #expect(try await profiles.revision(extended.revisionID) == nil)
        // Repeating a completed undo changes nothing; the confirmation cannot train again.
        try await profiles.undoEnrollment(created: extended, previous: dima)
        await #expect(throws: VoiceEnrollmentError.changed) {
            try await other.enroll(mistaken.confirmation, choice: .existing(profileID: dima.id, revisionID: dima.revisionID))
        }
        // A voice the Save created is deleted.
        let zoe = try await other.enroll(q.confirm("Zoe").confirmation, choice: .newProfile)
        try await profiles.undoEnrollment(created: zoe, previous: nil)
        #expect(try await profiles.profiles() == [dima])
        // A later Save into the voice, or a rename in Settings, refuses the undo.
        let again = try await other.enroll(q.confirm("Dima").confirmation, choice: .existing(profileID: dima.id, revisionID: dima.revisionID))
        let later = try await service.enroll(f.confirm("Dima").confirmation, choice: .existing(profileID: again.id, revisionID: again.revisionID))
        await #expect(throws: VoiceProfileSettingsError.changed) { try await profiles.undoEnrollment(created: again, previous: dima) }
        _ = try await profiles.rename(later, name: "Dmitry")
        await #expect(throws: VoiceProfileSettingsError.changed) { try await profiles.undoEnrollment(created: later, previous: again) }
        // Never while a recognition result is being committed.
        let current = try await profiles.recognitionProfiles()
        _ = try await profiles.withRecognitionSnapshot(current) {
            await #expect(throws: VoiceProfileSettingsError.busy) { try await profiles.undoEnrollment(created: later, previous: again) }
        }
        try await f.store.close(); try await q.store.close()
    }

    /// 2.2: restoring the naming heads read before a Save, for a reply and for a
    /// voice; a later naming makes the undo stale. Undone records stay as history.
    @Test func undoNamingRestoresReplyAndVoiceNamesAndRefusesStaleGenerations() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, pieces: 3)
        let ids = f.revision.segments.map(\.id)
        // Reply scope: the reply loses the name it did not have before.
        let none = try await f.store.namingHeads(meetingID: f.meeting.id)
        let named = try await f.store.nameFragment(meetingID: f.meeting.id, recordingID: f.recording.id, segmentIDs: [ids[0]], name: "Yuri")
        #expect(named.meeting.generation == none.generation + 1 && named.anchors.count == 1)
        var undone = try await f.store.undoNaming(none, generation: named.meeting.generation)
        #expect(undone.anchors.isEmpty && undone.meeting.generation == named.meeting.generation + 1)
        #expect(try f.db.integer("SELECT count(*) FROM records WHERE kind='fragmentAnchor'") == 1)
        // A replaced reply name returns.
        _ = try await f.store.nameFragment(meetingID: f.meeting.id, recordingID: f.recording.id, segmentIDs: [ids[1]], name: "Yuri")
        let yuri = try await f.store.namingHeads(meetingID: f.meeting.id)
        let wrong = try await f.store.nameFragment(meetingID: f.meeting.id, recordingID: f.recording.id, segmentIDs: [ids[1]], name: "Dima")
        undone = try await f.store.undoNaming(yuri, generation: wrong.meeting.generation)
        #expect(undone.anchors.map(\.name) == ["Yuri"])
        // Voice scope: the voice's previous name returns.
        _ = try await f.confirm("Dima")
        let dima = try await f.store.namingHeads(meetingID: f.meeting.id)
        let renamed = try await f.confirm("Boris")
        undone = try await f.store.undoNaming(dima, generation: renamed.snapshot.meeting.generation)
        #expect(undone.assignments.map(\.name) == ["Dima"] && undone.anchors.map(\.name) == ["Yuri"])
        #expect(try f.db.integer("SELECT count(*) FROM records WHERE kind='assignment'") == 2)
        // Another naming after the Save: nothing changes.
        let heads = try await f.store.namingHeads(meetingID: f.meeting.id)
        let first = try await f.store.nameFragment(meetingID: f.meeting.id, recordingID: f.recording.id, segmentIDs: [ids[2]], name: "Eva")
        let second = try await f.store.nameFragment(meetingID: f.meeting.id, recordingID: f.recording.id, segmentIDs: [ids[0]], name: "Oleg")
        await #expect(throws: NamingUndoError.changed) { try await f.store.undoNaming(heads, generation: first.meeting.generation) }
        #expect(try await f.store.meetingTranscript(meetingID: f.meeting.id) == second)
        try await f.store.close()
    }

    /// 2.3: a reply named Yuri saved as the saved voice Dima by mistake; Undo
    /// brings Yuri back and leaves Dima exactly as before. A session failure
    /// after the profile step keeps the token, and the retry skips that step.
    @Test @MainActor func undoWrongSavedVoiceRestoresNameAndSamplesAndRetriesAfterFailure() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), q = try await enrollmentFixture(root.url)
        let profiles = VoiceProfileStore(home: root.url)
        let dima = try await VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
            .enroll(f.confirm("Dima").confirmation, choice: .newProfile)
        let before = try await bank(profiles, dima.id)
        let p = MeetingTranscriptPresentation(store: q.store, meetingID: q.meeting.id,
            enrollment: VoiceProfileEnrollment(store: q.store, profiles: profiles, inference: EnrollmentInference()))
        let reply = [q.revision.segments[0].id]
        await p.beginNameFragment(recordingID: q.recording.id, segmentIDs: reply)
        p.draftName = "Yuri"; p.rememberVoice = false; await p.saveRename()
        await p.beginNameFragment(recordingID: q.recording.id, segmentIDs: reply)
        #expect(p.currentName == "Yuri")
        p.chooseProfile(try #require(p.profiles.first { $0.id == dima.id })); await p.saveRename(); await p.waitForLearning()
        #expect(p.snapshot?.anchors.map(\.name) == ["Dima"] && p.canUndo && p.undo?.learningTaskID != nil)
        #expect(try await bank(profiles, dima.id) != before)
        try q.db.execute("CREATE TRIGGER fail_heads BEFORE INSERT ON heads BEGIN SELECT RAISE(ABORT, 'injected head write'); END")
        await p.undoLastNaming()
        #expect(p.errorMessage?.contains("names were not restored") == true && p.undo?.profileUndone == true)
        #expect(try await bank(profiles, dima.id) == before)
        #expect(p.snapshot?.anchors.map(\.name) == ["Dima"])
        try q.db.execute("DROP TRIGGER fail_heads")
        await p.undoLastNaming()
        #expect(p.undo == nil && p.errorMessage == nil && p.noticeMessage?.hasPrefix("Undone") == true)
        #expect(p.snapshot?.anchors.map(\.name) == ["Yuri"])
        let restored = try await bank(profiles, dima.id)
        #expect(try await profiles.profiles() == [dima])
        #expect(restored == before)
        try await f.store.close(); try await q.store.close()
    }

    /// 2.3: Undo deletes a voice the Save created; a name kept when remembering
    /// failed is undone alone; a later naming refuses the undo.
    @Test @MainActor func undoCreatedVoiceKeptNameAndRefusalAfterAnotherNaming() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, pieces: 2), profiles = VoiceProfileStore(home: root.url)
        let p = MeetingTranscriptPresentation(store: f.store, meetingID: f.meeting.id,
            enrollment: VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference()))
        await p.beginRename(recordingID: f.recording.id, segmentID: f.revision.segments[0].id)
        p.draftName = "Dmitry"; await p.saveRename(); await p.waitForLearning()
        #expect(try await profiles.profiles().map(\.name) == ["Dmitry"])
        #expect(p.undo?.learningTaskID != nil)
        await p.undoLastNaming()
        #expect(try await profiles.profiles().isEmpty)
        #expect(p.snapshot?.assignments.isEmpty == true)
        #expect(p.noticeMessage?.contains("Dmitry was removed") == true)
        // Remembering failed: only the name is undone.
        let short = try await enrollmentFixture(root.url, seconds: 3)
        let s = MeetingTranscriptPresentation(store: short.store, meetingID: short.meeting.id,
            enrollment: VoiceProfileEnrollment(store: short.store, profiles: profiles, inference: EnrollmentInference()))
        await s.beginRename(recordingID: short.recording.id, segmentID: short.revision.segments[0].id)
        s.draftName = "Alex"; await s.saveRename(); await s.waitForLearning()
        #expect(try await profiles.learningTasks().last?.state == .insufficientSpeech && s.undo?.created == nil && s.canUndo)
        await s.undoLastNaming()
        #expect(s.snapshot?.assignments.isEmpty == true)
        #expect(try await profiles.profiles().isEmpty)
        // Another naming after the Save: nothing changes, and the reason is given.
        await p.beginNameFragment(recordingID: f.recording.id, segmentIDs: [f.revision.segments[0].id])
        p.draftName = "Eva"; p.rememberVoice = false; await p.saveRename()
        let other = try await f.store.nameFragment(meetingID: f.meeting.id, recordingID: f.recording.id,
                                                   segmentIDs: [f.revision.segments[1].id], name: "Oleg")
        await p.undoLastNaming()
        #expect(p.undo == nil && p.errorMessage?.contains("Remove Reply Name") == true)
        #expect(try await f.store.meetingTranscript(meetingID: f.meeting.id) == other)
        // Refresh after any other change drops the offer; so does the next naming action.
        await p.beginNameFragment(recordingID: f.recording.id, segmentIDs: [f.revision.segments[0].id])
        p.draftName = "Ivan"; p.rememberVoice = false; await p.saveRename()
        #expect(p.canUndo)
        _ = try await f.store.nameFragment(meetingID: f.meeting.id, recordingID: f.recording.id, segmentIDs: [f.revision.segments[1].id], name: "Zoe")
        await p.refresh()
        #expect(p.undo == nil)
        await p.beginNameFragment(recordingID: f.recording.id, segmentIDs: [f.revision.segments[0].id])
        p.draftName = "Maria"; p.rememberVoice = false; await p.saveRename()
        await p.clearSpeakerNames()
        #expect(p.undo == nil)
        try await f.store.close(); try await short.store.close()
    }

    /// 3.2: a removed reply name stops teaching every voice that learned it
    /// before; naming it Yuri later teaches Yuri; repeating changes nothing;
    /// saved-voice status reads the reduced bank.
    @Test func withdrawnReplySpeechLeavesEarlierBanksOnly() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, pieces: 3), q = try await enrollmentFixture(root.url)
        let profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let segments = f.revision.segments
        let dima = try await service.enroll(f.confirm("Dima").confirmation, choice: .newProfile)
        let reply = try await f.store.nameFragmentWithConfirmation(meetingID: f.meeting.id, recordingID: f.recording.id,
                                                                   segmentIDs: [segments[0].id], name: "Dima")
        _ = try await service.enroll(reply.confirmation, choice: .existing(profileID: dima.id, revisionID: dima.revisionID))
        let before = try await bank(profiles, dima.id)
        func inside(_ sample: VoiceProfileSample, _ index: Int) -> Bool {
            VoiceCorrection(libraryID: f.library.manifest.libraryID, recordingID: f.recording.id, interval: segments[index].interval, person: "")
                .covers(sample, libraryID: f.library.manifest.libraryID)
        }
        #expect(before.contains { inside($0, 0) })
        let removed = try await f.store.removeFragmentNames(meetingID: f.meeting.id, recordingID: f.recording.id, segmentIDs: [segments[0].id])
        #expect(removed.snapshot.anchors.isEmpty && removed.withdrawals.map(\.interval) == [segments[0].interval])
        try await profiles.withdraw(removed.withdrawals)
        let after = try await bank(profiles, dima.id)
        #expect(!after.isEmpty && !after.contains { inside($0, 0) } && after.count < before.count)
        try await profiles.withdraw(removed.withdrawals)
        #expect(try await bank(profiles, dima.id) == after)
        // Named again as Yuri: the speech now teaches Yuri and still not Dima.
        let yuri = try await VoiceProfileEnrollment(store: q.store, profiles: profiles, inference: EnrollmentInference())
            .enroll(q.confirm("Yuri").confirmation, choice: .newProfile)
        let renamed = try await f.store.nameFragmentWithConfirmation(meetingID: f.meeting.id, recordingID: f.recording.id,
                                                                     segmentIDs: [segments[0].id], name: "Yuri")
        _ = try await service.enroll(renamed.confirmation, choice: .existing(profileID: yuri.id, revisionID: yuri.revisionID))
        #expect(try await bank(profiles, yuri.id).contains { inside($0, 0) })
        #expect(try await bank(profiles, dima.id) == after)
        // Withdrawing more of Dima's speech leaves too little: Settings says it needs new speech.
        let (segmentation, embedding) = try clusteringModels()
        #expect(try await profiles.savedVoices(segmentation: segmentation, embedding: embedding).first { $0.id == dima.id }?.needsNewSpeech == false)
        try await profiles.withdraw([VoiceWithdrawal(libraryID: f.library.manifest.libraryID, recordingID: f.recording.id,
                                                     interval: segments[1].interval, withdrawnAt: Date())])
        #expect(try await profiles.savedVoices(segmentation: segmentation, embedding: embedding).first { $0.id == dima.id }?.needsNewSpeech == true)
        let status = try await profiles.recognitionStatus(segmentation: segmentation, embedding: embedding)
        #expect(status == VoiceProfileCalibrator.status(try await profiles.recognitionProfiles(), segmentation: segmentation, embedding: embedding))
        try await f.store.close(); try await q.store.close()
    }

    /// 3.3: Remove Reply Name records the withdrawal after the name removal;
    /// a failure keeps it, says what did not happen, and Retry records it.
    @Test @MainActor func removeReplyNameWithdrawsAndRetriesAfterFailure() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, pieces: 3), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let ids = f.revision.segments.map(\.id)
        let dima = try await service.enroll(f.confirm("Dima").confirmation, choice: .newProfile)
        _ = try await f.store.nameFragment(meetingID: f.meeting.id, recordingID: f.recording.id, segmentIDs: [ids[0]], name: "Dima")
        _ = try await f.store.nameFragment(meetingID: f.meeting.id, recordingID: f.recording.id, segmentIDs: [ids[1]], name: "Dima")
        let before = try await bank(profiles, dima.id)
        let p = MeetingTranscriptPresentation(store: f.store, meetingID: f.meeting.id, enrollment: service)
        await p.refresh()
        await p.removeFragmentName(recordingID: f.recording.id, segmentIDs: [ids[0]])
        #expect(p.errorMessage == nil && p.pendingWithdrawals.isEmpty && p.snapshot?.anchors.count == 1)
        let first = try await bank(profiles, dima.id)
        #expect(first.count < before.count)
        let db = try SQLiteConnection(path: "/" + DirectoryHandle.physicalComponents(profiles.databaseURL).dropFirst().joined(separator: "/"))
        try db.execute("CREATE TRIGGER fail_withdraw BEFORE INSERT ON withdrawals BEGIN SELECT RAISE(ABORT, 'injected withdrawal'); END")
        await p.removeFragmentName(recordingID: f.recording.id, segmentIDs: [ids[1]])
        #expect(p.snapshot?.anchors.isEmpty == true && p.pendingWithdrawals.count == 1)
        #expect(p.errorMessage?.contains("still use its speech") == true && p.errorMessage?.contains("injected withdrawal") == true)
        #expect(try await bank(profiles, dima.id) == first)
        try db.execute("DROP TRIGGER fail_withdraw")
        await p.retry()
        #expect(p.errorMessage == nil && p.pendingWithdrawals.isEmpty)
        #expect(try db.integer("SELECT count(*) FROM withdrawals") == 2)
        #expect(try await bank(profiles, dima.id).count < first.count)
        try await f.store.close()
    }
}
