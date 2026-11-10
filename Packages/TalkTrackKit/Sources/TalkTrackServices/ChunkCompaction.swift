import CryptoKit
import Darwin
import Foundation
import TalkTrackAudio
import TalkTrackDomain

/// Steps of one chunk replacement, for fault-injection tests (D6).
enum CompactionStep: String, Sendable, CaseIterable {
    case audioWritten, receiptWritten, audioReplaced, receiptReplaced, manifestRewritten
}

/// What compacting one recording did.
public struct RecordingCompactionResult: Equatable, Sendable {
    public var compacted = 0
    /// Chunks with too little padding to remove.
    public var skipped = 0
    /// Chunks in a layout the rewrite does not handle, or whose rewrite failed verification.
    public var refused = 0
    /// Chunks whose bytes do not match their receipt; left untouched.
    public var damaged = 0
    public var savedBytes: Int64 = 0
    /// Another writer, recovery or maintenance held the recording.
    public var busy = false
    /// Stopped between chunks on request; the rest is left for later.
    public var stopped = false
    public var timings = CompactionTimings()
}

/// Where compaction time goes, summed over chunks (reports and logs).
public struct CompactionTimings: Equatable, Sendable {
    /// Recovery of leftovers and the first 4 KB of each chunk.
    public var scan: Duration = .zero
    /// Reading the whole file and checking its hash against the receipt.
    public var read: Duration = .zero
    /// Building the file without padding (memory only).
    public var rewrite: Duration = .zero
    /// Step 1: writing and fsyncing the new file.
    public var write: Duration = .zero
    /// Comparing every packet and the decoded frame count.
    public var verify: Duration = .zero
    /// Steps 2–4: receipt, both renames and their fsyncs.
    public var publish: Duration = .zero
    /// Step 5 and the `.compacted` marker.
    public var manifest: Duration = .zero

    public var total: Duration { scan + read + rewrite + write + verify + publish + manifest }

    public static func + (a: Self, b: Self) -> Self {
        Self(scan: a.scan + b.scan, read: a.read + b.read, rewrite: a.rewrite + b.rewrite, write: a.write + b.write,
             verify: a.verify + b.verify, publish: a.publish + b.publish, manifest: a.manifest + b.manifest)
    }
}

/// Journaled, lossless replacement of a recording's chunk files without their
/// `free` padding (compact-library-storage D5–D6). Every step runs under the
/// recording's `.writer.lock` through descriptor-relative I/O:
///
/// 0. `.compacting` in the recording folder marks unfinished work.
/// 1. `.compact-<id>.audio`: the rewritten file, fsynced, then verified
///    packet by packet against the original.
/// 2. `.compact-<id>.receipt`: the receipt with the new size and hash.
/// 3. The audio replaces `<id>.m4a`. 4. The receipt replaces `<id>.json`.
/// 5. `manifest.json` takes the new sizes and hashes; the marker goes.
///
/// The journal names end in neither `.m4a` nor `.json`, so code that lists
/// receipts or audio never mistakes them for chunks.
enum ChunkCompaction {
    static let marker = ".compacting"
    /// A recording a full pass found nothing more to do in.
    static let finished = ".compacted"

