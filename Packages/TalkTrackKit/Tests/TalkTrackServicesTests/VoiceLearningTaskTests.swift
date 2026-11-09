import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// background-voice-learning tasks 1.1–1.3 and 2.3: durable learning tasks,
/// the runner, and review of mismatching speech.
actor LearningInference: SystemSpeakerInference {
    var voice: Int
    var delay = false
    var activityCalls = 0
    /// The first this many segmentation calls report two voices (no clean speech).
    var mixedCalls = 0
    init(voice: Int = 0, mixedCalls: Int = 0) { self.voice = voice; self.mixedCalls = mixedCalls }
    func setDelay(_ value: Bool) { delay = value }
    func setVoice(_ value: Int) { voice = value }
    func speakerActivity(_ model: ModelSnapshot, samples: [Float]) async throws -> [SpeakerWindowActivity] {
        activityCalls += 1
        if delay { try await Task.sleep(for: .seconds(30)) }
        let range = try clusterRange(0, Double(samples.count) / 16_000)
        return [SpeakerWindowActivity(slot: 1, relative: range)] + (activityCalls <= mixedCalls ? [SpeakerWindowActivity(slot: 2, relative: range)] : [])
    }
    func speakerEmbedding(_ model: ModelSnapshot, samples: [Float]) async throws -> SpeakerWindowEmbedding {
        SpeakerWindowEmbedding(values: clusterVector(voice), model: model)
    }
}

