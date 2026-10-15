import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// Installation fake: each role's install blocks until the test finishes,
/// fails or cancels it, and reports byte progress in between.
/// Installations are addressed by catalog id; the helpers take a role and use
/// the catalog's selected model for it (the selected text model for text roles).
private actor FakeInstallations: ModelInstallationControl {
    var states: [String: ModelInstallState] = [:]
    var installs: [ModelRole] = []
    var installedIDs: [String] = []
    var removals: [ModelRole] = []
    private var waiting: [String: CheckedContinuation<Void, Error>] = [:]
    private let catalog: ModelCatalog

    init(installed: Set<ModelRole>, catalog: ModelCatalog) {
        self.catalog = catalog
        for model in catalog.models { states[model.id] = .missing }
        for role in installed { states[try! catalog.model(for: role).id] = .ready }
    }

    private func id(_ role: ModelRole) -> String { try! catalog.model(for: role).id }
    private func role(_ id: String) -> ModelRole { try! catalog.model(id: id).roles[0] }
    private func set(_ id: String, _ state: ModelInstallState) { states[id] = state }

    func installState(_ id: String) throws -> ModelInstallState { states[id] ?? .missing }

    func install(_ id: String) async throws {
        installs.append(role(id)); installedIDs.append(id)
        set(id, .downloading(.downloading, completedBytes: 0, totalBytes: 100))
        try await withCheckedThrowingContinuation { waiting[id] = $0 }
    }

    func progress(_ role: ModelRole, bytes: Int64) { set(id(role), .downloading(.downloading, completedBytes: bytes, totalBytes: 100)) }

    func finish(_ role: ModelRole) { finish(id: id(role)) }
    func finish(id: String) {
        set(id, .ready)
        waiting.removeValue(forKey: id)?.resume()
    }

    func fail(_ role: ModelRole, _ message: String) {
        set(id(role), .failed(message))
        waiting.removeValue(forKey: id(role))?.resume(throwing: ModelDownloadError.insufficientSpace)
    }

    func cancelInstall(_ id: String) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        set(id, .paused)
        continuation.resume(throwing: CancellationError())
    }

    func remove(_ id: String) {
        removals.append(role(id))
        set(id, .missing)
    }

    func isWaiting(_ role: ModelRole) -> Bool { waiting[id(role)] != nil }
    func isWaiting(id: String) -> Bool { waiting[id] != nil }
}

@MainActor @Suite struct SettingsTests {
    @Test func languagesAndMicrophonePersistIndependently() throws {
        let suite = "TalkTrack.SettingsTest.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ProcessingPreferences.summaryLanguage(in: defaults) == .english)
        #expect(ProcessingPreferences.translationLanguage(in: defaults) == .russian)
        #expect(ProcessingPreferences.microphone(in: defaults) == nil)
        // Spelling correction is off unless the user turns it on.
        #expect(!ProcessingPreferences.snapshot(from: defaults).spellingCorrection)
        defaults.set(true, forKey: ProcessingPreferences.spellingCorrectionKey)
        #expect(ProcessingPreferences.snapshot(from: defaults).spellingCorrection)
        defaults.removeObject(forKey: ProcessingPreferences.spellingCorrectionKey)

        defaults.set(OutputLanguage.russian.rawValue, forKey: ProcessingPreferences.summaryLanguageKey)
        let running = ProcessingPreferences.snapshot(from: defaults)
        #expect(running.summaryLanguage == .russian && running.translationLanguage == .russian)
        defaults.set(OutputLanguage.english.rawValue, forKey: ProcessingPreferences.translationLanguageKey)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(ProcessingPreferences.summaryLanguage(in: reopened) == .russian)
        #expect(ProcessingPreferences.translationLanguage(in: reopened) == .english)
        // A queued job keeps the languages it was created with.
        #expect(running.translationLanguage == .russian)
        #expect(ProcessingPreferences.snapshot(from: reopened).translationLanguage == .english)

        defaults.set("klingon", forKey: ProcessingPreferences.summaryLanguageKey)
        #expect(ProcessingPreferences.summaryLanguage(in: defaults) == .english)

        defaults.set("BuiltInMicrophoneDevice", forKey: ProcessingPreferences.microphoneUIDKey)
        defaults.set("MacBook Pro Microphone", forKey: ProcessingPreferences.microphoneNameKey)
        let microphone = try #require(ProcessingPreferences.microphone(in: reopened))
        #expect(microphone.uid == "BuiltInMicrophoneDevice" && microphone.name == "MacBook Pro Microphone")
        defaults.set("", forKey: ProcessingPreferences.microphoneUIDKey)
        #expect(ProcessingPreferences.microphone(in: defaults) == nil)
    }

