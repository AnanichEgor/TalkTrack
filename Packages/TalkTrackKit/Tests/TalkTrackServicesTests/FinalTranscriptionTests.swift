import AVFoundation
import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

actor FinalProbe: FinalTranscriptionInference {
    var missing: [ModelRole] = [], textCalls = 0, alignmentCalls = 0, correctionCalls = 0, speakerCalls = 0
    var failAlignment = false, malformedAlignment = false, unsafeCorrection = false, oneBlockBudget = false
    var holdAlignment = false, held = false
    /// Real Qwen alignment can end the last words after the source audio.
    var overrunEnd = false
    /// Auto calls from this number on report an unsupported language.
    var undetectedFrom = Int.max, undetectedUntil = 0
    func undetected(from call: Int) { undetectedFrom = call }
    /// Auto calls before this number report an unsupported language.
    func undetected(until call: Int) { undetectedUntil = call }
    var text = "Alex will not pay 42 rubles tomorow"
    /// What the microphone track says; nil repeats `text`, which is an echo of the system track.
    var microphoneText: String?
    var maximumFrames = 0
    func unavailableFinalModels(_ models: [ModelSnapshot]) -> [ModelRole] { missing }
    func configure(missing: [ModelRole] = [], fail: Bool = false, malformed: Bool = false,
                   unsafeResult: Bool = false, partition: Bool = false, hold: Bool = false, text: String? = nil,
                   microphoneText: String? = nil) {
        self.missing = missing; failAlignment = fail; malformedAlignment = malformed
        unsafeCorrection = unsafeResult; oneBlockBudget = partition; holdAlignment = hold
        if let text { self.text = text }
        if let microphoneText { self.microphoneText = microphoneText }
    }
    func finalText(_ model: ModelSnapshot, samples: [Float], language: MeetingLanguage) -> FinalASRText {
        textCalls += 1; maximumFrames = max(maximumFrames, samples.count)
        if language == .auto, textCalls >= undetectedFrom || textCalls < undetectedUntil { return FinalASRText(text: "Olha eu sou lento", language: .auto) }
        let microphone = (samples.map(abs).max() ?? 0) > 0.15
        return FinalASRText(text: microphone ? microphoneText ?? text : text, language: language == .russian ? .russian : .english)
    }
    func finalAlignment(_ model: ModelSnapshot, samples: [Float], text: String, language: MeetingLanguage) async throws -> [FinalAlignmentItem] {
        alignmentCalls += 1
        if failAlignment { throw FinalTranscriptionError.invalidAlignment }
        held = true
        while holdAlignment { try await Task.sleep(for: .milliseconds(5)) }
        let words = text.split(separator: " ").map(String.init)
        let duration = Double(samples.count) / 16_000
        let step = min(0.2, duration / Double(words.count + 1))
        let result = try words.enumerated().map { index, word in
            try FinalAlignmentItem(text: String(word.filter { $0.isLetter || $0.isNumber || $0 == "'" }), relative: MediaInterval(start: MediaTime(seconds: Double(index) * step),
                end: MediaTime(seconds: Double(index + 1) * step)))
        }
        if overrunEnd, result.count >= 2 {
            // As observed on real audio: a zero-length first word, and the last
            // words placed after the source audio.
            var tail = [try FinalAlignmentItem(text: result[0].text,
                relative: MediaInterval(start: MediaTime(seconds: 0.08), end: MediaTime(seconds: 0.08)))]
            tail += Array(result.dropFirst().dropLast(2))
            tail.append(try FinalAlignmentItem(text: result[result.count - 2].text,
                relative: MediaInterval(start: MediaTime(seconds: duration - 0.1), end: MediaTime(seconds: duration + 0.2))))
            tail.append(try FinalAlignmentItem(text: result[result.count - 1].text,
                relative: MediaInterval(start: MediaTime(seconds: duration + 0.2), end: MediaTime(seconds: duration + 0.4))))
            return tail
        }
        return malformedAlignment ? Array(result.dropLast()) : result
    }
    func overrun() { overrunEnd = true }
    func correctIndexed(_ model: ModelSnapshot, settings: ProcessingSettings, blocks: [IndexedCorrection]) throws -> FinalCorrectionResponse {
        correctionCalls += 1
        if oneBlockBudget && blocks.count > 1 { throw FinalTranscriptionError.correctionBudget }
        let result = blocks.map { IndexedCorrection(id: $0.id, text: unsafeCorrection ? $0.text.replacingOccurrences(of: "42", with: "43") :
            $0.text.replacingOccurrences(of: "tomorow", with: "tomorrow").replacingOccurrences(of: "завтро", with: "завтра")) }
        return FinalCorrectionResponse(text: try IndexedSpellingCorrection.response(result, originals: blocks),
            contextPlan: try TextContextPlanner.resolve(selection: settings.contextLimit, role: .spelling, inputTokens: 100), generatedTokens: 50)
    }
    func speakerActivity(_ model: ModelSnapshot, samples: [Float]) throws -> [SpeakerWindowActivity] {
        speakerCalls += 1
        return [SpeakerWindowActivity(slot: 1, relative: try MediaInterval(start: .zero, end: MediaTime(seconds: Double(samples.count) / 16_000)))]
    }
    func speakerEmbedding(_ model: ModelSnapshot, samples: [Float]) -> SpeakerWindowEmbedding {
        SpeakerWindowEmbedding(values: [1] + Array(repeating: 0, count: 255), model: model)
    }
}

