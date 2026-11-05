import AVFoundation
import Foundation
import Synchronization
import Testing
import TalkTrackAudio
import TalkTrackDomain
@testable import TalkTrackServices

/// detect-loudspeaker-echo tasks 2.1–2.2: detection beside the capture
/// pipeline, and stretches saved with the recording's timing checkpoints.
@Suite struct PlaybackEchoCaptureTests {
    private static func ticks(_ seconds: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: seconds) }

    /// Blocks the analysis queue, simulating a detector that cannot keep up.
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var open = false
        func wait() { if !lock.withLock({ open }) { semaphore.wait(); semaphore.signal() } }
        func release() { lock.withLock { open = true }; semaphore.signal() }
    }

    /// Feeds `seconds` of 48 kHz audio in 32 ms packets: speech-like system
    /// audio and a microphone that hears it 90 ms later at −14 dB when `echo`.
    private static func feed(_ pipeline: RecordingCapturePipeline, origin: UInt64, seconds: Double, echo: Bool) async {
        let system = PlaybackEchoDetectorTests.speech48(seconds, seed: 21)
        let microphone = echo
            ? PlaybackEchoDetectorTests.add(PlaybackEchoDetectorTests.delayed(system, by: 4_320, gain: 0.2),
                                            PlaybackEchoDetectorTests.speech48(seconds, seed: 22, amplitude: 0.02))
            : PlaybackEchoDetectorTests.speech48(seconds, seed: 23, amplitude: 0.05)
        let packet = 1_536
        var count = 0
        for offset in stride(from: 0, to: system.count, by: packet) {
            let end = min(system.count, offset + packet)
            let host = origin + ticks(Double(offset) / 48_000)
            for (source, samples) in [(CaptureSource.system, system), (.microphone, microphone)] {
                pipeline.receive(AudioPacket(source: source, sampleRate: 48_000, hostTime: host,
                                             sampleTime: Double(offset), samples: Array(samples[offset..<end])))
            }
            count += 1
            if count % 64 == 0 { await pipeline.drain() }
        }
        await pipeline.drain()
    }

    @Test func pipelineSavesLoudspeakerStretchesWithTheRecording() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
        let monitor = PlaybackEchoMonitor(recordingID: recording.id, maximumBacklog: .max)
        let failures = Mutex<[String]>([])
        let pipeline = RecordingCapturePipeline(sink: writer, echo: monitor, now: { 0 },
                                                failure: { error in failures.withLock { $0.append("\(error)") } })
        let origin = Self.ticks(100)
        try await pipeline.begin(hostTime: origin, wallClock: Date(), timeZoneIdentifier: "UTC")
        await Self.feed(pipeline, origin: origin, seconds: 20, echo: true)
        await monitor.waitUntilIdle()
        #expect(monitor.status.state == .loudspeaker)
        let manifest = try await pipeline.finish()
        #expect(failures.withLock { $0 }.isEmpty)
        let stretches = try #require(manifest.recording.playbackEcho)
        #expect(stretches.map(\.state) == [.loudspeaker])
        #expect(abs((stretches[0].lagMilliseconds ?? 0) - 90) <= 5)
        #expect(stretches[0].active.end <= manifest.recording.activeDuration)
        // Detection changes nothing about the stored audio or its gaps.
        let gaps = manifest.recording.trackIntervals.filter { if case .gap = $0.content { true } else { false } }
        #expect(gaps.isEmpty)
        for track in AudioTrack.allCases {
            let frames = manifest.audio.filter { $0.chunk.track == track }.reduce(0) { $0 + $1.encoding.validFrames }
            #expect(frames == 20 * 48_000)
        }
        let recovered = try await RecordingAudioWriter.recover(library: library, meetingID: recording.meetingID, recordingID: recording.id)
        #expect(recovered.recording.playbackEcho == stretches)
    }

    @Test func stalledDetectorNeverDelaysStorage() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
        let gate = Gate()
        let monitor = PlaybackEchoMonitor(recordingID: recording.id, onMeasurement: { _ in gate.wait() })
        let pipeline = RecordingCapturePipeline(sink: writer, echo: monitor, now: { 0 }, failure: { _ in })
        let origin = Self.ticks(100)
        try await pipeline.begin(hostTime: origin, wallClock: Date(), timeZoneIdentifier: "UTC")
        await Self.feed(pipeline, origin: origin, seconds: 30, echo: true)
        // The detector is stuck in its first measurement, yet everything is stored.
        let manifest = try await pipeline.finish()
        #expect(manifest.recording.state == .complete)
        for track in AudioTrack.allCases {
            #expect(manifest.audio.filter { $0.chunk.track == track }.reduce(0) { $0 + $1.encoding.validFrames } == 30 * 48_000)
        }
        #expect(manifest.recording.playbackEcho == nil)
        gate.release()
        await monitor.waitUntilIdle()
        // Pause at finish discarded the backlog; nothing was decided from stale audio.
        #expect(monitor.status.state == .unknown)
    }

    @Test func checkpointsKeepOnlySavedStretchesAfterACrash() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let origin = Self.ticks(10)
        var clock = CaptureIntervalClock()
        try clock.begin(hostTime: origin, wallClock: Date(), timeZoneIdentifier: "UTC")
        let interval = { (a: Double, b: Double) in try MediaInterval(start: MediaTime(seconds: a), end: MediaTime(seconds: b)) }
        let loud = PlaybackEchoStretch(active: try interval(0, 8), state: .loudspeaker, peak: 0.27, lagMilliseconds: 90)
        do {
            let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
            await writer.updatePlaybackEcho([PlaybackEchoStretch(active: try interval(0, 12), state: .loudspeaker,
                                                                     peak: 0.27, lagMilliseconds: 90)])
            try await writer.updateCaptureTiming(clock.checkpoint(at: origin + Self.ticks(10)), state: .recording)
            // Clamped to the committed ten seconds.
            #expect(await writer.snapshot().recording.playbackEcho?.first?.active == (try interval(0, 10)))
            await writer.updatePlaybackEcho([loud, PlaybackEchoStretch(active: try interval(8, 20), state: .headset,
                                                                           peak: 0.01, lagMilliseconds: nil)])
            try await writer.updateCaptureTiming(clock.checkpoint(at: origin + Self.ticks(15)), state: .recording)
            // Measured after the last checkpoint: never saved.
            await writer.updatePlaybackEcho([loud, PlaybackEchoStretch(active: try interval(8, 25), state: .headset,
                                                                           peak: 0.01, lagMilliseconds: nil)])
        }
        // The writer is gone without Stop, as after SIGKILL.
        let recovered = try await RecordingAudioWriter.recover(library: library, meetingID: recording.meetingID, recordingID: recording.id)
        let stretches = try #require(recovered.recording.playbackEcho)
        #expect(stretches.map(\.state) == [.loudspeaker, .headset])
        #expect(stretches[1].active == (try interval(8, 15)))
        #expect(stretches.state(at: try MediaTime(seconds: 18)) == .unknown)
    }

    @Test func recordingsWithoutDetectionEncodeAsBefore() throws {
        var recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let old = try DomainCodec.encode(recording)
        #expect(!String(decoding: old, as: UTF8.self).contains("playbackEcho"))
        let decoded = try DomainCodec.decode(Recording.self, from: old)
        #expect(decoded.playbackEcho == nil)
        #expect(try SessionStore.fingerprint(decoded) == SessionStore.fingerprint(recording))
        recording.playbackEcho = [PlaybackEchoStretch(active: try MediaInterval(start: .zero, end: MediaTime(seconds: 3)),
                                                      state: .headset, peak: 0.01, lagMilliseconds: nil)]
        #expect(try DomainCodec.decode(Recording.self, from: DomainCodec.encode(recording)) == recording)
    }
}
