import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

actor SummaryJobInference: SummaryTextInference {
    enum Mode { case success, failure, wait, malformed, malformedFirst }
    var mode: Mode = .success
    var started = false
    var prompts: [String] = []
    var attempts: [Int] = []
    func set(_ mode: Mode) { self.mode = mode; started = false }
    func tokenCounts(_ model: ModelSnapshot, settings: ProcessingSettings, texts: [String]) async throws -> [Int] {
        texts.map { $0.count / 4 + 1 }
    }
    func formattedTokenCount(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String) async throws -> Int { 600 }
    func summaryText(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String,
                     outputTokens: Int?, attempt: Int) async throws -> SummaryTextResponse {
        started = true; prompts.append(prompt); attempts.append(attempt)
        switch mode {
        case .failure: throw SummaryGenerationError.outputLimit
        case .wait: try await Task.sleep(for: .seconds(60))
        case .success, .malformed, .malformedFirst: break
        }
        let template = SummaryTemplates.template(settings.summaryType)!
        let text = mode == .malformed || (mode == .malformedFirst && attempt == 0) ? "A truncated outline" : template.sections.map {
            "## " + $0.title(settings.summaryLanguage) + "\nNone noted."
        }.joined(separator: "\n\n")
        return SummaryTextResponse(text: text,
            contextPlan: try TextContextPlanner.resolve(selection: settings.contextLimit, role: .summary,
                inputTokens: 600, outputTokens: outputTokens), generatedTokens: 60)
    }
    func waitForStart() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !started && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(started)
    }
}

struct SummaryFixture {
    let library: OpenedLibrary
    let store: SessionStore
    let meeting: Meeting
    let recording: Recording
    let inference = SummaryJobInference()
    let model: ModelSnapshot
    var settings: ProcessingSettings { ProcessingSettings(contextLimit: .tokens4K) }
    var pipeline: SummaryJobPipeline { SummaryJobPipeline(store: store, inference: inference) }
    func enqueue() async throws -> ProcessingJob {
        try await store.enqueueSummary(meetingID: meeting.id, recordingID: recording.id, settings: settings, model: model)
    }
    func output() async throws -> GeneratedOutput? { try await store.summary(meetingID: meeting.id, recordingID: recording.id) }
    static func make(_ root: URL) async throws -> Self {
        let library = try await OwnedLibrary().open(root: root)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Release planning", description: "Build 42 and launch"))
        let model = try ModelCatalog.bundled().model(for: .summary).snapshot(for: .summary)
        var first: Recording?
        for day in 0..<2 {
            let start = ISO8601DateFormatter().date(from: day == 0 ? "2026-10-09T09:00:00Z" : "2026-10-12T09:00:00Z")!
            var recording = try Recording(meetingID: meeting.id, startedAt: start, timeZoneIdentifier: "UTC")
            recording.state = .complete; recording.activeDuration = try MediaTime(seconds: 10)
            recording.endedAt = start.addingTimeInterval(10)
            try await store.saveRecording(recording)
            if first == nil { first = recording }
            let segment = TranscriptSegment(recordingID: recording.id, dayID: recording.days[0].id, track: .microphone,
                interval: try MediaInterval(start: .zero, end: MediaTime(seconds: 8)), wallClockStart: start,
                speaker: .microphone, originalText: day == 0 ? "I will test build 42 tomorrow. We agreed to keep the launch date." :
                    "Сборка 42 прошла проверку. Дату запуска не меняем. Я обновлю список ошибок в пятницу.")
            let job = try await store.enqueue(kind: .finalTranscription, meetingID: meeting.id, recordingID: recording.id,
                settings: ProcessingSettings(), models: [])
            try await store.publishTranscript(TranscriptRevision(recordingID: recording.id, sourceGeneration: recording.generation,
                kind: .final, segments: [segment], modelRevisions: []), jobID: job.id)
        }
        try await store.commitNotes(NotesRevision(meetingID: meeting.id, text: "The budget is 500 euros. No additional owner was assigned."))
        return Self(library: library, store: store, meeting: meeting, recording: first!, model: model)
    }
}

