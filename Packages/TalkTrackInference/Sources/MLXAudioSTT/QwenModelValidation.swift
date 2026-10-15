import Foundation

public enum QwenAdapterError: Error, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case invalidAudio
    case invalidOutput
    case wrongRole
    case busy
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): "Unsupported Qwen configuration: \(detail). Repair the selected model."
        case .invalidAudio: "Provide a finite mono 16 kHz audio window between 0.1 and 30 seconds."
        case .invalidOutput: "The model returned incomplete text or invalid timing. Retry processing."
        case .wrongRole: "Select a Qwen speech model for this operation."
        case .busy: "The speech adapter is loading. Wait for that operation to finish."
        case .notLoaded: "Load the selected speech model before processing."
        }
    }
}

/// Reject absent/default-only configs and unsafe dimensions before any MLX
/// module constructors allocate arrays or evaluate their internal assertions.
public enum QwenModelValidation {
    public static func validate(_ data: Data, alignment: Bool) throws {
        _ = try decode(data, alignment: alignment)
    }

    static func decode(_ data: Data, alignment: Bool) throws -> Qwen3ASRConfig {
        guard data.count <= 4 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QwenAdapterError.invalidConfiguration("expected a JSON object")
        }
        let thinker: [String: Any]
        if let nested = root["thinker_config"] {
            guard let object = nested as? [String: Any] else { throw QwenAdapterError.invalidConfiguration("thinker_config") }
            thinker = object
        } else { thinker = root }
        guard let audio = thinker["audio_config"] as? [String: Any],
              let text = thinker["text_config"] as? [String: Any],
              ["d_model", "encoder_layers", "encoder_attention_heads", "output_dim"].allSatisfy({ audio[$0] != nil }),
              ["hidden_size", "num_hidden_layers", "num_attention_heads", "num_key_value_heads", "vocab_size"].allSatisfy({ text[$0] != nil }) else {
            throw QwenAdapterError.invalidConfiguration("missing architecture dimensions")
        }
        let config = try JSONDecoder().decode(Qwen3ASRConfig.self, from: data)
        let a = config.audioConfig, t = config.textConfig
        guard config.isForcedAligner == alignment,
              ["qwen3_asr", "qwen3_forced_aligner"].contains(config.modelType), t.modelType == "qwen3",
              a.numMelBins == 128, (1...32).contains(a.encoderLayers),
              (1...32).contains(a.encoderAttentionHeads), (128...2048).contains(a.dModel),
              a.dModel % 2 == 0, a.dModel % a.encoderAttentionHeads == 0,
              (128...8192).contains(a.encoderFfnDim), a.outputDim == t.hiddenSize,
              a.nWindow == 50, a.nWindowInfer == 800, a.convChunksize == 500,
              a.downsampleHiddenSize == 480, a.maxSourcePositions == 1500,
              a.activationFunction == "gelu",
              (128...2048).contains(t.hiddenSize), (128...8192).contains(t.intermediateSize),
              (1...32).contains(t.numHiddenLayers), (1...32).contains(t.numAttentionHeads),
              (1...16).contains(t.numKeyValueHeads), t.numAttentionHeads % t.numKeyValueHeads == 0,
              t.headDim == 128, (151677...200000).contains(t.vocabSize),
              (1024...131072).contains(t.maxPositionEmbeddings), t.hiddenAct == "silu",
              t.rmsNormEps.isFinite, t.rmsNormEps > 0, t.ropeTheta.isFinite, t.ropeTheta > 0,
              [config.audioTokenId, config.audioStartTokenId, config.audioEndTokenId].allSatisfy({ (0..<t.vocabSize).contains($0) }) else {
            throw QwenAdapterError.invalidConfiguration("unsupported audio/text dimensions or role")
        }
        // The pinned three checkpoints use affine 4/8-bit groups of 64. Reject
        // unknown quantizers before calling MLX's quantized layer constructors.
        if let raw = root["quantization"] {
            guard let q = raw as? [String: Any], q["group_size"] as? Int == 64,
                  [4, 8].contains(q["bits"] as? Int ?? 0), q["mode"] as? String == "affine",
                  Set(q.keys).isSubset(of: ["group_size", "bits", "mode"]), config.perLayerQuantization != nil else {
                throw QwenAdapterError.invalidConfiguration("quantization")
            }
        }
        if alignment {
            guard config.classifyNum == 5000, let token = config.timestampTokenId,
                  (0..<t.vocabSize).contains(token), config.timestampSegmentTime == 80 else {
                throw QwenAdapterError.invalidConfiguration("alignment timestamps")
            }
        }
        return config
    }
}
