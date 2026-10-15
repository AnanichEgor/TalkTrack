import AVFoundation
import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

private enum VoiceFixtureFailure: Error { case injected }
actor EnrollmentInference: SystemSpeakerInference {
    enum Mode { case clean, mixed, invalidVector, wrongModel, failure, fragmentedFirstWindow }
    var mode: Mode
    var delay = false
    var activityCalls = 0
    var embeddingFrames: [Int] = []
    init(_ mode: Mode = .clean) { self.mode = mode }
    func setDelay(_ value: Bool) { delay = value }
    func speakerActivity(_ model: ModelSnapshot, samples: [Float]) async throws -> [SpeakerWindowActivity] {
        activityCalls += 1
        if delay { try await Task.sleep(for: .seconds(5)) }
        if mode == .failure { throw VoiceFixtureFailure.injected }
        if mode == .fragmentedFirstWindow && activityCalls == 1 {
            return try (0..<8).map { SpeakerWindowActivity(slot: 1, relative: try clusterRange(Double($0) * 1.2, Double($0) * 1.2 + 1.1)) }
        }
        let range = try clusterRange(0, Double(samples.count) / 16_000)
        return [SpeakerWindowActivity(slot: 1, relative: range)] + (mode == .mixed ? [SpeakerWindowActivity(slot: 2, relative: range)] : [])
    }
    func speakerEmbedding(_ model: ModelSnapshot, samples: [Float]) async throws -> SpeakerWindowEmbedding {
        embeddingFrames.append(samples.count)
        let returned = mode == .wrongModel ? try clusteringModels().0 : model
        return SpeakerWindowEmbedding(values: mode == .invalidVector ? [Float](repeating: 0, count: 256) : clusterVector(0), model: returned)
    }
}

struct EnrollmentFixture {
    let library: OpenedLibrary
    let store: SessionStore
    let meeting: Meeting
    let recording: Recording
    let revision: TranscriptRevision
    let speaker: DaySpeaker
    let db: SQLiteConnection
    func confirm(_ name: String = "Alex") async throws -> ConfirmedSpeakerRename {
        let target = try await store.speakerRenameTarget(meetingID: meeting.id, recordingID: recording.id, segmentID: revision.segments[0].id)
        return try await store.renameSpeakerWithConfirmation(target, name: name)
    }
}

