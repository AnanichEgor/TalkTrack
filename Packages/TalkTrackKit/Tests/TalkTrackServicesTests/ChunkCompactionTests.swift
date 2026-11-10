import Darwin
import Foundation
import Testing
import TalkTrackAudio
import TalkTrackDomain
@testable import TalkTrackServices

/// compact-library-storage D5–D6: journaled replacement of padded chunk files.
@Suite struct ChunkCompactionTests {
    struct Fixture {
        let folder: TemporaryFolder
        let library: OpenedLibrary
        let manifest: RecordingAudioManifest
        var recording: Recording { manifest.recording }

        func recordingFolder() throws -> DirectoryHandle {
            try DirectoryHandle.openAbsolute(library.directory).directory("Meetings")
                .directory(recording.meetingID.uuidString).directory("Recordings").directory(recording.id.uuidString)
        }

        /// Decoded samples of every chunk, through the verified playback reader.
        func decodedChunks() throws -> [[UInt32]] {
            let chunks = CommittedAudioChunks(library: library)
            let owned = try chunks.ownedDirectory()
            return try recording.chunks.map { chunk in
                var samples: [Float] = []
                try chunks.decode(chunk, of: recording, selected: 0..<chunk.decodedFrameCount, owned: owned,
                                  checkCancellation: {}, into: &samples)
                return samples.map(\.bitPattern)
            }
        }

        /// Copies of every chunk file, to compare packets with later.
        func originals() throws -> [Data] {
            try recording.chunks.map { try Data(contentsOf: library.directory.appendingPathComponent($0.file.value)) }
        }

        /// Every chunk holds the same AAC packets as its saved original. Decoded
        /// samples are not compared here: the same file decodes differently on
        /// another thread after an `await`.
        func samePackets(as originals: [Data]) throws -> Bool {
            let scratch = folder.url.appendingPathComponent("originals")
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            for (chunk, data) in zip(recording.chunks, originals) {
                let copy = scratch.appendingPathComponent("\(chunk.id).m4a")
                try data.write(to: copy)
                let left = open(copy.path, O_RDONLY)
                let right = open(library.directory.appendingPathComponent(chunk.file.value).path, O_RDONLY)
                defer { close(left); close(right) }
                try AudioChunkCompactor.verifySamePackets(original: left, compacted: right)
            }
            return true
        }

        func fileSizes() throws -> [Int] {
            try recording.chunks.map {
                try FileManager.default.attributesOfItem(atPath: library.directory.appendingPathComponent($0.file.value).path)[.size] as! Int
            }
        }

        /// Names of journal files and the marker still on disk.
        func leftovers() throws -> [String] {
            let folder = try recordingFolder()
            var names = try folder.names().filter { $0 == ChunkCompaction.marker }
            for track in AudioTrack.allCases where folder.exists(track.rawValue) {
                names += try folder.directory(track.rawValue).names().filter { $0.hasPrefix(".compact-") }
            }
            return names
        }

        /// Manifest entries agree with the receipt files.
        func manifestMatchesReceipts() throws -> Bool {
            let folder = try recordingFolder()
            let stored = try DomainCodec.decode(RecordingAudioManifest.self, from: folder.read("manifest.json", maximum: 16_777_216))
            return try stored.recording == recording && stored.audio.allSatisfy { entry in
                let receipt = try DomainCodec.decode(StoredAudioChunk.self,
                    from: folder.directory(entry.chunk.track.rawValue).read("\(entry.chunk.id).json", maximum: 65_536))
                return receipt == entry
            }
        }
    }

