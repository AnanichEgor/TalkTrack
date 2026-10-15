@preconcurrency import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Foundation
import Testing
@testable import TalkTrackAudio

private final class ScreenBufferLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPackets: [AudioPacket] = []
    private var storedErrors: [AudioCaptureError] = []
    func receive(_ packet: AudioPacket) { lock.withLock { storedPackets.append(packet) } }
    func fail(_ error: AudioCaptureError) { lock.withLock { storedErrors.append(error) } }
    var packets: [AudioPacket] { lock.withLock { storedPackets } }
    var errors: [AudioCaptureError] { lock.withLock { storedErrors } }
}

private func screenBuffer(_ channels: [[Float]], interleaved: Bool = false,
                          rate: Double = 48_000, time: CMTime = CMTime(value: 123, timescale: 1)) throws -> CMSampleBuffer {
    let frames = try #require(channels.first?.count)
    let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
        channels: AVAudioChannelCount(channels.count), interleaved: interleaved))
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    pcm.frameLength = AVAudioFrameCount(frames)
    let pointers = try #require(pcm.floatChannelData)
    for channel in channels.indices {
        for frame in 0..<frames {
            if interleaved { pointers[0][frame * channels.count + channel] = channels[channel][frame] }
            else { pointers[channel][frame] = channels[channel][frame] }
        }
    }
    var description: CMAudioFormatDescription?
    #expect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &description) == noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
        presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var buffer: CMSampleBuffer?
    let audioDescription = try #require(description)
    #expect(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: audioDescription,
        sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer) == noErr)
    let ready = try #require(buffer)
    #expect(CMSampleBufferSetDataBufferFromAudioBufferList(ready, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
    return ready
}

@Suite struct SystemAudioBufferTests {
    @Test func actualCoreMediaBufferListsPreservePCMAndAnchors() async throws {
        for (channels, interleaved, expected) in [
            ([[Float(0.25), -0.5, 0.75]], false, [Float(0.25), -0.5, 0.75]),
            ([[Float(1), -0.5], [Float(-0.5), 0.25]], false, [Float(0.25), -0.125]),
            ([[Float(1), -0.5], [Float(-0.5), 0.25]], true, [Float(0.25), -0.125])
        ] {
            let log = ScreenBufferLog(), output = SystemAudioStreamOutput(receive: log.receive, failure: log.fail)
            // Release the source before draining: published packets own their PCM.
            do { output.consume(try screenBuffer(channels, interleaved: interleaved)) }
            await output.packets.finish()
            #expect(log.errors.isEmpty)
            #expect(log.packets.count == 1)
            #expect(log.packets.first?.samples == expected)
            #expect(log.packets.first?.hostTime == AVAudioTime.hostTime(forSeconds: 123))
            #expect(log.packets.first?.sampleTime == 5_904_000.0)
            #expect(log.packets.first?.source == .system)
        }
    }

    @Test func silenceIsValidAudioAndDoesNotImplyPermissionDenial() async throws {
        let log = ScreenBufferLog(), output = SystemAudioStreamOutput(receive: log.receive, failure: log.fail)
        output.consume(try screenBuffer([[Float](repeating: 0, count: 960)]))
        await output.packets.finish()
        #expect(log.errors.isEmpty)
        #expect(log.packets.first?.samples == [Float](repeating: 0, count: 960))
    }

    @Test func malformedTimingRateAndOversizedPacketsAreRejected() async throws {
        for buffer in [
            try screenBuffer([[1]], rate: 44_100),
            try screenBuffer([[1]], time: CMTime(value: -1, timescale: 1)),
            try screenBuffer([[Float](repeating: 0, count: 16_385)])
        ] {
            let log = ScreenBufferLog(), output = SystemAudioStreamOutput(receive: log.receive, failure: log.fail)
            output.consume(buffer); output.consume(buffer)
            await output.packets.finish()
            #expect(log.packets.isEmpty)
            #expect(log.errors.count == 1)
            #expect(log.errors.first?.recoverySuggestion?.contains("Privacy") == false)
        }
    }

    @Test func invalidBuffersAndClosedOutputsDoNotPublishLateErrors() async throws {
        let buffer = try screenBuffer([[1]])
        #expect(CMSampleBufferInvalidate(buffer) == noErr)
        let log = ScreenBufferLog(), output = SystemAudioStreamOutput(receive: log.receive, failure: log.fail)
        output.consume(buffer)
        output.closeErrors()
        output.consume(buffer)
        await output.packets.finish()
        #expect(log.errors.count == 1)
        #expect(log.packets.isEmpty)
        output.consume(try screenBuffer([[1]]))
        #expect(log.packets.isEmpty)
    }

    @Test func onlyPermissionFailuresSuggestChangingPrivacySettings() {
        for recovery in [AudioCaptureRecovery.microphonePermission, .screenRecordingPermission] {
            let error = AudioCaptureError(source: .system, operation: "Permission denied", status: nil, recovery: recovery)
            #expect(error.recoverySuggestion?.contains("Privacy") == true)
        }
        let bufferError = AudioCaptureError(source: .system, operation: "Cannot read audio buffers", status: -12737)
        #expect(bufferError.recoverySuggestion?.contains("Privacy") == false)
        #expect(bufferError.errorDescription?.contains("-12737") == true)
    }

    @Test func streamDeclineMapsToPermissionRecoveryOnly() {
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.userDeclined.rawValue)
        let permission = SystemAudioCapture.mapped(declined, operation: "Cannot start system audio capture")
        #expect(permission.recovery == .screenRecordingPermission)
        #expect(permission.recoverySuggestion?.contains("Screen & System Audio Recording") == true)
        #expect(permission.settingsURL?.absoluteString.hasSuffix("Privacy_ScreenCapture") == true)
        let audioFailure = NSError(domain: SCStreamErrorDomain, code: SCStreamError.failedToStartAudioCapture.rawValue)
        let retry = SystemAudioCapture.mapped(audioFailure, operation: "Cannot start system audio capture")
        #expect(retry.recovery == .retry)
        #expect(retry.status == OSStatus(SCStreamError.failedToStartAudioCapture.rawValue))
        #expect(retry.recoverySuggestion?.contains("Privacy") == false)
        #expect(retry.settingsURL == nil)
        #expect(AudioCaptureError(source: .microphone, operation: "Permission was denied", status: nil,
            recovery: .microphonePermission).settingsURL?.absoluteString.hasSuffix("Privacy_Microphone") == true)
    }
}
