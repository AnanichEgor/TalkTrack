@preconcurrency import AVFoundation
import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// Generated media for import tests (import-teams-session tasks 2.1–2.2).
enum ImportMedia {
    static func tone(_ frame: Int, rate: Double, frequency: Double, amplitude: Float = 0.3) -> Float {
        amplitude * Float(sin(2 * .pi * frequency * Double(frame) / rate))
    }

    /// WAV, AIFF or CAF PCM, or M4A AAC, through AVAudioFile.
    static func audioFile(_ url: URL, seconds: Double, rate: Double = 44_100, channels: Int = 1, aac: Bool = false,
                          frequency: Double = 440) throws {
        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
        if aac { settings[AVFormatIDKey] = kAudioFormatMPEG4AAC; settings[AVEncoderBitRateKey] = 96_000 }
        else { settings[AVFormatIDKey] = kAudioFormatLinearPCM; settings[AVLinearPCMBitDepthKey] = 16; settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = url.pathExtension == "aiff"; settings[AVLinearPCMIsNonInterleaved] = false }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<channels {
            for i in 0..<frames { buffer.floatChannelData![channel][i] = tone(i, rate: rate, frequency: frequency) }
        }
        try file.write(from: buffer)
    }

    /// MP4/MOV through AVAssetWriter: one AAC track per frequency, and optionally H.264 video.
    static func movie(_ url: URL, type: AVFileType, seconds: Double, tones: [Double], video: Bool = false, fastStart: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        writer.shouldOptimizeForNetworkUse = fastStart
        let rate = 48_000.0
        let audioInputs = tones.map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        }
        for input in audioInputs { input.expectsMediaDataInRealTime = false; writer.add(input) }
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if video {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        }
        guard writer.startWriting() else { throw writer.error ?? CancellationError() }
        writer.startSession(atSourceTime: .zero)
        var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        let total = Int(seconds * rate), block = 4_800
        for (index, input) in audioInputs.enumerated() {
            var offset = 0
            while offset < total {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                let count = min(block, total - offset)
                var samples = (offset..<(offset + count)).map { tone($0, rate: rate, frequency: tones[index]) }
                var blockBuffer: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 4, blockAllocator: nil,
                    customBlockSource: nil, offsetToData: 0, dataLength: count * 4, flags: 0, blockBufferOut: &blockBuffer)
                samples.withUnsafeMutableBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer!, offsetIntoDestination: 0, dataLength: count * 4) }
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: blockBuffer!, formatDescription: description!,
                    sampleCount: count, presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(rate)),
                    packetDescriptions: nil, sampleBufferOut: &sample)
                input.append(sample!)
                offset += count
            }
            input.markAsFinished()
        }
        if let adaptor {
            let frames = Int(seconds * 10)
            for i in 0..<frames {
                while !adaptor.assetWriterInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                var pixel: CVPixelBuffer?
                CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixel)
                adaptor.append(pixel!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
            }
            adaptor.assetWriterInput.markAsFinished()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CancellationError() }
    }

}

