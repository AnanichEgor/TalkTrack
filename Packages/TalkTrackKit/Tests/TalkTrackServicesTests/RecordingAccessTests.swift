import Darwin
import Foundation
import Testing
import TalkTrackAudio
import TalkTrackDomain
@testable import TalkTrackServices

/// compact-library-storage D7: chunk readers and folder operations against compaction.
@Suite struct RecordingAccessTests {
    /// Every place that reads receipts, opens chunk files or removes or clones
    /// recording folders, with how it is kept apart from compaction. A new
    /// entry fails here until it is reviewed and listed.
    static let audited: [String: String] = [
        "ChunkCompaction.swift": "the compactor: writing access per chunk, .writer.lock",
        "CommittedAudioChunks.swift": "reading access around receipt + open (player, window reader, voice learning, sample preview, echo replay)",
        "RecordingAudioWriter.swift": ".writer.lock: capture and writer recovery exclude compaction",
        "RecordingMove.swift": "reading access in relocateRecordingFolder; launch reconcile runs before compaction starts",
        "RecordingSplit.swift": "reading access in splitRecording; launch recoverSplits runs before compaction starts",
        "SessionStore.swift": "reading access for recording delete; library-wide reading for meeting delete",
        "SessionImport.swift": "only `.import-` staging folders, which compaction never visits",
        "LibraryMigration.swift": "library-wide reading access while copying and verifying",
        "ModelDownloadFiles.swift": "model folders, not recordings",
        "ModelCleanup.swift": "the Models folder cleanup, not recordings",
        "OwnedLibrary.swift": "DirectoryHandle itself",
    ]

    @Test func everyChunkFileEntryPointIsAudited() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TalkTrackServices")
        let pattern = ["StoredAudioChunk.self", "audioFile(", "cloneFile(", "removeTree(", "renameat"]
        var found: Set<String> = []
        for name in try FileManager.default.contentsOfDirectory(atPath: sources.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            if pattern.contains(where: text.contains) { found.insert(name) }
        }
        #expect(found.subtracting(Self.audited.keys).isEmpty, "unaudited: \(found.subtracting(Self.audited.keys).sorted())")
        let gated = ["CommittedAudioChunks.swift", "RecordingMove.swift", "RecordingSplit.swift", "SessionStore.swift", "LibraryMigration.swift"]
        for name in gated {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            #expect(text.contains("RecordingAccess.shared."), "\(name) takes no access")
        }
    }

    @Test func aReaderWaitsForOneChunkAndWritingNeverWaits() async throws {
        let access = RecordingAccess(), id = UUID(), lib = UUID()
        #expect(access.tryWriting(id, library: lib))
        #expect(!access.tryWriting(id, library: lib))
        let entered = AccessFlag()
        let reader = Thread { access.reading(id) { entered.set() } }
        reader.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!entered.value)
        #expect(access.isWanted(id, library: lib))
        access.endWriting(id)
        for _ in 0..<100 where !entered.value { try await Task.sleep(for: .milliseconds(10)) }
        #expect(entered.value)
        // While someone reads, writing is refused at once.
        let release = DispatchSemaphore(value: 0), holding = AccessFlag()
        Thread { access.reading(id) { holding.set(); release.wait() } }.start()
        for _ in 0..<100 where !holding.value { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!access.tryWriting(id, library: lib))
        let other = UUID()
        #expect(access.tryWriting(other, library: lib))
        access.endWriting(other)
        release.signal()
        try await Task.sleep(for: .milliseconds(50))
        #expect(access.tryWriting(id, library: lib))
        access.endWriting(id)
        // Library-wide reading blocks every recording of that library only.
        access.readingLibrary(lib) { #expect(!access.tryWriting(UUID(), library: lib)) }
        access.readingLibrary(UUID()) { #expect(access.tryWriting(id, library: lib)) }
        access.endWriting(id)
    }

    @Test func playbackReadsDuringCompactionAfterTheCurrentChunk() async throws {
        let fixture = try await ChunkCompactionTests.fixture()
        defer { fixture.folder.remove() }
        let paused = AccessFlag(), resume = DispatchSemaphore(value: 0)
        let result = AccessBox<RecordingCompactionResult>()
        let folder = try fixture.recordingFolder(), id = fixture.recording.id, libraryID = fixture.library.manifest.libraryID
        Thread {
            var first = true
            result.value = try? ChunkCompaction.compact(recording: folder, id: id, library: libraryID, hook: { step in
                guard step == .receiptWritten, first else { return }
                first = false
                paused.set(); resume.wait()
            })
        }.start()
        for _ in 0..<500 where !paused.value { try await Task.sleep(for: .milliseconds(10)) }
        // The player verifies chunks now; it waits for the chunk being replaced.
        let verified = AccessFlag()
        let library = fixture.library, recording = fixture.recording
        Thread {
            let chunks = CommittedAudioChunks(library: library)
            if let owned = try? chunks.ownedDirectory(),
               (try? recording.chunks.forEach { try chunks.verify($0, of: recording, owned: owned) }) != nil { verified.set() }
        }.start()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!verified.value)
        resume.signal()
        for _ in 0..<300 where !verified.value || result.value == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(verified.value)
        // Compaction finished that chunk and gave the recording up to the reader.
        #expect(result.value?.compacted == 1 && result.value?.busy == true)
        #expect(try fixture.manifestMatchesReceipts() || fixture.leftovers() == [ChunkCompaction.marker])
        // The next pass completes it.
        let rest = try ChunkCompaction.compact(recording: fixture.recordingFolder(), id: id, library: fixture.library.manifest.libraryID)
        #expect(rest.compacted == 5 && !rest.busy)
        #expect(try fixture.leftovers().isEmpty && fixture.manifestMatchesReceipts())
    }
}

final class AccessFlag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

final class AccessBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: T?
    var value: T? { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
