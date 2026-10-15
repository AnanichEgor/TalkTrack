import Dispatch
import Foundation
import Synchronization

/// Preallocated, bounded PCM handoff. The producer never waits, allocates a PCM
/// array, performs I/O, or creates a Task. One consumer copies owned packets on
/// its dedicated queue. Release/acquire indices protect every slot's lifetime.
/// A full queue or concurrent producer is an explicit interruption, not silence.
final class AudioPacketHandoff: @unchecked Sendable {
    private final class Slot {
        let samples: UnsafeMutablePointer<Float>
        var frames = 0
        var hostTime: UInt64 = 0
        var sampleTime: Double = 0
        init(frames: Int) { samples = .allocate(capacity: frames); samples.initialize(repeating: 0, count: frames) }
        deinit { samples.deallocate() }
    }

    private let slots: [Slot]
    private let maxFrames: Int
    private let readIndex = Atomic<Int>(0)
    private let writeIndex = Atomic<Int>(0)
    private let producerBusy = Atomic<Bool>(false)
    private let accepting = Atomic<Bool>(true)
    private let fault = Atomic<Int>(0)
    private let queue = DispatchQueue(label: "local.talktrack.audio-packets", qos: .userInitiated)
    private let signal: DispatchSourceUserDataAdd
    private let source: CaptureSource
    private let sampleRate: Double
    private let receive: @Sendable (AudioPacket) -> Void
    private let failure: @Sendable (AudioCaptureError) -> Void
    private var failureSent = false // consumer queue only

    init(source: CaptureSource, sampleRate: Double, capacity: Int = 32, maxFrames: Int = 16384,
         receive: @escaping @Sendable (AudioPacket) -> Void,
         failure: @escaping @Sendable (AudioCaptureError) -> Void) {
        precondition(capacity > 0 && maxFrames > 0)
        self.source = source; self.sampleRate = sampleRate; self.maxFrames = maxFrames
        self.receive = receive; self.failure = failure
        slots = (0...capacity).map { _ in Slot(frames: maxFrames) }
        signal = DispatchSource.makeUserDataAddSource(queue: queue)
        signal.setEventHandler { [weak self] in self?.drain() }
        signal.activate()
    }

    /// The borrowed sample reader is invoked only before returning to the HAL.
    func enqueue(frames: Int, channels: Int, hostTime: UInt64, sampleTime: Double,
                 sample: (_ frame: Int, _ channel: Int) -> Float) {
        guard accepting.load(ordering: .acquiring) else { return }
        guard frames > 0, frames <= maxFrames, (1...8).contains(channels), sampleTime.isFinite else {
            interrupt(code: 2); return
        }
        guard !producerBusy.exchange(true, ordering: .acquiring) else { interrupt(code: 1); return }
        defer { producerBusy.store(false, ordering: .releasing) }
        guard accepting.load(ordering: .acquiring) else { return }
        let index = writeIndex.load(ordering: .relaxed), next = (index + 1) % slots.count
        guard next != readIndex.load(ordering: .acquiring) else { interrupt(code: 1); return }
        let slot = slots[index]
        for frame in 0..<frames {
            var mono: Float = 0
            for channel in 0..<channels { mono += sample(frame, channel) / Float(channels) }
            guard mono.isFinite else { interrupt(code: 2); return }
            slot.samples[frame] = mono
        }
        slot.frames = frames; slot.hostTime = hostTime; slot.sampleTime = sampleTime
        writeIndex.store(next, ordering: .releasing)
        signal.add(data: 1)
    }

    func interrupt(code: Int = 2) {
        guard accepting.load(ordering: .acquiring) else { return }
        if fault.compareExchange(expected: 0, desired: code, ordering: .acquiringAndReleasing).exchanged {
            signal.add(data: 1)
        }
    }

    /// Call only after native callbacks have stopped. No accepted packet or
    /// failure callback remains in flight after this barrier returns.
    func finish() async {
        accepting.store(false, ordering: .releasing)
        await withCheckedContinuation { continuation in
            queue.async { [self] in finishOnQueue(continuation) }
        }
    }

    private func finishOnQueue(_ continuation: CheckedContinuation<Void, Never>) {
        // Also safe after a HAL teardown error: disable late producers and
        // wait for the bounded copy already in progress before the last drain.
        if producerBusy.load(ordering: .acquiring) {
            queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [self] in finishOnQueue(continuation) }
        } else {
            drain(); signal.cancel(); continuation.resume()
        }
    }

    private func drain() {
        var index = readIndex.load(ordering: .relaxed)
        while index != writeIndex.load(ordering: .acquiring) {
            let slot = slots[index]
            let packet = AudioPacket(source: source, sampleRate: sampleRate, hostTime: slot.hostTime,
                                     sampleTime: slot.sampleTime,
                                     samples: Array(UnsafeBufferPointer(start: slot.samples, count: slot.frames)))
            index = (index + 1) % slots.count
            readIndex.store(index, ordering: .releasing)
            receive(packet)
        }
        let code = fault.load(ordering: .acquiring)
        if code != 0, !failureSent {
            failureSent = true
            failure(AudioCaptureError(source: source, operation: code == 1
                ? "The audio buffer queue overflowed; recording was interrupted"
                : "The device returned invalid audio or timing; recording was interrupted", status: nil))
        }
    }
}