func enrollmentFixture(_ root: URL, seconds: Double = 24, amplitude: Double = 0.1, otherSpeech: Bool = false, at: Date? = nil,
                       models: [ModelSnapshot]? = nil, pieces: Int = 1) async throws -> EnrollmentFixture {
    let library = try await OwnedLibrary().open(root: root), store = try await SessionStore.open(library)
    let meeting = try await store.createMeeting(MeetingDraft(title: seconds >= 10 ? "Voice enrollment fixture" : "Insufficient speech fixture"))
    let date = at ?? ISO8601DateFormatter().date(from: "2026-10-09T09:00:00Z")!
    let initial = try Recording(meetingID: meeting.id, startedAt: date, timeZoneIdentifier: "UTC")
    let writer = try await RecordingAudioWriter.create(library: library, recording: initial)
    let origin = AVAudioTime.hostTime(forSeconds: 100), frames = Int(seconds * 48_000)
    var clock = CaptureIntervalClock()
    try clock.begin(hostTime: origin, wallClock: date, timeZoneIdentifier: "UTC")
    try await writer.updateCaptureTiming(clock.close(at: origin + AVAudioTime.hostTime(forSeconds: seconds)), state: .recording)
    for offset in stride(from: 0, to: frames, by: 8192) {
        let pcm = (offset..<min(frames, offset + 8192)).map { Float(amplitude * sin(2 * .pi * 400 * Double($0) / 48_000)) }
        try await writer.append(track: .system, samples: pcm, activeStartFrame: UInt64(offset),
            hostTimeStart: origin + AVAudioTime.hostTime(forSeconds: Double(offset) / 48_000))
    }
    let recording = try await writer.finish().recording
    try await store.saveRecording(recording)
    let speaker = DaySpeaker(meetingID: meeting.id, dayID: recording.days[0].id, number: 1)
    let db = try SQLiteConnection(path: "/" + DirectoryHandle.physicalComponents(library.directory).dropFirst().joined(separator: "/") + "/Library.sqlite3")
    for item in [speaker] + (otherSpeech ? [DaySpeaker(meetingID: meeting.id, dayID: speaker.dayID, number: 2)] : []) {
        try db.execute("INSERT INTO records VALUES ('daySpeaker',?,?,?,?)", [.text(item.id.uuidString), .text(item.meetingID.uuidString), .text(item.dayID.uuidString), .blob(DomainCodec.encode(item))])
    }
    let piece = seconds / Double(pieces)
    var segments = try (0..<pieces).map { index in
        TranscriptSegment(recordingID: recording.id, dayID: speaker.dayID, track: .system,
            interval: try clusterRange(Double(index) * piece, Double(index + 1) * piece),
            wallClockStart: date.addingTimeInterval(Double(index) * piece), speaker: .system(daySpeakerID: speaker.id),
            originalText: pieces == 1 ? "Alex will not change 42. Алекс не изменит сумму." : "Part \(index + 1).")
    }
    if otherSpeech {
        let speakers = try await store.daySpeakers(meetingID: meeting.id)
        let other = try #require(speakers.first { $0.id != speaker.id })
        segments.append(TranscriptSegment(recordingID: recording.id, dayID: speaker.dayID, track: .system,
            interval: try clusterRange(0, seconds), wallClockStart: date, speaker: .system(daySpeakerID: other.id), originalText: "Overlapping voice"))
    }
    let (segmentation, embedding) = try clusteringModels()
    let chosenModels = models ?? [segmentation, embedding]
    let revision = TranscriptRevision(recordingID: recording.id, sourceGeneration: recording.generation, kind: .final,
        segments: segments, modelRevisions: chosenModels)
    let job = try await store.enqueue(kind: .finalTranscription, meetingID: meeting.id, recordingID: recording.id, settings: ProcessingSettings(), models: chosenModels)
    try await store.publishTranscript(revision, jobID: job.id)
    return EnrollmentFixture(library: library, store: store, meeting: meeting, recording: recording, revision: revision, speaker: speaker, db: db)
}