    static func compact(recording folder: DirectoryHandle, id recordingID: UUID, library libraryID: UUID,
                        access: RecordingAccess = .shared,
                        shouldStop: () -> Bool = { false },
                        hook: (CompactionStep) throws -> Void = { _ in }) throws -> RecordingCompactionResult {
        var result = RecordingCompactionResult()
        guard let lock = try RecordingFileLock.acquireIfFree(folder) else { result.busy = true; return result }
        return try withExtendedLifetime(lock) {
            // Every change below happens with writing access, one chunk at a
            // time; a reader that wants the recording ends the pass (D7).
            func exclusively<T>(_ body: () throws -> T) throws -> T? {
                guard access.tryWriting(recordingID, library: libraryID) else { return nil }
                defer { access.endWriting(recordingID) }
                return try body()
            }
            let clock = ContinuousClock()
            let recovering = clock.now
            guard try exclusively({ try recoverLocked(folder) }) != nil else { result.busy = true; return result }
            result.timings.scan += clock.now - recovering
            var started = false
            tracks: for track in AudioTrack.allCases where folder.exists(track.rawValue) {
                let directory = try folder.directory(track.rawValue)
                for name in try directory.names() where name.hasSuffix(".json") {
                    guard let id = UUID(uuidString: String(name.dropLast(5))), name == "\(id).json" else { continue }
                    if shouldStop() { result.stopped = true; break tracks }
                    if access.isWanted(recordingID, library: libraryID) { result.busy = true; break tracks }
                    let outcome = try exclusively { () throws -> ChunkOutcome in
                        try compactChunk(directory, id: id, name: name, track: track, folder: folder,
                                         started: &started, timings: &result.timings, hook: hook)
                    }
                    switch outcome {
                    case nil: result.busy = true; break tracks
                    case .damaged?: result.damaged += 1
                    case .skipped?: result.skipped += 1
                    case .refused?: result.refused += 1
                    case .compacted(let saved)?: result.compacted += 1; result.savedBytes += saved
                    }
                }
            }
            var settled = true
            let finishing = clock.now
            defer { result.timings.manifest += clock.now - finishing }
            if started || folder.exists(marker) {
                // Left for recovery when a reader holds the recording now.
                settled = try exclusively { () throws -> Bool in
                    try rewriteManifest(folder)
                    try hook(.manifestRewritten)
                    try folder.removeFile(marker)
                    return true
                } != nil
            }
            if settled, !result.busy, !result.stopped, !folder.exists(finished) {
                try folder.writeExclusive(finished, data: Data())
                try folder.syncAudioDirectory()
            }
            return result
        }
    }

    enum ChunkOutcome { case damaged, skipped, refused, compacted(saved: Int64) }

    /// Steps 1–4 for one chunk; the caller holds the lock and writing access.
    private static func compactChunk(_ directory: DirectoryHandle, id: UUID, name: String, track: AudioTrack,
                                     folder: DirectoryHandle, started: inout Bool, timings: inout CompactionTimings,
                                     hook: (CompactionStep) throws -> Void) throws -> ChunkOutcome {
        let clock = ContinuousClock()
        var mark = clock.now
        func lap(_ field: WritableKeyPath<CompactionTimings, Duration>) {
            let now = clock.now; timings[keyPath: field] += now - mark; mark = now
        }
        // Chunks written since the encoder change have no padding: the first
        // 4 KB tell, without reading or hashing the rest.
        let head = try? readHead(directory, "\(id).m4a")
        lap(\.scan)
        if let head, AudioChunkCompactor.paddingInHead(head) < AudioChunkCompactor.minimumSaving { return .skipped }
        guard let receipt = try? DomainCodec.decode(StoredAudioChunk.self, from: directory.read(name, maximum: 65_536)),
              receipt.chunk.id == id, receipt.chunk.track == track,
              let original = try? directory.audioFile("\(id).m4a", create: false) else {
            return .damaged
        }
        defer { close(original) }
        let data: Data
        do {
            data = try readAll(original)
            guard UInt64(data.count) == receipt.byteCount, sha256(data) == receipt.sha256 else {
                return .damaged
            }
        } catch { return .damaged }
        lap(\.read)
        let compacted: Data
        do {
            guard let rewritten = try AudioChunkCompactor.compacted(data) else { return .skipped }
            compacted = rewritten
        } catch is AudioChunkCompactor.Refusal { return .refused }
        lap(\.rewrite)

        if !started {
            if !folder.exists(marker) { try folder.writeExclusive(marker, data: Data()) }
            try folder.syncAudioDirectory()
            started = true
        }
        let pendingAudio = ".compact-\(id).audio", pendingReceipt = ".compact-\(id).receipt"
        // 1. Rewritten audio, durable, then checked against the original.
        try directory.writeExclusive(pendingAudio, data: compacted)
        lap(\.write)
        try hook(.audioWritten)
        do {
            let rewritten = try directory.audioFile(pendingAudio, create: false)
            defer { close(rewritten) }
            try AudioChunkCompactor.verifySamePackets(original: original, compacted: rewritten)
            guard try AACChunkEncoder.inspect(fileDescriptor: rewritten, expectedFrames: receipt.encoding.validFrames)
                    == receipt.encoding else {
                throw AudioChunkCompactor.Refusal(reason: "decoded frames differ")
            }
        } catch {
            try directory.removeFile(pendingAudio)
            return .refused
        }
        lap(\.verify)
        // 2. Its receipt.
        let updated = StoredAudioChunk(libraryID: receipt.libraryID, meetingID: receipt.meetingID,
            recordingID: receipt.recordingID, chunk: receipt.chunk, encoding: receipt.encoding,
            byteCount: UInt64(compacted.count), sha256: sha256(compacted))
        try directory.writeExclusive(pendingReceipt, data: DomainCodec.encode(updated))
        try directory.syncAudioDirectory()
        try hook(.receiptWritten)
        // 3–4. Audio, then receipt, each made durable.
        try replace(directory, pendingAudio, with: "\(id).m4a")
        try hook(.audioReplaced)
        try replace(directory, pendingReceipt, with: name)
        try hook(.receiptReplaced)
        lap(\.publish)
        return .compacted(saved: Int64(data.count - compacted.count))
    }