    @Test func installStateCombinesDownloadProgressAndFiles() {
        func progress(_ phase: ModelDownloadPhase, _ message: String? = nil) -> ModelDownloadProgress {
            ModelDownloadProgress(phase: phase, completedBytes: 40, totalBytes: 100, completedFiles: 1, totalFiles: 3, message: message)
        }
        #expect(ModelInstallState.resolve(progress: nil, busy: false, ready: false) == .missing)
        #expect(ModelInstallState.resolve(progress: nil, busy: false, ready: true) == .ready)
        // Borrowed by running inference: installed, never offered for download.
        #expect(ModelInstallState.resolve(progress: nil, busy: true, ready: false) == .inUse)
        for phase in [ModelDownloadPhase.checking, .downloading, .preparing] {
            #expect(ModelInstallState.resolve(progress: progress(phase), busy: true, ready: false)
                    == .downloading(phase, completedBytes: 40, totalBytes: 100))
        }
        #expect(ModelInstallState.resolve(progress: progress(.ready), busy: false, ready: true) == .ready)
        #expect(ModelInstallState.resolve(progress: progress(.paused), busy: false, ready: false) == .paused)
        #expect(ModelInstallState.resolve(progress: progress(.failed, "Disk full"), busy: false, ready: false) == .failed("Disk full"))
        // A model removed after a completed download is missing again.
        #expect(ModelInstallState.resolve(progress: progress(.ready), busy: false, ready: false) == .missing)
    }

    @Test func missingModelMessageNamesTheSettingsRowsThatDownloadThem() async throws {
        let suite = "TalkTrack.SettingsTest.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = try ModelCatalog.bundled(in: defaults).selecting(textModel: nil, physicalMemory: 64 << 30)
        let fake = FakeInstallations(installed: [.liveASR, .finalASR], catalog: catalog)
        let models = ModelSettingsPresentation(catalog: catalog, control: fake, pollInterval: .milliseconds(10),
                                               defaults: defaults, physicalMemory: 64 << 30)
        #expect(models.items.map(\.title) == ["Live transcription", "Final transcription", "Word timing",
                                              "Speaker detection", "Voice identification",
                                              "Text processing: Qwen3.5 9B", "Text processing: Qwen3.5 4B"])
        await models.refresh()
        #expect(models.item(for: .liveASR)?.state == .ready)
        #expect(models.item(for: .alignment)?.state == .missing)

        // What a final job reports when models are missing, and what the row offers.
        let missing: [ModelRole] = [.alignment, .segmentation, .embedding, .spelling]
        let status = MeetingProcessingStatus.waitingForModels(jobID: UUID(), roles: missing)
        #expect(status.message == "Transcription needs models: Word timing, Speaker detection, Voice identification, Text processing")
        models.request(missing)
        let requested = models.items.filter { models.requested.contains($0.id) }
        #expect(requested.map(\.title).sorted() == ["Speaker detection", "Text processing: Qwen3.5 9B", "Voice identification", "Word timing"])
        let text = try #require(models.item(for: .spelling))
        #expect(text.id == (try catalog.model(for: .spelling)).id)
        #expect(text.repository == "mlx-community/Qwen3.5-9B-OptiQ-4bit")
        #expect(models.item(for: .summary)?.id == text.id && models.item(for: .translation)?.id == text.id)

        // The text row downloads the shared text installation once.
        let textRole = try #require(text.roles.first)
        models.download(text.id)
        try await waitUntil { await fake.isWaiting(textRole) }
        models.download(text.id)
        await fake.progress(textRole, bytes: 60)
        try await waitUntil { models.item(for: .spelling)?.state == .downloading(.downloading, completedBytes: 60, totalBytes: 100) }
        await fake.finish(textRole)
        try await waitUntil { models.item(for: .spelling)?.state == .ready }
        #expect(await fake.installs.count == 1)
        #expect(!models.requested.contains(text.id))
        #expect(models.requested.count == 3)
        // An installed model is not downloaded again.
        models.download(text.id)
        #expect(await fake.installs.count == 1)
    }

    @Test func textModelIsChosenByMemoryUnlessTheUserPicksOne() async throws {
        let suite = "TalkTrack.SettingsTest.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gib: UInt64 = 1 << 30
        let base = try ModelCatalog.bundled(in: defaults)
        #expect(base.textModels.map(\.repository) == ["mlx-community/Qwen3.5-9B-OptiQ-4bit", "mlx-community/Qwen3.5-4B-OptiQ-4bit"])
        let large = "text-qwen35-9b", small = "text-qwen35-4b"
        // 32 GB and more: 9B; 16 and 24 GB: 4B.
        for (memory, expected) in [(8 * gib, small), (16 * gib, small), (24 * gib, small), (32 * gib, large), (64 * gib, large)] {
            let catalog = base.selecting(textModel: nil, physicalMemory: memory)
            #expect(catalog.selectedTextModelID == expected)
            for role in [ModelRole.summary, .translation, .spelling] { #expect(try catalog.model(for: role).id == expected) }
            #expect(try catalog.model(for: .finalASR).id == base.model(for: .finalASR).id)
        }
        // An unknown saved id (an older release's model) falls back to the memory default.
        #expect(base.selecting(textModel: "text-removed", physicalMemory: 16 * gib).selectedTextModelID == small)
        #expect(base.selecting(textModel: large, physicalMemory: 16 * gib).selectedTextModelID == large)

        let catalog = base.selecting(textModel: nil, physicalMemory: 16 * gib)
        let fake = FakeInstallations(installed: [], catalog: catalog)
        let models = ModelSettingsPresentation(catalog: catalog, control: fake, pollInterval: .milliseconds(10),
                                               defaults: defaults, physicalMemory: 16 * gib)
        #expect(models.automaticTextModel == small && models.textModelChoice == nil && models.selectedTextModel == small)
        #expect(models.items.filter(\.isTextModel).map(\.id) == [large, small])
        var changes = 0
        models.onChange = { changes += 1 }
        models.chooseTextModel(large)
        #expect(models.selectedTextModel == large && changes == 1)
        #expect(ProcessingPreferences.textModel(in: defaults) == large)
        #expect(try ModelCatalog.bundled(in: defaults).selecting(textModel: ProcessingPreferences.textModel(in: defaults),
                                                                physicalMemory: 16 * gib).model(for: .summary).id == large)
        // A waiting job's text roles mark the selected text row.
        models.request([.summary])
        #expect(models.requested == [large])
        models.chooseTextModel("text-qwen35-9b-unknown")
        #expect(models.selectedTextModel == large && changes == 1)
        models.chooseTextModel(nil)
        #expect(models.selectedTextModel == small && ProcessingPreferences.textModel(in: defaults) == nil)

        // Both text models download and are removed independently.
        await models.refresh()
        models.download(large); models.download(small)
        try await waitUntil { let a = await fake.isWaiting(id: large), b = await fake.isWaiting(id: small); return a && b }
        await fake.finish(id: small)
        try await waitUntil { models.items.first { $0.id == small }?.state == .ready }
        #expect(models.items.first { $0.id == large }?.state.isDownloading == true)
        await fake.finish(id: large)
        try await waitUntil { models.items.first { $0.id == large }?.state == .ready }
        #expect(await fake.installedIDs.sorted() == [small, large].sorted())
        await models.remove(large)
        #expect(models.items.first { $0.id == large }?.state == .missing)
        #expect(models.items.first { $0.id == small }?.state == .ready)
    }

    @Test func downloadsCanBeCancelledRetriedAfterFailureAndRemoved() async throws {
        let suite = "TalkTrack.SettingsTest.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = try ModelCatalog.bundled(in: defaults).selecting(textModel: nil, physicalMemory: 64 << 30)
        let fake = FakeInstallations(installed: [.embedding], catalog: catalog)
        let models = ModelSettingsPresentation(catalog: catalog, control: fake, pollInterval: .milliseconds(10),
                                               defaults: defaults, physicalMemory: 64 << 30)
        await models.refresh()
        let alignment = try #require(models.item(for: .alignment)).id

        models.download(alignment)
        try await waitUntil { await fake.isWaiting(.alignment) }
        await models.cancel(alignment)
        #expect(models.item(for: .alignment)?.state == .paused)
        #expect(models.item(for: .alignment)?.error == nil)

        models.download(alignment)
        try await waitUntil { await fake.isWaiting(.alignment) }
        await fake.fail(.alignment, "Not enough free space")
        try await waitUntil { models.item(for: .alignment)?.error != nil }
        #expect(models.item(for: .alignment)?.state == .failed("Not enough free space"))
        #expect(models.item(for: .alignment)?.error?.contains("Free space and retry") == true)

        models.download(alignment)
        #expect(models.item(for: .alignment)?.error == nil)
        try await waitUntil { await fake.isWaiting(.alignment) }
        await fake.finish(.alignment)
        try await waitUntil { models.item(for: .alignment)?.state == .ready }
        #expect(await fake.installs == [.alignment, .alignment, .alignment])

        // Quitting pauses every running download, keeping it resumable.
        let segmentation = try #require(models.item(for: .segmentation)).id
        let text = try #require(models.item(for: .summary)).id
        models.download(segmentation); models.download(text)
        try await waitUntil { let a = await fake.isWaiting(.segmentation), b = await fake.isWaiting(.summary); return a && b }
        await models.cancelAll()
        #expect(models.item(for: .segmentation)?.state == .paused && models.item(for: .summary)?.state == .paused)
        let stillWaiting = [await fake.isWaiting(.segmentation), await fake.isWaiting(.summary)]
        #expect(stillWaiting == [false, false])

        let voices = try #require(models.item(for: .embedding)).id
        await models.remove(voices)
        #expect(await fake.removals == [.embedding])
        #expect(models.item(for: .embedding)?.state == .missing)
        #expect(models.item(for: .alignment)?.state == .ready)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out")
    }
}
