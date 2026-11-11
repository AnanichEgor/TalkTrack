import Foundation
import Observation
import TalkTrackDomain

/// What the summary-type picker selects: a built-in type or an imported template.
public enum SummaryTemplateChoice: Hashable, Sendable {
    case builtIn(SummaryType)
    case custom(UUID)
}

/// One summary per recording, listed chronologically. The view may disappear
/// while the application-owned runner continues; refresh reads durable state,
/// so returning to the tab or relaunching restores it.
@MainActor @Observable public final class SummaryPresentation {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let recording: Recording
        /// 1-based position in the meeting, for "Recording 2".
        public let number: Int
        public let output: GeneratedOutput?
        public let job: ProcessingJob?
        public let progress: SummaryProgress?
        public let outdated: Bool
        /// Why this recording cannot be summarized yet.
        public let requirement: String?
        /// The custom template of the shown summary (or attempt) no longer exists.
        public let templateMissing: Bool
        public var id: UUID { recording.id }

        public var running: Bool {
            guard let job else { return false }
            return job.stage.isActive
        }
        public var canRetry: Bool { job?.stage.isRetryable == true }
        public var status: String? {
            guard let job else { return nil }
            switch job.stage {
            case .completed: return nil
            case .queued: return "Summary queued…"
            case .waitingForModels: return SummaryJobError.missingModel.localizedDescription
            case .failed, .interrupted, .cancelled: return job.lastError ?? "Summary generation was interrupted. Retry when ready."
            default: return progress?.message ?? "Generating summary…"
            }
        }
    }

    /// The template for the next summaries; nil asks the user to choose one,
    /// because the last used custom template no longer exists.
    public var selection: SummaryTemplateChoice? = .builtIn(.auto)
    /// Imported templates, in the order Settings lists them.
    public private(set) var customTemplates: [CustomSummaryTemplate] = []
    /// The model for the next summaries, chosen beside Generate Summaries; nil uses the default.
    public var modelChoice: SummaryModelChoice?
    public private(set) var entries: [Entry] = []
    public private(set) var error: String?
    public private(set) var isBusy = false
    public private(set) var loaded = false
    public let meetingID: UUID
    private let store: SessionStore
    private let runner: FinalJobRunner
    private let pipeline: SummaryJobPipeline
    private let model: @MainActor (SummaryModelChoice?) throws -> ModelSnapshot
    private let settings: @MainActor (SummaryModelChoice?) -> ProcessingSettings
    private let templates: SummaryTemplateStore?
    private var refreshing = false

    public convenience init(meetingID: UUID, store: SessionStore, runner: FinalJobRunner,
                pipeline: SummaryJobPipeline, model: ModelSnapshot, templates: SummaryTemplateStore? = nil,
                settings: @escaping @MainActor () -> ProcessingSettings = { ProcessingPreferences.snapshot() }) {
        self.init(meetingID: meetingID, store: store, runner: runner, pipeline: pipeline,
                  model: { _ in model }, settings: { _ in settings() }, templates: templates)
    }

    /// `model` and `settings` are read with `modelChoice` when work is queued.
    public init(meetingID: UUID, store: SessionStore, runner: FinalJobRunner,
                pipeline: SummaryJobPipeline, model: @escaping @MainActor (SummaryModelChoice?) throws -> ModelSnapshot,
                settings: @escaping @MainActor (SummaryModelChoice?) -> ProcessingSettings,
                templates: SummaryTemplateStore? = nil) {
        self.meetingID = meetingID; self.store = store
        self.runner = runner; self.pipeline = pipeline; self.model = model; self.settings = settings
        self.templates = templates
    }

    /// Recordings `Generate Summaries` would queue now.
    public var pending: [Entry] {
        entries.filter { $0.requirement == nil && !$0.running && ($0.output == nil || $0.outdated) }
    }
    public var canGenerate: Bool { loaded && !isBusy && selectedSettings != nil && !pending.isEmpty }
    public func canRegenerate(_ entry: Entry) -> Bool {
        loaded && !isBusy && selectedSettings != nil && entry.requirement == nil && !entry.running
    }
    /// Retry reruns the attempt's own template, which must still exist, and
    /// waits like Generate while no template is chosen.
    public func canRetry(_ entry: Entry) -> Bool {
        !isBusy && entry.canRetry && selectedSettings != nil && !entry.templateMissing
    }

    /// The selected custom template, when it still exists.
    public var selectedCustomTemplate: CustomSummaryTemplate? {
        guard case .custom(let id) = selection else { return nil }
        return customTemplates.first { $0.id == id }
    }

    /// The settings of the next summaries; nil while no available template is chosen.
    private var selectedSettings: ProcessingSettings? {
        var value = settings(modelChoice)
        value.templateVersion = SummaryTemplates.currentVersion
        switch selection {
        case .builtIn(let type)?:
            value.summaryType = type; value.customTemplate = nil
        case .custom?:
            guard let template = selectedCustomTemplate else { return nil }
            value.summaryType = .custom; value.customTemplate = template.reference
        case nil: return nil
        }
        return value
    }

    private var templateHashes: [UUID: String] {
        Dictionary(uniqueKeysWithValues: customTemplates.map { ($0.id, $0.contentHash) })
    }

    public func refresh() async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let recordings = try await store.recordings(meetingID: meetingID).sorted { $0.startedAt < $1.startedAt }
            let outputs = try await store.summaries(meetingID: meetingID)
            let jobs = try await store.jobs(meetingID: meetingID).filter { $0.snapshot.kind == .summary }
            if let templates {
                await templates.reload()
                customTemplates = await templates.templates()
            }
            let hashes = templateHashes
            if !loaded {
                // The latest summary's template; a deleted one asks for a choice.
                let latest = jobs.filter { $0.snapshot.recordingID != nil }.max { $0.snapshot.createdAt < $1.snapshot.createdAt }
                if let settings = latest?.snapshot.settings, settings.summaryType == .custom {
                    selection = settings.customTemplate.flatMap { hashes[$0.id] != nil ? .custom($0.id) : nil }
                } else { selection = .builtIn(latest?.snapshot.settings.summaryType ?? .auto) }
            } else if case .custom(let id) = selection, hashes[id] == nil {
                selection = nil
            }
            let current = selectedSettings
            var values: [Entry] = []
            for (index, recording) in recordings.enumerated() {
                let own = jobs.filter { $0.snapshot.recordingID == recording.id }
                // Show an older retried request while active, otherwise the latest attempt.
                let job = own.last(where: { $0.stage.isActive }) ?? own.last
                let output = outputs[recording.id]
                var requirement: String?
                do { try await store.requireSummarySource(meetingID: meetingID, recordingID: recording.id) }
                catch { requirement = error.localizedDescription }
                var outdated = false
                if let output {
                    // Without a choice, a summary is compared under its own template.
                    var compared = current ?? settings(modelChoice)
                    if current == nil {
                        compared.summaryType = output.job.settings.summaryType
                        compared.customTemplate = output.job.settings.customTemplate
                    }
                    outdated = try await store.isOutdated(output, settings: compared, templateHashes: hashes)
                }
                var progress: SummaryProgress?
                if let job { progress = await pipeline.status(jobID: job.id) }
                let shown = job?.stage.isRetryable == true ? job?.snapshot.settings : (output?.job.settings ?? job?.snapshot.settings)
                let missing = shown?.customTemplate.map { hashes[$0.id] == nil } ?? false
                values.append(Entry(recording: recording, number: index + 1, output: output, job: job,
                    progress: progress, outdated: outdated, requirement: requirement, templateMissing: missing))
            }
            entries = values
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    /// Queues every recording whose summary is missing or outdated.
    public func generate() async {
        guard canGenerate, let settings = selectedSettings else { return }
        let hashes = templateHashes
        await perform { _ = try await self.store.enqueueSummaries(meetingID: self.meetingID, settings: settings,
                                                                  model: try self.model(self.modelChoice), templateHashes: hashes) }
    }

    public func regenerate(_ entry: Entry) async {
        guard canRegenerate(entry), let settings = selectedSettings else { return }
        await perform {
            _ = try await self.store.enqueueSummary(meetingID: self.meetingID, recordingID: entry.recording.id,
                                                    settings: settings, model: try self.model(self.modelChoice))
        }
    }

    public func retry(_ entry: Entry) async {
        guard canRetry(entry), let job = entry.job else { return }
        await perform { try await self.runner.retry(jobID: job.id) }
    }

    public func cancel(_ entry: Entry) async {
        guard !isBusy, entry.running, let job = entry.job else { return }
        await perform { try await self.runner.cancel(jobID: job.id) }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        isBusy = true; defer { isBusy = false }
        do { try await action(); error = nil; await runner.wake() }
        catch { self.error = error.localizedDescription }
        await refresh()
    }
}
