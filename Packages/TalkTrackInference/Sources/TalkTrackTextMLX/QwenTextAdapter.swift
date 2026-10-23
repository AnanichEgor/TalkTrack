import Foundation
import Hub
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon
import Tokenizers
import TalkTrackDomain
import TalkTrackServices

public enum TextAdapterError: Error, LocalizedError {
    case configuration, busy, notLoaded, inputBudget, incompleteOutput, unfinishedReasoning
    public var errorDescription: String? {
        switch self {
        case .configuration: "The installed text model has an unsupported configuration. Reinstall the selected checkpoint."
        case .busy: "The text model is busy. Wait for the current operation to finish."
        case .notLoaded: "The text model is not loaded."
        case .inputBudget: "The complete formatted input and output reserve exceed this request's context budget. Split the source into smaller parts."
        case .incompleteOutput: "Text generation did not produce a complete response. The previous result has been preserved."
        case .unfinishedReasoning: "The model's reasoning did not finish within the output limit. The previous result has been preserved."
        }
    }
}

public struct TextGeneration: Sendable {
    /// The answer, without the model's reasoning.
    public let text: String
    /// The model's reasoning when it was requested, else nil.
    public var reasoning: String? = nil
    public let contextPlan: TextContextPlan
    public let promptTokens: Int
    public let generatedTokens: Int
    public let promptSeconds: Double
    public let generationSeconds: Double
}

public enum TextConfigurationValidation {
    @discardableResult
    public static func validate(_ data: Data) throws -> TextMemoryProfile {
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelType = root["model_type"] as? String else { throw TextAdapterError.configuration }
        if modelType == "qwen3" { return try validateQwen3Dense4B(root) }
        guard ["qwen3_5_moe", "qwen3_5"].contains(modelType),
              root["auto_map"] == nil,
              // Text-only conversions keep the text settings at the top level.
              let config = root["text_config"] == nil ? root : root["text_config"] as? [String: Any],
              let quant = root["quantization"] as? [String: Any],
              quant["bits"] as? Int == 4, quant["group_size"] as? Int == 64,
              quant["mode"] as? String == "affine" else { throw TextAdapterError.configuration }
        // Validate the supported immutable checkpoint before upstream allocation.
        var dimensions = ["hidden_size": 2048, "num_hidden_layers": 40,
            "num_attention_heads": 16, "num_key_value_heads": 2, "head_dim": 256,
            "vocab_size": 248320, "num_experts": 256, "num_experts_per_tok": 8,
            "moe_intermediate_size": 512, "shared_expert_intermediate_size": 512,
            "linear_conv_kernel_dim": 4, "linear_key_head_dim": 128,
            "linear_num_key_heads": 16, "linear_num_value_heads": 32,
            "linear_value_head_dim": 128, "full_attention_interval": 4,
            "max_position_embeddings": 262144]
        // REAP-pruned 35B-A3B derivatives keep 90 of the 256 experts; every other
        // dimension, and so the attention/KV memory profile, is unchanged.
        if modelType == "qwen3_5_moe", config["num_experts"] as? Int == 90 { dimensions["num_experts"] = 90 }
        var dense4B = false
        if modelType == "qwen3_5" {
            for key in ["num_experts", "num_experts_per_tok", "moe_intermediate_size", "shared_expert_intermediate_size"] {
                dimensions.removeValue(forKey: key)
            }
            // 9B, or 4B (narrower layers; the same attention layout, so the same KV per token).
            dense4B = config["hidden_size"] as? Int == 2560
            dimensions["hidden_size"] = dense4B ? 2560 : 4096; dimensions["num_hidden_layers"] = 32
            dimensions["num_key_value_heads"] = 4; dimensions["intermediate_size"] = dense4B ? 9216 : 12288
            guard config["num_experts"] == nil else { throw TextAdapterError.configuration }
        }
        guard dimensions.allSatisfy({ config[$0.key] as? Int == $0.value }),
              config["hidden_act"] as? String == "silu" else { throw TextAdapterError.configuration }
        for (path, value) in quant where !["bits", "group_size", "mode"].contains(path) {
            if let skipped = value as? Bool, !skipped { continue }
            guard let layer = value as? [String: Any], let bits = layer["bits"] as? Int,
                  [4, 8].contains(bits), layer["group_size"] as? Int == 64,
                  layer["mode"] == nil || layer["mode"] as? String == "affine" else {
                throw TextAdapterError.configuration
            }
        }
        return modelType == "qwen3_5" ? (dense4B ? .qwen35Dense4B : .qwen35Dense9B) : .qwen36MoE35B
    }

