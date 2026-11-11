import Foundation
import Observation
import TalkTrackDomain

/// Settings ▸ Summaries (custom-summary-templates D7, D9): imported and built-in
/// templates, import with validation, replacement, deletion, export, the
/// prompt preview and the guide download.
@MainActor @Observable public final class SummaryTemplatesPresentation {
    public private(set) var templates: [CustomSummaryTemplate] = []
    public private(set) var damaged: [DamagedSummaryTemplate] = []
    public private(set) var error: String?
    public let store: SummaryTemplateStore
    /// The open library's store and runner; set when a library opens.
    public var sessions: SessionStore?
    public var runner: FinalJobRunner?
    private let language: @MainActor () -> OutputLanguage

    /// `sessions` and `runner` are the open library's, so deleting a template
    /// can cancel its summaries; `language` is the summary language in Settings.
    public init(store: SummaryTemplateStore, sessions: SessionStore? = nil, runner: FinalJobRunner? = nil,
                language: @escaping @MainActor () -> OutputLanguage = { ProcessingPreferences.snapshot().summaryLanguage }) {
        self.store = store; self.sessions = sessions; self.runner = runner; self.language = language
    }

    public var builtIn: [SummaryTemplate] { SummaryTemplates.current }
    public var summaryLanguage: OutputLanguage { language() }

    public func refresh() async {
        await store.reload()
        templates = await store.templates()
        damaged = await store.damaged()
    }

    /// Validates a file the user chose, before anything is saved.
    public func check(_ text: String) async -> SummaryTemplateCheck {
        await store.check(text, language: language())
    }

    /// Saves a checked file: adds it, or replaces the template with its name.
    @discardableResult
    public func save(_ text: String) async -> CustomSummaryTemplate? {
        do {
            let value = try await store.save(text)
            error = nil
            await refresh()
            return value
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Summaries using the template that have not finished (queued, running or
    /// waiting for models), for the delete confirmation.
    public func unfinishedSummaries(using id: UUID) async -> Int {
        (try? await sessions?.unfinishedSummaryJobs(templateID: id).count) ?? 0
    }

    /// Deletes the template for good, then cancels its unfinished summaries; a
    /// job that starts in between finds the template missing and fails.
    public func delete(_ id: UUID) async {
        do {
            try await store.delete(id: id)
            if let sessions {
                for job in try await sessions.unfinishedSummaryJobs(templateID: id) {
                    if job.stage.isActive, job.stage != .queued, let runner {
                        try? await runner.cancel(jobID: job.id)
                    }
                    if let current = try? await sessions.job(job.id), !current.stage.isEnded {
                        try await sessions.updateJob(job.id, stage: .cancelled, error: SummaryJobError.templateDeleted.localizedDescription)
                    }
                }
            }
            error = nil
        } catch { self.error = error.localizedDescription }
        await refresh()
    }

    /// The file Export… saves: an imported template as imported, a built-in
    /// type in the summary language, as a starting point.
    public func exportText(_ template: CustomSummaryTemplate) -> String { template.text }
    public func exportText(_ template: SummaryTemplate) -> String {
        SummaryTemplateFile.render(template, language: language())
    }

    /// Show Prompt: exactly the instructions the model receives.
    public func prompt(_ template: SummaryTemplate) -> String {
        SummaryPrompt.system(template, language: language())
    }

    /// Download Guide & Example…: the files that would be replaced in `folder`.
    public nonisolated static func existingGuideFiles(in folder: URL) -> [String] {
        [SummaryTemplateGuide.guideFileName, SummaryTemplateGuide.exampleFileName].filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Writes the English guide and example into `folder`, replacing files of the same names.
    public nonisolated static func writeGuide(to folder: URL) throws {
        guard let guide = SummaryTemplateGuide.guideText, let example = SummaryTemplateGuide.exampleText else {
            throw SummaryTemplateStoreError.notFound
        }
        try Data(guide.utf8).write(to: folder.appendingPathComponent(SummaryTemplateGuide.guideFileName), options: .atomic)
        try Data(example.utf8).write(to: folder.appendingPathComponent(SummaryTemplateGuide.exampleFileName), options: .atomic)
    }
}
