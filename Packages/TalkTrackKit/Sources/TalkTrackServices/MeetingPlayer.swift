@preconcurrency import AVFoundation
import Foundation
import Observation
import TalkTrackDomain

public enum PlaybackSpeed: Double, CaseIterable, Identifiable, Sendable {
    case normal = 1, oneAndHalf = 1.5, double = 2, twoAndHalf = 2.5, triple = 3
    public var id: Double { rawValue }
    public var label: String {
        switch self {
        case .normal: "1×"
        case .oneAndHalf: "1.5×"
        case .double: "2×"
        case .twoAndHalf: "2.5×"
        case .triple: "3×"
        }
    }
}

public enum PlaybackState: Equatable, Sendable {
    /// No meeting, or a meeting with no recorded audio.
    case unavailable
    case paused
    case playing
    case ended
    case failed(message: String, recovery: String?, recordingID: UUID?)
}

/// Why a meeting has nothing to play, for the player's explanatory state.
public enum PlaybackUnavailability: Equatable, Sendable {
    case noMeeting
    /// The meeting has never been recorded.
    case noRecordings
    /// Its only recordings are still being captured; they play after Stop.
    case recordingInProgress
    /// Recordings exist but captured no audio (for example interrupted at once).
    case noRecordedAudio

    public var message: String {
        switch self {
        case .noMeeting: "No meeting selected"
        case .noRecordings: "No recorded audio yet. Press Record to capture this meeting."
        case .recordingInProgress: "This recording can be played after you stop it."
        case .noRecordedAudio: "The recordings of this meeting contain no audio."
        }
    }
}

/// Where a recording sits in its meeting, so errors can name it.
public struct PlaybackRecordingInfo: Equatable, Sendable {
    public let number: Int
    public let count: Int
    public let startedAt: Date
    public let timeZoneIdentifier: String
    /// Global timeline interval of the recording.
    public let interval: MediaInterval
}

/// The meeting player: one continuous timeline over separate recordings.
///
/// Both tracks of a block are mixed into one buffer before scheduling, so they
/// cannot drift apart; one time-pitch unit applies the speed to the mix and
/// keeps the pitch. Positions are always source time: the player node counts
/// source frames upstream of the time-pitch unit. Decoding runs on the
/// source's executor; the main actor only schedules ready buffers a few
/// seconds ahead.
@MainActor @Observable public final class MeetingPlayer: CapturePlaybackExclusion {
    public enum Output: Sendable {
        case device
        /// Manual offline rendering for tests: nothing reaches an audio device.
        case offline
    }

    public private(set) var state: PlaybackState = .unavailable
    public private(set) var position: MediaTime = .zero
    public private(set) var duration: MediaTime = .zero
    public private(set) var meetingID: UUID?
    /// The timeline being played, so transcript timing matches the audio exactly.
    public private(set) var timeline: MeetingTimeline?
    /// The recording under the playhead.
    public private(set) var currentRecordingID: UUID?
    /// Set while `state` is `.unavailable`.
    public private(set) var unavailability: PlaybackUnavailability? = .noMeeting
    /// Stretches whose files are missing or damaged, found by checking every
    /// chunk after loading and before retrying. Empty until the check ends.
    public private(set) var damagedAudio: [DamagedAudio] = []
    public private(set) var checkingAudio = false
    public var speed: PlaybackSpeed = .normal { didSet { applySpeed() } }
    /// Set while TalkTrack is capturing: playback would be recaptured.
    public var captureActive = false { didSet { if captureActive { pause() } } }

    public var canPlay: Bool {
        guard !captureActive, duration > .zero else { return false }
        if case .unavailable = state { return false }
        return true
    }

    /// Source frames scheduled ahead of the playhead.
    static let lookaheadFrames = 4 * 48_000
    static let blockFrames = 48_000

    private let library: OpenedLibrary
    private let output: Output
    @ObservationIgnored private var source: MeetingAudioSource?
    @ObservationIgnored private var recordingsKey: [Recording] = []
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var node: AVAudioPlayerNode?
    @ObservationIgnored private var pitch: AVAudioUnitTimePitch?
    @ObservationIgnored private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    /// Global frame at which the node last started; the node's sample time counts from it.
    @ObservationIgnored private var startFrame: UInt64 = 0
    @ObservationIgnored private var scheduledEnd: UInt64 = 0
    @ObservationIgnored private var exhausted = false
    @ObservationIgnored private var readError: (any Error)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var filling = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var pendingStart: Task<Void, Never>?
    /// The audible position is integrated from the output clock: the player
    /// node's own sample time counts frames the time-pitch unit has pulled
    /// ahead, not frames heard. Re-anchored on every start and speed change.
    @ObservationIgnored private var nodeStarted = false
    @ObservationIgnored private var anchorFrame = 0.0
    @ObservationIgnored private var anchorClock = 0.0
    @ObservationIgnored private var anchorRate = 1.0
    @ObservationIgnored private var renderedFrames = 0
    @ObservationIgnored private var configurationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var check: Task<Void, Never>?
    @ObservationIgnored private var checkGeneration = 0