struct FinalFixture {
    let library: OpenedLibrary
    let store: SessionStore
    let recording: Recording
    let job: ProcessingJob
    let previous: TranscriptRevision
}
func finalFixture(_ folder: TemporaryFolder, seconds: Double = 3, language: MeetingLanguage = .english,
                          microphoneOnly: Bool = false, resumed: Bool = false, meetingID: UUID? = nil,
                          spelling: Bool = true, quietMicrophone: Bool = false) async throws -> FinalFixture {
    let library = try await OwnedLibrary().open(root: folder.url)
    let store = try await SessionStore.open(library)
    let owner: Meeting
    if let meetingID { owner = try await store.meeting(meetingID) }
    else { owner = try await store.createMeeting(MeetingDraft(title: "Final fixture")) }
    let start = ISO8601DateFormatter().date(from: "2026-10-08T10:00:00Z")!
    let recording = try Recording(meetingID: owner.id, startedAt: start, timeZoneIdentifier: "Europe/London")
    let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
    let origin = AVAudioTime.hostTime(forSeconds: 100)
    var clock = CaptureIntervalClock()
    try clock.begin(hostTime: origin, wallClock: start, timeZoneIdentifier: "Europe/London")
    if resumed {
        try clock.close(at: origin + AVAudioTime.hostTime(forSeconds: seconds / 2))
        try clock.begin(hostTime: origin + AVAudioTime.hostTime(forSeconds: 172_800),
            wallClock: start.addingTimeInterval(172_800), timeZoneIdentifier: "Asia/Tokyo")
        try clock.close(at: origin + AVAudioTime.hostTime(forSeconds: 172_800 + seconds / 2))
    } else { try clock.close(at: origin + AVAudioTime.hostTime(forSeconds: seconds)) }
    try await writer.updateCaptureTiming(clock.closedSnapshot, state: .recording)
    let frames = Int((seconds * 48_000).rounded())
    for track in microphoneOnly ? [.microphone] : AudioTrack.allCases {
        var offset = 0
        while offset < frames {
            let boundary = resumed && offset < frames / 2 ? frames / 2 : frames
            let count = min(4096, boundary - offset)
            // The microphone is louder than the system track (the user speaking),
            // which also lets the probe tell the tracks apart. `quietMicrophone`
            // models loudspeaker echo, which the level gate keeps from recognition.
            let amplitude = track == .microphone ? (quietMicrophone ? 0.06 : 0.18) : 0.12
            let samples = (offset..<(offset + count)).map { Float(amplitude * sin(Double($0) / 48_000 * 2 * .pi * 440)) }
            try await writer.append(track: track, samples: samples, activeStartFrame: UInt64(offset),
                hostTimeStart: origin + AVAudioTime.hostTime(forSeconds: resumed && offset >= frames / 2 ?
                    172_800 + Double(offset - frames / 2) / 48_000 : Double(offset) / 48_000))
            offset += count
        }
    }
    let saved = try await writer.finish().recording
    try await store.saveRecording(saved)
    let catalog = try ModelCatalog.bundled()
    let models = try FinalTranscriptionPipeline.requiredRoles.map { try catalog.model(for: $0).snapshot(for: $0) }
    let previousJob = try await store.enqueue(kind: .finalTranscription, meetingID: owner.id, recordingID: saved.id,
        settings: ProcessingSettings(meetingLanguage: language), models: models)
    let segment = TranscriptSegment(recordingID: saved.id, dayID: saved.days[0].id, track: .microphone,
        interval: try MediaInterval(start: .zero, end: MediaTime(seconds: min(1, seconds))), wallClockStart: start,
        speaker: .microphone, originalText: "Previously available transcript")
    let previous = TranscriptRevision(recordingID: saved.id, sourceGeneration: saved.generation, kind: .final,
        segments: [segment], modelRevisions: models)
    try await store.publishTranscript(previous, jobID: previousJob.id)
    let job = try await store.enqueue(kind: .finalTranscription, meetingID: owner.id, recordingID: saved.id,
        settings: ProcessingSettings(meetingLanguage: language, spellingCorrection: spelling), models: models)
    return FinalFixture(library: library, store: store, recording: saved, job: job, previous: previous)
}

