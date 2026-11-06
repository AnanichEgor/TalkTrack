@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import TalkTrackDomain

/// What a chosen audio or video file holds (import-teams-session D1).
public struct MediaProbe: Equatable, Sendable {
    public let fileName: String
    public let duration: MediaTime
    public let hasVideo: Bool
    public let creationDate: Date?
    public let modificationDate: Date

    /// `MP4 video` / `M4A audio`.
    public var kind: String { (URL(filePath: fileName).pathExtension.uppercased()) + (hasVideo ? " video" : " audio") }
}

public enum SessionMedia {
    public static let supportedExtensions: Set<String> = ["mp4", "m4v", "mov", "m4a", "aac", "mp3", "wav", "aiff", "aif", "caf"]
    /// How much shorter than its probed length decoded audio may be.
    static let shortfallTolerance: Int64 = 1_000_000

    /// Refuses unsupported extensions before opening, then reads the audio
    /// tracks' length, protection and recording date.
    public static func probe(_ url: URL) async throws -> MediaProbe {
        let file = url.lastPathComponent
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else { throw SessionImportError.unsupportedFormat(file) }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw SessionImportError.unreadable(file) }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks: [AVAssetTrack], readable: Bool, protected: Bool
        do { (tracks, readable, protected) = try await asset.load(.tracks, .isReadable, .hasProtectedContent) }
        catch { throw SessionImportError.unreadable(file) }
        guard !protected else { throw SessionImportError.protected(file) }
        let audio = tracks.filter { $0.mediaType == .audio }
        guard readable || !audio.isEmpty else { throw SessionImportError.unreadable(file) }
        guard !audio.isEmpty else { throw SessionImportError.noAudio(file) }
        var end = 0.0
        for track in audio {
            guard let range = try? await track.load(.timeRange) else { throw SessionImportError.unreadable(file) }
            let seconds = range.end.seconds
            if seconds.isFinite { end = max(end, seconds) }
        }
        guard end > 0, let duration = try? MediaTime(seconds: end) else { throw SessionImportError.noAudio(file) }
        var created: Date?
        if let item = try? await asset.load(.creationDate) { created = try? await item.load(.dateValue) }
        return MediaProbe(fileName: file, duration: duration, hasVideo: tracks.contains { $0.mediaType == .video },
                          creationDate: created, modificationDate: modified)
    }

    /// Undecodable packets of one compressed track become silence while they
    /// stay within this share of the audio and this total; more is damage.
    static let maximumLostShare = 0.01
    static let maximumLostSeconds = 10.0

    /// Mixes every audio track to mono 48 kHz float and appends it to `writer`
    /// in bounded blocks. Returns the decoded frame count.
    ///
    /// A single compressed track is decoded packet by packet, because one bad
    /// packet (seen in a Teams MP4) makes `AVAssetReader` fail the whole file;
    /// such packets become silence of their own length, within `maximumLost*`.
    static func decode(_ url: URL, expected: MediaTime, into writer: RecordingAudioWriter,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> UInt64 {
        let file = url.lastPathComponent
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audio: [AVAssetTrack]
        do { audio = try await asset.loadTracks(withMediaType: .audio) } catch { throw SessionImportError.unreadable(file) }
        guard !audio.isEmpty else { throw SessionImportError.noAudio(file) }
        let sink = BlockSink(writer: writer, expected: expected, progress: progress)
        if audio.count == 1, let format = try? await audio[0].load(.formatDescriptions).first,
           let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
           description.mFormatID != kAudioFormatLinearPCM {
            try await decodePackets(asset: asset, track: audio[0], format: format, description: description, file: file, into: sink)
        } else {
            try await decodeMixed(asset: asset, tracks: audio, file: file, into: sink)
        }
        try Task.checkCancellation()
        try await sink.flush()
        let decoded = Int64((Double(sink.frame) / 48_000 * 1_000_000).rounded())
        guard sink.frame > 0, decoded + shortfallTolerance >= expected.microseconds else { throw SessionImportError.damaged(file) }
        return sink.frame
    }

    /// Appends 48 kHz mono samples to the writer in one-second blocks.
    final class BlockSink {
        let writer: RecordingAudioWriter
        let expectedFrames: Double
        let progress: @Sendable (Double) -> Void
        private(set) var frame: UInt64 = 0
        private var pending: [Float] = []

        init(writer: RecordingAudioWriter, expected: MediaTime, progress: @escaping @Sendable (Double) -> Void) {
            self.writer = writer; self.progress = progress
            expectedFrames = max(1.0, expected.seconds * 48_000)
            pending.reserveCapacity(48_000)
        }

        func append(_ samples: UnsafeBufferPointer<Float>) async throws { try await append(Array(samples)) }

        func append(_ samples: [Float]) async throws {
            var offset = 0
            while offset < samples.count {
                let take = min(samples.count - offset, 48_000 - pending.count)
                for value in samples[offset..<(offset + take)] { pending.append(value.isFinite ? value : 0) }
                offset += take
                if pending.count == 48_000 { try await flush() }
            }
        }

        func flush() async throws {
            guard !pending.isEmpty else { return }
            try await writer.append(track: .system, samples: pending, activeStartFrame: frame,
                                    hostTimeStart: AVAudioTime.hostTime(forSeconds: Double(frame) / 48_000))
            frame += UInt64(pending.count)
            pending.removeAll(keepingCapacity: true)
            progress(min(1, Double(frame) / expectedFrames))
        }
    }

    /// PCM files and several tracks: `AVAssetReaderAudioMixOutput` mixes and resamples.
    private static func decodeMixed(asset: AVURLAsset, tracks: [AVAssetTrack], file: String, into sink: BlockSink) async throws {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw SessionImportError.unreadable(file) }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SessionImportError.unreadable(file) }
        reader.add(output)
        guard reader.startReading() else { throw SessionImportError.damaged(file) }
        defer { if reader.status == .reading { reader.cancelReading() } }
        while true {
            try Task.checkCancellation()
            guard let buffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(buffer) }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var samples = [Float](repeating: 0, count: count)
            let status = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw SessionImportError.damaged(file) }
            try await sink.append(samples)
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw SessionImportError.damaged(file) }
    }

    /// One compressed track: packets are read undecoded and decoded one at a
    /// time; a packet the decoder refuses becomes silence. Channels are summed
    /// with equal power (as the mix output does), then resampled to 48 kHz.
    private static func decodePackets(asset: AVURLAsset, track: AVAssetTrack, format: CMAudioFormatDescription,
                                      description: AudioStreamBasicDescription, file: String, into sink: BlockSink) async throws {
        let source = AVAudioFormat(cmAudioFormatDescription: format)
        let channels = max(1, Int(source.channelCount)), rate = source.sampleRate
        guard rate > 0,
              let decoded = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false),
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let decoder = AVAudioConverter(from: source, to: decoded),
              let resampler = AVAudioConverter(from: mono, to: target)
        else { throw SessionImportError.unreadable(file) }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw SessionImportError.unreadable(file) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SessionImportError.unreadable(file) }
        reader.add(output)
        guard reader.startReading() else { throw SessionImportError.damaged(file) }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let framesPerPacket = Int(description.mFramesPerPacket > 0 ? description.mFramesPerPacket : 1024)
        let capacity = AVAudioFrameCount(max(framesPerPacket * 2, 4096))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: decoded, frameCapacity: capacity),
              let chunk = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(rate.rounded(.up)) + capacity)
        else { throw SessionImportError.unreadable(file) }
        let gain = channels == 1 ? Float(1) : 1 / Float(Double(channels).squareRoot())
        var lostFrames = 0, totalFrames = 0

        /// Resamples the collected mono chunk (or flushes the resampler at the end).
        func resample(end: Bool) async throws {
            var supplied = end
            while true {
                guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) else { throw SessionImportError.damaged(file) }
                var error: NSError?
                let status = resampler.convert(to: out, error: &error) { _, state in
                    if !supplied { supplied = true; state.pointee = .haveData; return chunk }
                    state.pointee = end ? .endOfStream : .noDataNow
                    return nil
                }
                if status == .error { throw SessionImportError.damaged(file) }
                if out.frameLength > 0, let data = out.floatChannelData {
                    try await sink.append(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
                }
                if status != .haveData { break }
            }
            chunk.frameLength = 0
        }
        func collect(_ frames: Int, from buffer: AVAudioPCMBuffer?) async throws {
            let destination = chunk.floatChannelData![0]
            let at = Int(chunk.frameLength)
            if let buffer, let data = buffer.floatChannelData {
                for index in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += data[channel][index] }
                    destination[at + index] = sum * gain
                }
            } else {
                for index in 0..<frames { destination[at + index] = 0 }
            }
            chunk.frameLength = AVAudioFrameCount(at + frames)
            totalFrames += frames
            if Double(chunk.frameLength) >= rate { try await resample(end: false) }
        }

        while true {
            try Task.checkCancellation()
            guard let buffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(buffer) }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var descriptions: UnsafePointer<AudioStreamPacketDescription>?
            var count = 0
            guard CMSampleBufferGetAudioStreamPacketDescriptionsPtr(buffer, packetDescriptionsPointerOut: &descriptions,
                                                                     sizeOut: nil) == noErr else { throw SessionImportError.damaged(file) }
            count = CMSampleBufferGetNumSamples(buffer)
            for index in 0..<count {
                let packet = descriptions.map { $0[index] }
                    ?? AudioStreamPacketDescription(mStartOffset: Int64(index * Int(description.mBytesPerPacket)), mVariableFramesInPacket: 0,
                                                    mDataByteSize: description.mBytesPerPacket)
                let size = Int(packet.mDataByteSize)
                var frames = Int(packet.mVariableFramesInPacket > 0 ? packet.mVariableFramesInPacket : UInt32(framesPerPacket))
                var ok = false
                if size > 0 {
                    let compressed = AVAudioCompressedBuffer(format: source, packetCapacity: 1, maximumPacketSize: size)
                    if CMBlockBufferCopyDataBytes(block, atOffset: Int(packet.mStartOffset), dataLength: size,
                                                  destination: compressed.data) == kCMBlockBufferNoErr {
                        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0,
                            mVariableFramesInPacket: packet.mVariableFramesInPacket, mDataByteSize: UInt32(size))
                        compressed.packetCount = 1
                        compressed.byteLength = UInt32(size)
                        pcm.frameLength = 0
                        var given = false, error: NSError?
                        let status = decoder.convert(to: pcm, error: &error) { _, state in
                            if given { state.pointee = .noDataNow; return nil }
                            given = true; state.pointee = .haveData; return compressed
                        }
                        if status != .error { ok = true; frames = Int(pcm.frameLength) }
                    }
                }
                if ok {
                    try await collect(frames, from: pcm)
                } else {
                    decoder.reset()
                    lostFrames += frames
                    try await collect(frames, from: nil)
                }
            }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw SessionImportError.damaged(file) }
        let lost = Double(lostFrames) / rate
        guard lost <= maximumLostSeconds, Double(lostFrames) <= Double(totalFrames) * maximumLostShare else {
            throw SessionImportError.damaged(file)
        }
        if chunk.frameLength > 0 { try await resample(end: false) }
        try await resample(end: true)
    }

    /// One continuous capture from `start` over `frames`, split at midnight and
    /// at time-zone offset changes like a live recording. Days reuse the ids of
    /// `existing` days of the meeting with the same date and offset, so names
    /// of that day apply to the imported recording too.
    static func timing(frames: UInt64, start: Date, timeZone identifier: String, existing: [RecordingDay]) throws -> CaptureTimingSnapshot {
        guard let zone = TimeZone(identifier: identifier), frames > 0 else { throw SessionImportError.damaged("") }
        func time(_ frame: UInt64) throws -> MediaTime { try MediaTime(seconds: Double(frame) / 48_000) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let end = start.addingTimeInterval(Double(frames) / 48_000)
        var days: [RecordingDay] = [], intervals: [CaptureInterval] = []
        var wall = start, startFrame: UInt64 = 0
        while startFrame < frames {
            let candidate = try RecordingDay(capturedAt: wall, timeZoneIdentifier: identifier)
            let match = (days + existing).first { $0.localDate == candidate.localDate && $0.timeZoneIdentifier == candidate.timeZoneIdentifier
                && $0.utcOffsetSeconds == candidate.utcOffsetSeconds }
            let day = match ?? candidate
            if !days.contains(where: { $0.id == day.id }) { days.append(day) }
            guard let dayEnd = calendar.dateInterval(of: .day, for: wall)?.end, dayEnd > wall else { throw SessionImportError.damaged("") }
            var boundary = min(dayEnd, end)
            if let transition = zone.nextDaylightSavingTimeTransition(after: wall), transition > wall { boundary = min(boundary, transition) }
            let boundaryFrame = min(frames, UInt64(max(0, (boundary.timeIntervalSince(start) * 48_000).rounded())))
            guard boundaryFrame > startFrame else { break }
            intervals.append(CaptureInterval(active: try MediaInterval(start: time(startFrame), end: time(boundaryFrame)),
                wallClockStart: wall, hostTimeStart: AVAudioTime.hostTime(forSeconds: Double(startFrame) / 48_000), dayID: day.id))
            startFrame = boundaryFrame
            wall = boundary
        }
        return CaptureTimingSnapshot(activeFrameCount: frames, activeDuration: try time(frames), days: days, intervals: intervals)
    }
}

