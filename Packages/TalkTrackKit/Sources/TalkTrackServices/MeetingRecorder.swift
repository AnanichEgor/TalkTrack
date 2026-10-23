import Darwin
import Foundation
import TalkTrackAudio
import TalkTrackDomain

/// Capture control used by `MeetingRecorder`; `CaptureCoordinator` in the app.
public protocol MeetingCaptureControl: Actor {
    func start(timeout: Duration) async throws
    func pause() async throws
    func stop() async
}

extension CaptureCoordinator: MeetingCaptureControl {}

/// Callbacks the recorder hands to a new capture control for each recording.
public struct MeetingCaptureCallbacks: Sendable {
    public let receive: @Sendable (AudioPacket) -> Void
    public let restarted: @Sendable (CaptureSource, String) -> Void
    public let failed: @Sendable (AudioCaptureError) -> Void

    public init(receive: @escaping @Sendable (AudioPacket) -> Void,
                restarted: @escaping @Sendable (CaptureSource, String) -> Void,
                failed: @escaping @Sendable (AudioCaptureError) -> Void) {
        self.receive = receive; self.restarted = restarted; self.failed = failed
    }
}

/// TalkTrack's player. Capture starts only after playback has stopped, so a
/// meeting being played never becomes part of the new recording.
public protocol CapturePlaybackExclusion: Sendable {
    func stopPlaybackBeforeCapture() async
}

/// How Stop selects the immutable final-transcription job inputs.
public struct FinalJobPolicy: Sendable {
    public let models: @Sendable () throws -> [ModelSnapshot]
    /// Never downloads; missing roles leave the job waiting for models.
    public let missing: @Sendable ([ModelSnapshot]) async throws -> [ModelRole]
    public let settings: @Sendable (Meeting) -> ProcessingSettings

    public init(models: @escaping @Sendable () throws -> [ModelSnapshot],
                missing: @escaping @Sendable ([ModelSnapshot]) async throws -> [ModelRole],
                settings: @escaping @Sendable (Meeting) -> ProcessingSettings) {
        self.models = models; self.missing = missing; self.settings = settings
    }

    /// Current catalog selections for every final-transcription role.
    public static func catalog(_ catalog: ModelCatalog,
                               missing: @escaping @Sendable ([ModelSnapshot]) async throws -> [ModelRole],
                               settings: @escaping @Sendable (Meeting) -> ProcessingSettings) -> FinalJobPolicy {
        Self.catalog({ catalog }, missing: missing, settings: settings)
    }

    /// Reads the catalog at each Stop, so a text model chosen in Settings applies to the next job.
    public static func catalog(_ catalog: @escaping @Sendable () -> ModelCatalog,
                               missing: @escaping @Sendable ([ModelSnapshot]) async throws -> [ModelRole],
                               settings: @escaping @Sendable (Meeting) -> ProcessingSettings) -> FinalJobPolicy {
        FinalJobPolicy(models: {
            let catalog = catalog()
            return try FinalTranscriptionPipeline.requiredRoles.map { try catalog.model(for: $0).snapshot(for: $0) }
        }, missing: missing, settings: settings)
    }
}

public enum MeetingRecorderPhase: String, Sendable { case idle, starting, recording, paused, stopping }

public struct RecorderIssue: Equatable, Sendable {
    public let message: String
    public let recovery: String?
    public let settingsURL: URL?

    init(_ error: Error) {
        message = error.localizedDescription
        recovery = (error as? LocalizedError)?.recoverySuggestion
        settingsURL = (error as? AudioCaptureError)?.settingsURL
    }
}

public struct RecordingStopResult: Sendable {
    public let recording: Recording
    public let job: ProcessingJob?
    /// Why no job could be queued; the saved audio can still be processed later.
    public let jobIssue: String?
    /// The capture or storage failure that ended or interrupted the recording.
    public let issue: RecorderIssue?
}

public struct RecordingRecoveryResult: Sendable {
    public let meetingID: UUID
    public let recordingID: UUID
    public let recording: Recording?
    public let job: ProcessingJob?
    public let issue: String?
}

