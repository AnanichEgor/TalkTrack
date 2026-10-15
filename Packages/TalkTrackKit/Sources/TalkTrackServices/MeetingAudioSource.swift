import Dispatch
import Foundation
import TalkTrackAudio
import TalkTrackDomain

public enum PlaybackError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedAudio(recordingID: UUID)
    case unreadableAudio(recordingID: UUID, track: AudioTrack, at: MediaTime, detail: String)
    case outputUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAudio: "This recording uses an audio format the player cannot read."
        case let .unreadableAudio(_, track, at, _):
            "The \(track == .system ? "system audio" : "microphone") file at \(MeetingPlaybackClock.text(at)) cannot be read."
        case let .outputUnavailable(detail): "Audio output is unavailable: \(detail)"
        }
    }
    public var recoverySuggestion: String? {
        switch self {
        case .outputUnavailable: "Check the selected output device, then press Play again."
        default: "The transcript is still available. Restore the meeting's recording files, then play again."
        }
    }
}

public enum MeetingPlaybackClock {
    /// "m:ss", or "h:mm:ss" from one hour.
    public static func text(_ time: MediaTime) -> String {
        let value = Int(time.microseconds / 1_000_000)
        let hours = value / 3_600, minutes = value / 60 % 60, rest = value % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// A stretch of the timeline whose stored audio is missing or does not match
/// its receipt. The timeline keeps its length; playback stops on reaching it.
public struct DamagedAudio: Equatable, Sendable {
    public let recordingID: UUID
    public let track: AudioTrack
    /// Global timeline interval.
    public let interval: MediaInterval
}

/// One contiguous range of the virtual timeline, never crossing a recording
/// boundary. Both tracks cover exactly the same frames; explicit gaps are silence.
public struct PlaybackBlock: Sendable {
    public let recordingID: UUID
    public let globalStartFrame: UInt64
    public let system: [Float]
    public let microphone: [Float]
    public var frameCount: Int { system.count }
}

private final class PlaybackSourceExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "local.talktrack.playback-source", qos: .userInitiated)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

/// Reads a meeting's recordings in timeline order as 48 kHz blocks on a
/// dedicated executor. Source files are never joined: each block is decoded
/// from the verified committed chunks with their encoder trims excluded, and the
/// current chunk of each track stays decoded so the next block (and the next
/// chunk, read ahead by the player) never waits on the file system.
public actor MeetingAudioSource {
    public static let sampleRate: UInt32 = 48_000

    private struct Part: Sendable {
        let frames: Range<UInt64>
        /// Nil for an explicit gap.
        let chunk: TrackChunk?
        let firstDecodedFrame: UInt64
    }
    private struct Entry: Sendable {
        let recording: Recording
        let globalStart: UInt64
        let frames: UInt64
        let tracks: [AudioTrack: [Part]]
    }

    private nonisolated let executor = PlaybackSourceExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    public nonisolated let timeline: MeetingTimeline
    public nonisolated let totalFrames: UInt64
    private nonisolated let entries: [Entry]
    private let chunks: CommittedAudioChunks
    private var owned: DirectoryHandle?
    private var cursor: UInt64 = 0
    private var decoded: [AudioTrack: (id: UUID, samples: [Float])] = [:]

    public init(library: OpenedLibrary, meetingID: UUID, recordings: [Recording]) throws {
        timeline = try MeetingTimeline(meetingID: meetingID, recordings: recordings)
        let byID = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
        var entries: [Entry] = [], start: UInt64 = 0
        for item in timeline.recordings {
            let recording = byID[item.recordingID]!
            let frames = try PlaybackFrames.frame(recording.activeDuration)
            var tracks: [AudioTrack: [Part]] = [:]
            let chunkByID = Dictionary(uniqueKeysWithValues: recording.chunks.map { ($0.id, $0) })
            for track in AudioTrack.allCases {
                tracks[track] = try timeline.trackIntervals(recordingID: recording.id, track: track).map { interval in
                    let lower = try PlaybackFrames.frame(interval.active.start), upper = try PlaybackFrames.frame(interval.active.end)
                    switch interval.content {
                    case .gap: return Part(frames: lower..<upper, chunk: nil, firstDecodedFrame: 0)
                    case let .chunk(id, first, count):
                        let chunk = chunkByID[id]!
                        guard chunk.sampleRate == Self.sampleRate, chunk.decodedFrameCount <= AACChunkEncoder.maximumFrames,
                              count == upper - lower else { throw PlaybackError.unsupportedAudio(recordingID: recording.id) }
                        return Part(frames: lower..<upper, chunk: chunk, firstDecodedFrame: first)
                    }
                }
            }
            entries.append(Entry(recording: recording, globalStart: start, frames: frames, tracks: tracks))
            start += frames
        }
        self.entries = entries
        totalFrames = start
        chunks = CommittedAudioChunks(library: library)
    }

    /// Exact source time of a global frame: recordings start on whole frames.
    public nonisolated func time(atFrame frame: UInt64) -> MediaTime {
        guard frame < totalFrames, let entry = entry(containing: frame) else { return timeline.totalDuration }
        let local = (try? PlaybackFrames.time(frame - entry.globalStart)) ?? .zero
        return (try? timeline.globalTime(recordingID: entry.recording.id, activeTime: min(local, entry.recording.activeDuration))) ?? timeline.totalDuration
    }

    /// The global frame of a timeline position. An exact recording boundary
    /// belongs to the next recording, as in `MeetingTimeline`.
    public nonisolated func frame(at time: MediaTime) throws -> UInt64 {
        switch try timeline.position(at: time) {
        case .empty, .end: return totalFrames
        case let .recording(position):
            let entry = entries.first { $0.recording.id == position.recordingID }!
            return entry.globalStart + min(entry.frames, try PlaybackFrames.frame(position.activeTime))
        }
    }

    public nonisolated func recordingID(atFrame frame: UInt64) -> UUID? { entry(containing: frame)?.recording.id }

    public func seek(toFrame frame: UInt64) { cursor = min(frame, totalFrames) }

    /// Nil at the end of the meeting. A failure leaves the cursor in place.
    public func next(maximumFrames: Int = 48_000) throws -> PlaybackBlock? {
        guard maximumFrames > 0, cursor < totalFrames, let entry = entry(containing: cursor) else { return nil }
        let local = cursor - entry.globalStart
        let count = min(UInt64(maximumFrames), entry.frames - local)
        let range = local..<(local + count)
        let system = try samples(.system, range, in: entry)
        let microphone = try samples(.microphone, range, in: entry)
        let block = PlaybackBlock(recordingID: entry.recording.id, globalStartFrame: cursor, system: system, microphone: microphone)
        cursor += count
        return block
    }

    /// Verifies every chunk's receipt, size and hash without decoding, and
    /// returns the unreadable stretches per recording and track, adjacent
    /// chunks merged. Cancellation returns what was found so far.
    public func damagedAudio(isCancelled: @Sendable () -> Bool = { false }) -> [DamagedAudio] {
        var result: [DamagedAudio] = []
        let owned: DirectoryHandle
        do { owned = try self.owned ?? chunks.ownedDirectory() } catch {
            // The library itself is unreadable: every recording is affected.
            return entries.flatMap { entry in
                AudioTrack.allCases.compactMap { track in
                    damage(entry, track, entry.globalStart..<(entry.globalStart + entry.frames))
                }
            }
        }
        for entry in entries {
            for track in AudioTrack.allCases {
                var open: Range<UInt64>?
                for part in entry.tracks[track]! {
                    guard !isCancelled() else { return result }
                    guard let chunk = part.chunk else { continue }
                    let global = (entry.globalStart + part.frames.lowerBound)..<(entry.globalStart + part.frames.upperBound)
                    if (try? chunks.verify(chunk, of: entry.recording, owned: owned)) != nil {
                        if let range = open, let item = damage(entry, track, range) { result.append(item) }
                        open = nil
                    } else if let range = open, range.upperBound >= global.lowerBound {
                        open = range.lowerBound..<global.upperBound
                    } else {
                        if let range = open, let item = damage(entry, track, range) { result.append(item) }
                        open = global
                    }
                }
                if let range = open, let item = damage(entry, track, range) { result.append(item) }
            }
        }
        return result.sorted { $0.interval.start < $1.interval.start }
    }

    private nonisolated func damage(_ entry: Entry, _ track: AudioTrack, _ frames: Range<UInt64>) -> DamagedAudio? {
        guard let start = try? PlaybackFrames.time(frames.lowerBound - entry.globalStart),
              let end = try? PlaybackFrames.time(frames.upperBound - entry.globalStart),
              let globalStart = try? timeline.globalTime(recordingID: entry.recording.id, activeTime: min(start, entry.recording.activeDuration)),
              let globalEnd = try? timeline.globalTime(recordingID: entry.recording.id, activeTime: min(end, entry.recording.activeDuration)),
              let interval = try? MediaInterval(start: globalStart, end: globalEnd) else { return nil }
        return DamagedAudio(recordingID: entry.recording.id, track: track, interval: interval)
    }

    private nonisolated func entry(containing frame: UInt64) -> Entry? {
        var low = 0, high = entries.count
        while low < high {
            let mid = low + (high - low) / 2
            if entries[mid].globalStart + entries[mid].frames <= frame { low = mid + 1 } else { high = mid }
        }
        return low < entries.count ? entries[low] : nil
    }

    private func samples(_ track: AudioTrack, _ range: Range<UInt64>, in entry: Entry) throws -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(Int(range.count))
        for part in entry.tracks[track]! where part.frames.lowerBound < range.upperBound && range.lowerBound < part.frames.upperBound {
            let start = max(range.lowerBound, part.frames.lowerBound), end = min(range.upperBound, part.frames.upperBound)
            guard let chunk = part.chunk else {
                output.append(contentsOf: repeatElement(0, count: Int(end - start)))
                continue
            }
            let source = try decodedSamples(chunk, of: entry, at: start)
            let first = Int(part.firstDecodedFrame + start - part.frames.lowerBound)
            output.append(contentsOf: source[first..<(first + Int(end - start))])
        }
        guard output.count == range.count else { throw PlaybackError.unsupportedAudio(recordingID: entry.recording.id) }
        return output
    }