    /// Qwen/Qwen3-4B-MLX-4bit, accepted for model comparison only.
    private static func validateQwen3Dense4B(_ root: [String: Any]) throws -> TextMemoryProfile {
        let dimensions = ["hidden_size": 2560, "num_hidden_layers": 36, "num_attention_heads": 32,
            "num_key_value_heads": 8, "head_dim": 128, "intermediate_size": 9728,
            "vocab_size": 151936, "max_position_embeddings": 65536]
        guard root["auto_map"] == nil, dimensions.allSatisfy({ root[$0.key] as? Int == $0.value }),
              root["hidden_act"] as? String == "silu",
              let quant = root["quantization"] as? [String: Any], quant.count == 2,
              quant["bits"] as? Int == 4, quant["group_size"] as? Int == 128 else { throw TextAdapterError.configuration }
        return .qwen3Dense4B
    }
}

/// Token selection. Production uses greedy decoding; sampled settings exist
/// for measurement fixtures. Penalties apply in either case.
public struct TextSampling: Sendable, Equatable {
    public var temperature: Float = 0
    public var topP: Float = 1
    public var topK = 0
    public var minP: Float = 0
    public var repetitionPenalty: Float?
    public var presencePenalty: Float?
    /// Recent tokens the penalties look at (the library default is 20, shorter
    /// than one repeated summary line).
    public var penaltyContextSize = 20
    public var seed: UInt64 = 1
    public static let greedy = TextSampling()
    /// Summaries: on the task 7.1 review, temperature 0.2 with a repetition
    /// penalty stopped notes facts from becoming action items (0/18 runs over
    /// two seeds, against 5/9 greedy) without changing names or numbers.
    /// The fixed seed keeps a regenerated summary reproducible. Top-p 0.9 and
    /// top-k 40 (user choice, 2026-10-23) cut the tail of the distribution.
    /// Penalty 1.05 over the library's 20-token window let Qwen3.5-4B and then
    /// 9B repeat one Decisions line until the output limit on a real 22-minute
    /// Russian standup: one summary line is longer than the window. A 64-token
    /// window with penalty 1.1 ended every run; a longer window or a stronger
    /// penalty dropped the required citations.
    public static let summary: TextSampling = {
        var value = TextSampling(); value.temperature = 0.2; value.topP = 0.9; value.topK = 40
        value.repetitionPenalty = 1.1; value.penaltyContextSize = 64; value.seed = 1
        return value
    }()
    public init() {}

    var parameters: GenerateParameters {
        var value = GenerateParameters(temperature: temperature, topP: topP, prefillStepSize: 512)
        value.topK = topK; value.minP = minP; value.seed = seed
        value.repetitionPenalty = repetitionPenalty; value.presencePenalty = presencePenalty
        value.repetitionContextSize = penaltyContextSize; value.presenceContextSize = penaltyContextSize
        return value
    }
}

