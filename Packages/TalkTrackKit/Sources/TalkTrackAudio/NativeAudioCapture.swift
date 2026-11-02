@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

public enum CaptureSource: String, Codable, Sendable { case microphone, system }

public struct AudioPacket: Sendable {
    public let source: CaptureSource
    public let sampleRate: Double
    public let hostTime: UInt64
    public let sampleTime: Double
    public let samples: [Float]
    public init(source: CaptureSource, sampleRate: Double, hostTime: UInt64, sampleTime: Double, samples: [Float]) {
        self.source = source; self.sampleRate = sampleRate; self.hostTime = hostTime
        self.sampleTime = sampleTime; self.samples = samples
    }
}

public enum AudioCaptureRecovery: Sendable {
    case retry, microphonePermission, systemAudioPermission, selectedMicrophone
    /// A native audio call is hung; only restarting TalkTrack releases the device.
    case restartTalkTrack
}

public struct AudioCaptureError: Error, LocalizedError, Sendable {
    public let source: CaptureSource
    public let operation: String
    public let status: OSStatus?
    public let recovery: AudioCaptureRecovery
    /// A route or format change: the coordinator restarts only this source and
    /// keeps recording, leaving an explicit gap instead of failing the meeting.
    public let restartable: Bool
    public init(source: CaptureSource, operation: String, status: OSStatus?,
                recovery: AudioCaptureRecovery = .retry, restartable: Bool = false) {
        self.source = source; self.operation = operation; self.status = status
        self.recovery = recovery; self.restartable = restartable
    }
    public var errorDescription: String? {
        let origin = source == .microphone ? "Microphone" : "System audio"
        return "\(origin): \(operation)." + (status.map { " (OSStatus \($0))" } ?? "")
    }
    /// The Privacy & Security pane that resolves a permission failure, if any.
    public var settingsURL: URL? {
        switch recovery {
        case .microphonePermission: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        // System Audio Recording Only is listed in the Screen & System Audio Recording pane.
        case .systemAudioPermission:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .retry, .selectedMicrophone, .restartTalkTrack: nil
        }
    }
    public var recoverySuggestion: String? {
        switch recovery {
        case .microphonePermission:
            "Allow TalkTrack in System Settings > Privacy & Security > Microphone, then restart TalkTrack."
        case .systemAudioPermission:
            "Switch TalkTrack on under System Audio Recording Only in System Settings > Privacy & Security > Screen & System Audio Recording, then restart TalkTrack if recording is still refused."
        case .selectedMicrophone:
            "Connect it, or choose another microphone in TalkTrack Settings, then try recording again."
        case .restartTalkTrack:
            "Restart TalkTrack before recording again."
        case .retry:
            source == .microphone
                ? "Check the selected input device, then try recording again."
                : "Stop recording and try again. If the problem persists, check the audio output device."
        }
    }
}

public struct AudioInputDevice: Identifiable, Sendable {
    public let id: AudioObjectID
    public let name: String
    /// Persistent Core Audio UID; the object ID can change between launches.
    public let uid: String
}

public enum NativeAudioDevices {
    public static func inputs() throws -> [AudioInputDevice] {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size), .microphone, "Cannot list audio devices")
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices), .microphone, "Cannot read audio devices")
        return try devices.compactMap { id in
            var streams = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            return AudioInputDevice(id: id, name: try stringProperty(id, selector: kAudioObjectPropertyName, source: .microphone),
                                    uid: try stringProperty(id, selector: kAudioDevicePropertyDeviceUID, source: .microphone))
        }
    }

    /// Resolves a saved microphone at the moment capture starts. A device that
    /// is not connected fails the microphone source instead of silently
    /// recording from another input.
    public static func input(uid: String, name: String) throws -> AudioObjectID {
        guard let device = try inputs().first(where: { $0.uid == uid }) else {
            throw AudioCaptureError(source: .microphone, operation: "The selected microphone \u{201C}\(name)\u{201D} is not connected",
                                    status: nil, recovery: .selectedMicrophone)
        }
        return device.id
    }

    /// Calls `changed` on the main queue when devices are added or removed.
    /// Keep the returned observer; releasing it stops observation.
    public static func observe(_ changed: @escaping @MainActor @Sendable () -> Void) -> AudioDeviceObserver {
        AudioDeviceObserver(changed)
    }
}

