import Dispatch
import Foundation
import Testing
@testable import TalkTrackAudio

private final class PacketLog: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [AudioPacket] = []
    private var errors: [AudioCaptureError] = []
    func receive(_ packet: AudioPacket) { lock.withLock { packets.append(packet) } }
    func fail(_ error: AudioCaptureError) { lock.withLock { errors.append(error) } }
    var audio: [AudioPacket] { lock.withLock { packets } }
    var failures: [AudioCaptureError] { lock.withLock { errors } }
}

private func waitForPacket(_ log: PacketLog) async throws {
    let clock = ContinuousClock(), deadline = clock.now + .seconds(3)
    while log.audio.isEmpty {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@Suite struct AudioPacketHandoffTests {
    @Test func ownsMixedSamplesAndPreservesAnchorsThroughDrain() async {
        let log = PacketLog()
        let queue = AudioPacketHandoff(source: .microphone, sampleRate: 48000, receive: log.receive, failure: log.fail)
        var borrowed: [Float] = [1, -0.5, 0.2, 0.4]
        queue.enqueue(frames: 2, channels: 2, hostTime: 1234, sampleTime: 456) { borrowed[$0 * 2 + $1] }
        borrowed = [0, 0, 0, 0]
        await queue.finish()
        #expect(log.audio.count == 1)
        #expect(log.audio.first?.samples == [0.25, 0.3])
        #expect(log.audio.first?.hostTime == 1234)
        #expect(log.audio.first?.sampleTime == 456)
        #expect(log.audio.first?.source == .microphone)
        #expect(log.failures.isEmpty)
        queue.enqueue(frames: 1, channels: 1, hostTime: 1, sampleTime: 1) { _, _ in 1 }
        queue.interrupt()
        #expect(log.audio.count == 1)
        #expect(log.failures.isEmpty)
    }

    @Test func saturatedSinkHasBoundedStorageAndReportsOneInterruption() async throws {
        let log = PacketLog(), gate = DispatchSemaphore(value: 0)
        let queue = AudioPacketHandoff(source: .system, sampleRate: 48000, capacity: 1, receive: {
            log.receive($0)
            if $0.hostTime == 1 { gate.wait() }
        }, failure: log.fail)
        queue.enqueue(frames: 1, channels: 1, hostTime: 1, sampleTime: 0) { _, _ in 0.1 }
        try await waitForPacket(log)
        queue.enqueue(frames: 1, channels: 1, hostTime: 2, sampleTime: 1) { _, _ in 0.2 }
        for _ in 0..<100 { queue.enqueue(frames: 1, channels: 1, hostTime: 3, sampleTime: 2) { _, _ in 0.3 } }
        gate.signal()
        await queue.finish()
        #expect(log.audio.map(\.hostTime) == [1, 2])
        #expect(log.failures.count == 1)
        #expect(log.failures.first?.source == .system)
        #expect(log.failures.first?.operation.contains("overflowed") == true)
    }

    @Test func rejectsInvalidAndNonfiniteAudioWithoutPartialPublication() async {
        let log = PacketLog()
        let queue = AudioPacketHandoff(source: .system, sampleRate: 48000, maxFrames: 2, receive: log.receive, failure: log.fail)
        queue.enqueue(frames: 3, channels: 1, hostTime: 1, sampleTime: 0) { _, _ in 1 }
        queue.enqueue(frames: 1, channels: 9, hostTime: 1, sampleTime: 0) { _, _ in 1 }
        queue.enqueue(frames: 2, channels: 1, hostTime: 1, sampleTime: 0) { frame, _ in frame == 0 ? 1 : .nan }
        await queue.finish()
        #expect(log.audio.isEmpty)
        #expect(log.failures.count == 1)
    }

    @Test func finishWaitsForTheProducerCopyAndRejectsConcurrentProducer() async throws {
        let log = PacketLog(), entered = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let queue = AudioPacketHandoff(source: .microphone, sampleRate: 48000, receive: log.receive, failure: log.fail)
        let producer = Task.detached {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    queue.enqueue(frames: 1, channels: 1, hostTime: 1, sampleTime: 0) { _, _ in
                        entered.signal(); gate.wait(); return 0.5
                    }
                    continuation.resume()
                }
            }
        }
        await withCheckedContinuation { continuation in DispatchQueue.global().async { entered.wait(); continuation.resume() } }
        queue.enqueue(frames: 1, channels: 1, hostTime: 2, sampleTime: 1) { _, _ in 1 }
        let finish = Task { await queue.finish() }
        gate.signal()
        await producer.value; await finish.value
        #expect(log.audio.map(\.hostTime) == [1])
        #expect(log.failures.count == 1)
    }
}