@Suite struct VoiceLearningTaskTests {
    private func waitForCalls(_ model: LearningInference) async {
        while await model.activityCalls == 0 { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// 1.1: schema 4 registries migrate to 5 and keep their voices; newer refuse.
    @Test func schemaFiveMigratesFromFourAndRefusesNewer() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let alex = try await VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: LearningInference())
            .enroll(f.confirm().confirmation, choice: .newProfile)
        let path = "/" + DirectoryHandle.physicalComponents(profiles.databaseURL).dropFirst().joined(separator: "/")
        do {
            let db = try SQLiteConnection(path: path)
            try db.execute("DROP TABLE learning_tasks"); try db.execute("PRAGMA user_version = 4")
        }
        #expect(try await VoiceProfileStore(home: root.url).learningTasks().isEmpty)
        #expect(try await VoiceProfileStore(home: root.url).profiles() == [alex])
        do { let db = try SQLiteConnection(path: path); #expect(try db.integer("PRAGMA user_version") == 5) }
        do { let db = try SQLiteConnection(path: path); try db.execute("PRAGMA user_version = 6") }
        await #expect(throws: StoreError.unsupportedSchema(6)) { try await VoiceProfileStore(home: root.url).learningTasks() }
        try await f.store.close()
    }

    /// 1.2/1.3: a Save stores a task and returns; the runner learns the voice once.
    @Test func learnRunsInTheBackgroundAndRecordsTheVoiceForUndo() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: LearningInference())
        let updates = await service.updates()
        let queued = try await service.learn(f.confirm("Alex").confirmation, choice: .newProfile)
        #expect(queued.state == .queued && queued.name == "Alex" && queued.meetingID == f.meeting.id)
        await service.waitUntilIdle()
        let task = try #require(try await profiles.learningTask(queued.id))
        let alex = try #require(try await profiles.profiles().first)
        #expect(task.state == .learned && task.created == alex && task.previous == nil && alex.name == "Alex")
        let revision = try #require(try await profiles.revision(alex.revisionID))
        #expect(revision.selectionVersion == VoiceProfileEnrollment.selectionVersion)
        #expect(revision.enrollmentPolicyVersion == VoiceEnrollmentPolicy.version)
        var states: [VoiceLearningState] = []
        for await update in updates { states.append(update.state); if update.state == .learned { break } }
        #expect(states == [.queued, .running, .learned])
        try await f.store.close()
    }

    /// 1.2: names changed before the task ran: it ends superseded, nothing learned.
    @Test func staleNamesSupersedeTheTask() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: LearningInference())
        await service.setCaptureActive(true)
        let task = try await service.learn(f.confirm("Alex").confirmation, choice: .newProfile)
        _ = try await f.confirm("Boris")
        await service.setCaptureActive(false); await service.waitUntilIdle()
        #expect(try await profiles.learningTask(task.id)?.state == .superseded)
        #expect(try await profiles.profiles().isEmpty)
        try await f.store.close()
    }

    /// Save waits for the outcome; during capture its task waits for Stop instead.
    @Test func learnNowReturnsTheOutcomeAndDefersDuringCapture() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: LearningInference())
        let done = try await service.learnNow(f.confirm("Alex").confirmation, choice: .newProfile)
        #expect(done.state == .learned)
        #expect(try await profiles.profiles().map(\.name) == ["Alex"])
        await service.setCaptureActive(true)
        let waiting = try await service.learnNow(f.confirm("Boris").confirmation, choice: .newProfile)
        #expect(waiting.state == .queued)
        await service.setCaptureActive(false); await service.waitUntilIdle()
        #expect(try await profiles.learningTask(waiting.id)?.state == .learned)
        try await f.store.close()
    }

    /// 1.3: capture interrupts the running task; it runs again after Stop, once.
    @Test func captureInterruptsAndRestartsTheTask() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url), model = LearningInference()
        await model.setDelay(true)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: model)
        let task = try await service.learn(f.confirm("Alex").confirmation, choice: .newProfile)
        await waitForCalls(model)
        await service.setCaptureActive(true); await service.waitUntilIdle()
        #expect(try await profiles.learningTask(task.id)?.state == .queued)
        #expect(try await profiles.profiles().isEmpty)
        await model.setDelay(false)
        await service.setCaptureActive(false); await service.waitUntilIdle()
        #expect(try await profiles.learningTask(task.id)?.state == .learned)
        #expect(try await profiles.profiles().count == 1)
        try await f.store.close()
    }

    /// 1.3: quitting leaves the task queued; a crash leaves it running; both learn at the next launch.
    @Test func quitAndCrashRunTheTaskAgainAtLaunch() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url), model = LearningInference()
        await model.setDelay(true)
        let first = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: model)
        let task = try await first.learn(f.confirm("Alex").confirmation, choice: .newProfile)
        await waitForCalls(model)
        await first.shutDown()
        #expect(try await profiles.learningTask(task.id)?.state == .queued)
        // A crash while running: the stored state is still running.
        try await profiles.updateLearningTask(task.id, from: [.queued]) { $0.state = .running }
        await model.setDelay(false)
        let next = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: model)
        await next.start(); await next.waitUntilIdle()
        #expect(try await profiles.learningTask(task.id)?.state == .learned)
        #expect(try await profiles.profiles().count == 1)
        // A learned confirmation never trains twice.
        await #expect(throws: VoiceLearningError.changed) { try await next.retry(task.id) }
        try await f.store.close()
    }

    /// 1.3/D6: a cancelled running task adds nothing even if its commit comes later.
    @Test func cancelWhileRunningAddsNothing() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url), model = LearningInference()
        await model.setDelay(true)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: model)
        let confirmation = try await f.confirm("Alex").confirmation
        let task = try await service.learn(confirmation, choice: .newProfile)
        await waitForCalls(model)
        try await service.cancel(task.id)
        await service.waitUntilIdle()
        #expect(try await profiles.learningTask(task.id)?.state == .cancelled)
        #expect(try await profiles.profiles().isEmpty)
        // A commit that raced the cancel is refused in its own transaction.
        let (segmentation, embedding) = try clusteringModels()
        let samples = try [0, 4].map { VoiceProfileSample(recordingID: f.recording.id, transcriptRevisionID: f.revision.id,
            dayID: f.speaker.dayID, interval: try clusterRange(Double($0), Double($0) + 4), vector: clusterVector(0)) } + [
            VoiceProfileSample(recordingID: f.recording.id, transcriptRevisionID: f.revision.id, dayID: f.speaker.dayID,
                               interval: try clusterRange(9, 13), vector: clusterVector(0))]
        await #expect(throws: VoiceLearningError.changed) {
            try await profiles.enroll(confirmation, choice: .newProfile, segmentation: segmentation, embedding: embedding,
                                      samples: samples, taskID: task.id)
        }
        #expect(try await profiles.profiles().isEmpty)
        try await f.store.close()
    }

    /// Too little speech is reported on the task; Retry runs it again.
    @Test func insufficientSpeechIsReportedAndRetried() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, seconds: 3), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: LearningInference())
        let task = try await service.learn(f.confirm("Alex").confirmation, choice: .newProfile)
        await service.waitUntilIdle()
        let stored = try #require(try await profiles.learningTask(task.id))
        #expect(stored.state == .insufficientSpeech && stored.message?.contains("10 seconds") == true)
        try await service.retry(task.id); await service.waitUntilIdle()
        #expect(try await profiles.learningTask(task.id)?.state == .insufficientSpeech)
        try await service.acknowledge(task.id)
        #expect(try await profiles.learningTask(task.id)?.acknowledged == true)
        try await f.store.close()
    }

    /// D6: Undo cancels a pending task and takes back a learned one.
    @Test func undoLearningCancelsPendingAndRemovesLearned() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: LearningInference())
        await service.setCaptureActive(true)
        let pending = try await service.learn(f.confirm("Alex").confirmation, choice: .newProfile)
        #expect(try await service.undoLearning(pending.id) == nil)
        #expect(try await profiles.learningTask(pending.id)?.state == .cancelled)
        await service.setCaptureActive(false)
        let learned = try await service.learn(f.confirm("Alex").confirmation, choice: .newProfile)
        await service.waitUntilIdle()
        #expect(try await profiles.profiles().count == 1)
        let undone = try #require(try await service.undoLearning(learned.id))
        #expect(undone.previous == nil && undone.created.name == "Alex")
        #expect(try await profiles.profiles().isEmpty)
        #expect(try await profiles.learningTask(learned.id)?.state == .cancelled)
        try await f.store.close()
    }

    /// 2.3: speech unlike the chosen saved voice is held; each answer.
    @Test func mismatchingSpeechAwaitsReviewAndEachAnswer() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let mark = try await VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: LearningInference(voice: 0))
            .enroll(f.confirm("Mark").confirmation, choice: .newProfile)
        var tasks: [UUID] = []
        var fixtures: [EnrollmentFixture] = []
        for index in 0..<3 {
            // A voice not yet in Mark's bank each time (an added one joins it).
            let q = try await enrollmentFixture(root.url); fixtures.append(q)
            let other = VoiceProfileEnrollment(store: q.store, profiles: profiles, inference: LearningInference(voice: 5 + index))
            let current = try #require(try await profiles.profiles().first { $0.id == mark.id })
            let task = try await other.learn(q.confirm("Mark").confirmation, choice: .existing(profileID: mark.id, revisionID: current.revisionID))
            await other.waitUntilIdle()
            let held = try #require(try await profiles.learningTask(task.id))
            #expect(held.state == .awaitingReview && held.review?.profileName == "Mark" && held.review!.score < held.review!.threshold)
            tasks.append(task.id)
            #expect(try await profiles.profiles().first { $0.id == mark.id }?.revisionID == current.revisionID)
            // Answer with this library's service.
            switch tasks.count {
            case 1:
                try await other.resolve(task.id, .add)
                #expect(try await profiles.profiles().first { $0.id == mark.id }?.revisionID != mark.revisionID)
                #expect(try await profiles.learningTask(task.id)?.state == .learned)
            case 2:
                try await other.resolve(task.id, .differentPerson(name: "Anna"))
                #expect(try await profiles.profiles().contains { $0.name == "Anna" })
                #expect(try await q.store.speakerAssignments(meetingID: q.meeting.id).contains { $0.name == "Mark" })
            default:
                let before = try await profiles.profiles()
                try await other.resolve(task.id, .dontRemember)
                #expect(try await profiles.profiles() == before)
                let done = try await profiles.learningTask(task.id)
                #expect(done?.state == .cancelled && done?.review == nil)
            }
        }
        // A matching confirmation is added without review.
        let r = try await enrollmentFixture(root.url); fixtures.append(r)
        let same = VoiceProfileEnrollment(store: r.store, profiles: profiles, inference: LearningInference(voice: 0))
        let current = try #require(try await profiles.profiles().first { $0.id == mark.id })
        let task = try await same.learn(r.confirm("Mark").confirmation, choice: .existing(profileID: mark.id, revisionID: current.revisionID))
        await same.waitUntilIdle()
        #expect(try await profiles.learningTask(task.id)?.state == .learned)
        try await f.store.close()
        for item in fixtures { try await item.store.close() }
    }

    /// 2.3: a saved voice with one sample is not compared.
    @Test func oneSampleBankIsNotReviewed() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), q = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let (segmentation, embedding) = try clusteringModels()
        let confirmation = try await f.confirm("Mark").confirmation
        let sample = VoiceProfileSample(recordingID: f.recording.id, transcriptRevisionID: f.revision.id, dayID: f.speaker.dayID,
                                        interval: try clusterRange(0, 8), vector: clusterVector(0))
        let correction = VoiceProfileSample(recordingID: f.recording.id, transcriptRevisionID: f.revision.id, dayID: f.speaker.dayID,
                                            interval: try clusterRange(9, 12), vector: clusterVector(0))
        let mark = try await profiles.enroll(confirmation, choice: .newProfile, segmentation: segmentation, embedding: embedding,
                                             samples: [sample, correction])
        // Exclude one so the bank holds a single sample.
        let samples = try await profiles.samples(of: mark)
        try await profiles.exclude([samples[0].key], from: mark)
        let other = VoiceProfileEnrollment(store: q.store, profiles: profiles, inference: LearningInference(voice: 5))
        let task = try await other.learn(q.confirm("Mark").confirmation, choice: .existing(profileID: mark.id, revisionID: mark.revisionID))
        await other.waitUntilIdle()
        let state = try await profiles.learningTask(task.id)?.state
        #expect(state != .awaitingReview)
        try await f.store.close(); try await q.store.close()
    }

    /// 1.2: fragment and correction requests rebuild from storage; a removed
    /// fragment supersedes its task.
    @Test func fragmentAndCorrectionRequestsRebuild() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, pieces: 3), profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: LearningInference())
        let both = try await f.store.nameFragmentWithConfirmation(meetingID: f.meeting.id, recordingID: f.recording.id,
            segmentIDs: [f.revision.segments[0].id, f.revision.segments[2].id], name: "Yuri")
        let task = try await service.learn(both.confirmation, choice: .newProfile)
        await service.waitUntilIdle()
        let yuri = try #require(try await profiles.learningTask(task.id)?.created)
        // A correction: one more named reply added to Yuri, short speech allowed.
        let one = try await f.store.nameFragmentWithConfirmation(meetingID: f.meeting.id, recordingID: f.recording.id,
            segmentIDs: [f.revision.segments[1].id], name: "Yuri")
        let correction = try await service.learn(one.confirmation, choice: .existing(profileID: yuri.id, revisionID: yuri.revisionID))
        await service.waitUntilIdle()
        #expect(try await profiles.learningTask(correction.id)?.state == .learned)
        // Removed before running: superseded.
        await service.setCaptureActive(true)
        let again = try await f.store.nameFragmentWithConfirmation(meetingID: f.meeting.id, recordingID: f.recording.id,
            segmentIDs: [f.revision.segments[0].id], name: "Zed")
        let stale = try await service.learn(again.confirmation, choice: .newProfile)
        _ = try await f.store.removeFragmentName(meetingID: f.meeting.id, recordingID: f.recording.id, segmentIDs: [f.revision.segments[0].id])
        await service.setCaptureActive(false); await service.waitUntilIdle()
        #expect(try await profiles.learningTask(stale.id)?.state == .superseded)
        try await f.store.close()
    }

    // MARK: Selection (2.1, 2.2)

    /// 2.1: a long speaker is analysed in a bounded number of windows and the
    /// samples still cover the whole of the speech.
    @Test func longSpeechAnalysesBoundedWindowsAcrossTheWhole() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, seconds: 300, pieces: 30), profiles = VoiceProfileStore(home: root.url)
        let model = LearningInference()
        let alex = try await VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: model)
            .enroll(f.confirm().confirmation, choice: .newProfile)
        let calls = await model.activityCalls
        #expect(calls <= 2 * VoiceProfileEvidenceReader.firstPassCandidates * VoiceEnrollmentPolicy.maximumSamples)
        #expect(calls < 30)
        let revision = try #require(try await profiles.revision(alex.revisionID))
        #expect(revision.samples.count == 8)
        #expect(revision.samples.contains { $0.interval.start.seconds < 40 } && revision.samples.contains { $0.interval.start.seconds > 260 })
        try await f.store.close()
    }

    /// 2.1: when the best candidates have no clean speech, reading continues.
    @Test func unusableBestCandidatesContinueThroughTheRest() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url, seconds: 120, pieces: 12), profiles = VoiceProfileStore(home: root.url)
        let model = LearningInference(mixedCalls: 10)
        let alex = try await VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: model)
            .enroll(f.confirm().confirmation, choice: .newProfile)
        #expect(await model.activityCalls > 10)
        #expect(try await profiles.revision(alex.revisionID)?.samples.isEmpty == false)
        try await f.store.close()
    }

    private func sample(_ vector: [Float], at start: Double, length: Double = 3) throws -> VoiceProfileSample {
        VoiceProfileSample(recordingID: UUID(), transcriptRevisionID: UUID(), dayID: UUID(),
                           interval: try clusterRange(start, start + length), vector: vector)
    }

    /// 2.2: a well-covered voice gains only its minimum; new conditions add more.
    @Test func bankAwareSelectionAddsOnlyWhatIsNew() throws {
        let bank = try (0..<6).map { try sample(clusterVector(0, second: 1, coefficient: Float($0) * 0.02), at: Double($0) * 4) }
        let covered = try (0..<10).map { try sample(clusterVector(0, second: 1, coefficient: 0.01 + Float($0) * 0.01), at: Double($0) * 6, length: 6) }
        let few = VoiceProfileEvidenceReader.selectAgainstBank(covered, bank: bank, correction: false)
        #expect(few.count == 2)
        let fresh = try (0..<10).map { try sample(clusterVector(2 + $0), at: Double($0) * 6, length: 6) }
        let many = VoiceProfileEvidenceReader.selectAgainstBank(fresh, bank: bank, correction: false)
        #expect(many.count == VoiceEnrollmentPolicy.maximumSamples)
        // A correction needs only one sample.
        #expect(VoiceProfileEvidenceReader.selectAgainstBank(Array(covered.prefix(3)), bank: bank, correction: true).count == 1)
    }

    /// 2.2: one clip unlike the rest is dropped.
    @Test func strayClipIsDropped() throws {
        let voice = try (0..<6).map { try sample(clusterVector(0, second: 1, coefficient: Float($0) * 0.05), at: Double($0) * 4) }
        let stray = try sample(clusterVector(9), at: 30)
        let kept = VoiceProfileEvidenceReader.withoutOutliers(voice + [stray])
        #expect(kept == voice)
        // Two clips cannot be judged.
        #expect(VoiceProfileEvidenceReader.withoutOutliers([voice[0], stray]).count == 2)
    }

    /// 2.4: a tight one-meeting bank asks only below the ceiling, so the same
    /// voice from another meeting is not sent to review; one sample cannot judge.
    @Test func reviewThresholdHasACeiling() throws {
        let tight = try (0..<6).map { try sample(clusterVector(0, second: 1, coefficient: Float($0) * 0.01), at: Double($0) * 4) }
        #expect(VoiceProfileEnrollment.bankReviewThreshold(tight) == VoiceProfileEnrollment.reviewCeiling)
        let spread = try (0..<6).map { try sample(clusterVector(0, second: 1 + $0, coefficient: 0.9), at: Double($0) * 4) }
        let threshold = try #require(VoiceProfileEnrollment.bankReviewThreshold(spread))
        #expect(threshold < VoiceProfileEnrollment.reviewCeiling)
        #expect(VoiceProfileEnrollment.bankReviewThreshold(Array(tight.prefix(1))) == nil)
    }
}