@Suite struct VoiceProfileEnrollmentTests {
    /// Task 6.6 (user decision): remembering is the default. Cancel stores
    /// nothing; a new name creates a profile; the same name later reuses it.
    @Test @MainActor func renameRemembersByDefaultAndMatchesSavedNames() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let p = MeetingTranscriptPresentation(store: f.store, meetingID: f.meeting.id, enrollment: service)
        await p.beginRename(recordingID: f.recording.id, segmentID: f.revision.segments[0].id)
        #expect(p.rememberVoice && p.profiles.isEmpty && p.suggestions.isEmpty)
        p.draftName = "Not kept"; p.cancelRename()
        #expect(!FileManager.default.fileExists(atPath: profiles.databaseURL.path))
        await p.beginRename(recordingID: f.recording.id, segmentID: f.revision.segments[0].id)
        p.draftName = "Alex"; #expect(p.effectiveProfileID == nil)
        await p.saveRename()
        let alex = try #require(try await profiles.profiles().first)
        #expect(alex.name == "Alex" && p.noticeMessage?.contains("Voice remembered locally as Alex") == true)
        // Saved voices are suggested first and a typed same name selects the profile.
        await p.beginRename(recordingID: f.recording.id, segmentID: f.revision.segments[0].id)
        #expect(p.profiles == [alex])
        p.draftName = "al"; #expect(p.suggestions == [alex] && p.effectiveProfileID == nil)
        p.draftName = "bo"; #expect(p.suggestions.isEmpty)
        p.draftName = " alex "; #expect(p.effectiveProfileID == alex.id)
        await p.saveRename()
        let after = try await profiles.profiles()
        #expect(after.count == 1 && after[0].id == alex.id && after[0].revisionID != alex.revisionID)
        try await f.store.close()
    }

    @Test func enrollmentKeepsVersionedEvidenceAcrossReopenAndLibraryDeletion() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let model = EnrollmentInference(), service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: model)
        let saved = try await f.confirm(), profile = try await service.enroll(saved.confirmation, choice: .newProfile)
        let revision = try #require(try await profiles.revision(profile.revisionID))
        #expect(revision.previousRevisionID == nil && revision.calibrationVersion == nil)
        #expect(revision.libraryID == f.library.manifest.libraryID && revision.assignmentID == saved.confirmation.assignment.id)
        #expect(revision.samples.count == 3 && revision.samples.reduce(0) { $0 + $1.interval.duration.seconds } > 23)
        #expect(revision.samples.allSatisfy { $0.transcriptRevisionID == f.revision.id && VoiceEnrollmentPolicy.validVector($0.vector) })
        #expect(await model.embeddingFrames.allSatisfy { (16_000...160_000).contains($0) })
        #expect(try await f.store.transcript(meetingID: f.meeting.id, recordingID: f.recording.id) == f.revision)
        #expect(profiles.databaseURL.path.contains("Library/Application Support/TalkTrack/Speakers.sqlite3"))
        try await f.store.deleteMeeting(f.meeting.id); try await f.store.close()
        let reopened = VoiceProfileStore(home: root.url)
        #expect(try await reopened.profiles() == [profile])
        #expect(try await reopened.revision(profile.revisionID) == revision)
        #expect(!FileManager.default.fileExists(atPath: profiles.databaseURL.deletingLastPathComponent().appendingPathComponent("Models").path))
    }

    /// Samples are chosen over all of the speaker's speech (user request,
    /// 2026-10-14): eight short clips at the start do not fill the voice, and
    /// only the kept clips are embedded.
    @Test func eightEarlyShortSamplesDoNotHideLaterAdequateSpeech() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url), model = EnrollmentInference(.fragmentedFirstWindow)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: model)
        let profile = try await service.enroll(f.confirm().confirmation, choice: .newProfile)
        let revision = try #require(try await profiles.revision(profile.revisionID))
        #expect(revision.samples.count == 8)
        #expect(revision.samples.reduce(0) { $0 + $1.interval.duration.seconds } >= 10)
        #expect(revision.samples.contains { $0.interval.duration.seconds > 8 })
        #expect(revision.samples.contains { $0.interval.start.seconds < 10 } && revision.samples.contains { $0.interval.start.seconds >= 16 })
        let frames = await model.embeddingFrames
        #expect(frames.count == revision.samples.count)
        try await f.store.close()
    }

    @Test @MainActor func existingProfileSelectionAppendsImmutableRevisionWithoutRenamingHistory() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let first = try await service.enroll(f.confirm("Alex").confirmation, choice: .newProfile)
        let old = try await profiles.revision(first.revisionID)
        let p = MeetingTranscriptPresentation(store: f.store, meetingID: f.meeting.id, enrollment: service)
        await p.beginRename(recordingID: f.recording.id, segmentID: f.revision.segments[0].id)
        #expect(p.profiles == [first] && p.rememberVoice)
        p.draftName = "Алексей"; p.rememberVoice = true; p.selectedProfileID = first.id; await p.saveRename()
        let second = try #require(try await profiles.profiles().first)
        #expect(second.id == first.id && second.name == "Alex" && second.revisionID != first.revisionID)
        #expect(try await profiles.revision(second.revisionID)?.previousRevisionID == first.revisionID)
        #expect(try await profiles.revision(first.revisionID) == old)
        #expect(p.snapshot?.assignments[0].name == "Алексей")
        #expect(p.noticeMessage?.contains("Voice remembered locally as Alex") == true)
        try await f.store.close()
    }

    @Test(arguments: [3.0, 10.0]) @MainActor func insufficientSpeechRetainsNameAndExplainsMinimum(_ seconds: Double) async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, seconds: seconds), profiles = VoiceProfileStore(home: root.url)
        let p = MeetingTranscriptPresentation(store: f.store, meetingID: f.meeting.id,
            enrollment: VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference()))
        await p.beginRename(recordingID: f.recording.id, segmentID: f.revision.segments[0].id)
        p.draftName = "Alex"; p.rememberVoice = true; await p.saveRename()
        #expect(p.renameTarget == nil && p.renameError == nil && p.errorMessage == nil)
        #expect(p.snapshot?.assignments[0].name == "Alex")
        #expect(p.noticeMessage?.contains("Name saved") == true && p.noticeMessage?.contains("10 seconds") == true)
        #expect(try await profiles.profiles().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: profiles.databaseURL.path))
        try await f.store.close()
    }

    @Test func overlappingSegmentationAndOtherTranscriptVoicesCannotEnroll() async throws {
        for otherTranscript in [false, true] {
            let root = try TemporaryFolder(); defer { root.remove() }
            let f = try await enrollmentFixture(root.url, otherSpeech: otherTranscript), profiles = VoiceProfileStore(home: root.url)
            let model = EnrollmentInference(otherTranscript ? .clean : .mixed)
            let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: model)
            let confirmation = try await f.confirm().confirmation
            await #expect(throws: VoiceEnrollmentError.insufficientSpeech) { try await service.enroll(confirmation, choice: .newProfile) }
            #expect(await model.embeddingFrames.isEmpty)
            #expect(try await profiles.profiles().isEmpty)
            try await f.store.close()
        }
    }

    @Test func silenceClippingNonfiniteSignalsAndDuplicateIntervalsCannotManufactureEvidence() async throws {
        #expect(!VoiceProfileEnrollment.suitablePCM([0, 0, 0]))
        #expect(!VoiceProfileEnrollment.suitablePCM([1, -1, 1]))
        #expect(!VoiceProfileEnrollment.suitablePCM([.nan, .infinity]))
        #expect(VoiceProfileEnrollment.suitablePCM([0.1, -0.1]))
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, amplitude: 0), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let saved = try await f.confirm()
        await #expect(throws: VoiceEnrollmentError.insufficientSpeech) { try await service.enroll(saved.confirmation, choice: .newProfile) }
        let reader = try await RecordingAudioWindowReader.open(library: f.library, recording: f.recording, track: .system)
        guard case .audio(let window) = try await reader.next() else { Issue.record("Missing window"); return }
        let range = try clusterRange(0, window.active.duration.seconds)
        let intervals = try VoiceProfileEnrollment.cleanIntervals(window: window,
            activity: [SpeakerWindowActivity(slot: 1, relative: range), SpeakerWindowActivity(slot: 1, relative: range)], selected: [range, range], other: [])
        #expect(intervals == [window.owned])
        let firstVoice = try clusterRange(0, 4.5), secondVoice = try clusterRange(4.5, window.active.duration.seconds)
        let handoff = try VoiceProfileEnrollment.cleanIntervals(window: window, activity: [
            SpeakerWindowActivity(slot: 1, relative: firstVoice), SpeakerWindowActivity(slot: 2, relative: secondVoice)
        ], selected: [range], other: [])
        #expect(handoff.count == 2 && handoff[0].end == handoff[1].start)
        #expect(handoff[0].duration.seconds == 4.5)
        await reader.close(); try await f.store.close()
    }

    @Test func invalidEmbeddingAndAdapterFailureLeaveProfilesUntouched() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        for mode: EnrollmentInference.Mode in [.invalidVector, .wrongModel, .failure] {
            let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference(mode))
            let confirmation = try await f.confirm().confirmation
            await #expect(throws: (any Error).self) { try await service.enroll(confirmation, choice: .newProfile) }
            #expect(try await profiles.profiles().isEmpty)
        }
        try await f.store.close()
    }

    @Test func changedConfirmationAndReplayCannotTrain() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let old = try await f.confirm().confirmation
        _ = try await f.confirm("Changed")
        await #expect(throws: VoiceEnrollmentError.changed) { try await service.enroll(old, choice: .newProfile) }
        let current = try await f.confirm().confirmation
        _ = try await service.enroll(current, choice: .newProfile)
        let bytes = try Data(contentsOf: profiles.databaseURL)
        await #expect(throws: VoiceEnrollmentError.changed) { try await service.enroll(current, choice: .newProfile) }
        #expect(try Data(contentsOf: profiles.databaseURL) == bytes)
        try await f.store.close()
    }

    @Test func automaticAssignmentsAndMissingAudioCannotSupplyEnrollmentEvidence() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url), model = EnrollmentInference()
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: model)
        let confirmed = try await f.confirm().confirmation
        let automatic = SpeakerAssignment(id: confirmed.assignment.id, meetingID: f.meeting.id, dayID: f.speaker.dayID,
            daySpeakerID: f.speaker.id, name: "Alex", origin: .automatic(profileID: UUID(), profileRevision: UUID(), similarity: 1, margin: 1, calibrationVersion: "fixture"),
            evidence: confirmed.assignment.evidence)
        let forged = VoiceEnrollmentConfirmation(library: f.library, speakerID: f.speaker.id, assignment: automatic,
            recordings: confirmed.recordings, revisions: confirmed.revisions)
        await #expect(throws: VoiceEnrollmentError.changed) { try await service.enroll(forged, choice: .newProfile) }
        #expect(await model.activityCalls == 0)
        let chunk = try #require(f.recording.chunks.first { $0.track == .system })
        try FileManager.default.removeItem(at: f.library.directory.appendingPathComponent(chunk.file.value))
        await #expect(throws: (any Error).self) { try await service.enroll(confirmed, choice: .newProfile) }
        #expect(try await profiles.profiles().isEmpty)
        #expect(try await f.store.speakerAssignments(meetingID: f.meeting.id)[0].name == "Alex")
        try await f.store.close()
    }

    @Test @MainActor func unreadableProfileRegistryStillAllowsOrdinaryAndOptInLocalNames() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        try FileManager.default.createDirectory(at: profiles.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("foreign database".utf8).write(to: profiles.databaseURL)
        let p = MeetingTranscriptPresentation(store: f.store, meetingID: f.meeting.id,
            enrollment: VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference()))
        await p.beginRename(recordingID: f.recording.id, segmentID: f.revision.segments[0].id)
        #expect(p.profileLoadError != nil)
        p.draftName = "Local Alex"; await p.saveRename()
        #expect(p.snapshot?.assignments[0].name == "Local Alex" && p.renameTarget == nil)
        await p.beginRename(recordingID: f.recording.id, segmentID: f.revision.segments[0].id)
        p.draftName = "Still local"; p.rememberVoice = true; await p.saveRename()
        #expect(p.snapshot?.assignments[0].name == "Still local")
        #expect(p.noticeMessage?.contains("Voice was not remembered") == true)
        #expect(try Data(contentsOf: profiles.databaseURL) == Data("foreign database".utf8))
        try await f.store.close()
    }

    @Test @MainActor func cancellingRememberingKeepsLocalNameAndNoProfile() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url), model = EnrollmentInference()
        await model.setDelay(true)
        let p = MeetingTranscriptPresentation(store: f.store, meetingID: f.meeting.id,
            enrollment: VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: model))
        await p.beginRename(recordingID: f.recording.id, segmentID: f.revision.segments[0].id)
        p.draftName = "Alex"; p.rememberVoice = true
        let task = Task { await p.saveRename() }
        while await model.activityCalls == 0 { await Task.yield() }
        #expect(p.isRemembering && p.isBusy)
        p.cancelRemembering(); await task.value
        #expect(p.noticeMessage?.contains("cancelled") == true && p.snapshot?.assignments[0].name == "Alex")
        #expect(!p.isBusy && !p.isRemembering && p.renameTarget == nil)
        #expect(try await profiles.profiles().isEmpty)
        try await f.store.close()
    }

    @Test func renameDuringModelWorkRejectsEnrollmentAtRevalidation() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url), model = EnrollmentInference()
        await model.setDelay(true)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: model), confirmation = try await f.confirm().confirmation
        let task = Task { try await service.enroll(confirmation, choice: .newProfile) }
        while await model.activityCalls == 0 { await Task.yield() }
        _ = try await f.confirm("Changed")
        await model.setDelay(false)
        await #expect(throws: VoiceEnrollmentError.changed) { try await task.value }
        #expect(try await profiles.profiles().isEmpty)
        try await f.store.close()
    }

    @Test @MainActor func profileCommitFailureRollsBackRevisionAndKeepsTheNewDayName() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let first = try await service.enroll(f.confirm().confirmation, choice: .newProfile)
        let db = try SQLiteConnection(path: "/" + DirectoryHandle.physicalComponents(profiles.databaseURL).dropFirst().joined(separator: "/"))
        try db.execute("CREATE TRIGGER fail_profile BEFORE UPDATE ON profiles BEGIN SELECT RAISE(ABORT, 'injected profile write'); END")
        let p = MeetingTranscriptPresentation(store: f.store, meetingID: f.meeting.id, enrollment: service)
        await p.beginRename(recordingID: f.recording.id, segmentID: f.revision.segments[0].id)
        p.draftName = "Local survives"; p.rememberVoice = true; p.selectedProfileID = first.id; await p.saveRename()
        #expect(p.snapshot?.assignments[0].name == "Local survives")
        #expect(p.noticeMessage?.contains("injected profile write") == true)
        #expect(try await profiles.profiles() == [first])
        #expect(try db.integer("SELECT count(*) FROM revisions") == 1)
        try db.execute("DROP TRIGGER fail_profile")
        try await f.store.close()
    }

    @Test func staleProfileSelectionAndIncompatibleVersionDoNotUpdate() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let first = try await service.enroll(f.confirm().confirmation, choice: .newProfile)
        let second = try await service.enroll(f.confirm().confirmation, choice: .existing(profileID: first.id, revisionID: first.revisionID))
        let confirmation = try await f.confirm().confirmation
        await #expect(throws: VoiceEnrollmentError.changed) {
            try await service.enroll(confirmation, choice: .existing(profileID: first.id, revisionID: first.revisionID))
        }
        let db = try SQLiteConnection(path: "/" + DirectoryHandle.physicalComponents(profiles.databaseURL).dropFirst().joined(separator: "/"))
        var row = try #require(try db.rows("SELECT payload FROM revisions WHERE id=?", [.text(second.revisionID.uuidString)]).first)
        guard case .blob(let data) = row.removeFirst() else { Issue.record("Missing revision"); return }
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var value = try #require(object["value"] as? [String: Any])
        value["preprocessingVersion"] = "incompatible"
        object["value"] = value
        try db.execute("UPDATE revisions SET payload=? WHERE id=?", [.blob(JSONSerialization.data(withJSONObject: object)), .text(second.revisionID.uuidString)])
        await #expect(throws: VoiceEnrollmentError.incompatibleModels) {
            try await service.enroll(confirmation, choice: .existing(profileID: second.id, revisionID: second.revisionID))
        }
        #expect(try await profiles.profiles() == [second])
        try await f.store.close()
    }

    @Test func profilePathsRejectSymlinksAndFutureSchemaIsByteIdentical() async throws {
        await #expect(throws: (any Error).self) {
            try await VoiceProfileStore(home: URL(string: "https://example.invalid/fixture-home")!).profiles()
        }
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        _ = try await service.enroll(f.confirm().confirmation, choice: .newProfile)
        let db = try SQLiteConnection(path: "/" + DirectoryHandle.physicalComponents(profiles.databaseURL).dropFirst().joined(separator: "/"))
        try db.execute("PRAGMA user_version = 999")
        let before = try Data(contentsOf: profiles.databaseURL)
        await #expect(throws: StoreError.unsupportedSchema(999)) { try await profiles.profiles() }
        #expect(try Data(contentsOf: profiles.databaseURL) == before)
        let outside = try TemporaryFolder(); defer { outside.remove() }
        try FileManager.default.createSymbolicLink(at: outside.url.appendingPathComponent("Library"), withDestinationURL: root.url.appendingPathComponent("Library"))
        await #expect(throws: (any Error).self) { try await VoiceProfileStore(home: outside.url).profiles() }
        #expect(try Data(contentsOf: profiles.databaseURL) == before)
        try await f.store.close()
    }

    @Test func exportNativeProfileFixture() async throws {
        let root = try TemporaryFolder(), export = ProcessInfo.processInfo.environment["TALKTRACK_VOICE_PROFILE_FIXTURE"]
        defer { if export == nil { root.remove() } }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url.appendingPathComponent("fixture-home"))
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        _ = try await service.enroll(f.confirm("Existing Alex").confirmation, choice: .newProfile)
        try await f.store.close()
        if let export {
            let short = try await enrollmentFixture(root.url, seconds: 3)
            try await short.store.close()
            struct Config: Encodable { let root: String; let meetingIDs: [UUID]; let syntheticVoiceEvidence: Bool }
            let url = URL(fileURLWithPath: export)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Config(root: root.url.path, meetingIDs: [f.meeting.id, short.meeting.id], syntheticVoiceEvidence: true)).write(to: url, options: .atomic)
        }
    }

    /// Remembering from named fragments uses only those fragments' speech, and
    /// one key per person and meeting day (guided-speaker-labeling 6.3).
    @Test func rememberingFromFragmentsUsesOnlyTheirSpeech() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, pieces: 3), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let first = try await f.store.nameFragmentWithConfirmation(meetingID: f.meeting.id, recordingID: f.recording.id,
            segmentIDs: [f.revision.segments[0].id], name: "Yuri")
        #expect(first.confirmation.fragments.count == 1)
        let both = try await f.store.nameFragmentWithConfirmation(meetingID: f.meeting.id, recordingID: f.recording.id,
            segmentIDs: [f.revision.segments[2].id], name: " yuri ")
        #expect(both.confirmation.fragments.count == 2 && both.confirmation.speakerID == first.confirmation.speakerID)
        #expect(both.confirmation.speakerID != f.speaker.id)
        let profile = try await service.enroll(both.confirmation, choice: .newProfile)
        let revision = try #require(try await profiles.revision(profile.revisionID))
        let middle = f.revision.segments[1].interval
        #expect(revision.samples.allSatisfy { $0.interval.end <= middle.start || $0.interval.start >= middle.end })
        #expect(revision.samples.contains { $0.interval.start >= middle.end })
        #expect(revision.daySpeakerID == both.confirmation.speakerID && profile.name == "yuri")
        // A removed fragment invalidates its pending confirmation.
        _ = try await f.store.removeFragmentName(meetingID: f.meeting.id, recordingID: f.recording.id, segmentIDs: [f.revision.segments[0].id])
        await #expect(throws: VoiceEnrollmentError.changed) { try await service.enroll(both.confirmation, choice: .newProfile) }
        try await f.store.close()
    }
}
