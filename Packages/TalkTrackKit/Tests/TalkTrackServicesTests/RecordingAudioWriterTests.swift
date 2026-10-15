import AVFoundation
import Darwin
import Foundation
import Testing
import TalkTrackAudio
import TalkTrackDomain
@testable import TalkTrackServices

private func fixtureSignal(_ frame: Int, track: AudioTrack) -> Float {
    let t = Double(frame) / 48_000
    let base = track == .system ? 331.0 : 523.0
    return Float((0.22 * sin(2 * .pi * base * t) + 0.12 * sin(2 * .pi * (997 * t + 19 * t * t)))
        * (0.7 + 0.3 * sin(2 * .pi * 3.1 * t)))
}

private func feed(_ writer: RecordingAudioWriter, track: AudioTrack, count: Int, start: Int = 0) async throws {
    var offset = 0
    while offset < count {
        let size = min(1373, count - offset)
        let samples = (offset..<(offset + size)).map { fixtureSignal($0, track: track) }
        try await writer.append(track: track, samples: samples, activeStartFrame: UInt64(start + offset),
            hostTimeStart: 1_000_000 + AVAudioTime.hostTime(forSeconds: Double(start + offset) / 48_000))
        offset += size
    }
}

private func readChunk(_ item: StoredAudioChunk, library: OpenedLibrary) throws -> [Float] {
    let fd = open(library.directory.appendingPathComponent(item.chunk.file.value).path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw LibraryError.unavailable(item.chunk.file.value) }
    defer { close(fd) }
    var result: [Float] = []
    _ = try AACChunkEncoder.decode(fileDescriptor: fd, expectedFrames: item.encoding.validFrames) { result.append(contentsOf: $0) }
    return result
}

private final class CommitFault: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let point: AudioCommitPoint
    init(_ point: AudioCommitPoint) { self.point = point }
    func call(_ observed: AudioCommitPoint) throws {
        let fail = lock.withLock { () -> Bool in
            guard observed == point else { return false }
            count += 1; return count == 2
        }
        if fail { throw ServiceError(message: "Injected commit failure", recovery: "Recover") }
    }
}

