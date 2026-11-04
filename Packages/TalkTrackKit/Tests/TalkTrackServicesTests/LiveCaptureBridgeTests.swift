import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

actor BridgeInference: LiveTranscriptionInference {
    var held: Bool
    var calls = 0
    init(held: Bool = false) { self.held = held }
    func release() { held = false }
    func liveText(_ model: ModelSnapshot, samples: [Float], language: MeetingLanguage) async throws -> LiveASRResult {
        calls += 1
        while held { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        return LiveASRResult(text: "Row \(calls)", language: "English")
    }
    func speakerActivity(_ model: ModelSnapshot, samples: [Float]) async throws -> [SpeakerWindowActivity] {
        [SpeakerWindowActivity(slot: 1, relative: try clusterRange(0, Double(samples.count) / 16_000))]
    }
    func speakerEmbedding(_ model: ModelSnapshot, samples: [Float]) async throws -> SpeakerWindowEmbedding {
        SpeakerWindowEmbedding(values: clusterVector(0), model: model)
    }
}

final class BridgeRecorded: @unchecked Sendable {
    private let lock = NSLock()
    private var _drafts: [LiveDraft] = [], _begins = 0, _ends = 0
    var drafts: [LiveDraft] { lock.withLock { _drafts } }
    var begins: Int { lock.withLock { _begins } }
    var ends: Int { lock.withLock { _ends } }
    func draft(_ value: LiveDraft) { lock.withLock { _drafts.append(value) } }
    func begin() { lock.withLock { _begins += 1 } }
    func end() { lock.withLock { _ends += 1 } }
}

func bridgeHost(_ inference: BridgeInference, _ recorded: BridgeRecorded, failing: Bool = false) -> LiveCaptureHost {
    LiveCaptureHost(begin: {
        if failing { throw LiveTranscriptionError.invalidModel }
        recorded.begin()
        return LiveCaptureLease(makeSession: { meetingID, recordingID, options in
            let catalog = try ModelCatalog.bundled(), (seg, emb) = try clusteringModels()
            return try LiveTranscriptionSession(meetingID: meetingID, recordingID: recordingID, options: options,
                asr: catalog.model(for: .liveASR).snapshot(for: .liveASR), segmentation: seg, embedding: emb, inference: inference)
        }, end: { recorded.end() })
    })
}

private func fragments(track: AudioTrack = .system, start: Int = 0, frames: Int, day: RecordingDay, date: Date,
                       boundary: UUID, level: Float = 0.05, block: Int = 4800) -> [LiveCaptureFragment] {
    stride(from: 0, to: frames, by: block).map { offset in
        LiveCaptureFragment(track: track, samples: Array(repeating: level, count: min(block, frames - offset)),
            activeStartFrame: UInt64(start + offset), day: day,
            wallClockStart: date.addingTimeInterval(Double(start + offset) / 48_000), boundaryID: boundary)
    }
}

private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await predicate()) {
        guard ContinuousClock.now < end else { Issue.record("Timed out"); return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite struct LiveCaptureBridgeTests {
    @Test func fragmentsReachTheSessionInOrderAndStopSavesTheCompleteDraftBeforeReleasingTheLease() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let recorded = BridgeRecorded(), inference = BridgeInference()
        let bridge = LiveCaptureBridge(host: bridgeHost(inference, recorded), options: LiveTranscriptionOptions(language: .english),
                                       saveInterval: .seconds(60), save: { recorded.draft($0) })
        await bridge.begin()
        let meetingID = UUID(), recordingID = UUID()
        let session = try #require(await bridge.attach(meetingID: meetingID, recordingID: recordingID))
        #expect(await session.state == .ready && recorded.begins == 1)
        // The recorder's normalized blocks are larger than one session append.
        for fragment in fragments(frames: 144_000, day: day, date: date, boundary: boundary, block: 24_576) {
            #expect(bridge.mailbox.offer(fragment) == .accepted)
            try await Task.sleep(for: .milliseconds(1))
        }
        try await eventually { await session.publishedCount >= 1 }
        #expect(recorded.ends == 0)
        await bridge.finish()
        #expect(await session.state == .stopped)
        let saved = try #require(recorded.drafts.last)
        #expect(saved.complete && saved.meetingID == meetingID && saved.recordingID == recordingID)
        #expect(saved.utterances.map(\.text) == ["Row 1"] && saved.utterances[0].track == .system)
        #expect(recorded.ends == 1)
        // Finishing twice releases nothing more.
        await bridge.finish()
        #expect(recorded.ends == 1)
    }

    @Test func pauseAndResumeAreMirroredAndPauseSavesTheDraft() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let recorded = BridgeRecorded(), inference = BridgeInference()
        let bridge = LiveCaptureBridge(host: bridgeHost(inference, recorded), options: LiveTranscriptionOptions(language: .english),
                                       saveInterval: .seconds(60), save: { recorded.draft($0) })
        await bridge.begin()
        let session = try #require(await bridge.attach(meetingID: UUID(), recordingID: UUID()))
        for fragment in fragments(frames: 144_000, day: day, date: date, boundary: boundary) { bridge.mailbox.offer(fragment) ; try await Task.sleep(for: .milliseconds(1)) }
        try await eventually { await session.publishedCount >= 1 }
        await bridge.pause()
        #expect(await session.state == .paused)
        #expect(recorded.drafts.last?.complete == false && recorded.drafts.last?.utterances.count == 1)
        await bridge.resume()
        #expect(await session.state == .ready)
        await bridge.finish()
    }

    @Test func missingModelsOrLiveOffStillGiveASessionThatExplainsWhy() async throws {
        let recorded = BridgeRecorded()
        let none = LiveCaptureBridge(host: nil, options: LiveTranscriptionOptions(language: .english))
        await none.begin()
        #expect(await none.attach(meetingID: UUID(), recordingID: UUID())?.state == .unavailable)
        await none.finish()

        let failing = LiveCaptureBridge(host: bridgeHost(BridgeInference(), recorded, failing: true), options: LiveTranscriptionOptions(language: .english))
        await failing.begin()
        #expect(await failing.attach(meetingID: UUID(), recordingID: UUID())?.state == .unavailable)
        await failing.finish()
        #expect(recorded.ends == 0)

        let off = LiveCaptureBridge(host: bridgeHost(BridgeInference(), recorded), options: LiveTranscriptionOptions(enabled: false))
        await off.begin()
        #expect(recorded.begins == 0)
        #expect(await off.attach(meetingID: UUID(), recordingID: UUID())?.state == .disabled)
        await off.finish()
    }

    @Test func cancelDoesNotWaitForInferenceAndCaptureNeverWaitsForTheBridge() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let recorded = BridgeRecorded(), inference = BridgeInference(held: true)
        let bridge = LiveCaptureBridge(host: bridgeHost(inference, recorded), options: LiveTranscriptionOptions(language: .english),
                                       saveInterval: .seconds(60), save: { recorded.draft($0) })
        await bridge.begin()
        let session = try #require(await bridge.attach(meetingID: UUID(), recordingID: UUID()))
        // Offers return at once while inference is held; the mailbox replaces the oldest.
        let started = ContinuousClock.now
        var results: [LiveInferenceMailbox<LiveCaptureFragment>.OfferResult] = []
        for fragment in fragments(frames: 48_000 * 20, day: day, date: date, boundary: boundary) { results.append(bridge.mailbox.offer(fragment)) }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(results.contains(.replacedObsolete))
        try await eventually { await inference.calls >= 1 }
        await bridge.cancel()
        #expect(await session.state == .stopped)
        #expect(recorded.ends == 1)
        await inference.release()
    }

    @Test func replacedFragmentsInsideOneIntervalShowTheDraftAsDelayed() async throws {
        let date = Date(), day = try RecordingDay(capturedAt: date, timeZoneIdentifier: "UTC"), boundary = UUID()
        let recorded = BridgeRecorded()
        let bridge = LiveCaptureBridge(host: bridgeHost(BridgeInference(), recorded), options: LiveTranscriptionOptions(language: .english),
                                       saveInterval: .seconds(60))
        await bridge.begin()
        let session = try #require(await bridge.attach(meetingID: UUID(), recordingID: UUID()))
        let all = fragments(frames: 48_000, day: day, date: date, boundary: boundary)
        bridge.mailbox.offer(all[0])
        bridge.mailbox.offer(all[5])
        try await eventually { if case .delayed = await session.state { return true }; return false }
        await bridge.finish()
    }
}
