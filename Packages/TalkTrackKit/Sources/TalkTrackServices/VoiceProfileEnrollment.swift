import Dispatch
import Foundation
import TalkTrackDomain

private final class VoiceEnrollmentExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "local.talktrack.voice-enrollment", qos: .userInitiated)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

/// Uses the application's shared inference runtime. Reads at most ten seconds
/// of committed system AAC at a time; no PCM is saved in the global registry.
public actor VoiceProfileEnrollment {
    private nonisolated let executor = VoiceEnrollmentExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let store: SessionStore
    private let profiles: VoiceProfileStore
    private let evidenceReader: VoiceProfileEvidenceReader
    private var busy = false

    public init(store: SessionStore, profiles: VoiceProfileStore, inference: any SystemSpeakerInference) {
        self.store = store; self.profiles = profiles; evidenceReader = VoiceProfileEvidenceReader(inference: inference)
    }
    public func availableProfiles() async throws -> [VoiceProfile] { try await profiles.profiles() }
    public func availableSavedVoices(models: [ModelSnapshot]) async throws -> [SavedVoice] {
        let segmentation = models.filter { $0.role == .segmentation }, embedding = models.filter { $0.role == .embedding }
        guard segmentation.count == 1, embedding.count == 1 else { throw VoiceEnrollmentError.incompatibleModels }
        return try await profiles.savedVoices(segmentation: segmentation[0], embedding: embedding[0])
    }

    public func enroll(_ confirmation: VoiceEnrollmentConfirmation, choice: VoiceProfileChoice) async throws -> VoiceProfile {
        guard !busy else { throw VoiceEnrollmentError.busy }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        try await store.validateVoiceConfirmation(confirmation)
        let evidence = try await evidenceReader.read(library: confirmation.library, speakerID: confirmation.speakerID,
            recordings: confirmation.recordings, revisions: confirmation.revisions, selection: confirmation.selection,
            correction: VoiceEnrollmentPolicy.isCorrection(confirmation, choice))
        try Task.checkCancellation()
        try await store.validateVoiceConfirmation(confirmation)
        return try await profiles.enroll(confirmation, choice: choice, segmentation: evidence.segmentation, embedding: evidence.embedding, samples: evidence.samples)
    }

    static func suitablePCM(_ samples: [Float]) -> Bool { VoiceProfileEvidenceReader.suitablePCM(samples) }
    static func cleanIntervals(window: RecordingAudioWindow, activity: [SpeakerWindowActivity],
                               selected: [MediaInterval], other: [MediaInterval]) throws -> [MediaInterval] {
        try VoiceProfileEvidenceReader.cleanIntervals(window: window, activity: activity, selected: selected, other: other)
    }
}
