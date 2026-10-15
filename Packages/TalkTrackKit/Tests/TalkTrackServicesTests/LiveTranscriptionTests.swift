import AVFoundation
import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

private enum LiveFixtureError: Error { case injected }
private actor LiveFixtureInference: LiveTranscriptionInference {
    var texts: [String]
    var held = false, failFirst = false, mixed = false
    var asrCalls = 0, segmentationCalls = 0, embeddingCalls = 0
    var languages: [MeetingLanguage] = [], frames: [Int] = []
    var startedDrains = 0, finishedDrains = 0
    init(_ texts: [String], held: Bool = false, failFirst: Bool = false, mixed: Bool = false) {
        self.texts = texts; self.held = held; self.failFirst = failFirst; self.mixed = mixed
    }
    func release() { held = false }
    func failNext() { failFirst = true }
    func drainStarted() { startedDrains += 1 }
    func drainFinished() { finishedDrains += 1 }
    func liveText(_ model: ModelSnapshot, samples: [Float], language: MeetingLanguage) async throws -> LiveASRResult {
        asrCalls += 1; languages.append(language); frames.append(samples.count)
        while held { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        if failFirst { failFirst = false; throw LiveFixtureError.injected }
        let text = texts.isEmpty ? "Recognized test speech" : texts.removeFirst()
        return LiveASRResult(text: text, language: language.title)
    }
    func speakerActivity(_ model: ModelSnapshot, samples: [Float]) async throws -> [SpeakerWindowActivity] {
        segmentationCalls += 1
        let range = try clusterRange(0, Double(samples.count) / 16_000)
        return (1...(mixed ? 2 : 1)).map { SpeakerWindowActivity(slot: $0, relative: range) }
    }
    func speakerEmbedding(_ model: ModelSnapshot, samples: [Float]) async throws -> SpeakerWindowEmbedding {
        embeddingCalls += 1
        return SpeakerWindowEmbedding(values: clusterVector(0), model: model)
    }
}
private func liveSession(_ inference: LiveFixtureInference, meetingID: UUID = UUID(), recordingID: UUID = UUID(),
                         language: MeetingLanguage = .english) throws -> LiveTranscriptionSession {
    let catalog = try ModelCatalog.bundled(), (seg, emb) = try clusteringModels()
    return try LiveTranscriptionSession(meetingID: meetingID, recordingID: recordingID,
        options: LiveTranscriptionOptions(language: language), asr: catalog.model(for: .liveASR).snapshot(for: .liveASR),
        segmentation: seg, embedding: emb, inference: inference)
}
private func feedLive(_ session: LiveTranscriptionSession, track: AudioTrack = .system, start: Int = 0, frames: Int = 144_000,
                      day: RecordingDay, date: Date, boundary: UUID, level: Float = 0.05) async throws {
    var offset = 0
    while offset < frames {
        let count = min(4800, frames - offset)
        try await session.append(track: track, samples: Array(repeating: level, count: count), activeStartFrame: UInt64(start + offset),
            day: day, wallClockStart: date.addingTimeInterval(Double(offset) / 48_000), boundaryID: boundary)
        offset += count
    }
}
private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()) {
        guard ContinuousClock.now < end else { throw LiveFixtureError.injected }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite struct LiveTranscriptionTests {
    @Test func growingRetryRecoversFirstSpeechAndItsOriginalTimestamp() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let model = LiveFixtureInference(["Recovered complete phrase"], failFirst: true), session = try liveSession(model)
        try await feedLive(session, track: .microphone, day: day, date: date, boundary: boundary)
        try await eventually { if case .failed = await session.state { return true }; return false }
        try await feedLive(session, track: .microphone, start: 144_000, day: day, date: date.addingTimeInterval(3), boundary: boundary)
        await session.finish()
        let row = try #require(await session.utterances.first)
        #expect(row.interval == (try clusterRange(0, 6)))
        #expect(row.wallClockStart == date)
        #expect(await session.lastFailureMessage != nil)
    }
    @Test func silenceAfterPublishedSpeechSettlesFragmentAndPreservesRepeatedPhrase() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let model = LiveFixtureInference(["Repeat the phrase", "Repeat the phrase"]), session = try liveSession(model)
        try await feedLive(session, track: .microphone, day: day, date: date, boundary: boundary)
        try await eventually { await session.publishedCount == 1 }
        try await feedLive(session, track: .microphone, start: 144_000, frames: 14_400, day: day,
            date: date.addingTimeInterval(3), boundary: boundary, level: 0)
        #expect(await session.retainedSourceFrames == 0)
        try await feedLive(session, track: .microphone, start: 158_400, frames: 48_000, day: day,
            date: date.addingTimeInterval(3.3), boundary: boundary)
        await session.finish()
        let rows = await session.utterances
        #expect(rows.map(\.text) == ["Repeat the phrase", "Repeat the phrase"])
        #expect(rows[0].id != rows[1].id && rows[1].context.start.seconds == 3.3)
    }
    @Test func irregularPacketLengthsKeepExactCadenceAndBoundedContext() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let model = LiveFixtureInference(["One two", "One two three four"]), session = try liveSession(model)
        var offset = 0
        while offset < 288_000 {
            let count = min(1537, 288_000 - offset)
            try await session.append(track: .microphone, samples: Array(repeating: 0.05, count: count), activeStartFrame: UInt64(offset),
                day: day, wallClockStart: date.addingTimeInterval(Double(offset) / 48_000), boundaryID: boundary)
            offset += count
            if offset >= 144_000, await model.asrCalls == 0 { try await eventually { await model.asrCalls >= 1 } }
        }
        await session.finish()
        #expect(await model.frames == [48_000, 96_000])
        #expect(await session.utterances.last?.interval.end.seconds == 6)
    }
    @Test func rollingAfterSixSecondsDeduplicatesSharedWordsAndKeepsNewSpeech() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let model = LiveFixtureInference(["One two three", "One two three four five six seven eight nine ten.", "Nine ten, eleven twelve."])
        let session = try liveSession(model)
        for index in 0..<3 {
            try await feedLive(session, track: .microphone, start: index * 144_000, day: day,
                date: date.addingTimeInterval(Double(index * 3)), boundary: boundary)
            try await eventually { await session.publishedCount == index + 1 }
        }
        await session.finish()
        let rows = await session.utterances
        #expect(rows.count == 2)
        #expect(rows[0].text == "One two three four five six seven eight nine ten.")
        #expect(rows[1].text == "eleven twelve.")
        #expect(rows[1].interval == (try clusterRange(6, 9)))
        #expect(rows[1].context == (try clusterRange(4.5, 9)))
        #expect(await model.frames == [48_000, 96_000, 72_000])
    }
    @Test func failedWindowPreservesEarlierTextAndRetriesWithoutReusingFailedOverlap() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let model = LiveFixtureInference(["Earlier usable words", "Earlier usable words again"]), session = try liveSession(model)
        try await feedLive(session, track: .microphone, day: day, date: date, boundary: boundary)
        try await eventually { await session.publishedCount == 1 }
        await model.failNext()
        try await feedLive(session, track: .microphone, start: 144_000, day: day, date: date.addingTimeInterval(3), boundary: boundary)
        try await eventually { if case .failed = await session.state { return true }; return false }
        #expect(await session.utterances.map(\.text) == ["Earlier usable words"])
        try await feedLive(session, track: .microphone, start: 288_000, day: day, date: date.addingTimeInterval(6), boundary: boundary)
        try await eventually { await session.publishedCount == 2 }
        #expect(await session.utterances[1].text == "Earlier usable words again")
        #expect(await session.state == .delayed(skippedWindows: 1))
        await session.finish()
    }
    @Test func sourceOrderSurvivesEndpointAndResumeWhileAutoIsAnImmutableSnapshot() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let model = LiveFixtureInference(["Automatic language"]), session = try liveSession(model, language: .auto)
        try await feedLive(session, track: .microphone, frames: 48_000, day: day, date: date, boundary: boundary)
        try await feedLive(session, track: .microphone, start: 48_000, frames: 14_400, day: day, date: date.addingTimeInterval(1), boundary: boundary, level: 0)
        try await eventually { await session.publishedCount == 1 }
        await #expect(throws: LiveTranscriptionError.invalidPacket) {
            try await feedLive(session, track: .microphone, start: 0, frames: 4800, day: day, date: date, boundary: boundary)
        }
        await session.pause(); await session.resume()
        await #expect(throws: LiveTranscriptionError.invalidPacket) {
            try await feedLive(session, track: .microphone, start: 0, frames: 4800, day: day, date: date, boundary: UUID())
        }
        #expect(await model.languages == [.auto])
        #expect(await session.options.language == .auto)
        await session.finish()
    }
    @Test func incrementalEnglishRefinesProvisionalTextBeforeStopAndPreservesWindowTiming() async throws {
        let date = Date(timeIntervalSince1970: 1_000), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let model = LiveFixtureInference(["Today we discussed the project. The next meeting", "Today we discussed the project. The next meeting will be on Friday."])
        let session = try liveSession(model)
        let presentation = await LiveTranscriptPresentation()
        let observation = Task { await presentation.observe(session) }
        try await feedLive(session, day: day, date: date, boundary: boundary)
        try await eventually { await presentation.rows.count == 1 }
        #expect(await presentation.rows[0].text == "Today we discussed the project. The next meeting")
        #expect(await presentation.rows[0].speakerLabel == "Voice1")
        try await feedLive(session, start: 144_000, day: day, date: date.addingTimeInterval(3), boundary: boundary)
        try await eventually { await presentation.rows.first?.interval.end.seconds == 6 }
        let rows = await presentation.rows
        #expect(rows.count == 1)
        #expect(rows[0].text == "Today we discussed the project. The next meeting will be on Friday.")
        #expect(rows[0].interval == (try clusterRange(0, 6)))
        #expect(rows[0].context == (try clusterRange(0, 6)))
        #expect(rows[0].wallClockStart == date)
        #expect(rows.allSatisfy { $0.kind == .live && $0.speakers == rows[0].speakers })
        #expect(await model.frames == [48_000, 96_000])
        await session.finish(); await observation.value
        #expect(await presentation.state == .stopped)
    }
    @Test func russianMicrophoneAlwaysYouAndNeverInvokesSpeakerModels() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let model = LiveFixtureInference(["Сегодня мы обсудили проект", "Сегодня мы обсудили проект. Следующая встреча в пятницу."])
        let session = try liveSession(model, language: .russian)
        try await feedLive(session, track: .microphone, day: day, date: date, boundary: boundary)
        try await eventually { await session.publishedCount == 1 }
        try await feedLive(session, track: .microphone, start: 144_000, day: day, date: date.addingTimeInterval(3), boundary: boundary)
        await session.finish()
        let rows = await session.utterances
        #expect(rows.count == 1)
        #expect(rows[0].text == "Сегодня мы обсудили проект. Следующая встреча в пятницу.")
        #expect(rows.allSatisfy { $0.speakerLabel == "You" && $0.speakers.isEmpty })
        #expect(await model.languages == [.russian, .russian])
        #expect(await model.segmentationCalls == 0)
        #expect(await model.embeddingCalls == 0)
    }
    @Test func punctuationUnicodeAndIntentionalRepetition() {
        #expect(LiveOverlapDeduplicator.removingSharedPrefix(previous: "Привет, новый ПРОЕКТ!", current: "Новый проект, версия 2.") == "версия 2.")
        #expect(LiveOverlapDeduplicator.removingSharedPrefix(previous: "one two three", current: "two three") == "")
        #expect(LiveOverlapDeduplicator.removingSharedPrefix(previous: "say yes", current: "yes again") == "yes again")
        #expect(LiveOverlapDeduplicator.removingSharedPrefix(previous: "old source", current: "different words") == "different words")
        #expect(LiveOverlapDeduplicator.removingSharedPrefix(previous: "number 42", current: "number 43") == "number 43")
    }
    @Test func mixedSystemSpeechKeepsDistinctProvisionalCandidatesWithoutTraining() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC")
        let model = LiveFixtureInference(["Two people are speaking"], mixed: true), session = try liveSession(model)
        try await feedLive(session, day: day, date: date, boundary: UUID())
        await session.finish()
        let row = try #require(await session.utterances.first)
        #expect(row.speakerLabel == "Voice1 / Voice2")
        #expect(Set(row.speakers.map(\.id)).count == 2)
        #expect(await model.embeddingCalls == 0)
    }
    @Test func pauseAndFrozenDayResetOverlapAndIdentityWhileActiveTimeExcludesPause() async throws {
        let date = ISO8601DateFormatter().date(from: "2026-10-08T23:59:57Z")!
        let day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), next = date.addingTimeInterval(3600)
        let nextDay = try RecordingDay(capturedAt: next, timeZoneIdentifier: "UTC")
        let model = LiveFixtureInference(["same words", "same words"]), session = try liveSession(model)
        try await feedLive(session, day: day, date: date, boundary: UUID())
        try await eventually { await session.publishedCount == 1 }
        await session.pause()
        #expect(await session.state == .paused)
        try await feedLive(session, start: 144_000, day: day, date: date, boundary: UUID())
        #expect(await model.asrCalls == 1)
        await session.resume()
        try await feedLive(session, start: 144_000, day: nextDay, date: next, boundary: UUID())
        await session.finish()
        let rows = await session.utterances
        #expect(rows.count == 2 && rows[1].text == "same words")
        #expect(rows[1].interval == (try clusterRange(3, 6)))
        #expect(rows[1].wallClockStart == next)
        #expect(rows[0].speakers[0].id != rows[1].speakers[0].id)
        #expect(rows[1].day == nextDay)
    }
    @Test func backlogAndErrorLeaveActualDualAACCompleteAndNewestWindowsRetry() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url), date = Date(), meetingID = UUID()
        let recording = try Recording(meetingID: meetingID, startedAt: date, timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
        let model = LiveFixtureInference([], held: true, failFirst: true)
        let session = try liveSession(model, meetingID: meetingID, recordingID: recording.id)
        let day = recording.days[0], boundary = UUID(), origin = AVAudioTime.hostTime(forSeconds: 100)
        var clock = CaptureIntervalClock()
        try clock.begin(hostTime: origin, wallClock: date, timeZoneIdentifier: "UTC")
        try await writer.updateCaptureTiming(clock.close(at: origin + AVAudioTime.hostTime(forSeconds: 12)), state: .recording)
        var maxPending = 0, maxPCM = 0
        for offset in stride(from: 0, to: 576_000, by: 4800) {
            for track in AudioTrack.allCases {
                let packet = Array(repeating: Float(0.05), count: 4800)
                try await writer.append(track: track, samples: packet, activeStartFrame: UInt64(offset),
                    hostTimeStart: origin + AVAudioTime.hostTime(forSeconds: Double(offset) / 48_000))
                try await session.append(track: track, samples: packet, activeStartFrame: UInt64(offset), day: day,
                    wallClockStart: date.addingTimeInterval(Double(offset) / 48_000), boundaryID: boundary)
            }
            maxPending = max(maxPending, await session.pendingWindowCount)
            maxPCM = max(maxPCM, await session.retainedSourceFrames)
            if offset == 139_200 { try await eventually { await model.asrCalls == 1 } }
        }
        #expect(maxPending <= 2 && maxPCM <= 576_000)
        guard case .delayed = await session.state else { Issue.record("Backlog must be visible"); return }
        let stored = try await writer.finish().recording
        #expect(stored.activeDuration.seconds == 12)
        for track in AudioTrack.allCases { #expect(stored.chunks.filter { $0.track == track }.reduce(0) { $0 + $1.decodedFrameCount } == 576_000) }
        await model.release(); await session.finish()
        #expect(await session.publishedCount == 2)
        let rows = await session.utterances
        #expect(Set(rows.map(\.track)) == Set(AudioTrack.allCases))
        #expect(rows.allSatisfy { $0.interval.end.seconds == 12 })
        #expect(await model.asrCalls == 3)
        #expect(await model.frames.allSatisfy { $0 <= 96_000 })
    }
    @Test func cancellationRejectsLateResultAndInvalidPacketsCannotDamageSession() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let model = LiveFixtureInference(["late result"], held: true), session = try liveSession(model)
        await #expect(throws: LiveTranscriptionError.invalidPacket) {
            try await session.append(track: .microphone, samples: [.nan], activeStartFrame: 0, day: day, wallClockStart: date, boundaryID: boundary)
        }
        try await feedLive(session, track: .microphone, day: day, date: date, boundary: boundary)
        try await eventually { await model.asrCalls == 1 }
        await session.cancel()
        #expect(await session.publishedCount == 0)
        #expect(await session.utterances.isEmpty)
        #expect(await session.retainedSourceFrames == 0)
        #expect(await session.pendingWindowCount == 0)
        await #expect(throws: LiveTranscriptionError.stopped) { try await feedLive(session, day: day, date: date, boundary: boundary) }
        let held = LiveFixtureInference(["Drained once"], held: true), draining = try liveSession(held)
        try await feedLive(draining, track: .microphone, day: day, date: date, boundary: boundary)
        try await eventually { await held.asrCalls == 1 }
        let first = Task { await held.drainStarted(); await draining.finish(); await held.drainFinished() }
        let second = Task { await held.drainStarted(); await draining.finish(); await held.drainFinished() }
        try await eventually { await held.startedDrains == 2 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await held.finishedDrains == 0)
        await held.release(); await first.value; await second.value
        #expect(await held.finishedDrains == 2)
        #expect(await draining.publishedCount == 1)
    }
    @Test func silenceAndUnavailableDisabledModesAvoidAllInference() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC")
        for enabled in [true, false] {
            let session = try LiveTranscriptionSession(meetingID: UUID(), recordingID: UUID(), options: LiveTranscriptionOptions(enabled: enabled))
            #expect(await session.state == (enabled ? .unavailable : .disabled))
            try await feedLive(session, day: day, date: date, boundary: UUID())
            #expect(await session.retainedSourceFrames == 0)
            await session.finish()
        }
        let model = LiveFixtureInference([]), session = try liveSession(model)
        try await feedLive(session, day: day, date: date, boundary: UUID(), level: 0)
        await session.finish()
        #expect(await model.asrCalls == 0)
        #expect(await model.segmentationCalls == 0)
    }
    @Test func endpointPublishesBeforeCadenceAndStopFlushesShortSpeech() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let model = LiveFixtureInference(["Short speech", "Stop tail"]), session = try liveSession(model)
        try await feedLive(session, track: .microphone, frames: 48_000, day: day, date: date, boundary: boundary)
        try await feedLive(session, track: .microphone, start: 48_000, frames: 14_400, day: day, date: date.addingTimeInterval(1), boundary: boundary, level: 0)
        try await eventually { await session.publishedCount == 1 }
        #expect(await model.frames == [20_800])
        try await feedLive(session, track: .microphone, start: 62_400, frames: 4800, day: day, date: date.addingTimeInterval(1.3), boundary: boundary)
        await session.finish()
        #expect(await session.publishedCount == 2)
        #expect(await model.frames == [20_800, 1600])
    }
    @Test func preferencesInheritOverrideAndPersistMeetingLanguageAcrossReopen() async throws {
        let suite = "TalkTrack.LiveTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ProcessingPreferences.liveOptions(in: defaults) == LiveTranscriptionOptions())
        defaults.set(false, forKey: ProcessingPreferences.liveEnabledKey)
        defaults.set("russian", forKey: ProcessingPreferences.meetingLanguageKey)
        let frozen = ProcessingPreferences.liveOptions(meetingLanguage: .english, in: defaults)
        #expect(frozen == LiveTranscriptionOptions(enabled: false, language: .english))
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url), store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(ProcessingPreferences.meetingDraft(title: "Russian meeting", in: defaults))
        #expect(meeting.language == .russian)
        try await store.setMeetingLanguage(meeting.id, language: .english)
        try await store.close()
        defaults.set("auto", forKey: ProcessingPreferences.meetingLanguageKey)
        let reopened = try await SessionStore.open(library)
        #expect(try await reopened.meeting(meeting.id).language == .english)
        #expect(frozen.language == .english && !frozen.enabled)
        #expect(ProcessingPreferences.liveOptions(in: defaults).language == .auto)
        try await reopened.deleteMeeting(meeting.id)
        await #expect(throws: StoreError.missingMeeting) { try await reopened.setMeetingLanguage(meeting.id, language: .russian) }
        try await reopened.close()
    }
}
