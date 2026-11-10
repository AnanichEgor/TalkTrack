import Darwin
import Foundation
import Testing
import TalkTrackAudio
import TalkTrackDomain
@testable import TalkTrackServices

/// compact-library-storage D7: the background service against recording,
/// playback, delete and move.
@Suite struct AudioCompactionServiceTests {
    struct Library {
        let folder: TemporaryFolder
        let library: OpenedLibrary
        let store: SessionStore
        let meeting: Meeting
        let recordings: [Recording]
    }

    static func library(recordings count: Int = 2) async throws -> Library {
        let folder = try TemporaryFolder()
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Old meeting", description: ""))
        var recordings: [Recording] = []
        for _ in 0..<count {
            recordings.append(try await write(library: library, meetingID: meeting.id, padded: true, seconds: 25))
            try await store.saveRecording(recordings.last!)
        }
        return Library(folder: folder, library: library, store: store, meeting: meeting, recordings: recordings)
    }

    static func write(library: OpenedLibrary, meetingID: UUID, padded: Bool, seconds: Int) async throws -> Recording {
        let recording = try Recording(meetingID: meetingID, timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording, hook: nil)
        if padded { await writer.usePaddedChunks() }
        for track in AudioTrack.allCases {
            for offset in stride(from: 0, to: seconds * 48_000, by: 4_800) {
                let samples = (offset..<(offset + 4_800)).map { Float(0.2 * sin(Double($0) * (track == .system ? 0.03 : 0.05))) }
                try await writer.append(track: track, samples: samples, activeStartFrame: UInt64(offset),
                                        hostTimeStart: 1_000_000 + UInt64(offset) * 1000)
            }
        }
        return try await writer.finish().recording
    }

    static func folder(_ library: OpenedLibrary, _ recording: Recording) -> URL {
        library.directory.appendingPathComponent("Meetings/\(recording.meetingID)/Recordings/\(recording.id)")
    }

    /// Blocks the service at the first `receiptWritten` until released.
    final class Gate: @unchecked Sendable {
        let reached = AccessFlag()
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock(); private var used = false
        func step(_ step: CompactionStep) {
            guard step == .receiptWritten, lock.withLock({ let first = !used; used = true; return first }) else { return }
            reached.set(); release.wait()
        }
        func waitReached() async { for _ in 0..<1000 where !reached.value { try? await Task.sleep(for: .milliseconds(10)) } }
    }

    final class Busy: @unchecked Sendable {
        private let lock = NSLock(); private var flag = false
        var value: Bool { get { lock.withLock { flag } } set { lock.withLock { flag = newValue } } }
    }

    @Test func aPassCompactsEveryOldRecordingOnceAndMarksIt() async throws {
        let fixture = try await Self.library()
        defer { fixture.folder.remove() }
        let service = AudioCompaction(library: fixture.library, store: fixture.store, isBusy: { false })
        let pass = await service.runOnce()
        #expect(pass.recordings == 2 && pass.compacted == 12 && pass.deferred == 0 && pass.failed == 0 && pass.savedBytes > 12 * 32_768)
        for recording in fixture.recordings {
            #expect(FileManager.default.fileExists(atPath: Self.folder(fixture.library, recording).appendingPathComponent(".compacted").path))
        }
        // Marked recordings are not scanned again.
        #expect(await service.runOnce() == AudioCompaction.Pass())
        try await fixture.store.close()
    }

