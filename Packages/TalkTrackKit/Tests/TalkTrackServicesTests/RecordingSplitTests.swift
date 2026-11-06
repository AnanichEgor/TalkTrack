import AVFoundation
import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// One 25-second real AAC recording (both tracks, three 10-second chunks per
/// track) with a final transcript of two calls: Anna and the user in the first,
/// Boris and the user in the second. Optionally a summary and a translation.
private struct SplitFixture {
    let library: OpenedLibrary
    let store: SessionStore
    let meeting: Meeting
    let recording: Recording
    let revision: TranscriptRevision
    let start = Date(timeIntervalSince1970: 1_791_100_000)
    let translationModel = ModelSnapshot(role: .translation, repository: "test", revision: "1",
                                         directory: try! RelativePath("test/1"), preprocessingVersion: "1")
    var translationSettings: ProcessingSettings { ProcessingSettings(contextLimit: .tokens4K, templateVersion: IndexedTranslation.version) }

    static func signal(_ frame: Int, _ track: AudioTrack) -> Float {
        let t = Double(frame) / 48_000
        return Float(0.2 * sin(2 * .pi * ((track == .system ? 311.0 : 587.0) * t + 3 * t * t)))
    }

    static func make(_ root: URL, outputs: Bool = true) async throws -> Self {
        let library = try await OwnedLibrary().open(root: root)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Planning", description: "Two calls"))
        let start = Date(timeIntervalSince1970: 1_791_100_000), frames = 25 * 48_000
        let origin = AVAudioTime.hostTime(forSeconds: 100)
        let empty = try Recording(meetingID: meeting.id, startedAt: start, timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: empty)
        var clock = CaptureIntervalClock()
        try clock.begin(hostTime: origin, wallClock: start, timeZoneIdentifier: "UTC")
        try await writer.updateCaptureTiming(try clock.close(at: origin + AVAudioTime.hostTime(forSeconds: 25)), state: .recording)
        for track in AudioTrack.allCases {
            var offset = 0
            while offset < frames {
                let count = min(4_096, frames - offset)
                try await writer.append(track: track, samples: (offset..<(offset + count)).map { signal($0, track) },
                                        activeStartFrame: UInt64(offset),
                                        hostTimeStart: origin + AVAudioTime.hostTime(forSeconds: Double(offset) / 48_000))
                offset += count
            }
        }
        let recording = try await writer.finish().recording
        try await store.saveRecording(recording)

        let day = recording.days[0].id
        let anna = DaySpeaker(meetingID: meeting.id, dayID: day, number: 1), boris = DaySpeaker(meetingID: meeting.id, dayID: day, number: 2)
        for speaker in [anna, boris] {
            try await store.put(.daySpeaker, id: speaker.id, meetingID: meeting.id, scope: day.uuidString, value: speaker)
        }
        func segment(_ track: AudioTrack, _ from: Double, _ to: Double, _ speaker: DaySpeaker?, _ text: String) throws -> TranscriptSegment {
            TranscriptSegment(recordingID: recording.id, dayID: day, track: track,
                interval: try MediaInterval(start: MediaTime(seconds: from), end: MediaTime(seconds: to)),
                wallClockStart: start.addingTimeInterval(from), speaker: speaker.map { .system(daySpeakerID: $0.id) } ?? .microphone,
                originalText: text)
        }
        let revision = TranscriptRevision(recordingID: recording.id, sourceGeneration: recording.generation, kind: .final, segments: [
            try segment(.system, 1, 4, anna, "First call opens."),
            try segment(.microphone, 5, 7, nil, "Reply one."),
            try segment(.system, 14, 17, boris, "Second call opens."),
            try segment(.microphone, 18, 20, nil, "Reply two."),
        ], modelRevisions: [])
        let job = try await store.enqueue(kind: .finalTranscription, meetingID: meeting.id, recordingID: recording.id,
                                          settings: ProcessingSettings(), models: [])
        try await store.publishTranscript(revision, jobID: job.id)
        for (index, name) in ["Anna", "Boris"].enumerated() {
            let target = try await store.speakerRenameTarget(meetingID: meeting.id, recordingID: recording.id,
                                                             segmentID: revision.segments[index * 2].id)
            _ = try await store.renameSpeaker(target, name: name)
        }
        let fixture = Self(library: library, store: store, meeting: meeting, recording: try await store.recordings(meetingID: meeting.id)[0],
                           revision: revision)
        if outputs {
            let summaryModel = try ModelCatalog.bundled().model(for: .summary).snapshot(for: .summary)
            let summary = try await store.enqueueSummary(meetingID: meeting.id, recordingID: recording.id,
                                                         settings: ProcessingSettings(contextLimit: .tokens4K), model: summaryModel)
            try await SummaryJobPipeline(store: store, inference: SummaryJobInference()).run(jobID: summary.id)
            let translation = try await store.enqueueTranslation(meetingID: meeting.id, settings: fixture.translationSettings,
                                                                 model: fixture.translationModel)
            try await TranslationJobPipeline(store: store, inference: TranslationTestInference()).run(jobID: translation.id)
        }
        return fixture
    }