@Suite struct RecordingAudioWriterTests {
    @Test func independentTracksExactFramesTimingAndEveryDecodedBoundary() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "Europe/London")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
        let count = 1_009_643, microphoneOffset = 5760
        try await feed(writer, track: .system, count: count)
        try await feed(writer, track: .microphone, count: count, start: microphoneOffset)
        let result = try await writer.finish()
        #expect(result.recording.state == .complete)
        #expect(result.audio.count == 6)
        #expect(try await writer.finish() == result)
        await #expect(throws: ServiceError.self) {
            try await writer.append(track: .system, samples: [0], activeStartFrame: 0, hostTimeStart: 0)
        }
        for track in AudioTrack.allCases {
            let chunks = result.audio.filter { $0.chunk.track == track }
            #expect(chunks.map(\.encoding.validFrames) == [480_000, 480_000, 49_643])
            #expect(chunks.allSatisfy { $0.chunk.active.duration.seconds <= 10 })
            #expect(chunks.allSatisfy { $0.chunk.leadingTrimFrames == 0 && $0.chunk.trailingTrimFrames == 0 })
            let offset = track == .system ? 0 : microphoneOffset
            #expect(chunks.first?.chunk.active.start.seconds == Double(offset) / 48_000)
            let decoded = try chunks.flatMap { try readChunk($0, library: library) }
            #expect(decoded.count == count)
            for boundary in [480_000, 960_000] {
                // AAC is lossy: compare timing/correlation, not sample equality.
                // Unique chirped waveform makes a lost/duplicated packet visible.
                var bestLag = 0, bestError = Double.infinity
                for lag in -8...8 {
                    var error = 0.0
                    for i in (boundary - 1920)..<(boundary + 1920) {
                        let delta = Double(decoded[i]) - Double(fixtureSignal(i + lag, track: track))
                        error += delta * delta
                    }
                    if error < bestError { bestLag = lag; bestError = error }
                }
                #expect(abs(bestLag) <= 1)
                #expect(sqrt(bestError / 3840) < 0.015)
            }
            for pair in zip(chunks, chunks.dropFirst()) {
                #expect(pair.0.chunk.active.end == pair.1.chunk.active.start)
                let expected = AVAudioTime.hostTime(forSeconds: Double(pair.0.encoding.validFrames) / 48_000)
                // Each packet's input anchor and split position are rounded to
                // host ticks independently; their difference is within one tick.
                #expect(abs(Int64(pair.1.chunk.hostTimeStart - pair.0.chunk.hostTimeStart) - Int64(expected)) <= 1)
            }
        }
        let recovered = try await RecordingAudioWriter.recover(library: library, meetingID: recording.meetingID, recordingID: recording.id)
        #expect(recovered == result)
    }

    @Test(arguments: [AudioCommitPoint.audioSynced, .receiptSynced, .audioPublished, .manifestPublished])
    func recoversReceiptsAcrossEveryPublicationBoundary(point: AudioCommitPoint) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let fault = CommitFault(point)
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording, hook: fault.call)
        await #expect(throws: ServiceError.self) { try await feed(writer, track: .system, count: 960_000) }
        // Fault injection unwinds Swift; release the writer before recovery.
        // The standalone SIGKILL fixture exercises actual process termination.
        _ = try? await writer.finish(interrupted: true)
        let recovered = try await RecordingAudioWriter.recover(library: library, meetingID: recording.meetingID, recordingID: recording.id)
        #expect(recovered.recording.state == .interrupted)
        #expect(recovered.audio.count == (point == .audioSynced ? 1 : 2))
        #expect(recovered.audio.allSatisfy { $0.encoding.validFrames == 480_000 })
        #expect(try recovered.audio.flatMap { try readChunk($0, library: library) }.count == recovered.audio.count * 480_000)
        let again = try await RecordingAudioWriter.recover(library: library, meetingID: recording.meetingID, recordingID: recording.id)
        #expect(again == recovered)
    }

    @Test func recoveryRefusesAnActiveWriterAndFailureStillFlushesOtherSource() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let fault = CommitFault(.receiptSynced)
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording, hook: fault.call)
        try await feed(writer, track: .microphone, count: 4096)
        await #expect(throws: LibraryError.self) {
            try await RecordingAudioWriter.recover(library: library, meetingID: recording.meetingID, recordingID: recording.id)
        }
        await #expect(throws: ServiceError.self) { try await feed(writer, track: .system, count: 960_000) }
        await #expect(throws: ServiceError.self) { _ = try await writer.finish() }
        let recovered = try await RecordingAudioWriter.recover(library: library, meetingID: recording.meetingID, recordingID: recording.id)
        #expect(recovered.audio.filter { $0.chunk.track == .system }.count == 2)
        #expect(recovered.audio.filter { $0.chunk.track == .microphone }.map(\.encoding.validFrames) == [4096])
        #expect(recovered.recording.state == .interrupted)
    }

    @Test func pauseFlushesPartialChunksAndExplicitOffsetsPreserveGaps() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
        try await feed(writer, track: .system, count: 1025)
        await #expect(throws: ServiceError.self) { try await feed(writer, track: .system, count: 100, start: 2000) }
        try await writer.closeInterval()
        try await feed(writer, track: .system, count: 2047, start: 2000)
        let result = try await writer.finish(interrupted: true)
        #expect(result.audio.map(\.encoding.validFrames) == [1025, 2047])
        #expect(result.audio.last?.chunk.active.start == (try MediaTime(seconds: 2000.0 / 48_000)))
        #expect(result.recording.state == .interrupted)
    }

    @Test func corruptionMissingReceiptAndSymlinkNeverEraseCompletedAudio() async throws {
        let folder = try TemporaryFolder(), outside = try TemporaryFolder()
        defer { folder.remove(); outside.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
        try await feed(writer, track: .system, count: 4096)
        let result = try await writer.finish()
        let chunk = try #require(result.audio.first)
        let url = library.directory.appendingPathComponent(chunk.chunk.file.value)
        let original = try Data(contentsOf: url)
        let corrupted = Data("damaged container".utf8)
        try corrupted.write(to: url)
        await #expect(throws: ServiceError.self) {
            try await RecordingAudioWriter.recover(library: library, meetingID: recording.meetingID, recordingID: recording.id)
        }
        #expect(try Data(contentsOf: url) == corrupted)
        try original.write(to: url)
        let receipt = url.deletingPathExtension().appendingPathExtension("json")
        let receiptBytes = try Data(contentsOf: receipt)
        try FileManager.default.removeItem(at: receipt)
        await #expect(throws: ServiceError.self) {
            try await RecordingAudioWriter.recover(library: library, meetingID: recording.meetingID, recordingID: recording.id)
        }
        #expect(try Data(contentsOf: url) == original)
        try receiptBytes.write(to: receipt)
        let sentinel = outside.url.appendingPathComponent("sentinel")
        try original.write(to: sentinel)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: sentinel)
        await #expect(throws: LibraryError.self) {
            try await RecordingAudioWriter.recover(library: library, meetingID: recording.meetingID, recordingID: recording.id)
        }
        #expect(try Data(contentsOf: sentinel) == original)
    }

    @Test func refusesExistingRecordingAndEscapingTrackFolder() async throws {
        let folder = try TemporaryFolder(), outside = try TemporaryFolder()
        defer { folder.remove(); outside.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
        await #expect(throws: LibraryError.self) { try await RecordingAudioWriter.create(library: library, recording: recording) }
        _ = try await writer.finish()
        let track = library.directory.appendingPathComponent("Meetings/\(recording.meetingID)/Recordings/\(recording.id)/system")
        try FileManager.default.removeItem(at: track)
        try FileManager.default.createSymbolicLink(at: track, withDestinationURL: outside.url)
        await #expect(throws: LibraryError.self) {
            try await RecordingAudioWriter.recover(library: library, meetingID: recording.meetingID, recordingID: recording.id)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.url.path).isEmpty)
    }
}
