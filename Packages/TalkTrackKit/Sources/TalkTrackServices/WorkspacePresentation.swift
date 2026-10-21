import Foundation
import Observation
import TalkTrackDomain

public struct WorkspaceIssue: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let message: String
    public let recovery: String?
    public let settingsURL: URL?

    public init(message: String, recovery: String? = nil, settingsURL: URL? = nil) {
        self.message = message; self.recovery = recovery; self.settingsURL = settingsURL
    }

    init(_ error: Error) {
        self.init(message: error.localizedDescription, recovery: (error as? LocalizedError)?.recoverySuggestion)
    }

    init(_ issue: RecorderIssue) {
        self.init(message: issue.message, recovery: issue.recovery, settingsURL: issue.settingsURL)
    }
}

/// What the status row under the tabs reports for the selected meeting.
public enum MeetingProcessingStatus: Equatable, Sendable {
    case noRecordings
    case recording, paused
    /// A recording has saved audio but no queued job (queueing failed earlier).
    case notProcessed(recordingID: UUID)
    case queued
    case processing(JobStage)
    case waitingForModels(jobID: UUID, roles: [ModelRole])
    case interrupted(jobID: UUID)
    case failed(jobID: UUID, message: String)
    case ready

    public var message: String {
        switch self {
        case .noRecordings: "No recordings yet"
        case .recording: "Recording"
        case .paused: "Recording paused"
        case .notProcessed: "Saved audio has not been transcribed"
        case .queued: "Waiting to transcribe"
        case .processing(let stage): Self.title(stage)
        case .waitingForModels(_, let roles):
            roles.isEmpty ? "The required models are installed. Retry to transcribe this recording."
                : "Transcription needs models: " + Self.titles(roles)
        case .interrupted: "Transcription was interrupted"
        case .failed(_, let message): "Transcription failed: \(message)"
        case .ready: "Transcript ready"
        }
    }

    public var retryJobID: UUID? {
        switch self {
        case .waitingForModels(let id, _), .interrupted(let id), .failed(let id, _): id
        default: nil
        }
    }

    static func title(_ stage: JobStage) -> String {
        switch stage {
        case .decoding: "Reading audio…"
        case .transcribing: "Transcribing…"
        case .aligning: "Aligning words…"
        case .diarizing: "Identifying speakers…"
        case .correcting: "Correcting spelling…"
        case .validating, .publishing: "Saving transcript…"
        default: "Processing…"
        }
    }

    static func titles(_ roles: [ModelRole]) -> String {
        roles.map(Self.title).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
    }

    /// The installation name shown in Settings, so a missing-model message
    /// names exactly the row that offers its download.
    public static func title(_ role: ModelRole) -> String {
        ModelSettingsPresentation.describe([role]).title
    }

    /// Latest final-transcription job per recording; the most urgent wins.
    static func derive(recordings: [Recording], jobs: [ProcessingJob], missing: [UUID: [ModelRole]] = [:]) -> Self {
        if recordings.isEmpty { return .noRecordings }
        if recordings.contains(where: { $0.state == .recording || $0.state == .preparing }) { return .recording }
        if recordings.contains(where: { $0.state == .paused }) { return .paused }
        var states: [Self] = []
        for recording in recordings {
            guard let job = jobs.last(where: { $0.snapshot.kind == .finalTranscription && $0.snapshot.recordingID == recording.id }) else {
                if !recording.chunks.isEmpty { states.append(.notProcessed(recordingID: recording.id)) }
                continue
            }
            switch job.stage {
            case .completed: states.append(.ready)
            case .queued: states.append(.queued)
            case .waitingForModels:
                let roles = missing[job.id] ?? job.snapshot.models.map(\.role)
                states.append(.waitingForModels(jobID: job.id, roles: roles))
            case .interrupted: states.append(.interrupted(jobID: job.id))
            case .failed: states.append(.failed(jobID: job.id, message: job.lastError ?? "Unknown error"))
            case .cancelled: states.append(.notProcessed(recordingID: recording.id))
            default: states.append(.processing(job.stage))
            }
        }
        return states.min { $0.urgency < $1.urgency } ?? .ready
    }

