@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

public enum SystemAudioAccessState: String, Codable, Sendable {
    /// The tap delivered TalkTrack's own check tone.
    case allowed
    /// The tap delivered only exact zeros while the tone played.
    case denied
    /// No samples arrived, the tap start timed out, or the check could not run.
    case undetermined
}

/// What one access check observed; timings are seconds from the check's start.
public struct SystemAudioAccessReport: Codable, Sendable {
    public var state: SystemAudioAccessState
    /// The launch's earlier Allowed result was reused; nothing ran.
    public var cached = false
    public var startSeconds: Double?
    public var firstBufferSeconds: Double?
    public var buffers = 0
    public var peak: Float = 0
    public var teardownSeconds: Double?
    public var teardownTimedOut = false
    /// Why the check could not decide, when a call failed or timed out.
    public var detail: String?
}

/// The native side of an access check. Both calls block and run on a `HALWorker`.
/// `start` plays TalkTrack's own check tone and taps it; on failure it releases
/// what it created before throwing. `stop` is idempotent.
public protocol SystemAudioAccessProbe: AnyObject, Sendable {
    func start(deliver: @escaping @Sendable (UnsafeBufferPointer<Float>) -> Void) throws
    func stop() throws
}

/// Confirms System Audio Recording Only access with an active check (design D1):
/// a private global tap while TalkTrack plays an inaudible tone. HAL status codes are
/// `noErr` whether or not access is allowed, and the mix is silent when nothing plays,
/// so only a signal TalkTrack controls can tell allowed from denied. macOS shows no
/// prompt for taps: never asked and switched off both deliver exact zeros (denied). Allowed is cached for the launch, because macOS applies
/// grant changes after restart; denied and undetermined are checked again.
public actor SystemAudioAccess {
    public struct Timing: Sendable {
        /// Bounds the tap start, which blocks while the macOS prompt is open.
        /// The first start after launch took 2.8 s on macOS 27.0.1, later ones 0.5 s.
        public var start: Duration = .seconds(5)
        /// How long to wait for samples after the start returned.
        public var listen: Duration = .seconds(2.5)
        /// Exact zeros for this long after the first buffer mean denied.
        public var zeroSpan: Duration = .seconds(1)
        public var teardown: Duration = .seconds(5)
        public var poll: Duration = .milliseconds(20)
        public init() {}
    }

    /// Any sample louder than this is the check tone (amplitude 1e-4).
    static let signalThreshold: Float = 1e-6
    public static let shared = SystemAudioAccess()

    private let makeProbe: @Sendable () -> any SystemAudioAccessProbe
    private let timing: Timing
    private var allowed = false
    private var running: Task<SystemAudioAccessReport, Never>?

    public init(timing: Timing = Timing(),
                makeProbe: @escaping @Sendable () -> any SystemAudioAccessProbe = { ProcessTapAccessProbe() }) {
        self.timing = timing; self.makeProbe = makeProbe
    }

    /// Allowed in this launch, without running a check.
    public var isAllowed: Bool { allowed }

    /// Runs the check and throws a System Audio Recording Only error unless it is allowed.
    public func requireAllowed() async throws {
        let report = await check()
        guard report.state != .allowed else { return }
        throw AudioCaptureError(source: .system, operation: report.state == .denied
            ? "System Audio Recording Only access is not allowed"
            : "System Audio Recording Only access could not be confirmed" + (report.detail.map { " (\($0))" } ?? ""),
            status: nil, recovery: .systemAudioPermission)
    }

    /// Runs the check, or joins one in progress. Never throws: failures are `undetermined`.
    public func check() async -> SystemAudioAccessReport {
        if allowed { return SystemAudioAccessReport(state: .allowed, cached: true) }
        if let running { return await running.value }
        let task = Task.detached { [makeProbe, timing] in
            await Self.run(probe: makeProbe(), timing: timing)
        }
        running = task
        let report = await task.value
        running = nil
        if report.state == .allowed { allowed = true }
        return report
    }

    private static func run(probe: any SystemAudioAccessProbe, timing: Timing) async -> SystemAudioAccessReport {
        let clock = ContinuousClock(), began = clock.now
        func elapsed() -> Double { (clock.now - began).seconds }
        let worker = HALWorker(name: "local.talktrack.hal.access-check")
        let signal = SignalLog(clock: clock), claim = StartClaim()
        var report = SystemAudioAccessReport(state: .undetermined)
        do {
            try await worker.run("Starting the system audio access check", timeout: timing.start) {
                do { try probe.start(deliver: signal.record) } catch { try? probe.stop(); throw error }
                // A start that returns after its timeout stops itself: nobody else will.
                if !claim.markStarted() { try? probe.stop() }
            }
            report.startSeconds = elapsed()
        } catch {
            report.detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if case .timedOut = error as? HALWorkerError, claim.markAbandoned() { return report }
            // The start returned just as it timed out, or failed: release what remains.
        }
        if report.startSeconds != nil {
            let listenedFrom = clock.now
            while report.state == .undetermined && clock.now - listenedFrom < timing.listen {
                let seen = signal.snapshot
                if seen.peak > signalThreshold { report.state = .allowed }
                else if let first = seen.first, clock.now - first >= timing.zeroSpan { report.state = .denied }
                else { try? await Task.sleep(for: timing.poll) }
            }
        }
        let seen = signal.snapshot
        report.buffers = seen.buffers
        report.peak = seen.peak
        report.firstBufferSeconds = seen.first.map { ($0 - began).seconds }
        if report.startSeconds != nil, report.state == .undetermined, report.detail == nil {
            report.detail = seen.buffers == 0 ? "The system audio tap delivered no samples"
                : "The system audio tap delivered too few samples to decide"
        }
        let teardownBegan = clock.now
        for _ in 0..<50 {
            do {
                try await worker.run("Stopping the system audio access check", timeout: timing.teardown) { try probe.stop() }
                report.teardownSeconds = (clock.now - teardownBegan).seconds
                break
            } catch HALWorkerError.busy {
                // A late start is still returning on the worker; it clears in moments.
                try? await Task.sleep(for: .milliseconds(10))
            } catch HALWorkerError.timedOut {
                report.teardownTimedOut = true
                break
            } catch {
                report.teardownSeconds = (clock.now - teardownBegan).seconds
                break
            }
        }
        return report
    }
}