    /// Every sample of both tracks of `recordings`, as playback reads them.
    func audio(_ recordings: [Recording], store: SessionStore? = nil) throws -> (system: [Float], microphone: [Float]) {
        var system: [Float] = [], microphone: [Float] = []
        let chunks = CommittedAudioChunks(library: library)
        let owned = try chunks.ownedDirectory()
        for recording in recordings {
            for chunk in recording.chunks { try chunks.verify(chunk, of: recording, owned: owned) }
            for track in AudioTrack.allCases {
                var samples: [Float] = []
                for chunk in recording.chunks.filter({ $0.track == track }).sorted(by: { $0.active.start < $1.active.start }) {
                    try chunks.decode(chunk, of: recording, selected: chunk.leadingTrimFrames..<(chunk.decodedFrameCount - chunk.trailingTrimFrames),
                                      owned: owned, checkCancellation: {}, into: &samples)
                }
                if track == .system { system += samples } else { microphone += samples }
            }
        }
        return (system, microphone)
    }

    func lines(_ store: SessionStore? = nil, meetingID: UUID? = nil) async throws -> [String] {
        try await (store ?? self.store).meetingTranscript(meetingID: meetingID ?? meeting.id).items.map { item in
            switch item {
            case .speech(let block): "[\(block.timestamp)]: \(block.speakerLabel) - \(block.segments.map(\.originalText).joined(separator: " "))"
            default: "\(item)".contains("separator") || "\(item)".contains("Separator") ? "separator" : "other"
            }
        }
    }

    func path(_ components: String...) -> String {
        library.directory.appendingPathComponent((["Meetings", meeting.id.uuidString] + components).joined(separator: "/")).path
    }
}

@Suite(.serialized) struct RecordingSplitTests {
    @Test func theAudioIsCutExactlyAndBothPartsVerifyAndPlay() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SplitFixture.make(folder.url, outputs: false)
        let whole = try f.audio([f.recording])
        #expect(whole.system.count == 1_200_000)

        // 12.3 s is inside the second chunk of each track.
        let result = try await f.store.splitRecording(f.recording.id, meetingID: f.meeting.id, at: MediaTime(seconds: 12.3))

        #expect(try result.first.id == f.recording.id && result.first.activeDuration == (try MediaTime(seconds: 12.3)))
        #expect(result.second.activeDuration == (try MediaTime(seconds: 12.7)))
        #expect(result.second.startedAt == f.start.addingTimeInterval(12.3))
        #expect(result.first.chunks.count == 4 && result.second.chunks.count == 4)
        #expect(!result.needsTranscription)
        let parts = try await f.store.recordings(meetingID: f.meeting.id)
        #expect(parts.map(\.id) == [result.first.id, result.second.id])
        let first = try f.audio([parts[0]]), second = try f.audio([parts[1]])
        #expect(first.system == Array(whole.system[..<590_400]) && first.microphone == Array(whole.microphone[..<590_400]))
        #expect(second.system == Array(whole.system[590_400...]) && second.microphone == Array(whole.microphone[590_400...]))
        // Playback reads both parts as one timeline of the same length.
        let source = try MeetingAudioSource(library: f.library, meetingID: f.meeting.id, recordings: parts)
        #expect(source.totalFrames == 1_200_000)
        #expect(try try await source.damagedAudio().isEmpty)
        // Files: the part has its own folder; the original keeps only its chunks.
        let manager = FileManager.default
        #expect(!manager.fileExists(atPath: f.path("Recordings", ".split-\(result.second.id)")))
        #expect(try manager.contentsOfDirectory(atPath: f.path("Recordings", f.recording.id.uuidString, "system")).filter { $0.hasSuffix(".m4a") }.count == 2)
        #expect(try manager.contentsOfDirectory(atPath: f.path("Recordings", result.second.id.uuidString, "system")).filter { $0.hasSuffix(".m4a") }.count == 2)