public enum MeetingRecorderEvent: Sendable {
    case phase(MeetingRecorderPhase, meetingID: UUID?, recordingID: UUID?)
    /// Capture or storage failed; the recording is being finalized safely.
    case interrupted(meetingID: UUID, recordingID: UUID, RecorderIssue)
    case stopped(RecordingStopResult)
}

/// Owns at most one capture at a time and connects it to durable meeting
/// storage. Each Record action creates a separate recording folder; Pause and
/// Stop publish the committed audio to the library, Stop queues final
/// transcription, and relaunch recovery adopts audio left by a crash.
public actor MeetingRecorder {
    public nonisolated let events: AsyncStream<MeetingRecorderEvent>
    public private(set) var phase: MeetingRecorderPhase = .idle
    public var activeMeetingID: UUID? { active?.recording.meetingID }
    public var activeRecordingID: UUID? { active?.recording.id }
    public var pipelineStatus: CapturePipelineStatus? { get async { await active?.pipeline.status } }
    /// Live input levels and elapsed time of the active recording.
    public nonisolated let levels = AudioLevelMeter()

    private let library: OpenedLibrary
    private let store: SessionStore
    private let makeCapture: @Sendable (MeetingCaptureCallbacks) -> any MeetingCaptureControl
    private let playback: (any CapturePlaybackExclusion)?
    private let jobs: FinalJobPolicy
    private let hostClock: @Sendable () -> UInt64
    private let wallClock: @Sendable () -> Date
    private let timeZone: @Sendable () -> String
    private let startTimeout: Duration
    private let wrapSink: (@Sendable (RecordingAudioWriter) -> any CaptureAudioSink)?
    private let systemAudioAccess: (@Sendable () async throws -> Void)?
    private let continuation: AsyncStream<MeetingRecorderEvent>.Continuation
    private var active: Active?
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private struct Active {
        var recording: Recording
        let writer: RecordingAudioWriter
        let pipeline: RecordingCapturePipeline
        let capture: any MeetingCaptureControl
        var issue: RecorderIssue?
    }

    public init(library: OpenedLibrary, store: SessionStore,
                capture: @escaping @Sendable (MeetingCaptureCallbacks) -> any MeetingCaptureControl,
                playback: (any CapturePlaybackExclusion)? = nil, jobs: FinalJobPolicy,
                startTimeout: Duration = .seconds(20),
                systemAudioAccess: (@Sendable () async throws -> Void)? = nil) {
        self.init(library: library, store: store, capture: capture, playback: playback, jobs: jobs,
                  startTimeout: startTimeout, hostClock: { mach_absolute_time() }, wallClock: { Date() },
                  timeZone: { TimeZone.current.identifier }, wrapSink: nil, systemAudioAccess: systemAudioAccess)
    }

    init(library: OpenedLibrary, store: SessionStore,
         capture: @escaping @Sendable (MeetingCaptureCallbacks) -> any MeetingCaptureControl,
         playback: (any CapturePlaybackExclusion)?, jobs: FinalJobPolicy, startTimeout: Duration,
         hostClock: @escaping @Sendable () -> UInt64, wallClock: @escaping @Sendable () -> Date,
         timeZone: @escaping @Sendable () -> String,
         wrapSink: (@Sendable (RecordingAudioWriter) -> any CaptureAudioSink)?,
         systemAudioAccess: (@Sendable () async throws -> Void)? = nil) {
        self.library = library; self.store = store; makeCapture = capture; self.playback = playback
        self.jobs = jobs; self.startTimeout = startTimeout; self.hostClock = hostClock
        self.wallClock = wallClock; self.timeZone = timeZone; self.wrapSink = wrapSink
        self.systemAudioAccess = systemAudioAccess
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// Native microphone + Core Audio process tap system audio.
    public static func nativeCapture(deviceID: UInt32? = nil) -> @Sendable (MeetingCaptureCallbacks) -> any MeetingCaptureControl {
        { CaptureCoordinator.native(deviceID: deviceID, receive: $0.receive, restarted: $0.restarted, failed: $0.failed) }
    }

    /// Uses the microphone selected in Settings. The selection is read once per
    /// recording, so changing it never switches inputs inside a recording.
    public static func nativeCapture(selection: @escaping @Sendable () -> (uid: String, name: String)?)
        -> @Sendable (MeetingCaptureCallbacks) -> any MeetingCaptureControl {
        { callbacks in
            let selected = selection()
            return CaptureCoordinator.native(microphone: {
                try selected.map { try NativeAudioDevices.input(uid: $0.uid, name: $0.name) }
            }, receive: callbacks.receive, restarted: callbacks.restarted, failed: callbacks.failed)
        }
    }

    // MARK: Record / Pause / Resume / Stop

    /// Adds a new recording to an existing meeting. Earlier recordings are never
    /// reopened or joined. Throws, with nothing claimed as recording, when either
    /// source fails to start; audio that did arrive is kept as interrupted.
    /// System audio access is confirmed first (cached once allowed), so a denied
    /// tap never creates a recording of silence.
    @discardableResult
    public func start(meetingID: UUID, live: LiveInferenceMailbox<LiveCaptureFragment>? = nil) async throws -> Recording {
        await acquire(); defer { release() }
        guard active == nil, phase == .idle else {
            throw ServiceError(message: "Another recording is already active",
                               recovery: "Stop the current recording before recording another meeting.")
        }
        set(.starting, meetingID: meetingID, recordingID: nil)
        do {
            _ = try await store.meeting(meetingID)
            try await systemAudioAccess?()
            await playback?.stopPlaybackBeforeCapture()
            let startedAt = wallClock(), zone = timeZone()
            var recording = try Recording(meetingID: meetingID, startedAt: startedAt, timeZoneIdentifier: zone)
            let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
            let id = recording.id
            let pipeline = RecordingCapturePipeline(sink: wrapSink?(writer) ?? writer, live: live, now: hostClock,
                failure: { [weak self] error in Task { await self?.failed(recordingID: id, error: error) } })
            let levels = levels
            levels.reset()
            let capture = makeCapture(MeetingCaptureCallbacks(
                receive: { levels.record($0); pipeline.receive($0) },
                restarted: { pipeline.sourceRestarted($0, reason: $1) },
                failed: { [weak self] error in Task { await self?.failed(recordingID: id, error: error) } }))
            do {
                try await pipeline.begin(hostTime: hostClock(), wallClock: startedAt, timeZoneIdentifier: zone)
                try await capture.start(timeout: startTimeout)
            } catch {
                await capture.stop()
                await abandonStart(writer: writer, pipeline: pipeline, recording: recording)
                throw error
            }
            recording.state = .recording
            do { try await store.saveRecording(recording) } catch {
                // The folder stays on disk; relaunch recovery adopts its audio.
                await capture.stop()
                _ = try? await pipeline.finish(interrupted: true)
                throw error
            }
            active = Active(recording: recording, writer: writer, pipeline: pipeline, capture: capture)
            set(.recording, meetingID: meetingID, recordingID: id)
            return recording
        } catch {
            set(.idle, meetingID: nil, recordingID: nil)
            throw error
        }
    }

    /// Pause stops both sources and publishes committed audio. Pause time is
    /// excluded from the active timeline.
    public func pause() async throws {
        await acquire(); defer { release() }
        guard var current = active, phase == .recording else {
            throw ServiceError(message: "Only an active recording can be paused", recovery: "Start or resume recording first.")
        }
        do {
            try await current.capture.pause()
            try await current.pipeline.pause()
        } catch {
            current.issue = current.issue ?? RecorderIssue(error); active = current
            _ = await finalize(interrupted: true)
            throw error
        }
        let snapshot = await current.writer.snapshot().recording
        do { current.recording = try await publish(snapshot, over: current.recording) }
        catch { active = current; set(.paused, meetingID: current.recording.meetingID, recordingID: current.recording.id); throw error }
        active = current
        set(.paused, meetingID: current.recording.meetingID, recordingID: current.recording.id)
    }

    /// Resume continues the same recording with a new wall-clock anchor, which
    /// may be on a later day. A failed restart ends the recording as interrupted.
    public func resume() async throws {
        await acquire(); defer { release() }
        guard let current = active, phase == .paused else {
            throw ServiceError(message: "Only a paused recording can be resumed", recovery: "Start a new recording instead.")
        }
        set(.starting, meetingID: current.recording.meetingID, recordingID: current.recording.id)
        do {
            await playback?.stopPlaybackBeforeCapture()
            try await current.pipeline.begin(hostTime: hostClock(), wallClock: wallClock(), timeZoneIdentifier: timeZone())
            try await current.capture.start(timeout: startTimeout)
        } catch {
            await current.capture.stop()
            active?.issue = RecorderIssue(error)
            _ = await finalize(interrupted: true)
            throw error
        }
        set(.recording, meetingID: current.recording.meetingID, recordingID: current.recording.id)
    }

    /// Finalizes the audio, publishes the recording and queues final
    /// transcription. Errors after the audio is saved are reported in the result.
    public func stop() async throws -> RecordingStopResult {
        await acquire(); defer { release() }
        guard active != nil else {
            throw ServiceError(message: "No recording is active", recovery: "Start a recording first.")
        }
        return await finalize(interrupted: false)
    }

    // MARK: Failures

    private func failed(recordingID: UUID, error: Error) async {
        await acquire(); defer { release() }
        guard var current = active, current.recording.id == recordingID else { return }
        let issue = RecorderIssue(error)
        current.issue = current.issue ?? issue; active = current
        continuation.yield(.interrupted(meetingID: current.recording.meetingID, recordingID: recordingID, issue))
        _ = await finalize(interrupted: true)
    }

    /// Stops capture, flushes every accepted frame and publishes the result.
    /// Always leaves the recorder idle; the folder keeps all committed audio.
    private func finalize(interrupted: Bool) async -> RecordingStopResult {
        let current = active!
        set(.stopping, meetingID: current.recording.meetingID, recordingID: current.recording.id)
        defer { active = nil; set(.idle, meetingID: nil, recordingID: nil) }
        await current.capture.stop()
        var issue = current.issue
        var final: Recording
        do { final = try await current.pipeline.finish(interrupted: interrupted || issue != nil).recording }
        catch {
            issue = issue ?? RecorderIssue(error)
            final = await current.writer.snapshot().recording
            final.state = .interrupted
        }
        if final.state == .interrupted, issue == nil {
            issue = RecorderIssue(ServiceError(message: "The recording was interrupted",
                recovery: "Completed audio was kept and can be transcribed."))
        }
        do { final = try await publish(final, over: current.recording) } catch {
            let result = RecordingStopResult(recording: final, job: nil,
                jobIssue: "The recording could not be saved to the library: \(error.localizedDescription). Its audio folder is kept and will be recovered on the next launch.",
                issue: issue ?? RecorderIssue(error))
            continuation.yield(.stopped(result))
            return result
        }
        let (job, jobIssue) = await queueFinalJob(final)
        let result = RecordingStopResult(recording: final, job: job, jobIssue: jobIssue, issue: issue)
        continuation.yield(.stopped(result))
        return result
    }

    private func abandonStart(writer: RecordingAudioWriter, pipeline: RecordingCapturePipeline, recording: Recording) async {
        let manifest: RecordingAudioManifest
        do { manifest = try await pipeline.finish(interrupted: true) }
        catch { return }  // Keep the folder; relaunch recovery decides.
        if manifest.audio.isEmpty {
            try? await RecordingAudioWriter.discardEmpty(library: library, meetingID: recording.meetingID, recordingID: recording.id)
        } else if let saved = try? await publish(manifest.recording, over: nil) {
            _ = await queueFinalJob(saved)
        }
    }

    // MARK: Library publication

    private func publish(_ recording: Recording, over previous: Recording?) async throws -> Recording {
        var value = recording
        value.generation = previous.map { $0.generation + 1 } ?? 0
        if [RecordingState.complete, .interrupted].contains(value.state), value.endedAt == nil {
            value.endedAt = value.captureIntervals.last.map {
                $0.wallClockStart.addingTimeInterval($0.active.end.seconds - $0.active.start.seconds)
            } ?? value.startedAt
        }
        try await store.saveRecording(value)
        return value
    }

    private func queueFinalJob(_ recording: Recording) async -> (ProcessingJob?, String?) {
        guard !recording.chunks.isEmpty else { return (nil, "No audio was saved, so there is nothing to transcribe.") }
        do {
            let meeting = try await store.meeting(recording.meetingID)
            let models = try jobs.models()
            var job = try await store.enqueue(kind: .finalTranscription, meetingID: recording.meetingID,
                recordingID: recording.id, settings: jobs.settings(meeting), models: models)
            let missing = FinalTranscriptionPipeline.blocking(try await jobs.missing(models), settings: job.snapshot.settings)
            if !missing.isEmpty {
                let names = missing.map(\.rawValue).sorted().joined(separator: ", ")
                try await store.updateJob(job.id, stage: .waitingForModels,
                    error: "Final transcription is waiting for models: \(names). Download them in Settings.")
                job = try await store.job(job.id)
            }
            return (job, nil)
        } catch {
            return (nil, "Final transcription could not be queued: \(error.localizedDescription)")
        }
    }

    // MARK: Relaunch recovery

    /// Run once at launch before any recording starts. Recordings left in a
    /// capture state are rebuilt from their committed audio, marked interrupted
    /// and queued for final transcription. Folders a crash left without a
    /// library record are adopted when they hold audio and removed when empty.
    public func recoverAfterRelaunch() async throws -> [RecordingRecoveryResult] {
        await acquire(); defer { release() }
        guard active == nil else {
            throw ServiceError(message: "Recovery cannot run during a recording", recovery: "Stop recording first.")
        }
        let open: Set<RecordingState> = [.preparing, .recording, .paused, .stopping]
        var results: [RecordingRecoveryResult] = []
        for meeting in try await store.meetings() {
            let stored = try await store.recordings(meetingID: meeting.id)
            let known = Set(stored.map(\.id))
            let folders = (try? await RecordingAudioWriter.storedRecordingIDs(library: library, meetingID: meeting.id)) ?? []
            for previous in stored where open.contains(previous.state) {
                results.append(await recover(meetingID: meeting.id, recordingID: previous.id, previous: previous))
            }
            for id in folders where !known.contains(id) {
                // A deleted recording whose folder could not be removed yet stays deleted.
                if (try? await store.isDeletedRecording(id)) != false { continue }
                results.append(await recover(meetingID: meeting.id, recordingID: id, previous: nil))
            }
        }
        return results
    }

    private func recover(meetingID: UUID, recordingID: UUID, previous: Recording?) async -> RecordingRecoveryResult {
        do {
            let manifest: RecordingAudioManifest
            do { manifest = try await RecordingAudioWriter.recover(library: library, meetingID: meetingID, recordingID: recordingID) }
            catch LibraryError.unavailable(_) where previous != nil {
                var lost = previous!
                lost.state = .interrupted
                let saved = try await publish(lost, over: previous)
                return RecordingRecoveryResult(meetingID: meetingID, recordingID: recordingID, recording: saved, job: nil,
                    issue: "The recording folder is missing; the recording was marked interrupted.")
            }
            if previous == nil, manifest.audio.isEmpty {
                try await RecordingAudioWriter.discardEmpty(library: library, meetingID: meetingID, recordingID: recordingID)
                return RecordingRecoveryResult(meetingID: meetingID, recordingID: recordingID, recording: nil, job: nil, issue: nil)
            }
            let saved = try await publish(manifest.recording, over: previous)
            let (job, jobIssue) = await queueFinalJob(saved)
            return RecordingRecoveryResult(meetingID: meetingID, recordingID: recordingID, recording: saved, job: job, issue: jobIssue)
        } catch {
            return RecordingRecoveryResult(meetingID: meetingID, recordingID: recordingID, recording: previous, job: nil,
                issue: "Recording recovery failed; its folder was kept: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    /// Test hook: waits until the active pipeline has processed accepted packets.
    func drainCapture() async { await active?.pipeline.drain() }

    private func set(_ next: MeetingRecorderPhase, meetingID: UUID?, recordingID: UUID?) {
        phase = next
        continuation.yield(.phase(next, meetingID: meetingID, recordingID: recordingID))
    }

    /// FIFO serialization across suspension points: user actions and failure
    /// handling never interleave inside one recording transition.
    private func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}
