import Foundation
import Observation
import TalkTrackDomain

/// What Settings shows for one installation (one manifest may serve several roles).
public enum ModelInstallState: Equatable, Sendable {
    case checking
    case missing
    /// Cancelled or interrupted; verified partial files are reused on resume.
    case paused
    case failed(String)
    case downloading(ModelDownloadPhase, completedBytes: Int64, totalBytes: Int64)
    case ready
    /// Installed and currently borrowed by running work.
    case inUse
    case removing

    /// Combines the downloader's last progress with the installation's files.
    public static func resolve(progress: ModelDownloadProgress?, busy: Bool, ready: Bool) -> Self {
        if let progress, [.checking, .downloading, .preparing].contains(progress.phase) {
            return .downloading(progress.phase, completedBytes: progress.completedBytes, totalBytes: progress.totalBytes)
        }
        if busy { return .inUse }
        if ready { return .ready }
        switch progress?.phase {
        case .failed: return .failed(progress?.message ?? "The download failed.")
        case .paused: return .paused
        default: return .missing
        }
    }

    public var isInstalled: Bool { self == .ready || self == .inUse }
    public var isDownloading: Bool { if case .downloading = self { true } else { false } }
}

/// Implemented by the application's single `InferenceRuntime`. Installations
/// are addressed by catalog id: text models are alternatives with the same roles.
public protocol ModelInstallationControl: Sendable {
    func installState(_ id: String) async throws -> ModelInstallState
    /// Returns when the model is ready; throws `CancellationError` after `cancelInstall`.
    func install(_ id: String) async throws
    func cancelInstall(_ id: String) async throws
    /// Waits for running work that uses the model, then deletes only its files.
    func remove(_ id: String) async throws
}