/// One import as chosen in the import window (D6).
public struct SessionImportRequest: Sendable {
    public enum Destination: Sendable, Equatable { case newMeeting(MeetingDraft), existing(UUID) }
    public let destination: Destination
    public let media: URL
    public let transcript: TeamsTranscript?
    public let transcriptFile: URL?
    public let start: Date
    public let timeZoneIdentifier: String
    public let rememberVoices: Bool
    /// The segmentation and embedding models an imported transcript records:
    /// voice evidence from it is read with them (learning, saved voices).
    public let speakerModels: [ModelSnapshot]

    public init(destination: Destination, media: URL, transcript: TeamsTranscript? = nil, transcriptFile: URL? = nil,
                start: Date, timeZoneIdentifier: String = TimeZone.current.identifier, rememberVoices: Bool = true,
                speakerModels: [ModelSnapshot] = []) {
        self.destination = destination; self.media = media; self.transcript = transcript; self.transcriptFile = transcriptFile
        self.start = start; self.timeZoneIdentifier = timeZoneIdentifier; self.rememberVoices = rememberVoices
        self.speakerModels = speakerModels.filter { $0.role == .segmentation || $0.role == .embedding }
    }
}

public struct SessionImportResult: Equatable, Sendable {
    public let meeting: Meeting
    public let recording: Recording
    /// Day speakers named by the transcript, with their names.
    public let named: [UUID: String]
    public var hasTranscript: Bool { transcriptRevisionID != nil }
    public let transcriptRevisionID: UUID?
}

