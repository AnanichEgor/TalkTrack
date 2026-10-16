import Foundation
import MLX
import TalkTrackDomain
import TalkTrackServices

public struct QwenTranscription: Sendable {
    public let text: String
    public let language: String?
    public let generatedTokens: Int
}

/// Owns non-Sendable MLX objects on a background actor. Input is a bounded mono
/// window; timeline mapping and orchestration belong to the processing pipeline.
public actor QwenSpeechAdapter {
    private var asr: Qwen3ASRModel?
    private var aligner: Qwen3ForcedAlignerModel?
    private var access: ModelLocalDirectory?
    private var loading = false

    public init() {}

    public func prepare(_ manifest: ModelManifest, context: ModelPreparationContext) async throws {
        guard !loading, asr == nil, aligner == nil else { throw QwenAdapterError.busy }
        loading = true
        defer { loading = false }
        let alignment = try isAlignment(manifest)
        try QwenModelValidation.validate(try await context.read(RelativePath("config.json")), alignment: alignment)
        try await QwenTokenizerPreparation.prepare(in: context)
        let directory = try await context.localDirectory()
        if alignment { _ = try await Qwen3ForcedAlignerModel.fromModelDirectory(directory) }
        else { _ = try await Qwen3ASRModel.fromModelDirectory(directory) }
        try Task.checkCancellation()
        Memory.clearCache()
        // The coordinator owns the preparation ticket and publishes readiness.
    }

    public func load(_ manifest: ModelManifest, files: ModelDownloadFiles) async throws {
        guard !loading else { throw QwenAdapterError.busy }
        loading = true
        defer { loading = false }
        let alignment = try isAlignment(manifest)
        await clear()
        let directory = try await files.acquireLocalModel(manifest)
        do {
            if alignment { aligner = try await Qwen3ForcedAlignerModel.fromModelDirectory(directory) }
            else { asr = try await Qwen3ASRModel.fromModelDirectory(directory) }
            try Task.checkCancellation()
            access = directory
        } catch {
            asr = nil; aligner = nil
            await directory.release()
            Memory.clearCache()
            throw error
        }
    }

    public func transcribe(samples: [Float], language: String? = nil, maxTokens: Int = 512, allowEmpty: Bool = false) throws -> QwenTranscription {
        try validate(samples)
        guard !loading, let asr else { throw QwenAdapterError.notLoaded }
        guard language == nil || asr.config.supportLanguages.contains(language!),
              (1...2048).contains(maxTokens) else { throw QwenAdapterError.invalidOutput }
        let output = try asr.generate(audio: MLXArray(samples), maxTokens: maxTokens,
            temperature: 0, language: language, chunkDuration: 30, minChunkDuration: 0.1,
            repetitionPenalty: 1.1)
        try Task.checkCancellation()
        guard allowEmpty || !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              output.generationTokens < maxTokens else { throw QwenAdapterError.invalidOutput }
        return QwenTranscription(text: output.text, language: output.language, generatedTokens: output.generationTokens)
    }

    public func align(samples: [Float], text: String, language: String) throws -> [ForcedAlignItem] {
        try validate(samples)
        guard !loading, let aligner else { throw QwenAdapterError.notLoaded }
        guard aligner.config.supportLanguages.contains(language), !text.isEmpty, text.utf8.count <= 8192 else { throw QwenAdapterError.invalidOutput }
        let result = try aligner.generate(audio: MLXArray(samples), text: text, language: language)
        try Task.checkCancellation()
        let duration = Double(samples.count) / 16000
        guard !result.items.isEmpty, result.items.allSatisfy({
            $0.startTime.isFinite && $0.endTime.isFinite && $0.startTime >= 0 &&
            $0.endTime >= $0.startTime && $0.endTime <= duration + Self.edgeOvershoot
        }) else { throw QwenAdapterError.invalidOutput }
        return Self.clamped(result.items, duration: duration)
    }

    /// A word cut by the window's end is timed past it (Daily 3: "приходилось"
    /// ended at 10.32 s in a 10 s window, which failed the whole transcription).
    /// Timings up to this far past the end are moved to it; later ones still fail.
    static let edgeOvershoot = 2.0

    static func clamped(_ items: [ForcedAlignItem], duration: Double) -> [ForcedAlignItem] {
        items.map { item in
            guard item.endTime > duration else { return item }
            return ForcedAlignItem(text: item.text, startTime: min(item.startTime, duration), endTime: duration)
        }
    }

    public func unload() async throws {
        guard !loading else { throw QwenAdapterError.busy }
        loading = true
        await clear()
        loading = false
    }

    private func clear() async {
        asr = nil; aligner = nil
        let previous = access
        access = nil
        if let previous { await previous.release() }
        Memory.clearCache()
    }

    private func validate(_ samples: [Float]) throws {
        try Task.checkCancellation()
        guard (1600...480000).contains(samples.count), samples.allSatisfy({ $0.isFinite && abs($0) <= 1.0 }) else {
            throw QwenAdapterError.invalidAudio
        }
    }

    private func isAlignment(_ manifest: ModelManifest) throws -> Bool {
        switch manifest.adapter {
        case .qwen3ASR: false
        case .qwen3Aligner: true
        default: throw QwenAdapterError.wrongRole
        }
    }
}