    private var urgency: Int {
        switch self {
        case .failed: 0
        case .waitingForModels: 1
        case .interrupted: 2
        case .notProcessed: 3
        case .processing: 4
        case .queued: 5
        case .recording, .paused: 6
        case .ready: 7
        case .noRecordings: 8
        }
    }
}

/// Record/Stop and Pause/Resume for one meeting, following the single active capture.
public struct RecordControls: Equatable, Sendable {
    public enum Primary: Sendable { case record, stop }
    public enum Secondary: Sendable { case pause, resume }
    public let primary: Primary
    public let primaryEnabled: Bool
    public let secondary: Secondary
    public let secondaryEnabled: Bool
    public let primaryHelp: String
    public let secondaryHelp: String
}

/// Main-window state: meeting list, selection, the single active recording and
/// background transcription. Storage, capture and inference stay in services.
@MainActor @Observable public final class WorkspacePresentation {
    public private(set) var meetings: [Meeting] = []
    public private(set) var hasMeetings = false
    public private(set) var isLoaded = false
    public var search = "" { didSet { if search != oldValue { Task { await reloadMeetings() } } } }
    public var selectedID: UUID? { didSet { if selectedID != oldValue { Task { await loadSelection() } } } }
    public private(set) var selected: Meeting?
    public private(set) var recordings: [Recording] = []
    public private(set) var jobs: [ProcessingJob] = []
    public private(set) var phase: MeetingRecorderPhase = .idle
    public private(set) var activeMeeting: Meeting?
    /// Input levels and elapsed time of the active recording, polled by the interface.
    public var levels: AudioLevelMeter { recorder.levels }
    /// A non-blocking hint while recording when system audio has stayed at exact zeros
    /// although the microphone heard speech; recording continues unchanged.
    public var systemAudioHint: String? {
        guard phase == .recording, levels.read().systemSilentWhileSpeaking else { return nil }
        return Self.systemAudioHintText
    }
    public static let systemAudioHintText = "System audio is silent while you speak. Check that TalkTrack is switched on under System Audio Recording Only in System Settings > Privacy & Security."
    public private(set) var isCommandRunning = false
    public private(set) var runningJobMeetingID: UUID?
    public var issue: WorkspaceIssue?
    /// Which of a waiting job's models are still not installed, by job. Until
    /// known, the status names all of the job's models.
    public private(set) var missingModels: [UUID: [ModelRole]] = [:]
    /// Answers which snapshots are not installed, without waiting for running
    /// inference. Unset, waiting jobs name all of their models.
    public var unavailableModels: (@Sendable ([ModelSnapshot]) async throws -> [ModelRole])?
    /// Runs before a recording takes the capture lease (dictation cancels itself).
    public var beforeCapture: (@Sendable () async -> Void)?
    /// Changes whenever the selected meeting's published transcript may have changed.
    public private(set) var transcriptGeneration = 0

    public let store: SessionStore
    private let recorder: MeetingRecorder
    private let runner: FinalJobRunner
    private let defaults: UserDefaults
    private var observers: [Task<Void, Never>] = []
    /// Set while quitting: record/pause/resume/stop commands are refused.
    public private(set) var isQuitting = false

    public init(store: SessionStore, recorder: MeetingRecorder, runner: FinalJobRunner, defaults: UserDefaults = .standard) {
        self.store = store; self.recorder = recorder; self.runner = runner; self.defaults = defaults
    }

    // MARK: Lifecycle

    /// Recovers recordings left by a crash, loads meetings and starts queued work.
    public func start() async {
        guard observers.isEmpty else { return }
        let recorder = recorder, runner = runner
        observers.append(Task { [weak self] in
            for await event in recorder.events { await self?.handle(event) }
        })
        observers.append(Task { [weak self] in
            for await event in runner.events { await self?.handle(event) }
        })
        do {
            for result in try await recorder.recoverAfterRelaunch() {
                if let issue = result.issue {
                    self.issue = WorkspaceIssue(message: "A recording could not be recovered: \(issue)",
                        recovery: "Its audio folder was kept. Free disk space or restore access, then relaunch TalkTrack.")
                }
            }
        } catch { issue = WorkspaceIssue(error) }
        await reloadMeetings()
        if selectedID == nil { selectedID = meetings.first?.id }
        isLoaded = true
        await runner.wake()
    }

