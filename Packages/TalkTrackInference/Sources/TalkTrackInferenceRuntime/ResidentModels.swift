import Foundation
import MLXAudioSTT
import TalkTrackServices
import TalkTrackSpeakerMLX
import TalkTrackTextMLX

/// Background models kept loaded between consecutive requests of one job, so a
/// final transcription loads each model once instead of once per window/batch.
/// Called only inside the runtime's serial scheduler lane. Speech/speaker and
/// text models never stay resident together, which keeps peak memory at the
/// level of the per-request design plus the small speech cohort. The runtime
/// unloads everything before capture, removal or installation, and after a
/// short idle period, so loaded weights never outlive the work that uses them.
actor ResidentModels {
    static let idleSeconds: UInt64 = 20

    private var speech: [String: QwenSpeechAdapter] = [:]
    private var speakers: [String: SpeakerInferenceAdapter] = [:]
    private var text: (key: String, adapter: QwenTextAdapter)?
    private var generation = 0

    func speech(_ manifest: ModelManifest, files: ModelDownloadFiles) async throws -> QwenSpeechAdapter {
        let key = try Self.key(manifest)
        if let adapter = speech[key] { return adapter }
        try await unloadText()
        let adapter = QwenSpeechAdapter()
        try await adapter.load(manifest, files: files)
        speech[key] = adapter
        return adapter
    }

    func speaker(_ manifest: ModelManifest, files: ModelDownloadFiles) async throws -> SpeakerInferenceAdapter {
        let key = try Self.key(manifest)
        if let adapter = speakers[key] { return adapter }
        try await unloadText()
        let adapter = SpeakerInferenceAdapter()
        try await adapter.load(manifest, files: files)
        speakers[key] = adapter
        return adapter
    }

    func text(_ manifest: ModelManifest, files: ModelDownloadFiles, contextTokens: Int) async throws -> QwenTextAdapter {
        let key = try Self.key(manifest) + "#\(contextTokens)"
        if let text, text.key == key { return text.adapter }
        try await unloadAll()
        let adapter = QwenTextAdapter()
        try await adapter.load(manifest, files: files, contextTokens: contextTokens)
        text = (key, adapter)
        return adapter
    }

    /// Whether this exact installation is held loaded (and therefore ready).
    func holds(_ manifest: ModelManifest) throws -> Bool {
        let key = try Self.key(manifest)
        return speech[key] != nil || speakers[key] != nil || text?.key.hasPrefix(key + "#") == true
    }

    /// Drops a model whose request failed; its state is not trusted for reuse.
    func discard(_ manifest: ModelManifest) async {
        guard let key = try? Self.key(manifest) else { return }
        if let adapter = speech.removeValue(forKey: key) { try? await adapter.unload() }
        if let adapter = speakers.removeValue(forKey: key) { try? await adapter.unload() }
        if text?.key.hasPrefix(key + "#") == true { try? await unloadText() }
    }

    func unloadAll() async throws {
        var failure: (any Error)?
        for adapter in speech.values { do { try await adapter.unload() } catch { failure = failure ?? error } }
        for adapter in speakers.values { do { try await adapter.unload() } catch { failure = failure ?? error } }
        speech.removeAll(); speakers.removeAll()
        do { try await unloadText() } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    /// Marks a finished request; returns the token an idle unload must match.
    func touch() -> Int {
        generation += 1
        return generation
    }

    func unloadIfIdle(since token: Int) async {
        guard token == generation else { return }
        try? await unloadAll()
    }

    var isEmpty: Bool { speech.isEmpty && speakers.isEmpty && text == nil }

    private func unloadText() async throws {
        guard let current = text else { return }
        text = nil
        try await current.adapter.unload()
    }

    private static func key(_ manifest: ModelManifest) throws -> String {
        try manifest.installationPath.value
    }
}