    @Test func recordingDuringCompactionStartsAtOnceAndPausesIt() async throws {
        let fixture = try await Self.library()
        defer { fixture.folder.remove() }
        let busy = Busy(), gate = Gate()
        let service = AudioCompaction(library: fixture.library, store: fixture.store, isBusy: { busy.value })
        service.pollInterval = .milliseconds(20)
        service.hook = { _, step in gate.step(step) }
        let pass = Task { await service.runOnce() }
        await gate.waitReached()
        // Record while a chunk is mid-replacement: the new recording's writer
        // does not wait for compaction.
        busy.value = true
        let started = ContinuousClock.now
        let writer = try await RecordingAudioWriter.create(library: fixture.library,
            recording: try Recording(meetingID: fixture.meeting.id, timeZoneIdentifier: "UTC"))
        try await writer.append(track: .system, samples: [Float](repeating: 0.1, count: 4_800), activeStartFrame: 0, hostTimeStart: 1)
        #expect(ContinuousClock.now - started < .seconds(1))
        // The service notices the capture and stops after this chunk.
        try await Task.sleep(for: .milliseconds(100))
        gate.release.signal()
        let first = await pass.value
        #expect(first.compacted == 1 && first.deferred >= 1)
        _ = try await writer.finish()
        // After Stop, the next pass completes the rest.
        busy.value = false
        let second = await service.runOnce()
        #expect(second.compacted == 11 && second.deferred == 0)
        try await fixture.store.close()
    }

    @Test func playbackDuringCompactionStartsAfterOneChunk() async throws {
        let fixture = try await Self.library(recordings: 1)
        defer { fixture.folder.remove() }
        let gate = Gate()
        let service = AudioCompaction(library: fixture.library, store: fixture.store, isBusy: { false })
        service.hook = { _, step in gate.step(step) }
        let pass = Task { await service.runOnce() }
        await gate.waitReached()
        let recording = fixture.recordings[0], library = fixture.library
        let played = Task.detached { () -> Int in
            let chunks = CommittedAudioChunks(library: library)
            let owned = try chunks.ownedDirectory()
            var samples: [Float] = []
            for chunk in recording.chunks where chunk.track == .system {
                try chunks.decode(chunk, of: recording, selected: 0..<chunk.decodedFrameCount, owned: owned,
                                  checkCancellation: {}, into: &samples)
            }
            return samples.count
        }
        try await Task.sleep(for: .milliseconds(150))
        gate.release.signal()
        #expect(try await played.value == 25 * 48_000)
        let first = await pass.value
        #expect(first.deferred == 1)
        #expect(await service.runOnce().deferred == 0)
        try await fixture.store.close()
    }

    @Test func deleteAndMoveOfARecordingBeingCompactedWaitThenSucceed() async throws {
        let fixture = try await Self.library()
        defer { fixture.folder.remove() }
        let other = try await fixture.store.createMeeting(MeetingDraft(title: "Destination", description: ""))
        for (index, action) in ["delete", "move"].enumerated() {
            let gate = Gate()
            let service = AudioCompaction(library: fixture.library, store: fixture.store, isBusy: { false })
            service.hook = { _, step in gate.step(step) }
            let pass = Task { await service.runOnce() }
            await gate.waitReached()
            // The recording being compacted: the first one not yet marked.
            let target = fixture.recordings[index]
            let store = fixture.store
            let done = AccessFlag()
            let operation = Task {
                if action == "delete" { try await store.deleteRecording(meetingID: target.meetingID, recordingID: target.id) }
                else { _ = try await store.moveRecording(target.id, from: target.meetingID, to: other.id) }
                done.set()
            }
            try await Task.sleep(for: .milliseconds(150))
            #expect(!done.value, "\(action) waits for the chunk being replaced")
            // This pass ends after the chunk, leaving the other recording for the next case.
            await service.stop()
            gate.release.signal()
            try await operation.value
            _ = await pass.value
            let source = Self.folder(fixture.library, target)
            #expect(!FileManager.default.fileExists(atPath: source.path))
            if action == "move" {
                let recordings = try await store.recordings(meetingID: other.id)
                let current = try #require(recordings.first { $0.id == target.id })
                let chunks = CommittedAudioChunks(library: fixture.library)
                let owned = try chunks.ownedDirectory()
                for chunk in current.chunks { try chunks.verify(chunk, of: current, owned: owned) }
                // A later pass finishes it in its new place.
                let later = await AudioCompaction(library: fixture.library, store: store, isBusy: { false }).runOnce()
                #expect(later.failed == 0 && later.deferred == 0)
                #expect(!FileManager.default.fileExists(atPath: Self.folder(fixture.library, current).appendingPathComponent(".compacting").path))
                for chunk in current.chunks { try chunks.verify(chunk, of: current, owned: owned) }
            }
        }
        try await fixture.store.close()
    }
}