/// Model management for Settings. Owned for the application lifetime, so a
/// download continues while the Settings window is closed.
@MainActor @Observable public final class ModelSettingsPresentation {
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let roles: [ModelRole]
        public let title: String
        public let purpose: String
        public let repository: String
        public let downloadBytes: Int64
        public var state: ModelInstallState
        public var error: String?
        /// One of the alternative text models; `selectedTextModel` says which one new jobs use.
        public var isTextModel: Bool { roles.contains(where: \.isTextRole) }
        /// One of the alternative final-transcription models; `selectedFinalASRModel` says which one new jobs use.
        public var isFinalASRModel: Bool { roles.contains(.finalASR) }
        /// "Fast (default)" or "Slower, better quality" for a final-transcription model.
        public let speedLabel: String?
    }

    public private(set) var items: [Item]
    /// Installations a missing-model action asked the user to download.
    public private(set) var requested: Set<String> = []
    /// The user's text model, or nil for the memory-based choice.
    public private(set) var textModelChoice: String?
    /// The text model this Mac's memory suggests.
    public let automaticTextModel: String
    public let physicalMemory: UInt64
    /// The user's final-transcription model, or nil for the default (Parakeet).
    public private(set) var finalASRModelChoice: String?
    public let defaultFinalASRModel: String
    private let defaults: UserDefaults
    private let control: any ModelInstallationControl
    private var downloads: [String: Task<Void, Never>] = [:]
    private var monitors: [String: Task<Void, Never>] = [:]
    private let pollInterval: Duration
    /// Called after a download ends or a model is removed.
    public var onChange: (@MainActor () -> Void)?

    public init(catalog: ModelCatalog, control: any ModelInstallationControl, pollInterval: Duration = .milliseconds(400),
                defaults: UserDefaults = .standard, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.control = control
        self.pollInterval = pollInterval
        self.defaults = defaults
        self.physicalMemory = physicalMemory
        let text = catalog.textModels
        automaticTextModel = ModelCatalog.defaultTextModel(among: text, physicalMemory: physicalMemory)?.id ?? ""
        let saved = ProcessingPreferences.textModel(in: defaults)
        textModelChoice = text.contains { $0.id == saved } ? saved : nil
        let finals = catalog.finalASRModels
        defaultFinalASRModel = finals.first { $0.id == ProcessingPreferences.defaultFinalASRModel }?.id ?? finals.first?.id ?? ""
        let savedFinal = ProcessingPreferences.finalASRModel(in: defaults)
        finalASRModelChoice = finals.contains { $0.id == savedFinal } ? savedFinal : nil
        // Live, the final alternatives (fast one first), the other speech and speaker models, then text models largest first.
        let others = catalog.models.filter { $0.adapter != .qwen3Text && !$0.roles.contains(.finalASR) && !$0.roles.contains(.liveASR) }
        let live = catalog.models.filter { $0.roles.contains(.liveASR) }
        let ordered: [ModelManifest] = live + finals + others + text
        items = ordered.map { Self.makeItem($0) }
    }

    /// The text model new summaries, translations and spelling corrections use.
    public var selectedTextModel: String { textModelChoice ?? automaticTextModel }

    /// The user chose a text model larger than this Mac's memory suggests: it may
    /// be tried, but can be slow or stop when macOS runs out of memory.
    public var selectedTextModelExceedsMemory: Bool {
        guard let chosen = items.first(where: { $0.id == selectedTextModel }),
              let automatic = items.first(where: { $0.id == automaticTextModel }) else { return false }
        return chosen.downloadBytes > automatic.downloadBytes
    }

    /// Saves the text model for new jobs; nil returns to the memory-based choice.
    /// Running and queued jobs keep the model they were created with.
    public func chooseTextModel(_ id: String?) {
        guard id == nil || items.contains(where: { $0.id == id && $0.isTextModel }) else { return }
        textModelChoice = id
        if let id { defaults.set(id, forKey: ProcessingPreferences.textModelKey) }
        else { defaults.removeObject(forKey: ProcessingPreferences.textModelKey) }
        onChange?()
    }

    /// The final-transcription model new jobs use.
    public var selectedFinalASRModel: String { finalASRModelChoice ?? defaultFinalASRModel }

    /// Saves the final-transcription model for new jobs; nil returns to the default.
    /// Running and queued jobs keep the model they were created with.
    public func chooseFinalASRModel(_ id: String?) {
        guard id == nil || items.contains(where: { $0.id == id && $0.isFinalASRModel }) else { return }
        finalASRModelChoice = id == defaultFinalASRModel ? nil : id
        if let choice = finalASRModelChoice { defaults.set(choice, forKey: ProcessingPreferences.finalASRModelKey) }
        else { defaults.removeObject(forKey: ProcessingPreferences.finalASRModelKey) }
        onChange?()
    }

    public func item(for role: ModelRole) -> Item? {
        if role.isTextRole { return items.first { $0.id == selectedTextModel } }
        if role == .finalASR { return items.first { $0.id == selectedFinalASRModel } }
        return items.first { $0.roles.contains(role) }
    }

    /// Highlights the installations serving `roles`, e.g. from "Transcription needs models".
    public func request(_ roles: [ModelRole]) {
        requested = Set(roles.compactMap { item(for: $0)?.id })
    }

    public func refresh() async {
        for item in items where downloads[item.id] == nil && item.state != .removing {
            await refresh(item.id)
        }
    }

    public func download(_ id: String) {
        guard known(id), downloads[id] == nil, !(state(id)?.isInstalled ?? false) else { return }
        update(id) { $0.error = nil; $0.state = .downloading(.checking, completedBytes: 0, totalBytes: $0.downloadBytes) }
        monitor(id)
        downloads[id] = Task { [control] in
            do {
                try await control.install(id)
                self.requested.remove(id)
            } catch is CancellationError {
            } catch {
                self.update(id) { $0.error = Self.message(error) }
            }
            self.downloads[id] = nil
            self.monitors.removeValue(forKey: id)?.cancel()
            await self.refresh(id)
            self.onChange?()
        }
    }

    public func cancel(_ id: String) async {
        guard known(id), downloads[id] != nil else { return }
        do { try await control.cancelInstall(id) } catch { update(id) { $0.error = Self.message(error) } }
        await downloads[id]?.value
    }

    /// For quitting: pauses every download, keeping verified partial files for Resume.
    public func cancelAll() async {
        for id in Array(downloads.keys) { await cancel(id) }
    }

    public func remove(_ id: String) async {
        guard known(id), downloads[id] == nil, state(id) != .removing else { return }
        update(id) { $0.error = nil; $0.state = .removing }
        do { try await control.remove(id) } catch { update(id) { $0.error = Self.message(error) } }
        await refresh(id)
        onChange?()
    }

    // MARK: Private

    private func monitor(_ id: String) {
        monitors[id]?.cancel()
        monitors[id] = Task { [pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, self.downloads[id] != nil else { return }
                await self.refresh(id, keepDownloading: true)
            }
        }
    }

    /// While a download task runs, only progress updates are accepted, so a
    /// momentary state between files never shows Download again.
    private func refresh(_ id: String, keepDownloading: Bool = false) async {
        guard known(id) else { return }
        do {
            let state = try await control.installState(id)
            if keepDownloading, downloads[id] != nil, !state.isDownloading { return }
            update(id) { $0.state = state }
        } catch {
            update(id) { $0.state = .failed(Self.message(error)) }
        }
    }

    private func known(_ id: String) -> Bool { items.contains { $0.id == id } }
    private func state(_ id: String) -> ModelInstallState? { items.first { $0.id == id }?.state }
    private func update(_ id: String, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    nonisolated private static func message(_ error: Error) -> String {
        let error = error as NSError
        if let recovery = error.localizedRecoverySuggestion { return error.localizedDescription + " " + recovery }
        return error.localizedDescription
    }

    /// Weights from about 6 GB: the larger model. Names come from the repository ("Qwen3.5-9B-OptiQ-4bit").
    nonisolated static func describeText(_ model: ModelManifest) -> (title: String, purpose: String) {
        let parts = model.repository.split(separator: "/").last.map { $0.split(separator: "-") } ?? []
        let name = parts.count >= 2 ? "\(parts[0]) \(parts[1])" : model.repository
        let large = model.weightByteCount >= 5_000_000_000
        return ("Text processing: \(name)", large
            ? "Summaries, translation and spelling. Better results; recommended with 32 GB of memory or more."
            : "Summaries, translation and spelling. Faster and needs less memory; recommended below 32 GB.")
    }

    nonisolated private static func makeItem(_ model: ModelManifest) -> Item {
        var title = "", purpose = "", label: String?
        if model.adapter == .qwen3Text {
            (title, purpose) = describeText(model)
        } else if model.roles.contains(.finalASR) {
            let info = describeFinal(model)
            (title, purpose, label) = (info.title, info.purpose, info.label)
        } else {
            (title, purpose) = describe(model.roles)
        }
        return Item(id: model.id, roles: model.roles, title: title, purpose: purpose, repository: model.repository,
                    downloadBytes: model.downloadByteCount, state: .checking, speedLabel: label)
    }

    /// Parakeet is the fast default; Qwen3-ASR 1.7B is slower with better quality.
    nonisolated static func describeFinal(_ model: ModelManifest) -> (title: String, purpose: String, label: String) {
        if model.adapter == .parakeetTDT {
            return ("Final transcription: Parakeet v3",
                    "Fast (default). Transcribes saved audio after recording stops; quiet speech it misses is recovered by Qwen3-ASR when that model is installed.",
                    "Fast (default)")
        }
        return ("Final transcription: Qwen3-ASR 1.7B",
                "Slower, better quality. Transcribes saved audio after recording stops and recovers speech Parakeet misses.",
                "Slower, better quality")
    }

    nonisolated static func describe(_ roles: [ModelRole]) -> (title: String, purpose: String) {
        switch Set(roles.contains(where: \.isTextRole) ? [.summary, .translation, .spelling] : roles) {
        case [.liveASR]: ("Live transcription", "Shows provisional text while recording.")
        case [.finalASR]: ("Final transcription", "Transcribes saved audio after recording stops.")
        case [.alignment]: ("Word timing", "Places transcript words on the audio timeline.")
        case [.segmentation]: ("Speaker detection", "Finds when each voice is speaking.")
        case [.embedding]: ("Voice identification", "Tells speakers apart and recognizes saved voices.")
        case [.summary, .translation, .spelling]: ("Text processing", "Corrects spelling, writes summaries and translates transcripts.")
        default: (roles.map(\.rawValue).joined(separator: ", "), "")
        }
    }
}

extension ModelRole {
    /// Summary, translation and spelling share one text-model installation.
    public var isTextRole: Bool { self == .summary || self == .translation || self == .spelling }
}
