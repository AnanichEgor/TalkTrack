import CryptoKit
import Darwin
import Dispatch
import Foundation
import TalkTrackAudio
import TalkTrackDomain

/// Decoder-relative trims are zero: AudioToolbox already removes AAC priming
/// and padding. Raw packet accounting is retained separately for other readers.
public struct StoredAudioChunk: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let meetingID: UUID
    public let recordingID: UUID
    public let chunk: TrackChunk
    public let encoding: AACPacketInfo
    public let byteCount: UInt64
    public let sha256: String
}

public struct RecordingAudioManifest: Codable, Equatable, Sendable {
    public var recording: Recording
    public var audio: [StoredAudioChunk]
}

// Test/standalone crash fixture boundaries. Hooks are absent in normal use.
enum AudioCommitPoint: String, Sendable { case audioSynced, receiptSynced, audioPublished, manifestPublished }

private final class RecordingIOExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "local.talktrack.recording-storage", qos: .userInitiated)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

private final class RecordingFileLock {
    let fd: Int32
    init(directory: DirectoryHandle, create: Bool) throws {
        let opened = try directory.audioFile(".writer.lock", create: create)
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(opened)
            throw LibraryError.io(operation: "access recording audio; another writer or recovery is active", code: code)
        }
        fd = opened
    }
    deinit { close(fd) }
}

