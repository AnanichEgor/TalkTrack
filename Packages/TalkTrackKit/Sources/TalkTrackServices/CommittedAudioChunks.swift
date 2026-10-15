import Darwin
import Foundation
import TalkTrackAudio
import TalkTrackDomain

/// Verified decoding of committed AAC chunks, shared by processing and
/// playback: the receipt, byte count and hash must match before any sample is
/// used, and all I/O stays relative to the owned library directory.
struct CommittedAudioChunks {
    let library: OpenedLibrary

    func ownedDirectory() throws -> DirectoryHandle {
        let owned = try DirectoryHandle.openAbsolute(library.directory)
        let marker = try JSONDecoder().decode(LibraryManifest.self, from: owned.read("manifest.json", maximum: 65_536))
        guard marker == library.manifest else { throw LibraryError.wrongIdentity }
        return owned
    }

    /// Checks that a chunk's receipt, byte count and hash match, without
    /// decoding it.
    func verify(_ chunk: TrackChunk, of recording: Recording, owned: DirectoryHandle,
                checkCancellation: () throws -> Void = {}) throws {
        let (fd, _) = try open(chunk, of: recording, owned: owned, checkCancellation: checkCancellation)
        Darwin.close(fd)
    }

    /// Opens a chunk whose receipt and integrity match.
    private func open(_ chunk: TrackChunk, of recording: Recording, owned: DirectoryHandle,
                      checkCancellation: () throws -> Void) throws -> (Int32, StoredAudioChunk) {
        let track = chunk.track
        let prefix = "Meetings/\(recording.meetingID)/Recordings/\(recording.id)/\(track.rawValue)"
        guard chunk.file.value == "\(prefix)/\(chunk.id).m4a" else {
            throw AudioWindowReadError.invalidMetadata(recording.id)
        }
        let folder = try owned.directory("Meetings").directory(recording.meetingID.uuidString)
            .directory("Recordings").directory(recording.id.uuidString).directory(track.rawValue)
        let receipt = try DomainCodec.decode(StoredAudioChunk.self, from: folder.read("\(chunk.id).json", maximum: 65_536))
        guard receipt.libraryID == library.manifest.libraryID, receipt.meetingID == recording.meetingID,
              receipt.recordingID == recording.id, receipt.chunk == chunk, receipt.encoding.validFrames == chunk.decodedFrameCount else {
            throw AudioWindowReadError.damagedChunk(recordingID: recording.id, chunkID: chunk.id)
        }
        let fd = try folder.audioFile("\(chunk.id).m4a", create: false)
        do {
            let integrity = try audioIntegrity(fd, checkCancellation: checkCancellation)
            guard integrity.bytes == receipt.byteCount, integrity.hash == receipt.sha256 else {
                throw AudioWindowReadError.damagedChunk(recordingID: recording.id, chunkID: chunk.id)
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
        return (fd, receipt)
    }

    /// Appends the decoded frames `selected` (raw decoded coordinates,
    /// including any persisted trim) of `chunk`.
    func decode(_ chunk: TrackChunk, of recording: Recording, selected: Range<UInt64>, owned: DirectoryHandle,
                checkCancellation: () throws -> Void, into samples: inout [Float]) throws {
        let (fd, receipt) = try open(chunk, of: recording, owned: owned, checkCancellation: checkCancellation)
        defer { Darwin.close(fd) }
        var decoded: UInt64 = 0
        let encoding = try AACChunkEncoder.decode(fileDescriptor: fd, expectedFrames: chunk.decodedFrameCount) { buffer in
            try checkCancellation()
            let end = decoded + UInt64(buffer.count)
            let first = max(decoded, selected.lowerBound), last = min(end, selected.upperBound)
            if first < last {
                samples.append(contentsOf: UnsafeBufferPointer(rebasing: buffer[Int(first - decoded)..<Int(last - decoded)]))
            }
            decoded = end
        }
        guard encoding == receipt.encoding else { throw AudioWindowReadError.damagedChunk(recordingID: recording.id, chunkID: chunk.id) }
    }
}
