import Accelerate
import AVFoundation
import Darwin
import Foundation
import Testing
import TalkTrackAudio
import TalkTrackDomain
@testable import TalkTrackServices

private func ticks(_ seconds: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: seconds) }

/// Enforces the writer's ordering rules without storing two hours of PCM:
/// it keeps only burst onsets, frame totals, gaps and timing.
private actor MarkerSink: CaptureAudioSink {
    private var recording: Recording
    private var next: [AudioTrack: UInt64] = [:]
    private var last: [AudioTrack: Float] = [:]
    private(set) var onsets: [AudioTrack: [UInt64]] = [:]
    private(set) var frames: [AudioTrack: UInt64] = [:]
    private(set) var gaps: [(AudioTrack, MediaInterval, String)] = []
    private(set) var closes = 0
    private(set) var interrupted: Bool?
    private(set) var violations: [String] = []
    private let blocked: Gate?

    init(blocked: Gate? = nil) throws {
        recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC"); self.blocked = blocked
    }

    func append(track: AudioTrack, samples: [Float], activeStartFrame: UInt64, hostTimeStart: UInt64) throws {
        blocked?.wait()
        if let expected = next[track], expected != activeStartFrame { violations.append("discontiguous \(track)") }
        if Double(activeStartFrame + UInt64(samples.count)) / 48_000 > recording.activeDuration.seconds + 0.000_01 {
            violations.append("audio beyond timing \(track)")
        }
        if samples.count > 48_000 { violations.append("oversized append") }
        var previous = last[track] ?? 0
        if vDSP.maximum(samples) > 0.5 || previous > 0.5 {
            for (index, value) in samples.enumerated() {
                if value > 0.5 && previous <= 0.5 { onsets[track, default: []].append(activeStartFrame + UInt64(index)) }
                previous = value
            }
        }
        last[track] = samples.last
        next[track] = activeStartFrame + UInt64(samples.count)
        frames[track, default: 0] += UInt64(samples.count)
    }
    func closeInterval() throws { next = [:]; last = [:]; closes += 1 }
    func updateCaptureTiming(_ timing: CaptureTimingSnapshot, state: RecordingState) throws {
        if timing.activeDuration < recording.activeDuration { violations.append("timing moved backwards") }
        recording.activeDuration = timing.activeDuration; recording.captureIntervals = timing.intervals
        recording.days = timing.days
    }
    func recordGap(track: AudioTrack, active: MediaInterval, reason: String) throws {
        if let expected = next[track], Double(expected) / 48_000 > active.start.seconds + 0.000_01 {
            violations.append("gap over audio \(track)")
        }
        if active.end > recording.activeDuration { violations.append("gap beyond timing") }
        gaps.append((track, active, reason)); next[track] = nil; last[track] = nil
    }
    func finish(interrupted: Bool) throws -> RecordingAudioManifest {
        self.interrupted = interrupted
        return RecordingAudioManifest(recording: recording, audio: [])
    }
    var intervals: [CaptureInterval] { recording.captureIntervals }
    var duration: MediaTime { recording.activeDuration }
}

/// Blocks the sink's executor, simulating a stalled disk.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var open = false
    func wait() { if !lock.withLock({ open }) { semaphore.wait(); semaphore.signal() } }
    func release() { lock.withLock { open = true }; semaphore.signal() }
}

private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ error: Error) { lock.withLock { items.append(error.localizedDescription) } }
    var values: [String] { lock.withLock { items } }
}

/// One simulated device. Its sample clock runs at `actualRate` in host time
/// while it reports `nominalRate`; bursts sit at exact host times.
private struct SimulatedSource {
    let source: CaptureSource
    let nominalRate: Double
    let actualRate: Double
    let startHost: Double
    let packetFrames: Int
    var index = 0
    var hostSeconds: Double { startHost + Double(index * packetFrames) / actualRate }

