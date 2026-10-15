import Foundation
import MLX
import TalkTrackDomain
import TalkTrackServices

public enum SpeakerAdapterError: Error, LocalizedError, Sendable {
    case configuration
    case invalidAudio
    case invalidOutput
    case notLoaded
    case busy
    case fftUnavailable

    public var errorDescription: String? {
        switch self {
        case .configuration: "Unsupported speaker checkpoint configuration. Repair the selected model."
        case .invalidAudio: "Provide finite mono 16 kHz audio of up to 10 seconds, with at least one second for a voice embedding."
        case .invalidOutput: "The speaker model returned invalid probabilities or an incompatible embedding. Retry processing."
        case .notLoaded: "Load the corresponding speaker model before processing."
        case .busy: "A speaker model operation is active. Wait for it to finish."
        case .fftUnavailable: "Audio analysis could not allocate an FFT plan. Free memory and retry."
        }
    }
}

public struct LocalSpeakerSegment: Sendable {
    /// Window-local slot, not a meeting/day speaker identity.
    public let slot: Int
    public let start: Double
    public let end: Double
}

public struct SpeakerEmbedding: Sendable {
    public let values: [Float]
    public let model: ModelSnapshot
}

public enum SpeakerConfigurationValidation {
    public static func validate(_ data: Data, adapter: ModelAdapter) throws {
        guard data.count < 65536, let c = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              c["sample_rate"] as? Int == 16000 else { throw SpeakerAdapterError.configuration }
        switch adapter {
        case .pyannoteSegmentation:
            guard c["model_type"] as? String == "pyannote-segmentation",
                  c["num_classes"] as? Int == 7, c["max_speakers"] as? Int == 3,
                  c["powerset_max_classes"] as? Int == 2, c["num_frames_per_chunk"] as? Int == 589,
                  c["chunk_duration"] as? Double == 10,
                  let sinc = c["sincnet"] as? [String: Any], sinc["n_filters"] as? [Int] == [80, 60, 60],
                  sinc["kernel_sizes"] as? [Int] == [251, 5, 5], sinc["strides"] as? [Int] == [10, 1, 1],
                  sinc["pool_sizes"] as? [Int] == [3, 3, 3],
                  let lstm = c["lstm"] as? [String: Any], lstm["hidden_size"] as? Int == 128,
                  lstm["num_layers"] as? Int == 4, lstm["bidirectional"] as? Bool == true,
                  let linear = c["linear"] as? [String: Any], linear["hidden_size"] as? Int == 128,
                  linear["num_layers"] as? Int == 2 else { throw SpeakerAdapterError.configuration }
        case .weSpeaker:
            guard c["model_type"] as? String == "wespeaker-resnet34-lm",
                  c["n_mels"] as? Int == 80, c["embedding_dim"] as? Int == 256,
                  c["layers"] as? [Int] == [3, 4, 6, 3], c["channels"] as? [Int] == [32, 64, 128, 256],
                  c["pooling_output_dim"] as? Int == 5120 else { throw SpeakerAdapterError.configuration }
        default: throw SpeakerAdapterError.configuration
        }
    }
}

