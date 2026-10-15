import Foundation
import TalkTrackDomain

/// Matching changes assignment metadata only, after final publication. It never
/// calls enrollment or writes the global profile registry. The application's
/// single inference runtime is shared with transcription and capture.
public actor VoiceProfileRecognition {
    private let store: SessionStore
    private let profiles: VoiceProfileStore
    private let reader: VoiceProfileEvidenceReader
    private let calibration: VoiceRecognitionCalibration?
    private let fromConfirmations: Bool
    private let speakerModels: (segmentation: ModelSnapshot, embedding: ModelSnapshot)?
    private let recognitionEnabled: @Sendable () -> Bool
    private var busy = false

    /// `calibrateFromConfirmations`: without a fixed `calibration`, derive one
    /// from the saved voices' confirmed history (the application's mode).
    public init(store: SessionStore, profiles: VoiceProfileStore, inference: any SystemSpeakerInference,
                calibration: VoiceRecognitionCalibration? = nil, calibrateFromConfirmations: Bool = false,
                speakerModels: (segmentation: ModelSnapshot, embedding: ModelSnapshot)? = nil,
                recognitionEnabled: @escaping @Sendable () -> Bool = { ProcessingPreferences.voiceRecognitionEnabled() }) {
        self.store = store; self.profiles = profiles
        reader = VoiceProfileEvidenceReader(inference: inference); self.calibration = calibration
        fromConfirmations = calibrateFromConfirmations; self.speakerModels = speakerModels
        self.recognitionEnabled = recognitionEnabled
    }

    public func recognize(meetingID: UUID, enabled: Bool? = nil) async throws -> VoiceRecognitionReport {
        guard !busy else { throw VoiceRecognitionError.busy }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        let source = try await store.voiceRecognitionSource(meetingID: meetingID)
        var decisions: [UUID: VoiceRecognitionDisposition] = [:]
        func report() -> VoiceRecognitionReport {
            VoiceRecognitionReport(assignments: [], decisions: source.speakers.map {
                VoiceRecognitionDecision(speakerID: $0.id, disposition: decisions[$0.id] ?? .uncalibrated)
            })
        }
        let allowed: @Sendable () -> Bool = { [recognitionEnabled] in enabled ?? recognitionEnabled() }
        guard allowed() else { for s in source.speakers { decisions[s.id] = .disabled }; return report() }
        // Do not decode audio or load any model without calibration authority.
        var loaded: [VoiceRecognitionProfile]?
        var derived = calibration
        // Corrected fragments leave the bank of the person they were wrongly named for.
        let corrections = try await store.voiceCorrections()
        if derived == nil, fromConfirmations {
            let current = try await profiles.recognitionProfiles(corrections: corrections)
            let models = try speakerModels ?? VoiceProfileStore.currentSpeakerModels()
            derived = VoiceProfileCalibrator.status(current, segmentation: models.segmentation, embedding: models.embedding).calibration
            loaded = current
        }
        guard let calibration = derived else { return report() }
        guard calibration.valid else { throw VoiceRecognitionError.invalidCalibration }
        let registry: [VoiceRecognitionProfile]
        if let loaded { registry = loaded } else { registry = try await profiles.recognitionProfiles(corrections: corrections) }
        guard !registry.isEmpty else { for s in source.speakers { decisions[s.id] = .noProfiles }; return report() }
        guard registry.contains(where: { $0.revision.segmentation == calibration.segmentation &&
            $0.revision.embedding == calibration.embedding && $0.revision.preprocessingVersion == calibration.preprocessingVersion &&
            $0.revision.enrollmentPolicyVersion == calibration.enrollmentPolicyVersion }) else {
            for s in source.speakers { decisions[s.id] = .incompatibleProfiles }; return report()
        }
        var proposals: [AutomaticVoiceMatch] = []
        // Include manual speakers in the conflict check without changing their
        // names. Two distinct coactive voices cannot independently claim one
        // profile just because both passed a per-speaker threshold.
        var claimed: [UUID: UUID] = [:]
        for assignment in source.snapshot.assignments {
            if case .automatic(let profileID, _, _, _, _) = assignment.origin {
                claimed[assignment.daySpeakerID] = profileID
            }
        }
        for speaker in source.speakers {
            try Task.checkCancellation()
            let prior = source.snapshot.assignments.first { $0.daySpeakerID == speaker.id }
            if case .automatic = prior?.origin { decisions[speaker.id] = .existingAutomaticName; continue }
            // A linked name comes from the user's own names; it is kept like one.
            let manual = prior?.origin == .manual || prior?.origin == .linked
            let revisions = source.snapshot.revisions.filter { $0.segments.contains { $0.track == .system && $0.speaker == .system(daySpeakerID: speaker.id) } }
            guard revisions.allSatisfy({ $0.kind == .final &&
                $0.modelRevisions.filter { $0.role == .segmentation } == [calibration.segmentation] &&
                $0.modelRevisions.filter { $0.role == .embedding } == [calibration.embedding] }) else {
                decisions[speaker.id] = manual ? .manualName : .incompatibleEvidence; continue
            }
            let recordings = source.snapshot.recordings.filter { r in revisions.contains { $0.recordingID == r.id } }
            let evidence: VoiceProfileEvidence
            do { evidence = try await reader.read(library: source.library, speakerID: speaker.id, recordings: recordings, revisions: revisions) }
            catch VoiceEnrollmentError.insufficientSpeech { decisions[speaker.id] = manual ? .manualName : .insufficientSpeech; continue }
            catch VoiceEnrollmentError.incompatibleModels { decisions[speaker.id] = manual ? .manualName : .incompatibleEvidence; continue }
            let evaluation = try VoiceProfileMatcher.evaluate(evidence, profiles: registry, calibration: calibration)
            decisions[speaker.id] = manual ? .manualName : evaluation.disposition
            guard let winner = evaluation.winner else { continue }
            claimed[speaker.id] = winner.profile.id
            guard !manual else { continue }
            let samples = try evidence.samples.map { sample in
                VoiceMatchSample(recordingID: sample.recordingID, transcriptRevisionID: sample.transcriptRevisionID,
                    dayID: sample.dayID, interval: sample.interval, embeddingSHA256: try VoiceProfileMatcher.fingerprint(sample))
            }
            let assignment = SpeakerAssignment(meetingID: meetingID, dayID: speaker.dayID, daySpeakerID: speaker.id,
                name: winner.profile.name, origin: .automatic(profileID: winner.profile.id, profileRevision: winner.revision.id,
                    similarity: evaluation.similarity, margin: evaluation.margin, calibrationVersion: calibration.version),
                evidence: samples.map { SpeechEvidence(recordingID: $0.recordingID, interval: $0.interval, embeddingFingerprint: $0.embeddingSHA256) })
            proposals.append(AutomaticVoiceMatch(assignment: assignment, profile: winner.profile,
                profileRevisionSHA256: try VoiceProfileMatcher.fingerprint(winner.revision), calibration: calibration,
                samples: samples, rankedProfiles: evaluation.ranked))
        }
        proposals.removeAll { proposal in
            let id = proposal.assignment.daySpeakerID
            let conflicts = claimed.contains { $0.key != id && $0.value == proposal.profile.id && source.coactive(id, $0.key) }
            if conflicts { decisions[id] = .simultaneousConflict }
            return conflicts
        }
        try Task.checkCancellation()
        guard allowed() else { for s in source.speakers { decisions[s.id] = .disabled }; return report() }
        // Even when no names are proposed, stale source must not be reported as
        // a completed review of the current transcript.
        if proposals.isEmpty { try await store.validateVoiceRecognitionSource(source); return report() }
        let ready = proposals
        let committed = try await profiles.withRecognitionSnapshot(registry, corrections: corrections) { [store] in
            guard allowed() else { throw VoiceRecognitionError.disabled }
            return try await store.commitAutomaticVoiceMatches(source: source, proposals: ready)
        }
        let current = try await store.speakerAssignments(meetingID: meetingID)
        for proposal in proposals where !committed.contains(where: { $0.id == proposal.id }) {
            let prior = current.first { $0.daySpeakerID == proposal.assignment.daySpeakerID }
            if case .automatic = prior?.origin { decisions[proposal.assignment.daySpeakerID] = .existingAutomaticName }
            else { decisions[proposal.assignment.daySpeakerID] = .manualName }
        }
        return VoiceRecognitionReport(assignments: committed, decisions: source.speakers.map {
            VoiceRecognitionDecision(speakerID: $0.id, disposition: decisions[$0.id] ?? .uncalibrated)
        })
    }
}
