import AudioToolbox
import Darwin
import Foundation

public struct AACPacketInfo: Codable, Equatable, Sendable {
    public let validFrames: UInt64
    public let primingFrames: UInt32
    public let remainderFrames: UInt32
    public let packetCount: UInt64
}

public struct AudioEncodingError: Error, LocalizedError, Sendable {
    public let operation: String
    public let status: OSStatus
    public var errorDescription: String? { "Audio storage: \(operation) (OSStatus \(status))." }
    public var recoverySuggestion: String? { "Check free disk space and session folder access. Completed audio can be recovered." }
}

/// Synchronous worker-only codec. The caller owns the already-opened regular
/// file descriptor. AudioToolbox callbacks use that descriptor throughout, so
/// encoding/inspection never follows a path that can be swapped for a symlink.
/// Input is finite mono Float32 at 48 kHz; route resampling belongs upstream.
public final class AACChunkEncoder {
    public static let sampleRate: UInt32 = 48_000
    public static let bitRate: UInt32 = 64_000
    public static let maximumFrames: UInt64 = 480_000
    private let io: AudioDescriptorIO
    private var file: AudioFileID?
    private var extended: ExtAudioFileRef?
    public private(set) var frames: UInt64 = 0

    public init(fileDescriptor: Int32) throws {
        io = AudioDescriptorIO(fileDescriptor)
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        do {
            try encodingCheck(AudioFileInitializeWithCallbacks(io.pointer, descriptorRead, descriptorWrite,
                descriptorSize, descriptorResize, kAudioFileM4AType, &format, [], &file), "Create AAC chunk")
            try encodingCheck(ExtAudioFileWrapAudioFileID(file!, true, &extended), "Open AAC encoder")
            var pcm = monoPCM()
            try encodingCheck(ExtAudioFileSetProperty(extended!, kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout.size(ofValue: pcm)), &pcm), "Set PCM format")
            var converter: AudioConverterRef?
            var size = UInt32(MemoryLayout.size(ofValue: converter))
            try encodingCheck(ExtAudioFileGetProperty(extended!, kExtAudioFileProperty_AudioConverter,
                &size, &converter), "Get AAC converter")
            guard let converter else { throw AudioEncodingError(operation: "Missing AAC converter", status: -1) }
            var bitrate = Self.bitRate
            try encodingCheck(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                UInt32(MemoryLayout.size(ofValue: bitrate)), &bitrate), "Set AAC bitrate")
            var config: UnsafeRawPointer?
            try encodingCheck(ExtAudioFileSetProperty(extended!, kExtAudioFileProperty_ConverterConfig,
                UInt32(MemoryLayout.size(ofValue: config)), &config), "Apply AAC converter configuration")
        } catch { dispose(); throw error }
    }

    deinit { dispose() }

    public func append(_ samples: ArraySlice<Float>) throws {
        guard let extended, !samples.isEmpty, samples.count <= Int(Self.maximumFrames - frames),
              samples.allSatisfy(\.isFinite) else {
            throw AudioEncodingError(operation: "Invalid PCM or chunk exceeds ten seconds", status: -1)
        }
        try samples.withUnsafeBufferPointer { pointer in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
                mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(mutating: pointer.baseAddress!)))
            try encodingCheck(ExtAudioFileWrite(extended, UInt32(samples.count), &list), "Write AAC chunk")
        }
        frames += UInt64(samples.count)
    }

    /// Explicit close reports encoder/container failures before publication.
    public func finish() throws -> AACPacketInfo {
        guard let extended, let file, frames > 0 else {
            throw AudioEncodingError(operation: "AAC chunk is empty or already closed", status: -1)
        }
        self.extended = nil; self.file = nil
        let flushStatus = ExtAudioFileDispose(extended)
        let closeStatus = AudioFileClose(file)
        try encodingCheck(flushStatus, "Flush AAC encoder")
        try encodingCheck(closeStatus, "Finalize AAC container")
        return try Self.inspect(fileDescriptor: io.fd, expectedFrames: frames)
    }

    /// Reads in small windows; verifies the container, AAC packet accounting,
    /// and actual decoded frame count, with the decoder's standard trims active.
    /// TrackChunk consumers must not subtract priming/remainder a second time.
    public static func inspect(fileDescriptor: Int32, expectedFrames: UInt64) throws -> AACPacketInfo {
        try decode(fileDescriptor: fileDescriptor, expectedFrames: expectedFrames, receive: { _ in })
    }

    public static func decode(fileDescriptor: Int32, expectedFrames: UInt64,
                              receive: (UnsafeBufferPointer<Float>) throws -> Void) throws -> AACPacketInfo {
        guard expectedFrames > 0, expectedFrames <= maximumFrames else {
            throw AudioEncodingError(operation: "Invalid AAC frame count", status: -1)
        }
        let io = AudioDescriptorIO(fileDescriptor)
        var file: AudioFileID?
        try encodingCheck(AudioFileOpenWithCallbacks(io.pointer, descriptorRead, nil, descriptorSize,
            nil, kAudioFileM4AType, &file), "Read AAC container")
        defer { if let file { AudioFileClose(file) } }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        try encodingCheck(AudioFileGetProperty(file!, kAudioFilePropertyDataFormat, &size, &format), "Read AAC format")
        // kAudioFormatMPEG4AAC is the LC codec (HE has separate format IDs).
        // The M4A reader reports flags zero even when the encoder used AAC_LC.
        guard format.mFormatID == kAudioFormatMPEG4AAC, format.mSampleRate == 48_000,
              format.mChannelsPerFrame == 1, format.mFramesPerPacket == 1024 else {
            throw AudioEncodingError(operation: "Unexpected AAC format", status: -1)
        }
        var table = AudioFilePacketTableInfo(), packets: UInt64 = 0
        size = UInt32(MemoryLayout.size(ofValue: table))
        try encodingCheck(AudioFileGetProperty(file!, kAudioFilePropertyPacketTableInfo, &size, &table), "Read AAC trims")
        size = UInt32(MemoryLayout.size(ofValue: packets))
        try encodingCheck(AudioFileGetProperty(file!, kAudioFilePropertyAudioDataPacketCount, &size, &packets), "Read AAC packets")
        guard table.mNumberValidFrames == Int64(expectedFrames), table.mPrimingFrames >= 0,
              table.mRemainderFrames >= 0, packets <= (maximumFrames + 16_384) / 1024,
              packets * 1024 == expectedFrames + UInt64(table.mPrimingFrames) + UInt64(table.mRemainderFrames) else {
            throw AudioEncodingError(operation: "AAC packet/frame accounting mismatch", status: -1)
        }
        var extended: ExtAudioFileRef?
        try encodingCheck(ExtAudioFileWrapAudioFileID(file!, false, &extended), "Open AAC decoder")
        defer { if let extended { ExtAudioFileDispose(extended) } }
        var pcm = monoPCM()
        try encodingCheck(ExtAudioFileSetProperty(extended!, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: pcm)), &pcm), "Set decoder format")
        var decoded: UInt64 = 0
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        defer { buffer.deallocate() }
        while true {
            var count: UInt32 = 8192
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
                mDataByteSize: count * 4, mData: buffer))
            try encodingCheck(ExtAudioFileRead(extended!, &count, &list), "Decode AAC chunk")
            if count == 0 { break }
            decoded += UInt64(count)
            guard decoded <= expectedFrames else {
                throw AudioEncodingError(operation: "AAC decoder returned extra frames", status: -1)
            }
            let samples = UnsafeBufferPointer(start: buffer, count: Int(count))
            guard samples.allSatisfy(\.isFinite) else {
                throw AudioEncodingError(operation: "AAC decoder returned invalid samples", status: -1)
            }
            try receive(samples)
        }
        guard decoded == expectedFrames else {
            throw AudioEncodingError(operation: "AAC decoder returned missing frames", status: -1)
        }
        return AACPacketInfo(validFrames: decoded, primingFrames: UInt32(table.mPrimingFrames),
            remainderFrames: UInt32(table.mRemainderFrames), packetCount: packets)
    }

    public func abort() { dispose() }

    private func dispose() {
        if let extended { ExtAudioFileDispose(extended); self.extended = nil }
        if let file { AudioFileClose(file); self.file = nil }
    }
}

