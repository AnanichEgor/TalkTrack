import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// Task 7.5: the Settings preferences the tabs read. Changing one output's
/// language or the context marks only the affected saved output outdated and
/// never enqueues regeneration.
@MainActor @Suite struct OutputSettingsTests {
    @Test func preferenceChangesMarkOnlyRelevantOutputsWithoutRegenerating() async throws {
        let suite = "TalkTrack.OutputSettingsTest.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ProcessingPreferences.context(in: defaults) == .small)
        #expect(ProcessingPreferences.snapshot(from: defaults).contextLimit.rawValue == 32768)

        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), summaries = f.pipeline
        let translations = TranslationJobPipeline(store: f.store, inference: TranslationTestInference())
        let runner = FinalJobRunner(store: f.store, kinds: [.summary, .translation]) { id in
            switch try await f.store.job(id).snapshot.kind {
            case .summary: try await summaries.run(jobID: id)
            default: try await translations.run(jobID: id)
            }
        }
        let preferences: @MainActor () -> ProcessingSettings = { ProcessingPreferences.snapshot(from: defaults) }
        let translationModel = try ModelCatalog.bundled().model(for: .translation).snapshot(for: .translation)
        let summary = SummaryPresentation(meetingID: f.meeting.id, store: f.store, runner: runner, pipeline: summaries, model: f.model, settings: preferences)
        let translation = TranslationPresentation(meetingID: f.meeting.id, store: f.store, runner: runner,
            pipeline: translations, model: translationModel, settings: preferences)
        func refreshed() async { await runner.idle(); await summary.refresh(); await translation.refresh() }
        func jobCount() async throws -> Int {
            try await f.store.jobs(meetingID: f.meeting.id).filter { $0.snapshot.kind != .finalTranscription }.count
        }

        await summary.refresh(); await translation.refresh()
        await summary.generate(); await translation.generate(); await refreshed()
        let savedSummary = try #require(summary.entries.first?.output), savedTranslation = try #require(translation.output)
        #expect(savedSummary.job.settings.contextLimit == .small && savedTranslation.job.settings.translationLanguage == .russian)
        #expect(summary.entries.allSatisfy { !$0.outdated } && !translation.outdated)
        #expect(try await jobCount() == 3)

        defaults.set(OutputLanguage.russian.rawValue, forKey: ProcessingPreferences.summaryLanguageKey)
        await refreshed()
        #expect(summary.entries.allSatisfy(\.outdated) && !translation.outdated)
        #expect(ProcessingPreferences.translationLanguage(in: defaults) == .russian)

        defaults.set(OutputLanguage.english.rawValue, forKey: ProcessingPreferences.summaryLanguageKey)
        defaults.set(OutputLanguage.english.rawValue, forKey: ProcessingPreferences.translationLanguageKey)
        await refreshed()
        #expect(summary.entries.allSatisfy { !$0.outdated } && translation.outdated)
        #expect(ProcessingPreferences.summaryLanguage(in: defaults) == .english)

        defaults.set(OutputLanguage.russian.rawValue, forKey: ProcessingPreferences.translationLanguageKey)
        defaults.set(ContextLimit.automatic.rawValue, forKey: ProcessingPreferences.contextKey)
        await refreshed()
        #expect(ProcessingPreferences.context(in: defaults) == .automatic)
        #expect(summary.entries.allSatisfy(\.outdated) && translation.outdated)

        // Saved results stay visible and nothing was queued by the changes.
        #expect(summary.entries.first?.output == savedSummary && translation.output == savedTranslation)
        #expect(try await jobCount() == 3)
        #expect(try await f.store.summary(meetingID: f.meeting.id, recordingID: f.recording.id) == savedSummary)

        // An explicit request snapshots the new context; it clears only that output.
        await translation.generate(); await refreshed()
        #expect(translation.output?.job.settings.contextLimit == .automatic)
        #expect(!translation.outdated && summary.entries.allSatisfy(\.outdated))
        #expect(try await jobCount() == 4)
        try await f.store.close()
    }
}
