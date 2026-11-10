import Darwin
import Foundation
import Testing
import AudioToolbox
@testable import TalkTrackAudio

@Suite struct AACChunkEncoderTests {
    @Test(arguments: [1, 1023, 1024, 1025, 479_999, 480_000])
    func exactValidFramesAfterNativeTrimming(count: Int) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("audio.m4a").path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        let encoder = try AACChunkEncoder(fileDescriptor: fd)
        let input = (0..<count).map { Float(0.3 * sin(Double($0) * 2 * .pi * 440 / 48_000)) }
        try encoder.append(input[...])
        let info = try encoder.finish()
        #expect(info.validFrames == UInt64(count))
        #expect(info.primingFrames > 0)
        #expect(info.packetCount * 1024 == info.validFrames + UInt64(info.primingFrames) + UInt64(info.remainderFrames))
        var total = 0
        _ = try AACChunkEncoder.decode(fileDescriptor: fd, expectedFrames: UInt64(count)) { total += $0.count }
        #expect(total == count)
        #expect(throws: AudioEncodingError.self) { try encoder.append([Float(0.1)][...]) }
    }

    @Test func rejectsNonfiniteSamplesAndExcessFrames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        defer { close(fd); try? FileManager.default.removeItem(at: url) }
        let encoder = try AACChunkEncoder(fileDescriptor: fd)
        #expect(throws: AudioEncodingError.self) { try encoder.append([Float.nan][...]) }
        #expect(throws: AudioEncodingError.self) { try encoder.append([Float](repeating: 0, count: 480_001)[...]) }
        #expect(encoder.frames == 0)
        encoder.abort()
    }

    /// compact-library-storage D4: a ten-second chunk reserves no padding, and
    /// its audio is what the writer's default (padded) container holds.
    @Test func tenSecondChunkHasNoReservedPadding() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var generator = SystemRandomNumberGenerator()
        let input = (0..<480_000).map { Float(0.3 * sin(Double($0) * 0.05)) + Float.random(in: -0.05...0.05, using: &generator) }
        let path = folder.appendingPathComponent("chunk.m4a").path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        defer { close(fd) }
        let encoder = try AACChunkEncoder(fileDescriptor: fd)
        try encoder.append(input[...])
        let info = try encoder.finish()
        #expect(info.validFrames == 480_000 && info.primingFrames == 2112 && info.remainderFrames == 192)
        let boxes = try Self.boxes(Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(boxes.filter { $0.0 == "free" }.map(\.1).reduce(0, +) < 4096)
        // The same samples in the writer's default container: same packets, large padding.
        let reference = folder.appendingPathComponent("reference.m4a")
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var file: AudioFileID?
        #expect(AudioFileCreateWithURL(reference as CFURL, kAudioFileM4AType, &format, [], &file) == noErr)
        var extended: ExtAudioFileRef?
        #expect(ExtAudioFileWrapAudioFileID(file!, true, &extended) == noErr)
        var pcm = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        ExtAudioFileSetProperty(extended!, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: pcm)), &pcm)
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout.size(ofValue: converter))
        ExtAudioFileGetProperty(extended!, kExtAudioFileProperty_AudioConverter, &size, &converter)
        var bitrate = AACChunkEncoder.bitRate
        AudioConverterSetProperty(converter!, kAudioConverterEncodeBitRate, UInt32(MemoryLayout.size(ofValue: bitrate)), &bitrate)
        var config: UnsafeRawPointer?
        ExtAudioFileSetProperty(extended!, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout.size(ofValue: config)), &config)
        var samples = input
        samples.withUnsafeMutableBufferPointer { pointer in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
                mDataByteSize: UInt32(pointer.count * 4), mData: pointer.baseAddress))
            _ = ExtAudioFileWrite(extended!, UInt32(pointer.count), &list)
        }
        ExtAudioFileDispose(extended!); AudioFileClose(file!)
        let padded = try Self.boxes(Data(contentsOf: reference))
        #expect(padded.filter { $0.0 == "free" }.map(\.1).reduce(0, +) > 32_768)
        let audio = boxes.first { $0.0 == "mdat" }!.1, before = padded.first { $0.0 == "mdat" }!.1
        #expect(abs(Double(audio - before)) <= Double(before) * 0.02)
    }

    static func boxes(_ data: Data) throws -> [(String, Int)] {
        var result: [(String, Int)] = [], offset = 0
        while offset + 8 <= data.count {
            let size = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            result.append((String(decoding: data[offset + 4..<offset + 8], as: UTF8.self), size))
            guard size >= 8 else { break }
            offset += size
        }
        return result
    }
}
