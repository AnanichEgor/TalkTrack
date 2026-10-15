@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

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
    case retry, microphonePermission, screenRecordingPermission, selectedMicrophone
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
        case .screenRecordingPermission: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .retry, .selectedMicrophone: nil
        }
    }
    public var recoverySuggestion: String? {
        switch recovery {
        case .microphonePermission:
            "Allow TalkTrack in System Settings > Privacy & Security > Microphone, then restart TalkTrack."
        case .screenRecordingPermission:
            "Allow TalkTrack under Screen & System Audio Recording in System Settings > Privacy & Security, then restart TalkTrack."
        case .selectedMicrophone:
            "Connect it, or choose another microphone in TalkTrack Settings, then try recording again."
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

private func property(_ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
private func check(_ status: OSStatus, _ source: CaptureSource, _ operation: String) throws {
    guard status == noErr else { throw AudioCaptureError(source: source, operation: operation, status: status) }
}
private func stringProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector, source: CaptureSource) throws -> String {
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
private final class CaptureFailureRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private let sink: @Sendable (AudioCaptureError) -> Void
    init(_ sink: @escaping @Sendable (AudioCaptureError) -> Void) { self.sink = sink }
    func send(_ error: AudioCaptureError) {
        lock.withLock { if open { open = false; sink(error) } }
    }
    func close() { lock.withLock { open = false } }
}

/// Per-source drivers produce bounded owned PCM packets. The recording pipeline
/// supplies a nonblocking sink; conversion, encoding and inference belong off
/// the hardware callback. No callback borrows Core Audio buffers after return.
public actor MicrophoneCapture {
    private nonisolated let executor = AudioDriverExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var engine: AVAudioEngine?
    private var permission: CaptureReply<Bool>?
    private var startup: UUID?
    private var configurationObserver: (any NSObjectProtocol)?
    private var handoff: AudioPacketHandoff?
    private var failureRelay: CaptureFailureRelay?
    private var stopping = false
    private var stopReply: CaptureReply<Void>?
    public init() {}

    public func start(deviceID: AudioObjectID? = nil,
        receive: @escaping @Sendable (AudioPacket) -> Void,
        failure: @escaping @Sendable (AudioCaptureError) -> Void) async throws {
        guard engine == nil, startup == nil, !stopping else { throw AudioCaptureError(source: .microphone, operation: "Capture is already active", status: nil) }
        let run = UUID()
        startup = run
        defer { if startup == run { startup = nil; permission = nil } }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
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
        // Another start may have entered while the permission prompt was open.
        guard startup == run, engine == nil else { throw CancellationError() }
        let next = AVAudioEngine()
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
        let rate = format.sampleRate
        let relay = CaptureFailureRelay(failure)
        let packets = AudioPacketHandoff(source: .microphone, sampleRate: rate, receive: receive, failure: relay.send)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
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
        do {
            next.prepare()
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: next, queue: nil) { _ in
                relay.send(AudioCaptureError(source: .microphone,
                    operation: "The input device or its format changed", status: nil, restartable: true))
            }
            try next.start()
            try Task.checkCancellation()
            engine = next; handoff = packets; failureRelay = relay
        } catch {
            relay.close()
            if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
            configurationObserver = nil
            next.stop(); input.removeTap(onBus: 0)
            await packets.finish()
            if error is CancellationError { throw error }
            throw AudioCaptureError(source: .microphone, operation: "Cannot start input: \(error.localizedDescription)", status: nil)
        }
    }

    public func stop() async {
        if let stopReply { _ = try? await stopReply.value(); return }
        let completion = CaptureReply<Void>()
        stopReply = completion
        stopping = true
        defer { stopping = false; stopReply = nil; completion.resolve(.success(())) }
        startup = nil
        permission?.resolve(.failure(CancellationError())); permission = nil
        failureRelay?.close(); failureRelay = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let current = engine {
            engine = nil
            current.stop()
            current.inputNode.removeTap(onBus: 0)
        }
        let packets = handoff; handoff = nil
        await packets?.finish()
    }
}