    private func decodedSamples(_ chunk: TrackChunk, of entry: Entry, at local: UInt64) throws -> [Float] {
        if let cached = decoded[chunk.track], cached.id == chunk.id { return cached.samples }
        do {
            let owned = try self.owned ?? chunks.ownedDirectory()
            self.owned = owned
            var samples: [Float] = []
            samples.reserveCapacity(Int(chunk.decodedFrameCount))
            try chunks.decode(chunk, of: entry.recording, selected: 0..<chunk.decodedFrameCount, owned: owned,
                              checkCancellation: {}, into: &samples)
            guard samples.count == Int(chunk.decodedFrameCount) else { throw AudioWindowReadError.damagedChunk(recordingID: entry.recording.id, chunkID: chunk.id) }
            decoded[chunk.track] = (chunk.id, samples)
            return samples
        } catch {
            owned = nil
            let at = (try? timeline.globalTime(recordingID: entry.recording.id, activeTime: PlaybackFrames.time(local))) ?? .zero
            throw PlaybackError.unreadableAudio(recordingID: entry.recording.id, track: chunk.track, at: at,
                                                detail: error.localizedDescription)
        }
    }
}

enum PlaybackFrames {
    /// Nearest 48 kHz frame of a source time.
    static func frame(_ time: MediaTime) throws -> UInt64 {
        let value = UInt64(time.microseconds), seconds = value / 1_000_000
        guard seconds <= UInt64.max / 48_000 else { throw TimelineError.durationOverflow }
        return seconds * 48_000 + ((value % 1_000_000) * 48_000 + 500_000) / 1_000_000
    }
    static func time(_ frame: UInt64) throws -> MediaTime {
        let seconds = frame / 48_000, fraction = ((frame % 48_000) * 1_000_000 + 24_000) / 48_000
        guard seconds <= UInt64(Int64.max) / 1_000_000 - 1 else { throw TimelineError.durationOverflow }
        return try MediaTime(microseconds: Int64(seconds * 1_000_000 + fraction))
    }
}