/// Collects what the check tap delivers; written on the HAL callback queue.
private final class SignalLog: @unchecked Sendable {
    struct Snapshot { var buffers = 0; var peak: Float = 0; var first: ContinuousClock.Instant? }
    private let lock = NSLock()
    private let clock: ContinuousClock
    private var current = Snapshot()
    init(clock: ContinuousClock) { self.clock = clock }

    func record(_ samples: UnsafeBufferPointer<Float>) {
        var peak: Float = 0
        for sample in samples where sample.isFinite { peak = max(peak, abs(sample)) }
        let now = clock.now
        lock.withLock {
            current.buffers += 1
            current.peak = max(current.peak, peak)
            if current.first == nil { current.first = now }
        }
    }
    var snapshot: Snapshot { lock.withLock { current } }
}

/// Decides who stops a probe whose start raced its timeout.
final class StartClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var state = 0 // 0 pending, 1 started, 2 abandoned
    /// False when the caller has already given up on this start.
    func markStarted() -> Bool { lock.withLock { if state == 0 { state = 1 }; return state == 1 } }
    /// False when the start has already returned.
    func markAbandoned() -> Bool { lock.withLock { if state == 0 { state = 2 }; return state == 2 } }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// A private global tap (no process excluded) in a private aggregate device while a
