import AVFoundation
import Darwin
import Foundation
import Testing
import TalkTrackAudio
import TalkTrackDomain
@testable import TalkTrackServices

private func ticks(_ seconds: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: seconds) }
private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

/// Scripted capture: the test pushes packets through the recorder's callbacks.
private actor FakeMeetingCapture: MeetingCaptureControl {
    let callbacks: MeetingCaptureCallbacks
    private let log: Locked<[String]>
    private let startError: Error?
    private let beforeFailure: (@Sendable (MeetingCaptureCallbacks) -> Void)?
    init(callbacks: MeetingCaptureCallbacks, log: Locked<[String]>, startError: Error?,
         beforeFailure: (@Sendable (MeetingCaptureCallbacks) -> Void)?) {
        self.callbacks = callbacks; self.log = log; self.startError = startError; self.beforeFailure = beforeFailure
    }
    func start(timeout: Duration) async throws {
        log.mutate { $0.append("capture.start") }
        if let startError {
            beforeFailure?(callbacks)
            throw startError
        }
    }
    func pause() async throws { log.mutate { $0.append("capture.pause") } }
    func stop() async { log.mutate { $0.append("capture.stop") } }
}

private struct Playback: CapturePlaybackExclusion {
    let log: Locked<[String]>
    func stopPlaybackBeforeCapture() async { log.mutate { $0.append("playback.stop") } }
}

/// Delegates to the real writer and fails appends with ENOSPC after a limit.
private actor FullDiskSink: CaptureAudioSink {
    let writer: RecordingAudioWriter
    let limit: UInt64
    init(writer: RecordingAudioWriter, limit: UInt64) { self.writer = writer; self.limit = limit }
    func append(track: AudioTrack, samples: [Float], activeStartFrame: UInt64, hostTimeStart: UInt64) async throws {
        guard activeStartFrame + UInt64(samples.count) <= limit else {
            throw LibraryError.io(operation: "write AAC audio", code: ENOSPC)
        }
        try await writer.append(track: track, samples: samples, activeStartFrame: activeStartFrame, hostTimeStart: hostTimeStart)
    }
    func closeInterval() async throws { try await writer.closeInterval() }
    func updateCaptureTiming(_ timing: CaptureTimingSnapshot, state: RecordingState) async throws {
        try await writer.updateCaptureTiming(timing, state: state)
    }
    func recordGap(track: AudioTrack, active: MediaInterval, reason: String) async throws {
        try await writer.recordGap(track: track, active: active, reason: reason)
    }
    func finish(interrupted: Bool) async throws -> RecordingAudioManifest { try await writer.finish(interrupted: interrupted) }
}

private let speechModels = FinalTranscriptionPipeline.requiredRoles.map {
    ModelSnapshot(role: $0, repository: "fixture/\($0.rawValue)", revision: String(repeating: "a", count: 40),
                  directory: try! RelativePath("fixture/\($0.rawValue)"), preprocessingVersion: "1")
}

private final class RecorderFixture: @unchecked Sendable {
    let folder: TemporaryFolder
    let library: OpenedLibrary
    let store: SessionStore
    let meeting: Meeting
    let log = Locked<[String]>([])
    let host = Locked<UInt64>(ticks(100))
    let wall = Locked<Date>(utc("2026-10-08T10:00:00Z"))
    let missing = Locked<[ModelRole]>([])
    let startError = Locked<Error?>(nil)
    let beforeFailure = Locked<(@Sendable (MeetingCaptureCallbacks) -> Void)?>(nil)
    let captures = Locked<[FakeMeetingCapture]>([])
    let fullDiskAfter = Locked<UInt64?>(nil)
    var recorder: MeetingRecorder!

    init() async throws {
        folder = try TemporaryFolder()
        library = try await OwnedLibrary().open(root: folder.url)
        store = try await SessionStore.open(library)
        meeting = try await store.createMeeting(MeetingDraft(title: "Planning", description: "Weekly"),
                                                at: utc("2026-10-01T09:00:00Z"))
        recorder = makeRecorder()
    }

    func makeRecorder() -> MeetingRecorder {
        let log = log, startError = startError, beforeFailure = beforeFailure, captures = captures
        let host = host, wall = wall, missing = missing, fullDisk = fullDiskAfter
        return MeetingRecorder(library: library, store: store, capture: { callbacks in
            let capture = FakeMeetingCapture(callbacks: callbacks, log: log, startError: startError.value,
                                             beforeFailure: beforeFailure.value)
            captures.mutate { $0.append(capture) }
            return capture
        }, playback: Playback(log: log), jobs: FinalJobPolicy(models: { speechModels }, missing: { _ in missing.value },
            settings: { ProcessingSettings(meetingLanguage: $0.language) }), startTimeout: .seconds(5),
            hostClock: { host.value }, wallClock: { wall.value }, timeZone: { "Europe/Berlin" },
            wrapSink: { writer -> any CaptureAudioSink in
                if let limit = fullDisk.value { return FullDiskSink(writer: writer, limit: limit) }
                return writer
            })
    }