    mutating func packet(origin: UInt64, bursts: [Double]) -> AudioPacket {
        var samples = [Float](repeating: 0, count: packetFrames)
        let first = index * packetFrames
        for time in bursts where time >= startHost {
            let position = Int(((time - startHost) * actualRate).rounded()) - first
            for offset in 0..<5 where (0..<packetFrames).contains(position + offset) { samples[position + offset] = 0.9 }
        }
        let host = hostSeconds
        index += 1
        return AudioPacket(source: source, sampleRate: nominalRate, hostTime: origin + ticks(host),
                           sampleTime: Double(first), samples: samples)
    }
}

/// Feeds both sources in host-time order until `until`, draining regularly
/// as a real-time producer would allow.
private func feed(_ pipeline: RecordingCapturePipeline, _ sources: inout [SimulatedSource],
                  origin: UInt64, bursts: [Double], until: Double) async {
    var count = 0
    while let next = sources.indices.filter({ sources[$0].hostSeconds < until })
            .min(by: { sources[$0].hostSeconds < sources[$1].hostSeconds }) {
        pipeline.receive(sources[next].packet(origin: origin, bursts: bursts))
        count += 1
        if count % 256 == 0 { await pipeline.drain() }
    }
    await pipeline.drain()
}

/// The ideal active frame of a host time, from the recorded capture anchors.
private func expectedFrame(_ time: Double, origin: UInt64, intervals: [CaptureInterval]) -> Double {
    let interval = intervals.last { AVAudioTime.seconds(forHostTime: $0.hostTimeStart - origin) <= time }!
    return (interval.active.start.seconds + time - AVAudioTime.seconds(forHostTime: interval.hostTimeStart - origin)) * 48_000
}

