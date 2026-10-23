import AVFoundation
import Foundation
import Testing
import TalkTrackAudio
import TalkTrackDomain
@testable import TalkTrackServices

private func ticks(_ seconds: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: seconds) }

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private actor ScriptedCapture: MeetingCaptureControl {
    let callbacks: MeetingCaptureCallbacks
    init(_ callbacks: MeetingCaptureCallbacks) { self.callbacks = callbacks }
    func start(timeout: Duration) async throws {}
    func pause() async throws {}
    func stop() async {}
}

private let speechModels = FinalTranscriptionPipeline.requiredRoles.map {
    ModelSnapshot(role: $0, repository: "fixture/\($0.rawValue)", revision: String(repeating: "a", count: 40),
                  directory: try! RelativePath("fixture/\($0.rawValue)"), preprocessingVersion: "1")
}

/// Real store, recorder (scripted capture, real writer/AAC) and runner with a
/// scripted processor, so the presentation is exercised end to end.
@MainActor private final class WorkspaceFixture {
    let folder: TemporaryFolder
    let store: SessionStore
    let recorder: MeetingRecorder
    let runner: FinalJobRunner
    let workspace: WorkspacePresentation
    let captures = Box<[ScriptedCapture]>([])
    let host = Box<UInt64>(ticks(100))
    let wall = Box<Date>(Date().addingTimeInterval(60))
    let processed = Box<[UUID]>([])
    /// Called by the scripted processor for each job; default marks it validated.
    let behavior = Box<@Sendable (UUID, SessionStore) async throws -> Void>({ id, store in
        try await store.updateJob(id, stage: .validating)
    })
    let defaults: UserDefaults

    init() async throws {
        folder = try TemporaryFolder()
        let library = try await OwnedLibrary().open(root: folder.url)
        store = try await SessionStore.open(library)
        let captures = captures, host = host, wall = wall
        recorder = MeetingRecorder(library: library, store: store, capture: { callbacks in
            let capture = ScriptedCapture(callbacks)
            captures.value.append(capture)
            return capture
        }, playback: nil, jobs: FinalJobPolicy(models: { speechModels }, missing: { _ in [] },
            settings: { ProcessingSettings(meetingLanguage: $0.language) }), startTimeout: .seconds(5),
            hostClock: { host.value }, wallClock: { wall.value }, timeZone: { "Europe/Berlin" }, wrapSink: nil)
        let store = store, processed = processed, behavior = behavior
        runner = FinalJobRunner(store: store) { id in
            processed.value.append(id)
            try await behavior.value(id, store)
        }
        defaults = UserDefaults(suiteName: "WorkspacePresentationTests-\(UUID())")!
        workspace = WorkspacePresentation(store: store, recorder: recorder, runner: runner, defaults: defaults)
    }

    /// Both sources deliver `seconds` of tone; the clocks then advance.
    func deliver(seconds: Double) async {
        let callbacks = await captures.value.last!.callbacks
        let origin = host.value, frames = 1_024
        let packets = Int((seconds * 48_000 / Double(frames)).rounded(.up))
        for index in 0..<packets {
            for source in [CaptureSource.system, .microphone] {
                let samples = (0..<frames).map { Float(sin(Double(index * frames + $0) * 0.05)) * 0.1 }
                callbacks.receive(AudioPacket(source: source, sampleRate: 48_000,
                    hostTime: origin + ticks(Double(index * frames) / 48_000), sampleTime: Double(index * frames), samples: samples))
            }
            if index % 64 == 63 { await recorder.drainCapture() }
        }
        host.value = origin + ticks(Double(packets * frames) / 48_000)
        wall.value = wall.value.addingTimeInterval(seconds)
    }

    func remove() { workspace.stopObserving(); folder.remove() }
}

