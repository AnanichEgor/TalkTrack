import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

extension SummaryFixture {
    func settings(_ template: CustomSummaryTemplate) -> ProcessingSettings {
        var value = settings
        value.summaryType = .custom; value.customTemplate = template.reference
        return value
    }
    func pipeline(_ templates: SummaryTemplateStore) -> SummaryJobPipeline {
        SummaryJobPipeline(store: store, inference: inference, customTemplate: { await templates.template(id: $0) })
    }
    func enqueue(_ template: CustomSummaryTemplate) async throws -> ProcessingJob {
        try await store.enqueueSummary(meetingID: meeting.id, recordingID: recording.id, settings: settings(template), model: model)
    }
    func userVersion() throws -> Int {
        let path = "/" + DirectoryHandle.physicalComponents(library.directory).dropFirst().joined(separator: "/") + "/Library.sqlite3"
        return try SQLiteConnection(path: path, readOnly: true).integer("PRAGMA user_version")
    }
}

private func templateStore(_ folder: TemporaryFolder) -> SummaryTemplateStore {
    SummaryTemplateStore(directory: folder.url.appendingPathComponent("Templates", isDirectory: true))
}

private let corrected = SummaryTemplateFileTests.retro.replacingOccurrences(of: "## What Went Well", with: "## Wins")

extension SummaryJobTests {
    @Test func builtInSettingsKeepTheirJSONShape() throws {
        let built = try JSONEncoder().encode(ProcessingSettings())
        #expect(!String(decoding: built, as: UTF8.self).contains("customTemplate"))
        // Settings saved before custom templates decode unchanged.
        let old = #"{"meetingLanguage":"auto","summaryLanguage":"english","translationLanguage":"russian","contextLimit":32768,"summaryType":"standup","templateVersion":"4"}"#
        let decoded = try JSONDecoder().decode(ProcessingSettings.self, from: Data(old.utf8))
        #expect(decoded.summaryType == .standup && decoded.customTemplate == nil && decoded.spellingCorrection)
        var custom = ProcessingSettings(); custom.summaryType = .custom
        custom.customTemplate = CustomTemplateReference(id: UUID(), name: "Retro", contentHash: "ab")
        #expect(try JSONDecoder().decode(ProcessingSettings.self, from: JSONEncoder().encode(custom)) == custom)
        #expect(!SummaryType.allCases.contains(.custom))
        // Output records saved before the hash existed decode too.
        let output = GeneratedOutput(kind: .summary, job: ProcessingJobSnapshot(kind: .summary,
            source: SourceSnapshot(meetingID: UUID(), meetingGeneration: 0, cancellationGeneration: 0, recordingGenerations: [:],
                                   transcriptRevisionIDs: [], notesRevisionID: nil), settings: ProcessingSettings(), models: []), text: "x")
        let json = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        #expect(!json.contains("templateContentHash"))
        #expect(try JSONDecoder().decode(GeneratedOutput.self, from: Data(json.utf8)) == output)
    }