public final class AudioDeviceObserver: @unchecked Sendable {
    private var address = property(kAudioHardwarePropertyDevices)
    private let block: AudioObjectPropertyListenerBlock

    init(_ changed: @escaping @MainActor @Sendable () -> Void) {
        block = { _, _ in MainActor.assumeIsolated { changed() } }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }
}

func property(_ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func check(_ status: OSStatus, _ source: CaptureSource, _ operation: String) throws {
    guard status == noErr else { throw AudioCaptureError(source: source, operation: operation, status: status) }
}
func stringProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector, source: CaptureSource) throws -> String {
    var address = property(selector)
    // HAL name/UID properties return a retained CFObject (SDK contract).
    // Store the pointer without ARC's implicit raw-pointer conversion and
    // consume its +1 ownership exactly once.
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout.size(ofValue: value))
    try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), source, "Cannot read audio device name")
    guard let value else { throw AudioCaptureError(source: source, operation: "Audio device returned no name", status: nil) }
    return value.takeRetainedValue() as String
}

/// Notifications may race teardown. Deliver at most one error per driver run,
/// and close before unregistering listeners; teardown never occurs in a native
/// notification callback (AVAudioEngine explicitly warns this can deadlock).
final class CaptureFailureRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private let sink: @Sendable (AudioCaptureError) -> Void
    init(_ sink: @escaping @Sendable (AudioCaptureError) -> Void) { self.sink = sink }
    func send(_ error: AudioCaptureError) {
        lock.withLock { if open { open = false; sink(error) } }
    }
    func close() { lock.withLock { open = false } }
}

public typealias MicrophoneIO = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

/// The blocking native side of microphone capture; every call runs on a `HALWorker`.
/// `prepare` creates the engine, selects the device and returns the input sample
/// rate; on failure it releases what it created. `start` installs the tap, reports
/// configuration changes until `stop`, and starts the engine. `stop` is idempotent.
public protocol MicrophoneEngineSession: AnyObject, Sendable {
    func prepare(deviceID: AudioObjectID?) throws -> Double
    func start(_ io: @escaping MicrophoneIO, configurationChanged: @escaping @Sendable () -> Void) throws
    func stop()
}

