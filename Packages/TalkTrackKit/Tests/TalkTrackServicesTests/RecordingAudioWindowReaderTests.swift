import AVFoundation
import Darwin
import Foundation
import Testing
import TalkTrackAudio
import TalkTrackDomain
@testable import TalkTrackServices

private func windowSignal(_ frame: Int, track: AudioTrack) -> Float {
    let t = Double(frame) / 48_000, base = track == .system ? 331.0 : 733.0
    return Float(0.2 * sin(2 * .pi * (base * t + 7 * t * t)))
}
private func windowTicks(_ seconds: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: seconds) }
private func windowDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private func windowInterval(_ start: Double, _ end: Double) throws -> MediaInterval {
    try MediaInterval(start: MediaTime(seconds: start), end: MediaTime(seconds: end))
}
private func windowFeed(_ writer: RecordingAudioWriter, track: AudioTrack, start: Int, end: Int, origin: UInt64) async throws {
    var offset = start
    while offset < end {
        let count = min(1373, end - offset)
        let samples = (offset..<(offset + count)).map { windowSignal($0, track: track) }
        try await writer.append(track: track, samples: samples, activeStartFrame: UInt64(offset),
                                hostTimeStart: origin + windowTicks(Double(offset - start) / 48_000))
        offset += count
    }
}
private func windowFixture(_ folder: TemporaryFolder, frames: Int, tracks: [AudioTrack] = AudioTrack.allCases) async throws -> (OpenedLibrary, RecordingAudioManifest) {
    let library = try await OwnedLibrary().open(root: folder.url)
    let date = windowDate("2026-10-08T10:00:00Z"), origin = windowTicks(100)
    let recording = try Recording(meetingID: UUID(), startedAt: date, timeZoneIdentifier: "UTC")
    let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
    var clock = CaptureIntervalClock()
    try clock.begin(hostTime: origin, wallClock: date, timeZoneIdentifier: "UTC")
    let timing = try clock.close(at: origin + windowTicks(Double(frames) / 48_000))
    try await writer.updateCaptureTiming(timing, state: .recording)
    for track in tracks { try await windowFeed(writer, track: track, start: 0, end: frames, origin: origin) }
    return (library, try await writer.finish())
}
private func readAudio(_ reader: RecordingAudioWindowReader) async throws -> RecordingAudioWindow {
    guard case let .audio(window) = try await reader.next() else { throw AudioWindowReadError.invalidRelativeTime }
    return window
}