@Suite struct SummaryJobTests {
    @Test func explicitEnqueueSnapshotsSourcesAndSurvivesReopen() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url)
        #expect(try await f.store.jobs(meetingID: f.meeting.id).allSatisfy { $0.snapshot.kind == .finalTranscription })
        #expect(try await f.output() == nil)
        let job = try await f.enqueue()
        let source = try await f.store.summarySource(jobID: job.id)
        // One recording only, and notes are not input.
        #expect(source.revisions.map(\.recordingID) == [f.recording.id] && source.recordings.map(\.id) == [f.recording.id])
        #expect(try !source.transcript().map(\.text).joined().contains("resumption"))
        #expect(source.notes == nil)
        try await f.store.renameMeeting(f.meeting.id, title: "Later title")
        try await f.store.commitNotes(NotesRevision(meetingID: f.meeting.id, text: "Later notes"))
        try await f.store.updateJob(job.id, stage: .generating)
        try await f.store.close()
        let reopened = try await SessionStore.open(f.library)
        #expect(try await reopened.job(job.id).stage == .interrupted)
        _ = try await reopened.retryJob(job.id)
        #expect(try await reopened.summarySource(jobID: job.id) == source)
        try await SummaryJobPipeline(store: reopened, inference: f.inference).run(jobID: job.id)
        let output = try #require(await reopened.summary(meetingID: f.meeting.id, recordingID: f.recording.id))
        #expect(try await reopened.isOutdated(output, settings: f.settings))
        #expect(output.job == job.snapshot)
        #expect(await f.inference.prompts.first?.contains("notes") == false)
        #expect(await f.inference.prompts.first?.contains("Сборка 42") == false)
        #expect(try await reopened.notes(meetingID: f.meeting.id)?.text == "Later notes")
        try await reopened.close()
    }

    @Test func requiresFinalRecordingAndRejectsDuplicate() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url)
        let job = try await f.enqueue()
        await #expect(throws: SummaryJobError.alreadyQueued) { try await f.enqueue() }
        try await f.store.updateJob(job.id, stage: .interrupted)
        // Another recording without final text cannot be summarized, and does not block this one.
        var extra = try Recording(meetingID: f.meeting.id, timeZoneIdentifier: "UTC")
        extra.state = .complete
        try await f.store.saveRecording(extra)
        await #expect(throws: SummaryJobError.finalRequired) {
            try await f.store.enqueueSummary(meetingID: f.meeting.id, recordingID: extra.id, settings: f.settings, model: f.model)
        }
        _ = try await f.enqueue()
        let empty = try await f.store.createMeeting(MeetingDraft(title: "Notes only"))
        try await f.store.commitNotes(NotesRevision(meetingID: empty.id, text: "Notes"))
        #expect(try await f.store.enqueueSummaries(meetingID: empty.id, settings: f.settings, model: f.model).isEmpty)
        try await f.store.close()
    }

    @Test func failedReplacementKeepsOldThenRetryPublishes() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), pipeline = f.pipeline
        try await pipeline.run(jobID: f.enqueue().id)
        let old = try #require(await f.output())
        let job = try await f.enqueue()
        await f.inference.set(.failure)
        await #expect(throws: SummaryGenerationError.outputLimit) { try await pipeline.run(jobID: job.id) }
        #expect(try await f.output() == old)
        #expect(try await f.store.job(job.id).stage == .failed)
        await f.inference.set(.success)
        #expect(try await f.store.retryJob(job.id).snapshot == job.snapshot)
        try await pipeline.run(jobID: job.id)
        #expect(try await f.output()?.job == job.snapshot)
        #expect(try await f.store.job(job.id).stage == .completed)
        try await f.store.close()
    }

    @Test func invalidFormatNeverReplacesSavedOutput() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), pipeline = f.pipeline
        try await pipeline.run(jobID: f.enqueue().id)
        let old = try await f.output()
        let job = try await f.enqueue()
        await f.inference.set(.malformed)
        await #expect(throws: SummaryJobError.invalidOutput) { try await pipeline.run(jobID: job.id) }
        #expect(try await f.output() == old)
        #expect(try await f.store.job(job.id).stage == .failed)
        try await f.store.close()
    }

    @Test func invalidFormatGetsDifferentlySeededRetries() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url)
        await f.inference.set(.malformedFirst)
        try await f.pipeline.run(jobID: f.enqueue().id)
        #expect(await f.inference.attempts == [0, 1])
        #expect(try await f.output() != nil)
        // Invalid responses fail after exactly three attempts.
        await f.inference.set(.malformed)
        let job = try await f.enqueue()
        await #expect(throws: SummaryJobError.invalidOutput) { try await f.pipeline.run(jobID: job.id) }
        #expect(await f.inference.attempts == [0, 1, 0, 1, 2])
        try await f.store.close()
    }

    @Test func cancelledRunningAndQueuedJobsRetainPreviousOutput() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), pipeline = f.pipeline
        try await pipeline.run(jobID: f.enqueue().id)
        let old = try await f.output()
        let runner = FinalJobRunner(store: f.store, kinds: [.summary]) { try await pipeline.run(jobID: $0) }
        await f.inference.set(.wait)
        let job = try await f.enqueue()
        await runner.wake(); try await f.inference.waitForStart()
        #expect(await pipeline.status(jobID: job.id) == .direct)
        try await runner.cancel(jobID: job.id)
        await runner.idle()
        #expect(try await f.store.job(job.id).stage == .interrupted)
        #expect(try await f.output() == old)
        let queued = try await f.enqueue()
        try await runner.cancel(jobID: queued.id)
        #expect(try await f.store.job(queued.id).stage == .interrupted)
        try await f.store.close()
    }

    @Test func missingModelWaitsAndRetryUsesSameSource() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url)
        let job = try await f.enqueue()
        let pipeline = SummaryJobPipeline(store: f.store, inference: f.inference, missing: { _ in [.summary] })
        await #expect(throws: SummaryJobError.missingModel) { try await pipeline.run(jobID: job.id) }
        #expect(try await f.store.job(job.id).stage == .waitingForModels)
        #expect(await f.inference.prompts.isEmpty)
        _ = try await f.store.retryJob(job.id)
        try await f.pipeline.run(jobID: job.id)
        #expect(try await f.store.job(job.id).stage == .completed)
        try await f.store.close()
    }

    @Test func publicationFailureRollsBackHeadAndCanRetry() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), pipeline = f.pipeline
        try await pipeline.run(jobID: f.enqueue().id)
        let old = try await f.output()
        let job = try await f.enqueue()
        let path = "/" + DirectoryHandle.physicalComponents(f.library.directory).dropFirst().joined(separator: "/")
        let db = try SQLiteConnection(path: path + "/Library.sqlite3")
        try db.execute("CREATE TRIGGER fail_summary BEFORE UPDATE ON heads WHEN NEW.kind='summary' BEGIN SELECT RAISE(ABORT, 'disk failure'); END")
        await #expect(throws: StoreError.self) { try await pipeline.run(jobID: job.id) }
        #expect(try await f.output() == old)
        try db.execute("DROP TRIGGER fail_summary")
        _ = try await f.store.retryJob(job.id)
        try await pipeline.run(jobID: job.id)
        #expect(try await f.output()?.job.id == job.id)
        try await f.store.close()
    }

    @Test func captureAndShutdownInterruptGeneration() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), pipeline = f.pipeline
        let runner = FinalJobRunner(store: f.store, kinds: [.summary]) { try await pipeline.run(jobID: $0) }
        await f.inference.set(.wait)
        let job = try await f.enqueue()
        await runner.wake(); try await f.inference.waitForStart()
        await runner.setCaptureActive(true)
        await runner.idle()
        #expect(try await f.store.job(job.id).stage == .interrupted)
        await f.inference.set(.wait)
        try await runner.retry(jobID: job.id)
        await runner.idle()
        #expect(await !f.inference.started)
        await runner.setCaptureActive(false)
        try await f.inference.waitForStart()
        #expect(await runner.shutDown() == job.id)
        await runner.idle()
        #expect(try await f.store.job(job.id).stage == .interrupted)
        try await f.store.close()
    }

    @Test func deletionRefusesLatePublication() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url)
        let job = try await f.enqueue()
        try await f.store.deleteMeeting(f.meeting.id)
        await #expect(throws: StoreError.self) { try await f.pipeline.run(jobID: job.id) }
        await #expect(throws: StoreError.self) {
            try await f.store.publishOutput(GeneratedOutput(kind: .summary, job: job.snapshot, text: "Late"))
        }
        #expect(try await f.store.meetings().isEmpty)
        try await f.store.close()
    }

    /// Task 7.7: each recording gets its own summary, listed in order.
    @MainActor @Test func presentationListsOneSummaryPerRecording() async throws {
        let folder = try TemporaryFolder()
        let export = ProcessInfo.processInfo.environment["TALKTRACK_SUMMARY_FIXTURE"]
        defer { if export == nil { folder.remove() } }
        let f = try await SummaryFixture.make(folder.url), pipeline = f.pipeline
        let runner = FinalJobRunner(store: f.store, kinds: [.summary]) { try await pipeline.run(jobID: $0) }
        let p = SummaryPresentation(meetingID: f.meeting.id, store: f.store,
            runner: runner, pipeline: pipeline, model: f.model, settings: { f.settings })
        await p.refresh()
        #expect(p.entries.map(\.number) == [1, 2] && p.entries.allSatisfy { $0.output == nil && $0.requirement == nil })
        #expect(p.pending.count == 2 && p.canGenerate)
        p.type = .standup
        await p.generate(); await runner.idle(); await p.refresh()
        #expect(p.entries.allSatisfy { $0.output?.job.settings.summaryType == .standup && !$0.outdated })
        #expect(p.entries[0].output?.job.recordingID == p.entries[0].recording.id)
        let prompts = await f.inference.prompts
        #expect(prompts.count == 2)
        #expect(prompts[0].contains("build 42 tomorrow") && !prompts[0].contains("Сборка 42"))
        #expect(prompts[1].contains("Сборка 42") && !prompts[1].contains("build 42 tomorrow"))
        #expect(!prompts.contains { $0.contains("500 euros") })
        #expect(!p.canGenerate)

        // Notes are not input; nothing becomes outdated or is queued again.
        try await f.store.commitNotes(NotesRevision(meetingID: f.meeting.id, text: "New notes"))
        await p.refresh()
        #expect(p.entries.allSatisfy { !$0.outdated } && !p.canGenerate)

        // A failed regeneration of one recording keeps both saved summaries.
        let kept = p.entries.map(\.output)
        await f.inference.set(.malformed)
        await p.regenerate(p.entries[1]); await runner.idle(); await p.refresh()
        #expect(p.entries.map(\.output) == kept)
        #expect(p.entries[1].canRetry && p.entries[1].status != nil && p.entries[0].status == nil)
        await f.inference.set(.success)
        await p.retry(p.entries[1]); await runner.idle(); await p.refresh()
        #expect(p.entries[1].output != kept[1] && p.entries[0].output == kept[0])

        // Another type makes every summary outdated; Generate queues them all.
        p.type = .auto; await p.refresh()
        #expect(p.entries.allSatisfy(\.outdated) && p.pending.count == 2)
        if let export { try folder.url.path.write(toFile: export, atomically: true, encoding: .utf8) }
        try await f.store.close()
    }
}