    var callbacks: MeetingCaptureCallbacks { get async { await captures.value.last!.callbacks } }

    /// Both sources deliver `seconds` of a quiet tone from the current host
    /// time; the host clock then advances past the delivered audio.
    func deliver(seconds: Double, sources: [CaptureSource] = [.system, .microphone]) async {
        let callbacks = await callbacks
        let origin = host.value, frames = 1_024
        let packets = Int((seconds * 48_000 / Double(frames)).rounded(.up))
        for index in 0..<packets {
            for source in sources {
                let samples = (0..<frames).map { Float(sin(Double(index * frames + $0) * 0.05)) * 0.1 }
                callbacks.receive(AudioPacket(source: source, sampleRate: 48_000,
                    hostTime: origin + ticks(Double(index * frames) / 48_000), sampleTime: Double(index * frames), samples: samples))
            }
            // Real drivers deliver in real time; never outrun the bounded queue.
            if index % 64 == 63 { await recorder.drainCapture() }
        }
        host.value = origin + ticks(Double(packets * frames) / 48_000)
    }

    func remove() { folder.remove() }
}

private func storedFrames(_ recording: Recording, _ track: AudioTrack) -> UInt64 {
    recording.chunks.filter { $0.track == track }.reduce(0) { $0 + $1.decodedFrameCount }
}

private func nextStopped(_ recorder: MeetingRecorder) async -> RecordingStopResult? {
    for await event in recorder.events { if case .stopped(let result) = event { return result } }
    return nil
}

/// Abandons a writer the way a crash would: committed chunks stay, the open
/// chunk remains a pending file and the folder lock is released with the process.
private func crashedWriter(_ library: OpenedLibrary, _ recording: Recording, seconds: Double) async throws {
    var clock = CaptureIntervalClock()
    let origin = ticks(50)
    try clock.begin(hostTime: origin, wallClock: recording.startedAt, timeZoneIdentifier: recording.timeZoneIdentifier)
    var writer: RecordingAudioWriter? = try await RecordingAudioWriter.create(library: library, recording: recording)
    let frames = Int(seconds * 48_000)
    try await writer!.updateCaptureTiming(clock.checkpoint(at: origin + ticks(seconds)), state: .recording)
    var offset = 0
    while offset < frames {
        let count = min(48_000, frames - offset)
        let samples = (0..<count).map { Float(sin(Double(offset + $0) * 0.03)) * 0.1 }
        for track in AudioTrack.allCases {
            try await writer!.append(track: track, samples: samples, activeStartFrame: UInt64(offset),
                                     hostTimeStart: origin + ticks(Double(offset) / 48_000))
        }
        offset += count
    }
    writer = nil
}

@Suite(.serialized) struct MeetingRecorderTests {
    @Test func recordingsOnDifferentDaysStaySeparateAndEachStopQueuesFinalTranscription() async throws {
        let f = try await RecorderFixture()
        defer { f.remove() }
        let first = try await f.recorder.start(meetingID: f.meeting.id)
        #expect(await f.recorder.phase == .recording)
        #expect(try await f.store.recordings(meetingID: f.meeting.id).map(\.state) == [.recording])
        await f.deliver(seconds: 12)
        let one = try await f.recorder.stop()
        #expect(one.recording.id == first.id && one.recording.state == .complete && one.issue == nil)
        #expect(storedFrames(one.recording, .system) >= 11 * 48_000 && storedFrames(one.recording, .microphone) >= 11 * 48_000)
        #expect(one.job?.stage == .queued && one.job?.snapshot.recordingID == first.id)
        #expect(one.job?.snapshot.source.recordingGenerations[first.id] == one.recording.generation)

        f.wall.value = utc("2026-10-10T08:30:00Z")
        f.host.value += ticks(3_600)
        let second = try await f.recorder.start(meetingID: f.meeting.id)
        await f.deliver(seconds: 4)
        let two = try await f.recorder.stop()
        #expect(two.recording.id != first.id && two.recording.state == .complete)

        let saved = try await f.store.recordings(meetingID: f.meeting.id)
        #expect(saved.map(\.id) == [first.id, second.id])
        // The earlier recording is untouched by the later one.
        #expect(saved[0] == one.recording)
        #expect(saved.map { $0.days.map(\.localDate) } == [["2026-10-08"], ["2026-10-10"]])
        for recording in saved {
            #expect(recording.chunks.allSatisfy { $0.file.value.contains("/Recordings/\(recording.id)/") })
        }
        #expect(Set(try await RecordingAudioWriter.storedRecordingIDs(library: f.library, meetingID: f.meeting.id)) == [first.id, second.id])
        let timeline = try MeetingTimeline(meetingID: f.meeting.id, recordings: saved)
        #expect(timeline.recordings.map(\.recordingID) == [first.id, second.id])
        #expect(abs(timeline.totalDuration.seconds - (one.recording.activeDuration.seconds + two.recording.activeDuration.seconds)) < 0.001)
        #expect(try await f.store.meeting(f.meeting.id).latestRecordingStartedAt == utc("2026-10-10T08:30:00Z"))
        let jobs = try await f.store.jobs(meetingID: f.meeting.id)
        #expect(jobs.map(\.snapshot.recordingID) == [first.id, second.id])
        #expect(jobs.allSatisfy { $0.snapshot.kind == .finalTranscription && $0.snapshot.models == speechModels })
    }

