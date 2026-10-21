import AVFoundation
import CoreAudio
import Foundation
import os
import TalkTrackAudio

/// What one dictation recorded, in memory only.
public struct DictationCapture: Sendable {
    /// Mono 16 kHz audio, including the trailing tail.
    public var samples: [Float]
    /// Audio recorded until release, without the tail.
    public var spokenSeconds: Double
    public var tailSeconds: Double
    public var reachedLimit: Bool
    /// The device stopped delivering audio during the recording.
    public var deviceFailed = false
}

/// Microphone access as the dictation session needs it; `MicrophoneCapture`
/// in the app, a fake in tests.
public protocol DictationMicrophoneDriver: Sendable {
    func start(deviceID: AudioObjectID?, receive: @escaping @Sendable (AudioPacket) -> Void,
               failure: @escaping @Sendable (AudioCaptureError) -> Void) async throws
    func stop() async
}

extension MicrophoneCapture: DictationMicrophoneDriver {}

/// The controller's view of a dictation recording.
public protocol DictationAudioSource: Sendable {
    /// Starts recording; `limitReached` is called once at the maximum length.
    func start(maximumSeconds: Int, limitReached: @escaping @Sendable () -> Void) async throws
    /// Keeps recording through the trailing tail, then stops and returns the audio.
    func finish() async -> DictationCapture
    /// Stops and discards the audio.
    func cancel() async
    /// Current input level (0...1) for the HUD waveform.
    func level() -> Float
}

/// After release, capture continues for at least 80 ms and stops once the new
/// audio is quiet, at most 400 ms after release, so a last word is not cut.
public enum DictationTail {
    public static let minimumSeconds = 0.08
    public static let maximumSeconds = 0.4
    /// The window whose level decides that speech has ended.
    static let windowSeconds = 0.05
    /// About −45 dBFS on `AudioLevelMeter`'s scale.
    static let quietLevel: Float = 0.25

    public static func isComplete(_ tail: ArraySlice<Float>, sampleRate: Double) -> Bool {
        let seconds = Double(tail.count) / sampleRate
        if seconds >= maximumSeconds { return true }
        guard seconds >= minimumSeconds else { return false }
        let window = tail.suffix(max(1, Int(windowSeconds * sampleRate)))
        let rms = (window.reduce(0) { $0 + $1 * $1 } / Float(window.count)).squareRoot()
        return AudioLevelMeter.normalized(rms) < quietLevel
    }
}

/// One in-memory microphone recording per dictation, from the device chosen in
/// Settings ▸ Audio. Nothing is written to disk.
public actor DictationMicrophone: DictationAudioSource {
    public static let minimumSeconds = 0.25

    private let driver: DictationMicrophoneDriver
    private let resolveDevice: @Sendable () throws -> AudioObjectID?
    private let meter = AudioLevelMeter()
    private let buffer = SampleBuffer()
    private var running = false

    public init(driver: DictationMicrophoneDriver = MicrophoneCapture(),
                resolveDevice: @escaping @Sendable () throws -> AudioObjectID? = DictationMicrophone.selectedDevice) {
        self.driver = driver
        self.resolveDevice = resolveDevice
    }

    /// The Settings ▸ Audio microphone, resolved now; a disconnected one throws
    /// an error naming it instead of recording from another input.
    @Sendable public static func selectedDevice() throws -> AudioObjectID? {
        try ProcessingPreferences.microphone().map { try NativeAudioDevices.input(uid: $0.uid, name: $0.name) }
    }

    public func start(maximumSeconds: Int, limitReached: @escaping @Sendable () -> Void) async throws {
        guard !running else { throw AudioCaptureError(source: .microphone, operation: "Capture is already active", status: nil) }
        let device = try resolveDevice()
        buffer.reset(maximumSeconds: Double(maximumSeconds), limitReached: limitReached)
        meter.reset()
        running = true
        do {
            try await driver.start(deviceID: device, receive: { [buffer, meter] packet in
                meter.record(packet)
                buffer.append(packet)
            }, failure: { [buffer] _ in buffer.fail() })
        } catch {
            running = false
            buffer.reset(maximumSeconds: 0, limitReached: {})
            throw error
        }
    }

    public func finish() async -> DictationCapture {
        guard running else { return DictationCapture(samples: [], spokenSeconds: 0, tailSeconds: 0, reachedLimit: false) }
        // Packets stop arriving on a failed device; the wall clock bounds the wait.
        await buffer.waitForTail(timeout: .milliseconds(Int(DictationTail.maximumSeconds * 1000) + 150))
        await driver.stop()
        running = false
        let recorded = buffer.take()
        let samples = (try? Self.resample(recorded.samples, from: recorded.sampleRate)) ?? []
        return DictationCapture(samples: samples, spokenSeconds: Double(recorded.spoken) / recorded.sampleRate,
            tailSeconds: Double(recorded.samples.count - recorded.spoken) / recorded.sampleRate, reachedLimit: recorded.reachedLimit,
            deviceFailed: recorded.failed)
    }

    public func cancel() async {
        guard running else { return }
        await driver.stop()
        running = false
        _ = buffer.take()
    }

    public nonisolated func level() -> Float { meter.read().microphone }

    /// Whether `finish` has marked the release (tests deliver the tail after it).
    nonisolated var isReleased: Bool { buffer.isReleased }

    static func resample(_ samples: [Float], from rate: Double) throws -> [Float] {
        let target = Double(DictationAudio.sampleRate)
        guard !samples.isEmpty, rate > 0 else { return [] }
        guard rate != target else { return samples }
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output),
              let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
              let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(samples.count) * target / rate) + 1024)
        else { throw AudioResamplingError.conversionFailed("The converter is unavailable.") }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        nonisolated(unsafe) var supplied = false
        var failure: NSError?
        let status = converter.convert(to: result, error: &failure) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true
            state.pointee = .haveData
            return source
        }
        guard status != .error, failure == nil else { throw AudioResamplingError.conversionFailed("The converter is unavailable.") }
        return Array(UnsafeBufferPointer(start: result.floatChannelData![0], count: Int(result.frameLength))).map { min(1, max(-1, $0)) }
    }
}

