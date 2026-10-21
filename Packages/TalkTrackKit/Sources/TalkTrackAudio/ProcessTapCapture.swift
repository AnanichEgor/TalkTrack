@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

public typealias SystemTapIO = @Sendable (UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>) -> Void

/// The blocking native side of a system tap; every call runs on a `HALWorker`.
/// `prepare` creates the tap and device and returns the sample rate; on failure it
/// releases what it created. `start` also reports output route changes (default
/// output device, device lost) until `stop`, which is idempotent and releases everything.
public protocol SystemTapSession: AnyObject, Sendable {
    func prepare() throws -> Double
    func start(_ io: @escaping SystemTapIO, routeChanged: @escaping @Sendable (String) -> Void) throws
    func stop() throws
}

/// System audio through a Core Audio process tap of every process except TalkTrack
/// (design D3), so TalkTrack's playback and its access check tone are never recorded.
/// Needs System Audio Recording Only; a denied tap still starts and delivers zeros,
/// so `SystemAudioAccess` must confirm access before Record (design D4).
///
/// HAL calls run on one process-wide `HALWorker` with timeouts (design D2): a start
/// that waits on the system for longer than 10 s fails visibly, and a teardown that
/// hangs for 5 s is abandoned with its objects. While such a call has not returned,
/// later starts are refused with an error that suggests restarting TalkTrack.
public actor ProcessTapCapture {
    public struct Timing: Sendable {
        public var prepare: Duration = .seconds(10)
        public var start: Duration = .seconds(10)
        public var teardown: Duration = .seconds(5)
        public init() {}
    }

    static let sharedWorker = HALWorker(name: "local.talktrack.hal.system-audio")
    private let worker: HALWorker
    private let timing: Timing
    private let makeSession: @Sendable () -> any SystemTapSession
    private var session: (any SystemTapSession)?
    private var handoff: AudioPacketHandoff?
    private var relay: CaptureFailureRelay?
    private var starting = false
    private var stopReply: CaptureReply<Void>?

    public init() {
        self.init(worker: Self.sharedWorker, timing: Timing()) { GlobalTapSession() }
    }

    init(worker: HALWorker, timing: Timing, makeSession: @escaping @Sendable () -> any SystemTapSession) {
        self.worker = worker; self.timing = timing; self.makeSession = makeSession
    }

    public func start(receive: @escaping @Sendable (AudioPacket) -> Void,
                      failure: @escaping @Sendable (AudioCaptureError) -> Void) async throws {
        guard session == nil, !starting, stopReply == nil else {
            throw AudioCaptureError(source: .system, operation: "Capture is already active", status: nil)
        }
        if let hung = worker.hungOperation { throw Self.mapped(HALWorkerError.busy(hungOperation: hung)) }
        starting = true
        defer { starting = false }
        let next = makeSession()
        let rate: Double
        do {
            rate = try await worker.run("Preparing system audio capture", timeout: timing.prepare) {
                do { return try next.prepare() } catch { try? next.stop(); throw error }
            }
        } catch {
            throw Self.mapped(error)
        }
        let relay = CaptureFailureRelay(failure)
        let packets = AudioPacketHandoff(source: .system, sampleRate: rate, receive: receive, failure: relay.send)
        session = next; handoff = packets; self.relay = relay
        let claim = StartClaim()
        do {
            try await worker.run("Starting system audio capture", timeout: timing.start) {
                // A route change restarts only the system source with an explicit gap;
                // the coordinator fails the recording after too many (design D3).
                try next.start({ list, time in SystemTapBuffers.consume(list, time, into: packets) }) { change in
                    relay.send(AudioCaptureError(source: .system, operation: change, status: nil, restartable: true))
                }
                // A start that returns after its timeout stops itself: its caller gave up.
                if !claim.markStarted() { try? next.stop() }
            }
            try Task.checkCancellation()
        } catch {
            if case .timedOut = error as? HALWorkerError, claim.markAbandoned() {
                // The hung worker owns the session now and releases it when the start returns.
                relay.close(); session = nil; handoff = nil; self.relay = nil
                await packets.finish()
                throw Self.mapped(error)
            }
            try? await stop()
            if error is CancellationError { throw error }
            throw Self.mapped(error)
        }
    }

    public func stop() async throws {
        if let stopReply { return try await stopReply.value() }
        let reply = CaptureReply<Void>(); stopReply = reply
        defer { stopReply = nil }
        relay?.close(); relay = nil
        var problem: AudioCaptureError?
        if let current = session {
            do {
                try await worker.run("Stopping system audio capture", timeout: timing.teardown) { try current.stop() }
                session = nil
            } catch HALWorkerError.timedOut(_, let seconds) {
                // Abandoned with the hung worker: callbacks may still run, but the
                // handoff below stops accepting them. Committed audio is kept.
                session = nil
                problem = AudioCaptureError(source: .system, operation:
                    "Stopping system audio did not finish within \(seconds.formatted(.number.precision(.fractionLength(0...1)))) s; the recording was saved. Restart TalkTrack before recording again",
                    status: nil)
            } catch {
                problem = Self.mapped(error)
            }
        }
        if session == nil {
            let packets = handoff; handoff = nil
            await packets?.finish()
        }
        if let problem { reply.resolve(.failure(problem)); throw problem }
        reply.resolve(.success(()))
    }

    static func mapped(_ error: Error) -> AudioCaptureError {
        switch error {
        case let error as AudioCaptureError: return error
        case HALWorkerError.busy(let operation):
            return AudioCaptureError(source: .system, operation:
                "\(operation) has not returned since an earlier recording; restart TalkTrack to record system audio", status: nil)
        case let error as HALWorkerError:
            return AudioCaptureError(source: .system, operation: (error.errorDescription ?? "\(error)")
                + "; try again, or restart TalkTrack if it keeps failing", status: nil)
        default:
            return AudioCaptureError(source: .system, operation: error.localizedDescription, status: nil)
        }
    }
}

