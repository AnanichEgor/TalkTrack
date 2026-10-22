import Foundation
import MLXAudioSTT
import TalkTrackDomain
import TalkTrackServices
import TalkTrackSpeakerMLX
import TalkTrackTextMLX

/// Application-scoped entry point for model installation, execution and removal.
/// Every operation snapshots its manifest/settings before entering the serial
/// lane. No model object or local-directory capability escapes to the caller.
public final class InferenceRuntime: ModelInstallationControl, DictationInference {
    private let scheduler = InferenceScheduler()
    private let files = ModelDownloadFiles()
    private let downloads: ModelDownloadCoordinator
    private let catalog: ModelCatalog
    private let liveModels = LiveCaptureModels()
    private let residents = ResidentModels()
    private let dictation: DictationModelHolder<QwenSpeechAdapter>

    public init() throws {
        catalog = try ModelCatalog.bundled()
        downloads = ModelDownloadCoordinator(files: files)
        dictation = DictationModelHolder(load: { [catalog, files] id in
            let adapter = QwenSpeechAdapter()
            try await adapter.load(catalog.model(id: id), files: files)
            return adapter
        }, unload: { adapter in try? await adapter.unload() })
    }

    public func beginCapture() async throws -> InferenceScheduler.CaptureLease {
        let lease = try await scheduler.beginCapture()
        // Capture has priority over memory: resident job and dictation models leave first.
        do { try await scheduler.run(priority: .capture(lease)) { [residents, dictation] in
            await dictation.unloadAll()
            try await residents.unloadAll()
        } }
        catch { try? await scheduler.endCapture(lease); throw error }
        return lease
    }
    public func endCapture(_ lease: InferenceScheduler.CaptureLease) async throws {
        // Cleanup is joined even when Stop's caller was cancelled. No resident
        // live model or file capability may survive into background admission.
        let cleanup = Task.detached { [scheduler, liveModels] in
            try await scheduler.run(priority: .capture(lease)) { try await liveModels.unload() }
            try await scheduler.endCapture(lease)
        }
        try await cleanup.value
    }

    public func install(_ id: String) async throws {
        let manifest = try catalog.model(id: id)
        try await downloads.download(manifest) { [scheduler, residents] manifest, context in
            try await scheduler.run {
                try await residents.unloadAll()
                switch manifest.adapter {
                case .qwen3ASR, .qwen3Aligner:
                    try await QwenSpeechAdapter().prepare(manifest, context: context)
                case .pyannoteSegmentation, .weSpeaker:
                    try await SpeakerInferenceAdapter().prepare(manifest, context: context)
                case .qwen3Text:
                    try await QwenTextAdapter().prepare(manifest, context: context)
                }
            }
        }
    }

    public func remove(_ id: String) async throws {
        let manifest = try catalog.model(id: id)
        // Cancel preparation before queuing removal, avoiding a queue dependency
        // between deletion and a download waiting for its preparation turn.
        try await downloads.cancelAndWait(manifest)
        try await scheduler.run { [downloads, residents, dictation] in
            await dictation.unloadAll()
            try await residents.unloadAll()
            try await downloads.remove(manifest)
        }
    }

    public func status(_ id: String) async throws -> ModelDownloadProgress? {
        try await downloads.status(catalog.model(id: id))
    }

    /// Cancels an installation; verified partial files are kept for resume.
    public func cancelInstall(_ id: String) async throws {
        try await downloads.cancelAndWait(catalog.model(id: id))
    }

    /// Answers without queuing behind inference, so Settings stays responsive
    /// while a long job holds the lane.
    public func installState(_ id: String) async throws -> ModelInstallState {
        let manifest = try catalog.model(id: id)
        let progress = try await downloads.status(manifest)
        return try await ModelInstallState.resolve(progress: progress, busy: files.isBusy(manifest), ready: files.isReady(manifest))
    }

    public func liveMetrics() async -> LiveInferenceMetrics { await liveModels.metrics }

    // MARK: Dictation

    public func isInstalled(dictationModel id: String) async -> Bool {
        (try? await installState(id).isInstalled) ?? false
    }

    public func beginInteractive() async throws -> InferenceScheduler.InteractiveLease {
        try await scheduler.beginInteractive()
    }

    public func prepareDictation(modelID: String, lease: InferenceScheduler.InteractiveLease) async throws {
        try await scheduler.run(priority: .interactive(lease)) { [self] in
            try await withDictationModel(modelID) { _ in }
        }
    }