/// Written from the audio executor without waiting; the session reads it after
/// stopping the driver.
private final class SampleBuffer: Sendable {
    private struct State {
        var samples: [Float] = []
        var sampleRate: Double = 48_000
        var limitFrames = Int.max
        var limitReached: @Sendable () -> Void = {}
        var reachedLimit = false
        var release: Int?
        var failed = false
        /// The tail ended; packets until the driver stops are not kept.
        var closed = false
        var tailWaiter: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func reset(maximumSeconds: Double, limitReached: @escaping @Sendable () -> Void) {
        let waiter = state.withLock { state in
            let waiter = state.tailWaiter
            state = State()
            state.limitFrames = Int(maximumSeconds * state.sampleRate)
            state.limitReached = limitReached
            return waiter
        }
        waiter?.resume()
    }

    func append(_ packet: AudioPacket) {
        guard packet.sampleRate > 0 else { return }
        let (notify, waiter) = state.withLock { state -> ((@Sendable () -> Void)?, CheckedContinuation<Void, Never>?) in
            if state.samples.isEmpty, state.sampleRate != packet.sampleRate {
                // The limit was computed for the assumed rate.
                state.limitFrames = Int(Double(state.limitFrames) / state.sampleRate * packet.sampleRate)
                state.sampleRate = packet.sampleRate
            }
            guard packet.sampleRate == state.sampleRate, !state.closed else { return (nil, nil) }
            if let release = state.release {
                // Only the tail is kept after release; the limit no longer applies.
                state.samples += packet.samples
                guard DictationTail.isComplete(state.samples[release...], sampleRate: state.sampleRate) else { return (nil, nil) }
                state.closed = true
                defer { state.tailWaiter = nil }
                return (nil, state.tailWaiter)
            }
            let room = state.limitFrames - state.samples.count
            guard room > 0 else { return (nil, nil) }
            state.samples += packet.samples.prefix(room)
            guard state.samples.count >= state.limitFrames, !state.reachedLimit else { return (nil, nil) }
            state.reachedLimit = true
            return (state.limitReached, nil)
        }
        notify?()
        waiter?.resume()
    }

    /// A failed device delivers nothing more; finishing proceeds immediately.
    func fail() {
        let waiter = state.withLock { state in
            defer { state.tailWaiter = nil }
            state.failed = true
            state.closed = true
            state.release = state.release ?? state.samples.count
            return state.tailWaiter
        }
        waiter?.resume()
    }

    func waitForTail(timeout: Duration) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            let waiter = self?.state.withLock { state in
                defer { state.tailWaiter = nil; state.closed = true }
                return state.tailWaiter
            }
            waiter?.resume()
        }
        defer { timer.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let complete = state.withLock { state -> Bool in
                let release = state.release ?? state.samples.count
                state.release = release
                // A recording that hit its limit has nothing more to wait for.
                if state.reachedLimit || state.closed
                    || DictationTail.isComplete(state.samples[release...], sampleRate: state.sampleRate) {
                    state.closed = true
                    return true
                }
                state.tailWaiter = continuation
                return false
            }
            if complete { continuation.resume() }
        }
    }

    var isReleased: Bool { state.withLock { $0.release != nil } }

    func take() -> (samples: [Float], sampleRate: Double, spoken: Int, reachedLimit: Bool, failed: Bool) {
        state.withLock { state in
            let value = (state.samples, state.sampleRate, min(state.release ?? state.samples.count, state.samples.count),
                         state.reachedLimit, state.failed)
            state.samples = []
            return value
        }
    }
}
