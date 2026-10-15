import Foundation
import Observation
import TalkTrackDomain

@MainActor @Observable public final class TranslationPresentation {
    public private(set) var output: GeneratedOutput?
    public private(set) var items: [TranscriptDisplayItem] = []
    /// The meeting's day speakers in Transcript order, for matching name colors.
    public private(set) var speakerIDs: [UUID] = []
    public private(set) var job: ProcessingJob?
    public private(set) var progress: TranslationProgress?
    public private(set) var outdated = false
    public private(set) var requirement: String?
    public private(set) var error: String?
    public private(set) var isBusy = false
    public private(set) var loaded = false
    public let meetingID: UUID
    private let store: SessionStore
    private let runner: FinalJobRunner
    private let pipeline: TranslationJobPipeline
    private let model: @MainActor () throws -> ModelSnapshot
    private let settings: @MainActor () -> ProcessingSettings
    private var refreshing = false

    public convenience init(meetingID: UUID, store: SessionStore, runner: FinalJobRunner, pipeline: TranslationJobPipeline,
                model: ModelSnapshot, settings: @escaping @MainActor () -> ProcessingSettings = { ProcessingPreferences.snapshot() }) {
        self.init(meetingID: meetingID, store: store, runner: runner, pipeline: pipeline, model: { model }, settings: settings)
    }

    /// `model` is read when work is queued, so a text model chosen in Settings applies to the next translation.
    public init(meetingID: UUID, store: SessionStore, runner: FinalJobRunner, pipeline: TranslationJobPipeline,
                model: @escaping @MainActor () throws -> ModelSnapshot,
                settings: @escaping @MainActor () -> ProcessingSettings = { ProcessingPreferences.snapshot() }) {
        self.meetingID = meetingID; self.store = store; self.runner = runner
        self.pipeline = pipeline; self.model = model; self.settings = settings
    }
    public var running: Bool {
        job.map { ![.completed, .interrupted, .failed, .cancelled, .waitingForModels].contains($0.stage) } == true
    }
    public var canGenerate: Bool { loaded && !isBusy && !running && requirement == nil }
    public var canRetry: Bool { !isBusy && job.map { [.failed, .interrupted, .waitingForModels].contains($0.stage) } == true }
    public var target: OutputLanguage { settings().translationLanguage }
    public var status: String? {
        guard let job else { return nil }
        switch job.stage {
        case .completed: return nil
        case .queued: return "Translation queued…"
        case .waitingForModels: return TranslationError.missingModel.localizedDescription
        case .failed, .interrupted, .cancelled: return job.lastError ?? "Translation was interrupted. Retry when ready."
        case .publishing: return "Saving translation…"
        default: return progress?.message ?? "Preparing translation…"
        }
    }
    private var selectedSettings: ProcessingSettings {
        var value = settings(); value.templateVersion = IndexedTranslation.version; return value
    }
    public func refresh() async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let value = try await store.output(.translation, meetingID: meetingID)
            if value?.id != output?.id {
                if let value { items = try await store.translatedItems(value) } else { items = [] }
                speakerIDs = try await store.daySpeakers(meetingID: meetingID).map(\.id)
                output = value
            }
            let jobs = try await store.jobs(meetingID: meetingID).filter { $0.snapshot.kind == .translation }
            job = jobs.last(where: { ![.completed, .failed, .interrupted, .cancelled, .waitingForModels].contains($0.stage) }) ?? jobs.last
            if let job { progress = await pipeline.status(jobID: job.id) } else { progress = nil }
            if let output { outdated = try await store.isOutdated(output, settings: selectedSettings) } else { outdated = false }
            do { try await store.requireTranslationSource(meetingID: meetingID); requirement = nil }
            catch { requirement = error.localizedDescription }
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
    public func generate() async {
        guard canGenerate else { return }
        isBusy = true; defer { isBusy = false }
        do {
            job = try await store.enqueueTranslation(meetingID: meetingID, settings: selectedSettings, model: try model())
            error = nil; await runner.wake()
        } catch { self.error = error.localizedDescription }
        await refresh()
    }
    public func retry() async {
        guard canRetry, let job else { return }
        isBusy = true; defer { isBusy = false }
        do { try await runner.retry(jobID: job.id); error = nil } catch { self.error = error.localizedDescription }
        await refresh()
    }
    public func cancel() async {
        guard !isBusy, running, let job else { return }
        isBusy = true; defer { isBusy = false }
        do { try await runner.cancel(jobID: job.id); error = nil } catch { self.error = error.localizedDescription }
        await refresh()
    }
}
