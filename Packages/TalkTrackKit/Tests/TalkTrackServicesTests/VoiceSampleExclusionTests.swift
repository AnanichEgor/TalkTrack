import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// saved-voice-samples: samples listed per voice, removed from one voice only,
/// counted again after a fresh confirmation, and restored exactly by Undo.
@Suite struct VoiceSampleExclusionTests {
    private func voice(_ profiles: VoiceProfileStore, _ id: UUID) async throws -> VoiceRecognitionProfile {
        try #require(try await profiles.recognitionProfiles().first { $0.profile.id == id })
    }
    private func current(_ profiles: VoiceProfileStore, _ id: UUID) async throws -> VoiceProfile {
        try #require(try await profiles.profiles().first { $0.id == id })
    }

    /// 2.1: the list is exactly the compatible bank candidates, and the
    /// "used" flags are the bank selection.
    @Test func listingMatchesBankCandidatesAndSelection() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, pieces: 3), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let dima = try await service.enroll(f.confirm("Dima").confirmation, choice: .newProfile)
        let listed = try await profiles.samples(of: dima)
        let voice = try await voice(profiles, dima.id), bank = voice.bank()
        let candidates = voice.compatibleHistory.flatMap(\.samples)
        #expect(!listed.isEmpty && listed.count == candidates.count)
        #expect(Set(listed.map(\.id)) == Set(voice.compatibleHistory.flatMap { revision in revision.samples.map {
            SavedVoiceSample(key: VoiceSampleExclusion(profileID: dima.id, revisionID: revision.id, recordingID: $0.recordingID, interval: $0.interval),
                             libraryID: revision.libraryID, meetingID: revision.meetingID, daySpeakerID: revision.daySpeakerID,
                             confirmedAt: revision.createdAt, usedForRecognition: true).id } }))
        #expect(listed.filter(\.usedForRecognition).count == bank.count)
        #expect(listed.allSatisfy { $0.meetingID == f.meeting.id && $0.libraryID == f.library.manifest.libraryID && $0.recordingID == f.recording.id })
        let renamed = try await profiles.rename(dima, name: "Dmitry")
        await #expect(throws: VoiceProfileSettingsError.changed) { try await profiles.samples(of: dima) }
        #expect(try await profiles.samples(of: renamed).map(\.id) == listed.map(\.id))
        try await f.store.close()
    }

    /// 1.2: an excluded sample leaves only that voice's bank, status and
    /// adequacy; a later confirmation of the same speech counts again.
    @Test func exclusionRemovesFromOneVoiceAndFreshConfirmationCountsAgain() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, pieces: 3), q = try await enrollmentFixture(root.url, pieces: 3)
        let profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let dima = try await service.enroll(f.confirm("Dima").confirmation, choice: .newProfile)
        // Another voice that learned speech at the same recording times.
        let other = try await VoiceProfileEnrollment(store: q.store, profiles: profiles, inference: EnrollmentInference())
            .enroll(q.confirm("Other").confirmation, choice: .newProfile)
        let otherBank = try await voice(profiles, other.id).bank()
        let listed = try await profiles.samples(of: dima), first = try #require(listed.first)
        try await profiles.exclude([first.key], from: dima)
        let after = try await profiles.samples(of: dima)
        #expect(after.count == listed.count - 1 && !after.contains { $0.id == first.id })
        #expect(!(try await voice(profiles, dima.id).bank()).contains { $0.recordingID == first.recordingID && $0.interval == first.interval })
        #expect(try await voice(profiles, other.id).bank() == otherBank)
        let (segmentation, embedding) = try clusteringModels()
        let status = try await profiles.recognitionStatus(segmentation: segmentation, embedding: embedding)
        #expect(status == VoiceProfileCalibrator.status(try await profiles.recognitionProfiles(), segmentation: segmentation, embedding: embedding))
        // Removing everything leaves too little speech: Settings says so.
        #expect(try await profiles.savedVoices(segmentation: segmentation, embedding: embedding).first { $0.id == dima.id }?.needsNewSpeech == false)
        try await profiles.exclude(after.map(\.key), from: dima)
        #expect(try await profiles.samples(of: dima).isEmpty)
        #expect(try await profiles.savedVoices(segmentation: segmentation, embedding: embedding).first { $0.id == dima.id }?.needsNewSpeech == true)
        // Naming the same speech Dima again creates a new revision that counts.
        let again = try await service.enroll(f.confirm("Dima").confirmation, choice: .newProfile)
        #expect(try await profiles.samples(of: again).count == listed.count)
        try await f.store.close(); try await q.store.close()
    }

    /// 1.3: stale, unlisted, repeated and busy removals are refused; restore
    /// returns the exact bank; Undo of a naming still works afterwards.
    @Test func refusalsRestoreAndNamingUndoAfterExclusion() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, pieces: 3), q = try await enrollmentFixture(root.url)
        let profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let dima = try await service.enroll(f.confirm("Dima").confirmation, choice: .newProfile)
        let before = try await voice(profiles, dima.id).bank()
        let sample = try #require(try await profiles.samples(of: dima).first)
        let unlisted = VoiceSampleExclusion(profileID: dima.id, revisionID: sample.key.revisionID, recordingID: sample.recordingID,
            interval: try MediaInterval(start: MediaTime(microseconds: 1), end: MediaTime(microseconds: 2)))
        await #expect(throws: VoiceProfileSettingsError.changed) { try await profiles.exclude([unlisted], from: dima) }
        let foreign = VoiceSampleExclusion(profileID: UUID(), revisionID: sample.key.revisionID, recordingID: sample.recordingID, interval: sample.interval)
        await #expect(throws: VoiceProfileSettingsError.changed) { try await profiles.exclude([foreign], from: dima) }
        let registry = try await profiles.recognitionProfiles()
        try await profiles.withRecognitionSnapshot(registry) {
            await #expect(throws: VoiceProfileSettingsError.busy) { try await profiles.exclude([sample.key], from: dima) }
            await #expect(throws: VoiceProfileSettingsError.busy) { try await profiles.restore([sample.key], to: dima) }
        }
        #expect(try await voice(profiles, dima.id).bank() == before)
        let removed = try await profiles.exclude([sample.key, sample.key], from: dima)
        #expect(removed == [sample.key])
        await #expect(throws: VoiceProfileSettingsError.changed) { try await profiles.exclude([sample.key], from: dima) }
        try await profiles.restore(removed, to: dima)
        #expect(try await voice(profiles, dima.id).bank() == before)
        // A stale head refuses both.
        let renamed = try await profiles.rename(dima, name: "Dmitry")
        await #expect(throws: VoiceProfileSettingsError.changed) { try await profiles.exclude([sample.key], from: dima) }
        await #expect(throws: VoiceProfileSettingsError.changed) { try await profiles.restore([sample.key], to: dima) }
        // Undo of another voice's naming is unaffected by an exclusion.
        let yuri = try await VoiceProfileEnrollment(store: q.store, profiles: profiles, inference: EnrollmentInference())
            .enroll(q.confirm("Yuri").confirmation, choice: .newProfile)
        try await profiles.exclude([sample.key], from: renamed)
        try await profiles.undoEnrollment(created: yuri, previous: nil)
        #expect(try await profiles.profiles().map(\.id) == [renamed.id])
        #expect(try await current(profiles, renamed.id) == renamed)
        // Deleting a voice removes its exclusions too.
        try await profiles.delete(renamed)
        let db = try SQLiteConnection(path: "/" + DirectoryHandle.physicalComponents(profiles.databaseURL).dropFirst().joined(separator: "/"))
        #expect(try db.integer("SELECT count(*) FROM exclusions") == 0)
        try await f.store.close(); try await q.store.close()
    }

    /// 2.2: meeting, day, time and reply text from the open library; other
    /// libraries and deleted recordings or meetings are named; nothing is written.
    @Test func contextNamesMeetingTimeAndTextAndUnavailableSamples() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, pieces: 3), profiles = VoiceProfileStore(home: root.url)
        let dima = try await VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
            .enroll(f.confirm("Dima").confirmation, choice: .newProfile)
        let samples = try await profiles.samples(of: dima), sample = try #require(samples.first)
        let registry = try Data(contentsOf: profiles.databaseURL)
        let contexts = await f.store.voiceSampleContexts(samples)
        guard case .available(let details) = contexts[sample.id] else { Issue.record("no context"); return }
        #expect(details.meetingTitle == "Voice enrollment fixture" && details.date == "October 9, 2026")
        // Each sample shows where it starts, not the start of its block.
        let times = samples.compactMap { if case .available(let d) = contexts[$0.id] { d.time } else { nil } }
        #expect(times.count == samples.count && Set(times).count == samples.count && times[0] == "09:00:00")
        #expect(details.time != nil && !(details.text ?? "").isEmpty && (details.text ?? "").count <= VoiceSampleContext.maximumText)
        let foreign = SavedVoiceSample(key: sample.key, libraryID: UUID(), meetingID: sample.meetingID, daySpeakerID: sample.daySpeakerID,
                                       confirmedAt: sample.confirmedAt, usedForRecognition: true)
        #expect(await f.store.voiceSampleContexts([foreign])[foreign.id] == .otherLibrary)
        try await f.store.deleteRecording(meetingID: f.meeting.id, recordingID: f.recording.id)
        #expect(await f.store.voiceSampleContexts([sample])[sample.id] == .recordingDeleted)
        try await f.store.deleteMeeting(f.meeting.id)
        #expect(await f.store.voiceSampleContexts([sample])[sample.id] == .recordingDeleted)
        #expect(try Data(contentsOf: profiles.databaseURL) == registry)
        #expect(VoiceSampleContext.clipped(String(repeating: "a", count: 400)).count == VoiceSampleContext.maximumText)
        try await f.store.close()
    }

    /// 2.3: Settings groups samples by meeting day, removes one or a day,
    /// offers one Undo, and an injected write failure changes nothing.
    @Test @MainActor func presentationRemovesUndoesAndKeepsStateOnFailure() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, pieces: 3), q = try await enrollmentFixture(root.url, pieces: 3)
        let profiles = VoiceProfileStore(home: root.url)
        let dima = try await VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
            .enroll(f.confirm("Dima").confirmation, choice: .newProfile)
        let extended = try await VoiceProfileEnrollment(store: q.store, profiles: profiles, inference: EnrollmentInference())
            .enroll(q.confirm("Dima").confirmation, choice: .existing(profileID: dima.id, revisionID: dima.revisionID))
        let defaults = try #require(UserDefaults(suiteName: "saved-voice-samples-\(UUID())"))
        let presentation = SavedSpeakersPresentation(store: profiles, defaults: defaults)
        let store = f.store
        presentation.sampleContexts = { samples in await store.voiceSampleContexts(samples) }
        await presentation.refresh()
        await presentation.toggleSamples(extended)
        let days = try #require(presentation.sampleDays[dima.id])
        #expect(days.count == 2 && Set(days.map(\.meetingID)) == [f.meeting.id, q.meeting.id])
        #expect(days[0].meetingID == q.meeting.id)
        let total = try #require(presentation.sampleCount(dima.id))
        let one = try #require(days[0].samples.first)
        // Both fixtures share one library, so both days are described.
        for day in days { #expect(presentation.contexts[day.samples[0].id].map { if case .available = $0 { true } else { false } } == true) }
        // An injected write failure shows the error and changes nothing.
        let db = try SQLiteConnection(path: "/" + DirectoryHandle.physicalComponents(profiles.databaseURL).dropFirst().joined(separator: "/"))
        try db.execute("CREATE TRIGGER fail BEFORE INSERT ON exclusions BEGIN SELECT RAISE(ABORT, 'injected'); END")
        await presentation.remove([one], from: extended)
        #expect(presentation.errorMessage != nil && presentation.removalUndo == nil && presentation.sampleCount(dima.id) == total)
        try db.execute("DROP TRIGGER fail")
        await presentation.remove([one], from: extended)
        #expect(presentation.errorMessage == nil && presentation.sampleCount(dima.id) == total - 1)
        #expect(presentation.removalUndo?.removed == [one.key] && presentation.removalUndo?.text == "Removed 1 sample from Dima.")
        await presentation.undoRemoval()
        #expect(presentation.removalUndo == nil && presentation.sampleCount(dima.id) == total)
        // A whole day; then a refresh ends the Undo offer.
        await presentation.remove(days[1].samples, from: extended)
        #expect(presentation.sampleDays[dima.id]?.map(\.meetingID) == [q.meeting.id])
        #expect(presentation.removalUndo?.removed.count == days[1].samples.count)
        await presentation.refresh()
        #expect(presentation.removalUndo == nil && presentation.sampleDays[dima.id]?.count == 1)
        await presentation.toggleSamples(extended)
        #expect(presentation.sampleDays[dima.id] == nil && presentation.expanded.isEmpty)
        try await f.store.close(); try await q.store.close()
    }

    /// 3.1: a sample plays exactly its recording's system audio for its
    /// interval; deleted recordings and capture refuse it.
    @Test @MainActor func previewReadsOnlySystemAudioOfTheInterval() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, pieces: 3), profiles = VoiceProfileStore(home: root.url)
        let dima = try await VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
            .enroll(f.confirm("Dima").confirmation, choice: .newProfile)
        let sample = try #require(try await profiles.samples(of: dima).first)
        let audio = try await VoiceSamplePreview.audio(of: sample, library: f.library, store: f.store)
        // The whole recording read the way the meeting player reads it.
        let recordings = try await f.store.recordings(meetingID: f.meeting.id)
        let source = try MeetingAudioSource(library: f.library, meetingID: f.meeting.id, recordings: recordings)
        var system: [Float] = [], microphone: [Float] = []
        while let block = try await source.next() { system += block.system; microphone += block.microphone }
        let first = Int(try PlaybackFrames.frame(sample.interval.start)), last = Int(try PlaybackFrames.frame(sample.interval.end))
        #expect(audio.count == last - first && Array(system[first..<last]) == audio)
        #expect(audio.contains { abs($0) > 0.01 } && Array(microphone[first..<last]) != audio)
        let preview = VoiceSamplePreview(library: f.library, store: f.store)
        var paused = false
        preview.beforePlay = { paused = true }
        preview.isCapturing = { true }
        await preview.play(sample)
        #expect(preview.playing == nil && preview.errorMessage == VoiceSamplePreview.capturingMessage && !paused)
        let foreign = SavedVoiceSample(key: sample.key, libraryID: UUID(), meetingID: sample.meetingID, daySpeakerID: sample.daySpeakerID,
                                       confirmedAt: sample.confirmedAt, usedForRecognition: true)
        await #expect(throws: VoiceSamplePreviewError.unavailable) { try await VoiceSamplePreview.audio(of: foreign, library: f.library, store: f.store) }
        try await f.store.deleteRecording(meetingID: f.meeting.id, recordingID: f.recording.id)
        await #expect(throws: VoiceSamplePreviewError.unavailable) { try await VoiceSamplePreview.audio(of: sample, library: f.library, store: f.store) }
        try await f.store.close()
    }

    /// 3.2: capture start stops every TalkTrack player, in order.
    @Test func combinedExclusionStopsEveryPlayer() async {
        actor Calls { var names: [String] = []; func add(_ name: String) { names.append(name) } }
        struct Spy: CapturePlaybackExclusion {
            let name: String, calls: Calls
            func stopPlaybackBeforeCapture() async { await calls.add(name) }
        }
        let calls = Calls()
        await CombinedPlaybackExclusion([Spy(name: "player", calls: calls), Spy(name: "preview", calls: calls)]).stopPlaybackBeforeCapture()
        #expect(await calls.names == ["player", "preview"])
    }
}