    /// Long audio is recognized in pieces of at most a minute, split where it
    /// is quietest, each with the dictionary as context.
    public func dictate(modelID: String, samples: [Float], language: MeetingLanguage, context: String,
                        lease: InferenceScheduler.InteractiveLease) async throws -> DictationRecognition {
        try await scheduler.run(priority: .interactive(lease)) { [self] in
            try await withDictationModel(modelID) { adapter in
                var texts: [String] = [], languages: [String] = []
                for piece in DictationAudio.pieces(samples) {
                    let result = try await adapter.transcribe(samples: Array(piece), language: language == .auto ? nil : language.title,
                        maxTokens: 1024, allowEmpty: true, context: context)
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { texts.append(text) }
                    if let detected = result.language { languages.append(detected) }
                }
                return DictationRecognition(text: texts.joined(separator: " "), language: languages.first)
            }
        }
    }

    public func endInteractive(_ lease: InferenceScheduler.InteractiveLease, idleMinutes: Int) async {
        try? await scheduler.endInteractive(lease)
        let token = await dictation.touch()
        Task.detached { [dictation] in
            try? await Task.sleep(for: .seconds(idleMinutes * 60))
            await dictation.unloadIfIdle(since: token)
        }
    }

    public func unloadDictation() async { await dictation.unloadAll() }

    /// A speech model already resident for a job is used as is instead of
    /// loading a second copy.
    private func withDictationModel<T: Sendable>(_ id: String, _ operation: @Sendable (QwenSpeechAdapter) async throws -> T) async throws -> T {
        let manifest = try catalog.model(id: id)
        if try await residents.holds(manifest) {
            return try await operation(residents.speech(manifest, files: files))
        }
        return try await dictation.use(id, operation)
    }

    func isInstalled(_ model: ModelSnapshot) async throws -> Bool {
        let manifest = try resolve(model)
        // Capture may hold installed speaker capabilities. Wait in the
        // background lane instead of misreporting leased weights as missing.
        return try await scheduler.run { [files, residents] in
            // A resident model holds its files, which reads as busy, not missing.
            if try await residents.holds(manifest) { return true }
            return try await files.isReady(manifest)
        }
    }

    func validateLiveModels(_ models: [ModelManifest], capture: InferenceScheduler.CaptureLease) async throws -> Bool {
        try await scheduler.run(priority: .capture(capture)) { [files, liveModels] in
            do {
                try await liveModels.load(models, files: files, capture: capture)
                return true
            } catch is CancellationError { throw CancellationError() }
            catch { return false }
        }
    }

    func liveText(_ model: ModelSnapshot, samples: [Float], language: MeetingLanguage,
                  capture: InferenceScheduler.CaptureLease) async throws -> LiveASRResult {
        try await scheduler.run(priority: .capture(capture)) { [liveModels] in
            try await liveModels.text(model, samples: samples, language: language, capture: capture)
        }
    }
    func liveActivity(_ model: ModelSnapshot, samples: [Float], capture: InferenceScheduler.CaptureLease) async throws -> [SpeakerWindowActivity] {
        try await scheduler.run(priority: .capture(capture)) { [liveModels] in
            try await liveModels.activity(model, samples: samples, capture: capture)
        }
    }
    func liveVector(_ model: ModelSnapshot, samples: [Float], capture: InferenceScheduler.CaptureLease) async throws -> SpeakerWindowEmbedding {
        try await scheduler.run(priority: .capture(capture)) { [liveModels] in
            try await liveModels.vector(model, samples: samples, capture: capture)
        }
    }

    public func transcribe(_ model: ModelSnapshot, samples: [Float], language: String?,
        capture: InferenceScheduler.CaptureLease? = nil, maxTokens: Int = 512, allowEmpty: Bool = false) async throws -> QwenTranscription {
        guard capture == nil || model.role == .liveASR else {
            throw ModelCatalogError.invalidManifest("Only the live ASR role is admitted during capture.")
        }
        let manifest = try resolve(model)
        return try await speech(manifest, capture: capture) { adapter in
            try await adapter.transcribe(samples: samples, language: language, maxTokens: maxTokens, allowEmpty: allowEmpty)
        }
    }

    public func transcribeBatch(_ model: ModelSnapshot, windows: [[Float]], language: String?,
        maxTokens: Int = 512, allowEmpty: Bool = false) async throws -> [QwenTranscription] {
        let manifest = try resolve(model)
        return try await speech(manifest) { adapter in
            try await adapter.transcribeBatch(windows, language: language, maxTokens: maxTokens, allowEmpty: allowEmpty)
        }
    }

    public func align(_ model: ModelSnapshot, samples: [Float], text: String,
                      language: String) async throws -> [ForcedAlignItem] {
        let manifest = try resolve(model)
        return try await speech(manifest) { adapter in
            try await adapter.align(samples: samples, text: text, language: language)
        }
    }