/// Background model owner. Heavy-job scheduling and measured admission policy
/// are layered above this bounded, single-request adapter.
public actor QwenTextAdapter {
    private var container: ModelContainer?
    private var access: ModelLocalDirectory?
    private var busy = false
    private var weightBytes: Int64 = 0
    private var memoryProfile: TextMemoryProfile = .qwen36MoE35B
    public init() {}

    public func prepare(_ manifest: ModelManifest, context: ModelPreparationContext) async throws {
        guard !busy, container == nil else { throw TextAdapterError.busy }
        busy = true
        defer { busy = false; Memory.clearCache() }
        guard manifest.adapter == .qwen3Text else { throw TextAdapterError.configuration }
        let profile = try TextConfigurationValidation.validate(try await context.read(RelativePath("config.json")))
        try TextMemoryAdmission.admit(weightBytes: manifest.weightByteCount, contextTokens: 32768,
            alreadyLoaded: false, memory: NativeMemorySnapshot.current(), profile: profile)
        _ = try await Self.loadLocal(try await context.localDirectory())
        try Task.checkCancellation()
    }

    public func load(_ manifest: ModelManifest, files: ModelDownloadFiles, contextTokens: Int = ContextLimit.defaultSelection.rawValue) async throws {
        guard !busy else { throw TextAdapterError.busy }
        busy = true
        defer { busy = false }
        guard manifest.adapter == .qwen3Text else { throw TextAdapterError.configuration }
        await clear()
        let directory = try await files.acquireLocalModel(manifest)
        do {
            let url = try await directory.validatedURL()
            let profile = try TextConfigurationValidation.validate(Data(contentsOf: url.appendingPathComponent("config.json")))
            try TextMemoryAdmission.admit(weightBytes: manifest.weightByteCount,
                contextTokens: contextTokens == 0 ? ContextLimit.tokens4K.rawValue : contextTokens,
                alreadyLoaded: false, memory: NativeMemorySnapshot.current(), profile: profile)
            container = try await Self.loadLocal(directory)
            try Task.checkCancellation()
            access = directory
            weightBytes = manifest.weightByteCount
            memoryProfile = profile
        } catch {
            container = nil
            await directory.release()
            Memory.clearCache()
            throw error
        }
    }

    private static func loadLocal(_ directory: ModelLocalDirectory) async throws -> ModelContainer {
        // MLX otherwise permits the free buffer pool to grow to its full
        // memory limit; unused buffers must not consume capture headroom.
        Memory.cacheLimit = min(Memory.cacheLimit, 512 * 1024 * 1024)
        Memory.clearCache()
        let url = try await directory.validatedURL()
        try TextConfigurationValidation.validate(Data(contentsOf: url.appendingPathComponent("config.json")))
        let model = try await LLMModelFactory.shared.loadContainer(from: url, using: LocalTokenizerLoader())
        try await model.perform { context in
            eval(context.model)
            _ = try context.tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Hello"]],
                tools: nil, additionalContext: ["enable_thinking": false])
        }
        return model
    }

    /// With `reasoning`, the model thinks before answering (Qwen3.5's thinking
    /// mode). Its reasoning counts against `maxTokens` and is returned apart
    /// from the answer; an answer that never ends its reasoning is incomplete.
    public func generate(system: String, prompt: String, contextTokens: Int = ContextLimit.defaultSelection.rawValue,
                         maxTokens: Int? = nil, role: ModelRole = .summary, reasoning: Bool = false,
                         sampling: TextSampling = .greedy) async throws -> TextGeneration {
        try Task.checkCancellation()
        guard !busy else { throw TextAdapterError.busy }
        guard let container else { throw TextAdapterError.notLoaded }
        guard let selection = ContextLimit(rawValue: contextTokens),
              !prompt.isEmpty, prompt.utf8.count + system.utf8.count <= 2_097_152 else {
            throw TextAdapterError.inputBudget
        }
        busy = true
        defer { busy = false }
        return try await container.perform { [weightBytes, memoryProfile] context in
            let tokens = try context.tokenizer.applyChatTemplate(messages: [
                ["role": "system", "content": system], ["role": "user", "content": prompt]],
                tools: nil, additionalContext: ["enable_thinking": reasoning])
            let plan = try TextContextPlanner.resolve(selection: selection, role: role,
                inputTokens: tokens.count, outputTokens: maxTokens)
            try TextMemoryAdmission.admit(weightBytes: weightBytes, contextTokens: plan.contextTokens,
                alreadyLoaded: true, memory: NativeMemorySnapshot.current(), profile: memoryProfile)
            try Task.checkCancellation()
            let iterator = try TokenIterator(input: LMInput(tokens: MLXArray(tokens)), model: CancellablePrefillModel(context.model),
                parameters: { var value = sampling.parameters; value.maxTokens = plan.outputTokens; return value }())
            let (stream, task) = generateTask(promptTokenCount: tokens.count,
                modelConfiguration: context.configuration, tokenizer: context.tokenizer, iterator: iterator)
            return try await withTaskCancellationHandler {
                var text = ""
                var completion: GenerateCompletionInfo?
                var toolOutput = false
                do {
                    for await event in stream {
                        try TextMemoryAdmission.checkDuringGeneration(NativeMemorySnapshot.current())
                        switch event {
                        case .chunk(let chunk): text += chunk
                        case .info(let info): completion = info
                        case .toolCall: toolOutput = true
                        }
                    }
                } catch {
                    task.cancel()
                    await task.value
                    throw error
                }
                // Await the producer, including GPU synchronization, before releasing a lease.
                await task.value
                try Task.checkCancellation()
                guard let info = completion, case .stop = info.stopReason,
                      !toolOutput, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw reasoning && !text.contains("</think>") ? TextAdapterError.unfinishedReasoning : TextAdapterError.incompleteOutput
                }
                var answer = text, thought: String?
                if reasoning {
                    // The template opens the reasoning; the model closes it before answering.
                    guard let end = text.range(of: "</think>") else { throw TextAdapterError.incompleteOutput }
                    thought = String(text[..<end.lowerBound]).replacingOccurrences(of: "<think>", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    answer = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !answer.isEmpty else { throw TextAdapterError.incompleteOutput }
                }
                return TextGeneration(text: answer, reasoning: thought, contextPlan: plan, promptTokens: info.promptTokenCount,
                    generatedTokens: info.generationTokenCount, promptSeconds: info.promptTime,
                    generationSeconds: info.generateTime)
            } onCancel: { task.cancel() }
        }
    }

    public func formattedTokenCount(system: String, prompt: String) async throws -> Int {
        guard !busy else { throw TextAdapterError.busy }
        guard let container else { throw TextAdapterError.notLoaded }
        return try await container.perform { context in
            try context.tokenizer.applyChatTemplate(messages: [
                ["role": "system", "content": system], ["role": "user", "content": prompt]],
                tools: nil, additionalContext: ["enable_thinking": false]).count
        }
    }

    /// Tokens of each text alone, without chat formatting or special tokens.
    public func tokenCounts(_ texts: [String]) async throws -> [Int] {
        guard !busy else { throw TextAdapterError.busy }
        guard let container else { throw TextAdapterError.notLoaded }
        return await container.perform { context in
            texts.map { context.tokenizer.encode(text: $0, addSpecialTokens: false).count }
        }
    }

    public func unload() async throws {
        guard !busy else { throw TextAdapterError.busy }
        busy = true
        await clear()
        busy = false
    }

    private func clear() async {
        container = nil
        weightBytes = 0
        let previous = access
        access = nil
        if let previous { await previous.release() }
        Memory.clearCache()
    }
}

