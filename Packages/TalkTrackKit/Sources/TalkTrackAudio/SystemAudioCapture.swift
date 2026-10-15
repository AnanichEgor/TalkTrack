@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// System audio through the audio output of a ScreenCaptureKit display stream.
/// Unlike a Core Audio process tap, a denied grant is detectable through public
/// API before Recording is reported; no screen frames are consumed or stored.
/// The stream excludes TalkTrack's own process audio, so playback is not recaptured.
public actor SystemAudioCapture {
    private nonisolated let executor = AudioDriverExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private let queue = DispatchQueue(label: "local.talktrack.system-audio", qos: .userInteractive)
    private var stream: SCStream?
    private var output: SystemAudioStreamOutput?
    private var startup = false
    private var started = false
    private var stopReply: CaptureReply<Void>?
    public init() {}

    public static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    public func start(receive: @escaping @Sendable (AudioPacket) -> Void,
                      failure: @escaping @Sendable (AudioCaptureError) -> Void) async throws {
        guard stream == nil, !startup, stopReply == nil else {
            throw AudioCaptureError(source: .system, operation: "Capture is already active", status: nil)
        }
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt only on first use; macOS applies a new
            // grant after TalkTrack restarts, so this start fails either way.
            _ = CGRequestScreenCaptureAccess()
            throw Self.permissionError
        }
        startup = true
        defer { startup = false }
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch { throw Self.mapped(error, operation: "Cannot list capture content") }
        try Task.checkCancellation()
        guard let display = content.displays.first else {
            throw AudioCaptureError(source: .system, operation: "No display is available for the system audio stream", status: nil)
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = Int(SystemAudioStreamOutput.sampleRate)
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = false
        // Video cannot be disabled; keep the unused screen output minimal.
        configuration.width = 2; configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        let next = SystemAudioStreamOutput(receive: receive, failure: failure)
        let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                               configuration: configuration, delegate: next)
        do { try capture.addStreamOutput(next, type: .audio, sampleHandlerQueue: queue) }
        catch { throw Self.mapped(error, operation: "Cannot register system audio output") }
        stream = capture; output = next
        do {
            try await capture.startCapture()
            started = true
            try Task.checkCancellation()
            if #available(macOS 27.0, *), !capture.isCapturing {
                throw AudioCaptureError(source: .system, operation: "The system audio stream did not become active", status: nil)
            }
            guard CGPreflightScreenCaptureAccess() else { throw Self.permissionError }
        } catch {
            if !started {
                next.closeErrors()
                queue.sync {}
                await next.packets.finish()
                stream = nil; output = nil
            }
            // After a started stream fails, the coordinator invokes Stop.
            if error is CancellationError || error is AudioCaptureError { throw error }
            throw Self.mapped(error, operation: "Cannot start system audio capture")
        }
    }

    public func stop() async throws {
        if let stopReply { return try await stopReply.value() }
        let reply = CaptureReply<Void>(); stopReply = reply
        defer { stopReply = nil }
        do {
            output?.closeErrors()
            if started, let stream { try await stream.stopCapture() }
            started = false
            queue.sync {}
            await output?.packets.finish()
            stream = nil; output = nil
            reply.resolve(.success(()))
        } catch {
            let problem = AudioCaptureError(source: .system,
                operation: "Cannot stop system audio capture; retry Stop (\(error.localizedDescription))", status: nil)
            reply.resolve(.failure(problem)); throw problem
        }
    }

    static let permissionError = AudioCaptureError(source: .system,
        operation: "Screen & System Audio Recording access is not allowed", status: nil, recovery: .screenRecordingPermission)

    static func mapped(_ error: Error, operation: String) -> AudioCaptureError {
        if let error = error as? AudioCaptureError { return error }
        let code = (error as NSError).domain == SCStreamErrorDomain ? (error as NSError).code : nil
        if code == SCStreamError.userDeclined.rawValue { return permissionError }
        return AudioCaptureError(source: .system, operation: "\(operation): \(error.localizedDescription)",
                                 status: code.map { OSStatus(truncatingIfNeeded: $0) })
    }
}

