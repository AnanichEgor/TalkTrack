import Foundation
import TalkTrackDomain

/// Immutable source data, saved with the job so a retry after relaunch uses
/// the same title, speech and speaker names even after later edits. A
/// summary job covers one recording; `notes` is set only by meeting-wide jobs
/// saved before per-recording summaries.
public struct SummarySource: Codable, Equatable, Sendable {
    public let job: ProcessingJobSnapshot
    public let meeting: Meeting
    public let notes: NotesRevision?
    public let recordings: [Recording]
    public let revisions: [TranscriptRevision]
    public let speakers: [DaySpeaker]
    public let assignments: [SpeakerAssignment]

    public func transcript() throws -> [TranscriptDisplayItem] {
        try TranscriptFormatter.format(meetingID: meeting.id, recordings: recordings,
            segments: revisions.flatMap(\.segments), speakers: speakers, assignments: assignments)
    }
}

public enum SummaryJobError: Error, Equatable, LocalizedError, Sendable {
    case finalRequired, alreadyQueued, missingModel, busy, invalidOutput
    public var errorDescription: String? {
        switch self {
        case .finalRequired: "The summary is available after final transcription of this recording finishes."
        case .alreadyQueued: "A summary is already queued or running for this recording."
        case .missingModel: "The summary model is missing. Download it in Settings, then retry."
        case .busy: "This summary is already running."
        case .invalidOutput: "The summary did not follow the selected format. The previous summary is preserved. Retry generation."
        }
    }
}

public enum SummaryProgress: Equatable, Sendable {
    case preparing, direct, part(Int, Int), merge(Int, Int, Int), final, saving
    public var message: String {
        switch self {
        case .preparing: "Preparing summary…"
        case .direct: "Generating summary…"
        case .part(let index, let count): "Summarizing part \(index) of \(count)…"
        case .merge(let round, let index, let count): "Combining summaries, round \(round), part \(index) of \(count)…"
        case .final: "Writing final summary…"
        case .saving: "Saving summary…"
        }
    }
}

/// Runs on the shared durable queue. Inference uses the application's runtime
/// and its capture-priority scheduler; only complete results reach the head.
public actor SummaryJobPipeline {
    private let store: SessionStore
    private let inference: any SummaryTextInference
    private let missing: @Sendable ([ModelSnapshot]) async throws -> [ModelRole]
    private var running: Set<UUID> = []
    private var progress: [UUID: SummaryProgress] = [:]

    public init(store: SessionStore, inference: any SummaryTextInference,
                missing: @escaping @Sendable ([ModelSnapshot]) async throws -> [ModelRole] = { _ in [] }) {
        self.store = store; self.inference = inference; self.missing = missing
    }

    public func status(jobID: UUID) -> SummaryProgress? { progress[jobID] }

    public func run(jobID: UUID) async throws {
        guard running.insert(jobID).inserted else { throw SummaryJobError.busy }
        defer { running.remove(jobID); progress[jobID] = nil }
        do {
            let source = try await store.summarySource(jobID: jobID)
            let job = source.job
            guard job.kind == .summary, job.models.count == 1, let model = job.models.first,
                  model.role == .summary else { throw SummaryGenerationError.invalidRequest }
            progress[jobID] = .preparing
            if try await !missing(job.models).isEmpty {
                try await store.updateJob(jobID, stage: .waitingForModels, error: SummaryJobError.missingModel.localizedDescription)
                throw SummaryJobError.missingModel
            }
            try Task.checkCancellation()
            try await store.updateJob(jobID, stage: .generating)
            let transcript = try source.transcript()
            guard let template = SummaryTemplates.template(job.settings.summaryType, version: job.settings.templateVersion) else {
                throw SummaryGenerationError.invalidRequest
            }
            // A response in the wrong format gets up to two more, differently
            // seeded attempts (the 4B model sometimes leaves a task uncited);
            // a third failure keeps the previous summary.
            var draft: SummaryDraft?
            for attempt in 0..<Self.formatAttempts where draft == nil {
                let value = try await MeetingSummarizer(model: model, settings: job.settings, inference: inference, attempt: attempt,
                    progress: { [weak self] value in await self?.report(value, jobID: jobID) })
                    .summarize(meeting: source.meeting, notes: source.notes?.text, transcript: transcript)
                try Task.checkCancellation()
                if Self.isValid(value.text, template: template, language: job.settings.summaryLanguage) { draft = value }
            }
            guard let draft else { throw SummaryJobError.invalidOutput }
            var text = draft.text
            if let section = template.perPersonSection {
                text = SummaryCheck.withoutBriefSpeakers(text, section: section.title(job.settings.summaryLanguage),
                                                               language: job.settings.summaryLanguage, transcript: transcript)
            }
            progress[jobID] = .saving
            try await store.updateJob(jobID, stage: .publishing)
            try Task.checkCancellation()
            try await store.publishOutput(GeneratedOutput(kind: .summary, job: job, text: text))
        } catch {
            // A missing model is a durable waiting state, not a generic failure.
            if (try? await store.job(jobID).stage) != .waitingForModels {
                let cancelled = error is CancellationError || Task.isCancelled
                // A model removed in Settings during generation waits for a download.
                if !cancelled, let job = try? await store.job(jobID), let removed = try? await missing(job.snapshot.models), !removed.isEmpty {
                    try? await store.updateJob(jobID, stage: .waitingForModels, error: SummaryJobError.missingModel.localizedDescription)
                    throw SummaryJobError.missingModel
                }
                try? await store.updateJob(jobID, stage: cancelled ? .interrupted : .failed,
                    error: cancelled ? "Summary generation was cancelled. The previous summary is preserved. Retry when ready." : error.localizedDescription)
            }
            throw error
        }
    }

    private func report(_ value: SummaryProgress, jobID: UUID) { progress[jobID] = value }

    /// Required headings in order, no extra or repeated headings, well-formed action items;
    /// "(notes)" is a citation only for version 1, which had notes.
    static let formatAttempts = 3

    static func isValid(_ text: String, template: SummaryTemplate, language: OutputLanguage) -> Bool {
        let notes = template.version == "1"
        return SummaryCheck.missingHeadings(text, template: template, language: language).isEmpty
            && SummaryCheck.extraHeadings(text, template: template, language: language).isEmpty
            && SummaryCheck.repeatedHeadings(text).isEmpty
            && SummaryCheck.malformedActionItems(text, language: language, notes: notes).isEmpty
            && (notes || !text.contains("(notes)"))
    }
}
