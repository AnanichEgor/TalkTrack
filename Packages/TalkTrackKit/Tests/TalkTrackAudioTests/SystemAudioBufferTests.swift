import CoreAudio
import Foundation
import Testing
@testable import TalkTrackAudio

private final class BufferLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPackets: [AudioPacket] = []
    private var storedErrors: [AudioCaptureError] = []
    func receive(_ packet: AudioPacket) { lock.withLock { storedPackets.append(packet) } }
    func fail(_ error: AudioCaptureError) { lock.withLock { storedErrors.append(error) } }
    var packets: [AudioPacket] { lock.withLock { storedPackets } }
    var errors: [AudioCaptureError] { lock.withLock { storedErrors } }
}

/// Calls `SystemTapBuffers.consume` with buffers shaped like an aggregate device's IOProc input.
private func consume(_ buffers: [[Float]], channelsPerBuffer: [UInt32], frames: Int, hostTime: UInt64 = 1_000,
                     flags: AudioTimeStampFlags = [.hostTimeValid, .sampleTimeValid], byteSizes: [UInt32]? = nil,
                     into packets: AudioPacketHandoff) {
    var storage = buffers
    let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
    defer { free(list.unsafeMutablePointer) }
    for index in storage.indices {
        storage[index].withUnsafeMutableBytes { bytes in
            list[index] = AudioBuffer(mNumberChannels: channelsPerBuffer[index],
                mDataByteSize: byteSizes?[index] ?? UInt32(frames) * channelsPerBuffer[index] * 4, mData: bytes.baseAddress)
        }
    }
    var time = AudioTimeStamp()
    time.mHostTime = hostTime; time.mSampleTime = 512; time.mFlags = flags
    withExtendedLifetime(storage) { SystemTapBuffers.consume(list.unsafePointer, &time, into: packets) }
}

@Suite struct SystemAudioBufferTests {
    @Test func interleavedAndSplitChannelsMixToMonoWithHostTime() async {
        let log = BufferLog()
        let packets = AudioPacketHandoff(source: .system, sampleRate: 48_000, receive: log.receive, failure: log.fail)
        consume([[0.2, 0.4, 0.2, 0.4]], channelsPerBuffer: [2], frames: 2, into: packets)
        consume([[0.6, 0.6], [0.0, 0.2]], channelsPerBuffer: [1, 1], frames: 2, hostTime: 2_000, into: packets)
        await packets.finish()
        #expect(log.errors.isEmpty)
        #expect(log.packets.map(\.hostTime) == [1_000, 2_000])
        #expect(log.packets.allSatisfy { $0.sampleTime == 512 && $0.sampleRate == 48_000 && $0.source == .system })
        #expect(log.packets[0].samples.allSatisfy { abs($0 - 0.3) < 1e-6 })
        #expect(log.packets[1].samples.map { ($0 * 10).rounded() / 10 } == [0.3, 0.4])
    }

    @Test func silenceIsValidAudioAndDoesNotImplyPermissionDenial() async {
        let log = BufferLog()
        let packets = AudioPacketHandoff(source: .system, sampleRate: 48_000, receive: log.receive, failure: log.fail)
        consume([[Float](repeating: 0, count: 480)], channelsPerBuffer: [1], frames: 480, into: packets)
        await packets.finish()
        #expect(log.errors.isEmpty)
        #expect(log.packets.first?.samples.allSatisfy { $0 == 0 } == true)
    }

    @Test func missingHostTimeOrMismatchedBuffersInterruptTheRecording() async {
        for broken in 0..<2 {
            let log = BufferLog()
            let packets = AudioPacketHandoff(source: .system, sampleRate: 48_000, receive: log.receive, failure: log.fail)
            if broken == 0 {
                consume([[0.1, 0.1]], channelsPerBuffer: [1], frames: 2, flags: [.sampleTimeValid], into: packets)
            } else {
                consume([[0.1, 0.1], [0.1]], channelsPerBuffer: [1, 1], frames: 2, byteSizes: [8, 4], into: packets)
            }
            await packets.finish()
            #expect(log.packets.isEmpty)
            #expect(log.errors.count == 1 && log.errors[0].operation.contains("invalid audio or timing"))
        }
    }

    @Test func emptyBuffersAreIgnored() async {
        let log = BufferLog()
        let packets = AudioPacketHandoff(source: .system, sampleRate: 48_000, receive: log.receive, failure: log.fail)
        consume([[]], channelsPerBuffer: [1], frames: 0, into: packets)
        await packets.finish()
        #expect(log.packets.isEmpty && log.errors.isEmpty)
    }

    @Test func onlyPermissionFailuresSuggestChangingPrivacySettings() {
        for recovery in [AudioCaptureRecovery.microphonePermission, .systemAudioPermission] {
            let error = AudioCaptureError(source: .system, operation: "Permission denied", status: nil, recovery: recovery)
            #expect(error.recoverySuggestion?.contains("Privacy") == true)
        }
        let system = AudioCaptureError(source: .system, operation: "Not allowed", status: nil, recovery: .systemAudioPermission)
        #expect(system.recoverySuggestion?.contains("System Audio Recording Only") == true)
        #expect(system.settingsURL?.absoluteString.hasSuffix("Privacy_ScreenCapture") == true)
        #expect(AudioCaptureError(source: .microphone, operation: "Permission was denied", status: nil,
            recovery: .microphonePermission).settingsURL?.absoluteString.hasSuffix("Privacy_Microphone") == true)
        let bufferError = AudioCaptureError(source: .system, operation: "Cannot read audio buffers", status: -12737)
        #expect(bufferError.recoverySuggestion?.contains("Privacy") == false)
        #expect(bufferError.settingsURL == nil)
        #expect(bufferError.errorDescription?.contains("-12737") == true)
    }
}