    public func stopObserving() { observers.forEach { $0.cancel() }; observers = [] }

    // MARK: Meetings

    public func reloadMeetings() async {
        do {
            let query = search
            let values = try await store.meetings(search: query)
            guard query == search else { return }
            meetings = values
            hasMeetings = query.isEmpty ? !values.isEmpty : !(try await store.meetings().isEmpty)
            if let id = activeMeeting?.id { activeMeeting = try? await store.meeting(id) }
        } catch { issue = WorkspaceIssue(error) }
    }

    func loadSelection() async {
        guard let id = selectedID else { selected = nil; recordings = []; jobs = []; return }
        do {
            let meeting = try await store.meeting(id)
            let recordings = try await store.recordings(meetingID: id)
            let jobs = try await store.jobs(meetingID: id)
            guard selectedID == id else { return }
            selected = meeting; self.recordings = recordings; self.jobs = jobs
            await refreshMissingModels()
        } catch {
            guard selectedID == id else { return }
            selected = nil; recordings = []; jobs = []
            if case StoreError.missingMeeting = error { selectedID = nil } else { issue = WorkspaceIssue(error) }
        }
    }

    /// Re-checks waiting jobs of the selected meeting, e.g. after a download or removal.
    public func refreshMissingModels() async {
        guard let unavailableModels else { return }
        for job in jobs where job.stage == .waitingForModels {
            if let missing = try? await unavailableModels(job.snapshot.models) {
                missingModels[job.id] = FinalTranscriptionPipeline.blocking(missing, settings: job.snapshot.settings)
            }
        }
    }

    /// Validates, saves and selects a new meeting. Errors are for the sheet.
    @discardableResult
    public func createMeeting(title: String, description: String) async throws -> Meeting {
        let meeting = try await store.createMeeting(ProcessingPreferences.meetingDraft(title: title, description: description, in: defaults))
        search = ""
        await reloadMeetings()
        selectedID = meeting.id
        await loadSelection()
        return meeting
    }

    public func renameMeeting(_ id: UUID, title: String, description: String) async throws {
        try await store.renameMeeting(id, title: title, description: description)
        await reloadMeetings()
        if selectedID == id { await loadSelection() }
    }

    /// The meeting being recorded cannot be deleted; Stop first.
    public func canDelete(_ id: UUID) -> Bool { activeMeeting?.id != id && !(phase != .idle && activeMeeting == nil) }

    /// Cancels its processing, then removes the meeting with all of its audio.
    public func deleteMeeting(_ id: UUID) async {
        guard canDelete(id) else {
            issue = WorkspaceIssue(message: "This meeting is recording.", recovery: "Stop the recording before deleting the meeting.")
            return
        }
        await runner.cancel(meetingID: id)
        do {
            try await store.deleteMeeting(id)
        } catch { issue = WorkspaceIssue(error) }
        let index = meetings.firstIndex { $0.id == id }
        await reloadMeetings()
        if selectedID == id {
            selectedID = meetings.isEmpty ? nil : meetings[min(index ?? 0, meetings.count - 1)].id
        }
    }

    // MARK: Recording