/// Per-source drivers produce bounded owned PCM packets. The recording pipeline
/// supplies a nonblocking sink; conversion, encoding and inference belong off
/// the hardware callback. No callback borrows Core Audio buffers after return.
///
/// `AVAudioEngine` calls run on one process-wide `HALWorker` with timeouts (design
/// D2), like the system tap: a start that waits for longer than 10 s fails visibly,
/// and a stop that hangs for 5 s is abandoned with its engine. While such a call has
/// not returned, later starts are refused with an error that suggests a restart.
public actor MicrophoneCapture {
    public struct Timing: Sendable {
        public var start: Duration = .seconds(10)
        public var stop: Duration = .seconds(5)
        public init() {}
    }

    static let sharedWorker = HALWorker(name: "local.talktrack.hal.microphone")
    private let worker: HALWorker
    private let timing: Timing
    private let makeSession: @Sendable () -> any MicrophoneEngineSession
    private let authorization: @Sendable () -> AVAuthorizationStatus
    private var session: (any MicrophoneEngineSession)?
    private var permission: CaptureReply<Bool>?
    private var startup: UUID?
    private var handoff: AudioPacketHandoff?
    private var failureRelay: CaptureFailureRelay?
    private var stopReply: CaptureReply<Void>?

    public init() {
        self.init(worker: Self.sharedWorker, timing: Timing()) { EngineMicrophoneSession() }
    }

    init(worker: HALWorker, timing: Timing,
         authorization: @escaping @Sendable () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
         makeSession: @escaping @Sendable () -> any MicrophoneEngineSession) {
        self.worker = worker; self.timing = timing; self.authorization = authorization; self.makeSession = makeSession
    }

    public func start(deviceID: AudioObjectID? = nil,
        receive: @escaping @Sendable (AudioPacket) -> Void,
        failure: @escaping @Sendable (AudioCaptureError) -> Void) async throws {
        guard session == nil, startup == nil, stopReply == nil else {
            throw AudioCaptureError(source: .microphone, operation: "Capture is already active", status: nil)
        }
        if let hung = worker.hungOperation { throw Self.mapped(HALWorkerError.busy(hungOperation: hung)) }
        let run = UUID()
        startup = run
        defer { if startup == run { startup = nil; permission = nil } }
        let allowed: Bool
        switch authorization() {
        case .authorized: allowed = true
        case .notDetermined:
            let reply = CaptureReply<Bool>()
            permission = reply
            allowed = try await withTaskCancellationHandler {
                AVCaptureDevice.requestAccess(for: .audio) { reply.resolve(.success($0)) }
                return try await reply.value()
            } onCancel: { reply.resolve(.failure(CancellationError())) }
        default: allowed = false
        }
        guard allowed else { throw AudioCaptureError(source: .microphone, operation: "Permission was denied", status: nil, recovery: .microphonePermission) }
        try Task.checkCancellation()
        // Stop may have run while the permission prompt was open.
        guard startup == run, session == nil else { throw CancellationError() }
        let next = makeSession()
        let prepared = StartClaim()
        let rate: Double
        do {
            rate = try await CaptureLog.timed("mic.prepare") { try await worker.run("Preparing the microphone", timeout: timing.start) {
                do {
                    let rate = try next.prepare(deviceID: deviceID)
                    // A prepare that returns after its timeout releases itself: its caller gave up.
                    if !prepared.markStarted() { next.stop() }
                    return rate
                } catch { next.stop(); throw error }
            } }
        } catch {
            _ = prepared.markAbandoned()
            throw Self.mapped(error)
        }
        guard startup == run else { next.stop(); throw CancellationError() }
        let relay = CaptureFailureRelay(failure)
        let packets = AudioPacketHandoff(source: .microphone, sampleRate: rate, receive: receive, failure: relay.send)
        session = next; handoff = packets; failureRelay = relay
        let claim = StartClaim()
        do {
            try await CaptureLog.timed("mic.start") { try await worker.run("Starting the microphone", timeout: timing.start) {
                do {
                    try next.start({ buffer, time in MicrophoneBuffers.consume(buffer, time, rate: rate, into: packets) }) {
                        relay.send(AudioCaptureError(source: .microphone,
                            operation: "The input device or its format changed", status: nil, restartable: true))
                    }
                } catch {
                    if !claim.markStarted() { next.stop() }
                    throw error
                }
                // A start that returns after its timeout stops itself: its caller gave up.
                if !claim.markStarted() { next.stop() }
            } }
            try Task.checkCancellation()
        } catch {
            if case .timedOut = error as? HALWorkerError, claim.markAbandoned() {
                // The hung worker owns the engine now and releases it when the start returns.
                relay.close(); session = nil; handoff = nil; failureRelay = nil
                await packets.finish()
                throw Self.mapped(error)
            }
            try? await stop()
            if error is CancellationError { throw error }
            throw Self.mapped(error)
        }
    }

    /// Returns after callbacks have quiesced, or after the stop timeout with the
    /// engine abandoned: late callbacks are then dropped by the finished handoff.
    public func stop() async throws {
        if let stopReply { return try await stopReply.value() }
        let reply = CaptureReply<Void>(); stopReply = reply
        defer { stopReply = nil }
        startup = nil
        permission?.resolve(.failure(CancellationError())); permission = nil
        failureRelay?.close(); failureRelay = nil
        var problem: AudioCaptureError?
        if let current = session {
            session = nil
            do {
                try await CaptureLog.timed("mic.stop") {
                    try await worker.run("Stopping the microphone", timeout: timing.stop) { current.stop() }
                }
            } catch HALWorkerError.timedOut(_, let seconds) {
                CaptureLog.capture.error("mic.stop abandoned")
                problem = AudioCaptureError(source: .microphone, operation:
                    "Stopping the microphone did not finish within \(seconds.formatted(.number.precision(.fractionLength(0...1)))) s; the recording was saved with the audio received so far",
                    status: nil, recovery: .restartTalkTrack)
            } catch {
                problem = Self.mapped(error)
            }
        }
        let packets = handoff; handoff = nil
        await packets?.finish()
        if let problem { reply.resolve(.failure(problem)); throw problem }
        reply.resolve(.success(()))
    }

    static func mapped(_ error: Error) -> AudioCaptureError {
        switch error {
        case let error as AudioCaptureError: return error
        case is CancellationError:
            return AudioCaptureError(source: .microphone, operation: "Microphone startup was cancelled", status: nil)
        case HALWorkerError.busy(let operation):
            return AudioCaptureError(source: .microphone, operation:
                "\(operation) has not returned since an earlier recording", status: nil, recovery: .restartTalkTrack)
        case let error as HALWorkerError:
            return AudioCaptureError(source: .microphone, operation: (error.errorDescription ?? "\(error)")
                + "; try again, or restart TalkTrack if it keeps failing", status: nil)
        default:
            return AudioCaptureError(source: .microphone, operation: "Cannot start input: \(error.localizedDescription)", status: nil)
        }
    }

    #if DEBUG
    /// Review hook: the next real engine stop blocks the worker for `seconds`, as a
    /// stalled `AVAudioEngine.stop` would.
    public static func hangNextStopForReview(seconds: Double) { EngineMicrophoneSession.reviewStopHang.withLock { $0 = seconds } }
    #endif
}