public enum SessionImporter {
    static func stagingName(_ recordingID: UUID) -> String { ".import-\(recordingID.uuidString)" }

    /// Probes, decodes into a staging folder, then publishes the meeting (when
    /// new), recording, transcript and names in one transaction and moves the
    /// folder to its final name. Cancellation and errors leave the library as it was.
    public static func run(_ request: SessionImportRequest, library: OpenedLibrary, store: SessionStore,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SessionImportResult {
        let probe = try await SessionMedia.probe(request.media)
        if let transcript = request.transcript {
            try transcript.validate(audioDuration: probe.duration, file: request.transcriptFile?.lastPathComponent ?? "transcript")
        }
        let meetingID: UUID
        var newMeeting: Meeting?
        switch request.destination {
        case .existing(let id): meetingID = try await store.meeting(id).id
        case .newMeeting(let draft):
            guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SessionImportError.missingTitle }
            let meeting = Meeting(id: UUID(), draft: draft, createdAt: Date())
            meetingID = meeting.id; newMeeting = meeting
        }
        let recording = try Recording(meetingID: meetingID, startedAt: request.start, timeZoneIdentifier: request.timeZoneIdentifier)
        let source = try request.transcriptFile.map { url -> TranscriptImportSource in
            let data = try Data(contentsOf: url)
            return TranscriptImportSource(format: url.pathExtension.lowercased(), fileName: url.lastPathComponent,
                                          sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let existingDays = newMeeting == nil ? try await store.recordings(meetingID: meetingID).flatMap(\.days) : []
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording, hook: nil,
                                                           folderName: stagingName(recording.id))
        do {
            let frames = try await SessionMedia.decode(request.media, expected: probe.duration, into: writer, progress: progress)
            let timing = try SessionMedia.timing(frames: frames, start: request.start, timeZone: request.timeZoneIdentifier, existing: existingDays)
            try await writer.closeInterval()
            try await writer.updateCaptureTiming(timing, state: .stopping)
            try await writer.recordGap(track: .microphone, active: MediaInterval(start: .zero, end: timing.activeDuration), reason: "imported")
            var stored = try await writer.finish().recording
            stored.endedAt = request.start.addingTimeInterval(timing.activeDuration.seconds)
            try Task.checkCancellation()
            let result = try await store.publishImport(stored, newMeeting: newMeeting, transcript: request.transcript, source: source,
                                                       speakerModels: request.speakerModels)
            try? await store.finishImport(meetingID: meetingID, recordingID: recording.id)
            return result
        } catch {
            _ = try? await writer.finish(interrupted: true)
            try? await store.discardImport(meetingID: meetingID, recordingID: recording.id, removeMeetingFolder: newMeeting != nil)
            if error is CancellationError { throw error }
            if let error = error as? SessionImportError { throw error }
            throw error
        }
    }
}

extension SessionStore {
    private func importRecordings(_ meetingID: UUID) throws -> DirectoryHandle? {
        let meetings = try DirectoryHandle.openAbsolute(library.directory).directory("Meetings")
        guard meetings.exists(meetingID.uuidString) else { return nil }
        let meeting = try meetings.directory(meetingID.uuidString)
        return meeting.exists("Recordings") ? try meeting.directory("Recordings") : nil
    }