/// Short, serialized MLX operations. Cross-window clustering and identity
/// decisions are deliberately left to the diarization/profile services.
public actor SpeakerInferenceAdapter {
    private var segmentation: SegmentationModel?
    private var embedding: WeSpeakerNetwork?
    private var extractor: MelFeatureExtractor?
    private var snapshot: ModelSnapshot?
    private var access: ModelLocalDirectory?
    private var loading = false

    public init() {}

    public func prepare(_ manifest: ModelManifest, context: ModelPreparationContext) async throws {
        guard !loading, access == nil else { throw SpeakerAdapterError.busy }
        loading = true
        defer { loading = false }
        try SpeakerConfigurationValidation.validate(try await context.read(RelativePath("config.json")), adapter: manifest.adapter)
        let local = try await context.localDirectory()
        if manifest.adapter == .pyannoteSegmentation {
            let model = SegmentationModel()
            try await SegmentationWeightLoader.loadWeights(model: model, from: local)
        } else {
            let model = WeSpeakerNetwork()
            try await WeSpeakerWeightLoader.loadWeights(model: model, from: local)
        }
        try Task.checkCancellation()
        Memory.clearCache()
    }

    public func load(_ manifest: ModelManifest, files: ModelDownloadFiles) async throws {
        guard !loading else { throw SpeakerAdapterError.busy }
        loading = true
        defer { loading = false }
        await clear()
        let local = try await files.acquireLocalModel(manifest)
        do {
            let url = try await local.validatedURL()
            try SpeakerConfigurationValidation.validate(Data(contentsOf: url.appendingPathComponent("config.json")), adapter: manifest.adapter)
            if manifest.adapter == .pyannoteSegmentation {
                let model = SegmentationModel()
                try await SegmentationWeightLoader.loadWeights(model: model, from: local)
                segmentation = model
            } else {
                let model = WeSpeakerNetwork()
                try await WeSpeakerWeightLoader.loadWeights(model: model, from: local)
                extractor = try MelFeatureExtractor()
                embedding = model
                snapshot = try manifest.snapshot(for: .embedding)
            }
            try Task.checkCancellation()
            access = local
        } catch {
            segmentation = nil; embedding = nil; extractor = nil; snapshot = nil
            await local.release()
            Memory.clearCache()
            throw error
        }
    }

    public func segment(samples: [Float]) throws -> [LocalSpeakerSegment] {
        try validate(samples, minimum: 1600)
        guard !loading, let segmentation else { throw SpeakerAdapterError.notLoaded }
        let duration = Double(samples.count) / 16000
        let padded = samples + [Float](repeating: 0, count: 160000 - samples.count)
        let posteriors = try segmentation(MLXArray(padded, [1, 1, 160000]))
        eval(posteriors)
        try Task.checkCancellation()
        guard posteriors.shape == [1, 589, 7] else { throw SpeakerAdapterError.invalidOutput }
        let probabilities = posteriors.asArray(Float.self)
        guard probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw SpeakerAdapterError.invalidOutput }
        let tracks = PowersetDecoder.hardSpeakerActivity(from: posteriors).asArray(Float.self)
        var result: [LocalSpeakerSegment] = []
        // SincNet: receptive field 991 samples, stride 270 samples. Use frame
        // centers +/- half a stride, and crop right-padding to original audio.
        for slot in 0..<3 {
            var start: Double?
            for frame in 0..<589 {
                let boundary = min(duration, max(0, Double(495 + frame * 270 - 135) / 16000))
                let active = tracks[frame * 3 + slot] > 0 && boundary < duration
                if active && start == nil { start = boundary }
                if !active, let began = start {
                    if boundary > began { result.append(LocalSpeakerSegment(slot: slot + 1, start: began, end: boundary)) }
                    start = nil
                }
            }
            if let began = start, duration > began { result.append(LocalSpeakerSegment(slot: slot + 1, start: began, end: duration)) }
        }
        return result.sorted { $0.start == $1.start ? $0.slot < $1.slot : $0.start < $1.start }
    }

    public func embed(samples: [Float]) throws -> SpeakerEmbedding {
        try validate(samples, minimum: 16000)
        guard !loading, let embedding, let extractor, let snapshot else { throw SpeakerAdapterError.notLoaded }
        let mel = try extractor.extract(samples)
        try Task.checkCancellation()
        let output = embedding(mel.expandedDimensions(axis: 0).expandedDimensions(axis: -1))
        eval(output)
        try Task.checkCancellation()
        guard output.shape == [1, 256] else { throw SpeakerAdapterError.invalidOutput }
        let values = output.asArray(Float.self)
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard values.allSatisfy(\.isFinite), norm.isFinite, abs(norm - 1) < 0.001 else { throw SpeakerAdapterError.invalidOutput }
        return SpeakerEmbedding(values: values, model: snapshot)
    }

    public func unload() async throws {
        guard !loading else { throw SpeakerAdapterError.busy }
        loading = true
        await clear()
        loading = false
    }

    private func clear() async {
        segmentation = nil; embedding = nil; extractor = nil; snapshot = nil
        let previous = access
        access = nil
        if let previous { await previous.release() }
        Memory.clearCache()
    }

    private func validate(_ samples: [Float], minimum: Int) throws {
        try Task.checkCancellation()
        guard (minimum...160000).contains(samples.count), samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
            throw SpeakerAdapterError.invalidAudio
        }
    }
}