@Suite struct SessionImportAudioTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "import-audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func open() async throws -> (OpenedLibrary, SessionStore) {
        let folder = root.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let library = try await OwnedLibrary().open(root: folder)
        return (library, try await SessionStore.open(library))
    }

    func media(_ name: String) -> URL { root.appending(path: name) }

    /// The stored system track of `recording`, at 48 kHz.
    static func storedSystem(_ library: OpenedLibrary, _ recording: Recording) async throws -> [Float] {
        let source = try MeetingAudioSource(library: library, meetingID: recording.meetingID, recordings: [recording])
        var samples: [Float] = []
        while let block = try await source.next() {
            samples += block.system
            #expect(block.microphone.allSatisfy { $0 == 0 })
        }
        return samples
    }

    static func correlation(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>) -> Double {
        var ab = 0.0, aa = 0.0, bb = 0.0
        for (x, y) in zip(a, b) { ab += Double(x * y); aa += Double(x * x); bb += Double(y * y) }
        return ab / max(1e-12, (aa * bb).squareRoot())
    }

    static func rms(_ a: ArraySlice<Float>) -> Double {
        (a.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, a.count))).squareRoot()
    }

    func importFile(_ url: URL, transcript: TeamsTranscript? = nil, into store: SessionStore, library: OpenedLibrary,
                    start: Date = Date(timeIntervalSince1970: 1_793_000_000)) async throws -> SessionImportResult {
        try await SessionImporter.run(SessionImportRequest(destination: .newMeeting(MeetingDraft(title: "Imported", description: "")),
            media: url, transcript: transcript, start: start, timeZoneIdentifier: "UTC"), library: library, store: store)
    }

    @Test func wavM4AAndMP3AreDecodedToTheirLength() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, store) = try await open()
        let wav = media("call.wav"), m4a = media("call.m4a"), aiff = media("call.aiff"), mp3 = media("tone.mp3")
        try ImportMedia.audioFile(wav, seconds: 12.5, rate: 48_000)
        try ImportMedia.audioFile(m4a, seconds: 4, rate: 44_100, channels: 2, aac: true)
        try ImportMedia.audioFile(aiff, seconds: 2, rate: 16_000)
        try #require(Data(base64Encoded: ImportMediaMP3.base64)).write(to: mp3)

        let fromWAV = try await importFile(wav, into: store, library: library)
        #expect(abs(fromWAV.recording.activeDuration.seconds - 12.5) < 0.001)
        #expect(fromWAV.recording.state == .complete && fromWAV.recording.chunks.count == 2)
        #expect(fromWAV.recording.trackIntervals.contains { $0.track == .microphone && $0.content == .gap(reason: "imported") })
        let stored = try await Self.storedSystem(library, fromWAV.recording)
        #expect(stored.count == 600_000)
        let source = (0..<600_000).map { ImportMedia.tone($0, rate: 48_000, frequency: 440) }
        #expect(Self.correlation(stored[48_000..<540_000], source[48_000..<540_000]) > 0.99)

        for (url, seconds, amplitude) in [(m4a, 4.0, 0.3 * 2.squareRoot()), (aiff, 2.0, 0.3), (mp3, 2.0, 0.125)] {
            let result = try await importFile(url, into: store, library: library)
            #expect(abs(result.recording.activeDuration.seconds - seconds) < 0.15, "\(url.lastPathComponent) \(result.recording.activeDuration.seconds)")
            let samples = try await Self.storedSystem(library, result.recording)
            let middle = samples[(samples.count / 4)..<(samples.count * 3 / 4)]
            // The 440 Hz tone survives resampling and both codecs (ffmpeg’s tone is at 1/8; the stereo M4A downmix is equal-power, so √2 louder).
            #expect(abs(Self.rms(middle) - amplitude / 2.squareRoot()) < 0.03, "\(url.lastPathComponent) \(Self.rms(middle))")
        }
        #expect(try await store.meetings().count == 4)
    }

    @Test func twoAudioTracksAreMixedAndVideoIsDropped() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, store) = try await open()
        let mov = media("call.mov")
        try await ImportMedia.movie(mov, type: .mov, seconds: 3, tones: [300, 700], video: true)
        let probe = try await SessionMedia.probe(mov)
        #expect(probe.hasVideo && probe.kind == "MOV video")
        let result = try await importFile(mov, into: store, library: library)
        let samples = try await Self.storedSystem(library, result.recording)
        #expect(abs(Double(samples.count) - 144_000) < 4_800)
        let middle = Array(samples[48_000..<96_000])
        let a = (48_000..<96_000).map { ImportMedia.tone($0, rate: 48_000, frequency: 300) }
        let b = (48_000..<96_000).map { ImportMedia.tone($0, rate: 48_000, frequency: 700) }
        // Both tones are present: the mix correlates with each of them.
        #expect(Self.correlation(middle[...], a[...]) > 0.3 && Self.correlation(middle[...], b[...]) > 0.3)
        let folder = library.directory.appending(path: "Meetings/\(result.meeting.id)/Recordings/\(result.recording.id)")
        let files = try FileManager.default.subpathsOfDirectory(atPath: folder.path)
        #expect(files.allSatisfy { !$0.hasSuffix(".mov") && !$0.hasSuffix(".mp4") })
        #expect(files.contains { $0.hasPrefix("system/") && $0.hasSuffix(".m4a") })
    }

    @Test func unsupportedSilentAndDamagedFilesAreRefusedWithoutChanges() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, store) = try await open()
        let webm = media("call.webm")
        try Data("not really".utf8).write(to: webm)
        await #expect(throws: SessionImportError.unsupportedFormat("call.webm")) { try await importFile(webm, into: store, library: library) }

        let silent = media("screen.mp4")
        try await ImportMedia.movie(silent, type: .mp4, seconds: 1, tones: [], video: true)
        await #expect(throws: SessionImportError.noAudio("screen.mp4")) { try await importFile(silent, into: store, library: library) }

        let garbage = media("noise.mp4")
        try Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 * 7) }).write(to: garbage)
        await #expect(throws: SessionImportError.unreadable("noise.mp4")) { try await importFile(garbage, into: store, library: library) }

        let full = media("full.mp4"), cut = media("cut.mp4")
        try await ImportMedia.movie(full, type: .mp4, seconds: 20, tones: [440], fastStart: true)
        let data = try Data(contentsOf: full)
        try data.prefix(data.count / 2).write(to: cut)
        await #expect(throws: SessionImportError.damaged("cut.mp4")) { try await importFile(cut, into: store, library: library) }

        #expect(try await store.meetings().isEmpty)
        let meetings = library.directory.appending(path: "Meetings")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: meetings.path)) ?? [] == [])
    }

    /// Copies the AAC packets of `source` into `target` without re-encoding,
    /// replacing the listed packets with 1100-byte ones. A mono AAC packet may
    /// hold at most 768 bytes; the decoder refuses larger ones (the bad packet
    /// of the real Teams MP4 was 1078 bytes).
    static func oversize(_ source: URL, to target: URL, packets: Set<Int>) async throws {
        let asset = AVURLAsset(url: source)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let format = try #require(try await track.load(.formatDescriptions).first)
        let rate = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee.mSampleRate
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        let writer = try AVAssetWriter(outputURL: target, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var index = 0
        while let buffer = output.copyNextSampleBuffer() {
            var descriptions: UnsafePointer<AudioStreamPacketDescription>?
            CMSampleBufferGetAudioStreamPacketDescriptionsPtr(buffer, packetDescriptionsPointerOut: &descriptions, sizeOut: nil)
            guard let block = CMSampleBufferGetDataBuffer(buffer), let descriptions else { continue }
            for packet in 0..<CMSampleBufferGetNumSamples(buffer) {
                defer { index += 1 }
                let description = descriptions[packet]
                var bytes = Data(count: Int(description.mDataByteSize))
                _ = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: Int(description.mStartOffset), dataLength: $0.count, destination: $0.baseAddress!) }
                if packets.contains(index) { bytes = Data(repeating: 0xFF, count: 1100) }
                var data: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &data)
                _ = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data!, offsetIntoDestination: 0, dataLength: $0.count) }
                var one = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count))
                var sample: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: data!, formatDescription: format, sampleCount: 1,
                    presentationTimeStamp: CMTime(value: CMTimeValue(index * 1024), timescale: CMTimeScale(rate)),
                    packetDescriptions: &one, sampleBufferOut: &sample)
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                #expect(input.append(try #require(sample)))
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    /// One bad packet (as in a real Teams MP4) stops `AVAssetReader` decoding;
    /// the import keeps the rest with silence in its place. Wide damage is refused.
    @Test func aBadPacketBecomesSilenceButWideDamageIsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, store) = try await open()
        let clean = media("clean.mp4"), bad = media("teams.mp4"), worse = media("worse.mp4")
        try await ImportMedia.movie(clean, type: .mp4, seconds: 20, tones: [440])
        try await Self.oversize(clean, to: bad, packets: [180])
        try await Self.oversize(clean, to: worse, packets: Set(stride(from: 20, to: 900, by: 3)))

        // The whole-file reader gives up at the bad packet.
        let asset = AVURLAsset(url: bad)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: try await asset.loadTracks(withMediaType: .audio),
                                                 audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        reader.startReading()
        while output.copyNextSampleBuffer() != nil {}
        #expect(reader.status == .failed)

        let result = try await importFile(bad, into: store, library: library)
        #expect(abs(result.recording.activeDuration.seconds - 20) < 0.15)
        let samples = try await Self.storedSystem(library, result.recording)
        // The tone continues after the damage (the length above shows nothing was dropped);
        // the copied packets have no encoder-delay edit, so compare level, not phase.
        let late = samples[(samples.count * 3 / 4)..<(samples.count * 3 / 4 + 48_000)]
        #expect(abs(Self.rms(late) - 0.3 / 2.squareRoot()) < 0.03)

        await #expect(throws: SessionImportError.damaged("worse.mp4")) { try await importFile(worse, into: store, library: library) }
        #expect(try await store.meetings().count == 1)
    }

    @Test func cancellingLeavesTheLibraryUnchanged() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (library, store) = try await open()
        let existing = try await store.createMeeting(MeetingDraft(title: "Existing", description: ""))
        let wav = media("long.wav")
        try ImportMedia.audioFile(wav, seconds: 120, rate: 48_000)
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            try await SessionImporter.run(SessionImportRequest(destination: .existing(existing.id), media: wav,
                start: Date(), timeZoneIdentifier: "UTC"), library: library, store: store) { fraction in
                if fraction > 0.1 { started.continuation.yield() }
            }
        }
        for await _ in started.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.recordings(meetingID: existing.id).isEmpty)
        let recordings = library.directory.appending(path: "Meetings/\(existing.id)/Recordings")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? []).isEmpty)
    }

    @Test func relaunchRemovesAnInterruptedImportAndFinishesAnInterruptedRename() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var (library, store) = try await open()
        let wav = media("call.wav")
        try ImportMedia.audioFile(wav, seconds: 3, rate: 48_000)

        // A crash while decoding: a staged folder, no record, a new meeting's folder.
        let orphanMeeting = UUID(), orphanRecording = UUID()
        let staging = library.directory.appending(path: "Meetings/\(orphanMeeting)/Recordings/.import-\(orphanRecording)/system")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staging.appending(path: ".pending-x.m4a"))

        // A crash after the commit, before the rename.
        let result = try await importFile(wav, into: store, library: library)
        let recordings = library.directory.appending(path: "Meetings/\(result.meeting.id)/Recordings")
        try FileManager.default.moveItem(at: recordings.appending(path: result.recording.id.uuidString),
                                         to: recordings.appending(path: ".import-\(result.recording.id)"))
        try await store.close()

        (library, store) = try await open()
        #expect(!FileManager.default.fileExists(atPath: library.directory.appending(path: "Meetings/\(orphanMeeting)").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: recordings.path) == [result.recording.id.uuidString])
        #expect(try await RecordingAudioWriter.storedRecordingIDs(library: library, meetingID: result.meeting.id) == [result.recording.id])
        let samples = try await Self.storedSystem(library, try #require(try await store.recordings(meetingID: result.meeting.id).first))
        #expect(samples.count == 144_000)
    }

    @Test func storedAudioKeepsItsDecodedLengthWithoutAShortfall() throws {
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        // 23:59:30 to 00:00:30 UTC crosses midnight into two days.
        let late = Date(timeIntervalSince1970: 1_793_059_170)
        let one = try SessionMedia.timing(frames: 48_000 * 60, start: start, timeZone: "UTC", existing: [])
        #expect(one.intervals.count == 1 && one.days.count == 1 && one.activeDuration.seconds == 60)
        let two = try SessionMedia.timing(frames: 48_000 * 60, start: late, timeZone: "UTC", existing: [])
        #expect(two.intervals.count == 2 && two.days.count == 2)
        #expect(two.intervals[0].active.end.seconds == 30 && two.intervals[1].wallClockStart == late.addingTimeInterval(30))
        let reused = try SessionMedia.timing(frames: 48_000, start: start, timeZone: "UTC", existing: one.days)
        #expect(reused.days == one.days)
    }
}