    public func controls(for meetingID: UUID) -> RecordControls {
        let busy = isCommandRunning || phase == .starting || phase == .stopping
        if let active = activeMeeting, active.id != meetingID {
            let help = "Stop the recording in “\(active.title)” first"
            return RecordControls(primary: .record, primaryEnabled: false, secondary: .pause, secondaryEnabled: false,
                                  primaryHelp: help, secondaryHelp: "Pause is available while this meeting records")
        }
        switch phase {
        case .idle:
            return RecordControls(primary: .record, primaryEnabled: !busy, secondary: .pause, secondaryEnabled: false,
                                  primaryHelp: "Record a new recording in this meeting",
                                  secondaryHelp: "Pause is available while this meeting records")
        case .starting:
            return RecordControls(primary: .stop, primaryEnabled: false, secondary: .pause, secondaryEnabled: false,
                                  primaryHelp: "Starting recording…", secondaryHelp: "Starting recording…")
        case .recording:
            return RecordControls(primary: .stop, primaryEnabled: !busy, secondary: .pause, secondaryEnabled: !busy,
                                  primaryHelp: "Stop and save this recording", secondaryHelp: "Pause recording")
        case .paused:
            return RecordControls(primary: .stop, primaryEnabled: !busy, secondary: .resume, secondaryEnabled: !busy,
                                  primaryHelp: "Stop and save this recording", secondaryHelp: "Resume recording")
        case .stopping:
            return RecordControls(primary: .stop, primaryEnabled: false, secondary: .pause, secondaryEnabled: false,
                                  primaryHelp: "Saving recording…", secondaryHelp: "Saving recording…")
        }
    }

    /// Status of the selected meeting, from its loaded recordings and jobs.
    public var selectedStatus: MeetingProcessingStatus? {
        guard let meetingID = selected?.id else { return nil }
        if activeMeeting?.id == meetingID {
            if phase == .paused { return .paused }
            if phase != .idle { return .recording }
        }
        let status = MeetingProcessingStatus.derive(recordings: recordings, jobs: jobs, missing: missingModels)
        if case .queued = status, runningJobMeetingID == meetingID { return .processing(.transcribing) }
        return status
    }

    public func record() async {
        guard let id = selectedID else { return }
        await command {
            await self.beforeCapture?()
            await self.runner.setCaptureActive(true)
            do { try await self.recorder.start(meetingID: id) }
            catch { await self.runner.setCaptureActive(false); throw error }
        }
    }

    public func pause() async { await command { try await self.recorder.pause() } }
    public func resume() async { await command { try await self.recorder.resume() } }

    /// Saves the recording; the `.stopped` event reports the queued job.
    public func stop() async { await command { _ = try await self.recorder.stop() } }

    /// Selects the meeting being recorded, clearing a search that hides it.
    public func showActiveMeeting() {
        guard let id = activeMeeting?.id else { return }
        if !meetings.contains(where: { $0.id == id }) { search = "" }
        selectedID = id
    }

    public func retry(jobID: UUID) async {
        do { try await runner.retry(jobID: jobID) } catch { issue = WorkspaceIssue(error) }
        await loadSelection()
    }

    /// Queues processing for saved audio whose job could not be queued at Stop.
    public func process(recordingID: UUID, policy: FinalJobPolicy) async {
        guard let meeting = selected else { return }
        do { try await enqueue(meeting, recordingIDs: [recordingID], policy: policy) } catch { issue = WorkspaceIssue(error) }
        await loadSelection()
    }

    /// Whether the selected meeting's saved audio can be transcribed again:
    /// it is not recording and none of its jobs is still waiting or running.
    public var canReprocess: Bool {
        guard let id = selected?.id, activeMeeting?.id != id, runningJobMeetingID != id else { return false }
        // A job that is not running but still waits to run would be duplicated.
        return !reprocessable.isEmpty && !jobs.contains { [.queued, .waitingForModels].contains($0.stage) }
    }

    private var reprocessable: [UUID] {
        recordings.filter { [.complete, .interrupted].contains($0.state) && $0.activeDuration > .zero }.map(\.id)
    }

    /// Transcribes every saved recording of the selected meeting again with the
    /// current models and settings (for example after a speaker-separation fix).
    /// The current transcript stays visible until the new one is published;
    /// confirmed speaker names carry over where the voices match.
    public func reprocess(policy: FinalJobPolicy) async {
        guard let meeting = selected, canReprocess else { return }
        do { try await enqueue(meeting, recordingIDs: reprocessable, policy: policy) } catch { issue = WorkspaceIssue(error) }
        await loadSelection()
    }