    static func fixture(padded: Bool = true) async throws -> Fixture {
        let folder = try TemporaryFolder()
        let library = try await OwnedLibrary().open(root: folder.url)
        let recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording, hook: nil)
        if padded { await writer.usePaddedChunks() }
        for track in AudioTrack.allCases {
            let base = track == .system ? 0.031 : 0.047
            let samples = (0..<1_009_643).map { Float(0.25 * sin(Double($0) * base) + 0.05 * sin(Double($0) * 0.0007)) }
            var offset = 0
            while offset < samples.count {
                let end = min(offset + 4800, samples.count)
                try await writer.append(track: track, samples: Array(samples[offset..<end]), activeStartFrame: UInt64(offset),
                                        hostTimeStart: 1_000_000 + UInt64(offset) * 1000)
                offset = end
            }
        }
        return Fixture(folder: folder, library: library, manifest: try await writer.finish())
    }

    @Test func paddedChunksShrinkAndPlayTheSame() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.folder.remove() }
        let originals = try fixture.originals(), sizesBefore = try fixture.fileSizes()
        let result = try ChunkCompaction.compact(recording: fixture.recordingFolder(), id: fixture.recording.id, library: fixture.library.manifest.libraryID)
        #expect(result.compacted == 6 && result.refused == 0 && result.damaged == 0 && !result.busy)
        let sizesAfter = try fixture.fileSizes()
        #expect(zip(sizesBefore, sizesAfter).allSatisfy { $0 - $1 > 32_768 })
        #expect(result.savedBytes == Int64(sizesBefore.reduce(0, +) - sizesAfter.reduce(0, +)))
        #expect(try fixture.samePackets(as: originals))
        #expect(try fixture.decodedChunks().map(\.count) == fixture.recording.chunks.map { Int($0.decodedFrameCount) })
        #expect(try fixture.manifestMatchesReceipts())
        #expect(try fixture.leftovers().isEmpty)
        // Writer recovery accepts the rewritten folder; the recording itself is unchanged.
        let recovered = try await RecordingAudioWriter.recover(library: fixture.library, meetingID: fixture.recording.meetingID,
                                                               recordingID: fixture.recording.id)
        #expect(recovered.recording.chunks == fixture.recording.chunks)
        // A second pass finds nothing to do.
        let again = try ChunkCompaction.compact(recording: fixture.recordingFolder(), id: fixture.recording.id, library: fixture.library.manifest.libraryID)
        #expect(again.compacted == 0 && again.skipped == 6)
    }

    @Test func currentChunksAreSkipped() async throws {
        let fixture = try await Self.fixture(padded: false)
        defer { fixture.folder.remove() }
        let result = try ChunkCompaction.compact(recording: fixture.recordingFolder(), id: fixture.recording.id, library: fixture.library.manifest.libraryID)
        #expect(result.compacted == 0 && result.skipped == 6)
        #expect(try fixture.leftovers().isEmpty)
    }

    struct InjectedCrash: Error {}

    @Test(arguments: CompactionStep.allCases)
    func anInterruptionAtEveryStepRecovers(step: CompactionStep) async throws {
        let fixture = try await Self.fixture()
        defer { fixture.folder.remove() }
        let originals = try fixture.originals()
        // Stop at the second chunk's step (the manifest step happens once).
        var seen = 0
        #expect(throws: InjectedCrash.self) {
            _ = try ChunkCompaction.compact(recording: fixture.recordingFolder(), id: fixture.recording.id, library: fixture.library.manifest.libraryID, hook: { observed in
                guard observed == step else { return }
                seen += 1
                if seen == (step == .manifestRewritten ? 1 : 2) { throw InjectedCrash() }
            })
        }
        #expect(try fixture.leftovers().contains(ChunkCompaction.marker))
        // Launch recovery: opening the store recovers before anything reads audio.
        let store = try await SessionStore.open(fixture.library)
        try await store.close()
        #expect(try fixture.leftovers().isEmpty)
        #expect(try fixture.manifestMatchesReceipts())
        let owned = try CommittedAudioChunks(library: fixture.library).ownedDirectory()
        for chunk in fixture.recording.chunks {
            try CommittedAudioChunks(library: fixture.library).verify(chunk, of: fixture.recording, owned: owned)
        }
        #expect(try fixture.samePackets(as: originals))
        _ = try await RecordingAudioWriter.recover(library: fixture.library, meetingID: fixture.recording.meetingID,
                                                   recordingID: fixture.recording.id)
        // The next pass finishes the rest.
        let rest = try ChunkCompaction.compact(recording: fixture.recordingFolder(), id: fixture.recording.id, library: fixture.library.manifest.libraryID)
        #expect(rest.compacted + rest.skipped == 6 && rest.refused == 0)
        #expect(try ChunkCompaction.compact(recording: fixture.recordingFolder(), id: fixture.recording.id, library: fixture.library.manifest.libraryID).compacted == 0)
        #expect(try fixture.samePackets(as: originals))
        #expect(try fixture.manifestMatchesReceipts())
    }

    @Test func writerRecoveryFinishesAnInterruptedCompaction() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.folder.remove() }
        #expect(throws: InjectedCrash.self) {
            _ = try ChunkCompaction.compact(recording: fixture.recordingFolder(), id: fixture.recording.id, library: fixture.library.manifest.libraryID, hook: { if $0 == .audioReplaced { throw InjectedCrash() } })
        }
        let recovered = try await RecordingAudioWriter.recover(library: fixture.library, meetingID: fixture.recording.meetingID,
                                                               recordingID: fixture.recording.id)
        #expect(recovered.recording.chunks == fixture.recording.chunks)
        #expect(try fixture.leftovers().isEmpty)
    }

    @Test func aHeldRecordingIsSkippedAndADamagedChunkIsLeftAlone() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.folder.remove() }
        let folder = try fixture.recordingFolder()
        do {
            let held = try #require(try RecordingFileLock.acquireIfFree(folder))
            let result = try ChunkCompaction.compact(recording: folder, id: fixture.recording.id, library: fixture.library.manifest.libraryID)
            #expect(result.busy)
            withExtendedLifetime(held) {}
        }
        // Damage one chunk: it keeps its bytes, the others are compacted.
        let damaged = fixture.recording.chunks[0]
        let path = fixture.library.directory.appendingPathComponent(damaged.file.value)
        var bytes = try Data(contentsOf: path)
        bytes[bytes.count - 50] ^= 0xFF
        try bytes.write(to: path)
        let result = try ChunkCompaction.compact(recording: try fixture.recordingFolder(), id: fixture.recording.id, library: fixture.library.manifest.libraryID)
        #expect(result.damaged == 1 && result.compacted == 5)
        #expect(try Data(contentsOf: path) == bytes)
    }

    @Test func stoppingBetweenChunksLeavesAConsistentFolder() async throws {
        let fixture = try await Self.fixture()
        defer { fixture.folder.remove() }
        var asked = 0
        let result = try ChunkCompaction.compact(recording: fixture.recordingFolder(), id: fixture.recording.id, library: fixture.library.manifest.libraryID, shouldStop: { asked += 1; return asked > 2 })
        #expect(result.stopped && result.compacted == 2)
        #expect(try fixture.leftovers().isEmpty)
        #expect(try fixture.manifestMatchesReceipts())
    }
}

