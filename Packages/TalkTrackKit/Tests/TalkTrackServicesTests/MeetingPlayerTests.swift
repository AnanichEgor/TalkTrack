import AVFoundation
import Darwin
import Foundation
import Testing
import TalkTrackAudio
import TalkTrackDomain
@testable import TalkTrackServices

private func playbackSignal(_ frame: Int, track: AudioTrack, recording: Int) -> Float {
    let t = Double(frame) / 48_000, base = (track == .system ? 311.0 : 587.0) + Double(recording) * 97
    return Float(0.2 * sin(2 * .pi * (base * t + 5 * t * t)))
}

/// A meeting of real AAC recordings written by the recording writer, each on
/// its own day, with the given tracks captured.
private func playbackMeeting(_ folder: TemporaryFolder, recordings: [(frames: Int, tracks: [AudioTrack])])
    async throws -> (OpenedLibrary, UUID, [Recording]) {
    let library = try await OwnedLibrary().open(root: folder.url)
    let meetingID = UUID()
    var result: [Recording] = []
    for (index, item) in recordings.enumerated() {
        let date = Date(timeIntervalSince1970: 1_791_000_000 + Double(index) * 3 * 86_400)
        let origin = AVAudioTime.hostTime(forSeconds: 100 + Double(index) * 1_000)
        let recording = try Recording(meetingID: meetingID, startedAt: date, timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
        var clock = CaptureIntervalClock()
        try clock.begin(hostTime: origin, wallClock: date, timeZoneIdentifier: "UTC")
        let timing = try clock.close(at: origin + AVAudioTime.hostTime(forSeconds: Double(item.frames) / 48_000))
        try await writer.updateCaptureTiming(timing, state: .recording)
        for track in item.tracks {
            var offset = 0
            while offset < item.frames {
                let count = min(1_531, item.frames - offset)
                try await writer.append(track: track, samples: (offset..<(offset + count)).map { playbackSignal($0, track: track, recording: index) },
                                        activeStartFrame: UInt64(offset),
                                        hostTimeStart: origin + AVAudioTime.hostTime(forSeconds: Double(offset) / 48_000))
                offset += count
            }
        }
        result.append(try await writer.finish().recording)
    }
    return (library, meetingID, result)
}

private func rms(_ samples: ArraySlice<Float>, _ expected: (Int) -> Float) -> Double {
    var sum = 0.0
    for (i, sample) in samples.enumerated() {
        let delta = Double(sample) - Double(expected(i))
        sum += delta * delta
    }
    return sqrt(sum / Double(max(1, samples.count)))
}

private func expectedMix(_ library: OpenedLibrary, _ meetingID: UUID, _ recordings: [Recording],
                         tracks: PlaybackTracks = .system) async throws -> [Float] {
    let source = try MeetingAudioSource(library: library, meetingID: meetingID, recordings: recordings)
    var mix: [Float] = []
    while let block = try await source.next(maximumFrames: 30_000) {
        switch tracks {
        case .system: mix += block.system
        case .microphone: mix += block.microphone
        case .both, .auto: mix.append(contentsOf: zip(block.system, block.microphone).map { max(-1, min(1, $0 + $1)) })
        }
    }
    return mix
}

@MainActor
private func startedPlayer(_ library: OpenedLibrary, _ meetingID: UUID, _ recordings: [Recording],
                           at time: MediaTime = .zero, speed: PlaybackSpeed = .normal,
                           tracks: PlaybackTracks = .system) async throws -> MeetingPlayer {
    let player = MeetingPlayer(library: library, output: .offline)
    player.load(meetingID: meetingID, recordings: recordings)
    player.speed = speed
    player.tracks = tracks
    player.seek(to: time)
    player.play()
    await player.waitUntilStarted()
    #expect(player.state == .playing)
    return player
}

@Suite struct MeetingPlayerTests {
    @Test func sourceReadsBothTracksAcrossChunksRecordingsAndGapsWithoutJoiningFiles() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        // 12.5 s spans two AAC chunks; the second recording has no microphone.
        let (library, meetingID, recordings) = try await playbackMeeting(folder, recordings: [
            (600_000, AudioTrack.allCases), (144_000, [.system]),
        ])
        #expect(recordings[0].chunks.filter { $0.track == .system }.count == 2)
        let source = try MeetingAudioSource(library: library, meetingID: meetingID, recordings: recordings)
        #expect(source.totalFrames == 744_000)
        #expect(source.timeline.totalDuration == (try MediaTime(seconds: 15.5)))

        var system: [Float] = [], microphone: [Float] = [], owners: [(UUID, Range<UInt64>)] = []
        while let block = try await source.next(maximumFrames: 47_000) {
            #expect(block.globalStartFrame == UInt64(system.count))
            owners.append((block.recordingID, block.globalStartFrame..<(block.globalStartFrame + UInt64(block.frameCount))))
            system += block.system; microphone += block.microphone
        }
        #expect(system.count == 744_000 && microphone.count == 744_000)
        // No block crosses the recording boundary.
        for (id, range) in owners {
            #expect(id == (range.lowerBound < 600_000 ? recordings[0].id : recordings[1].id))
            #expect(range.lowerBound >= 600_000 || range.upperBound <= 600_000)
        }
        // Lossy codec, so compare the analytic signal away from the outer edges,
        // across the internal chunk boundary at 480,000.
        #expect(rms(system[256..<599_744], { playbackSignal($0 + 256, track: .system, recording: 0) }) < 0.025)
        #expect(rms(microphone[256..<599_744], { playbackSignal($0 + 256, track: .microphone, recording: 0) }) < 0.025)
        #expect(rms(system[478_000..<482_000], { playbackSignal($0 + 478_000, track: .system, recording: 0) }) < 0.025)
        #expect(rms(system[600_256..<743_744], { playbackSignal($0 + 256, track: .system, recording: 1) }) < 0.025)
        // The missing microphone track is explicit silence of the same length.
        #expect(microphone[600_000...].allSatisfy { $0 == 0 })

        // 600-to-605 style seeks: an exact boundary selects the next recording.
        #expect(try source.frame(at: MediaTime(seconds: 12.5)) == 600_000)
        #expect(source.recordingID(atFrame: 600_000) == recordings[1].id)
        #expect(try source.frame(at: MediaTime(seconds: 13.5)) == 648_000)
        #expect(source.time(atFrame: 648_000) == (try MediaTime(seconds: 13.5)))
        #expect(try source.frame(at: MediaTime(seconds: 15.5)) == 744_000)
        await source.seek(toFrame: 648_000)
        let block = try #require(try await source.next(maximumFrames: 1_000))
        #expect(block.recordingID == recordings[1].id)
        #expect(block.system == Array(system[648_000..<649_000]))
    }

    @MainActor @Test func normalSpeedPlaysTheExactMixContinuouslyAndEnds() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (library, meetingID, recordings) = try await playbackMeeting(folder, recordings: [
            (600_000, AudioTrack.allCases), (144_000, [.system]),
        ])
        let expected = try await expectedMix(library, meetingID, recordings)
        let player = try await startedPlayer(library, meetingID, recordings)
        let output = try await player.renderOffline(frames: 800_000)
        #expect(player.state == .ended)
        #expect(player.position == player.duration)
        // Every source frame is played once, in order, across chunk and
        // recording boundaries; no frame is duplicated, dropped or reordered.
        #expect(output.count >= expected.count)
        var worst: Float = 0
        for i in 0..<expected.count { worst = max(worst, abs(output[i] - expected[i])) }
        #expect(worst < 1e-5)
        #expect(output[expected.count...].allSatisfy { abs($0) < 1e-6 })
    }

    @MainActor @Test func eachTrackChoicePlaysExactlyItsTracksAndAChangeWhilePlayingKeepsThePosition() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (library, meetingID, recordings) = try await playbackMeeting(folder, recordings: [(144_000, AudioTrack.allCases)])
        #expect(MeetingPlayer(library: library, output: .offline).tracks == .auto)
        for tracks in PlaybackTracks.allCases where tracks != .auto {
            let expected = try await expectedMix(library, meetingID, recordings, tracks: tracks)
            let player = try await startedPlayer(library, meetingID, recordings, tracks: tracks)
            let output = try await player.renderOffline(frames: 48_000)
            var worst: Float = 0
            for i in 0..<48_000 { worst = max(worst, abs(output[i] - expected[i])) }
            #expect(worst < 1e-5, "\(tracks)")
        }
        // Switching while playing drops the scheduled audio and continues from the same position.
        let player = try await startedPlayer(library, meetingID, recordings)
        _ = try await player.renderOffline(frames: 48_000)
        player.tracks = .microphone
        #expect(player.position == (try MediaTime(seconds: 1)))
        await player.waitUntilStarted()
        #expect(player.state == .playing)
        let output = try await player.renderOffline(frames: 24_000)
        let microphone = try await expectedMix(library, meetingID, recordings, tracks: .microphone)
        var worst: Float = 0
        for i in 0..<24_000 { worst = max(worst, abs(output[i] - microphone[48_000 + i])) }
        #expect(worst < 1e-5)
    }

    @MainActor @Test func autoMicrophoneGainCoversOwnRepliesWithPaddingAndFades() {
        let pad = Int(MeetingPlayer.ownSpeechPadding), fade = Int(MeetingPlayer.ownSpeechFade)
        let gain = MeetingPlayer.microphoneGain(start: 0, count: 96_000, speech: [48_000..<52_000])
        #expect(gain[0..<(48_000 - pad - fade)].allSatisfy { $0 == 0 })
        #expect(gain[(48_000 - pad)..<(52_000 + pad)].allSatisfy { $0 == 1 })
        #expect(gain[(52_000 + pad + fade)...].allSatisfy { $0 == 0 })
        let rising = gain[(48_000 - pad - fade)..<(48_000 - pad)]
        #expect(zip(rising, rising.dropFirst()).allSatisfy { $0 < $1 })
        // A reply in the previous block still fades into this one.
        let next = MeetingPlayer.microphoneGain(start: 52_000 + UInt64(pad), count: 2_000, speech: [48_000..<52_000])
        #expect(next[0] > 0.99 && next[fade] == 0)
    }

    @MainActor @Test func autoPlaysTheMicrophoneOnlyDuringOwnReplies() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (library, meetingID, recordings) = try await playbackMeeting(folder, recordings: [(144_000, AudioTrack.allCases)])
        let system = try await expectedMix(library, meetingID, recordings, tracks: .system)
        let both = try await expectedMix(library, meetingID, recordings, tracks: .both)
        let player = MeetingPlayer(library: library, output: .offline)
        player.load(meetingID: meetingID, recordings: recordings)
        player.setOwnSpeech(meetingID: meetingID, intervals: [recordings[0].id: [
            try MediaInterval(start: MediaTime(seconds: 1), end: MediaTime(seconds: 1.5))]])
        player.tracks = .auto
        player.play()
        await player.waitUntilStarted()
        let output = try await player.renderOffline(frames: 144_000)
        func worst(_ range: Range<Int>, _ expected: [Float]) -> Float { range.map { abs(output[$0] - expected[$0]) }.max() ?? 0 }
        let pad = Int(MeetingPlayer.ownSpeechPadding), fade = Int(MeetingPlayer.ownSpeechFade)
        #expect(worst(0..<(48_000 - pad - fade), system) < 1e-5)
        #expect(worst((48_000 - pad)..<(72_000 + pad), both) < 1e-5)
        #expect(worst((72_000 + pad + fade)..<144_000, system) < 1e-5)
        // Another meeting's replies never apply.
        player.setOwnSpeech(meetingID: UUID(), intervals: [recordings[0].id: [try MediaInterval(start: .zero, end: MediaTime(seconds: 3))]])
        #expect(player.ownSpeechRanges().isEmpty)
    }

    @MainActor @Test func speedChangesKeepSourceTimeAndCarryAcrossRecordingBoundaries() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (library, meetingID, recordings) = try await playbackMeeting(folder, recordings: [
            (480_000, AudioTrack.allCases), (480_000, AudioTrack.allCases),
        ])
        // Start 2 s before the boundary at 2×: 3 s of output covers 6 s of source.
        let player = try await startedPlayer(library, meetingID, recordings, at: MediaTime(seconds: 8), speed: .double)
        #expect(player.currentRecordingID == recordings[0].id)
        let output = try await player.renderOffline(frames: 144_000)
        #expect(player.state == .playing)
        #expect(player.speed == .double)
        #expect(player.currentRecordingID == recordings[1].id)
        #expect(abs(player.position.seconds - 14) < 0.15)
        // Audio continues through the boundary at 2× (no silent reset).
        for second in 0..<3 {
            let slice = output[(second * 48_000 + 4_000)..<((second + 1) * 48_000 - 4_000)]
            #expect(sqrt(slice.map { Double($0 * $0) }.reduce(0, +) / Double(slice.count)) > 0.1)
        }
        // A new speed applies immediately and keeps the source position.
        player.speed = .triple
        let before = player.position
        _ = try await player.renderOffline(frames: 48_000)
        #expect(abs(player.position.seconds - before.seconds - 3) < 0.15)

        player.pause()
        #expect(player.state == .paused)
        let paused = player.position
        player.speed = .oneAndHalf
        player.play()
        await player.waitUntilStarted()
        _ = try await player.renderOffline(frames: 48_000)
        #expect(abs(player.position.seconds - paused.seconds - 1.5) < 0.15)
        #expect(player.speed == .oneAndHalf)
    }

    @MainActor @Test func seekingCaptureExclusionAndReloadKeepControlStateCorrect() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (library, meetingID, recordings) = try await playbackMeeting(folder, recordings: [
            (480_000, AudioTrack.allCases), (240_000, AudioTrack.allCases),
        ])
        let player = MeetingPlayer(library: library, output: .offline)
        #expect(player.state == .unavailable && !player.canPlay)
        player.load(meetingID: meetingID, recordings: [])
        #expect(player.state == .unavailable && !player.canPlay)
        player.load(meetingID: meetingID, recordings: recordings)
        #expect(player.state == .paused)
        #expect(player.duration == (try MediaTime(seconds: 15)))

        // An exact boundary seek starts the second recording.
        player.seek(to: try MediaTime(seconds: 10))
        #expect(player.currentRecordingID == recordings[1].id)
        player.play()
        await player.waitUntilStarted()
        _ = try await player.renderOffline(frames: 24_000)
        #expect(abs(player.position.seconds - 10.5) < 0.05)
        // Seeking backwards while playing continues from the new position.
        player.seek(to: try MediaTime(seconds: 2))
        await player.waitUntilStarted()
        #expect(player.state == .playing && player.currentRecordingID == recordings[0].id)
        _ = try await player.renderOffline(frames: 24_000)
        #expect(abs(player.position.seconds - 2.5) < 0.05)

        // Capture stops playback first and keeps Play disabled until it ends.
        await player.stopPlaybackBeforeCapture()
        #expect(player.state == .paused)
        player.captureActive = true
        player.play()
        #expect(player.state == .paused && !player.canPlay)
        player.captureActive = false
        #expect(player.canPlay)

        // Appending a recording keeps the position; another meeting resets it.
        let kept = player.position
        player.load(meetingID: meetingID, recordings: recordings)
        #expect(player.position == kept)
        player.load(meetingID: UUID(), recordings: [])
        #expect(player.state == .unavailable && player.position == .zero)

        // Seeking to the total end is the ended state; Play restarts from zero.
        player.load(meetingID: meetingID, recordings: recordings)
        player.seek(to: player.duration)
        #expect(player.state == .ended)
        player.play()
        await player.waitUntilStarted()
        #expect(player.state == .playing && player.currentRecordingID == recordings[0].id)
        _ = try await player.renderOffline(frames: 4_800)
        #expect(player.position.seconds < 0.2)
    }

    @MainActor @Test func transcriptTimestampsSeekAcrossDaysAndFollowThePlayhead() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (library, meetingID, recordings) = try await playbackMeeting(folder, recordings: [
            (480_000, AudioTrack.allCases), (240_000, AudioTrack.allCases),
        ])
        func segment(_ recording: Recording, _ start: Double, _ end: Double, _ text: String) throws -> TranscriptSegment {
            TranscriptSegment(recordingID: recording.id, dayID: recording.days[0].id, track: .microphone,
                interval: try MediaInterval(start: MediaTime(seconds: start), end: MediaTime(seconds: end)),
                wallClockStart: recording.startedAt.addingTimeInterval(start), speaker: .microphone, originalText: text)
        }
        let items = try TranscriptFormatter.format(meetingID: meetingID, recordings: recordings, segments: [
            try segment(recordings[0], 1, 4, "First day."), try segment(recordings[1], 2, 4, "Third day."),
        ], speakers: [])
        let ids = items.compactMap { if case .speech = $0 { $0.id } else { nil } }
        #expect(ids.count == 2)
        let expected = try await expectedMix(library, meetingID, recordings)
        let player = MeetingPlayer(library: library, output: .offline)
        player.load(meetingID: meetingID, recordings: recordings)
        let index = TranscriptPlaybackIndex(timeline: try #require(player.timeline), items: items)

        // Forwards to another day, then backwards, each from a timestamp.
        for (id, seconds, recording) in [(ids[1], 12.0, recordings[1].id), (ids[0], 1.0, recordings[0].id)] {
            let start = try #require(index.start(of: id))
            #expect(start == (try MediaTime(seconds: seconds)))
            #expect(player.play(from: start, meetingID: meetingID))
            await player.waitUntilStarted()
            #expect(player.state == .playing && player.currentRecordingID == recording)
            let output = try await player.renderOffline(frames: 24_000)
            // Both tracks are heard from exactly that speech.
            let first = Int(seconds * 48_000)
            var worst: Float = 0
            for i in 0..<24_000 { worst = max(worst, abs(output[i] - expected[first + i])) }
            #expect(worst < 1e-5)
            #expect(index.activeItem(at: player.position) == id)
        }

        // Starting capture or showing another meeting refuses old timestamps.
        player.captureActive = true
        #expect(!player.play(from: .zero, meetingID: meetingID))
        #expect(player.state == .paused)
        player.captureActive = false
        player.load(meetingID: UUID(), recordings: [])
        #expect(player.timeline == nil)
        #expect(!player.play(from: .zero, meetingID: meetingID))
        #expect(player.state == .unavailable)
    }

    @MainActor @Test func unreadableFileStopsAtItsPositionAndNamesTheRecording() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (library, meetingID, recordings) = try await playbackMeeting(folder, recordings: [
            (96_000, AudioTrack.allCases), (96_000, AudioTrack.allCases),
        ])
        let chunk = recordings[1].chunks.first { $0.track == .microphone }!
        try FileManager.default.removeItem(at: library.directory.appendingPathComponent(chunk.file.value))
        let player = try await startedPlayer(library, meetingID, recordings)
        _ = try await player.renderOffline(frames: 192_000)
        guard case let .failed(message, recovery, recordingID) = player.state else {
            Issue.record("Expected a failure, got \(player.state)"); return
        }
        #expect(recordingID == recordings[1].id)
        #expect(message.contains("microphone"))
        #expect(recovery?.contains("transcript") == true)
        // The timeline is not shortened: the duration stays, and the position
        // is the start of the unreadable recording.
        #expect(player.duration == (try MediaTime(seconds: 4)))
        #expect(player.position == (try MediaTime(seconds: 2)))
        // The readable recording still plays after a seek.
        player.seek(to: .zero)
        #expect(player.state == .paused)
        player.play()
        await player.waitUntilStarted()
        _ = try await player.renderOffline(frames: 24_000)
        #expect(player.state == .playing)
    }

    @MainActor @Test func unrecordedMeetingsExplainWhyPlaybackIsUnavailable() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (library, meetingID, recordings) = try await playbackMeeting(folder, recordings: [(96_000, AudioTrack.allCases)])
        let player = MeetingPlayer(library: library, output: .offline)
        #expect(player.unavailability == .noMeeting)
        player.load(meetingID: meetingID, recordings: [])
        #expect(player.state == .unavailable && player.unavailability == .noRecordings && !player.canPlay)

        // The first recording is still being captured: nothing to play until Stop.
        var capturing = try Recording(meetingID: meetingID, startedAt: Date(), timeZoneIdentifier: "UTC")
        capturing.state = .recording
        player.load(meetingID: meetingID, recordings: [capturing])
        #expect(player.state == .unavailable && player.unavailability == .recordingInProgress)

        // A recording interrupted before any audio was captured.
        var empty = try Recording(meetingID: meetingID, startedAt: Date(), timeZoneIdentifier: "UTC")
        empty.state = .interrupted
        player.load(meetingID: meetingID, recordings: [empty])
        #expect(player.state == .unavailable && player.unavailability == .noRecordedAudio && player.duration == .zero)

        player.load(meetingID: meetingID, recordings: recordings + [capturing])
        #expect(player.state == .paused && player.unavailability == nil && player.canPlay)
        await player.waitForAudioCheck()
        #expect(player.damagedAudio.isEmpty && !player.checkingAudio)
        player.load(meetingID: nil, recordings: [])
        #expect(player.unavailability == .noMeeting)
    }

    @MainActor @Test func damagedFilesAreReportedWithoutShorteningAndRecoveryIsExplicit() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        // 2 s, then 12.5 s in two chunks (0-10 s and 10-12.5 s), then 2 s.
        let (library, meetingID, recordings) = try await playbackMeeting(folder, recordings: [
            (96_000, AudioTrack.allCases), (600_000, AudioTrack.allCases), (96_000, AudioTrack.allCases),
        ])
        func url(_ recording: Recording, _ track: AudioTrack, _ index: Int = 0) -> URL {
            let chunks = recording.chunks.filter { $0.track == track }.sorted { $0.active.start < $1.active.start }
            return library.directory.appendingPathComponent(chunks[index].file.value)
        }
        // Damaged bytes in the first system chunk of the second recording, and
        // a removed microphone file in the third.
        let damagedURL = url(recordings[1], .system), missingURL = url(recordings[2], .microphone)
        let original = try Data(contentsOf: damagedURL), removed = try Data(contentsOf: missingURL)
        var changed = original
        changed[changed.count / 2] ^= 0xFF
        try changed.write(to: damagedURL)
        try FileManager.default.removeItem(at: missingURL)

        let player = MeetingPlayer(library: library, output: .offline)
        player.load(meetingID: meetingID, recordings: recordings)
        #expect(player.checkingAudio)
        await player.waitForAudioCheck()
        let seconds = { (value: Double) in try MediaTime(seconds: value) }
        #expect(player.damagedAudio == [
            DamagedAudio(recordingID: recordings[1].id, track: .system, interval: try MediaInterval(start: seconds(2), end: seconds(12))),
            DamagedAudio(recordingID: recordings[2].id, track: .microphone, interval: try MediaInterval(start: seconds(14.5), end: seconds(16.5))),
        ])
        // Nothing is shortened or substituted.
        #expect(player.duration == (try seconds(16.5)))
        let info = try #require(player.recordingInfo(recordings[1].id))
        #expect(info.number == 2 && info.count == 3 && info.startedAt == recordings[1].startedAt)

        // Playback reaches the damage and stops there, naming the recording.
        player.play()
        await player.waitUntilStarted()
        _ = try await player.renderOffline(frames: 192_000)
        guard case let .failed(message, _, failedID) = player.state else { Issue.record("Expected a failure, got \(player.state)"); return }
        #expect(failedID == recordings[1].id && message.contains("system audio") && message.contains("0:02"))
        #expect(player.position == (try seconds(2)))
        // Pressing Play again fails at the same place rather than skipping.
        player.play()
        await player.waitUntilStarted()
        _ = try await player.renderOffline(frames: 4_800)
        guard case .failed = player.state else { Issue.record("Retry skipped the damage: \(player.state)"); return }
        #expect(player.position == (try seconds(2)))

        // The explicit recovery continues after the damaged stretch, inside the
        // same recording, then stops at the next one.
        let next = try #require(player.readablePositionAfterFailure)
        #expect(next == (try seconds(12)))
        player.seek(to: next)
        #expect(player.state == .paused)
        player.play()
        await player.waitUntilStarted()
        #expect(player.currentRecordingID == recordings[1].id)
        _ = try await player.renderOffline(frames: 192_000)
        guard case let .failed(second, _, secondID) = player.state else { Issue.record("Expected a failure, got \(player.state)"); return }
        #expect(secondID == recordings[2].id && second.contains("microphone"))
        #expect(player.position == (try seconds(14.5)))
        #expect(player.readablePositionAfterFailure == nil)

        // Restored files play again from the same position, and the check clears.
        try original.write(to: damagedURL)
        try removed.write(to: missingURL)
        player.play()
        await player.waitUntilStarted()
        _ = try await player.renderOffline(frames: 24_000)
        #expect(player.state == .playing && player.currentRecordingID == recordings[2].id)
        await player.waitForAudioCheck()
        #expect(player.damagedAudio.isEmpty)
        let expected = try await expectedMix(library, meetingID, recordings)
        #expect(expected.count == 792_000)
    }
}
