import Foundation
import Synchronization
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

actor TranslationTestInference: TranslationTextInference {
    enum Mode { case normal, invalid, capped, wait, copyMixed }
    var mode: Mode = .normal
    var started = false
    var plans: [TextContextPlan] = []
    var seen: [[IndexedTranslation.Row]] = []
    func set(_ mode: Mode) { self.mode = mode; started = false }
    func translationTokenCount(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String) async throws -> Int {
        180 + prompt.count / 4
    }
    func translationText(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String,
                         outputTokens: Int) async throws -> TranslationTextResponse {
        started = true
        let rows = try JSONDecoder().decode([IndexedTranslation.Row].self, from: Data(prompt.utf8))
        let plan = try TextContextPlanner.resolve(selection: settings.contextLimit, role: .translation,
            inputTokens: 180 + prompt.count / 4, outputTokens: outputTokens)
        plans.append(plan); seen.append(rows)
        switch mode {
        case .wait: try await Task.sleep(for: .seconds(60))
        case .capped: if rows.count > 1 || rows[0].text.count > 150 { throw TranslationError.outputLimit }
        default: break
        }
        // copyMixed: a batch with any Russian row comes back unchanged (the
        // observed failure); a batch of only English rows is translated.
        let copies = mode == .copyMixed && rows.contains { !IndexedTranslation.needsTranslation($0.text, to: .russian) }
        let output = mode == .invalid ? [] : rows.map {
            IndexedTranslation.Row(id: $0.id, text: $0.text == "Hello, Alex." && settings.translationLanguage == .russian ? "Привет, Alex." :
                mode == .copyMixed && !copies && IndexedTranslation.needsTranslation($0.text, to: .russian) ? "Перевод: " + $0.text : $0.text)
        }
        return TranslationTextResponse(text: String(decoding: try JSONEncoder().encode(IndexedTranslation.Response(translations: output)), as: UTF8.self),
            contextPlan: plan, generatedTokens: max(1, rows.reduce(0) { $0 + $1.text.count / 4 }))
    }
    func waitForStart() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !started && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(started)
    }
}

@Suite struct TranslationTests {
    let model = ModelSnapshot(role: .translation, repository: "test", revision: "1",
                              directory: try! RelativePath("test/1"), preprocessingVersion: "1")
    func segment(_ text: String) throws -> TranscriptSegment {
        TranscriptSegment(recordingID: UUID(), dayID: UUID(), track: .microphone,
            interval: try MediaInterval(start: .zero, end: MediaTime(seconds: 2)), wallClockStart: Date(), speaker: .microphone, originalText: text)
    }
    func job(_ f: SummaryFixture) async throws -> ProcessingJob {
        try await f.store.enqueueTranslation(meetingID: f.meeting.id,
            settings: ProcessingSettings(contextLimit: .tokens4K, templateVersion: IndexedTranslation.version), model: model)
    }

