import AVFoundation
import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

private enum DiarizationFixtureError: Error { case injected }
private actor FixtureSpeakerInference: SystemSpeakerInference {
    enum Mode: Sendable { case single, overlap, mixed }
    let mode: Mode
    var failEmbedding: Bool
    var delay = false
    var segmentCalls = 0, embeddingCalls = 0
    var segmentFrames: [Int] = [], embeddingFrames: [Int] = []
    init(_ mode: Mode = .single, failEmbedding: Bool = false) { self.mode = mode; self.failEmbedding = failEmbedding }
    func setDelay(_ enabled: Bool) { delay = enabled }
    func speakerActivity(_ model: ModelSnapshot, samples: [Float]) async throws -> [SpeakerWindowActivity] {
        segmentCalls += 1; segmentFrames.append(samples.count)
        if delay { try await Task.sleep(for: .seconds(5)) }
        let end = Double(samples.count) / 16_000
        switch mode {
        case .single: return [SpeakerWindowActivity(slot: segmentCalls % 3 + 1, relative: try clusterRange(0, end))]
        case .overlap: return [SpeakerWindowActivity(slot: 1, relative: try clusterRange(0, 3)), SpeakerWindowActivity(slot: 2, relative: try clusterRange(2, end))]
        case .mixed: return [SpeakerWindowActivity(slot: 1, relative: try clusterRange(0, end)), SpeakerWindowActivity(slot: 2, relative: try clusterRange(0, end))]
        }
    }
    func speakerEmbedding(_ model: ModelSnapshot, samples: [Float]) async throws -> SpeakerWindowEmbedding {
        embeddingCalls += 1; embeddingFrames.append(samples.count)
        if failEmbedding { failEmbedding = false; throw DiarizationFixtureError.injected }
        return SpeakerWindowEmbedding(values: clusterVector(mode == .overlap ? (embeddingCalls - 1) % 2 : 0), model: model)
    }
}

private func diarizationRecording(_ library: OpenedLibrary, meetingID: UUID, seconds: Double = 5.1,
                                  date: Date = ISO8601DateFormatter().date(from: "2026-10-08T10:00:00Z")!) async throws -> Recording {
    let recording = try Recording(meetingID: meetingID, startedAt: date, timeZoneIdentifier: "UTC")
    let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
    let origin = AVAudioTime.hostTime(forSeconds: 100), frames = Int((seconds * 48_000).rounded())
    var clock = CaptureIntervalClock()
    try clock.begin(hostTime: origin, wallClock: date, timeZoneIdentifier: "UTC")
    try await writer.updateCaptureTiming(clock.close(at: origin + AVAudioTime.hostTime(forSeconds: seconds)), state: .recording)
    for track in AudioTrack.allCases {
        var offset = 0
        while offset < frames {
            let end = min(frames, offset + 1537)
            let samples = (offset..<end).map { Float(0.1 * sin(2 * .pi * 400 * Double($0) / 48_000)) }
            try await writer.append(track: track, samples: samples, activeStartFrame: UInt64(offset),
                hostTimeStart: origin + AVAudioTime.hostTime(forSeconds: Double(offset) / 48_000))
            offset = end
        }
    }
    return try await writer.finish().recording
}