@Suite struct FinalTranscriptionTests {
    /// Task 5.8: system audio is primary; a microphone quieter than the system
    /// track is not recognized at all, and stored audio is untouched.
    @Test func quieterMicrophoneIsNotRecognized() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, quietMicrophone: true)
        let probe = FinalProbe()
        let result = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
            .run(jobID: fixture.job.id)
        #expect(result.readyForPublication && result.completedTracks.count == 2)
        #expect(result.blocks.allSatisfy { $0.track == .system } && result.blocks.count == 1)
        #expect(await probe.textCalls == 1)
        #expect(result.systemLevels?.isEmpty == false)
        let chunks = try FileManager.default.contentsOfDirectory(atPath: fixture.library.directory
            .appendingPathComponent("Meetings/\(fixture.recording.meetingID.uuidString)/Recordings/\(fixture.recording.id.uuidString)/microphone").path)
        #expect(!chunks.isEmpty)
        try await fixture.store.close()
    }

    @Test func completeEnglishAACSourceStagesBothTracksWithoutPublishing() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let probe = FinalProbe()
        let pipeline = FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
        let result = try await pipeline.run(jobID: fixture.job.id)
        #expect(result.readyForPublication)
        #expect(result.completedTracks.count == 2)
        #expect(result.windows.count == 2)
        #expect(result.blocks.count == 2)
        #expect(result.blocks.allSatisfy { $0.originalText.contains("tomorow") && $0.correctedText?.contains("tomorrow") == true })
        let mic = try #require(result.blocks.first { $0.track == .microphone })
        #expect(mic.speakerLabel == "You" && mic.speakerCandidates.isEmpty)
        #expect(result.blocks.first { $0.track == .system }?.speakerCandidates.count == 1)
        #expect(mic.words[0].wallClockStart == fixture.recording.startedAt)
        #expect(mic.day.timeZoneIdentifier == "Europe/London")
        #expect(await probe.speakerCalls == 1)
        #expect(await probe.maximumFrames <= 160_000)
        #expect(try await fixture.store.job(fixture.job.id).stage == .validating)
        #expect(try await fixture.store.transcript(meetingID: fixture.recording.meetingID, recordingID: fixture.recording.id) == fixture.previous)
        #expect(try await pipeline.run(jobID: fixture.job.id) == result)
        #expect(await probe.textCalls == 2)
        try await fixture.store.close()
    }

    @Test func russianFactsAndMissingTrackGapRemainDistinct() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, language: .russian, microphoneOnly: true)
        let probe = FinalProbe(); await probe.configure(text: "Алексей не заплатит 42 рубля завтро")
        let result = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id)
        #expect(result.windows.filter { $0.gapReason != nil }.count == 1)
        #expect(result.blocks.count == 1)
        #expect(result.blocks[0].correctedText == "Алексей не заплатит 42 рубля завтра")
        #expect(result.blocks[0].speakerLabel == "You")
        #expect(await probe.speakerCalls == 0)
        try await fixture.store.close()
    }

    @Test func alignmentFailureRestoresRawStageWithoutRerunningASRAfterRelaunch() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let probe = FinalProbe(); await probe.configure(fail: true)
        let pipeline = FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
        await #expect(throws: FinalTranscriptionError.invalidAlignment) { try await pipeline.run(jobID: fixture.job.id) }
        #expect(await probe.textCalls == 1)
        #expect(try await fixture.store.finalCheckpoint(jobID: fixture.job.id)?.windows[0].asr != nil)
        #expect(try await fixture.store.job(fixture.job.id).stage == .failed)
        try await fixture.store.close()
        let reopened = try await SessionStore.open(fixture.library)
        #expect(try await reopened.transcript(meetingID: fixture.recording.meetingID, recordingID: fixture.recording.id) == fixture.previous)
        _ = try await reopened.retryJob(fixture.job.id)
        await probe.configure()
        let result = try await FinalTranscriptionPipeline(store: reopened, library: fixture.library, inference: probe).run(jobID: fixture.job.id)
        #expect(result.readyForPublication)
        #expect(await probe.textCalls == 2)
        try await reopened.close()
    }

    @Test func malformedAlignmentRetainsPreviousRevisionAndUnsafeCorrectionKeepsOriginalText() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let probe = FinalProbe(); await probe.configure(malformed: true)
        let pipeline = FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
        await #expect(throws: FinalTranscriptionError.invalidAlignment) { try await pipeline.run(jobID: fixture.job.id) }
        #expect(try await fixture.store.finalCheckpoint(jobID: fixture.job.id)?.readyForPublication == false)
        #expect(try await fixture.store.transcript(meetingID: fixture.recording.meetingID, recordingID: fixture.recording.id) == fixture.previous)
        _ = try await fixture.store.retryJob(fixture.job.id)
        // A correction that changes a number is refused row by row: the
        // original recognized text is kept and transcription still completes.
        await probe.configure(unsafeResult: true)
        let result = try await pipeline.run(jobID: fixture.job.id)
        #expect(result.readyForPublication)
        let blocks = result.windows.flatMap { $0.blocks ?? [] }
        #expect(!blocks.isEmpty && blocks.allSatisfy { $0.correctedText == $0.originalText })
        #expect(blocks.allSatisfy { !($0.correctedText ?? "").contains("43") })
        try await fixture.store.close()
    }

    @Test func cancellationKeepsCheckpointAndReentrantRunCannotEnter() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let probe = FinalProbe(); await probe.configure(hold: true)
        let pipeline = FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
        let work = Task { try await pipeline.run(jobID: fixture.job.id) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !probe.held, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await probe.held)
        await #expect(throws: FinalTranscriptionError.busy) { try await pipeline.run(jobID: fixture.job.id) }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try await fixture.store.job(fixture.job.id).stage == .interrupted)
        #expect(try await fixture.store.finalCheckpoint(jobID: fixture.job.id)?.windows.first?.asr != nil)
        #expect(try await fixture.store.transcript(meetingID: fixture.recording.meetingID, recordingID: fixture.recording.id) == fixture.previous)
        _ = try await fixture.store.retryJob(fixture.job.id)
        await probe.configure()
        #expect(try await pipeline.run(jobID: fixture.job.id).readyForPublication)
        try await fixture.store.close()
    }

    @Test func missingModelWaitsAndResumeRetainsImmutableSettings() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let probe = FinalProbe(); await probe.configure(missing: [.spelling])
        let pipeline = FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
        await #expect(throws: FinalTranscriptionError.missingModels([.spelling])) { try await pipeline.run(jobID: fixture.job.id) }
        #expect(try await fixture.store.job(fixture.job.id).stage == .waitingForModels)
        #expect(await probe.textCalls == 0)
        try await fixture.store.setMeetingLanguage(fixture.recording.meetingID, language: .russian)
        // Notes and defaults do not change this recording's immutable source.
        // A retry uses its original English snapshot, not the later default.
        try await fixture.store.commitNotes(NotesRevision(meetingID: fixture.recording.meetingID, text: "Keep these new notes"))
        _ = try await fixture.store.retryJob(fixture.job.id)
        #expect(try await fixture.store.job(fixture.job.id).snapshot.settings.meetingLanguage == .english)
        await probe.configure()
        #expect(try await pipeline.run(jobID: fixture.job.id).readyForPublication)
        #expect(try await fixture.store.notes(meetingID: fixture.recording.meetingID)?.text == "Keep these new notes")
        try await fixture.store.close()
    }

    @Test func completeLongSourceUsesBoundedWindowsAndBudgetSubdivision() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, seconds: 20)
        let probe = FinalProbe(); await probe.configure(partition: true)
        let result = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id)
        #expect(result.windows.count == 6)
        for track in AudioTrack.allCases {
            let windows = result.windows.filter { $0.track == track }
            #expect(windows.first?.owned.start == .zero)
            #expect(windows.last?.owned.end == fixture.recording.activeDuration)
            #expect(zip(windows, windows.dropFirst()).allSatisfy { $0.owned.end == $1.owned.start })
        }
        #expect(await probe.maximumFrames == 160_000)
        #expect(await probe.correctionCalls > 6)
        #expect(result.blocks.allSatisfy { $0.correctedText != nil })
        try await fixture.store.close()
    }

    @Test func deletedMeetingCannotBeRevivedByHeldProcessing() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let probe = FinalProbe(); await probe.configure(hold: true)
        let work = Task { try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !probe.held, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try await fixture.store.deleteMeeting(fixture.recording.meetingID)
        await probe.configure()
        await #expect(throws: StoreError.self) { try await work.value }
        #expect(try await fixture.store.meetings().isEmpty)
        try await fixture.store.close()
    }

    @Test func readyCheckpointRevalidatesAudioIntegrityAndCannotPublishChangedSource() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let probe = FinalProbe()
        let pipeline = FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
        #expect(try await pipeline.run(jobID: fixture.job.id).readyForPublication)
        let chunk = try #require(fixture.recording.chunks.first)
        let url = fixture.library.directory.appendingPathComponent(chunk.file.value)
        var bytes = try Data(contentsOf: url); bytes[100] ^= 1
        try bytes.write(to: url)
        await #expect(throws: AudioWindowReadError.self) { try await pipeline.run(jobID: fixture.job.id) }
        #expect(try await fixture.store.finalCheckpoint(jobID: fixture.job.id)?.readyForPublication == false)
        #expect(try await fixture.store.transcript(meetingID: fixture.recording.meetingID, recordingID: fixture.recording.id) == fixture.previous)
        #expect(await probe.textCalls == 2)
        var changed = fixture.recording; changed.generation += 1
        try await fixture.store.saveRecording(changed)
        await #expect(throws: StoreError.staleSource) { try await fixture.store.retryJob(fixture.job.id) }
        try await fixture.store.close()
    }

    @Test func checkpointAndStageWriteRollBackTogetherOnInjectedDatabaseFailure() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let path = "/" + DirectoryHandle.physicalComponents(fixture.library.directory).dropFirst().joined(separator: "/")
        let db = try SQLiteConnection(path: path + "/Library.sqlite3")
        try db.execute("CREATE TRIGGER fail_final BEFORE UPDATE ON records WHEN NEW.kind = 'finalCheckpoint' BEGIN SELECT RAISE(ABORT, 'injected checkpoint failure'); END")
        let probe = FinalProbe()
        await #expect(throws: StoreError.self) {
            try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id)
        }
        #expect(try await fixture.store.job(fixture.job.id).stage == .failed)
        #expect(try await fixture.store.finalCheckpoint(jobID: fixture.job.id)?.windows.isEmpty == true)
        #expect(await probe.textCalls == 0)
        try db.execute("DROP TRIGGER fail_final")
        _ = try await fixture.store.retryJob(fixture.job.id)
        #expect(try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id).readyForPublication)
        try await fixture.store.close()
    }

    @Test func alignerNormalizationCannotEraseDecimalOrNegativeSigns() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, microphoneOnly: true)
        let probe = FinalProbe(); await probe.configure(text: "Alex will not pay -42.5% tomorow")
        let result = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id)
        #expect(result.blocks[0].originalText.contains("-42.5%"))
        #expect(result.blocks[0].correctedText?.contains("-42.5%") == true)
        #expect(result.windows.first { $0.track == .microphone }?.asr?.text == "Alex will not pay -42.5% tomorow")
        try await fixture.store.close()
    }

    @Test func zeroLengthAndOverrunningAlignmentKeepsEveryWordInsideTheSource() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, seconds: 2.5, microphoneOnly: true)
        let probe = FinalProbe(); await probe.overrun()
        let result = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id)
        let words = result.windows.flatMap { $0.words ?? [] }
        #expect(words.map(\.text).joined(separator: " ").hasPrefix("Alex will not pay 42 rubles tomorow"))
        let end = fixture.recording.activeDuration
        #expect(words.allSatisfy { $0.active.end <= end && $0.active.duration > .zero })
        #expect(result.blocks.map(\.originalText).joined(separator: " ").contains("tomorow"))
        try await fixture.store.close()
    }

    @Test func undetectedLanguageUsesTheTrackLanguageOrAsksForTheMeetingLanguage() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, seconds: 15, language: .auto, microphoneOnly: true)
        let probe = FinalProbe(); await probe.undetected(from: 2)
        let result = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id)
        let asr = result.windows.compactMap(\.asr).filter { !$0.text.isEmpty }
        #expect(asr.count >= 2 && asr.allSatisfy { $0.language == .english && !$0.text.contains("Olha") })
        #expect(await probe.textCalls == asr.count * 2 - 1)
        try await fixture.store.close()

        let other = try TemporaryFolder(); defer { other.remove() }
        let first = try await finalFixture(other, seconds: 3, language: .auto, microphoneOnly: true)
        let unknown = FinalProbe(); await unknown.undetected(from: 1)
        await #expect(throws: FinalTranscriptionError.undetectedLanguage) {
            try await FinalTranscriptionPipeline(store: first.store, library: first.library, inference: unknown).run(jobID: first.job.id)
        }
        #expect(try await first.store.job(first.job.id).stage == .failed)
        try await first.store.close()
    }

    /// The user's "Антон Demo" opened with a short "Да, да." read as Portuguese:
    /// with nothing earlier, the following speech decides the language.
    @Test func undetectedOpeningTakesTheLanguageOfTheFollowingSpeech() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, seconds: 15, language: .auto, microphoneOnly: true)
        let probe = FinalProbe(); await probe.undetected(until: 2)
        let result = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id)
        let asr = result.windows.compactMap(\.asr).filter { !$0.text.isEmpty }
        #expect(asr.count >= 2 && asr.allSatisfy { $0.language == .english && !$0.text.contains("Olha") })
        // Opening (auto), look-ahead on the next window (six words), opening again in English, then the rest.
        #expect(await probe.textCalls == asr.count + 2)
        try await fixture.store.close()
    }

    @Test func pauseAndDayResumptionKeepSourceWallTimeAndFrozenZone() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, seconds: 4, microphoneOnly: true, resumed: true)
        let probe = FinalProbe()
        let result = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id)
        let blocks = result.blocks.filter { $0.track == .microphone }
        #expect(blocks.count == 2)
        #expect(blocks[0].interval.start == .zero)
        let resumedTime = try MediaTime(seconds: 2)
        #expect(blocks[1].interval.start == resumedTime)
        #expect(blocks[0].words[0].wallClockStart == fixture.recording.startedAt)
        #expect(blocks[1].words[0].wallClockStart == fixture.recording.startedAt.addingTimeInterval(172_800))
        #expect(blocks[0].day.timeZoneIdentifier == "Europe/London")
        #expect(blocks[1].day.timeZoneIdentifier == "Asia/Tokyo")
        #expect(blocks[0].day.id != blocks[1].day.id)
        #expect(blocks.allSatisfy { $0.speakerLabel == "You" })
        try await fixture.store.close()
    }

    @Test func changedCheckpointVersionIsRejectedWithoutErasingVisibleText() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let probe = FinalProbe()
        let result = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id)
        let altered = FinalTranscriptionCheckpoint(version: 2, correctionPromptVersion: result.correctionPromptVersion,
            job: result.job, recordingFingerprint: result.recordingFingerprint,
            windows: result.windows, completedTracks: result.completedTracks, speakerCheckpoint: result.speakerCheckpoint,
            correctionBatches: result.correctionBatches, readyForPublication: true)
        try await fixture.store.saveFinalCheckpoint(altered, stage: .validating)
        await #expect(throws: FinalTranscriptionError.invalidCheckpoint) {
            try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id)
        }
        #expect(try await fixture.store.transcript(meetingID: fixture.recording.meetingID, recordingID: fixture.recording.id) == fixture.previous)
        #expect(await probe.textCalls == 2)
        try await fixture.store.close()
    }

    @Test func earlierCorrectionPromptRedoesOnlyCorrection() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let probe = FinalProbe()
        let result = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id)
        let calls = (await probe.textCalls, await probe.alignmentCalls, await probe.correctionCalls)
        var windows = result.windows
        for i in windows.indices { for j in (windows[i].blocks ?? []).indices { windows[i].blocks![j].correctedText = "stale" } }
        let earlier = FinalTranscriptionCheckpoint(version: 1, correctionPromptVersion: "indexed-spelling-1",
            job: result.job, recordingFingerprint: result.recordingFingerprint,
            windows: windows, completedTracks: result.completedTracks, speakerCheckpoint: result.speakerCheckpoint,
            correctionBatches: result.correctionBatches, readyForPublication: true)
        try await fixture.store.saveFinalCheckpoint(earlier, stage: .validating)
        let resumed = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe).run(jobID: fixture.job.id)
        #expect(resumed.correctionPromptVersion == IndexedSpellingCorrection.promptVersion && resumed.readyForPublication)
        #expect(resumed.blocks.map(\.correctedText) == result.blocks.map(\.correctedText))
        let alignments = await probe.alignmentCalls
        #expect(await probe.textCalls == calls.0 && alignments == calls.1)
        #expect(await probe.correctionCalls == calls.2 * 2)
        try await fixture.store.close()
    }

    @Test func withoutSpellingCorrectionTheTextModelIsNeitherRequiredNorCalled() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, spelling: false)
        let probe = FinalProbe()
        await probe.configure(missing: [.spelling])
        let publication = try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
            .runAndPublish(jobID: fixture.job.id)
        #expect(await probe.correctionCalls == 0)
        let revision = try #require(try await fixture.store.transcriptRevision(publication.id))
        #expect(!revision.segments.isEmpty && revision.segments.allSatisfy { $0.correctedText == nil })
        #expect(revision.segments.contains { $0.originalText.contains("tomorow") })
        // With correction on, the same missing model still blocks the job.
        #expect(FinalTranscriptionPipeline.blocking([.spelling], settings: ProcessingSettings()) == [.spelling])
        try await fixture.store.close()
    }

    @Test func snapshotsSavedBeforeTheSettingKeepSpellingCorrection() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ProcessingSettings(spellingCorrection: false))) as! [String: Any]
        json.removeValue(forKey: "spellingCorrection")
        let decoded = try JSONDecoder().decode(ProcessingSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.spellingCorrection && decoded == ProcessingSettings())
    }

    @Test func twoPipelineOwnersCannotAdvanceTheSameDurableJob() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let probe = FinalProbe(); await probe.configure(hold: true)
        let first = FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
        let second = FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
        let work = Task { try await first.run(jobID: fixture.job.id) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !probe.held, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await #expect(throws: FinalTranscriptionError.busy) { try await second.run(jobID: fixture.job.id) }
        #expect(try await fixture.store.job(fixture.job.id).stage == .aligning)
        await probe.configure()
        #expect(try await work.value.readyForPublication)
        #expect(try await second.run(jobID: fixture.job.id).readyForPublication)
        #expect(await probe.textCalls == 2)
        try await fixture.store.close()
    }

    @Test(arguments: [
        ("Alex will not pay 42", "Alice will not pay 42"),
        ("Alex will not pay 42", "Alex will now pay 42"),
        ("Алексей не заплатит 42", "Алексей заплатит 42"),
        ("The amount is -42.5%", "The amount is 42.5%"),
        ("I need forty rubles", "I need fifty rubles"),
        ("ровно двадцать рублей", "ровно тридцать рублей"),
        ("Keep repeated repeated words", "Keep repeated words"),
        ("The change is possible", "The change is impossible"),
        ("Это возможно", "Это невозможно"),
        ("The US budget is 42", "The us budget is 42")
    ]) func correctionRejectsChangedFactsAndDeletedWords(pair: (String, String)) throws {
        let row = IndexedCorrection(id: UUID(), text: pair.0)
        let output = try IndexedSpellingCorrection.response([IndexedCorrection(id: row.id, text: pair.1)], originals: [row])
        #expect(throws: FinalTranscriptionError.invalidCorrection) { try IndexedSpellingCorrection.validate(output, originals: [row]) }
    }

    @Test func indexedResultRefusesDuplicateReorderedOutOfRangeAndInventedMetadata() throws {
        let rows = [IndexedCorrection(id: UUID(), text: "Alex will not pay 42"), IndexedCorrection(id: UUID(), text: "We meet tomorow")]
        #expect(try IndexedSpellingCorrection.prompt(rows) == #"[{"i":1,"text":"Alex will not pay 42"},{"i":2,"text":"We meet tomorow"}]"#)
        let fixed = #"[{"i":2,"text":"We meet tomorrow"}]"#
        // Omitted rows are unchanged; an empty array changes nothing.
        #expect(try IndexedSpellingCorrection.validate(fixed, originals: rows).map(\.text) == ["Alex will not pay 42", "We meet tomorrow"])
        #expect(try IndexedSpellingCorrection.validate("[]", originals: rows) == rows)
        let invalid = [#"[{"i":2,"text":"We meet tomorrow"},{"i":2,"text":"We meet tomorrow"}]"#,
                       #"[{"i":2,"text":"We meet tomorrow"},{"i":1,"text":"Alex will not pay 42"}]"#,
                       #"[{"i":3,"text":"We meet tomorrow"}]"#, #"[{"i":0,"text":"Alex will not pay 42"}]"#,
                       #"[{"i":1.5,"text":"We meet tomorrow"}]"#, #"[{"i":true,"text":"We meet tomorrow"}]"#,
                       #"[{"i":"2","text":"We meet tomorrow"}]"#, #"[{"i":2,"text":"We meet tomorrow","speaker":"Alice"}]"#,
                       #"{"i":2,"text":"We meet tomorrow"}"#]
        for output in invalid {
            #expect(throws: FinalTranscriptionError.invalidCorrection) { try IndexedSpellingCorrection.validate(output, originals: rows) }
            // The pipeline policy keeps the original text instead of failing.
            let kept = IndexedSpellingCorrection.accept(output, originals: rows)
            #expect(kept.corrections == rows && kept.rejected == 2)
        }
        #expect(IndexedSpellingCorrection.accept("not json", originals: rows).corrections == rows)
        let mixed = #"[{"i":1,"text":"Alex will pay 42"},{"i":2,"text":"We meet tomorrow"}]"#
        let accepted = IndexedSpellingCorrection.accept(mixed, originals: rows)
        #expect(accepted.corrections.map(\.text) == ["Alex will not pay 42", "We meet tomorrow"] && accepted.rejected == 1)
        #expect(try IndexedSpellingCorrection.response(accepted.corrections, originals: rows) == fixed)
    }
}
