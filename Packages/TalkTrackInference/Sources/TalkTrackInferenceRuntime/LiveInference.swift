import Foundation
import TalkTrackDomain
import TalkTrackServices

/// A capture lease is mandatory for every member of the live workload. Routing
/// speakers through the background bridge would wait until capture ends.
private struct CaptureLiveInference: LiveTranscriptionInference {
    let runtime: InferenceRuntime
    let capture: InferenceScheduler.CaptureLease
    func liveText(_ model: ModelSnapshot, samples: [Float], language: MeetingLanguage) async throws -> LiveASRResult {
        try await runtime.liveText(model, samples: samples, language: language, capture: capture)
    }
    func speakerActivity(_ model: ModelSnapshot, samples: [Float]) async throws -> [SpeakerWindowActivity] {
        try await runtime.liveActivity(model, samples: samples, capture: capture)
    }
    func speakerEmbedding(_ model: ModelSnapshot, samples: [Float]) async throws -> SpeakerWindowEmbedding {
        try await runtime.liveVector(model, samples: samples, capture: capture)
    }
}

extension InferenceRuntime {
    public func makeLiveSession(meetingID: UUID, recordingID: UUID, options: LiveTranscriptionOptions,
                                capture: InferenceScheduler.CaptureLease) async throws -> LiveTranscriptionSession {
        guard options.enabled else {
            return try LiveTranscriptionSession(meetingID: meetingID, recordingID: recordingID, options: options)
        }
        let catalog = try ModelCatalog.bundled()
        let models = try [ModelRole.liveASR, .segmentation, .embedding].map { try catalog.model(for: $0) }
        // Readiness is local and never starts a download. Run in the capture lane
        // so a stale capture lease cannot create a seemingly usable session.
        let ready = try await validateLiveModels(models, capture: capture)
        guard ready else {
            return try LiveTranscriptionSession(meetingID: meetingID, recordingID: recordingID, options: options)
        }
        return try LiveTranscriptionSession(meetingID: meetingID, recordingID: recordingID, options: options,
            asr: models[0].snapshot(for: .liveASR), segmentation: models[1].snapshot(for: .segmentation),
            embedding: models[2].snapshot(for: .embedding), inference: CaptureLiveInference(runtime: self, capture: capture))
    }
}