@Suite struct RecordingCapturePipelineTests {
    @Test func twoHourDriftingSourcesStayWithinFiftyMilliseconds() async throws {
        let sink = try MarkerSink(), failures = Failures(), origin = ticks(1_000)
        let pipeline = RecordingCapturePipeline(sink: sink, capacity: 4_096, now: { 0 }, failure: failures.add)
        // System audio runs 30 ppm slow; the microphone is a 44.1 kHz device
        // running 80 ppm fast. Uncorrected, they would separate by ~0.8 s.
        var sources = [
            SimulatedSource(source: .system, nominalRate: 48_000, actualRate: 48_000 * (1 - 30e-6), startHost: 0.15, packetFrames: 4_800),
            SimulatedSource(source: .microphone, nominalRate: 44_100, actualRate: 44_100 * (1 + 80e-6), startHost: 0.02, packetFrames: 4_410),
        ]
        let pause = (3_700.0, 4_000.0)
        let bursts = stride(from: 120.0, through: 7_400, by: 300).filter { !($0 >= pause.0 - 1 && $0 <= pause.1 + 1) }
        let wall = Date(timeIntervalSince1970: 1_791_000_000)
        try await pipeline.begin(hostTime: origin, wallClock: wall, timeZoneIdentifier: "UTC")
        // A route change at 30 minutes: 300 ms without microphone audio, then
        // a different 48 kHz input device running 50 ppm fast.
        await feed(pipeline, &sources, origin: origin, bursts: bursts, until: 1_800)
        pipeline.sourceRestarted(.microphone, reason: "The input device or its format changed")
        sources[1] = SimulatedSource(source: .microphone, nominalRate: 48_000, actualRate: 48_000 * (1 + 50e-6),
                                     startHost: 1_800.3, packetFrames: 4_800)
        await feed(pipeline, &sources, origin: origin, bursts: bursts, until: pause.0)
        try await pipeline.pause()
        try await pipeline.begin(hostTime: origin + ticks(pause.1), wallClock: wall.addingTimeInterval(pause.1),
                                 timeZoneIdentifier: "UTC")
        sources[0] = SimulatedSource(source: .system, nominalRate: 48_000, actualRate: 48_000 * (1 - 30e-6),
                                     startHost: pause.1 + 0.15, packetFrames: 4_800)
        sources[1] = SimulatedSource(source: .microphone, nominalRate: 48_000, actualRate: 48_000 * (1 + 50e-6),
                                     startHost: pause.1 + 0.02, packetFrames: 4_800)
        await feed(pipeline, &sources, origin: origin, bursts: bursts, until: 7_500)
        _ = try await pipeline.finish()

        let violations = await sink.violations
        #expect(violations.isEmpty, "\(violations)")
        #expect(failures.values.isEmpty)
        let onsets = await sink.onsets
        #expect(onsets[.system]?.count == bursts.count)
        #expect(onsets[.microphone]?.count == bursts.count)
        let intervals = await sink.intervals
        var interTrack = 0.0, absolute = 0.0
        for (index, time) in bursts.enumerated() {
            guard let system = onsets[.system]?[safe: index], let microphone = onsets[.microphone]?[safe: index] else { continue }
            interTrack = max(interTrack, abs(Double(system) - Double(microphone)) / 48)
            let expected = expectedFrame(time, origin: origin, intervals: intervals)
            absolute = max(absolute, abs(Double(system) - expected) / 48, abs(Double(microphone) - expected) / 48)
        }
        let summary = await pipeline.status
        print("two-hour drift fixture: max inter-track \(interTrack) ms, max absolute \(absolute) ms, status \(summary)")
        #expect(interTrack <= 50)
        #expect(absolute <= 50)
        let status = await pipeline.status
        #expect((status.correctedFrames[.system] ?? 0) > 2_000)
        #expect((status.correctedFrames[.microphone] ?? 0) > 2_000)
        #expect(Double(status.maximumDriftFrames[.microphone] ?? .max) <= 0.012 * 48_000)
        // Active time excludes the five-minute pause and keeps both intervals.
        #expect(abs(await sink.duration.seconds - 7_200) < 0.2)
        #expect(await sink.intervals.count == 2)
        #expect(await sink.closes == 2)
        let gaps = await sink.gaps
        let route = gaps.filter { $0.0 == .microphone && $0.2.hasPrefix("Device changed") }
        #expect(route.count == 1)
        // The last packet before the change ends up to 100 ms after 1800 s.
        #expect((0.18...0.31).contains(route.first?.1.duration.seconds ?? 0))
        // System audio starts 150 ms late after each Start/Resume: explicit gaps.
        #expect(gaps.filter { $0.0 == .system && $0.2.contains("late") }.count == 2)
        #expect(await sink.interrupted == false)
    }

    @Test(arguments: [false, true])
    func stalledOrClosedLiveInferenceKeepsEveryStoredFrame(closed: Bool) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
        let live = LiveInferenceMailbox<LiveCaptureFragment>(capacity: 1)
        if closed { live.finish() } // A failed live session stops consuming.
        let failures = Failures(), origin = ticks(50)
        let pipeline = RecordingCapturePipeline(sink: writer, live: live, now: { 0 }, failure: failures.add)
        var sources = [
            SimulatedSource(source: .system, nominalRate: 48_000, actualRate: 48_000, startHost: 0, packetFrames: 1_024),
            SimulatedSource(source: .microphone, nominalRate: 48_000, actualRate: 48_000, startHost: 0, packetFrames: 1_024),
        ]
        try await pipeline.begin(hostTime: origin, wallClock: Date(), timeZoneIdentifier: "UTC")
        await feed(pipeline, &sources, origin: origin, bursts: [5, 25], until: 30)
        let manifest = try await pipeline.finish()
        #expect(failures.values.isEmpty)
        #expect(manifest.recording.state == .complete)
        for track in AudioTrack.allCases {
            let stored = manifest.audio.filter { $0.chunk.track == track }.reduce(0) { $0 + $1.encoding.validFrames }
            #expect(stored == 30 * 48_000 / 1_024 * 1_024 + (30 * 48_000 % 1_024 == 0 ? 0 : 1_024))
        }
        let status = await pipeline.status
        if !closed { #expect(status.replacedLiveFragments > 0) }
        var first: LiveCaptureFragment?
        for await fragment in live.requests { first = first ?? fragment; break }
        #expect(closed ? first == nil : first?.boundaryID != nil)
    }