    @Test func playbackStopsFirstOneCaptureAtATimeAndPauseResumeAcrossDaysPublishes() async throws {
        let f = try await RecorderFixture()
        defer { f.remove() }
        let other = try await f.store.createMeeting(MeetingDraft(title: "Other"))
        let recording = try await f.recorder.start(meetingID: f.meeting.id)
        #expect(f.log.value == ["playback.stop", "capture.start"])
        await #expect(throws: ServiceError.self) { try await f.recorder.start(meetingID: other.id) }
        #expect(try await f.store.recordings(meetingID: other.id).isEmpty)

        await f.deliver(seconds: 11)
        try await f.recorder.pause()
        let paused = try await f.store.recordings(meetingID: f.meeting.id)[0]
        #expect(paused.state == .paused && paused.generation == 1 && !paused.chunks.isEmpty)

        // Resume after midnight: same recording, a second capture day.
        f.wall.value = utc("2026-10-09T07:00:00Z")
        f.host.value += ticks(20 * 3_600)
        f.log.value = []
        try await f.recorder.resume()
        #expect(f.log.value == ["playback.stop", "capture.start"])
        await f.deliver(seconds: 3)
        let result = try await f.recorder.stop()
        #expect(result.recording.id == recording.id && result.recording.state == .complete)
        #expect(result.recording.days.map(\.localDate) == ["2026-10-08", "2026-10-09"])
        #expect(result.recording.captureIntervals.count == 2)
        #expect(abs(result.recording.activeDuration.seconds - 14) < 0.1)
        #expect(result.recording.generation == 2)
        #expect(try await f.store.recordings(meetingID: f.meeting.id) == [result.recording])
        #expect(await f.recorder.phase == .idle)
        await #expect(throws: ServiceError.self) { _ = try await f.recorder.stop() }
    }

    @Test func missingModelsLeaveTheJobWaitingWithTheSavedAudio() async throws {
        let f = try await RecorderFixture()
        defer { f.remove() }
        f.missing.value = [.finalASR, .spelling]
        try await f.recorder.start(meetingID: f.meeting.id)
        await f.deliver(seconds: 2)
        let result = try await f.recorder.stop()
        #expect(result.recording.state == .complete && !result.recording.chunks.isEmpty)
        #expect(result.job?.stage == .waitingForModels)
        #expect(result.job?.lastError?.contains("finalASR, spelling") == true)
    }