    /// Finishes or rolls back an interrupted compaction of one recording. Run
    /// before anything reads its audio. Returns false while the recording is
    /// held by someone else.
    @discardableResult
    static func recover(recording folder: DirectoryHandle) throws -> Bool {
        guard folder.exists(marker) else { return true }
        guard let lock = try RecordingFileLock.acquireIfFree(folder) else { return false }
        try withExtendedLifetime(lock) { try recoverLocked(folder) }
        return true
    }

    /// Launch: recovers every recording folder left mid-compaction, before any
    /// audio is read. Returns how many folders it recovered.
    @discardableResult
    static func recoverLibrary(_ owned: DirectoryHandle) throws -> Int {
        guard owned.exists("Meetings") else { return 0 }
        let meetings = try owned.directory("Meetings")
        var recovered = 0
        for meeting in try meetings.names() where UUID(uuidString: meeting) != nil {
            guard let meetingFolder = try? meetings.directory(meeting), meetingFolder.exists("Recordings") else { continue }
            let recordings = try meetingFolder.directory("Recordings")
            for name in try recordings.names() where UUID(uuidString: name) != nil {
                guard let folder = try? recordings.directory(name), folder.exists(marker) else { continue }
                if try recover(recording: folder) { recovered += 1 }
            }
        }
        return recovered
    }

    /// Recovery for a caller that already holds the recording's lock.
    static func recoverLocked(_ folder: DirectoryHandle) throws {
        guard folder.exists(marker) else { return }
        for track in AudioTrack.allCases where folder.exists(track.rawValue) {
            let directory = try folder.directory(track.rawValue)
            let names = try directory.names()
            for name in names where name.hasPrefix(".compact-") && name.hasSuffix(".receipt") {
                guard let id = UUID(uuidString: String(name.dropFirst(9).dropLast(8))),
                      name == ".compact-\(id).receipt" else { continue }
                let pendingAudio = ".compact-\(id).audio"
                // Replaced audio (step 3) matches the pending receipt: finish step 4.
                if let pending = try? DomainCodec.decode(StoredAudioChunk.self, from: directory.read(name, maximum: 65_536)),
                   pending.chunk.id == id, !directory.exists(pendingAudio),
                   let current = try? directory.audioFile("\(id).m4a", create: false) {
                    defer { close(current) }
                    if let integrity = try? audioIntegrity(current),
                       integrity.bytes == pending.byteCount, integrity.hash == pending.sha256 {
                        try replace(directory, name, with: "\(id).json")
                        continue
                    }
                }
                // Not replaced yet: the original and its receipt stay.
                try directory.removeFile(pendingAudio)
                try directory.removeFile(name)
            }
            for name in try directory.names() where name.hasPrefix(".compact-") && name.hasSuffix(".audio") {
                try directory.removeFile(name)
            }
        }
        try rewriteManifest(folder)
        try folder.removeFile(marker)
    }