/// A real out-of-space error while the import writes audio. It attaches a disk
/// image, so it runs only with TALKTRACK_VOLUME_FIXTURES=1.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TALKTRACK_VOLUME_FIXTURES"] == "1"))
struct SessionImportVolumeTests {
    static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    @Test func fullDiskDuringImportLeavesTheLibraryUnchanged() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "import-full-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appending(path: "full.dmg"), mount = folder.appending(path: "volume", directoryHint: .isDirectory)
        try Self.hdiutil(["create", "-size", "12m", "-fs", "APFS", "-volname", "ImportFull", "-type", "UDIF", image.path])
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.hdiutil(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer { try? Self.hdiutil(["detach", "-force", mount.path]) }

        let root = mount.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = try await OwnedLibrary().open(root: root)
        let store = try await SessionStore.open(library)
        let existing = try await store.createMeeting(MeetingDraft(title: "Existing", description: ""))
        // Leave about 400 KB: far less than 10 minutes of audio (~4.8 MB).
        let filler = mount.appending(path: "filler")
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        let handle = try FileHandle(forWritingTo: filler)
        while let free = try? URL(filePath: mount.path).resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
              free > 400_000 {
            guard (try? handle.write(contentsOf: Data(count: min(256_000, free - 400_000)))) != nil else { break }
            try handle.synchronize()
        }
        try handle.close()

        let wav = folder.appending(path: "long.wav")
        try ImportMedia.audioFile(wav, seconds: 600, rate: 16_000)
        do {
            _ = try await SessionImporter.run(SessionImportRequest(destination: .newMeeting(MeetingDraft(title: "New", description: "")),
                media: wav, start: Date(), timeZoneIdentifier: "UTC"), library: library, store: store)
            Issue.record("The import fitted on the full volume")
        } catch {
            // The writer's own error: errno 28 (ENOSPC) or the encoder's out-of-space status.
            let text = "\(error) \(error.localizedDescription)"
            #expect(text.contains("28") || text.lowercased().contains("space") || text.contains("dfl!"), "\(text)")
        }
        #expect(try await store.meetings().map(\.id) == [existing.id])
        let meetings = library.directory.appending(path: "Meetings")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: meetings.path)) ?? []).allSatisfy { $0 == existing.id.uuidString })
        try FileManager.default.removeItem(at: filler)
        try await store.close()
    }
}