    @Test func rejectsMissingDuplicateInventedAndExtraFields() throws {
        let rows = [IndexedTranslation.Row(id: "a", text: "One"), IndexedTranslation.Row(id: "b", text: "Two")]
        for output in [
            #"{"translations":[{"id":"a","text":"Один"}]}"#,
            #"{"translations":[{"id":"a","text":"Один"},{"id":"a","text":"Два"}]}"#,
            #"{"translations":[{"id":"a","text":"Один"},{"id":"c","text":"Два"}]}"#,
            #"{"translations":[{"id":"a","text":"Один","speaker":"Bad"},{"id":"b","text":"Два"}]}"#,
            #"{"translations":[{"id":"a","text":""},{"id":"b","text":"Два"}]}"#
        ] { #expect(throws: TranslationError.invalidOutput) { try IndexedTranslation.decode(output, rows: rows) } }
        let reordered = #"{"translations":[{"id":"b","text":"Два"},{"id":"a","text":"Один"}]}"#
        #expect(try IndexedTranslation.decode(reordered, rows: rows) == ["Один", "Два"])
    }

    @Test func everyContextCoversAllIDsAndOversizedUtterance() async throws {
        let long = (0..<1800).map { "word\($0)" }.joined(separator: " ")
        let segments = try [segment("Hello, Alex."), segment(long), segment(""), segment("Tail 42 not approved")]
        for limit in ContextLimit.allCases {
            let fake = TranslationTestInference()
            let translator = TranscriptTranslator(model: model, settings: ProcessingSettings(contextLimit: limit, templateVersion: IndexedTranslation.version), inference: fake)
            let result = try await translator.translate(segments)
            #expect(result.map(\.sourceSegmentID) == segments.map(\.id))
            #expect(result.map(\.text) == ["Привет, Alex.", long, "", "Tail 42 not approved"])
            #expect(await fake.plans.allSatisfy { $0.inputTokens + $0.outputTokens <= $0.contextTokens && $0.contextTokens <= 65536 })
        }
    }

    @Test func outputCapsSubdivideWithoutLosingWords() async throws {
        let text = (0..<90).map { "w\($0)" }.joined(separator: " ")
        let fake = TranslationTestInference(); await fake.set(.capped)
        let result = try await TranscriptTranslator(model: model, settings: ProcessingSettings(contextLimit: .tokens4K, templateVersion: IndexedTranslation.version), inference: fake)
            .translate([segment(text), segment("Last")])
        #expect(result.map(\.text) == [text, "Last"])
        #expect(await fake.seen.count > 2)
    }

    @Test func oneUnbreakableOversizedWordFailsWithoutClipping() async throws {
        let fake = TranslationTestInference()
        await #expect(throws: TranslationError.tooLarge) {
            try await TranscriptTranslator(model: model, settings: ProcessingSettings(contextLimit: .tokens4K, templateVersion: IndexedTranslation.version), inference: fake)
                .translate([segment(String(repeating: "x", count: 20_000))])
        }
        #expect(await fake.seen.isEmpty)
    }