    /// Takes the size and hash of each manifest entry from its receipt file,
    /// leaving everything else as it is.
    static func rewriteManifest(_ folder: DirectoryHandle) throws {
        guard folder.exists("manifest.json") else { return }
        var manifest = try DomainCodec.decode(RecordingAudioManifest.self, from: folder.read("manifest.json", maximum: 16_777_216))
        var changed = false
        for (index, entry) in manifest.audio.enumerated() {
            let track = entry.chunk.track
            guard folder.exists(track.rawValue),
                  let receipt = try? DomainCodec.decode(StoredAudioChunk.self,
                      from: folder.directory(track.rawValue).read("\(entry.chunk.id).json", maximum: 65_536)),
                  receipt.chunk == entry.chunk, receipt.encoding == entry.encoding,
                  receipt.byteCount != entry.byteCount || receipt.sha256 != entry.sha256 else { continue }
            manifest.audio[index] = StoredAudioChunk(libraryID: entry.libraryID, meetingID: entry.meetingID,
                recordingID: entry.recordingID, chunk: entry.chunk, encoding: entry.encoding,
                byteCount: receipt.byteCount, sha256: receipt.sha256)
            changed = true
        }
        if changed { try folder.replace("manifest.json", data: DomainCodec.encode(manifest)) }
    }

    /// `rename` over an existing name, then the folder made durable.
    private static func replace(_ directory: DirectoryHandle, _ pending: String, with name: String) throws {
        guard renameat(directory.fd, pending, directory.fd, name) == 0 else {
            throw LibraryError.io(operation: "replace \(name)", code: errno)
        }
        try directory.syncAudioDirectory()
    }

    private static func readHead(_ directory: DirectoryHandle, _ name: String) throws -> Data {
        let fd = try directory.audioFile(name, create: false)
        defer { close(fd) }
        var head = Data(count: 4096)
        let count = head.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, 4096, 0) }
        guard count > 0 else { throw LibraryError.io(operation: "read AAC audio", code: errno) }
        return head.prefix(count)
    }

    private static func readAll(_ fd: Int32) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= 2_000_000 else {
            throw LibraryError.io(operation: "read AAC audio", code: EINVAL)
        }
        var data = Data(count: Int(info.st_size)), offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: offset), remaining, off_t(offset)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw LibraryError.io(operation: "read AAC audio", code: errno) }
            offset += count
        }
        return data
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Fixture access for the SIGKILL check of `scripts/test-audio-storage-crash.sh`.
@_spi(Diagnostics) public enum ChunkCompactionDiagnostics {
    public static var steps: [String] { CompactionStep.allCases.map(\.rawValue) }

    /// Later chunks of `writer` use the earlier padded layout.
    public static func usePaddedChunks(_ writer: RecordingAudioWriter) async { await writer.usePaddedChunks() }

    static func folder(_ library: OpenedLibrary, meetingID: UUID, recordingID: UUID) throws -> DirectoryHandle {
        try DirectoryHandle.openAbsolute(library.directory).directory("Meetings").directory(meetingID.uuidString)
            .directory("Recordings").directory(recordingID.uuidString)
    }

    /// Compacts one recording, calling `reached` after each step.
    public static func compact(library: OpenedLibrary, meetingID: UUID, recordingID: UUID,
                               reached: (String) throws -> Void = { _ in }) throws -> RecordingCompactionResult {
        try ChunkCompaction.compact(recording: folder(library, meetingID: meetingID, recordingID: recordingID), id: recordingID,
                                    library: library.manifest.libraryID,
                                    hook: { try reached($0.rawValue) })
    }

    /// Journal files and the marker still in the recording folder.
    public static func leftovers(library: OpenedLibrary, meetingID: UUID, recordingID: UUID) throws -> [String] {
        let folder = try folder(library, meetingID: meetingID, recordingID: recordingID)
        var names = folder.exists(ChunkCompaction.marker) ? [ChunkCompaction.marker] : []
        for track in AudioTrack.allCases where folder.exists(track.rawValue) {
            names += try folder.directory(track.rawValue).names().filter { $0.hasPrefix(".compact-") }
        }
        return names
    }

    /// Checks every chunk against its receipt the way playback does.
    public static func verifyChunks(library: OpenedLibrary, recording: Recording) throws {
        let chunks = CommittedAudioChunks(library: library)
        let owned = try chunks.ownedDirectory()
        for chunk in recording.chunks { try chunks.verify(chunk, of: recording, owned: owned) }
    }
}