    @Test func realWriterKeepsRouteGapPauseAndAlignedMarkers() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
        let failures = Failures(), origin = ticks(10)
        let pipeline = RecordingCapturePipeline(sink: writer, now: { 0 }, failure: failures.add)
        var sources = [
            SimulatedSource(source: .system, nominalRate: 48_000, actualRate: 48_000 * (1 - 200e-6), startHost: 0.01, packetFrames: 480),
            SimulatedSource(source: .microphone, nominalRate: 44_100, actualRate: 44_100 * (1 + 200e-6), startHost: 0.01, packetFrames: 441),
        ]
        let bursts = [4.0, 11.0, 19.0]
        try await pipeline.begin(hostTime: origin, wallClock: Date(timeIntervalSince1970: 1_791_000_000), timeZoneIdentifier: "UTC")
        await feed(pipeline, &sources, origin: origin, bursts: bursts, until: 8)
        pipeline.sourceRestarted(.microphone, reason: "Headphones connected")
        sources[1] = SimulatedSource(source: .microphone, nominalRate: 48_000, actualRate: 48_000, startHost: 8.5, packetFrames: 480)
        await feed(pipeline, &sources, origin: origin, bursts: bursts, until: 12)
        try await pipeline.pause()
        try await pipeline.begin(hostTime: origin + ticks(15), wallClock: Date(timeIntervalSince1970: 1_791_000_015), timeZoneIdentifier: "UTC")
        sources[0] = SimulatedSource(source: .system, nominalRate: 48_000, actualRate: 48_000, startHost: 15.01, packetFrames: 480)
        sources[1] = SimulatedSource(source: .microphone, nominalRate: 48_000, actualRate: 48_000, startHost: 15.01, packetFrames: 480)
        await feed(pipeline, &sources, origin: origin, bursts: bursts, until: 21)
        let manifest = try await pipeline.finish()
        #expect(failures.values.isEmpty)
        #expect(manifest.recording.state == .complete)
        #expect(manifest.recording.captureIntervals.count == 2)
        #expect(abs(manifest.recording.activeDuration.seconds - 18) < 0.05)
        let gaps = manifest.recording.trackIntervals.compactMap { interval -> (AudioTrack, MediaInterval, String)? in
            if case let .gap(reason) = interval.content { return (interval.track, interval.active, reason) }
            return nil
        }
        #expect(gaps.count == 1)
        #expect(gaps.first?.0 == .microphone && gaps.first?.2 == "Device changed: Headphones connected")
        #expect(abs((gaps.first?.1.start.seconds ?? 0) - 8) < 0.01 && abs((gaps.first?.1.end.seconds ?? 0) - 8.5) < 0.01)
        var decoded: [AudioTrack: [(UInt64, [Float])]] = [:]
        for item in manifest.audio {
            let fd = open(library.directory.appendingPathComponent(item.chunk.file.value).path, O_RDONLY | O_NOFOLLOW)
            defer { close(fd) }
            var samples: [Float] = []
            _ = try AACChunkEncoder.decode(fileDescriptor: fd, expectedFrames: item.encoding.validFrames) { samples.append(contentsOf: $0) }
            decoded[item.chunk.track, default: []].append((UInt64((item.chunk.active.start.seconds * 48_000).rounded()), samples))
        }
        func onsets(_ track: AudioTrack) -> [Double] {
            var result: [Double] = []
            for (start, samples) in decoded[track] ?? [] {
                var index = 0
                while index < samples.count {
                    if samples[index] > 0.4 { result.append(Double(start + UInt64(index)) / 48); index += 4_800 } else { index += 1 }
                }
            }
            return result.sorted()
        }
        let system = onsets(.system), microphone = onsets(.microphone)
        #expect(system.count == 3 && microphone.count == 3)
        for (expected, (a, b)) in zip([4_000.0, 11_000, 16_000], zip(system, microphone)) {
            #expect(abs(a - b) <= 50)
            #expect(abs(a - expected) <= 50 && abs(b - expected) <= 50)
        }
    }

    @Test func stalledStorageOverflowIsAnExplicitInterruptionWithAGap() async throws {
        let gate = Gate(), sink = try MarkerSink(blocked: gate), failures = Failures(), origin = ticks(20)
        let pipeline = RecordingCapturePipeline(sink: sink, capacity: 16, now: { 0 }, failure: failures.add)
        try await pipeline.begin(hostTime: origin, wallClock: Date(), timeZoneIdentifier: "UTC")
        var system = SimulatedSource(source: .system, nominalRate: 48_000, actualRate: 48_000, startHost: 0, packetFrames: 4_800)
        // The first batch blocks inside the sink; capture keeps producing.
        for _ in 0..<80 { pipeline.receive(system.packet(origin: origin, bursts: [])) }
        #expect(failures.values.count == 1)
        #expect(failures.values.first?.contains("fell behind") == true)
        gate.release()
        await pipeline.drain()
        for _ in 0..<20 { pipeline.receive(system.packet(origin: origin, bursts: [])) }
        _ = try await pipeline.finish()
        #expect(await sink.interrupted == true)
        #expect(await pipeline.status.droppedPackets > 0)
        let gaps = await sink.gaps.filter { $0.0 == .system && $0.2 == RecordingCapturePipeline.overflowReason }
        #expect(!gaps.isEmpty)
        #expect(await sink.violations.isEmpty)
        #expect(failures.values.count == 1)
    }

    @Test func alignerTrimsRewindsCorrectsDriftAndBreaksOnRateChange() throws {
        var aligner = CaptureTrackAligner()
        let block = [Float](repeating: 0.1, count: 1_000)
        #expect(try aligner.process(block, sampleRate: 48_000, target: 10_000, intervalStart: 10_000)
                == [.audio(start: 10_000, samples: block)])
        // A large rewind onto stored audio keeps the stored frames.
        let rewound = try aligner.process([Float](repeating: 0.2, count: 8_000), sampleRate: 48_000,
                                          target: 5_000, intervalStart: 0)
        #expect(rewound == [.audio(start: 11_000, samples: [Float](repeating: 0.2, count: 2_000))])
        // Ten ms behind: at most 0.5% (5 frames) inserted per 1000-frame packet.
        let next = aligner.next!
        let late = try aligner.process(block, sampleRate: 48_000, target: next + 480, intervalStart: 0)
        guard case let .audio(lateStart, lateSamples) = late.first else { Issue.record("No audio"); return }
        #expect(lateStart == next && lateSamples.count == 1_005)
        #expect(aligner.corrected == 5)
        // A sample-rate change starts a new section with an explicit gap.
        let after = aligner.next!
        let changed = try aligner.process([Float](repeating: 0.1, count: 4_410), sampleRate: 44_100,
                                          target: after + 96, intervalStart: 0)
        #expect(changed.first == .gap(start: after, end: after + 96, reason: "The source sample rate changed"))
        // A large forward jump is an interruption, not drift to absorb.
        let resumed = aligner.next!
        let jump = try aligner.process([Float](repeating: 0.1, count: 4_410), sampleRate: 44_100,
                                       target: resumed + 9_600, intervalStart: 0)
        #expect(jump.first == .gap(start: resumed, end: resumed + 9_600, reason: "Audio from the source was interrupted"))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