/// Receives ScreenCaptureKit sample buffers serially on the stream's handler
/// queue. Only borrowed PCM pointers are used; the handoff copies samples
/// before `consume` returns.
final class SystemAudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let sampleRate: Double = 48_000
    let packets: AudioPacketHandoff
    private let failure: @Sendable (AudioCaptureError) -> Void
    private let lock = NSLock()
    private var errorsOpen = true
    private let storage: UnsafeMutableRawPointer
    private let storageSize = MemoryLayout<AudioBufferList>.size + 7 * MemoryLayout<AudioBuffer>.stride

    init(receive: @escaping @Sendable (AudioPacket) -> Void,
         failure: @escaping @Sendable (AudioCaptureError) -> Void) {
        self.failure = failure
        storage = .allocate(byteCount: storageSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        packets = AudioPacketHandoff(source: .system, sampleRate: Self.sampleRate, receive: receive, failure: failure)
        super.init()
    }
    deinit { storage.deallocate() }
    func closeErrors() { lock.withLock { errorsOpen = false } }
    private func fault(_ error: AudioCaptureError) {
        let send = lock.withLock { () -> Bool in
            guard errorsOpen else { return false }; errorsOpen = false; return true
        }
        if send { failure(error) }
    }
    private func fault(_ operation: String, status: OSStatus? = nil) {
        fault(AudioCaptureError(source: .system, operation: operation, status: status))
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fault(SystemAudioCapture.mapped(error, operation: "System audio capture was interrupted"))
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        consume(sampleBuffer)
    }

    func consume(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else {
            fault("The system audio sample buffer is invalid or not ready"); return
        }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        guard frames <= 16_384 else {
            fault("The system audio sample buffer exceeds the bounded packet size"); return
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mSampleRate == Self.sampleRate, (1...8).contains(format.mChannelsPerFrame),
              time.isNumeric, time.seconds.isFinite, time.seconds > 0 else {
            let detail = CMSampleBufferGetFormatDescription(sampleBuffer)
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            fault("System audio format/timing rejected: frames=\(frames), rate=\(detail?.mSampleRate ?? 0), bits=\(detail?.mBitsPerChannel ?? 0), flags=\(detail?.mFormatFlags ?? 0), channels=\(detail?.mChannelsPerFrame ?? 0), PTS=\(time.value)/\(time.timescale), timeFlags=\(time.flags.rawValue)")
            return
        }
        var retainedBlock: CMBlockBuffer?
        var needed = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
            bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard sizeStatus == noErr, needed >= MemoryLayout<AudioBufferList>.size, needed <= storageSize else {
            fault("Unsupported system audio buffer list size (needed=\(needed))", status: sizeStatus); return
        }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer,
            bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, blockBufferOut: &retainedBlock)
        guard status == noErr else {
            fault("Cannot read the system audio buffer list (needed=\(needed), allocated=\(storageSize))", status: status); return
        }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard !buffers.isEmpty, buffers.count <= 8,
              buffers.reduce(0, { $0 + Int($1.mNumberChannels) }) == Int(format.mChannelsPerFrame),
              buffers.allSatisfy({ $0.mNumberChannels > 0 && $0.mData != nil &&
                  Int($0.mDataByteSize) == frames * Int($0.mNumberChannels) * MemoryLayout<Float>.size }) else {
            fault("System audio buffer shape rejected: frames=\(frames), formatChannels=\(format.mChannelsPerFrame), buffers=\(buffers.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)bytes/data=\($0.mData != nil)" }.joined(separator: ","))")
            return
        }
        withExtendedLifetime(retainedBlock) {
            // ScreenCaptureKit timestamps use the host-time clock.
            packets.enqueue(frames: frames, channels: Int(format.mChannelsPerFrame),
                hostTime: AVAudioTime.hostTime(forSeconds: time.seconds), sampleTime: time.seconds * Self.sampleRate) { frame, channel in
                var offset = channel
                for buffer in buffers {
                    let count = Int(buffer.mNumberChannels)
                    if offset < count { return buffer.mData!.assumingMemoryBound(to: Float.self)[frame * count + offset] }
                    offset -= count
                }
                return 0 // validated channel count makes this unreachable
            }
        }
    }
}