    public init(library: OpenedLibrary, output: Output = .device) {
        self.library = library; self.output = output
    }

    // MARK: Loading

    /// Shows `recordings` of a meeting. The same meeting keeps its position
    /// when recordings are appended; another meeting stops and starts at zero.
    public func load(meetingID: UUID?, recordings: [Recording]) {
        let usable = meetingID.map { Self.playable(recordings, meetingID: $0) } ?? []
        let emptyReason: PlaybackUnavailability = meetingID == nil ? .noMeeting
            : recordings.contains { $0.meetingID == meetingID } ? .recordingInProgress : .noRecordings
        if meetingID == self.meetingID, usable == recordingsKey, source != nil || usable.isEmpty {
            if usable.isEmpty { unavailability = emptyReason }
            return
        }
        let sameMeeting = meetingID == self.meetingID
        let resumeAt = sameMeeting ? position : .zero
        let wasPlaying = sameMeeting && state == .playing
        stopNode()
        cancelCheck()
        if !sameMeeting { damagedAudio = [] }
        self.meetingID = meetingID; recordingsKey = usable; source = nil; exhausted = false; timeline = nil
        unavailability = nil
        guard let meetingID, !usable.isEmpty else {
            duration = .zero; position = .zero; currentRecordingID = nil; state = .unavailable; damagedAudio = []
            unavailability = emptyReason
            return
        }
        do {
            let source = try MeetingAudioSource(library: library, meetingID: meetingID, recordings: usable)
            self.source = source
            timeline = source.timeline
            duration = source.timeline.totalDuration
            guard duration > .zero else {
                position = .zero; state = .unavailable; damagedAudio = []
                unavailability = .noRecordedAudio
                return
            }
            position = min(resumeAt, duration)
            currentRecordingID = source.recordingID(atFrame: (try? source.frame(at: position)) ?? 0)
            state = position == duration ? .ended : .paused
            checkAudio()
            if wasPlaying { play() }
        } catch {
            duration = .zero; position = .zero; currentRecordingID = nil
            state = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                            recovery: (error as? LocalizedError)?.recoverySuggestion, recordingID: nil)
        }
    }

    /// Finished recordings of the meeting; one still being captured is not
    /// played and is not part of the timeline until it stops.
    public static func playable(_ recordings: [Recording], meetingID: UUID) -> [Recording] {
        recordings.filter { $0.meetingID == meetingID && ![.preparing, .recording, .paused, .stopping].contains($0.state) }
    }

    // MARK: Controls

    public func toggle() { state == .playing ? pause() : play() }

    public func play() {
        guard canPlay, let source, state != .playing else { return }
        // Retrying after an error: files may have been restored meanwhile.
        if case .failed = state { checkAudio() }
        if state == .ended || position >= duration { position = .zero }
        do {
            try prepareEngine()
            let frame = try source.frame(at: position)
            currentRecordingID = source.recordingID(atFrame: frame)
            start(at: frame)
        } catch {
            fail(error)
        }
    }

    public func pause() {
        guard state == .playing else { return }
        updatePosition()
        stopNode()
        state = .paused
    }

    /// Seeks anywhere on the meeting timeline; playing continues from there.
    public func seek(to time: MediaTime) {
        guard let source, duration > .zero else { return }
        let target = min(time, duration)
        let playing = state == .playing
        stopNode()
        if playing { state = .paused }
        position = target
        currentRecordingID = source.recordingID(atFrame: (try? source.frame(at: target)) ?? source.totalFrames)
        if target == duration { state = .ended; return }
        if case .failed = state { state = .paused }
        if state == .ended { state = .paused }
        if playing { play() }
    }

    /// A transcript timestamp: seeks to `time` of `meetingID` and plays.
    /// Refused for another meeting than the one loaded, or while capturing.
    @discardableResult public func play(from time: MediaTime, meetingID: UUID) -> Bool {
        guard meetingID == self.meetingID, canPlay, time < duration else { return false }
        seek(to: time)
        if state != .playing { play() }
        return true
    }

    /// The recording containing `id`, numbered in timeline order.
    public func recordingInfo(_ id: UUID) -> PlaybackRecordingInfo? {
        guard let timeline, let index = timeline.recordings.firstIndex(where: { $0.recordingID == id }),
              let recording = recordingsKey.first(where: { $0.id == id }) else { return nil }
        return PlaybackRecordingInfo(number: index + 1, count: timeline.recordings.count, startedAt: recording.startedAt,
                                     timeZoneIdentifier: recording.timeZoneIdentifier, interval: timeline.recordings[index].global)
    }

    /// After an unreadable file: the first position past every damaged
    /// stretch that contains the playhead, within the same or a later
    /// recording. Nil when nothing readable follows. Never chosen automatically.
    public var readablePositionAfterFailure: MediaTime? {
        guard case .failed = state else { return nil }
        var time = position
        while let damage = damagedAudio.first(where: { $0.interval.start <= time && time < $0.interval.end }) {
            time = damage.interval.end
        }
        if time == position, case let .failed(_, _, id) = state, let id, let info = recordingInfo(id) {
            // The check has not found the damage (yet): continue with the next recording.
            time = info.interval.end
        }
        return time < duration ? time : nil
    }

    /// Re-checks every chunk off the main actor, for example after files were restored.
    public func checkAudio() {
        cancelCheck()
        guard let source else { damagedAudio = []; return }
        checkGeneration += 1
        let generation = checkGeneration
        checkingAudio = true
        check = Task { [weak self] in
            let flag = CancellationFlag()
            let found = await withTaskCancellationHandler {
                await source.damagedAudio(isCancelled: { flag.isSet })
            } onCancel: { flag.set() }
            guard let self, generation == self.checkGeneration, !Task.isCancelled else { return }
            self.damagedAudio = found
            self.checkingAudio = false
        }
    }

    /// Waits for the current file check (tests).
    func waitForAudioCheck() async { await check?.value }

    private func cancelCheck() {
        check?.cancel(); check = nil
        checkGeneration += 1
        checkingAudio = false
    }

    nonisolated public func stopPlaybackBeforeCapture() async {
        await MainActor.run { self.pause() }
    }

    // MARK: Engine

    private func prepareEngine() throws {
        if let engine, engine.isRunning || output == .offline { return }
        if engine == nil {
            let engine = AVAudioEngine(), node = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
            if output == .offline {
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
            }
            engine.attach(node); engine.attach(pitch)
            engine.connect(node, to: pitch, format: format)
            engine.connect(pitch, to: engine.mainMixerNode, format: format)
            self.engine = engine; self.node = node; self.pitch = pitch
            applySpeed()
            if let diagnosticTap { Self.installTap(on: pitch, format: format, diagnosticTap) }
            if diagnosticMute { engine.mainMixerNode.outputVolume = 0 }
            if output == .device {
                configurationObserver = NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.outputChanged() }
                }
            }
        }
        do { try engine!.start() } catch { throw PlaybackError.outputUnavailable(error.localizedDescription) }
    }

    /// The output device changed (for example headphones were removed): stop
    /// at the current position instead of continuing on another device.
    private func outputChanged() {
        guard state == .playing else { return }
        updatePosition()
        stopNode()
        state = .paused
    }

    private func applySpeed() {
        if nodeStarted {
            anchorFrame = estimatedFrame(); anchorClock = outputClock()
        }
        anchorRate = speed.rawValue
        pitch?.rate = Float(speed.rawValue)
        // At 1× the mix passes unchanged.
        pitch?.bypass = speed == .normal
    }

    private func start(at frame: UInt64) {
        guard let node, let source else { return }
        generation += 1
        startFrame = frame; scheduledEnd = frame; exhausted = false; readError = nil
        state = .playing
        let generation = generation
        pendingStart = Task {
            await source.seek(toFrame: frame)
            await fill(generation)
            guard generation == self.generation, state == .playing else { return }
            node.play()
            nodeStarted = true
            anchorFrame = Double(frame); anchorRate = speed.rawValue
            anchorClock = outputClock() + (output == .device ? engine?.outputNode.presentationLatency ?? 0 : 0)
            // Offline rendering drives the schedule itself.
            if output == .device { startTicker() }
        }
    }

    private func stopNode() {
        generation += 1
        ticker?.cancel(); ticker = nil
        nodeStarted = false
        node?.stop()
        // Drop audio the time-pitch unit buffered from before a seek.
        pitch?.reset()
        if output == .device { engine?.pause() }
    }

    /// Schedules decoded blocks until the lookahead is full or the meeting ends.
    func fill(_ generation: Int) async {
        guard !filling, let source, let node else { return }
        filling = true; defer { filling = false }
        while generation == self.generation, !exhausted,
              scheduledEnd < playedFrame() + UInt64(Self.lookaheadFrames) {
            let block: PlaybackBlock?
            do { block = try await source.next(maximumFrames: Self.blockFrames) } catch {
                guard generation == self.generation else { return }
                // Audio before the unreadable file is already scheduled; it
                // plays out, then playback stops exactly there (see tick).
                readError = error; exhausted = true
                return
            }
            guard generation == self.generation else { return }
            guard let block else { exhausted = true; return }
            Self.schedule(Self.mix(block, format: format), on: node)
            scheduledEnd = block.globalStartFrame + UInt64(block.frameCount)
        }
    }

    /// Synchronous on purpose: nothing waits for the buffer to finish playing.
    private static func schedule(_ buffer: AVAudioPCMBuffer, on node: AVAudioPlayerNode) {
        node.scheduleBuffer(buffer, completionHandler: nil)
    }

    static func mix(_ block: PlaybackBlock, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block.frameCount))!
        buffer.frameLength = AVAudioFrameCount(block.frameCount)
        let out = buffer.floatChannelData![0]
        for i in 0..<block.frameCount {
            out[i] = max(-1, min(1, block.system[i] + block.microphone[i]))
        }
        return buffer
    }

    private func outputClock() -> Double {
        output == .offline ? Double(renderedFrames) / 48_000 : Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    private func estimatedFrame() -> Double {
        anchorFrame + max(0, outputClock() - anchorClock) * anchorRate * 48_000
    }

    /// The source frame being heard, never past what has been scheduled.
    private func playedFrame() -> UInt64 {
        guard nodeStarted else { return startFrame }
        return min(scheduledEnd, UInt64(estimatedFrame().rounded(.down)))
    }

    private func updatePosition() {
        guard let source, state == .playing else { return }
        let frame = playedFrame()
        position = source.time(atFrame: frame)
        currentRecordingID = source.recordingID(atFrame: frame)
    }

    private func startTicker() {
        ticker?.cancel()
        let generation = generation
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, generation == self.generation else { return }
                await self.tick(generation)
            }
        }
    }

    /// Advances the published position, tops up the lookahead and detects the end.
    func tick(_ generation: Int) async {
        guard generation == self.generation, state == .playing else { return }
        updatePosition()
        if exhausted, playedFrame() >= scheduledEnd {
            if let readError, let source {
                stopNode()
                position = source.time(atFrame: scheduledEnd)
                currentRecordingID = source.recordingID(atFrame: scheduledEnd)
                fail(readError)
                return
            }
            stopNode()
            position = duration; currentRecordingID = nil
            state = .ended
            return
        }
        await fill(generation)
    }

    private func fail(_ error: any Error) {
        stopNode()
        let playback = error as? PlaybackError
        var recordingID: UUID?
        if case let .unreadableAudio(id, _, _, _) = playback { recordingID = id }
        state = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                        recovery: (error as? LocalizedError)?.recoverySuggestion, recordingID: recordingID)
        // Make the reported stretch exact if the last check did not find it.
        if recordingID != nil, !checkingAudio,
           !damagedAudio.contains(where: { $0.interval.start <= position && position < $0.interval.end }) { checkAudio() }
    }

    // MARK: Diagnostics

    @ObservationIgnored private var diagnosticTap: (@Sendable (UnsafeBufferPointer<Float>) -> Void)?
    @ObservationIgnored private var diagnosticMute = false

    /// The tap runs on an audio thread, never on the main actor.
    private nonisolated static func installTap(on node: AVAudioNode, format: AVAudioFormat,
                                               _ receive: @escaping @Sendable (UnsafeBufferPointer<Float>) -> Void) {
        node.installTap(onBus: 0, bufferSize: 4_800, format: format) { buffer, _ in
            receive(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
    }

    /// For the device playback check: receives the time-stretched mix as the
    /// output device pulls it, and optionally mutes the device. Call before
    /// the first play.
    @_spi(Diagnostics) public func observeOutput(muted: Bool, _ receive: @escaping @Sendable (UnsafeBufferPointer<Float>) -> Void) {
        diagnosticTap = receive; diagnosticMute = muted
    }

    // MARK: Offline rendering (tests)

    /// Renders `frames` output frames in `.offline` mode, topping up the
    /// schedule as the device ticker would.
    func renderOffline(frames: Int) async throws -> [Float] {
        guard output == .offline, let engine else { return [] }
        var result: [Float] = []
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1_024)!
        while result.count < frames, state == .playing {
            await tick(generation)
            guard state == .playing else { break }
            let count = AVAudioFrameCount(min(1_024, frames - result.count))
            let status = try engine.renderOffline(count, to: buffer)
            guard status == .success else { break }
            result.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            renderedFrames += Int(buffer.frameLength)
        }
        return result
    }

    /// Waits for a pending start (seek and first decoding) to begin playing.
    func waitUntilStarted() async { await pendingStart?.value }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
