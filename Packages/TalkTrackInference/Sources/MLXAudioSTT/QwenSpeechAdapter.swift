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
    private var parakeet: ParakeetModel?
    private var access: ModelLocalDirectory?
    private var loading = false

    public init() {}

    public func prepare(_ manifest: ModelManifest, context: ModelPreparationContext) async throws {
        guard !loading, asr == nil, aligner == nil, parakeet == nil else { throw QwenAdapterError.busy }
        loading = true
        defer { loading = false }
        if manifest.adapter == .parakeetTDT {
            let directory = try await context.localDirectory()
            _ = try await ParakeetModel.fromModelDirectory(directory)
            try Task.checkCancellation()
            Memory.clearCache()
            return
        }
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
        await clear()
        if manifest.adapter == .parakeetTDT {
            let directory = try await files.acquireLocalModel(manifest)
            do {
                parakeet = try await ParakeetModel.fromModelDirectory(directory)
                try Task.checkCancellation()
                access = directory
            } catch {
                parakeet = nil
                await directory.release()
                Memory.clearCache()
                throw error
            }
            return
        }
        let alignment = try isAlignment(manifest)
        let directory = try await files.acquireLocalModel(manifest)
        do {
            if alignment { aligner = try await Qwen3ForcedAlignerModel.fromModelDirectory(directory) }
            else { asr = try await Qwen3ASRModel.fromModelDirectory(directory) }
            try Task.checkCancellation()
            access = directory
        } catch {
            asr = nil; aligner = nil; parakeet = nil
            await directory.release()
            Memory.clearCache()
            throw error
        }
    }

    /// `context` is a system prompt of terms the model should prefer (dictation's
    /// dictionary); meeting transcription passes none, keeping its outputs unchanged.
    public func transcribe(samples: [Float], language: String? = nil, maxTokens: Int = 512, allowEmpty: Bool = false,
                           context: String = "") throws -> QwenTranscription {
        try validate(samples)
        if parakeet != nil {
            // Parakeet takes no prompt: the dictionary context and language are ignored.
            let result = try recognizeWords([samples])[0]
            guard allowEmpty || !result.text.isEmpty else { throw QwenAdapterError.invalidOutput }
            return QwenTranscription(text: result.text, language: nil, generatedTokens: result.words.count)
        }
        guard !loading, let asr else { throw QwenAdapterError.notLoaded }
        guard language == nil || asr.config.supportLanguages.contains(language!),
              (1...2048).contains(maxTokens) else { throw QwenAdapterError.invalidOutput }
        let output = try asr.generate(audio: MLXArray(samples), maxTokens: maxTokens,
            temperature: 0, context: context, language: language, chunkDuration: 30, minChunkDuration: 0.1,
            repetitionPenalty: 1.1)
        try Task.checkCancellation()
        guard allowEmpty || !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              output.generationTokens < maxTokens else { throw QwenAdapterError.invalidOutput }
        return QwenTranscription(text: output.text, language: output.language, generatedTokens: output.generationTokens)
    }

    /// Several windows in one decoder batch, with the same checks per window as
    /// `transcribe`. Windows longer than one 30 s chunk are refused.
    public func transcribeBatch(_ windows: [[Float]], language: String? = nil, maxTokens: Int = 512,
                                allowEmpty: Bool = false) throws -> [QwenTranscription] {
        for samples in windows {
            try validate(samples)
            guard samples.count <= 30 * 16000 else { throw QwenAdapterError.invalidOutput }
        }
        guard !loading, let asr else { throw QwenAdapterError.notLoaded }
        guard !windows.isEmpty, language == nil || asr.config.supportLanguages.contains(language!),
              (1...2048).contains(maxTokens) else { throw QwenAdapterError.invalidOutput }
        let outputs = try asr.generateBatch(audios: windows.map { MLXArray($0) }, maxTokens: maxTokens,
            language: language, repetitionPenalty: 1.1)
        try Task.checkCancellation()
        return try outputs.map { output in
            guard allowEmpty || !output.text.isEmpty, output.generationTokens < maxTokens else { throw QwenAdapterError.invalidOutput }
            return QwenTranscription(text: output.text, language: output.language, generatedTokens: output.generationTokens)
        }
    }

    /// Windows recognized together with the model's own word timings. Windows are
    /// at most 30 s; empty text is a valid answer (quiet or non-speech audio).
    public func recognizeWords(_ windows: [[Float]]) throws -> [ParakeetRecognition] {
        for samples in windows {
            try validate(samples)
            guard samples.count <= 30 * 16000 else { throw QwenAdapterError.invalidOutput }
        }
        guard !loading, let parakeet else { throw QwenAdapterError.notLoaded }
        guard !windows.isEmpty else { throw QwenAdapterError.invalidOutput }
        let results = try parakeet.recognize(audios: windows.map { MLXArray($0) })
        try Task.checkCancellation()
        let limits = windows.map { Double($0.count) / 16000 }
        return zip(results, limits).map { result, duration in
            // A word cut by the window end may be timed slightly past it; keep it inside.
            ParakeetRecognition(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                words: result.words.map { ParakeetWord(text: $0.text, start: min($0.start, duration), end: min($0.end, duration)) })
        }
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
        asr = nil; aligner = nil; parakeet = nil
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
