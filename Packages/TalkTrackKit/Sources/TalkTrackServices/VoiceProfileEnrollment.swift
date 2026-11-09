import Dispatch
import Foundation
import TalkTrackDomain

private final class VoiceEnrollmentExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "local.talktrack.voice-enrollment", qos: .utility)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

/// Uses the application's shared inference runtime. Reads at most ten seconds
/// of committed system AAC at a time; no PCM is saved in the global registry.
///
/// Remembering is stored as durable tasks. A Save in the naming sheet waits for
/// its task (`learnNow`); imports queue theirs (`learn`). One task runs at a
/// time, capture pauses it and it starts again afterwards; quitting leaves it queued.
public actor VoiceProfileEnrollment {
    private nonisolated let executor = VoiceEnrollmentExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let store: SessionStore
    private let profiles: VoiceProfileStore
    private let evidenceReader: VoiceProfileEvidenceReader
    private var busy = false
    private var runner: Task<Void, Never>?
    private var runningID: UUID?
    private var needsDrain = false
    private var direct: Task<Void, Never>?
    private var directRunning = false
    private var captureActive = false
    private var stopped = false
    private var observers: [UUID: AsyncStream<VoiceLearningTask>.Continuation] = [:]

    /// Below the bank's own spread by this much, speech awaits review (D5, 2.4).
    static let reviewMargin = 0.05
    /// A bank from one meeting is tighter than the same voice across meetings:
    /// without a cap, 2 of 6 real repeat confirmations went to review, while
    /// wrong names scored at most 0.33 (2.4, docs/validation/background-voice-learning.md).
    static let reviewCeiling = 0.5
    /// The review threshold from the bank alone (before any calibration).
    static func bankReviewThreshold(_ bank: [VoiceProfileSample]) -> Double? {
        guard bank.count >= 2 else { return nil }
        let own = bank.indices.map { index in
            VoiceProfileMatcher.score([bank[index]], bank: bank.enumerated().filter { $0.offset != index }.map(\.element))
        }.min() ?? -1
        return min(own - reviewMargin, reviewCeiling)
    }
    static let selectionVersion = "ranked-bank-aware-v1"

    public init(store: SessionStore, profiles: VoiceProfileStore, inference: any SystemSpeakerInference) {
        self.store = store; self.profiles = profiles; evidenceReader = VoiceProfileEvidenceReader(inference: inference)
    }
    /// Undo of one Save's remembering (see VoiceProfileStore.undoEnrollment).
    public func undoEnrollment(created: VoiceProfile, previous: VoiceProfile?) async throws {
        try await profiles.undoEnrollment(created: created, previous: previous)
    }

    /// Removed reply names stop teaching saved voices (VoiceProfileStore.withdraw).
    public func withdraw(_ withdrawals: [VoiceWithdrawal]) async throws {
        try await profiles.withdraw(withdrawals)
    }

    public func availableSavedVoices(models: [ModelSnapshot]) async throws -> [SavedVoice] {
        let segmentation = models.filter { $0.role == .segmentation }, embedding = models.filter { $0.role == .embedding }
        guard segmentation.count == 1, embedding.count == 1 else { throw VoiceEnrollmentError.incompatibleModels }
        return try await profiles.savedVoices(segmentation: segmentation[0], embedding: embedding[0])
    }

    /// Learns at once and waits (fixtures and validation). Mismatching speech
    /// throws `VoiceLearningError.needsReview` and adds nothing.
    public func enroll(_ confirmation: VoiceEnrollmentConfirmation, choice: VoiceProfileChoice) async throws -> VoiceProfile {
        guard !busy else { throw VoiceEnrollmentError.busy }
        busy = true; defer { busy = false }
        return try await enrollNow(confirmation, choice: choice, taskID: nil)
    }

    private func enrollNow(_ confirmation: VoiceEnrollmentConfirmation, choice: VoiceProfileChoice, taskID: UUID?) async throws -> VoiceProfile {
        try Task.checkCancellation()
        try await store.validateVoiceConfirmation(confirmation)
        let correction = VoiceEnrollmentPolicy.isCorrection(confirmation, choice)
        // D4/D5: an existing voice's bank shapes the selection and is the reference for review.
        var bank: [VoiceProfileSample] = []
        if case .existing(let profileID, _) = choice {
            bank = try await profiles.recognitionProfiles().first { $0.profile.id == profileID }?.bank() ?? []
        }
        let evidence = try await evidenceReader.read(library: confirmation.library, speakerID: confirmation.speakerID,
            recordings: confirmation.recordings, revisions: confirmation.revisions, selection: confirmation.selection,
            correction: correction, bank: bank, filterOutliers: true)
        try Task.checkCancellation()
        try await store.validateVoiceConfirmation(confirmation)
        if case .existing(let profileID, _) = choice, bank.count >= 2,
           let profile = try await profiles.profiles().first(where: { $0.id == profileID }) {
            let score = VoiceProfileMatcher.score(evidence.samples, bank: bank)
            let threshold = try await reviewThreshold(bank: bank, segmentation: evidence.segmentation, embedding: evidence.embedding)
            if score < threshold {
                throw VoiceLearningError.needsReview(VoiceLearningReview(profileID: profileID, profileName: profile.name,
                    segmentation: evidence.segmentation, embedding: evidence.embedding, samples: evidence.samples,
                    score: score, threshold: threshold))
            }
        }
        return try await profiles.enroll(confirmation, choice: choice, segmentation: evidence.segmentation, embedding: evidence.embedding,
                                         samples: evidence.samples, selectionVersion: Self.selectionVersion, taskID: taskID)
    }

    /// Validation (2.4): what one confirmation's read selects with `tuning`,
    /// against `bank` when given, without storing anything.
    @_spi(Validation) public func measure(_ confirmation: VoiceEnrollmentConfirmation, bank: [VoiceProfileSample],
                                          tuning: VoiceLearningTuning) async throws -> VoiceLearningMeasurement {
        let started = Date()
        let evidence = try await evidenceReader.read(library: confirmation.library, speakerID: confirmation.speakerID,
            recordings: confirmation.recordings, revisions: confirmation.revisions, selection: confirmation.selection,
            correction: false, bank: bank, filterOutliers: true, tuning: tuning)
        let embedded = await evidenceReader.lastEmbedded
        return VoiceLearningMeasurement(seconds: Date().timeIntervalSince(started), windowsAnalyzed: await evidenceReader.lastWindowsAnalyzed,
            clipSeconds: await evidenceReader.lastClipSeconds, embedded: embedded, samples: evidence.samples,
            dropped: embedded.count - VoiceProfileEvidenceReader.withoutOutliers(embedded, margin: tuning.outlierMargin).count,
            score: bank.count >= 2 ? VoiceProfileMatcher.score(evidence.samples, bank: bank) : nil,
            bankThreshold: Self.bankReviewThreshold(bank))
    }
    /// What the last read analysed, also when it ended without enough speech.
    @_spi(Validation) public var lastRead: (windows: Int, clipSeconds: Double) {
        get async { (await evidenceReader.lastWindowsAnalyzed, await evidenceReader.lastClipSeconds) }
    }
    /// Selection from embedded clips with other constants (validation sweeps).
    @_spi(Validation) public nonisolated static func select(_ embedded: [VoiceProfileSample], bank: [VoiceProfileSample],
                                                            outlierMargin: Double, noveltyFloor: Double) -> [VoiceProfileSample] {
        let kept = VoiceProfileEvidenceReader.withoutOutliers(embedded, margin: outlierMargin)
        return bank.isEmpty ? kept : VoiceProfileEvidenceReader.selectAgainstBank(kept, bank: bank, correction: false, floor: noveltyFloor)
    }
    @_spi(Validation) public nonisolated static func outliers(_ embedded: [VoiceProfileSample], margin: Double) -> Int {
        embedded.count - VoiceProfileEvidenceReader.withoutOutliers(embedded, margin: margin).count
    }
    @_spi(Validation) public nonisolated static var reviewMarginValue: Double { reviewMargin }
    /// The matcher's score of `evidence` against `bank` (validation).
    @_spi(Validation) public nonisolated static func score(_ evidence: [VoiceProfileSample], bank: [VoiceProfileSample]) -> Double {
        VoiceProfileMatcher.score(evidence, bank: bank)
    }

    /// The bank's own weakest member against the rest, less a margin, at most
    /// `reviewCeiling`; an active calibration's threshold when that is lower.
    private func reviewThreshold(bank: [VoiceProfileSample], segmentation: ModelSnapshot, embedding: ModelSnapshot) async throws -> Double {
        var threshold = Self.bankReviewThreshold(bank) ?? -1
        if let calibration = try? await profiles.recognitionStatus(segmentation: segmentation, embedding: embedding).calibration {
            threshold = min(threshold, calibration.minimumSimilarity)
        }
        return threshold
    }

    static func suitablePCM(_ samples: [Float]) -> Bool { VoiceProfileEvidenceReader.suitablePCM(samples) }
    static func cleanIntervals(window: RecordingAudioWindow, activity: [SpeakerWindowActivity],
                               selected: [MediaInterval], other: [MediaInterval]) throws -> [MediaInterval] {
        try VoiceProfileEvidenceReader.cleanIntervals(window: window, activity: activity, selected: selected, other: other)
    }

    // MARK: Background learning (D1, D2)

    /// Save in the naming sheet: learns now, ahead of queued imports, and returns
    /// the outcome. During capture, which owns the inference lane, the task waits
    /// for Stop and comes back still pending. Cancelling the caller cancels it.
    public func learnNow(_ confirmation: VoiceEnrollmentConfirmation, choice: VoiceProfileChoice) async throws -> VoiceLearningTask {
        guard !captureActive, !stopped else { return try await learn(confirmation, choice: choice) }
        guard !directRunning else { throw VoiceEnrollmentError.busy }
        directRunning = true
        defer { directRunning = false; direct = nil; kick() }
        // A running import task goes back to the queue and restarts afterwards.
        if let current = runner { current.cancel(); await current.value }
        let stored = try await profiles.addLearningTask(VoiceLearningRequest(confirmation, choice: choice))
        publish(stored)
        guard !captureActive, !stopped else { return stored }
        let work = Task { await self.run(stored) }
        direct = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        if Task.isCancelled, let current = try? await profiles.learningTask(stored.id), current.state == .queued {
            return try await cancel(stored.id)
        }
        return try await profiles.learningTask(stored.id) ?? stored
    }

    /// Stores a learning task to run in turn (imports, and Save during capture).
    public func learn(_ confirmation: VoiceEnrollmentConfirmation, choice: VoiceProfileChoice) async throws -> VoiceLearningTask {
        let task = try await profiles.addLearningTask(VoiceLearningRequest(confirmation, choice: choice))
        publish(task)
        kick()
        return task
    }

    /// Queues learning for imported names: a saved voice with the same name is
    /// taught, otherwise a new one is made. The usual checks and reviews apply.
    public func learnImported(_ confirmations: [VoiceEnrollmentConfirmation]) async -> [VoiceLearningTask] {
        var tasks: [VoiceLearningTask] = []
        for confirmation in confirmations {
            let person = NamedSpeech.person(confirmation.assignment.name ?? "")
            let models = confirmation.revisions.first?.modelRevisions ?? []
            let voice = (try? await availableSavedVoices(models: models))?.first { NamedSpeech.person($0.profile.name) == person && !$0.needsNewSpeech }
            let choice: VoiceProfileChoice = voice.map { .existing(profileID: $0.profile.id, revisionID: $0.profile.revisionID) } ?? .newProfile
            if let task = try? await learn(confirmation, choice: choice) { tasks.append(task) }
        }
        return tasks
    }

    /// At launch: tasks interrupted by quitting run again.
    public func start() async {
        stopped = false
        try? await profiles.prepareLearningTasks()
        kick()
    }

    /// Recording pauses learning (the inference lane belongs to capture); the
    /// interrupted task starts again after Stop.
    public func setCaptureActive(_ active: Bool) {
        captureActive = active
        if active { runner?.cancel(); direct?.cancel() } else { kick() }
    }

    /// Quit: the running task stops and stays queued for the next launch.
    public func shutDown() async {
        stopped = true
        let current = runner, saving = direct
        current?.cancel(); saving?.cancel()
        await current?.value; await saving?.value
    }

    /// Until no task can run now (tests and validation).
    public func waitUntilIdle() async {
        while let current = runner { await current.value; if runner == current { break } }
    }

    public func tasks() async throws -> [VoiceLearningTask] { try await profiles.learningTasks() }

    /// Every change of a task, from now on.
    public func updates() -> AsyncStream<VoiceLearningTask> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func publish(_ task: VoiceLearningTask) { for observer in observers.values { observer.yield(task) } }

    /// Cancels a queued, running or held task; it adds nothing afterwards.
    @discardableResult
    public func cancel(_ id: UUID) async throws -> VoiceLearningTask {
        let task = try await profiles.updateLearningTask(id, from: [.queued, .running, .awaitingReview]) { $0.state = .cancelled }
        if runningID == id { needsDrain = true; runner?.cancel(); direct?.cancel() }
        publish(task)
        return task
    }

    /// A failed or short task runs again.
    public func retry(_ id: UUID) async throws {
        let task = try await profiles.updateLearningTask(id, from: [.failed, .insufficientSpeech]) {
            $0.state = .queued; $0.message = nil; $0.acknowledged = false
        }
        publish(task)
        kick()
    }

    /// The user saw a finished task; it leaves the notices.
    public func acknowledge(_ id: UUID) async throws {
        let task = try await profiles.updateLearningTask(id, from: [.learned, .insufficientSpeech, .failed, .cancelled, .superseded]) {
            $0.acknowledged = true
        }
        publish(task)
    }

    /// Undo of the Save that queued `id`: a pending task is cancelled; a learned
    /// one has its samples taken back. Returns the voice whose samples changed.
    public func undoLearning(_ id: UUID) async throws -> (created: VoiceProfile, previous: VoiceProfile?)? {
        guard let task = try await profiles.learningTask(id) else { return nil }
        if task.state.isPending {
            do { try await cancel(id); return nil }
            catch VoiceLearningError.changed { return try await undoLearning(id) }
        }
        guard task.state == .learned, let created = task.created else { return nil }
        try await profiles.undoEnrollment(created: created, previous: task.previous)
        let undone = try await profiles.updateLearningTask(id, from: [.learned]) { $0.state = .cancelled; $0.acknowledged = true }
        publish(undone)
        return (created, task.previous)
    }

    /// The answer to a review (D5). Adding or a new voice is an explicit confirmation.
    public func resolve(_ id: UUID, _ answer: VoiceReviewAnswer) async throws {
        guard let task = try await profiles.learningTask(id), task.state == .awaitingReview, let review = task.review else {
            throw VoiceLearningError.changed
        }
        if case .dontRemember = answer {
            publish(try await profiles.updateLearningTask(id, from: [.awaitingReview]) { $0.state = .cancelled; $0.acknowledged = true })
            return
        }
        guard let confirmation = try await store.voiceConfirmation(for: task.request) else { throw VoiceEnrollmentError.unavailable }
        do {
            switch answer {
            case .add:
                guard let profile = try await profiles.profiles().first(where: { $0.id == review.profileID }) else { throw VoiceEnrollmentError.changed }
                _ = try await profiles.enroll(confirmation, choice: .existing(profileID: profile.id, revisionID: profile.revisionID),
                    segmentation: review.segmentation, embedding: review.embedding, samples: review.samples,
                    selectionVersion: Self.selectionVersion, taskID: id)
            case .differentPerson(let name):
                _ = try await profiles.enroll(confirmation, choice: .newProfile, segmentation: review.segmentation, embedding: review.embedding,
                    samples: review.samples, selectionVersion: Self.selectionVersion, taskID: id, profileName: name)
            case .dontRemember: break
            }
        } catch VoiceEnrollmentError.changed {
            publish(try await profiles.updateLearningTask(id, from: [.awaitingReview]) { $0.state = .superseded })
            throw VoiceEnrollmentError.changed
        }
        if let learned = try await profiles.learningTask(id) { publish(learned) }
    }

    private func kick() {
        needsDrain = true
        guard runner == nil, !directRunning, !captureActive, !stopped else { return }
        runner = Task { await self.drain() }
    }

    private func drain() async {
        while needsDrain, !captureActive, !stopped, !Task.isCancelled {
            needsDrain = false
            while !captureActive, !stopped, !Task.isCancelled, let next = await nextQueued() {
                await run(next)
            }
        }
        runner = nil
        // A cancel (Undo) of the running task, or a task added meanwhile.
        if needsDrain { kick() }
    }

    private func nextQueued() async -> VoiceLearningTask? {
        let library = store.library.manifest.libraryID
        return (try? await profiles.learningTasks())?.first { $0.state == .queued && $0.request.libraryID == library }
    }

    private func run(_ queued: VoiceLearningTask) async {
        let id = queued.id
        guard let task = try? await profiles.updateLearningTask(id, from: [.queued], { $0.state = .running }) else { return }
        publish(task)
        runningID = id; defer { runningID = nil }
        var outcome: (VoiceLearningState, String?, VoiceLearningReview?)
        do {
            // nextQueued only picks tasks of the open library.
            guard let confirmation = try await store.voiceConfirmation(for: task.request) else { throw VoiceEnrollmentError.unavailable }
            _ = try await enrollNow(confirmation, choice: task.request.choice, taskID: id)
            if let learned = try? await profiles.learningTask(id) { publish(learned) }
            return
        } catch is CancellationError {
            outcome = (.queued, nil, nil)
        } catch VoiceLearningError.needsReview(let review) {
            outcome = (.awaitingReview, nil, review)
        } catch VoiceLearningError.changed {
            // Cancelled meanwhile (Undo): nothing to record.
            return
        } catch VoiceEnrollmentError.changed {
            outcome = (.superseded, nil, nil)
        } catch VoiceEnrollmentError.insufficientSpeech {
            outcome = (.insufficientSpeech, VoiceEnrollmentError.insufficientSpeech.localizedDescription, nil)
        } catch {
            outcome = (.failed, error.localizedDescription, nil)
        }
        if let updated = try? await profiles.updateLearningTask(id, from: [.running], {
            $0.state = outcome.0; $0.message = outcome.1; $0.review = outcome.2
        }) { publish(updated) }
    }
}

@_spi(Validation) public struct VoiceLearningMeasurement: Sendable {
    public let seconds: Double
    public let windowsAnalyzed: Int
    public let clipSeconds: Double
    /// Every embedded clip, before outliers were dropped.
    public let embedded: [VoiceProfileSample]
    public let samples: [VoiceProfileSample]
    public let dropped: Int
    public let score: Double?
    /// The review threshold from the bank alone (calibration may lower it).
    public let bankThreshold: Double?
}