private func monoPCM() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
}
private func encodingCheck(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioEncodingError(operation: operation, status: status) }
}
private final class AudioDescriptorIO {
    let fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    static func descriptor(_ pointer: UnsafeMutableRawPointer) -> Int32 {
        Unmanaged<AudioDescriptorIO>.fromOpaque(pointer).takeUnretainedValue().fd
    }
}
private let descriptorRead: AudioFile_ReadProc = { context, position, count, buffer, actual in
    var result: Int
    repeat { result = pread(AudioDescriptorIO.descriptor(context), buffer, Int(count), off_t(position)) }
    while result < 0 && errno == EINTR
    actual.pointee = result >= 0 ? UInt32(result) : 0
    return result < 0 ? OSStatus(errno) : noErr
}
private let descriptorWrite: AudioFile_WriteProc = { context, position, count, buffer, actual in
    var written = 0
    while written < Int(count) {
        let result = pwrite(AudioDescriptorIO.descriptor(context), buffer.advanced(by: written),
            Int(count) - written, off_t(position) + off_t(written))
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else { actual.pointee = UInt32(written); return OSStatus(result < 0 ? errno : EIO) }
        written += result
    }
    actual.pointee = count
    return noErr
}
private let descriptorSize: AudioFile_GetSizeProc = { context in
    var info = stat()
    return fstat(AudioDescriptorIO.descriptor(context), &info) == 0 ? info.st_size : 0
}
private let descriptorResize: AudioFile_SetSizeProc = { context, size in
    ftruncate(AudioDescriptorIO.descriptor(context), off_t(size)) == 0 ? noErr : OSStatus(errno)
}