/// dedicated engine plays a 1 kHz tone at about −80 dBFS, so the mix always carries a
/// known signal. Other apps' samples are reduced to a peak and discarded. The tone is
/// inaudible and the meeting tap excludes TalkTrack's process, so it is never recorded.
/// A tap on TalkTrack's own process alone once reported allowed on macOS 27 while a
/// global tap in the same state received zeros, so the check taps the global mix.
public final class ProcessTapAccessProbe: SystemAudioAccessProbe, @unchecked Sendable {
    static let toneAmplitude: Float = 1e-4
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var engine: AVAudioEngine?
    private let callbackQueue = DispatchQueue(label: "local.talktrack.access-check", qos: .userInitiated)

    public init() {}

    public func start(deliver: @escaping @Sendable (UnsafeBufferPointer<Float>) -> Void) throws {
        try startTone()
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "TalkTrack Access Check"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), .system, "Cannot create the access check tap")
        let tapUID = try stringProperty(tap, selector: kAudioTapPropertyUID, source: .system)
        let definition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TalkTrack Access Check",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
        ]
        try check(AudioHardwareCreateAggregateDevice(definition as CFDictionary, &aggregate), .system,
                  "Cannot create the access check device")
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, callbackQueue) { _, input, _, _, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let data = buffer.mData else { continue }
                deliver(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                            count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
            }
        }, .system, "Cannot register the access check callback")
        guard let ioProc else { throw AudioCaptureError(source: .system, operation: "Access check callback is unavailable", status: nil) }
        try check(AudioDeviceStart(aggregate, ioProc), .system, "Cannot start the access check tap")
    }

    public func stop() throws {
        var failure: AudioCaptureError?
        func remember(_ status: OSStatus, _ operation: String) {
            if status != noErr, failure == nil { failure = AudioCaptureError(source: .system, operation: operation, status: status) }
        }
        if let ioProc, aggregate != kAudioObjectUnknown {
            remember(AudioDeviceStop(aggregate, ioProc), "Cannot stop the access check tap")
            let destroyed = AudioDeviceDestroyIOProcID(aggregate, ioProc)
            if destroyed == noErr { self.ioProc = nil } else { remember(destroyed, "Cannot remove the access check callback") }
        }
        engine?.stop(); engine = nil
        if aggregate != kAudioObjectUnknown {
            let result = AudioHardwareDestroyAggregateDevice(aggregate)
            if result == noErr { aggregate = AudioObjectID(kAudioObjectUnknown) } else { remember(result, "Cannot release the access check device") }
        }
        if tap != kAudioObjectUnknown {
            let result = AudioHardwareDestroyProcessTap(tap)
            if result == noErr { tap = AudioObjectID(kAudioObjectUnknown) } else { remember(result, "Cannot release the access check tap") }
        }
        if let failure { throw failure }
    }

    private func startTone() throws {
        let next = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw AudioCaptureError(source: .system, operation: "Cannot create the access check tone format", status: nil)
        }
        var phase: Float = 0
        let step = 2 * Float.pi * 1_000 / Float(format.sampleRate), amplitude = Self.toneAmplitude
        let tone = AVAudioSourceNode(format: format) { _, _, frames, output in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                var local = phase
                for frame in 0..<Int(frames) {
                    data[frame] = amplitude * sin(local)
                    local += step
                    if local > 2 * .pi { local -= 2 * .pi }
                }
                phase = local
            }
            return noErr
        }
        next.attach(tone)
        next.connect(tone, to: next.mainMixerNode, format: format)
        next.mainMixerNode.outputVolume = 1
        do { try next.start() } catch {
            throw AudioCaptureError(source: .system,
                operation: "Cannot play the access check tone; check the audio output device (\(error.localizedDescription))", status: nil)
        }
        engine = next
    }
}

/// TalkTrack's own Core Audio process object, for tapping or excluding its output.
func ownProcessObject() throws -> AudioObjectID {
    var pid = getpid()
    var process = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = property(kAudioHardwarePropertyTranslatePIDToProcessObject)
    try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout.size(ofValue: pid)), &pid, &size, &process), .system, "Cannot identify TalkTrack's audio process")
    guard process != kAudioObjectUnknown else {
        throw AudioCaptureError(source: .system, operation: "TalkTrack's audio process is unavailable", status: nil)
    }
    return process
}