        // A relaunch reads the same audio.
        try await f.store.close()
        let reopened = try await SessionStore.open(f.library)
        let again = try await reopened.recordings(meetingID: f.meeting.id)
        #expect(try f.audio(again).system == whole.system)
    }

    @Test func theTextNamesAndOutputsAreDividedByTime() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SplitFixture.make(folder.url)
        let settings = ProcessingSettings(contextLimit: .tokens4K)
        let translatedBefore = try await f.store.translatedItems(try #require(try await f.store.output(.translation, meetingID: f.meeting.id))).map(\.text)

        let result = try await f.store.splitRecording(f.recording.id, meetingID: f.meeting.id, at: MediaTime(seconds: 12))

        let snapshot = try await f.store.meetingTranscript(meetingID: f.meeting.id)
        let blocks = snapshot.items.compactMap { item -> TranscriptBlock? in if case .speech(let block) = item { block } else { nil } }
        #expect(blocks.map(\.speakerLabel) == ["Anna", "You", "Boris", "You"])
        #expect(blocks.map(\.recordingID) == [result.first.id, result.first.id, result.second.id, result.second.id])
        #expect(blocks.map(\.timestamp) == blocks.map(\.timestamp))
        // Each part starts with its own separator; the second at its start time.
        #expect(snapshot.items.count == blocks.count + 2)
        let second = try #require(try await f.store.transcript(meetingID: f.meeting.id, recordingID: result.second.id))
        #expect(second.segments.map(\.interval.start) == [try MediaTime(seconds: 2), try MediaTime(seconds: 6)])
        #expect(second.kind == .final && second.sourceGeneration == result.second.generation)
        // The new part counts as transcribed, like the original.
        let jobs = try await f.store.jobs(meetingID: f.meeting.id)
        #expect(jobs.contains { $0.snapshot.recordingID == result.second.id && $0.snapshot.kind == .finalTranscription && $0.stage == .completed })
        // Names stay given: renaming Boris in the new part changes the shared day voice.
        let target = try await f.store.speakerRenameTarget(meetingID: f.meeting.id, recordingID: result.second.id, segmentID: second.segments[0].id)
        #expect(target.name == "Boris")
        // The summary stays with the first part and is Outdated; the translation stays current.
        let summary = try #require(try await f.store.summary(meetingID: f.meeting.id, recordingID: f.recording.id))
        #expect(try await f.store.isOutdated(summary, settings: settings))
        let translation = try #require(try await f.store.output(.translation, meetingID: f.meeting.id))
        #expect(try await !f.store.isOutdated(translation, settings: f.translationSettings))
        #expect(try await f.store.translatedItems(translation).map(\.text).filter { !$0.hasPrefix("---") }
                == translatedBefore.filter { !$0.hasPrefix("---") })
        // Name evidence follows the speech.
        let boris = try await f.store.speakerAssignments(meetingID: f.meeting.id).first { $0.name == "Boris" }
        #expect(boris?.evidence.map(\.recordingID) == [result.second.id])
        #expect(boris?.evidence.first?.interval.start == (try MediaTime(seconds: 2)))
        // Saved-voice samples of the original find their part.
        let (id, interval) = await f.store.resolveRecordingTime(f.recording.id, try MediaInterval(start: MediaTime(seconds: 15), end: MediaTime(seconds: 16)))
        #expect(try id == result.second.id && interval.start == (try MediaTime(seconds: 3)))
        let (same, kept) = await f.store.resolveRecordingTime(f.recording.id, try MediaInterval(start: MediaTime(seconds: 1), end: MediaTime(seconds: 2)))
        #expect(try same == f.recording.id && kept.start == (try MediaTime(seconds: 1)))
    }

    @Test func theSecondPartMovesAndStillPlays() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SplitFixture.make(folder.url, outputs: false)
        let result = try await f.store.splitRecording(f.recording.id, meetingID: f.meeting.id, at: MediaTime(seconds: 12.3))
        let target = try await f.store.createMeeting(MeetingDraft(title: "Second call", description: ""))

        try await f.store.moveRecording(result.second.id, from: f.meeting.id, to: target.id)

        let moved = try await f.store.recordings(meetingID: target.id)
        #expect(moved.map(\.id) == [result.second.id])
        #expect(try f.audio(moved).system.count == 609_600)
        #expect(try await f.lines(meetingID: target.id).filter { $0 != "separator" && $0 != "other" }.map { $0.components(separatedBy: "]: ").last! }
                == ["Boris - Second call opens.", "You - Reply two."])
    }

    @Test func aMovedRecordingVerifiesInItsNewMeeting() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SplitFixture.make(folder.url, outputs: false)
        let target = try await f.store.createMeeting(MeetingDraft(title: "Elsewhere", description: ""))
        try await f.store.moveRecording(f.recording.id, from: f.meeting.id, to: target.id)
        #expect(try f.audio(try await f.store.recordings(meetingID: target.id)).system.count == 1_200_000)

        // A folder moved before receipts were rewritten is repaired at launch.
        let receipts = f.library.directory.appendingPathComponent("Meetings/\(target.id)/Recordings/\(f.recording.id)/system")
        for name in try FileManager.default.contentsOfDirectory(atPath: receipts.path) where name.hasSuffix(".json") {
            let url = receipts.appendingPathComponent(name)
            let text = try String(contentsOf: url, encoding: .utf8)
            try Data(text.replacingOccurrences(of: target.id.uuidString, with: f.meeting.id.uuidString).utf8).write(to: url)
        }
        let stale = try await f.store.recordings(meetingID: target.id)
        #expect(throws: (any Error).self) { try f.audio(stale) }
        try await f.store.close()
        let reopened = try await SessionStore.open(f.library)
        #expect(try f.audio(try await reopened.recordings(meetingID: target.id)).system.count == 1_200_000)
    }

    @Test func anInterruptedFinishIsCompletedAtTheNextLaunch() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SplitFixture.make(folder.url, outputs: false)
        let whole = try f.audio([f.recording])
        let result = try await f.store.splitRecording(f.recording.id, meetingID: f.meeting.id, at: MediaTime(seconds: 12.3))
        // As if the app stopped right after the commit: the part is still staged.
        let manager = FileManager.default
        try manager.moveItem(atPath: f.path("Recordings", result.second.id.uuidString), toPath: f.path("Recordings", ".split-\(result.second.id)"))
        var record: RecordingSplitRecord = try #require(try await f.store.record(.recordingSplit, id: result.second.id))
        record.finished = false
        try await f.store.put(.recordingSplit, id: result.second.id, meetingID: f.meeting.id, scope: "split", value: record)
        // And a staging folder of a split that never committed.
        try manager.createDirectory(atPath: f.path("Recordings", ".split-\(UUID())", "system"), withIntermediateDirectories: true)
        try await f.store.close()

        let reopened = try await SessionStore.open(f.library)

        let restored = try f.audio(try await reopened.recordings(meetingID: f.meeting.id)).system
        #expect(restored.count == whole.system.count)
        #expect(restored == whole.system)
        #expect(try manager.contentsOfDirectory(atPath: f.path("Recordings")).filter { $0.hasPrefix(".split-") }.isEmpty)
        let done: RecordingSplitRecord = try #require(try await reopened.record(.recordingSplit, id: result.second.id))
        #expect(done.finished)
    }

    @Test func refusalsLeaveTheRecordingUnchanged() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SplitFixture.make(folder.url, outputs: false)
        await #expect(throws: RecordingSplitError.tooShort) {
            try await f.store.splitRecording(f.recording.id, meetingID: f.meeting.id, at: MediaTime(seconds: 0.5))
        }
        await #expect(throws: RecordingSplitError.tooShort) {
            try await f.store.splitRecording(f.recording.id, meetingID: f.meeting.id, at: MediaTime(seconds: 24.5))
        }
        let job = try await f.store.enqueue(kind: .finalTranscription, meetingID: f.meeting.id, recordingID: f.recording.id,
                                            settings: ProcessingSettings(), models: [])
        await #expect(throws: RecordingSplitError.busy) {
            try await f.store.splitRecording(f.recording.id, meetingID: f.meeting.id, at: MediaTime(seconds: 12))
        }
        #expect(try !FileManager.default.fileExists(atPath: f.path("Recordings")) ||
                (try FileManager.default.contentsOfDirectory(atPath: f.path("Recordings")).filter { $0.hasPrefix(".split-") }.isEmpty))
        try await f.store.updateJob(job.id, stage: .cancelled, error: nil)
        var open = try Recording(meetingID: f.meeting.id, startedAt: f.start.addingTimeInterval(3_600), timeZoneIdentifier: "UTC")
        open.state = .recording
        try await f.store.saveRecording(open)
        await #expect(throws: RecordingSplitError.capturing) {
            try await f.store.splitRecording(open.id, meetingID: f.meeting.id, at: MediaTime(seconds: 12))
        }
        #expect(try await f.store.recordings(meetingID: f.meeting.id).first == f.recording)
    }

    @Test func aPartWithoutAFinalTranscriptNeedsTranscription() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SplitFixture.make(folder.url, outputs: false)
        // A newer generation makes the transcript stale, as if audio changed.
        var newer = f.recording; newer.generation += 1
        try await f.store.saveRecording(newer)
        let result = try await f.store.splitRecording(f.recording.id, meetingID: f.meeting.id, at: MediaTime(seconds: 12))
        #expect(result.needsTranscription)
    }
}