/// Events arrive asynchronously; poll a condition for up to five seconds.
@MainActor private func until(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@MainActor @Suite(.serialized) struct WorkspacePresentationTests {
    @Test func meetingsAreCreatedSearchedRenamedAndDeletedWithEmptyStates() async throws {
        let f = try await WorkspaceFixture()
        defer { f.remove() }
        let w = f.workspace
        await w.start()
        #expect(w.isLoaded && !w.hasMeetings && w.meetings.isEmpty && w.selectedID == nil)

        await #expect(throws: MeetingDraft.ValidationError.emptyTitle) {
            try await w.createMeeting(title: "   ", description: "ignored")
        }
        #expect(!w.hasMeetings)

        f.defaults.set(MeetingLanguage.russian.rawValue, forKey: ProcessingPreferences.meetingLanguageKey)
        let first = try await w.createMeeting(title: "Weekly sync", description: "Progress and OPEN tasks")
        try await Task.sleep(for: .milliseconds(5))
        let second = try await w.createMeeting(title: "Product planning", description: "October plan")
        #expect(w.selectedID == second.id && w.selected?.title == "Product planning")
        #expect(w.meetings.map(\.id) == [second.id, first.id])
        #expect(first.language == .russian)

        w.search = "open"
        #expect(await until { w.meetings.map(\.id) == [first.id] })
        w.search = "nothing matches"
        #expect(await until { w.meetings.isEmpty })
        #expect(w.hasMeetings)   // a search miss is not an empty library
        w.search = ""
        #expect(await until { w.meetings.count == 2 })

        try await w.renameMeeting(second.id, title: " Roadmap ", description: "Q4 priorities")
        #expect(w.selected?.title == "Roadmap" && w.selected?.description == "Q4 priorities")
        await #expect(throws: MeetingDraft.ValidationError.emptyTitle) {
            try await w.renameMeeting(second.id, title: "", description: "x")
        }
        #expect(try await f.store.meeting(second.id).title == "Roadmap")

        await w.deleteMeeting(second.id)
        #expect(w.meetings.map(\.id) == [first.id])
        #expect(await until { w.selectedID == first.id && w.selected?.id == first.id })
        await w.deleteMeeting(first.id)
        #expect(!w.hasMeetings && w.selectedID == nil)
        #expect(w.issue == nil)
    }

    @Test func onlyOneMeetingRecordsAndControlsFollowTheActiveCapture() async throws {
        let f = try await WorkspaceFixture()
        defer { f.remove() }
        let w = f.workspace
        await w.start()
        let older = try await w.createMeeting(title: "Older", description: "")
        let other = try await w.createMeeting(title: "Other", description: "")
        #expect(w.meetings.map(\.id) == [other.id, older.id])
        let idle = w.controls(for: older.id)
        #expect(idle.primary == .record && idle.primaryEnabled && idle.secondary == .pause && !idle.secondaryEnabled)

        w.selectedID = older.id
        #expect(await until { w.selected?.id == older.id })
        await w.record()
        #expect(await until { w.phase == .recording && w.activeMeeting?.id == older.id })
        // Recording an older meeting moves it to the top.
        #expect(await until { w.meetings.first?.id == older.id })
        #expect(w.selectedStatus == .recording)
        let recording = w.controls(for: older.id)
        #expect(recording.primary == .stop && recording.primaryEnabled && recording.secondary == .pause && recording.secondaryEnabled)
        await f.deliver(seconds: 3)

        // Another meeting can be inspected, but cannot start a second capture or delete the active one.
        w.selectedID = other.id
        #expect(await until { w.selected?.id == other.id })
        let blocked = w.controls(for: other.id)
        #expect(blocked.primary == .record && !blocked.primaryEnabled && blocked.primaryHelp.contains("Older"))
        await w.record()
        #expect(w.issue?.message == "Another recording is already active")
        w.issue = nil
        #expect(!w.canDelete(older.id) && w.canDelete(other.id))
        await w.deleteMeeting(older.id)
        #expect(w.issue?.recovery == "Stop the recording before deleting the meeting.")
        #expect(try await f.store.meeting(older.id).id == older.id)
        w.issue = nil
        #expect(f.captures.value.count == 1)

        // A search hiding the active meeting is cleared when returning to it.
        w.search = "Other"
        #expect(await until { w.meetings.map(\.id) == [other.id] })
        w.showActiveMeeting()
        #expect(w.search.isEmpty && w.selectedID == older.id)
        #expect(await until { w.selected?.id == older.id && w.meetings.count == 2 })

        await w.pause()
        #expect(await until { w.phase == .paused })
        let paused = w.controls(for: older.id)
        #expect(paused.primary == .stop && paused.primaryEnabled && paused.secondary == .resume && paused.secondaryEnabled)
        #expect(w.selectedStatus == .paused)
        await w.resume()
        #expect(await until { w.phase == .recording })
        await f.deliver(seconds: 2)

        await w.stop()
        #expect(await until { w.phase == .idle && w.activeMeeting == nil })
        #expect(w.controls(for: other.id).primaryEnabled)
        #expect(w.recordings.count == 1 && w.recordings[0].state == .complete)
        // Stop queued a job; the runner picked it up.
        #expect(await until { f.processed.value.count == 1 })
        #expect(await until { w.jobs.first?.stage == .validating })
        #expect(w.selectedStatus == .processing(.validating))
        #expect(w.canDelete(older.id) && w.issue == nil)

        // A second Record appends a separate recording to the same meeting.
        await w.record()
        #expect(await until { w.phase == .recording })
        await f.deliver(seconds: 2)
        await w.stop()
        #expect(await until { w.phase == .idle && w.recordings.count == 2 })
        #expect(Set(w.recordings.map(\.id)).count == 2)
        #expect(await until { f.processed.value.count == 2 })
    }

    @Test func reprocessQueuesEverySavedRecordingAgainOnlyWhenIdle() async throws {
        let f = try await WorkspaceFixture()
        defer { f.remove() }
        let w = f.workspace
        let policy = FinalJobPolicy(models: { speechModels }, missing: { _ in [] },
                                    settings: { ProcessingSettings(meetingLanguage: $0.language) })
        await w.start()
        _ = try await w.createMeeting(title: "Weekly", description: "")
        for _ in 0..<2 {
            await w.record()
            #expect(await until { w.phase == .recording })
            #expect(!w.canReprocess)
            await f.deliver(seconds: 1)
            await w.stop()
            #expect(await until { w.phase == .idle })
        }
        #expect(await until { f.processed.value.count == 2 && w.canReprocess })
        let first = Set(f.processed.value)
        await w.reprocess(policy: policy)
        #expect(await until { f.processed.value.count == 4 && w.canReprocess })
        // Two new jobs, one per recording, never the old ones again.
        #expect(Set(f.processed.value.suffix(2)).isDisjoint(with: first))
        let recordings = Set(w.jobs.filter { !first.contains($0.id) }.compactMap(\.snapshot.recordingID))
        #expect(recordings == Set(w.recordings.map(\.id)))
    }

    @Test func processingFailuresAreRetriedAndDeletionCancelsRunningWork() async throws {
        let f = try await WorkspaceFixture()
        defer { f.remove() }
        let w = f.workspace
        f.behavior.value = { id, store in
            try await store.updateJob(id, stage: .failed, error: "Decoder error")
            throw ServiceError(message: "Decoder error", recovery: "Retry")
        }
        await w.start()
        let meeting = try await w.createMeeting(title: "Interview", description: "")
        await w.record()
        #expect(await until { w.phase == .recording })
        await f.deliver(seconds: 2)
        await w.stop()
        #expect(await until { if case .failed = w.selectedStatus { true } else { false } })
        guard case .failed(let jobID, let message)? = w.selectedStatus else { Issue.record("not failed"); return }
        #expect(message == "Decoder error" && w.selectedStatus?.retryJobID == jobID)

        // Retry returns the same job to the queue; this run blocks until cancelled.
        let started = Box(false)
        f.behavior.value = { _, _ in
            started.value = true
            try await Task.sleep(for: .seconds(60))
        }
        await w.retry(jobID: jobID)
        #expect(await until { started.value && w.runningJobMeetingID == meeting.id })
        #expect(f.processed.value == [jobID, jobID])

        // Deleting the meeting cancels the running job first, then removes everything.
        let begin = ContinuousClock.now
        await w.deleteMeeting(meeting.id)
        #expect(ContinuousClock.now - begin < .seconds(10))
        await #expect(throws: StoreError.missingMeeting) { try await f.store.meeting(meeting.id) }
        #expect(await until { w.runningJobMeetingID == nil })
        #expect(!w.hasMeetings && w.selectedID == nil)
        #expect(try await f.store.queuedJobs(kind: .finalTranscription).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.folder.url
            .appendingPathComponent(".talktrack-library/Meetings/\(meeting.id)").path))
    }

    @Test func cancelStopsTheRunningAndQueuedTranscriptionsOfTheMeeting() async throws {
        let f = try await WorkspaceFixture()
        defer { f.remove() }
        let w = f.workspace
        // Like the pipeline: a cancelled run tries to mark itself interrupted, which a
        // job the user cancelled refuses.
        f.behavior.value = { id, store in
            try await store.updateJob(id, stage: .transcribing)
            do { try await Task.sleep(for: .seconds(60)) } catch {
                try? await store.updateJob(id, stage: .interrupted, error: "Cancelled")
                throw error
            }
        }
        await w.start()
        let meeting = try await w.createMeeting(title: "Long call", description: "")
        for _ in 0..<2 {
            await w.record()
            #expect(await until { w.phase == .recording })
            await f.deliver(seconds: 1)
            await w.stop()
            #expect(await until { w.phase == .idle })
        }
        // The first recording runs, the second waits behind it.
        #expect(await until { f.processed.value.count == 1 && w.queueStates[meeting.id] == .running })
        #expect(w.canCancelProcessing && w.selectedStatus?.isQueuedOrProcessing == true)
        #expect(w.selectedProgress != nil)

        await w.cancelProcessing()
        #expect(await until { w.runningJobMeetingID == nil })
        let stages = try await f.store.jobs(meetingID: meeting.id).map(\.stage)
        #expect(stages == [.cancelled, .cancelled])
        #expect(w.queueStates.isEmpty && !w.canCancelProcessing && w.selectedProgress == nil)
        // Nothing else starts; without an earlier transcript the audio can be transcribed again.
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.processed.value.count == 1)
        if case .notProcessed? = w.selectedStatus {} else { Issue.record("\(String(describing: w.selectedStatus))") }
        #expect(w.canReprocess)
    }

    @Test func deletingARecordingStopsItsWorkAndPlaybackAndIsRefusedWhileCapturing() async throws {
        let f = try await WorkspaceFixture()
        defer { f.remove() }
        let w = f.workspace
        // Transcription runs until cancelled, like the pipeline.
        f.behavior.value = { id, store in
            try await store.updateJob(id, stage: .transcribing)
            do { try await Task.sleep(for: .seconds(60)) } catch {
                try? await store.updateJob(id, stage: .interrupted, error: "Cancelled")
                throw error
            }
        }
        let stopped = Box<[UUID]>([])
        w.stopPlayback = { stopped.value.append($0) }
        await w.start()
        let meeting = try await w.createMeeting(title: "Two takes", description: "")
        await w.record()
        #expect(await until { w.phase == .recording })
        await f.deliver(seconds: 1)
        await w.stop()
        #expect(await until { w.phase == .idle && w.queueStates[meeting.id] == .running })
        let first = try #require(w.recordings.first)
        // The second take is capturing: it cannot be deleted.
        await w.record()
        #expect(await until { w.phase == .recording && w.recordings.count == 2 })
        let second = try #require(w.recordings.first { $0.id != first.id })
        #expect(w.deleteRefusal(recordingID: second.id) == "Stop recording before deleting this recording.")
        await w.deleteRecording(second.id)
        #expect(w.issue != nil && w.recordings.count == 2)
        w.issue = nil
        await f.deliver(seconds: 1)
        await w.stop()
        #expect(await until { w.phase == .idle })

        // Deleting the first take stops playback and its running transcription.
        #expect(w.deleteRefusal(recordingID: first.id) == nil)
        await w.deleteRecording(first.id)
        #expect(w.issue == nil && stopped.value == [meeting.id])
        #expect(w.recordings.map(\.id) == [second.id])
        #expect(try await f.store.jobs(meetingID: meeting.id).allSatisfy { $0.snapshot.recordingID == second.id })
        // The second take's transcription runs next.
        #expect(await until { f.processed.value.count == 2 && w.queueStates[meeting.id] == .running })
        #expect(!FileManager.default.fileExists(atPath: f.folder.url
            .appendingPathComponent(".talktrack-library/Meetings/\(meeting.id)/Recordings/\(first.id)").path))
    }

    @Test func aMeetingWaitingBehindAnotherShowsItsPlaceInTheQueue() async throws {
        let f = try await WorkspaceFixture()
        defer { f.remove() }
        let w = f.workspace
        let released = Box<Set<UUID>>([])
        f.behavior.value = { id, store in
            try await store.updateJob(id, stage: .transcribing)
            while !released.value.contains(id) { try await Task.sleep(for: .milliseconds(10)) }
            try await store.updateJob(id, stage: .validating)
        }
        await w.start()
        var meetings: [Meeting] = []
        for title in ["Daily 5", "Weekly"] {
            let meeting = try await w.createMeeting(title: title, description: "")
            meetings.append(meeting)
            await w.record()
            #expect(await until { w.phase == .recording })
            await f.deliver(seconds: 1)
            await w.stop()
            #expect(await until { w.phase == .idle })
        }
        let (a, b) = (meetings[0], meetings[1])
        #expect(await until { w.queueStates == [a.id: .running, b.id: .queued(position: 2, after: "Daily 5")] })
        // Weekly is selected: it names its place and what it waits for.
        #expect(w.selectedID == b.id && w.selectedStatus == .queued)
        #expect(w.selectedQueueMessage == "In queue: 2nd, after “Daily 5”" && w.selectedProgress == nil)

        // Daily 5 finishes: Weekly runs with progress, Daily 5 leaves the queue.
        released.value.insert(try #require(f.processed.value.first))
        #expect(await until { w.queueStates == [b.id: .running] })
        #expect(await until { w.selectedProgress != nil && w.selectedQueueMessage == nil })
        released.value.insert(try #require(f.processed.value.last))
        #expect(await until { w.queueStates.isEmpty && w.selectedProgress == nil })
    }

    @Test func quittingSavesCaptureKeepsProcessingForTheNextLaunchAndWritesNotes() async throws {
        let f = try await WorkspaceFixture()
        defer { f.remove() }
        let w = f.workspace
        // Processing behaves like the pipeline: cancellation leaves the job interrupted.
        let started = Box(false)
        f.behavior.value = { id, store in
            try await store.updateJob(id, stage: .transcribing)
            started.value = true
            do { try await Task.sleep(for: .seconds(60)) } catch {
                try? await store.updateJob(id, stage: .interrupted, error: "Cancelled")
                throw error
            }
        }
        await w.start()
        let processed = try await w.createMeeting(title: "Processed", description: "")
        await w.record()
        #expect(await until { w.phase == .recording })
        await f.deliver(seconds: 2)
        await w.stop()
        #expect(await until { started.value && w.runningJobMeetingID == processed.id })
        let runningJob = try #require(f.processed.value.first)

        // A second meeting records (and has unsaved notes) when the user quits.
        let recorded = try await w.createMeeting(title: "Recorded", description: "")
        await w.record()
        #expect(await until { w.phase == .recording && w.activeMeeting?.id == recorded.id })
        await f.deliver(seconds: 3)
        let notes = NotesAutosave(store: f.store, delay: .seconds(60))
        try await notes.edit(meetingID: recorded.id, text: "Follow up on budget")
        #expect(try await f.store.notes(meetingID: recorded.id)?.text != "Follow up on budget")

        let report = await w.prepareToQuit(notes: notes)
        // Capture stopped and the recording is saved with its audio.
        let saved = try #require(report.saved?.recording)
        #expect(await f.recorder.phase == .idle && w.isQuitting)
        let stored = try await f.store.recordings(meetingID: recorded.id)
        #expect(stored.map(\.id) == [saved.id] && stored[0].state == .complete && !stored[0].chunks.isEmpty)
        // Its transcription is queued for the next launch, not started now.
        let newJob = try #require(report.saved?.job)
        #expect(try await f.store.job(newJob.id).stage == .queued)
        // The running job stopped at a checkpoint and is queued again.
        #expect(report.cancelledJobID == runningJob && report.requeued)
        #expect(try await f.store.job(runningJob).stage == .queued)
        #expect(try await f.store.notes(meetingID: recorded.id)?.text == "Follow up on budget")

        // Nothing starts afterwards: no processing, no new capture.
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.processed.value == [runningJob])
        await w.record()
        #expect(await f.recorder.phase == .idle && f.captures.value.count == 2)
        // Quitting again (or when idle) has nothing left to do.
        let again = await w.prepareToQuit(notes: notes)
        #expect(again.saved == nil && again.cancelledJobID == nil)
    }

    @Test func waitingJobsNameOnlyTheModelsStillMissing() async throws {
        let f = try await WorkspaceFixture()
        defer { f.remove() }
        let w = f.workspace
        let installed = Box<Set<ModelRole>>([.finalASR, .alignment, .embedding, .spelling])
        w.unavailableModels = { snapshots in snapshots.map(\.role).filter { !installed.value.contains($0) } }
        f.behavior.value = { id, store in
            try await store.updateJob(id, stage: .waitingForModels, error: "Missing")
            throw FinalTranscriptionError.missingModels([.segmentation])
        }
        await w.start()
        _ = try await w.createMeeting(title: "Needs a model", description: "")
        await w.record()
        #expect(await until { w.phase == .recording })
        await f.deliver(seconds: 1)
        await w.stop()
        #expect(await until { w.selectedStatus?.message == "Transcription needs models: Speaker detection" })
        guard case .waitingForModels(let jobID, let roles)? = w.selectedStatus else { Issue.record("not waiting"); return }
        #expect(roles == [.segmentation] && w.selectedStatus?.retryJobID == jobID)

        // After the download, the status says Retry instead of naming a model.
        installed.value.insert(.segmentation)
        await w.refreshMissingModels()
        #expect(w.selectedStatus == .waitingForModels(jobID: jobID, roles: []))
        #expect(w.selectedStatus?.message == "The required models are installed. Retry to transcribe this recording.")
        // A removed model is named again; nothing is retried automatically.
        installed.value.remove(.alignment)
        await w.refreshMissingModels()
        #expect(w.selectedStatus?.message == "Transcription needs models: Word timing")
        #expect(f.processed.value == [jobID])
    }

    @Test func statusPrefersTheMostActionableRecordingState() throws {
        let meeting = UUID()
        func recording(_ state: RecordingState, chunks: Bool = true) throws -> Recording {
            var value = try Recording(meetingID: meeting, timeZoneIdentifier: "UTC")
            value.state = state
            if chunks {
                value.chunks = [try TrackChunk(track: .system, file: try RelativePath("a.m4a"),
                    active: try MediaInterval(start: .zero, end: try MediaTime(seconds: 1)),
                    sampleRate: 48_000, decodedFrameCount: 48_000, leadingTrimFrames: 0, trailingTrimFrames: 0, hostTimeStart: 0)]
            }
            return value
        }
        func job(_ recording: Recording, _ stage: JobStage, error: String? = nil) -> ProcessingJob {
            ProcessingJob(snapshot: ProcessingJobSnapshot(kind: .finalTranscription, recordingID: recording.id,
                source: SourceSnapshot(meetingID: meeting, meetingGeneration: 1, cancellationGeneration: 0,
                                       recordingGenerations: [recording.id: 1], transcriptRevisionIDs: [], notesRevisionID: nil),
                settings: ProcessingSettings(meetingLanguage: .auto), models: speechModels), stage: stage, lastError: error)
        }
        typealias S = MeetingProcessingStatus
        #expect(S.derive(recordings: [], jobs: []) == .noRecordings)
        let a = try recording(.complete), b = try recording(.interrupted)
        #expect(S.derive(recordings: [a], jobs: []) == .notProcessed(recordingID: a.id))
        #expect(S.derive(recordings: [try recording(.complete, chunks: false)], jobs: []) == .ready)
        #expect(S.derive(recordings: [a, b], jobs: [job(a, .completed), job(b, .completed)]) == .ready)
        #expect(S.derive(recordings: [a, b], jobs: [job(a, .completed), job(b, .transcribing)]) == .processing(.transcribing))
        let waiting = job(b, .waitingForModels)
        #expect(S.derive(recordings: [a, b], jobs: [job(a, .queued), waiting])
                == .waitingForModels(jobID: waiting.id, roles: FinalTranscriptionPipeline.requiredRoles))
        let failed = job(a, .failed, error: "Disk")
        #expect(S.derive(recordings: [a, b], jobs: [failed, waiting]) == .failed(jobID: failed.id, message: "Disk"))
        // The latest job per recording decides: a retried, completed run replaces an old failure.
        #expect(S.derive(recordings: [a], jobs: [failed, job(a, .completed)]) == .ready)
        #expect(S.derive(recordings: [try recording(.paused)], jobs: []) == .paused)
        // A cancelled reprocess leaves a transcribed recording ready, an untranscribed one not processed.
        #expect(S.derive(recordings: [a], jobs: [job(a, .completed), job(a, .cancelled)]) == .ready)
        #expect(S.derive(recordings: [a], jobs: [job(a, .cancelled)]) == .notProcessed(recordingID: a.id))
        #expect(S.ready.message == "Transcript ready")
    }

    @Test func systemAudioHintNeedsLongExactZerosWhileTheMicrophoneHearsSpeech() async throws {
        let f = try await WorkspaceFixture()
        defer { f.remove() }
        let w = f.workspace
        await w.start()
        let meeting = try await w.createMeeting(title: "Call", description: "")
        w.selectedID = meeting.id
        #expect(await until { w.selected?.id == meeting.id })
        await w.record()
        #expect(await until { w.phase == .recording })
        #expect(w.systemAudioHint == nil)
        // One-second packets at 10 Hz reach the ten-minute threshold without real time.
        func second(_ source: CaptureSource, _ value: Float) {
            w.levels.record(AudioPacket(source: source, sampleRate: 10, hostTime: 1, sampleTime: 0,
                                        samples: (0..<10).map { value * Float(sin(Double($0))) }))
        }
        // A quiet but non-zero system track with a silent microphone: no hint.
        for _ in 0..<700 { second(.system, 1e-5); second(.microphone, 0) }
        #expect(w.systemAudioHint == nil)
        // Exact zeros while nobody speaks: still no hint.
        for _ in 0..<700 { second(.system, 0); second(.microphone, 0) }
        #expect(w.systemAudioHint == nil)
        // Exact zeros while the microphone hears speech: the hint appears.
        for index in 0..<700 { second(.system, 0); second(.microphone, index % 10 == 0 ? 0.2 : 0) }
        #expect(w.systemAudioHint == WorkspacePresentation.systemAudioHintText)
        // Any real system sample clears it.
        second(.system, 0.01)
        #expect(w.systemAudioHint == nil)
        await w.stop()
        #expect(await until { w.phase == .idle })
    }
}