private struct LocalTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory,
            hubApi: HubApi(downloadBase: directory, cache: nil, useOfflineMode: true))
        return LocalTokenizer(upstream: tokenizer)
    }
}

// Copyright © 2024 Apple Inc. (adapted portions below; MIT).
// Protocol bridge adapted from Apple's mlx-swift-lm 3.31.4
// TokenizerAdaptorMacro (MIT; ThirdParty licenses and source-provenance.json).
private struct LocalTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

// Adapted from Apple's MLXLLM/LLMModel.swift (MIT). The checkpoint loader and
// forward implementation remain upstream; this wrapper bounds cancellation
// latency to one evaluated prefill chunk instead of queuing the entire prompt.
private final class CancellablePrefillModel: Module, LanguageModel {
    let wrapped: any LanguageModel
    init(_ wrapped: any LanguageModel) { self.wrapped = wrapped }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { wrapped.newCache(parameters: parameters) }
    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        wrapped(input, cache: cache, state: state)
    }
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        let step = windowSize ?? 512
        var remaining = input.text
        try withPreparedCache(cache, lengths: remaining.sequenceLengths) {
            var state: LMOutput.State?
            while remaining.tokens.size > step {
                try Task.checkCancellation()
                try TextMemoryAdmission.checkDuringGeneration(NativeMemorySnapshot.current())
                let output = wrapped(remaining[.newAxis, ..<step], cache: cache, state: state)
                state = output.state
                eval(cache)
                remaining = remaining[step...]
            }
        }
        try Task.checkCancellation()
        return .tokens(remaining)
    }
}