/// Independent chunk encoders and durable receipts on a dedicated worker.
/// This service consumes normalized 48 kHz mono audio and caller-supplied active
/// frame offsets. Capture/resampling, interval mapping and SQLite publication
/// are separate owners. Never invoke it from a hardware callback or enqueue an
/// unbounded Task per packet: the integration must use bounded worker handoff.
public actor RecordingAudioWriter {
    private nonisolated let executor = RecordingIOExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let library: OpenedLibrary
    private var manifest: RecordingAudioManifest
    private var directory: DirectoryHandle?
    private var fileLock: RecordingFileLock?
    private var tracks: [AudioTrack: DirectoryHandle] = [:]
    private var openChunks: [AudioTrack: OpenChunk] = [:]
    private var nextFrame: [AudioTrack: UInt64] = [:]
    private var stopped = false
    private var failure: String?
    private let commitHook: (@Sendable (AudioCommitPoint) throws -> Void)?

    private final class OpenChunk {
        let id = UUID()
        let fd: Int32
        let encoder: AACChunkEncoder
        let startFrame: UInt64
        let hostTime: UInt64
        var temporaryName: String { ".pending-\(id.uuidString).m4a" }
        init(directory: DirectoryHandle, startFrame: UInt64, hostTime: UInt64) throws {
            self.startFrame = startFrame; self.hostTime = hostTime
            let name = ".pending-\(id.uuidString).m4a"
            fd = try directory.audioFile(name, create: true)
            do { encoder = try AACChunkEncoder(fileDescriptor: fd) }
            catch { close(fd); throw error }
        }
        deinit { encoder.abort(); close(fd) }
    }

    private init(library: OpenedLibrary, recording: Recording,
                 hook: (@Sendable (AudioCommitPoint) throws -> Void)? = nil) {
        self.library = library
        manifest = RecordingAudioManifest(recording: recording, audio: [])
        commitHook = hook
    }

    public static func create(library: OpenedLibrary, recording: Recording) async throws -> RecordingAudioWriter {
        try await create(library: library, recording: recording, hook: nil)
    }

    static func create(library: OpenedLibrary, recording: Recording,
                       hook: (@Sendable (AudioCommitPoint) throws -> Void)?) async throws -> RecordingAudioWriter {
        guard recording.chunks.isEmpty, recording.activeDuration == .zero,
              recording.state == .preparing else { throw audioStorageError("A new recording is required") }
        let writer = RecordingAudioWriter(library: library, recording: recording, hook: hook)
        try await writer.prepare()
        return writer
    }

    private func prepare() throws {
        let owned = try openOwnedDirectory()
        let meetings = try owned.directory("Meetings")
        let meeting = try meetings.createDirectory(manifest.recording.meetingID.uuidString)
        let recordings = try meeting.createDirectory("Recordings")
        let name = manifest.recording.id.uuidString
        guard mkdirat(recordings.fd, name, 0o700) == 0 else {
            throw LibraryError.io(operation: "create a new recording folder", code: errno)
        }
        directory = try recordings.directory(name)
        fileLock = try RecordingFileLock(directory: directory!, create: true)
        for track in AudioTrack.allCases { tracks[track] = try directory!.createDirectory(track.rawValue) }
        try saveManifest()
        // Persist all newly-created parent links, not just the recording leaf.
        for handle in [directory!, recordings, meeting, meetings, owned] { try handle.syncAudioDirectory() }
    }

    /// At most one second of PCM per call. Offsets must be contiguous until
    /// closeInterval(); a deliberate gap thereafter retains its absolute offset.
    public func append(track: AudioTrack, samples: [Float], activeStartFrame: UInt64,
                       hostTimeStart: UInt64) throws {
        guard !stopped, failure == nil else { throw audioStorageError(failure ?? "Recording audio is closed") }
        guard !samples.isEmpty, samples.count <= 48_000, samples.allSatisfy(\.isFinite),
              activeStartFrame <= UInt64(Int64.max / 1_000_000) * 48_000,
              activeStartFrame.addingReportingOverflow(UInt64(samples.count)).overflow == false,
              nextFrame[track].map({ $0 == activeStartFrame }) ?? true else {
            throw audioStorageError("Invalid PCM or discontinuous active frame offset; close the interval before a gap")
        }
        if let last = manifest.audio.last(where: { $0.chunk.track == track }),
           try frameTime(activeStartFrame) < last.chunk.active.end {
            throw audioStorageError("Audio would overlap an already committed chunk")
        }
        let range = try MediaInterval(start: frameTime(activeStartFrame), end: frameTime(activeStartFrame + UInt64(samples.count)))
        guard manifest.recording.captureIntervals.isEmpty || range.end <= manifest.recording.activeDuration else {
            throw audioStorageError("Publish capture timing before committing audio beyond the current checkpoint")
        }
        guard !manifest.recording.trackIntervals.contains(where: {
            if case .gap = $0.content {
                return $0.track == track && range.start < $0.active.end && $0.active.start < range.end
            }
            return false
        }) else { throw audioStorageError("Audio would overwrite an explicit capture gap") }
        do {
            var offset = 0
            while offset < samples.count {
                if openChunks[track] == nil {
                    let anchor = try addingHostFrames(hostTimeStart, frames: UInt64(offset))
                    openChunks[track] = try OpenChunk(directory: tracks[track]!,
                        startFrame: activeStartFrame + UInt64(offset), hostTime: anchor)
                }
                let current = openChunks[track]!
                let count = min(samples.count - offset, Int(AACChunkEncoder.maximumFrames - current.encoder.frames))
                try current.encoder.append(samples[offset..<(offset + count)])
                offset += count
                nextFrame[track] = activeStartFrame + UInt64(offset)
                if current.encoder.frames == AACChunkEncoder.maximumFrames { try commit(track) }
            }
        } catch { failure = error.localizedDescription; throw error }
    }

    /// Flush both sources before a pause/route boundary. The timing owner may
    /// resume at a later active offset, but cannot overwrite committed audio.
    public func closeInterval() throws {
        guard !stopped, failure == nil else { throw audioStorageError(failure ?? "Recording audio is closed") }
        do {
            for track in AudioTrack.allCases { try commit(track) }
            nextFrame = [:]
        } catch { failure = error.localizedDescription; throw error }
    }

    /// Publish the common capture clock before audio reaching this checkpoint
    /// is committed. Recovery keeps these anchors even when a source has no
    /// samples, rather than deriving meeting duration from the longer file.
    public func updateCaptureTiming(_ timing: CaptureTimingSnapshot, state: RecordingState) throws {
        guard !stopped, failure == nil,
              [.recording, .paused, .stopping].contains(state),
              timing.activeDuration >= manifest.recording.activeDuration else {
            throw audioStorageError("Invalid or backwards capture timing checkpoint")
        }
        let old = manifest.recording.captureIntervals
        guard timing.intervals.count >= old.count else { throw audioStorageError("Capture anchors cannot be removed") }
        for (i, interval) in old.enumerated() {
            let next = timing.intervals[i]
            guard next.active.start == interval.active.start, next.active.end >= interval.active.end,
                  next.wallClockStart == interval.wallClockStart, next.hostTimeStart == interval.hostTimeStart,
                  next.dayID == interval.dayID,
                  i == old.count - 1 || next.active.end == interval.active.end else {
                throw audioStorageError("Committed capture anchors cannot be changed")
            }
        }
        var recording = manifest.recording
        recording.activeDuration = timing.activeDuration
        recording.captureIntervals = timing.intervals
        recording.days = timing.days
        recording.state = state
        _ = try MeetingTimeline(meetingID: recording.meetingID, recordings: [recording])
        manifest.recording = recording
        do { try saveManifest() } catch { failure = error.localizedDescription; throw error }
    }

    /// A lost source keeps its absolute active range. Flush only that source;
    /// the other encoder continues and its position is never shifted.
    public func recordGap(track: AudioTrack, active: MediaInterval, reason: String) throws {
        guard !stopped, failure == nil, active.duration > .zero,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              manifest.recording.captureIntervals.isEmpty || active.end <= manifest.recording.activeDuration else {
            throw audioStorageError("Invalid capture gap")
        }
        func overlaps(_ other: MediaInterval) -> Bool { active.start < other.end && other.start < active.end }
        guard !manifest.recording.trackIntervals.contains(where: { $0.track == track && overlaps($0.active) }),
              nextFrame[track].map({ (try? frameTime($0)).map { $0 <= active.start } ?? false }) ?? true else {
            throw audioStorageError("A capture gap would overwrite accepted audio")
        }
        do {
            try commit(track)
            manifest.recording.trackIntervals.append(TrackInterval(track: track, active: active, content: .gap(reason: reason)))
            manifest.recording.activeDuration = max(manifest.recording.activeDuration, active.end)
            nextFrame[track] = nil
            try saveManifest()
        } catch { failure = error.localizedDescription; throw error }
    }

    /// Flush the remaining independently decodable chunks. A failed source
    /// cannot prevent attempting to preserve the other source's accepted audio.
    public func finish(interrupted: Bool = false) throws -> RecordingAudioManifest {
        if stopped {
            if let failure { throw audioStorageError(failure) }
            return manifest
        }
        var firstError: Error?
        for track in AudioTrack.allCases {
            do { try commit(track) } catch { if firstError == nil { firstError = error } }
        }
        manifest.recording.state = interrupted || failure != nil || firstError != nil ? .interrupted : .complete
        stopped = true
        defer { fileLock = nil }
        do { try saveManifest() } catch { if firstError == nil { firstError = error } }
        if let firstError { failure = firstError.localizedDescription; throw firstError }
        if let failure { throw audioStorageError(failure) }
        return manifest
    }

    public func snapshot() -> RecordingAudioManifest { manifest }

    private func commit(_ track: AudioTrack) throws {
        guard let current = openChunks.removeValue(forKey: track) else { return }
        let target = tracks[track]!
        let encoding = try current.encoder.finish()
        guard fsync(current.fd) == 0 else { throw LibraryError.io(operation: "sync AAC audio", code: errno) }
        try commitHook?(.audioSynced)
        let prefix = "Meetings/\(manifest.recording.meetingID)/Recordings/\(manifest.recording.id)"
        let chunk = try TrackChunk(id: current.id, track: track,
            file: RelativePath("\(prefix)/\(track.rawValue)/\(current.id).m4a"),
            active: MediaInterval(start: frameTime(current.startFrame), end: frameTime(current.startFrame + encoding.validFrames)),
            sampleRate: AACChunkEncoder.sampleRate, decodedFrameCount: encoding.validFrames,
            leadingTrimFrames: 0, trailingTrimFrames: 0, hostTimeStart: current.hostTime)
        let integrity = try audioIntegrity(current.fd)
        let receipt = StoredAudioChunk(libraryID: library.manifest.libraryID, meetingID: manifest.recording.meetingID,
            recordingID: manifest.recording.id, chunk: chunk, encoding: encoding,
            byteCount: integrity.bytes, sha256: integrity.hash)
        // A durable receipt precedes the rename: recovery can finish publication
        // if termination occurs before the audio name or global manifest changes.
        try target.writeExclusive("\(current.id).json", data: DomainCodec.encode(receipt))
        try target.syncAudioDirectory()
        try commitHook?(.receiptSynced)
        try target.publishAudio(current.temporaryName, as: "\(current.id).m4a")
        try commitHook?(.audioPublished)
        manifest.audio.append(receipt)
        rebuildRecording()
        try saveManifest()
        try commitHook?(.manifestPublished)
    }

    private func saveManifest() throws { try directory!.replace("manifest.json", data: DomainCodec.encode(manifest)) }

    private func rebuildRecording() {
        manifest.audio.sort { a, b in
            if a.chunk.active.start != b.chunk.active.start { return a.chunk.active.start < b.chunk.active.start }
            return a.chunk.file.value < b.chunk.file.value
        }
        manifest.recording.chunks = manifest.audio.map(\.chunk)
        let gaps = manifest.recording.trackIntervals.filter { if case .gap = $0.content { true } else { false } }
        manifest.recording.trackIntervals = gaps + manifest.audio.map {
            TrackInterval(track: $0.chunk.track, active: $0.chunk.active,
                content: .chunk(id: $0.chunk.id, firstDecodedFrame: 0, frameCount: $0.encoding.validFrames))
        }
        manifest.recording.activeDuration = max(manifest.recording.activeDuration,
            manifest.audio.map(\.chunk.active.end).max() ?? .zero)
    }

    /// Run only after capture has stopped / on relaunch, with no live writer for
    /// this recording. Missing or damaged committed audio produces a visible
    /// error and is preserved. Only receipt-less, owned pending files are removed.
    public static func recover(library: OpenedLibrary, meetingID: UUID, recordingID: UUID) async throws -> RecordingAudioManifest {
        let empty = try Recording(id: recordingID, meetingID: meetingID, timeZoneIdentifier: "UTC")
        let worker = RecordingAudioWriter(library: library, recording: empty)
        return try await worker.recoverOnWorker()
    }

    /// Recording folders present on disk for a meeting, including folders a
    /// crash left without a library record. Unrecognized names are ignored.
    public static func storedRecordingIDs(library: OpenedLibrary, meetingID: UUID) async throws -> [UUID] {
        let empty = try Recording(meetingID: meetingID, timeZoneIdentifier: "UTC")
        return try await RecordingAudioWriter(library: library, recording: empty).listOnWorker()
    }

    /// Removes a finished recording folder that holds no audio receipt, such as
    /// one whose capture never started. Audio, even uncommitted, is never removed.
    public static func discardEmpty(library: OpenedLibrary, meetingID: UUID, recordingID: UUID) async throws {
        let empty = try Recording(id: recordingID, meetingID: meetingID, timeZoneIdentifier: "UTC")
        try await RecordingAudioWriter(library: library, recording: empty).discardOnWorker()
    }

    private func listOnWorker() throws -> [UUID] {
        let meeting = try openOwnedDirectory().directory("Meetings").directory(manifest.recording.meetingID.uuidString)
        guard meeting.exists("Recordings") else { return [] }
        return try meeting.directory("Recordings").audioNames().compactMap { name in
            UUID(uuidString: name).flatMap { $0.uuidString == name ? $0 : nil }
        }.sorted { $0.uuidString < $1.uuidString }
    }

    private func discardOnWorker() throws {
        let recordings = try openOwnedDirectory().directory("Meetings")
            .directory(manifest.recording.meetingID.uuidString).directory("Recordings")
        let name = manifest.recording.id.uuidString
        let folder = try recordings.directory(name)
        do {
            let lock = try RecordingFileLock(directory: folder, create: false)
            let stored = try DomainCodec.decode(RecordingAudioManifest.self, from: folder.read("manifest.json", maximum: 16_777_216))
            guard stored.recording.id == manifest.recording.id, stored.audio.isEmpty else {
                throw audioStorageError("The recording folder contains audio and was kept")
            }
            for track in AudioTrack.allCases where folder.exists(track.rawValue) {
                guard try folder.directory(track.rawValue).audioNames().isEmpty else {
                    throw audioStorageError("The recording folder contains audio and was kept")
                }
            }
            _ = lock
        }
        try recordings.removeTree(name)
        try recordings.syncAudioDirectory()
    }

    private func recoverOnWorker() throws -> RecordingAudioManifest {
        let owned = try openOwnedDirectory()
        let recordings = try owned.directory("Meetings").directory(manifest.recording.meetingID.uuidString).directory("Recordings")
        directory = try recordings.directory(manifest.recording.id.uuidString)
        fileLock = try RecordingFileLock(directory: directory!, create: false)
        defer { fileLock = nil }
        let original = try DomainCodec.decode(RecordingAudioManifest.self, from: directory!.read("manifest.json", maximum: 16_777_216))
        guard original.recording.id == manifest.recording.id, original.recording.meetingID == manifest.recording.meetingID else {
            throw audioStorageError("Recording manifest identity mismatch")
        }
        manifest = original
        var recovered: [StoredAudioChunk] = []
        for track in AudioTrack.allCases {
            let target = try directory!.directory(track.rawValue)
            tracks[track] = target
            let names = try target.audioNames()
            let receipts = names.filter { $0.hasSuffix(".json") }.sorted()
            var ids: Set<UUID> = []
            for name in receipts {
                guard let id = UUID(uuidString: String(name.dropLast(5))), name == "\(id).json" else {
                    throw audioStorageError("Unrecognized audio receipt: \(name)")
                }
                let receipt = try DomainCodec.decode(StoredAudioChunk.self, from: target.read(name, maximum: 65_536))
                try validateReceipt(receipt, id: id, track: track)
                ids.insert(id)
                let finalName = "\(id).m4a", pendingName = ".pending-\(id).m4a"
                let published = target.exists(finalName)
                let fd = try target.audioFile(published ? finalName : pendingName, create: false)
                defer { close(fd) }
                let integrity = try audioIntegrity(fd)
                guard integrity.bytes == receipt.byteCount, integrity.hash == receipt.sha256,
                      try AACChunkEncoder.inspect(fileDescriptor: fd, expectedFrames: receipt.encoding.validFrames) == receipt.encoding else {
                    throw audioStorageError("Completed audio is damaged: \(receipt.chunk.file.value)")
                }
                if !published { try target.publishAudio(pendingName, as: finalName) }
                recovered.append(receipt)
            }
            for name in names where name.hasSuffix(".m4a") {
                if name.hasPrefix(".pending-"), let id = UUID(uuidString: String(name.dropFirst(9).dropLast(4))),
                   name == ".pending-\(id).m4a", !ids.contains(id) {
                    // Current uncommitted chunk; never remove a final name or
                    // an arbitrary entry. Completed receipts above survive.
                    try target.removeFile(name)
                } else if !name.hasPrefix(".pending-") {
                    guard let id = UUID(uuidString: String(name.dropLast(4))), ids.contains(id) else {
                        throw audioStorageError("Completed audio has no recovery receipt: \(name)")
                    }
                }
            }
        }
        // A corrupt/missing receipt must not silently erase a manifest reference.
        guard original.audio.allSatisfy({ recovered.contains($0) }) else {
            throw audioStorageError("A committed audio receipt is missing or changed")
        }
        for track in AudioTrack.allCases {
            let chunks = recovered.filter { $0.chunk.track == track }.sorted { $0.chunk.active.start < $1.chunk.active.start }
            for pair in zip(chunks, chunks.dropFirst()) where pair.0.chunk.active.end > pair.1.chunk.active.start {
                throw audioStorageError("Recovered audio chunks overlap")
            }
        }
        manifest.audio = recovered
        rebuildRecording()
        _ = try MeetingTimeline(meetingID: manifest.recording.meetingID, recordings: [manifest.recording])
        if original.recording.state != .complete { manifest.recording.state = .interrupted }
        stopped = true
        try saveManifest()
        return manifest
    }

    private func openOwnedDirectory() throws -> DirectoryHandle {
        let owned = try DirectoryHandle.openAbsolute(library.directory)
        let marker = try JSONDecoder().decode(LibraryManifest.self, from: owned.read("manifest.json", maximum: 65_536))
        guard marker == library.manifest else { throw LibraryError.wrongIdentity }
        return owned
    }

    private func validateReceipt(_ receipt: StoredAudioChunk, id: UUID, track: AudioTrack) throws {
        let chunk = receipt.chunk
        let expectedPath = "Meetings/\(manifest.recording.meetingID)/Recordings/\(manifest.recording.id)/\(track.rawValue)/\(id).m4a"
        guard receipt.libraryID == library.manifest.libraryID, receipt.meetingID == manifest.recording.meetingID,
              receipt.recordingID == manifest.recording.id, chunk.id == id, chunk.track == track,
              chunk.file.value == expectedPath, chunk.sampleRate == AACChunkEncoder.sampleRate,
              chunk.leadingTrimFrames == 0, chunk.trailingTrimFrames == 0,
              chunk.decodedFrameCount == receipt.encoding.validFrames,
              chunk.decodedFrameCount > 0, chunk.decodedFrameCount <= AACChunkEncoder.maximumFrames,
              abs(chunk.active.duration.seconds - Double(chunk.decodedFrameCount) / 48_000) <= 0.000001,
              receipt.byteCount > 0, receipt.sha256.count == 64 else {
            throw audioStorageError("Audio receipt identity, timing or codec metadata is invalid")
        }
    }
}