    /// Commits a decoded import: the new meeting (if any), the recording, and a
    /// transcript's revision, day speakers and manual names (D2, D4).
    func publishImport(_ recording: Recording, newMeeting: Meeting?, transcript: TeamsTranscript?,
                       source: TranscriptImportSource?, speakerModels: [ModelSnapshot] = [], at date: Date = Date()) throws -> SessionImportResult {
        try db.transaction {
            if let newMeeting {
                guard try db.rows("SELECT id FROM tombstones WHERE id = ?", [.text(newMeeting.id.uuidString)]).isEmpty else { throw StoreError.missingMeeting }
                try db.execute("INSERT INTO meetings(id,payload) VALUES (?,?)", [.text(newMeeting.id.uuidString), .blob(DomainCodec.encode(newMeeting))])
            }
            var owner = try meeting(recording.meetingID)
            guard try (record(.recording, id: recording.id) as Recording?) == nil, try !isDeletedRecording(recording.id) else { throw StoreError.invalidResult }
            try put(.recording, id: recording.id, meetingID: owner.id, scope: recording.id.uuidString, value: recording)
            owner.latestRecordingStartedAt = max(owner.latestRecordingStartedAt ?? .distantPast, recording.startedAt)
            var named: [UUID: String] = [:]
            var revisionID: UUID?
            if let transcript {
                let (revision, names) = try writeImportedTranscript(transcript, recording: recording, source: source,
                                                                     models: speakerModels, at: date)
                named = names; revisionID = revision.id
            }
            owner.generation += 1
            try update(owner)
            return SessionImportResult(meeting: owner, recording: recording, named: named, transcriptRevisionID: revisionID)
        }
    }