/// Copies one tap buffer into the bounded handoff; validates format and host time.
enum MicrophoneBuffers {
    static func consume(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime, rate: Double, into packets: AudioPacketHandoff) {
        guard time.isHostTimeValid, buffer.format.sampleRate == rate, let channels = buffer.floatChannelData else {
            packets.interrupt(); return
        }
        let frames = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
        guard frames > 0 else { return }
        packets.enqueue(frames: frames, channels: count, hostTime: time.hostTime,
                        sampleTime: time.isSampleTimeValid ? Double(time.sampleTime) : 0) { frame, channel in
            buffer.format.isInterleaved ? channels[0][frame * count + channel] : channels[channel][frame]
        }
    }
}

/// One `AVAudioEngine` input run. Only the microphone worker thread calls it.
final class EngineMicrophoneSession: MicrophoneEngineSession, @unchecked Sendable {
    static let reviewStopHang = Mutex<Double?>(nil)
    private var engine: AVAudioEngine?
    private var format: AVAudioFormat?
    private var tapInstalled = false
    private var configurationObserver: (any NSObjectProtocol)?

    func prepare(deviceID: AudioObjectID?) throws -> Double {
        let next = AVAudioEngine()
        engine = next
        let input = next.inputNode
        if let deviceID {
            guard let unit = input.audioUnit else { throw AudioCaptureError(source: .microphone, operation: "Input device is unavailable", status: nil) }
            var selected = deviceID
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout.size(ofValue: selected))), .microphone, "Cannot select input device")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              (1...8).contains(format.channelCount), format.commonFormat == .pcmFormatFloat32 else {
            throw AudioCaptureError(source: .microphone, operation: "The input format is unsupported or the device is unavailable", status: nil)
        }
        self.format = format
        return format.sampleRate
    }

    func start(_ io: @escaping MicrophoneIO, configurationChanged: @escaping @Sendable () -> Void) throws {
        guard let engine, let format else { throw AudioCaptureError(source: .microphone, operation: "Input device is unavailable", status: nil) }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { io($0, $1) }
        tapInstalled = true
        engine.prepare()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in configurationChanged() }
        do { try engine.start() } catch {
            throw AudioCaptureError(source: .microphone, operation: "Cannot start input: \(error.localizedDescription)", status: nil)
        }
    }

    func stop() {
        if let hang = Self.reviewStopHang.withLock({ value -> Double? in defer { value = nil }; return value }) {
            Thread.sleep(forTimeInterval: hang)
        }
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard let engine else { return }
        self.engine = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }
}