/// 3.2: the meeting's learning notices and review answers.
@Suite struct VoiceLearningPresentationTests {
    private static func fail(_ id: UUID, in profiles: VoiceProfileStore) async throws {
        _ = try await profiles.updateLearningTask(id, from: [.queued]) { $0.state = .failed; $0.message = "Models are missing." }
    }
    @Test @MainActor func meetingShowsReviewAndAnswersIt() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let mark = try await VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: LearningInference(voice: 0))
            .enroll(f.confirm("Mark").confirmation, choice: .newProfile)
        let q = try await enrollmentFixture(root.url)
        let service = VoiceProfileEnrollment(store: q.store, profiles: profiles, inference: LearningInference(voice: 7))
        let p = MeetingTranscriptPresentation(store: q.store, meetingID: q.meeting.id, enrollment: service)
        await p.refresh()
        let watcher = Task { await p.observeLearning() }
        defer { watcher.cancel() }
        await p.beginRename(recordingID: q.recording.id, segmentID: q.revision.segments[0].id)
        p.draftName = "Mark"; p.rememberVoice = true; p.selectedProfileID = mark.id
        await p.saveRename()
        // While pending, the Save's own notice names it; the list leaves it out.
        #expect(p.noticeMessage?.hasPrefix("Name saved for") == true)
        await service.waitUntilIdle()
        while p.learningTasks.first?.state != .awaitingReview { await Task.yield() }
        let held = try #require(p.learningNotices.first)
        #expect(p.learningNotices.count == 1)
        // With an outcome, the Save's notice no longer says it is learning.
        #expect(p.noticeMessage?.hasPrefix("Name saved for") == true && p.noticeMessage?.contains("Learning") == false)
        #expect(MeetingTranscriptPresentation.learningMessage(held).contains("does not sound like the saved voice Mark"))
        await p.resolveLearning(held.id, .dontRemember)
        #expect(p.learningNotices.isEmpty && p.errorMessage == nil)
        #expect(try await profiles.profiles().map(\.revisionID) == [mark.revisionID])
        // A failed task offers Retry and Dismiss; Dismiss removes it.
        let other = try await profiles.addLearningTask(VoiceLearningRequest(q.confirm("Mark").confirmation, choice: .newProfile))
        try await Self.fail(other.id, in: profiles)
        await p.retryLearning(UUID())   // unknown id: an error, the stored state is shown
        #expect(p.errorMessage != nil && p.learningTasks.contains { $0.id == other.id && $0.state == .failed })
        #expect(MeetingTranscriptPresentation.learningMessage(p.learningTasks.first { $0.id == other.id }!) == "Mark's voice was not remembered: Models are missing.")
        await p.dismissLearning(other.id)
        #expect(!p.learningTasks.contains { $0.id == other.id })
        try await f.store.close(); try await q.store.close()
    }

    @Test @MainActor func otherMeetingsTasksAreNotShown() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), q = try await enrollmentFixture(root.url)
        let profiles = VoiceProfileStore(home: root.url)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: LearningInference(voice: 0))
        let p = MeetingTranscriptPresentation(store: q.store, meetingID: q.meeting.id, enrollment: service)
        let watcher = Task { await p.observeLearning() }
        defer { watcher.cancel() }
        let task = try await service.learn(f.confirm("Alex").confirmation, choice: .newProfile)
        await service.waitUntilIdle()
        #expect(try await profiles.learningTask(task.id)?.state == .learned)
        await p.dismissLearning(UUID())
        #expect(p.learningTasks.isEmpty)
        try await f.store.close(); try await q.store.close()
    }
}