    /// An imported transcript on a stored recording (tests; imports use publishImport).
    func importTranscript(_ transcript: TeamsTranscript, recordingID: UUID, source: TranscriptImportSource? = nil,
                          speakerModels: [ModelSnapshot] = []) throws -> SessionImportResult {
        try db.transaction {
            guard let recording: Recording = try record(.recording, id: recordingID) else { throw StoreError.invalidResult }
            let (revision, named) = try writeImportedTranscript(transcript, recording: recording, source: source, models: speakerModels, at: Date())
            var owner = try meeting(recording.meetingID)
            owner.generation += 1
            try update(owner)
            return SessionImportResult(meeting: owner, recording: recording, named: named, transcriptRevisionID: revision.id)
        }
    }

    /// Each reply is a system segment of its day; each distinct name one day
    /// speaker with a manual name whose evidence is the replies, so Reprocess
    /// names the new voices from them. A same-day speaker of the meeting with
    /// that name is reused; replies without a name go to the day's Unidentified.
    private func writeImportedTranscript(_ transcript: TeamsTranscript, recording: Recording, source: TranscriptImportSource?,
                                         models: [ModelSnapshot], at date: Date) throws -> (TranscriptRevision, [UUID: String]) {
        let meetingID = recording.meetingID
        var speakers = try daySpeakers(meetingID: meetingID)
        let assignments = try speakerAssignments(meetingID: meetingID)
        var chosen: [String: (speaker: DaySpeaker, name: String, previous: SpeakerAssignment?)] = [:]
        var unidentified: [UUID: DaySpeaker] = [:]
        var evidence: [UUID: [SpeechEvidence]] = [:]
        var segments: [TranscriptSegment] = []
        func dayID(at time: MediaTime) -> UUID {
            (recording.captureIntervals.last { $0.active.start <= time } ?? recording.captureIntervals[0]).dayID
        }
        for (reply, interval) in transcript.intervals(audioDuration: recording.activeDuration) {
            let day = dayID(at: interval.start)
            let speaker: DaySpeaker
            if let raw = reply.name {
                let name = (try? SpeakerRenameError.validatedName(raw)) ?? String(raw.prefix(80))
                let key = NamedSpeech.person(name) + "@" + day.uuidString
                if let known = chosen[key] { speaker = known.speaker } else {
                    let known = speakers
                    let previous = assignments.first { assignment in
                        guard let other = assignment.name, NamedSpeech.person(other) == NamedSpeech.person(name),
                              assignment.origin == .manual || assignment.origin == .linked else { return false }
                        return known.contains { $0.id == assignment.daySpeakerID && !$0.unidentified && $0.recordingDayIDs.contains(day) }
                    }
                    if let previous, let existing = speakers.first(where: { $0.id == previous.daySpeakerID }) {
                        chosen[key] = (existing, previous.name ?? name, previous)
                    } else {
                        chosen[key] = (try addImportSpeaker(&speakers, meetingID: meetingID, day: day, unidentified: false), name, nil)
                    }
                    speaker = chosen[key]!.speaker
                }
                evidence[speaker.id, default: []].append(SpeechEvidence(recordingID: recording.id, interval: interval))
            } else if let known = unidentified[day] { speaker = known } else {
                let existing = speakers.first { $0.unidentified && $0.recordingDayIDs.contains(day) }
                speaker = try existing ?? addImportSpeaker(&speakers, meetingID: meetingID, day: day, unidentified: true)
                unidentified[day] = speaker
            }
            let wall = recording.wallClock(at: interval.start) ?? recording.startedAt
            segments.append(TranscriptSegment(recordingID: recording.id, dayID: day, track: .system, interval: interval,
                wallClockStart: wall, speaker: .system(daySpeakerID: speaker.id), originalText: reply.text))
        }
        var named: [UUID: String] = [:]
        for (speaker, name, previous) in chosen.values {
            let assignment = SpeakerAssignment(meetingID: meetingID, dayID: speaker.dayID, daySpeakerID: speaker.id, name: name,
                origin: .manual, evidence: (previous?.evidence ?? []) + (evidence[speaker.id] ?? []), createdAt: date)
            try put(.assignment, id: assignment.id, meetingID: meetingID, scope: speaker.id.uuidString, value: assignment)
            try setHead(.assignment, meetingID: meetingID, scope: speaker.id.uuidString, id: assignment.id)
            named[speaker.id] = name
        }
        let revision = TranscriptRevision(recordingID: recording.id, sourceGeneration: recording.generation, kind: .final,
                                          segments: segments, modelRevisions: models, createdAt: date, importSource: source)
        try put(.transcript, id: revision.id, meetingID: meetingID, scope: recording.id.uuidString, value: revision)
        try setHead(.transcript, meetingID: meetingID, scope: recording.id.uuidString, id: revision.id)
        return (revision, named)
    }