/// The imported transcript, names and Reprocess (task 2.3).
@Suite struct SessionImportTranscriptTests {
    static func vtt(_ cues: [(String?, Double, Double, String)]) throws -> TeamsTranscript {
        func stamp(_ s: Double) -> String { String(format: "00:%02d:%06.3f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60)) }
        let body = cues.map { name, start, end, text in
            "\(stamp(start)) --> \(stamp(end))\n" + (name.map { "<v \($0)>\(text)</v>" } ?? text)
        }.joined(separator: "\n\n")
        return try TeamsTranscriptParser.vtt(Data(("WEBVTT\n\n" + body + "\n").utf8), file: "t.vtt")
    }

    static func blocks(_ store: SessionStore, _ meetingID: UUID) async throws -> [TranscriptBlock] {
        try await store.meetingTranscript(meetingID: meetingID).items.compactMap { if case .speech(let block) = $0 { block } else { nil } }
    }

    @Test func aVTTBecomesTheFinalTranscriptWithItsNames() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let wav = folder.url.appending(path: "call.wav"), file = folder.url.appending(path: "call.vtt")
        try ImportMedia.audioFile(wav, seconds: 40, rate: 16_000)
        let transcript = try Self.vtt([("Mark Davis", 6, 9, "Okay, great."), ("Ana Lee", 10, 14, "Yep."),
                                       ("Mark Davis", 20, 25, "Let's start."), (nil, 30, 31, "Hm.")])
        try Data("x".utf8).write(to: file)
        // 15:04 UTC: the reply at 0:06 shows 15:04.
        let start = ISO8601DateFormatter().date(from: "2026-10-27T15:04:00Z")!
        let result = try await SessionImporter.run(SessionImportRequest(destination: .newMeeting(MeetingDraft(title: "Q&A", description: "")),
            media: wav, transcript: transcript, transcriptFile: file, start: start, timeZoneIdentifier: "UTC"), library: library, store: store)

        let blocks = try await Self.blocks(store, result.meeting.id)
        #expect(blocks.map(\.speakerLabel) == ["Mark Davis", "Ana Lee", "Mark Davis", "Unidentified"])
        #expect(blocks.allSatisfy { $0.speaker != .microphone && !$0.isNamedFragment })
        #expect(blocks[0].timestamp.hasPrefix("15:04"))
        #expect(blocks[0].segments[0].interval == (try MediaInterval(start: MediaTime(seconds: 6), end: MediaTime(seconds: 9))))
        #expect(Set(result.named.values) == ["Mark Davis", "Ana Lee"])
        #expect(try await store.jobs(meetingID: result.meeting.id).isEmpty)
        let revision = try #require(try await store.transcript(meetingID: result.meeting.id, recordingID: result.recording.id))
        #expect(revision.kind == .final && revision.modelRevisions.isEmpty)
        #expect(revision.importSource?.format == "vtt" && revision.importSource?.fileName == "call.vtt" && revision.importSource?.sha256.count == 64)
        let assignments = try await store.speakerAssignments(meetingID: result.meeting.id)
        #expect(assignments.filter { $0.origin == .manual }.compactMap(\.name).sorted() == ["Ana Lee", "Mark Davis"])
        #expect(assignments.first { $0.name == "Mark Davis" }?.evidence.count == 2)
        // A summary can use it: no transcription job is required.
        try await store.requireSummarySource(meetingID: result.meeting.id, recordingID: result.recording.id)
        try await store.close()
    }

    @Test func theSameNameOnTheSameDayIsTheSameSpeaker() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let wav = folder.url.appending(path: "call.wav")
        try ImportMedia.audioFile(wav, seconds: 20, rate: 16_000)
        let start = ISO8601DateFormatter().date(from: "2026-10-27T10:00:00Z")!
        let first = try await SessionImporter.run(SessionImportRequest(destination: .newMeeting(MeetingDraft(title: "Day", description: "")),
            media: wav, transcript: try Self.vtt([("Mark Davis", 1, 5, "One."), ("Ana Lee", 6, 9, "Two.")]),
            start: start, timeZoneIdentifier: "UTC"), library: library, store: store)
        let second = try await SessionImporter.run(SessionImportRequest(destination: .existing(first.meeting.id),
            media: wav, transcript: try Self.vtt([("mark davis", 2, 6, "Three."), ("Boris", 7, 9, "Four.")]),
            start: start.addingTimeInterval(3_600), timeZoneIdentifier: "UTC"), library: library, store: store)
        let mark = try #require(first.named.first { $0.value == "Mark Davis" }?.key)
        #expect(second.named[mark] == "Mark Davis")
        #expect(second.recording.days.map(\.id) == first.recording.days.map(\.id))
        let speakers = try await store.daySpeakers(meetingID: first.meeting.id)
        #expect(speakers.count == 3 && Set(speakers.map(\.number)) == [1, 2, 3])
        let blocks = try await Self.blocks(store, first.meeting.id)
        #expect(blocks.map(\.speakerLabel) == ["Mark Davis", "Ana Lee", "Mark Davis", "Boris"])
        #expect(blocks[0].speaker == blocks[2].speaker)
        let evidence = try await store.speakerAssignments(meetingID: first.meeting.id).first { $0.daySpeakerID == mark }?.evidence
        #expect(Set(evidence?.map(\.recordingID) ?? []) == [first.recording.id, second.recording.id])
        // Another day's recording gets its own speaker.
        let later = try await SessionImporter.run(SessionImportRequest(destination: .existing(first.meeting.id),
            media: wav, transcript: try Self.vtt([("Mark Davis", 1, 5, "Five.")]),
            start: start.addingTimeInterval(86_400), timeZoneIdentifier: "UTC"), library: library, store: store)
        #expect(later.named.keys.first != mark)
        try await store.close()
    }