    private func enqueue(_ meeting: Meeting, recordingIDs: [UUID], policy: FinalJobPolicy) async throws {
        let models = try policy.models()
        let settings = policy.settings(meeting)
        let missing = FinalTranscriptionPipeline.blocking(try await policy.missing(models), settings: settings)
        for recordingID in recordingIDs {
            let job = try await store.enqueue(kind: .finalTranscription, meetingID: meeting.id, recordingID: recordingID,
                                              settings: settings, models: models)
            if !missing.isEmpty {
                try await store.updateJob(job.id, stage: .waitingForModels,
                    error: "Missing: " + MeetingProcessingStatus.titles(missing))
            }
        }
        await runner.wake()
    }

    // MARK: Quit

    /// What `prepareToQuit` did, for the caller's log and tests.
    public struct QuitReport: Sendable {
        /// The recording that was stopped and saved, if one was active.
        public let saved: RecordingStopResult?
        /// The transcription that was running; it keeps its completed stages.
        public let cancelledJobID: UUID?
        /// True when that job stopped in time and was queued again, so it
        /// resumes at the next launch. Otherwise relaunch marks it interrupted.
        public let requeued: Bool
    }

    /// Readies the library for the process to exit without losing recoverable
    /// work: no new transcription starts; the running one is cancelled (its
    /// completed stages are checkpoints) and queued again; an active or starting
    /// recording is stopped and saved, which also queues its transcription for
    /// the next launch; pending notes are written. Returns only when capture has
    /// stopped. A failed note write keeps the text in recovery storage.
    @discardableResult
    public func prepareToQuit(notes: NotesAutosave?, processingTimeout: Duration = .seconds(10)) async -> QuitReport {
        isQuitting = true
        let cancelled = await runner.shutDown()
        // Waits for a start in progress; throws harmlessly when nothing records.
        let saved = try? await recorder.stop()
        let deadline = ContinuousClock.now + processingTimeout
        while await runner.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        var requeued = false
        if let cancelled, await !runner.isRunning, let stage = try? await store.job(cancelled).stage {
            if stage == .interrupted { requeued = (try? await store.retryJob(cancelled)) != nil }
            else { requeued = stage == .queued }
        }
        try? await notes?.flushForQuit()
        return QuitReport(saved: saved, cancelledJobID: cancelled, requeued: requeued)
    }

    private func command(_ body: @escaping @MainActor () async throws -> Void) async {
        guard !isCommandRunning, !isQuitting else { return }
        isCommandRunning = true
        defer { isCommandRunning = false }
        do { try await body() } catch { issue = WorkspaceIssue(error) }
        await reloadMeetings()
        await loadSelection()
    }

    // MARK: Events

    private func handle(_ event: MeetingRecorderEvent) async {
        switch event {
        case let .phase(next, meetingID, _):
            phase = next
            await runner.setCaptureActive(next != .idle)
            if let meetingID, next != .idle {
                if activeMeeting?.id != meetingID { activeMeeting = try? await store.meeting(meetingID) }
            } else if next == .idle {
                activeMeeting = nil
            }
            if next == .recording || next == .idle { await reloadMeetings(); await loadSelection() }
        case let .interrupted(_, _, issue):
            self.issue = WorkspaceIssue(issue)
        case let .stopped(result):
            if let issue = result.issue { self.issue = WorkspaceIssue(issue) }
            else if let jobIssue = result.jobIssue {
                self.issue = WorkspaceIssue(message: "The recording was saved, but transcription could not be queued: \(jobIssue)",
                                            recovery: "Use Transcribe in the meeting's status row to try again.")
            }
            await runner.wake()
            await reloadMeetings()
            if selectedID == result.recording.meetingID { await loadSelection() }
        }
    }

    private func handle(_ event: FinalJobRunnerEvent) async {
        switch event {
        case let .started(_, meetingID):
            runningJobMeetingID = meetingID
            if selectedID == meetingID { await loadSelection() }
        case let .finished(_, meetingID, error):
            runningJobMeetingID = nil
            if selectedID == meetingID {
                await loadSelection()
                if error == nil { transcriptGeneration += 1 }
            }
        }
    }
}