private func audioStorageError(_ message: String) -> ServiceError {
    ServiceError(message: message, recovery: "Stop recording and check disk space and session folder access. Preserve the recording folder for recovery.")
}
private func frameTime(_ frame: UInt64) throws -> MediaTime { try MediaTime(seconds: Double(frame) / 48_000) }
private func addingHostFrames(_ anchor: UInt64, frames: UInt64) throws -> UInt64 {
    var base = mach_timebase_info_data_t()
    guard mach_timebase_info(&base) == KERN_SUCCESS, base.numer > 0 else { throw audioStorageError("Host clock is unavailable") }
    let delta = (Double(frames) / 48_000 * 1_000_000_000 * Double(base.denom) / Double(base.numer)).rounded()
    guard delta < Double(UInt64.max), !anchor.addingReportingOverflow(UInt64(delta)).overflow else {
        throw audioStorageError("Host clock anchor overflow")
    }
    return anchor + UInt64(delta)
}
func audioIntegrity(_ fd: Int32, checkCancellation: () throws -> Void = {}) throws -> (bytes: UInt64, hash: String) {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_size > 0, info.st_size <= 2_000_000 else {
        throw audioStorageError("Invalid or oversized AAC file")
    }
    var hash = SHA256(), offset: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while offset < info.st_size {
        try checkCancellation()
        let requested = min(buffer.count, Int(info.st_size - offset))
        let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, requested, off_t(offset)) }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw LibraryError.io(operation: "verify AAC bytes", code: errno) }
        hash.update(data: Data(buffer.prefix(count)))
        offset += Int64(count)
    }
    return (UInt64(info.st_size), hash.finalize().map { String(format: "%02x", $0) }.joined())
}

extension DirectoryHandle {
    func audioFile(_ name: String, create: Bool) throws -> Int32 {
        let flags = create ? O_RDWR | O_CREAT | O_EXCL : O_RDONLY
        let file = openat(fd, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw LibraryError.io(operation: "open audio \(name)", code: errno) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            close(file); throw LibraryError.unsafePath(name)
        }
        return file
    }
    func syncAudioDirectory() throws {
        guard fsync(fd) == 0 else { throw LibraryError.io(operation: "sync audio directory", code: errno) }
    }
    func publishAudio(_ pending: String, as name: String) throws {
        guard renameatx_np(fd, pending, fd, name, UInt32(RENAME_EXCL)) == 0 else {
            throw LibraryError.io(operation: "publish AAC audio", code: errno)
        }
        try syncAudioDirectory()
    }
    func audioNames() throws -> [String] {
        guard let stream = fdopendir(dup(fd)) else { throw LibraryError.io(operation: "list audio", code: errno) }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }
}