@Suite struct RecordingAudioWindowReaderTests {
    @Test func actualAACWindowsCrossChunksWithNoMissingFramesAndUniqueOverlapOwnership() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let frames = 997_643
        let (library, manifest) = try await windowFixture(folder, frames: frames)
        #expect(manifest.audio.count == 6)
        let config = try AudioWindowConfiguration(sourceFrames: 288_000, overlapFrames: 48_000)
        for track in AudioTrack.allCases {
            let reader = try await RecordingAudioWindowReader.open(library: library, recording: manifest.recording, track: track, configuration: config)
            var windows: [RecordingAudioWindow] = [], ownedEnd = MediaTime.zero
            while let event = try await reader.next() {
                guard case let .audio(window) = event else { Issue.record("Unexpected gap in complete fixture"); return }
                #expect(window.track == track)
                #expect(window.recordingID == manifest.recording.id)
                #expect(window.owned.start == ownedEnd)
                #expect(window.sourceFrames.upperBound - window.sourceFrames.lowerBound <= 288_000)
                #expect(window.validSampleFrames == Int((window.sourceFrames.upperBound - window.sourceFrames.lowerBound + 2) / 3))
                // Independent analytic signal checks source-frame selection,
                // channel provenance and timing through the native lossy codec.
                var sum = 0.0
                let range = 128..<(window.validSampleFrames - 128)
                for i in range {
                    let frame = Int(window.sourceFrames.lowerBound) + i * 3
                    let delta = Double(window.samples[i]) - Double(windowSignal(frame, track: track))
                    sum += delta * delta
                }
                #expect(sqrt(sum / Double(range.count)) < 0.025)
                ownedEnd = window.owned.end
                windows.append(window)
            }
            #expect(windows.map(\.sourceFrames.lowerBound) == [0, 240_000, 480_000, 720_000])
            #expect(windows.last?.sourceFrames.upperBound == UInt64(frames))
            #expect(ownedEnd == manifest.recording.activeDuration)
            #expect(await reader.progress == 1)
            // This utterance straddles the midpoint of the shared 5–6 s area.
            let first = try windows[0].project(relative: windowInterval(5.25, 5.75))
            let second = try windows[1].project(relative: windowInterval(0.25, 0.75))
            #expect(first == second)
            #expect(!windows[0].owns(first))
            #expect(windows[1].owns(second))
            #expect(windows[1].wallClockStart == manifest.recording.startedAt.addingTimeInterval(5))
            // Closing does not retain any active file or background producer.
            await reader.close()
            #expect(try await reader.next() == nil)
        }
    }

    @Test func finalPartialReadAndModelPaddingKeepOnlyRealSourceTimestamps() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (library, manifest) = try await windowFixture(folder, frames: 48_003, tracks: [.microphone])
        let config = try AudioWindowConfiguration(sourceFrames: 48_000, overlapFrames: 0)
        let reader = try await RecordingAudioWindowReader.open(library: library, recording: manifest.recording, track: .microphone, configuration: config)
        let first = try await readAudio(reader), last = try await readAudio(reader)
        #expect(first.validSampleFrames == 16_000)
        #expect(last.sourceFrames == 48_000..<48_003)
        #expect(last.validSampleFrames == 1)
        #expect(last.samples.count == 1600)
        #expect(last.samples.dropFirst().allSatisfy { $0 == 0 })
        let projection = try last.project(relative: windowInterval(0, 1.0 / 16_000))
        #expect(projection.active.end == manifest.recording.activeDuration)
        #expect(projection.track == .microphone)
        #expect(throws: AudioWindowReadError.invalidRelativeTime) {
            try last.project(relative: windowInterval(0.02, 0.05))
        }
        #expect(throws: AudioWindowReadError.invalidRelativeTime) {
            try first.project(relative: windowInterval(0.9, 1.1))
        }
        let segment = TranscriptSegment(recordingID: projection.recordingID, dayID: projection.dayID, track: projection.track,
            interval: projection.active, wallClockStart: projection.wallClockStart, speaker: .system(daySpeakerID: UUID()), originalText: "You")
        #expect(segment.speaker == .microphone)
        #expect(try await reader.next() == nil)
        #expect(await reader.progress == 1)
    }

    @Test func pauseMidnightTimezoneAndSourceGapResetContextWithoutShiftingOtherTrack() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let start = windowDate("2026-10-08T23:59:59Z"), origin = windowTicks(100)
        let recording = try Recording(meetingID: UUID(), startedAt: start, timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
        var clock = CaptureIntervalClock()
        try clock.begin(hostTime: origin, wallClock: start, timeZoneIdentifier: "UTC")
        let firstTiming = try clock.close(at: origin + windowTicks(2))
        try await writer.updateCaptureTiming(firstTiming, state: .recording)
        for track in AudioTrack.allCases { try await windowFeed(writer, track: track, start: 0, end: 96_000, origin: origin) }
        try await writer.closeInterval()
        try await writer.updateCaptureTiming(firstTiming, state: .paused)
        try clock.begin(hostTime: origin + windowTicks(302), wallClock: start.addingTimeInterval(302), timeZoneIdentifier: "Asia/Tokyo")
        let completeTiming = try clock.close(at: origin + windowTicks(305))
        try await writer.updateCaptureTiming(completeTiming, state: .recording)
        try await windowFeed(writer, track: .system, start: 96_000, end: 240_000, origin: origin + windowTicks(302))
        try await windowFeed(writer, track: .microphone, start: 96_000, end: 120_000, origin: origin + windowTicks(302))
        try await writer.recordGap(track: .microphone, active: windowInterval(2.5, 3.5), reason: "Input route disconnected")
        try await windowFeed(writer, track: .microphone, start: 168_000, end: 240_000, origin: origin + windowTicks(303.5))
        let manifest = try await writer.finish(interrupted: true)
        let config = try AudioWindowConfiguration(sourceFrames: 1_440_000, overlapFrames: 48_000)
        let system = try await RecordingAudioWindowReader.open(library: library, recording: manifest.recording, track: .system, configuration: config)
        let a = try await readAudio(system), b = try await readAudio(system), c = try await readAudio(system)
        #expect(a.sourceFrames == 0..<48_000)
        #expect(b.sourceFrames == 48_000..<96_000)
        #expect(c.sourceFrames == 96_000..<240_000)
        #expect(a.day.localDate == "2026-10-08")
        #expect(b.day.localDate == "2026-10-09")
        #expect(a.day.utcOffsetSeconds == 0 && b.day.utcOffsetSeconds == 0)
        #expect(c.day.utcOffsetSeconds == 32_400)
        #expect(c.day.timeZoneIdentifier == "Asia/Tokyo")
        #expect(c.wallClockStart == start.addingTimeInterval(302))
        let projection = try c.project(relative: windowInterval(0.1, 0.3))
        #expect(projection.active == (try windowInterval(2.1, 2.3)))
        #expect(projection.wallClockStart == start.addingTimeInterval(302.1))
        #expect(try await system.next() == nil)
        let microphone = try await RecordingAudioWindowReader.open(library: library, recording: manifest.recording, track: .microphone, configuration: config)
        _ = try await readAudio(microphone); _ = try await readAudio(microphone)
        let beforeGap = try await readAudio(microphone)
        #expect(beforeGap.active == (try windowInterval(2, 2.5)))
        guard case let .gap(gap) = try await microphone.next() else { Issue.record("Missing source gap"); return }
        #expect(gap.active == (try windowInterval(2.5, 3.5)))
        #expect(gap.reason == "Input route disconnected")
        #expect(gap.track == .microphone)
        #expect(gap.wallClockStart == start.addingTimeInterval(302.5))
        let afterGap = try await readAudio(microphone)
        #expect(afterGap.active == (try windowInterval(3.5, 5)))
        #expect(afterGap.owned == afterGap.active)
        #expect(afterGap.wallClockStart == start.addingTimeInterval(303.5))
        #expect(try await microphone.next() == nil)
        #expect(await microphone.progress == 1)
    }

    @Test func absentTrackIsAnExplicitEventAndEmptyRecordingIsEmpty() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (library, manifest) = try await windowFixture(folder, frames: 48_000, tracks: [.system])
        let reader = try await RecordingAudioWindowReader.open(library: library, recording: manifest.recording, track: .microphone)
        guard case let .gap(gap) = try await reader.next() else { Issue.record("Missing track was replaced with fabricated audio"); return }
        #expect(gap.active == (try windowInterval(0, 1)))
        #expect(gap.track == .microphone)
        #expect(try await reader.next() == nil)
        let empty = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let noAudio = try await RecordingAudioWindowReader.open(library: library, recording: empty, track: .system)
        #expect(try await noAudio.next() == nil)
        #expect(await noAudio.progress == 1)
    }

    @Test func corruptionMissingReceiptAndSymlinkFailuresRetrySamePosition() async throws {
        let folder = try TemporaryFolder(), outside = try TemporaryFolder()
        defer { folder.remove(); outside.remove() }
        let (library, manifest) = try await windowFixture(folder, frames: 60_000, tracks: [.system])
        let chunk = try #require(manifest.audio.first)
        let audio = library.directory.appendingPathComponent(chunk.chunk.file.value)
        let receipt = audio.deletingPathExtension().appendingPathExtension("json")
        let audioBytes = try Data(contentsOf: audio), receiptBytes = try Data(contentsOf: receipt)
        let config = try AudioWindowConfiguration(sourceFrames: 48_000, overlapFrames: 0)
        let reader = try await RecordingAudioWindowReader.open(library: library, recording: manifest.recording, track: .system, configuration: config)
        try Data("corrupt container".utf8).write(to: audio)
        await #expect(throws: AudioWindowReadError.damagedChunk(recordingID: manifest.recording.id, chunkID: chunk.chunk.id)) {
            try await reader.next()
        }
        #expect(await reader.progress == 0)
        try audioBytes.write(to: audio)
        try FileManager.default.removeItem(at: receipt)
        await #expect(throws: LibraryError.self) { try await reader.next() }
        #expect(await reader.progress == 0)
        try receiptBytes.write(to: receipt)
        let sentinel = outside.url.appendingPathComponent("sentinel.m4a")
        try audioBytes.write(to: sentinel)
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: sentinel)
        await #expect(throws: LibraryError.self) { try await reader.next() }
        #expect(try Data(contentsOf: sentinel) == audioBytes)
        #expect(await reader.progress == 0)
        try FileManager.default.removeItem(at: audio)
        try audioBytes.write(to: audio)
        let restored = try await readAudio(reader)
        #expect(restored.sourceFrames.lowerBound == 0)
        #expect(await reader.progress == 0.8)
        #expect(try await readAudio(reader).sourceFrames == 48_000..<60_000)
    }

    @Test func cancelledReadDoesNotAdvanceAndCloseStopsFutureReads() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (library, manifest) = try await windowFixture(folder, frames: 48_000, tracks: [.system])
        let reader = try await RecordingAudioWindowReader.open(library: library, recording: manifest.recording, track: .system)
        let work = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await reader.next()
        }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(await reader.progress == 0)
        #expect(try await readAudio(reader).sourceFrames.lowerBound == 0)
        await reader.close()
        #expect(try await reader.next() == nil)
    }

    @Test func twoHourMetadataIsLazyAndPCMRemainsOneBoundedWindow() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (library, manifest) = try await windowFixture(folder, frames: 480_000, tracks: [.system])
        var recording = manifest.recording
        recording.activeDuration = try MediaTime(seconds: 7200)
        recording.captureIntervals = [CaptureInterval(active: try windowInterval(0, 7200), wallClockStart: recording.startedAt,
            hostTimeStart: recording.captureIntervals[0].hostTimeStart, dayID: recording.days[0].id)]
        // Only the first ten-second file exists. If opening a recording eagerly
        // reads future files or allocates full-duration PCM, this read cannot pass.
        for i in 1..<720 {
            let id = UUID()
            let chunk = try TrackChunk(id: id, track: .system,
                file: RelativePath("Meetings/\(recording.meetingID)/Recordings/\(recording.id)/system/\(id).m4a"),
                active: windowInterval(Double(i * 10), Double(i * 10 + 10)), sampleRate: 48_000,
                decodedFrameCount: 480_000, leadingTrimFrames: 0, trailingTrimFrames: 0, hostTimeStart: 1)
            recording.chunks.append(chunk)
            recording.trackIntervals.append(TrackInterval(track: .system, active: chunk.active,
                content: .chunk(id: id, firstDecodedFrame: 0, frameCount: 480_000)))
        }
        let config = try AudioWindowConfiguration(sourceFrames: 144_000, overlapFrames: 24_000)
        let reader = try await RecordingAudioWindowReader.open(library: library, recording: recording, track: .system, configuration: config)
        let first = try await readAudio(reader)
        #expect(first.sourceFrames == 0..<144_000)
        #expect(first.samples.count == 48_000)
        #expect(await reader.progress < 0.001)
        await reader.close()
    }

    @Test func invalidBoundsMissingTimingAndCrossSourceReferencesAreRejected() async throws {
        for (frames, overlap): (UInt32, UInt32) in [(0, 0), (10, 10), (1_440_001, 0)] {
            #expect(throws: AudioWindowReadError.invalidConfiguration) {
                try AudioWindowConfiguration(sourceFrames: frames, overlapFrames: overlap)
            }
        }
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (library, manifest) = try await windowFixture(folder, frames: 48_000, tracks: [.system])
        var recording = manifest.recording
        recording.captureIntervals = []
        await #expect(throws: AudioWindowReadError.missingCaptureTiming(recording.id)) {
            try await RecordingAudioWindowReader.open(library: library, recording: recording, track: .system)
        }
        let receipt = try #require(manifest.audio.first)
        let wrong = StoredAudioChunk(libraryID: UUID(), meetingID: receipt.meetingID, recordingID: receipt.recordingID,
            chunk: receipt.chunk, encoding: receipt.encoding, byteCount: receipt.byteCount, sha256: receipt.sha256)
        let url = library.directory.appendingPathComponent(receipt.chunk.file.value).deletingPathExtension().appendingPathExtension("json")
        try DomainCodec.encode(wrong).write(to: url)
        let reader = try await RecordingAudioWindowReader.open(library: library, recording: manifest.recording, track: .system)
        await #expect(throws: AudioWindowReadError.damagedChunk(recordingID: manifest.recording.id, chunkID: receipt.chunk.id)) {
            try await reader.next()
        }
    }
}
