import Foundation
import MLXAudioSTT
import TalkTrackDomain
import TalkTrackServices
import TalkTrackSpeakerMLX

public struct LiveInferenceMetrics: Codable, Sendable {
    public var loadedRoles: [ModelRole] = []
    public var asrWindows = 0
    public var segmentationWindows = 0
    public var embeddings = 0
    public var largestInputFrames = 0
}

/// Only the three small live roles stay resident during one capture lease.
/// The runtime calls this owner exclusively inside its serial scheduler lane;
/// endCapture joins cleanup before admitting any background work/removal.
actor LiveCaptureModels {
    private let asr = QwenSpeechAdapter()
    private let segmentation = SpeakerInferenceAdapter()
    private let embedding = SpeakerInferenceAdapter()
    private var capture: InferenceScheduler.CaptureLease?
    private var snapshots: [ModelSnapshot] = []
    private(set) var metrics = LiveInferenceMetrics()

    func load(_ models: [ModelManifest], files: ModelDownloadFiles, capture: InferenceScheduler.CaptureLease) async throws {
        guard models.count == 3 else { throw LiveTranscriptionError.invalidModel }
        let snapshots = try zip(models, [ModelRole.liveASR, .segmentation, .embedding]).map { try $0.snapshot(for: $1) }
        if self.capture == capture, self.snapshots == snapshots { return }
        guard self.capture == nil else { throw InferenceSchedulingError.captureAlreadyRequested }
        do {
            try await asr.load(models[0], files: files)
            try await segmentation.load(models[1], files: files)
            try await embedding.load(models[2], files: files)
            try Task.checkCancellation()
            self.capture = capture; self.snapshots = snapshots
            metrics = LiveInferenceMetrics(loadedRoles: snapshots.map(\.role))
        } catch { try await unload(); throw error }
    }
    func text(_ model: ModelSnapshot, samples: [Float], language: MeetingLanguage,
              capture: InferenceScheduler.CaptureLease) async throws -> LiveASRResult {
        try validate(model, role: .liveASR, capture: capture)
        metrics.asrWindows += 1; metrics.largestInputFrames = max(metrics.largestInputFrames, samples.count)
        let result = try await asr.transcribe(samples: samples, language: language == .auto ? nil : language.title)
        return LiveASRResult(text: result.text, language: result.language)
    }
    func activity(_ model: ModelSnapshot, samples: [Float], capture: InferenceScheduler.CaptureLease) async throws -> [SpeakerWindowActivity] {
        try validate(model, role: .segmentation, capture: capture)
        metrics.segmentationWindows += 1; metrics.largestInputFrames = max(metrics.largestInputFrames, samples.count)
        return try await segmentation.segment(samples: samples).map {
            SpeakerWindowActivity(slot: $0.slot, relative: try MediaInterval(start: MediaTime(seconds: $0.start), end: MediaTime(seconds: $0.end)))
        }
    }
    func vector(_ model: ModelSnapshot, samples: [Float], capture: InferenceScheduler.CaptureLease) async throws -> SpeakerWindowEmbedding {
        try validate(model, role: .embedding, capture: capture)
        metrics.embeddings += 1; metrics.largestInputFrames = max(metrics.largestInputFrames, samples.count)
        let result = try await embedding.embed(samples: samples)
        return SpeakerWindowEmbedding(values: result.values, model: result.model)
    }
    func unload() async throws {
        try await asr.unload()
        try await segmentation.unload()
        try await embedding.unload()
        capture = nil; snapshots.removeAll()
        metrics.loadedRoles.removeAll()
    }
    private func validate(_ model: ModelSnapshot, role: ModelRole, capture: InferenceScheduler.CaptureLease) throws {
        guard self.capture == capture, model.role == role, snapshots.contains(model) else { throw LiveTranscriptionError.invalidModel }
    }
}