    private func addImportSpeaker(_ speakers: inout [DaySpeaker], meetingID: UUID, day: UUID, unidentified: Bool) throws -> DaySpeaker {
        let number = (speakers.filter { !$0.unidentified && $0.recordingDayIDs.contains(day) }.map(\.number).max() ?? 0) + 1
        let speaker = DaySpeaker(meetingID: meetingID, dayID: day, number: unidentified ? 1 : number, unidentified: unidentified)
        try put(.daySpeaker, id: speaker.id, meetingID: meetingID, scope: day.uuidString, value: speaker)
        speakers.append(speaker)
        return speaker
    }

    /// What learning each imported name's voice needs: its manual name and the
    /// imported recording's replies (`Remember participants' voices`, D6).
    public func importedVoiceConfirmations(_ result: SessionImportResult) throws -> [VoiceEnrollmentConfirmation] {
        guard let revisionID = result.transcriptRevisionID,
              let revision = try transcript(meetingID: result.meeting.id, recordingID: result.recording.id), revision.id == revisionID,
              let recording: Recording = try record(.recording, id: result.recording.id) else { return [] }
        let assignments = try speakerAssignments(meetingID: result.meeting.id)
        return result.named.keys.sorted { (result.named[$0] ?? "", $0.uuidString) < (result.named[$1] ?? "", $1.uuidString) }.compactMap { id in
            guard let assignment = assignments.first(where: { $0.daySpeakerID == id }), assignment.origin == .manual else { return nil }
            return VoiceEnrollmentConfirmation(library: library, speakerID: id, assignment: assignment,
                                               recordings: [recording], revisions: [revision])
        }
    }