@Suite struct SystemDiarizationSessionTests {
    @Test func realAACPullStreamSharesSameDayIdentitiesAcrossRecordingsAndFormatsAliases() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url), meetingID = UUID()
        let (segmentation, embedding) = try clusteringModels(), model = FixtureSpeakerInference()
        let session = try SystemDiarizationSession(meetingID: meetingID, segmentation: segmentation, embedding: embedding, inference: model)
        let first = try await diarizationRecording(library, meetingID: meetingID)
        let second = try await diarizationRecording(library, meetingID: meetingID, date: first.startedAt.addingTimeInterval(3600))
        let config = try AudioWindowConfiguration(sourceFrames: 96_000, overlapFrames: 24_000)
        var segments: [DiarizedSystemSegment] = []
        for recording in [first, second] {
            let reader = try await RecordingAudioWindowReader.open(library: library, recording: recording, track: .system, configuration: config)
            let stream = RecordingDiarizationStream(reader: reader, session: session)
            var end = MediaTime.zero
            while let event = try await stream.next() {
                guard case let .speech(result) = event else { Issue.record("Unexpected gap"); return }
                #expect(result.processed.start == end)
                end = result.processed.end
                segments += result.segments
            }
            #expect(end == recording.activeDuration)
            #expect(await stream.progress == 1)
            try await stream.close()
            #expect(try await stream.next() == nil)
        }
        #expect(Set(segments.map(\.speakerID)).count == 1)
        #expect(await model.segmentCalls == 8)
        #expect(await model.segmentFrames.allSatisfy { $0 <= 32_000 })
        #expect(await model.embeddingFrames.allSatisfy { (16_000...32_000).contains($0) })
        #expect(await session.retainedVectorCount <= 8)
        let speakers = await session.speakers
        #expect(Set(try #require(speakers.first).recordingDayIDs) == Set([first.days[0].id, second.days[0].id]))
        let transcript = segments.map { TranscriptSegment(recordingID: $0.recordingID, dayID: $0.dayID, track: .system,
            interval: $0.active, wallClockStart: $0.wallClockStart, speaker: .system(daySpeakerID: $0.speakerID), originalText: "Hello") }
        let formatted = try TranscriptFormatter.format(meetingID: meetingID, recordings: [first, second], segments: transcript, speakers: speakers)
        #expect(formatted.compactMap { if case let .speech(block) = $0 { block.speakerLabel } else { nil } } == ["Voice1", "Voice1"])
        let data = try await session.checkpoint()
        let reopened = try SystemDiarizationSession(meetingID: meetingID, segmentation: segmentation, embedding: embedding, inference: model, checkpoint: data)
        #expect(await reopened.speakers == speakers)
    }

    @Test func overlapIsRetainedAndOnlyExclusiveSpeechFeedsEmbeddings() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url), meetingID = UUID()
        let (segmentation, embedding) = try clusteringModels()
        let recording = try await diarizationRecording(library, meetingID: meetingID, seconds: 5)
        for mode: FixtureSpeakerInference.Mode in [.overlap, .mixed] {
            let model = FixtureSpeakerInference(mode)
            let session = try SystemDiarizationSession(meetingID: meetingID, segmentation: segmentation, embedding: embedding, inference: model)
            let reader = try await RecordingAudioWindowReader.open(library: library, recording: recording, track: .system)
            guard case let .audio(window) = try await reader.next() else { Issue.record("Expected audio"); return }
            let result = try await session.process(window)
            #expect(result.segments.count == 2)
            #expect(Set(result.segments.map(\.speakerID)).count == 2)
            if mode == .overlap {
                #expect(await model.embeddingCalls == 2)
                #expect(await model.embeddingFrames == [30_400, 30_400])
                #expect(result.segments[0].active.end > result.segments[1].active.start)
            } else {
                #expect(await model.embeddingCalls == 0)
                #expect(await session.retainedVectorCount == 0)
            }
        }
    }

    @Test func modelFailureAndCancellationRetryPendingWindowWithoutAdvancingCheckpoint() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url), meetingID = UUID()
        let (segmentation, embedding) = try clusteringModels(), model = FixtureSpeakerInference(failEmbedding: true)
        let session = try SystemDiarizationSession(meetingID: meetingID, segmentation: segmentation, embedding: embedding, inference: model)
        let recording = try await diarizationRecording(library, meetingID: meetingID, seconds: 2)
        let reader = try await RecordingAudioWindowReader.open(library: library, recording: recording, track: .system)
        let stream = RecordingDiarizationStream(reader: reader, session: session), initial = try await session.checkpoint()
        await #expect(throws: DiarizationFixtureError.self) { try await stream.next() }
        #expect(await stream.progress == 0)
        #expect(try await session.checkpoint() == initial)
        await model.setDelay(true)
        let previousCalls = await model.segmentCalls
        let work = Task { try await stream.next() }
        while await model.segmentCalls == previousCalls { await Task.yield() }
        await #expect(throws: SpeakerClusteringError.busy) { try await stream.next() }
        await #expect(throws: SpeakerClusteringError.busy) { try await session.checkpoint() }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try await session.checkpoint() == initial)
        #expect(await stream.progress == 0)
        await model.setDelay(false)
        guard case let .speech(result) = try await stream.next() else { Issue.record("Expected retry result"); return }
        #expect(result.processed.start == .zero)
        #expect(result.processed.end == recording.activeDuration)
        #expect(await model.segmentCalls == 3)
        #expect(await session.speakers.count == 1)
    }

    @Test func microphoneForeignMeetingAndOversizedWindowAreRejectedBeforeInference() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url), meetingID = UUID()
        let (segmentation, embedding) = try clusteringModels(), model = FixtureSpeakerInference()
        let session = try SystemDiarizationSession(meetingID: meetingID, segmentation: segmentation, embedding: embedding, inference: model)
        for (id, track, seconds) in [(meetingID, AudioTrack.microphone, 2.0), (UUID(), .system, 2), (meetingID, .system, 11)] {
            let recording = try await diarizationRecording(library, meetingID: id, seconds: seconds)
            let reader = try await RecordingAudioWindowReader.open(library: library, recording: recording, track: track,
                configuration: AudioWindowConfiguration(sourceFrames: 1_440_000, overlapFrames: 0))
            guard case let .audio(window) = try await reader.next() else { Issue.record("Expected audio"); return }
            await #expect(throws: SpeakerClusteringError.invalidInput) { try await session.process(window) }
        }
        #expect(await model.segmentCalls == 0)
        #expect(await session.speakers.isEmpty)
    }

    @Test func sourceGapReturnsWithoutInferenceAndDoesNotFabricateSpeech() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url), meetingID = UUID()
        let (segmentation, embedding) = try clusteringModels(), model = FixtureSpeakerInference()
        var recording = try await diarizationRecording(library, meetingID: meetingID, seconds: 2)
        recording.trackIntervals = [TrackInterval(track: .system, active: try clusterRange(0, 2), content: .gap(reason: "Source unavailable"))]
        let session = try SystemDiarizationSession(meetingID: meetingID, segmentation: segmentation, embedding: embedding, inference: model)
        let reader = try await RecordingAudioWindowReader.open(library: library, recording: recording, track: .system)
        let stream = RecordingDiarizationStream(reader: reader, session: session)
        guard case let .gap(gap) = try await stream.next() else { Issue.record("Expected gap"); return }
        #expect(gap.reason == "Source unavailable")
        #expect(try await stream.next() == nil)
        #expect(await stream.progress == 1)
        #expect(await model.segmentCalls == 0)
    }
}