    @Test func reprocessNamesTheNewVoicesFromTheImportedNames() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        try removeFinalHead(fixture)
        let store = fixture.store, meetingID = fixture.recording.meetingID
        let transcript = TeamsTranscript(format: .docx, title: nil, start: nil, duration: nil,
            replies: [ImportedReply(name: "Mark Davis", start: .zero, text: "Okay, great.")])
        _ = try await store.importTranscript(transcript, recordingID: fixture.recording.id)
        #expect(try await Self.blocks(store, meetingID).map(\.speakerLabel) == ["Mark Davis"])

        let job = try await nextFinalJob(fixture)
        _ = try await stageFinal(fixture, job: job)
        _ = try await store.publishFinalTranscript(jobID: job.id)
        let system = try await Self.blocks(store, meetingID).filter { $0.speaker != .microphone }
        #expect(!system.isEmpty && system.allSatisfy { $0.speakerLabel == "Mark Davis" }, "\(system.map(\.speakerLabel))")
        try await store.close()
    }

    @Test func revisionsWithoutAnImportKeepTheirStoredForm() throws {
        let segment = TranscriptSegment(recordingID: UUID(), dayID: UUID(), track: .microphone,
            interval: try MediaInterval(start: .zero, end: MediaTime(seconds: 1)), wallClockStart: Date(timeIntervalSince1970: 0),
            speaker: .microphone, originalText: "Hi")
        let plain = TranscriptRevision(recordingID: segment.recordingID, sourceGeneration: 0, kind: .final, segments: [segment],
                                       modelRevisions: [], createdAt: Date(timeIntervalSince1970: 0))
        let json = String(decoding: try DomainCodec.encode(plain), as: UTF8.self)
        #expect(!json.contains("importSource"))
        #expect(try DomainCodec.decode(TranscriptRevision.self, from: Data(json.utf8)) == plain)
        let imported = TranscriptRevision(recordingID: segment.recordingID, sourceGeneration: 0, kind: .final, segments: [segment],
            modelRevisions: [], createdAt: Date(timeIntervalSince1970: 0), importSource: TranscriptImportSource(format: "docx", fileName: "a.docx", sha256: "00"))
        #expect(try DomainCodec.decode(TranscriptRevision.self, from: DomainCodec.encode(imported)).importSource?.fileName == "a.docx")
    }
}