    /// After the commit: the staging folder becomes the recording's folder.
    func finishImport(meetingID: UUID, recordingID: UUID) throws {
        guard let recordings = try importRecordings(meetingID) else { return }
        let staging = SessionImporter.stagingName(recordingID), final = recordingID.uuidString
        guard recordings.exists(staging) else { return }
        if recordings.exists(final) { try recordings.removeTree(staging); return }
        guard renameatx_np(recordings.fd, staging, recordings.fd, final, UInt32(RENAME_EXCL)) == 0 else {
            throw LibraryError.io(operation: "finish the imported recording folder", code: errno)
        }
        try recordings.syncAudioDirectory()
    }

    /// A refused or cancelled import: its staging folder, and the folder of a
    /// new meeting that was never committed.
    func discardImport(meetingID: UUID, recordingID: UUID, removeMeetingFolder: Bool) throws {
        if let recordings = try importRecordings(meetingID) {
            try recordings.removeTree(SessionImporter.stagingName(recordingID))
            try recordings.syncAudioDirectory()
        }
        if removeMeetingFolder { try removeEmptyMeetingFolder(meetingID) }
    }

    private func removeEmptyMeetingFolder(_ meetingID: UUID) throws {
        guard try db.rows("SELECT id FROM meetings WHERE id = ?", [.text(meetingID.uuidString)]).isEmpty else { return }
        let meetings = try DirectoryHandle.openAbsolute(library.directory).directory("Meetings")
        let name = meetingID.uuidString
        guard meetings.exists(name) else { return }
        let folder = try meetings.directory(name)
        let entries = try folder.names()
        guard entries.allSatisfy({ $0 == "Recordings" }) else { return }
        if entries.contains("Recordings"), try !folder.directory("Recordings").names().isEmpty { return }
        try meetings.removeTree(name)
        try meetings.syncAudioDirectory()
    }

    /// Launch: a committed import whose folder was not renamed is finished;
    /// any other staging folder, and a new meeting's empty folder, is removed.
    func recoverImports() throws {
        let owned = try DirectoryHandle.openAbsolute(library.directory)
        guard owned.exists("Meetings") else { return }
        let meetings = try owned.directory("Meetings")
        for meeting in try meetings.names() {
            guard let meetingID = UUID(uuidString: meeting), let folder = try? meetings.directory(meeting),
                  folder.exists("Recordings"), let recordings = try? folder.directory("Recordings") else { continue }
            var removed = false
            for name in try recordings.names() where name.hasPrefix(".import-") {
                guard let id = UUID(uuidString: String(name.dropFirst(8))), name == SessionImporter.stagingName(id) else { continue }
                if let stored: Recording = try record(.recording, id: id), stored.meetingID == meetingID {
                    try? finishImport(meetingID: meetingID, recordingID: id)
                } else {
                    try? recordings.removeTree(name); removed = true
                }
            }
            if removed { try? recordings.syncAudioDirectory(); try? removeEmptyMeetingFolder(meetingID) }
        }
    }
}