    @Test func fullDiskDuringCaptureStopsSafelyAndKeepsCommittedAudio() async throws {
        let f = try await RecorderFixture()
        defer { f.remove() }
        f.fullDiskAfter.value = 13 * 48_000
        let stopped = Task { await nextStopped(f.recorder) }
        let recording = try await f.recorder.start(meetingID: f.meeting.id)
        await f.deliver(seconds: 20)
        let result = try #require(await stopped.value)
        #expect(result.recording.id == recording.id && result.recording.state == .interrupted)
        #expect(result.issue?.message.contains("system error \(ENOSPC)") == true)
        // Every frame accepted before the failure is retained (first chunk + flushed rest).
        for track in AudioTrack.allCases { #expect(storedFrames(result.recording, track) >= 10 * 48_000) }
        #expect(f.log.value.contains("capture.stop"))
        #expect(await f.recorder.phase == .idle)
        let saved = try await f.store.recordings(meetingID: f.meeting.id)
        #expect(saved == [result.recording])
        #expect(result.job?.stage == .queued)
        let reread = try await RecordingAudioWriter.recover(library: f.library, meetingID: f.meeting.id, recordingID: recording.id)
        #expect(reread.recording.chunks == result.recording.chunks)
    }

    @Test func sourceLostDuringRecordingFinalizesAsInterrupted() async throws {
        let f = try await RecorderFixture()
        defer { f.remove() }
        let stopped = Task { await nextStopped(f.recorder) }
        try await f.recorder.start(meetingID: f.meeting.id)
        await f.deliver(seconds: 3)
        await f.callbacks.failed(AudioCaptureError(source: .microphone,
            operation: "Cannot restart after a device change: device unavailable", status: nil))
        let result = try #require(await stopped.value)
        #expect(result.recording.state == .interrupted)
        #expect(result.issue?.message.contains("device change") == true)
        #expect(result.issue?.settingsURL == nil)
        #expect(storedFrames(result.recording, .system) >= 2 * 48_000)
        #expect(result.job != nil)
    }

    @Test(arguments: [false, true])
    func failedStartClaimsNothingAndKeepsOnlyRealAudio(partial: Bool) async throws {
        let f = try await RecorderFixture()
        defer { f.remove() }
        f.startError.value = AudioCaptureError(source: .microphone, operation: "Microphone access is denied",
                                               status: nil, recovery: .microphonePermission)
        if partial {
            // System audio arrived before the microphone failed.
            let host = f.host.value
            f.beforeFailure.value = { callbacks in
                for index in 0..<48 {
                    callbacks.receive(AudioPacket(source: .system, sampleRate: 48_000, hostTime: host + ticks(Double(index * 1_024) / 48_000),
                        sampleTime: 0, samples: [Float](repeating: 0.05, count: 1_024)))
                }
            }
        }
        await #expect(throws: AudioCaptureError.self) { try await f.recorder.start(meetingID: f.meeting.id) }
        #expect(await f.recorder.phase == .idle)
        #expect(f.log.value == ["playback.stop", "capture.start", "capture.stop"])
        let saved = try await f.store.recordings(meetingID: f.meeting.id)
        let folders = try await RecordingAudioWriter.storedRecordingIDs(library: f.library, meetingID: f.meeting.id)
        if partial {
            #expect(saved.count == 1 && saved[0].state == .interrupted && storedFrames(saved[0], .system) > 0)
            #expect(storedFrames(saved[0], .microphone) == 0 && folders == saved.map(\.id))
        } else {
            #expect(saved.isEmpty && folders.isEmpty)
        }
        f.startError.value = nil
        try await f.recorder.start(meetingID: f.meeting.id)
        #expect(await f.recorder.phase == .recording)
        _ = try await f.recorder.stop()
    }

    @Test func relaunchRecoversCrashedRecordingAdoptsOrphanAudioAndRemovesEmptyFolders() async throws {
        let f = try await RecorderFixture()
        defer { f.remove() }
        var crashed = try Recording(meetingID: f.meeting.id, startedAt: utc("2026-10-08T10:00:00Z"), timeZoneIdentifier: "UTC")
        crashed.state = .recording
        try await f.store.saveRecording(crashed)
        crashed.state = .preparing
        try await crashedWriter(f.library, crashed, seconds: 14)
        let orphan = try Recording(meetingID: f.meeting.id, startedAt: utc("2026-10-08T11:00:00Z"), timeZoneIdentifier: "UTC")
        try await crashedWriter(f.library, orphan, seconds: 12)
        let empty = try Recording(meetingID: f.meeting.id, startedAt: utc("2026-10-08T12:00:00Z"), timeZoneIdentifier: "UTC")
        try await crashedWriter(f.library, empty, seconds: 0)

        let recorder = f.makeRecorder()  // A relaunched application.
        let results = try await recorder.recoverAfterRelaunch()
        #expect(Set(results.map(\.recordingID)) == [crashed.id, orphan.id, empty.id])
        #expect(results.allSatisfy { $0.issue == nil })
        let saved = try await f.store.recordings(meetingID: f.meeting.id)
        #expect(saved.map(\.id) == [crashed.id, orphan.id])
        for recording in saved {
            #expect(recording.state == .interrupted)
            // Only the uncommitted (< 10 s) tail is lost.
            for track in AudioTrack.allCases { #expect(storedFrames(recording, track) == 10 * 48_000) }
        }
        #expect(saved[0].generation == 1 && saved[1].generation == 0)
        #expect(try await RecordingAudioWriter.storedRecordingIDs(library: f.library, meetingID: f.meeting.id).sorted { $0.uuidString < $1.uuidString }
                == [crashed.id, orphan.id].sorted { $0.uuidString < $1.uuidString })
        #expect(try await f.store.jobs(meetingID: f.meeting.id).compactMap(\.snapshot.recordingID) == [crashed.id, orphan.id])
        #expect(try await recorder.recoverAfterRelaunch().isEmpty)
    }
}
