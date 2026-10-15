@preconcurrency import AVFoundation
import Dispatch
import Foundation
import Synchronization
import TalkTrackAudio
import TalkTrackDomain

/// Durable destination of normalized capture audio; `RecordingAudioWriter` in
/// production. Calls are serialized by the pipeline.
public protocol CaptureAudioSink: Actor {
    func append(track: AudioTrack, samples: [Float], activeStartFrame: UInt64, hostTimeStart: UInt64) async throws
    func closeInterval() async throws
    func updateCaptureTiming(_ timing: CaptureTimingSnapshot, state: RecordingState) async throws
    func recordGap(track: AudioTrack, active: MediaInterval, reason: String) async throws
    func finish(interrupted: Bool) async throws -> RecordingAudioManifest
}

extension RecordingAudioWriter: CaptureAudioSink {}

/// Normalized audio offered to live transcription after it was handed to the
/// durable sink. `boundaryID` changes on Resume, midnight and discontinuities.
public struct LiveCaptureFragment: Sendable {
    public let track: AudioTrack
    public let samples: [Float]
    public let activeStartFrame: UInt64
    public let day: RecordingDay
    public let wallClockStart: Date
    public let boundaryID: UUID
}

public struct CapturePipelineStatus: Equatable, Sendable {
    /// Largest observed source-versus-host-clock offset, in 48 kHz frames,
    /// before correction; corrections keep it near the tolerance.
    public var maximumDriftFrames: [AudioTrack: Int64] = [:]
    public var correctedFrames: [AudioTrack: Int64] = [:]
    public var gaps: [AudioTrack: Int] = [:]
    public var replacedLiveFragments = 0
    public var droppedPackets = 0
}

/// Streaming native sample-rate conversion to the stored 48 kHz grid.
final class StreamingResampler {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat, ratio: Double
    init(sourceRate: Double) throws {
        guard sourceRate.isFinite, (8_000...384_000).contains(sourceRate),
              let input = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioResamplingError.conversionFailed("Unsupported capture sample rate \(sourceRate)")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        // No priming: the converter's few-sample latency is far below the
        // alignment tolerance and is absorbed by the drift correction.
        converter.primeMethod = .none
        self.converter = converter; self.input = input; ratio = 48_000 / sourceRate
    }