    @Test func untranslatedRowsInAMixedBatchAreRetriedAlone() async throws {
        let fake = TranslationTestInference(); await fake.set(.copyMixed)
        let segments = try [segment("Мы договорились о дате релиза."), segment("Let's start with the release date."),
                            segment("Agreed, October 21 stays."), segment("OK"), segment("Согласен.")]
        let result = try await TranscriptTranslator(model: model,
            settings: ProcessingSettings(translationLanguage: .russian, contextLimit: .tokens4K, templateVersion: IndexedTranslation.version),
            inference: fake).translate(segments)
        #expect(result.map(\.text) == ["Мы договорились о дате релиза.", "Перевод: Let's start with the release date.",
                                        "Перевод: Agreed, October 21 stays.", "OK", "Согласен."])
        // One mixed request, then one request with only the two copied English rows.
        #expect(await fake.seen.map(\.count) == [5, 2])
        #expect(IndexedTranslation.needsTranslation("Let's start with the release date.", to: .russian))
        #expect(IndexedTranslation.needsTranslation("Agreed.", to: .russian))
        #expect(!IndexedTranslation.needsTranslation("TT-118 OK", to: .russian))
        #expect(!IndexedTranslation.needsTranslation("Сборка 42 прошла проверку.", to: .russian))
        #expect(IndexedTranslation.needsTranslation("Сборка 42 прошла проверку.", to: .english))
    }

    @Test func invalidSingleRowHasBoundedRetries() async throws {
        let fake = TranslationTestInference(); await fake.set(.invalid)
        await #expect(throws: TranslationError.invalidOutput) {
            try await TranscriptTranslator(model: model, settings: ProcessingSettings(templateVersion: IndexedTranslation.version), inference: fake).translate([segment("one")])
        }
        #expect(await fake.seen.count == 2)
    }

    @Test func savedDatesNamesYouAndAudioMetadataStayExact() throws {
        let meeting = Meeting(draft: try MeetingDraft(title: "Two days"))
        var recordings: [Recording] = [], revisions: [TranscriptRevision] = [], speakers: [DaySpeaker] = [], names: [SpeakerAssignment] = []
        for index in 0..<2 {
            let recording = try Recording(meetingID: meeting.id, startedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 3 * 86400), timeZoneIdentifier: "Europe/London")
            let voice = DaySpeaker(meetingID: meeting.id, dayID: recording.days[0].id, number: 1)
            recordings.append(recording); speakers.append(voice)
            names.append(SpeakerAssignment(meetingID: meeting.id, dayID: voice.dayID, daySpeakerID: voice.id, name: "Alex",
                origin: .manual, evidence: []))
            let segments = try [AudioTrack.system, .microphone].enumerated().map { offset, track in
                TranscriptSegment(recordingID: recording.id, dayID: voice.dayID, track: track,
                    interval: try MediaInterval(start: MediaTime(seconds: Double(offset) * 4), end: MediaTime(seconds: Double(offset) * 4 + 2)),
                    wallClockStart: recording.startedAt.addingTimeInterval(Double(offset) * 4), speaker: .system(daySpeakerID: voice.id), originalText: "Hello")
            }
            revisions.append(TranscriptRevision(recordingID: recording.id, sourceGeneration: 0, kind: .final, segments: segments, modelRevisions: []))
        }
        let snapshot = ProcessingJobSnapshot(kind: .translation, source: SourceSnapshot(meetingID: meeting.id, meetingGeneration: 0,
            cancellationGeneration: 0, recordingGenerations: [:], transcriptRevisionIDs: revisions.map(\.id), notesRevisionID: nil),
            settings: ProcessingSettings(), models: [model])
        let source = TranslationSource(job: snapshot, recordings: recordings, revisions: revisions, speakers: speakers, assignments: names)
        let original = try source.items()
        let translated = try source.items(translations: revisions.flatMap(\.segments).map { TranslatedSegment(sourceSegmentID: $0.id, text: "Привет") })
        #expect(original.map(\.id) == translated.map(\.id))
        for (before, after) in zip(original, translated) {
            switch (before, after) {
            case (.date(let a), .date(let b)): #expect(a == b)
            case (.speech(let a), .speech(let b)):
                #expect(a.speakerLabel == b.speakerLabel); #expect(a.timestamp == b.timestamp)
                #expect(a.segments.map(\.interval) == b.segments.map(\.interval))
                #expect(a.segments.map(\.wallClockStart) == b.segments.map(\.wallClockStart))
                #expect(a.segments.map(\.originalText) == b.segments.map(\.originalText))
                #expect(b.text.contains("Привет"))
            default: Issue.record("Metadata changed")
            }
        }
        #expect(translated.map(\.text).joined().contains("resumption"))
        #expect(translated.map(\.text).joined().contains("You"))
        #expect(translated.map(\.text).joined().contains("Alex"))
    }

    @Test func durablePipelineRetainsOldOnFailureAndReopens() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), fake = TranslationTestInference()
        let pipeline = TranslationJobPipeline(store: f.store, inference: fake)
        let first = try await job(f); try await pipeline.run(jobID: first.id)
        let old = try #require(await f.store.output(.translation, meetingID: f.meeting.id))
        let items = try await f.store.translatedItems(old)
        #expect(items.map(\.text).joined(separator: "\n\n") == old.text)
        let second = try await job(f); await fake.set(.invalid)
        await #expect(throws: TranslationError.invalidOutput) { try await pipeline.run(jobID: second.id) }
        #expect(try await f.store.output(.translation, meetingID: f.meeting.id) == old)
        try await f.store.close()
        let reopened = try await SessionStore.open(f.library)
        #expect(try await reopened.output(.translation, meetingID: f.meeting.id) == old)
        _ = try await reopened.retryJob(second.id); await fake.set(.normal)
        try await TranslationJobPipeline(store: reopened, inference: fake).run(jobID: second.id)
        #expect(try await reopened.output(.translation, meetingID: f.meeting.id)?.job == second.snapshot)
        try await reopened.close()
    }

    @Test func cancellationAndMissingModelsKeepOldOutput() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), fake = TranslationTestInference()
        let pipeline = TranslationJobPipeline(store: f.store, inference: fake)
        try await pipeline.run(jobID: job(f).id)
        let old = try await f.store.output(.translation, meetingID: f.meeting.id)
        let next = try await job(f)
        let missing = TranslationJobPipeline(store: f.store, inference: fake, missing: { _ in [.translation] })
        await #expect(throws: TranslationError.missingModel) { try await missing.run(jobID: next.id) }
        #expect(try await f.store.job(next.id).stage == .waitingForModels)
        _ = try await f.store.retryJob(next.id); await fake.set(.wait)
        let runner = FinalJobRunner(store: f.store, kinds: [.translation]) { try await pipeline.run(jobID: $0) }
        await runner.wake(); try await fake.waitForStart()
        await runner.setCaptureActive(true); await runner.idle()
        #expect(try await f.store.job(next.id).stage == .interrupted)
        #expect(try await f.store.output(.translation, meetingID: f.meeting.id) == old)
        try await f.store.close()
    }

    /// Task 11.4: the model is removed in Settings while the job runs.
    @Test func modelRemovedDuringTranslationWaitsForIt() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), fake = TranslationTestInference()
        try await TranslationJobPipeline(store: f.store, inference: fake).run(jobID: job(f).id)
        let old = try await f.store.output(.translation, meetingID: f.meeting.id)
        let next = try await job(f); await fake.set(.invalid)
        let checks = Mutex(0)
        let removed = TranslationJobPipeline(store: f.store, inference: fake, missing: { _ in
            checks.withLock { $0 += 1; return $0 == 1 ? [] : [.translation] }
        })
        await #expect(throws: TranslationError.missingModel) { try await removed.run(jobID: next.id) }
        #expect(try await f.store.job(next.id).stage == .waitingForModels)
        #expect(try await f.store.output(.translation, meetingID: f.meeting.id) == old)
        try await f.store.close()
    }

    @Test func independentSettingsAndNotesOnlyAffectRelevantOutputs() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), fake = TranslationTestInference()
        try await f.pipeline.run(jobID: f.enqueue().id)
        let summary = try #require(await f.output())
        let job = try await job(f)
        try await TranslationJobPipeline(store: f.store, inference: fake).run(jobID: job.id)
        let translation = try #require(await f.store.output(.translation, meetingID: f.meeting.id))
        var settings = f.settings
        #expect(try await !f.store.isOutdated(summary, settings: settings))
        #expect(try await !f.store.isOutdated(translation, settings: settings))
        settings.summaryLanguage = .russian
        #expect(try await f.store.isOutdated(summary, settings: settings))
        #expect(try await !f.store.isOutdated(translation, settings: settings))
        settings = f.settings; settings.translationLanguage = .english
        #expect(try await !f.store.isOutdated(summary, settings: settings))
        #expect(try await f.store.isOutdated(translation, settings: settings))
        try await f.store.commitNotes(NotesRevision(meetingID: f.meeting.id, text: "Notes changed"))
        // Notes are input to neither output.
        #expect(try await !f.store.isOutdated(summary, settings: f.settings))
        #expect(try await !f.store.isOutdated(translation, settings: f.settings))
        settings = f.settings; settings.contextLimit = .automatic
        #expect(try await f.store.isOutdated(summary, settings: settings))
        #expect(try await f.store.isOutdated(translation, settings: settings))
        #expect(try await f.store.jobs(meetingID: f.meeting.id).filter { $0.snapshot.kind == .translation }.count == 1)
        try await f.store.close()
    }
}