    public func segment(_ model: ModelSnapshot, samples: [Float],
        capture: InferenceScheduler.CaptureLease? = nil) async throws -> [LocalSpeakerSegment] {
        let manifest = try resolve(model)
        return try await speaker(manifest, capture: capture) { adapter in try await adapter.segment(samples: samples) }
    }

    public func embed(_ model: ModelSnapshot, samples: [Float],
        capture: InferenceScheduler.CaptureLease? = nil) async throws -> SpeakerEmbedding {
        let manifest = try resolve(model)
        return try await speaker(manifest, capture: capture) { adapter in try await adapter.embed(samples: samples) }
    }

    public func generate(_ model: ModelSnapshot, settings: ProcessingSettings,
                         system: String, prompt: String, maxTokens: Int? = nil,
                         sampling: TextSampling = .greedy) async throws -> TextGeneration {
        let manifest = try resolve(model)
        return try await background(manifest) { [files, residents] in
            let adapter = try await residents.text(manifest, files: files, contextTokens: settings.contextLimit.rawValue)
            return try await adapter.generate(system: system, prompt: prompt,
                contextTokens: settings.contextLimit.rawValue, maxTokens: maxTokens, role: model.role, sampling: sampling)
        }
    }

    /// Exact token counts from the job's text model, loading it as generation would.
    public func textTokenCounts(_ model: ModelSnapshot, settings: ProcessingSettings, texts: [String]) async throws -> [Int] {
        let manifest = try resolve(model)
        return try await background(manifest) { [files, residents] in
            try await residents.text(manifest, files: files, contextTokens: settings.contextLimit.rawValue).tokenCounts(texts)
        }
    }

    public func formattedTextTokens(_ model: ModelSnapshot, settings: ProcessingSettings,
                                    system: String, prompt: String) async throws -> Int {
        let manifest = try resolve(model)
        return try await background(manifest) { [files, residents] in
            try await residents.text(manifest, files: files, contextTokens: settings.contextLimit.rawValue)
                .formattedTokenCount(system: system, prompt: prompt)
        }
    }

    private func resolve(_ snapshot: ModelSnapshot) throws -> ModelManifest {
        try catalog.model(for: snapshot)
    }

    private func speech<T: Sendable>(_ manifest: ModelManifest,
        capture: InferenceScheduler.CaptureLease? = nil,
        operation: @escaping @Sendable (QwenSpeechAdapter) async throws -> T) async throws -> T {
        guard let capture else {
            return try await background(manifest) { [files, residents] in
                try await operation(residents.speech(manifest, files: files))
            }
        }
        return try await scheduler.run(priority: .capture(capture)) { [files] in
            let adapter = QwenSpeechAdapter()
            do {
                try await adapter.load(manifest, files: files)
                let result = try await operation(adapter)
                try await adapter.unload()
                return result
            } catch { try? await adapter.unload(); throw error }
        }
    }

    private func speaker<T: Sendable>(_ manifest: ModelManifest,
        capture: InferenceScheduler.CaptureLease? = nil,
        operation: @escaping @Sendable (SpeakerInferenceAdapter) async throws -> T) async throws -> T {
        guard let capture else {
            return try await background(manifest) { [files, residents] in
                try await operation(residents.speaker(manifest, files: files))
            }
        }
        return try await scheduler.run(priority: .capture(capture)) { [files] in
            let adapter = SpeakerInferenceAdapter()
            do {
                try await adapter.load(manifest, files: files)
                let result = try await operation(adapter)
                try await adapter.unload()
                return result
            } catch { try? await adapter.unload(); throw error }
        }
    }

    /// Background request on a resident model. A failed request drops its
    /// model; every request restarts the idle countdown that unloads them all.
    private func background<T: Sendable>(_ manifest: ModelManifest,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        defer { scheduleIdleUnload() }
        return try await scheduler.run { [residents] in
            do { return try await operation() }
            // Cancellation (dictation preemption, capture) leaves no model state behind.
            catch is CancellationError { throw CancellationError() }
            // A refused budget leaves the model intact; anything else may not.
            catch let error as TextAdapterError where error == .inputBudget { throw error }
            catch let error as TextContextPlanningError { throw error }
            catch { await residents.discard(manifest); throw error }
        }
    }

    private func scheduleIdleUnload() {
        Task.detached { [scheduler, residents] in
            let token = await residents.touch()
            try? await Task.sleep(nanoseconds: ResidentModels.idleSeconds * 1_000_000_000)
            guard await !residents.isEmpty else { return }
            _ = try? await scheduler.run { await residents.unloadIfIdle(since: token) }
        }
    }
}