    func convert(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                  frameCapacity: AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 64) else {
            throw AudioResamplingError.conversionFailed("Cannot allocate capture conversion buffers")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        var provided = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if provided { state.pointee = .noDataNow; return nil }
            provided = true; state.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, let channel = output.floatChannelData?[0] else {
            throw AudioResamplingError.conversionFailed(error?.localizedDescription ?? "The capture converter failed")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Places one source's packets on the shared 48 kHz active-frame grid.
/// Hardware timestamps decide position: sample counts follow the device clock,
/// which drifts against host time, so small offsets are corrected by at most
/// 0.5% per packet and large jumps become explicit gaps or trimmed overlap.
struct CaptureTrackAligner {
    static let discontinuityFrames: Int64 = 4_800 // 100 ms
    static let toleranceFrames: Int64 = 240       // 5 ms

    enum Output: Equatable {
        case audio(start: UInt64, samples: [Float])
        case gap(start: UInt64, end: UInt64, reason: String)
    }

    private(set) var next: UInt64?
    private(set) var maximumDrift: Int64 = 0
    private(set) var corrected: Int64 = 0
    private var rate: Double?
    private var resampler: StreamingResampler?
    private var breakReason: String?

    /// The next packet starts a new section even if its offset is small.
    /// The first reason wins: a device change also changes the sample rate.
    mutating func markBreak(_ reason: String) { if next != nil, breakReason == nil { breakReason = reason } }

    mutating func reset() { next = nil; rate = nil; resampler = nil; breakReason = nil }

    mutating func process(_ samples: [Float], sampleRate: Double, target: UInt64,
                          intervalStart: UInt64) throws -> [Output] {
        if rate != sampleRate {
            if rate != nil { markBreak("The source sample rate changed") }
            resampler = sampleRate == 48_000 ? nil : try StreamingResampler(sourceRate: sampleRate)
            rate = sampleRate
        }
        var audio = try resampler?.convert(samples) ?? samples
        guard !audio.isEmpty else { return [] }
        var result: [Output] = []
        let expected = next ?? intervalStart
        let error = Int64(target) - Int64(expected)
        var start = expected
        if next == nil || breakReason != nil || abs(error) > Self.discontinuityFrames {
            if error > 0 {
                start = target
                if next != nil || error > Self.discontinuityFrames {
                    result.append(.gap(start: expected, end: target, reason: breakReason
                        ?? (next == nil ? "The source started delivering audio late" : "Audio from the source was interrupted")))
                }
            } else if error < 0, next != nil {
                // The source rewound onto stored audio: keep the stored samples.
                let overlap = Int(min(-error, Int64(audio.count)))
                audio.removeFirst(overlap)
                if audio.isEmpty { breakReason = nil; return [] }
            }
            breakReason = nil
        } else {
            maximumDrift = max(maximumDrift, abs(error))
            if abs(error) > Self.toleranceFrames {
                let step = Int64(max(1, audio.count / 200))
                let change = min(max(error, -step), step)
                if change > 0 { audio.append(contentsOf: repeatElement(audio.last!, count: Int(change))) }
                else { audio.removeLast(Int(min(-change, Int64(audio.count - 1)))) }
                corrected += abs(change)
            }
        }
        next = start + UInt64(audio.count)
        result.append(.audio(start: start, samples: audio))
        return result
    }
}

private final class CapturePipelineExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "local.talktrack.capture-pipeline", qos: .userInitiated)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

/// Owns the shared capture clock between native capture and durable storage.
/// `receive` never waits: packets enter a bounded queue, and a full queue is an
/// explicit interruption with a recorded gap, never silent loss. Live
/// transcription gets fragments through a replacing mailbox and is never
/// awaited, so slow or failed inference cannot stall or drop stored audio.
public actor RecordingCapturePipeline {
    private nonisolated let executor = CapturePipelineExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    private enum Item: Sendable {
        case packet(AudioPacket)
        case discontinuity(CaptureSource, String)
        case barrier(CheckedContinuation<Void, Never>)
    }

    public static let batchFrames = 24_000
    private nonisolated let continuation: AsyncStream<Item>.Continuation
    private nonisolated let queued = Atomic<Int>(0)
    private nonisolated let dropped = Atomic<Int>(0)
    private nonisolated let overflowReported = Atomic<Bool>(false)
    /// Bit per source: packets were dropped since its last accepted packet.
    private nonisolated let lostSources = Atomic<Int>(0)
    static let overflowReason = "Recording storage fell behind; audio was dropped"
    private nonisolated let capacity: Int
    private let sink: any CaptureAudioSink
    private let live: LiveInferenceMailbox<LiveCaptureFragment>?
    private let now: @Sendable () -> UInt64
    private let failure: @Sendable (Error) -> Void
    private var clock = CaptureIntervalClock()
    private var aligners: [AudioTrack: CaptureTrackAligner] = [.system: .init(), .microphone: .init()]
    private var pending: [AudioTrack: (start: UInt64, samples: [Float])] = [:]
    private var anchorHost: UInt64?
    private var intervalStart: UInt64 = 0
    private var checkpointFrame: UInt64 = 0
    private var checkpointHost: UInt64 = 0
    private var latestHost: UInt64 = 0
    private var timing: CaptureTimingSnapshot?
    private var boundaries: [String: UUID] = [:]
    private var sections: [AudioTrack: Int] = [:]
    private var seenDropped = 0
    private var interrupted = false
    private var problem: Error?
    private var finished = false
    public private(set) var status = CapturePipelineStatus()

    /// `capacity` bounds queued packets (32 ms each from the drivers, so the
    /// default is about 30 seconds). `failure` reports the first storage or
    /// overflow error; the owner should stop and surface it.
    public init(sink: any CaptureAudioSink, live: LiveInferenceMailbox<LiveCaptureFragment>? = nil,
                capacity: Int = 1_024, now: @escaping @Sendable () -> UInt64 = { mach_absolute_time() },
                failure: @escaping @Sendable (Error) -> Void) {
        precondition(capacity > 0)
        let stream = AsyncStream<Item>.makeStream(bufferingPolicy: .unbounded)
        continuation = stream.continuation
        self.sink = sink; self.live = live; self.capacity = capacity; self.now = now; self.failure = failure
        let items = stream.stream
        Task { await self.run(items) }
    }

    private func run(_ items: AsyncStream<Item>) async {
        for await item in items {
            switch item {
            case .packet(let packet):
                queued.subtract(1, ordering: .relaxed)
                await handle(packet)
            case .discontinuity(let source, let reason):
                aligners[track(source)]!.markBreak(reason)
            case .barrier(let done):
                done.resume()
            }
        }
    }

    /// Capture sink. Bounded, nonblocking and safe from any driver queue.
    /// Each source calls this serially, so its marker precedes its next packet.
    public nonisolated func receive(_ packet: AudioPacket) {
        let bit = packet.source == .microphone ? 2 : 1
        guard queued.add(1, ordering: .relaxed).newValue <= capacity else {
            queued.subtract(1, ordering: .relaxed)
            dropped.add(1, ordering: .relaxed)
            lostSources.bitwiseOr(bit, ordering: .relaxed)
            if !overflowReported.exchange(true, ordering: .relaxed) {
                failure(ServiceError(message: "Recording storage fell behind and some audio was dropped",
                    recovery: "Stop recording and check free disk space. Audio before and after the gap is kept."))
            }
            return
        }
        if lostSources.bitwiseAnd(~bit, ordering: .relaxed).oldValue & bit != 0 { continuation.yield(.discontinuity(packet.source, Self.overflowReason)) }
        continuation.yield(.packet(packet))
    }

    /// Coordinator restart callback: the next packet of this source starts a
    /// new section with an explicit gap.
    public nonisolated func sourceRestarted(_ source: CaptureSource, reason: String) {
        continuation.yield(.discontinuity(source, "Device changed: \(reason)"))
    }

    /// Waits until every packet accepted so far has been processed.
    public func drain() async {
        await withCheckedContinuation { done in
            // After finish() the stream is closed: nothing is left to drain.
            if case .terminated = continuation.yield(.barrier(done)) { done.resume() }
        }
    }

    /// Start or Resume. Call before the drivers start delivering packets.
    public func begin(hostTime: UInt64, wallClock: Date = Date(),
                      timeZoneIdentifier: String = TimeZone.current.identifier) async throws {
        try usable()
        guard anchorHost == nil else { throw CaptureClockError.alreadyRunning }
        do {
            try clock.begin(hostTime: hostTime, wallClock: wallClock, timeZoneIdentifier: timeZoneIdentifier)
            anchorHost = hostTime; checkpointHost = hostTime; latestHost = hostTime
            intervalStart = clock.closedSnapshot.activeFrameCount; checkpointFrame = intervalStart
            for key in aligners.keys { aligners[key]!.reset() }
            try await checkpoint(at: hostTime, state: .recording)
        } catch { throw fail(error) }
    }

    /// Pause after the coordinator has drained the drivers. Pause time is
    /// excluded from active time; the next begin() opens a new interval.
    public func pause() async throws {
        await drain()
        try usable()
        do { try await close(state: .paused) } catch { throw fail(error) }
    }

    /// Stop after the coordinator has drained the drivers. Audio already
    /// handed to the sink is finalized even after an earlier failure.
    public func finish(interrupted forced: Bool = false) async throws -> RecordingAudioManifest {
        await drain()
        continuation.finish()
        if !finished, anchorHost != nil, problem == nil {
            do { try await close(state: .stopping) } catch { _ = fail(error) }
        }
        finished = true
        noteDropped()
        return try await sink.finish(interrupted: forced || interrupted || problem != nil)
    }

    private func usable() throws {
        if finished { throw ServiceError(message: "The recording has finished", recovery: "Start a new recording.") }
        if let problem { throw problem }
    }

    @discardableResult private func fail(_ error: Error) -> Error {
        if problem == nil {
            problem = error
            if !overflowReported.exchange(true, ordering: .relaxed) { failure(error) }
        }
        return problem!
    }

    private func track(_ source: CaptureSource) -> AudioTrack { source == .microphone ? .microphone : .system }

    private func noteDropped() {
        let total = dropped.load(ordering: .relaxed)
        guard total > seenDropped else { return }
        seenDropped = total; status.droppedPackets = total; interrupted = true
    }

    private func handle(_ packet: AudioPacket) async {
        guard problem == nil, !finished, let anchor = anchorHost else { return }
        noteDropped()
        do {
            var samples = packet.samples, host = packet.hostTime
            if host < anchor {
                // Delivered before Resume's anchor: never place it in the pause.
                let early = Int((AVAudioTime.seconds(forHostTime: anchor - host) * packet.sampleRate).rounded(.up))
                guard early < samples.count else { return }
                samples.removeFirst(early); host = anchor
            }
            let target = try clock.activeFrame(at: host)
            latestHost = max(latestHost, host + AVAudioTime.hostTime(forSeconds: Double(samples.count) / packet.sampleRate))
            let key = track(packet.source)
            let outputs = try aligners[key]!.process(samples, sampleRate: packet.sampleRate,
                                                     target: target, intervalStart: intervalStart)
            status.maximumDriftFrames[key] = aligners[key]!.maximumDrift
            status.correctedFrames[key] = aligners[key]!.corrected
            for output in outputs {
                switch output {
                case let .gap(start, end, reason):
                    try await flush(key, through: nil)
                    try await gap(key, start: start, end: end, reason: reason)
                case let .audio(start, audio):
                    if let current = pending[key], current.start + UInt64(current.samples.count) != start {
                        try await flush(key, through: nil)
                    }
                    pending[key, default: (start, [])].samples.append(contentsOf: audio)
                    if pending[key]!.samples.count >= Self.batchFrames { try await flush(key, through: nil) }
                }
            }
        } catch { fail(error) }
    }

    private func checkpoint(at host: UInt64, state: RecordingState) async throws {
        let snapshot = try clock.checkpoint(at: host)
        try await sink.updateCaptureTiming(snapshot, state: state)
        timing = snapshot; checkpointHost = host; checkpointFrame = snapshot.activeFrameCount
    }

    /// Writes pending audio that the published timing covers. A batch slightly
    /// ahead of the checkpoint stays pending; at close it is trimmed to `limit`.
    private func flush(_ key: AudioTrack, through limit: UInt64?) async throws {
        guard var batch = pending[key], !batch.samples.isEmpty else { return }
        let end = batch.start + UInt64(batch.samples.count)
        if limit == nil, end > checkpointFrame {
            try await checkpoint(at: max(now(), latestHost, checkpointHost), state: .recording)
        }
        let bound = limit ?? checkpointFrame
        let count = Int(min(end, bound).subtractingReportingOverflow(batch.start).overflow ? 0 : min(end, bound) - batch.start)
        var offset = 0
        while offset < count {
            let size = min(48_000, count - offset)
            let start = batch.start + UInt64(offset)
            let slice = Array(batch.samples[offset..<(offset + size)])
            try await sink.append(track: key, samples: slice, activeStartFrame: start, hostTimeStart: hostTime(start))
            offer(key, samples: slice, start: start)
            offset += size
        }
        if limit != nil || count == batch.samples.count { pending[key] = nil; return }
        batch.samples.removeFirst(count); batch.start += UInt64(count)
        pending[key] = batch
    }

    private func gap(_ key: AudioTrack, start: UInt64, end: UInt64, reason: String) async throws {
        guard end > start else { return }
        if end > checkpointFrame { try await checkpoint(at: max(now(), latestHost, checkpointHost), state: .recording) }
        let bounded = min(end, checkpointFrame)
        guard bounded > start else { return }
        try await sink.recordGap(track: key, active: MediaInterval(start: frameTime(start), end: frameTime(bounded)), reason: reason)
        status.gaps[key, default: 0] += 1
        sections[key, default: 0] += 1
    }

    private func close(state: RecordingState) async throws {
        guard anchorHost != nil else { return }
        noteDropped()
        let host = max(now(), latestHost, checkpointHost)
        let snapshot = try clock.close(at: host)
        try await sink.updateCaptureTiming(snapshot, state: state)
        timing = snapshot; checkpointFrame = snapshot.activeFrameCount
        for key in AudioTrack.allCases {
            try await flush(key, through: checkpointFrame)
            let last = aligners[key]!.next ?? intervalStart
            if checkpointFrame > last, Int64(checkpointFrame - last) > CaptureTrackAligner.discontinuityFrames {
                try await gap(key, start: last, end: checkpointFrame, reason: aligners[key]!.next == nil
                    ? "No audio was received from the source" : "The source stopped delivering audio")
            }
            aligners[key]!.reset()
        }
        try await sink.closeInterval()
        anchorHost = nil
        for key in AudioTrack.allCases { sections[key, default: 0] += 1 }
    }

    private func hostTime(_ frame: UInt64) -> UInt64 {
        (anchorHost ?? checkpointHost) + AVAudioTime.hostTime(forSeconds: Double(frame - intervalStart) / 48_000)
    }

    private func offer(_ key: AudioTrack, samples: [Float], start: UInt64) {
        guard let live, let timing else { return }
        let time = Double(start) / 48_000
        guard let interval = timing.intervals.last(where: { $0.active.start.seconds <= time }),
              let day = timing.days.first(where: { $0.id == interval.dayID }) else { return }
        let name = "\(key.rawValue)-\(interval.active.start.microseconds)-\(sections[key, default: 0])"
        let boundary = boundaries[name] ?? UUID()
        boundaries[name] = boundary
        let fragment = LiveCaptureFragment(track: key, samples: samples, activeStartFrame: start, day: day,
            wallClockStart: interval.wallClockStart.addingTimeInterval(time - interval.active.start.seconds),
            boundaryID: boundary)
        if live.offer(fragment) == .replacedObsolete { status.replacedLiveFragments += 1 }
    }
}

private func frameTime(_ frame: UInt64) throws -> MediaTime { try MediaTime(seconds: Double(frame) / 48_000) }