    @Test func customJobsNeedTheirReferenceAndRaiseTheSchemaOnce() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), templates = templateStore(folder)
        let retro = try await templates.save(SummaryTemplateFileTests.retro)
        // Built-in jobs and importing templates leave the library readable by older builds.
        _ = try await f.enqueue()
        #expect(try f.userVersion() == 3)
        var orphan = f.settings; orphan.summaryType = .custom
        await #expect(throws: SummaryGenerationError.invalidRequest) {
            try await f.store.enqueueSummary(meetingID: f.meeting.id, recordingID: f.recording.id, settings: orphan, model: f.model)
        }
        var mixed = f.settings; mixed.customTemplate = retro.reference
        await #expect(throws: SummaryGenerationError.invalidRequest) {
            try await f.store.enqueueSummary(meetingID: f.meeting.id, recordingID: f.recording.id, settings: mixed, model: f.model)
        }
        #expect(try f.userVersion() == 3)
        try await f.pipeline.run(jobID: try #require(try await f.store.jobs(meetingID: f.meeting.id).last?.id))
        let job = try await f.enqueue(retro)
        #expect(try f.userVersion() == 4)
        #expect(try await f.store.job(job.id).snapshot.settings.customTemplate == retro.reference)
        try await f.store.close()
        // Version 4 reopens here; a build whose newest schema is 3 refuses it as newer.
        let directory = try DirectoryHandle.openAbsolute(f.library.directory)
        #expect(try SQLiteConnection.closedHeader(in: directory).version == 4)
        #expect(SessionStore.schemaVersion == 4)
        let reopened = try await SessionStore.open(f.library)
        #expect(try await reopened.job(job.id).snapshot.settings.customTemplate?.name == "Sprint Retro")
        try await reopened.close()
    }

    @Test func retryAfterReplacementUsesTheNewVersionAndRecordsIt() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), templates = templateStore(folder)
        let retro = try await templates.save(SummaryTemplateFileTests.retro)
        let pipeline = f.pipeline(templates)
        await f.inference.set(.failure)
        let job = try await f.enqueue(retro)
        await #expect(throws: (any Error).self) { try await pipeline.run(jobID: job.id) }
        #expect(try await f.store.job(job.id).stage == .failed)
        #expect(await f.inference.systems.last?.contains("## What Went Well") == true)

        let replaced = try await templates.save(corrected)
        #expect(replaced.id == retro.id)
        await f.inference.set(.success)
        _ = try await f.store.retryJob(job.id)
        try await pipeline.run(jobID: job.id)
        #expect(await f.inference.systems.last?.contains("## Wins") == true)
        let output = try #require(try await f.output())
        #expect(output.text.hasPrefix("## Wins"))
        #expect(output.templateContentHash == replaced.contentHash && output.job.settings.customTemplate?.contentHash == retro.contentHash)
        // Made with the current version: not outdated.
        #expect(try await !f.store.isOutdated(output, settings: f.settings(replaced), templateHashes: await templates.hashes()))
    }

    @Test func outdatedByTemplateHashAndNeverForAMissingTemplate() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), templates = templateStore(folder)
        let retro = try await templates.save(SummaryTemplateFileTests.retro)
        let example = try await templates.save(try #require(SummaryTemplateGuide.exampleText))
        try await f.pipeline(templates).run(jobID: try await f.enqueue(retro).id)
        let output = try #require(try await f.output())
        #expect(output.templateContentHash == retro.contentHash)
        // Unchanged.
        #expect(try await !f.store.isOutdated(output, settings: f.settings(retro), templateHashes: await templates.hashes()))
        // Another template or a built-in type is a changed type.
        #expect(try await f.store.isOutdated(output, settings: f.settings(example), templateHashes: await templates.hashes()))
        #expect(try await f.store.isOutdated(output, settings: f.settings, templateHashes: await templates.hashes()))
        // Replaced.
        let replaced = try await templates.save(corrected)
        #expect(try await f.store.isOutdated(output, settings: f.settings(replaced), templateHashes: await templates.hashes()))
        // Missing: not outdated under its own template; another choice is a changed type.
        try await templates.delete(id: retro.id)
        #expect(try await !f.store.isOutdated(output, settings: f.settings(retro), templateHashes: await templates.hashes()))
        #expect(try await f.store.isOutdated(output, settings: f.settings, templateHashes: await templates.hashes()))
        // Built-in summaries are compared as before.
        try await f.pipeline.run(jobID: try await f.enqueue().id)
        let builtIn = try #require(try await f.output())
        #expect(try await !f.store.isOutdated(builtIn, settings: f.settings, templateHashes: await templates.hashes()))
        #expect(try await f.store.isOutdated(builtIn, settings: f.settings(example), templateHashes: await templates.hashes()))
    }

    @Test func missingTemplateFailsTheJobAndKeepsThePreviousSummary() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), templates = templateStore(folder)
        try await f.pipeline.run(jobID: try await f.enqueue().id)
        let previous = try await f.output()
        let retro = try await templates.save(SummaryTemplateFileTests.retro)
        let job = try await f.enqueue(retro)
        try await templates.delete(id: retro.id)
        await #expect(throws: SummaryJobError.templateDeleted) { try await f.pipeline(templates).run(jobID: job.id) }
        let failed = try await f.store.job(job.id)
        #expect(failed.stage == .failed && failed.lastError == SummaryJobError.templateDeleted.localizedDescription)
        #expect(try await f.output() == previous)
    }

    @Test func briefSpeakersLeaveOnlyThePerPersonSection() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), templates = templateStore(folder)
        let retro = try await templates.save(SummaryTemplateFileTests.retro)
        // "You" said 13 words in the first recording, below the 20-word threshold.
        await f.inference.set(reply: """
            ## What Went Well
            - Build 42 passed.

            ## What Did Not Go Well
            None noted.

            ## Updates by Person
            - **You**: will test build 42 tomorrow.

            ## Decisions
            - You agreed to keep the launch date.

            ## Action Items
            None noted.
            """)
        try await f.pipeline(templates).run(jobID: try await f.enqueue(retro).id)
        let text = try #require(try await f.output()).text
        #expect(!text.contains("**You**"))
        #expect(text.contains("## Updates by Person\nNone noted."))
        #expect(text.contains("- You agreed to keep the launch date."))
        #expect(await f.inference.systems.last?.contains("Leave out of Updates by Person anyone who only greeted") == true)
    }

    @Test func templateTooLargeFailsBeforeAnyModelWork() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url)
        try await f.pipeline.run(jobID: try await f.enqueue().id)
        let previous = try await f.output()
        // Injected past import validation, as a hand-edited store file could be.
        let text = SummaryTemplateFileTests.retro.replacingOccurrences(of: "one bullet each.", with: "one bullet each. OVERSIZE")
        let file = try #require(SummaryTemplateFile.parse(text).file)
        let huge = CustomSummaryTemplate(id: UUID(), text: text, contentHash: SummaryTemplateStore.hash(text), importedAt: Date(), file: file)
        await f.inference.set(oversizeMarker: "OVERSIZE")
        let generatedBefore = await f.inference.prompts.count
        let job = try await f.enqueue(huge)
        let pipeline = SummaryJobPipeline(store: f.store, inference: f.inference, customTemplate: { $0 == huge.id ? huge : nil })
        await #expect(throws: SummaryGenerationError.templateTooLarge(name: "Sprint Retro", context: "4K")) {
            try await pipeline.run(jobID: job.id)
        }
        #expect(await f.inference.prompts.count == generatedBefore)
        let failed = try await f.store.job(job.id)
        #expect(failed.stage == .failed && failed.lastError?.contains("“Sprint Retro” is too large for the 4K context") == true)
        #expect(try await f.output() == previous)
    }

    @Test func deletingATemplateCancelsOnlyItsUnfinishedSummaries() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), templates = templateStore(folder)
        try await f.pipeline.run(jobID: try await f.enqueue().id)
        let previous = try await f.output()
        let retro = try await templates.save(SummaryTemplateFileTests.retro)
        let example = try await templates.save(try #require(SummaryTemplateGuide.exampleText))
        let recordings = try await f.store.recordings(meetingID: f.meeting.id)
        let mine = try await f.enqueue(retro)
        let other = try await f.store.enqueueSummary(meetingID: f.meeting.id, recordingID: recordings[1].id,
                                                     settings: f.settings(example), model: f.model)
        let presentation = await SummaryTemplatesPresentation(store: templates, sessions: f.store, language: { .english })
        #expect(await presentation.unfinishedSummaries(using: retro.id) == 1)
        #expect(await presentation.unfinishedSummaries(using: example.id) == 1)
        await presentation.delete(retro.id)
        #expect(await templates.template(id: retro.id) == nil)
        #expect(try await f.store.job(mine.id).stage == .cancelled)
        #expect(try await f.store.job(other.id).stage == .queued)
        #expect(try await f.output() == previous)
        #expect(await presentation.templates.map(\.id) == [example.id])
    }

    @MainActor @Test func presentationAsksForATemplateWhenTheLastOneIsMissing() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), templates = templateStore(folder)
        let retro = try await templates.save(SummaryTemplateFileTests.retro)
        let pipeline = f.pipeline(templates)
        let runner = FinalJobRunner(store: f.store, kinds: [.summary]) { try await pipeline.run(jobID: $0) }
        let p = SummaryPresentation(meetingID: f.meeting.id, store: f.store, runner: runner, pipeline: pipeline,
                                    model: f.model, templates: templates, settings: { f.settings })
        await p.refresh()
        #expect(p.customTemplates.map(\.name) == ["Sprint Retro"])
        p.selection = .custom(retro.id)
        await p.generate(); await runner.idle(); await p.refresh()
        #expect(p.entries.allSatisfy { $0.output?.job.settings.customTemplate?.id == retro.id && !$0.outdated && !$0.templateMissing })

        // Replacing marks them outdated; Generate queues them again.
        _ = try await templates.save(corrected)
        await p.refresh()
        #expect(p.entries.allSatisfy(\.outdated) && p.canGenerate)

        // A new window on the meeting preselects the last template; after deletion it asks for one.
        let reopened = SummaryPresentation(meetingID: f.meeting.id, store: f.store, runner: runner, pipeline: pipeline,
                                           model: f.model, templates: templates, settings: { f.settings })
        await reopened.refresh()
        #expect(reopened.selection == .custom(retro.id))
        try await templates.delete(id: retro.id)
        let afterDelete = SummaryPresentation(meetingID: f.meeting.id, store: f.store, runner: runner, pipeline: pipeline,
                                              model: f.model, templates: templates, settings: { f.settings })
        await afterDelete.refresh()
        #expect(afterDelete.selection == nil)
        #expect(afterDelete.entries.allSatisfy { $0.output != nil && $0.templateMissing && !$0.outdated })
        #expect(!afterDelete.canGenerate && afterDelete.entries.allSatisfy { !afterDelete.canRegenerate($0) })
        // The open window loses the deleted selection too.
        await p.refresh()
        #expect(p.selection == nil && !p.canGenerate)

        // Choosing another template makes Generate and Regenerate available again.
        afterDelete.selection = .builtIn(.standup)
        await afterDelete.refresh()
        #expect(afterDelete.canGenerate && afterDelete.entries.allSatisfy { afterDelete.canRegenerate($0) })
        try await f.store.close()
    }
}
