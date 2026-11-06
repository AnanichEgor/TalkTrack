import Foundation
import Observation
import TalkTrackAudio
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
    /// Stop was pressed and the recording is being finalized.
    case saving
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
        case .saving: "Saving…"
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

    public var isQueuedOrProcessing: Bool {
        switch self {
        case .queued, .processing: true
        default: false
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
            case .cancelled:
                // Cancel keeps an earlier final transcript, which is still current.
                let transcribed = jobs.contains { $0.snapshot.kind == .finalTranscription
                    && $0.snapshot.recordingID == recording.id && $0.stage == .completed }
                states.append(transcribed ? .ready : .notProcessed(recordingID: recording.id))
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
        case .recording, .paused, .saving: 6
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
    /// Every meeting, newest first, whatever the search (move destinations).
    public private(set) var allMeetings: [Meeting] = []
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
    /// The recording being captured (recording or paused); nil when idle.
    public private(set) var activeRecordingID: UUID?
    /// The recording whose headset notification the user closed.
    public private(set) var headsetHintDismissedRecordingID: UUID?
    /// A non-blocking notification while the microphone hears the loudspeakers
    /// (detect-loudspeaker-echo D6). Hidden while paused, after Stop, once closed
    /// for this recording, and while the system-audio warning is shown.
    public var headsetHint: String? {
        guard phase == .recording, let id = activeRecordingID, headsetHintDismissedRecordingID != id,
              systemAudioHint == nil, levels.read().playbackEcho == .loudspeaker else { return nil }
        return Self.headsetHintText
    }
    public static let headsetHintText = "Speakers detected. Use a headset for better transcription."
    /// Closes the headset notification for the rest of the current recording.
    public func dismissHeadsetHint() { headsetHintDismissedRecordingID = activeRecordingID }
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
    /// The runtime's live models and capture lease; nil leaves live text unavailable.
    public var liveHost: LiveCaptureHost?
    /// How often the draft of the recording is saved while it records.
    public var draftSaveInterval: Duration = .seconds(10)
    /// The draft of the recording in progress (`live-draft-naming`), with the
    /// meeting and recording it belongs to; nil when nothing records.
    public private(set) var liveDraft: LiveTranscriptPresentation?
    public private(set) var liveMeetingID: UUID?
    public private(set) var liveRecordingID: UUID?
    /// The meeting whose final transcription waits for the recording to stop.
    public private(set) var pausedJobMeetingID: UUID?
    public static let waitsForRecordingMessage = "Waits for the recording to stop"
    private var bridge: LiveCaptureBridge?
    private var liveObserver: Task<Void, Never>?
    private var liveEnding: Task<Void, Never>?
    /// The recording whose live text is being ended, so it ends once.
    private var liveEndingRecordingID: UUID?
    /// Stops playback of a meeting before one of its recordings is deleted.
    public var stopPlayback: ((UUID) -> Void)?
    /// Changes when a recording is deleted, so summary and translation views reload.
    public private(set) var recordingDeletions = 0
    /// Changes whenever the selected meeting's published transcript may have changed.
    public private(set) var transcriptGeneration = 0
    /// Meetings whose final transcription runs or waits, for the sidebar and status.
    public private(set) var queueStates: [UUID: FinalQueueState] = [:]
    /// Progress and remaining time of the running final transcription, by meeting.
    public private(set) var progressDisplays: [UUID: FinalProgressDisplay] = [:]
    private var finalQueue: [ProcessingJob] = []
    /// The job the runner started last, which may not have left `queued` in storage yet.
    private var runningJobID: UUID?
    private var running: RunningFinalJob?
    /// Track audio of a meeting's jobs finished earlier in the same run of work, so
    /// its progress bar does not restart at each recording.
    private var finishedAudio: [UUID: Double] = [:]
    public static let finalTranscriptionRateKey = "finalTranscriptionRate"

    private struct RunningFinalJob {
        let jobID: UUID
        let meetingID: UUID
        /// Set by the first report: what came before (loading models, the first
        /// window) is not representative of the rest.
        var started: ContinuousClock.Instant?
        var baseline: Double = 0
        /// Weighted audio seconds of the meeting's recordings, by recording.
        let audio: [UUID: Double]
        var progress: FinalJobProgress
        var elapsed: Double = 0
        var shownMinutes: Int?
    }

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
        await refreshQueue()
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
            allMeetings = query.isEmpty ? values : try await store.meetings()
            hasMeetings = !allMeetings.isEmpty
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
        await refreshQueue()
        let index = meetings.firstIndex { $0.id == id }
        await reloadMeetings()
        if selectedID == id {
            selectedID = meetings.isEmpty ? nil : meetings[min(index ?? 0, meetings.count - 1)].id
        }
    }

    // MARK: Deleting a recording

    /// Why a recording of the selected meeting cannot be deleted now, or nil.
    public func deleteRefusal(recordingID: UUID) -> String? {
        if isQuitting { return "TalkTrack is quitting." }
        guard let recording = recordings.first(where: { $0.id == recordingID }) else { return "This recording is unavailable." }
        if [.preparing, .recording, .paused, .stopping].contains(recording.state) {
            return "Stop recording before deleting this recording."
        }
        return nil
    }

    /// Stops playback and the recording's work (and a translation covering it),
    /// then permanently deletes it from the selected meeting.
    public func deleteRecording(_ recordingID: UUID) async {
        guard let meetingID = selected?.id else { return }
        if let refusal = deleteRefusal(recordingID: recordingID) {
            issue = WorkspaceIssue(message: "This recording cannot be deleted now.", recovery: refusal)
            return
        }
        stopPlayback?(meetingID)
        let active: (ProcessingJob) -> Bool = { ![.completed, .failed, .interrupted, .cancelled].contains($0.stage) }
        for job in (try? await store.jobs(meetingID: meetingID)) ?? []
            where active(job) && (job.snapshot.recordingID == recordingID || job.snapshot.kind == .translation) {
            try? await runner.cancel(jobID: job.id)
        }
        do { try await store.deleteRecording(meetingID: meetingID, recordingID: recordingID) }
        catch { issue = WorkspaceIssue(error) }
        recordingDeletions += 1
        transcriptGeneration += 1
        await refreshQueue()
        await reloadMeetings()
        await loadSelection()
    }

    // MARK: Moving a recording

    /// Why a recording of the selected meeting cannot be moved now, or nil.
    public func moveRefusal(recordingID: UUID) -> String? {
        if isQuitting { return "TalkTrack is quitting." }
        guard let recording = recordings.first(where: { $0.id == recordingID }) else { return "This recording is unavailable." }
        if [.preparing, .recording, .paused, .stopping].contains(recording.state) {
            return "Stop recording before moving this recording."
        }
        return nil
    }

    /// Why `recordingID` cannot be split at `time` (its active time), or nil.
    public func splitRefusal(recordingID: UUID, at time: MediaTime) -> String? {
        if let refusal = moveRefusal(recordingID: recordingID) {
            return refusal.replacingOccurrences(of: "moving", with: "splitting")
        }
        guard let recording = recordings.first(where: { $0.id == recordingID }) else { return "This recording is unavailable." }
        guard time.microseconds >= RecordingCut.minimumPart,
              recording.activeDuration.microseconds - time.microseconds >= RecordingCut.minimumPart else {
            return "Each part must be at least one second long."
        }
        return nil
    }

    /// Splits a recording of the selected meeting at `time` into two
    /// recordings (split-recording D6). Playback stops, the recording's
    /// unfinished work and the meeting translation are cancelled first, and
    /// parts without a current final transcript are queued for transcription.
    public func splitRecording(_ recordingID: UUID, at time: MediaTime, policy: FinalJobPolicy?) async {
        guard let meeting = selected else { return }
        if let refusal = splitRefusal(recordingID: recordingID, at: time) {
            issue = WorkspaceIssue(message: "This recording cannot be split here.", recovery: refusal)
            return
        }
        stopPlayback?(meeting.id)
        let active: (ProcessingJob) -> Bool = { ![.completed, .failed, .interrupted, .cancelled].contains($0.stage) }
        for job in (try? await store.jobs(meetingID: meeting.id)) ?? []
            where active(job) && (job.snapshot.recordingID == recordingID || job.snapshot.kind == .translation) {
            try? await runner.cancel(jobID: job.id)
        }
        do {
            let result = try await store.splitRecording(recordingID, meetingID: meeting.id, at: time)
            if result.needsTranscription, let policy, let current = try? await store.meeting(meeting.id) {
                do { try await enqueue(current, recordingIDs: [result.first.id, result.second.id], policy: policy) }
                catch { issue = WorkspaceIssue(message: "The recording was split but could not be queued for transcription.",
                                               recovery: error.localizedDescription) }
            }
        } catch {
            issue = WorkspaceIssue(error)
            return
        }
        recordingDeletions += 1
        transcriptGeneration += 1
        await refreshQueue()
        await reloadMeetings()
        await loadSelection()
    }

    /// Meetings a recording of the selected meeting can move to, newest first.
    public var moveDestinations: [Meeting] {
        allMeetings.filter { $0.id != selected?.id }
    }

    /// Moves a recording of the selected meeting, as it is, to `destinationID`
    /// and selects that meeting. Playback of both meetings and the recording's
    /// work (and the source translation) stop first; a recording without a final
    /// transcript is queued for transcription in the destination.
    public func moveRecording(_ recordingID: UUID, to destinationID: UUID, policy: FinalJobPolicy?) async {
        guard let sourceID = selected?.id else { return }
        if let refusal = moveRefusal(recordingID: recordingID) {
            issue = WorkspaceIssue(message: "This recording cannot be moved now.", recovery: refusal)
            return
        }
        stopPlayback?(sourceID); stopPlayback?(destinationID)
        let active: (ProcessingJob) -> Bool = { ![.completed, .failed, .interrupted, .cancelled].contains($0.stage) }
        for job in (try? await store.jobs(meetingID: sourceID)) ?? []
            where active(job) && (job.snapshot.recordingID == recordingID || job.snapshot.kind == .translation) {
            try? await runner.cancel(jobID: job.id)
        }
        do {
            let result = try await store.moveRecording(recordingID, from: sourceID, to: destinationID)
            if result.needsTranscription, let policy, let destination = try? await store.meeting(destinationID) {
                do { try await enqueue(destination, recordingIDs: [recordingID], policy: policy) }
                catch { issue = WorkspaceIssue(message: "The recording was moved but could not be queued for transcription.",
                                               recovery: error.localizedDescription) }
            }
        } catch {
            issue = WorkspaceIssue(error)
            return
        }
        recordingDeletions += 1
        transcriptGeneration += 1
        search = ""
        await refreshQueue()
        await reloadMeetings()
        selectedID = destinationID
        await loadSelection()
    }

    /// Creates a meeting from the New Meeting fields and moves the recording
    /// into it. Field errors are for the sheet; when the move itself fails the
    /// new, empty meeting is removed again.
    public func moveRecordingToNewMeeting(_ recordingID: UUID, title: String, description: String,
                                          policy: FinalJobPolicy?) async throws {
        guard let sourceID = selected?.id else { return }
        if let refusal = moveRefusal(recordingID: recordingID) {
            throw ServiceError(message: "This recording cannot be moved now.", recovery: refusal)
        }
        let meeting = try await store.createMeeting(ProcessingPreferences.meetingDraft(title: title, description: description, in: defaults))
        await moveRecording(recordingID, to: meeting.id, policy: policy)
        if (try? await store.recordingMeetingID(recordingID)) != meeting.id {
            try? await store.deleteMeeting(meeting.id)
            await reloadMeetings()
            selectedID = sourceID
            await loadSelection()
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

    /// How the active recording is shown in the sidebar, banner and menu bar:
    /// `.recording`, `.paused` or `.saving`; nil when nothing records.
    public var activeCaptureStatus: MeetingProcessingStatus? {
        guard activeMeeting != nil else { return nil }
        switch phase {
        case .idle: return nil
        case .paused: return .paused
        case .stopping: return .saving
        case .starting, .recording: return .recording
        }
    }

    /// Status of the selected meeting, from its loaded recordings and jobs.
    public var selectedStatus: MeetingProcessingStatus? {
        guard let meetingID = selected?.id else { return nil }
        if activeMeeting?.id == meetingID, let capture = activeCaptureStatus { return capture }
        let status = MeetingProcessingStatus.derive(recordings: recordings, jobs: jobs, missing: missingModels)
        if case .queued = status, runningJobMeetingID == meetingID { return .processing(.transcribing) }
        return status
    }

    /// `In queue: 2nd, after “Daily 5”` while the selected meeting waits behind another.
    public var selectedQueueMessage: String? {
        guard case .queued? = selectedStatus, let id = selected?.id else { return nil }
        if pausedJobMeetingID == id, phase != .idle { return Self.waitsForRecordingMessage }
        guard case .queued? = queueStates[id] else { return nil }
        return queueStates[id]?.message
    }

    /// Progress of the selected meeting's running final transcription.
    public var selectedProgress: FinalProgressDisplay? {
        guard let id = selected?.id, case .processing? = selectedStatus else { return nil }
        return progressDisplays[id]
    }

    /// Whether the selected meeting has final transcription to cancel.
    public var canCancelProcessing: Bool {
        guard let id = selected?.id else { return false }
        return queueStates[id] != nil
    }

    /// Stops the selected meeting's queued and running final transcriptions. The
    /// audio and any published transcript stay; a transcribed recording is ready again.
    public func cancelProcessing() async {
        guard let id = selected?.id else { return }
        do {
            for jobID in try await store.cancelFinalTranscription(meetingID: id) {
                try? await runner.cancel(jobID: jobID)
            }
        } catch { issue = WorkspaceIssue(error) }
        await refreshQueue()
        await loadSelection()
    }

    /// Reloads the order of all meetings' final transcriptions.
    func refreshQueue() async {
        guard let queue = try? await store.finalQueue() else { return }
        finalQueue = queue
        // A search may hide meetings from the list; their titles are read directly.
        var titles = Dictionary(meetings.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        for meetingID in Set(queue.map(\.snapshot.source.meetingID)) where titles[meetingID] == nil {
            titles[meetingID] = try? await store.meeting(meetingID).title
        }
        queueStates = FinalQueueState.states(queue: queue, titles: titles, runningJobID: runningJobID)
        finishedAudio = finishedAudio.filter { queueStates[$0.key] != nil }
        if let running, queueStates[running.meetingID] == nil { self.running = nil }
        progressDisplays = progressDisplays.filter { queueStates[$0.key] == .running }
    }

    private var storedRate: Double {
        let value = defaults.double(forKey: Self.finalTranscriptionRateKey)
        return value > 0 ? value : FinalTranscriptionEstimate.defaultRate
    }

    private func startProgress(jobID: UUID, meetingID: UUID) async {
        guard let job = finalQueue.first(where: { $0.id == jobID }), let recordingID = job.snapshot.recordingID,
              let recordings = try? await store.recordings(meetingID: meetingID) else { return }
        let audio = Dictionary(recordings.map { ($0.id, FinalJobProgress.audio($0.activeDuration)) },
                               uniquingKeysWith: { a, _ in a })
        running = RunningFinalJob(jobID: jobID, meetingID: meetingID, audio: audio,
            progress: FinalJobProgress(jobID: jobID, processed: 0, total: audio[recordingID] ?? 0))
        updateDisplay()
    }

    private func updateProgress(_ progress: FinalJobProgress) {
        guard var current = running, current.jobID == progress.jobID else { return }
        guard let started = current.started else {
            current.started = .now; current.baseline = progress.processed; current.progress = progress
            running = current; updateDisplay(); return
        }
        let elapsed = ContinuousClock.now - started
        current.elapsed = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        current.progress = progress
        running = current
        updateDisplay()
    }

    private func updateDisplay() {
        guard var current = running else { return }
        let queued = finalQueue.filter { $0.snapshot.source.meetingID == current.meetingID && $0.stage == .queued && $0.id != current.jobID }
            .map { $0.snapshot.recordingID.flatMap { current.audio[$0] } ?? 0 }
        let seconds = FinalTranscriptionEstimate.remaining(progress: current.progress, elapsed: current.elapsed,
                                                           stored: storedRate, baseline: current.baseline, queuedAudio: queued)
        let minutes = FinalTranscriptionEstimate.minutes(seconds, shown: current.shownMinutes)
        current.shownMinutes = minutes
        running = current
        let done = finishedAudio[current.meetingID] ?? 0
        let total = done + current.progress.total + queued.reduce(0, +)
        progressDisplays[current.meetingID] = FinalProgressDisplay(
            fraction: total > 0 ? (done + current.progress.processed) / total : 0,
            remaining: FinalTranscriptionEstimate.label(minutes: minutes))
    }

    /// A completed job teaches the stored rate the first estimate of the next one uses.
    private func finishProgress(jobID: UUID, succeeded: Bool) {
        guard let current = running, current.jobID == jobID else { return }
        running = nil
        progressDisplays[current.meetingID] = nil
        finishedAudio[current.meetingID, default: 0] += current.progress.total
        let measured = current.progress.processed - max(current.progress.resumed, current.baseline)
        if succeeded, measured >= FinalTranscriptionEstimate.minimumMeasured {
            defaults.set(FinalTranscriptionEstimate.updated(stored: storedRate, measured: current.elapsed / measured),
                         forKey: Self.finalTranscriptionRateKey)
        }
    }

    public func record() async {
        guard let id = selectedID else { return }
        await command {
            await self.liveEnding?.value
            await self.beforeCapture?()
            // A running final transcription stops at a checkpoint and waits for Stop.
            await self.runner.setCaptureActive(true)
            let language = (try? await self.store.meeting(id))?.language
            let options = ProcessingPreferences.liveOptions(meetingLanguage: language, in: self.defaults)
            let store = self.store
            let bridge = LiveCaptureBridge(host: self.liveHost, options: options, saveInterval: self.draftSaveInterval,
                                           save: { draft in try? await store.saveLiveDraft(draft) })
            await bridge.begin()
            let recordingID = UUID()
            await self.attachLive(bridge, meetingID: id, recordingID: recordingID)
            do { try await self.recorder.start(meetingID: id, recordingID: recordingID, live: bridge.mailbox) }
            catch {
                await self.endLive(bridge, interrupted: true)
                await self.runner.setCaptureActive(false)
                throw error
            }
            // The new recording's separator is where its draft rows appear.
            self.transcriptGeneration += 1
        }
    }

    public func pause() async {
        await command {
            try await self.recorder.pause()
            await self.bridge?.pause()
        }
    }

    public func resume() async {
        await command {
            await self.bridge?.resume()
            try await self.recorder.resume()
        }
    }

    private func attachLive(_ bridge: LiveCaptureBridge, meetingID: UUID, recordingID: UUID) async {
        self.bridge = bridge
        liveMeetingID = meetingID; liveRecordingID = recordingID
        let presentation = LiveTranscriptPresentation()
        liveDraft = presentation
        if let session = await bridge.attach(meetingID: meetingID, recordingID: recordingID) {
            liveObserver = Task { await presentation.observe(session) }
        }
    }

    /// Drains the draft's tail (or drops in-flight work after an interruption),
    /// saves it and releases the capture lease; then the saved draft is shown.
    private func endLive(_ bridge: LiveCaptureBridge, interrupted: Bool) async {
        if interrupted { await bridge.cancel() } else { await bridge.finish() }
        guard self.bridge === bridge else { return }
        await liveObserver?.value
        liveObserver = nil
        self.bridge = nil
        liveDraft = nil; liveMeetingID = nil; liveRecordingID = nil
        transcriptGeneration += 1
    }

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
        await refreshQueue()
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
        await refreshQueue()
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
        /// Stop did not finish within the quit deadline; the next launch recovers
        /// the recording's committed audio as interrupted.
        public let stopTimedOut: Bool
    }

    /// Readies the library for the process to exit without losing recoverable
    /// work: no new transcription starts; the running one is cancelled (its
    /// completed stages are checkpoints) and queued again; an active or starting
    /// recording is stopped and saved, which also queues its transcription for
    /// the next launch; pending notes are written. Returns when capture has
    /// stopped or after `stopTimeout` (design D5), so Quit never hangs; relaunch
    /// recovery then adopts the committed audio. A failed note write keeps the text
    /// in recovery storage.
    @discardableResult
    public func prepareToQuit(notes: NotesAutosave?, processingTimeout: Duration = .seconds(10),
                              stopTimeout: Duration = .seconds(20)) async -> QuitReport {
        isQuitting = true
        let cancelled = await runner.shutDown()
        // Waits for a start in progress; throws harmlessly when nothing records.
        let started = ContinuousClock.now, recorder = recorder
        let outcome = await Self.within(stopTimeout) { try? await recorder.stop() }
        let saved = outcome ?? nil
        let outcomeName = outcome == nil ? "stopTimedOut" : (saved == nil ? "none" : "saved")
        // The draft keeps the rows published so far; in-flight live text is dropped.
        if let bridge { _ = await Self.within(.seconds(5)) { await bridge.cancel() } }
        CaptureLog.recorder.log("quit.stop end ms=\(CaptureLog.milliseconds(since: started), privacy: .public) outcome=\(outcomeName, privacy: .public)")
        let deadline = ContinuousClock.now + processingTimeout
        while await runner.isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        var requeued = false
        if let cancelled, await !runner.isRunning, let stage = try? await store.job(cancelled).stage {
            if stage == .interrupted { requeued = (try? await store.retryJob(cancelled)) != nil }
            else { requeued = stage == .queued }
        }
        try? await notes?.flushForQuit()
        return QuitReport(saved: saved, cancelledJobID: cancelled, requeued: requeued, stopTimedOut: outcome == nil)
    }

    /// The operation's result, or nil when `timeout` passed first; the operation keeps running.
    nonisolated static func within<T: Sendable>(_ timeout: Duration,
                                                _ operation: @escaping @Sendable () async -> T) async -> T? {
        let results = AsyncStream<T?> { continuation in
            Task { continuation.yield(await operation()); continuation.finish() }
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                continuation.yield(nil); continuation.finish()
            }
            continuation.onTermination = { _ in timer.cancel() }
        }
        for await result in results { return result }
        return nil
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
        case let .phase(next, meetingID, recordingID):
            phase = next
            if next == .idle { activeRecordingID = nil } else if let recordingID { activeRecordingID = recordingID }
            await runner.setCaptureActive(next != .idle)
            if let meetingID, next != .idle {
                if activeMeeting?.id != meetingID { activeMeeting = try? await store.meeting(meetingID) }
            } else if next == .idle {
                activeMeeting = nil
            }
            if next == .recording || next == .idle { await reloadMeetings(); await loadSelection() }
        case let .interrupted(_, _, issue):
            self.issue = WorkspaceIssue(issue)
        case let .captureEnded(_, recordingID, interrupted):
            endLiveIfCapturing(recordingID, interrupted: interrupted)
        case let .stopped(result):
            // Normally ended at `.captureEnded` already.
            endLiveIfCapturing(result.recording.id, interrupted: result.recording.state == .interrupted)
            if let issue = result.issue { self.issue = WorkspaceIssue(issue) }
            else if let jobIssue = result.jobIssue {
                self.issue = WorkspaceIssue(message: "The recording was saved, but transcription could not be queued: \(jobIssue)",
                                            recovery: "Use Transcribe in the meeting's status row to try again.")
            }
            await runner.wake()
            await reloadMeetings()
            await refreshQueue()
            if selectedID == result.recording.meetingID { await loadSelection() }
        }
    }

    /// Not awaited: the recorder's Stop waits for the capture lease that ending
    /// live text releases (it queues the final job after checking models in the
    /// inference lane), and draining live text must not hold up queued work.
    private func endLiveIfCapturing(_ recordingID: UUID, interrupted: Bool) {
        guard let bridge, liveRecordingID == recordingID, liveEndingRecordingID != recordingID else { return }
        liveEndingRecordingID = recordingID
        liveEnding = Task { await self.endLive(bridge, interrupted: interrupted) }
    }

    private func handle(_ event: FinalJobRunnerEvent) async {
        switch event {
        case let .started(jobID, meetingID):
            pausedJobMeetingID = nil
            runningJobMeetingID = meetingID
            runningJobID = jobID
            await refreshQueue()
            await startProgress(jobID: jobID, meetingID: meetingID)
            if selectedID == meetingID { await loadSelection() }
        case let .progress(progress):
            updateProgress(progress)
        case let .paused(_, meetingID):
            // Queued again with its checkpoint; progress resumes after Stop.
            runningJobMeetingID = nil
            runningJobID = nil
            running = nil
            progressDisplays[meetingID] = nil
            pausedJobMeetingID = meetingID
            await refreshQueue()
            if selectedID == meetingID { await loadSelection() }
        case let .finished(jobID, meetingID, error):
            runningJobMeetingID = nil
            runningJobID = nil
            finishProgress(jobID: jobID, succeeded: error == nil)
            await refreshQueue()
            if selectedID == meetingID {
                await loadSelection()
                if error == nil { transcriptGeneration += 1 }
            }
        }
    }
}
