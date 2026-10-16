import Foundation
import Observation
import TalkTrackDomain

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
        public var id: UUID { recording.id }

        public var running: Bool {
            guard let job else { return false }
            return ![.completed, .interrupted, .failed, .cancelled, .waitingForModels].contains(job.stage)
        }
        public var canRetry: Bool { job.map { [.failed, .interrupted, .waitingForModels].contains($0.stage) } == true }
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

    public var type: SummaryType = .auto
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
    private var refreshing = false

    public convenience init(meetingID: UUID, store: SessionStore, runner: FinalJobRunner,
                pipeline: SummaryJobPipeline, model: ModelSnapshot,
                settings: @escaping @MainActor () -> ProcessingSettings = { ProcessingPreferences.snapshot() }) {
        self.init(meetingID: meetingID, store: store, runner: runner, pipeline: pipeline,
                  model: { _ in model }, settings: { _ in settings() })
    }

    /// `model` and `settings` are read with `modelChoice` when work is queued.
    public init(meetingID: UUID, store: SessionStore, runner: FinalJobRunner,
                pipeline: SummaryJobPipeline, model: @escaping @MainActor (SummaryModelChoice?) throws -> ModelSnapshot,
                settings: @escaping @MainActor (SummaryModelChoice?) -> ProcessingSettings) {
        self.meetingID = meetingID; self.store = store
        self.runner = runner; self.pipeline = pipeline; self.model = model; self.settings = settings
    }

    public var running: Bool { entries.contains(where: \.running) }
    /// Recordings `Generate Summaries` would queue now.
    public var pending: [Entry] {
        entries.filter { $0.requirement == nil && !$0.running && ($0.output == nil || $0.outdated) }
    }
    public var canGenerate: Bool { loaded && !isBusy && !pending.isEmpty }
    public func canRegenerate(_ entry: Entry) -> Bool { loaded && !isBusy && entry.requirement == nil && !entry.running }

    private var selectedSettings: ProcessingSettings {
        var value = settings(modelChoice)
        value.summaryType = type; value.templateVersion = SummaryTemplates.currentVersion
        return value
    }

    public func refresh() async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let recordings = try await store.recordings(meetingID: meetingID).sorted { $0.startedAt < $1.startedAt }
            let outputs = try await store.summaries(meetingID: meetingID)
            let jobs = try await store.jobs(meetingID: meetingID).filter { $0.snapshot.kind == .summary }
            if !loaded {
                let latest = jobs.filter { $0.snapshot.recordingID != nil }.max { $0.snapshot.createdAt < $1.snapshot.createdAt }
                type = latest?.snapshot.settings.summaryType ?? .auto
            }
            let current = selectedSettings
            var values: [Entry] = []
            for (index, recording) in recordings.enumerated() {
                let own = jobs.filter { $0.snapshot.recordingID == recording.id }
                // Show an older retried request while active, otherwise the latest attempt.
                let job = own.last(where: { ![.completed, .failed, .interrupted, .cancelled, .waitingForModels].contains($0.stage) }) ?? own.last
                let output = outputs[recording.id]
                var requirement: String?
                do { try await store.requireSummarySource(meetingID: meetingID, recordingID: recording.id) }
                catch { requirement = error.localizedDescription }
                var outdated = false
                if let output { outdated = try await store.isOutdated(output, settings: current) }
                var progress: SummaryProgress?
                if let job { progress = await pipeline.status(jobID: job.id) }
                values.append(Entry(recording: recording, number: index + 1, output: output, job: job,
                    progress: progress, outdated: outdated, requirement: requirement))
            }
            entries = values
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    /// Queues every recording whose summary is missing or outdated.
    public func generate() async {
        guard canGenerate else { return }
        await perform { _ = try await self.store.enqueueSummaries(meetingID: self.meetingID, settings: self.selectedSettings, model: try self.model(self.modelChoice)) }
    }

    public func regenerate(_ entry: Entry) async {
        guard canRegenerate(entry) else { return }
        await perform {
            _ = try await self.store.enqueueSummary(meetingID: self.meetingID, recordingID: entry.recording.id,
                                                    settings: self.selectedSettings, model: try self.model(self.modelChoice))
        }
    }

    public func retry(_ entry: Entry) async {
        guard !isBusy, entry.canRetry, let job = entry.job else { return }
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