/// Copies one IOProc input into the bounded handoff; validates shape and host time.
/// Runs on the HAL callback queue and never retains the borrowed buffers.
enum SystemTapBuffers {
    static func consume(_ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>,
                        into packets: AudioPacketHandoff) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        guard frames > 0 else { return }
        guard time.pointee.mFlags.contains(.hostTimeValid), time.pointee.mHostTime > 0 else {
            packets.interrupt(); return
        }
        let channelCount = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, buffer.mDataByteSize == frames * channels * MemoryLayout<Float>.size, buffer.mData != nil else {
                packets.interrupt(); return
            }
        }
        packets.enqueue(frames: frames, channels: channelCount, hostTime: time.pointee.mHostTime,
                        sampleTime: time.pointee.mFlags.contains(.sampleTimeValid) ? time.pointee.mSampleTime : 0) { frame, channel in
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

/// A private global mono tap excluding TalkTrack's process, in a private aggregate
/// device with drift compensation; 32-bit float little-endian only.
final class GlobalTapSession: SystemTapSession, @unchecked Sendable {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let callbackQueue = DispatchQueue(label: "local.talktrack.system-capture", qos: .userInteractive)
    private let monitorQueue = DispatchQueue(label: "local.talktrack.audio-route", qos: .userInitiated)
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    func prepare() throws -> Double {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [try ownProcessObject()])
        description.uuid = UUID()
        description.name = "TalkTrack System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), .system, "Cannot create the system audio tap")
        let tapUID = try stringProperty(tap, selector: kAudioTapPropertyUID, source: .system)
        let definition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TalkTrack Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(definition as CFDictionary, &aggregate), .system,
                  "Cannot create the system capture device")
        var format = AudioStreamBasicDescription()
        var address = property(kAudioDevicePropertyStreamFormat, scope: kAudioDevicePropertyScopeInput)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &format), .system,
                  "Cannot read the system capture format")
        guard Self.supported(format) else {
            throw AudioCaptureError(source: .system, operation: "Unsupported system audio format (rate \(format.mSampleRate), bits \(format.mBitsPerChannel), flags \(format.mFormatFlags))", status: nil)
        }
        return format.mSampleRate
    }

    static func supported(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 && format.mBitsPerChannel == 32
            && format.mSampleRate.isFinite && format.mSampleRate > 0
    }

    func start(_ io: @escaping SystemTapIO, routeChanged: @escaping @Sendable (String) -> Void) throws {
        try listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) {
            routeChanged("The default output device changed")
        }
        try listen(aggregate, kAudioDevicePropertyDeviceIsAlive) { routeChanged("The system capture device was lost") }
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, callbackQueue) { _, input, time, _, _ in
            io(input, time)
        }, .system, "Cannot register the system capture callback")
        guard let ioProc else { throw AudioCaptureError(source: .system, operation: "System capture callback is unavailable", status: nil) }
        try check(AudioDeviceStart(aggregate, ioProc), .system, "Cannot start system capture")
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ changed: @escaping @Sendable () -> Void) throws {
        var address = property(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        try check(AudioObjectAddPropertyListenerBlock(object, &address, monitorQueue, block), .system,
                  "Cannot monitor the system audio route")
        listeners.append((object, address, block))
    }

    func stop() throws {
        var failure: AudioCaptureError?
        func remember(_ status: OSStatus, _ operation: String) {
            if status != noErr, failure == nil { failure = AudioCaptureError(source: .system, operation: operation, status: status) }
        }
        for var listener in listeners {
            _ = AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, monitorQueue, listener.block)
        }
        listeners = []
        if let ioProc, aggregate != kAudioObjectUnknown {
            remember(AudioDeviceStop(aggregate, ioProc), "Cannot stop system capture; retry Stop")
            let destroyed = AudioDeviceDestroyIOProcID(aggregate, ioProc)
            if destroyed == noErr { self.ioProc = nil } else { remember(destroyed, "Cannot remove the system capture callback; retry Stop") }
        }
        if aggregate != kAudioObjectUnknown {
            let result = AudioHardwareDestroyAggregateDevice(aggregate)
            if result == noErr { aggregate = AudioObjectID(kAudioObjectUnknown); ioProc = nil }
            else { remember(result, "Cannot release the system capture device; retry Stop") }
        }
        if tap != kAudioObjectUnknown {
            let result = AudioHardwareDestroyProcessTap(tap)
            if result == noErr { tap = AudioObjectID(kAudioObjectUnknown) }
            else { remember(result, "Cannot release the system audio tap; retry Stop") }
        }
        callbackQueue.sync {}
        if let failure { throw failure }
    }
}