/// 3.3: Settings ▸ Speakers lists learning and counts reviews.
@Suite struct VoiceLearningSettingsTests {
    private static func fail(_ id: UUID, in profiles: VoiceProfileStore) async throws {
        _ = try await profiles.updateLearningTask(id, from: [.queued]) { $0.state = .insufficientSpeech }
    }

    @Test @MainActor func learningSectionListsPendingAndReviewWithBadge() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let mark = try await VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: LearningInference(voice: 0))
            .enroll(f.confirm("Mark").confirmation, choice: .newProfile)
        let q = try await enrollmentFixture(root.url)
        let service = VoiceProfileEnrollment(store: q.store, profiles: profiles, inference: LearningInference(voice: 7))
        let p = SavedSpeakersPresentation(store: profiles)
        let store = q.store
        p.meetingTitle = { id in try? await store.meeting(id).title }
        #expect(!p.canChangeLearning)
        p.attach(service)
        let held = try await service.learn(q.confirm("Mark").confirmation, choice: .existing(profileID: mark.id, revisionID: mark.revisionID))
        await service.waitUntilIdle()
        await p.reloadLearning()
        #expect(p.learning.map(\.id) == [held.id] && p.reviewCount == 1 && p.canChangeLearning)
        #expect(p.learningMeetings[q.meeting.id] == q.meeting.title)
        #expect(SavedSpeakersPresentation.learningStatus(p.learning[0]).contains("Sounds different from Mark"))
        // Don't Remember (cancel) leaves the list; a short task offers Retry until dismissed.
        await p.cancelLearning(p.learning[0])
        #expect(p.learning.isEmpty && p.reviewCount == 0)
        let short = try await profiles.addLearningTask(VoiceLearningRequest(q.confirm("Mark").confirmation, choice: .newProfile))
        try await Self.fail(short.id, in: profiles)
        await p.reloadLearning()
        #expect(p.learning.map(\.state) == [.insufficientSpeech])
        await p.dismissLearning(p.learning[0])
        #expect(p.learning.isEmpty)
        p.attach(nil)
        #expect(!p.canChangeLearning)
        try await f.store.close(); try await q.store.close()
    }
}
