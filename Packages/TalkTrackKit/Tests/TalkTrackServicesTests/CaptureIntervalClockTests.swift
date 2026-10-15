import AVFoundation
import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

private func ticks(_ seconds: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: seconds) }
private func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@Suite struct CaptureIntervalClockTests {
    @Test func sharedHostClockIgnoresDeliveryDelayAndFiveMinutePause() throws {
        var clock = CaptureIntervalClock()
        let start = utc("2026-10-08T10:00:00Z"), origin = ticks(100)
        try clock.begin(hostTime: origin, wallClock: start, timeZoneIdentifier: "Europe/London")
        #expect(try clock.activeFrame(at: origin + ticks(0.120)) == 5760)
        // Delivery order is unrelated to the captured position of either track.
        #expect(try clock.activeFrame(at: origin + ticks(0.010)) == 480)
        let checkpoint = try clock.checkpoint(at: origin + ticks(30))
        #expect(checkpoint.activeDuration.seconds == 30)
        #expect(clock.closedSnapshot.activeDuration == .zero)
        #expect(throws: CaptureClockError.invalidAnchor) { try clock.close(at: origin + ticks(29)) }
        let paused = try clock.close(at: origin + ticks(60))
        #expect(paused.activeFrameCount == 2_880_000)
        #expect(throws: CaptureClockError.notRunning) { try clock.activeFrame(at: origin + ticks(180)) }
        try clock.begin(hostTime: origin + ticks(360), wallClock: start.addingTimeInterval(360), timeZoneIdentifier: "Europe/London")
        #expect(try clock.activeFrame(at: origin + ticks(365)) == 3_120_000)
        let done = try clock.close(at: origin + ticks(420))
        #expect(done.activeDuration.seconds == 120)
        #expect(done.intervals.map(\.active.duration.seconds) == [60, 60])
        #expect(done.intervals.last?.wallClockStart == start.addingTimeInterval(360))
        #expect(done.days.count == 1)
        var recording = try Recording(meetingID: UUID(), startedAt: start, timeZoneIdentifier: "Europe/London")
        recording.activeDuration = done.activeDuration; recording.days = done.days; recording.captureIntervals = done.intervals
        let timeline = try MeetingTimeline(meetingID: recording.meetingID, recordings: [recording])
        guard case let .recording(position) = try timeline.position(at: MediaTime(seconds: 65)) else { Issue.record("Missing position"); return }
        #expect(position.capturedTime?.wallClock == start.addingTimeInterval(365))
    }

    @Test func midnightAndResumeInAnotherTimeZoneKeepFrozenDays() throws {
        var clock = CaptureIntervalClock()
        let start = utc("2026-10-08T22:59:50Z"), origin = ticks(100)
        try clock.begin(hostTime: origin, wallClock: start, timeZoneIdentifier: "Europe/London")
        let checkpoint = try clock.checkpoint(at: origin + ticks(15))
        let secondCheckpoint = try clock.checkpoint(at: origin + ticks(18))
        #expect(checkpoint.days == secondCheckpoint.days)
        let first = try clock.close(at: origin + ticks(20))
        #expect(first.days == checkpoint.days)
        #expect(first.days.map(\.localDate) == ["2026-10-08", "2026-10-09"])
        #expect(first.days.map(\.utcOffsetSeconds) == [3600, 3600])
        #expect(first.intervals.map(\.active.duration.seconds) == [10, 10])
        #expect(first.intervals.last?.hostTimeStart == origin + ticks(10))
        let later = utc("2026-10-11T00:00:00Z")
        try clock.begin(hostTime: origin + ticks(3 * 86_400), wallClock: later, timeZoneIdentifier: "Asia/Tokyo")
        let done = try clock.close(at: origin + ticks(3 * 86_400 + 10))
        #expect(done.days.prefix(2).elementsEqual(first.days))
        #expect(done.days.last?.utcOffsetSeconds == 32_400)
        #expect(done.days.last?.localDate == "2026-10-11")
        #expect(done.activeDuration.seconds == 30)
    }

    @Test func dstTransitionCreatesCorrectFrozenOffset() throws {
        var clock = CaptureIntervalClock()
        let start = utc("2026-10-25T00:59:50Z"), origin = ticks(100)
        try clock.begin(hostTime: origin, wallClock: start, timeZoneIdentifier: "Europe/London")
        let snapshot = try clock.close(at: origin + ticks(20))
        #expect(snapshot.days.map(\.localDate) == ["2026-10-25", "2026-10-25"])
        #expect(snapshot.days.map(\.utcOffsetSeconds) == [3600, 0])
        #expect(snapshot.intervals.map(\.active.duration.seconds) == [10, 10])
        #expect(snapshot.activeFrameCount == 960_000)
    }

    @Test func invalidAnchorsDoNotMutateAndZeroDurationAddsNoInterval() throws {
        var clock = CaptureIntervalClock()
        #expect(throws: CaptureClockError.notRunning) { try clock.close(at: 1) }
        #expect(throws: CaptureClockError.invalidAnchor) {
            try clock.begin(hostTime: 1, wallClock: Date(), timeZoneIdentifier: "not-a-zone")
        }
        try clock.begin(hostTime: 100, wallClock: Date(), timeZoneIdentifier: "UTC")
        #expect(throws: CaptureClockError.alreadyRunning) { try clock.begin(hostTime: 100, wallClock: Date(), timeZoneIdentifier: "UTC") }
        #expect(throws: CaptureClockError.invalidAnchor) { try clock.close(at: 99) }
        #expect(try clock.close(at: 100).intervals.isEmpty)
        #expect(clock.closedSnapshot.activeDuration == .zero)
        #expect(throws: CaptureClockError.invalidAnchor) { try clock.begin(hostTime: 99, wallClock: Date(), timeZoneIdentifier: "UTC") }
        try clock.begin(hostTime: 101, wallClock: Date(), timeZoneIdentifier: "UTC")
        #expect(try clock.close(at: 101 + ticks(1)).activeFrameCount == 48_000)
    }

    @Test func twoHourClockCheckpointsDoNotAccumulatePacketRounding() throws {
        var clock = CaptureIntervalClock()
        let origin = ticks(100), start = utc("2026-10-08T10:00:00Z")
        try clock.begin(hostTime: origin, wallClock: start, timeZoneIdentifier: "UTC")
        // Unequal packet grids: sample counters are deliberately not the clock.
        for second in stride(from: 0, through: 7200, by: 7) {
            let systemFrame = try clock.activeFrame(at: origin + ticks(Double(second)))
            let microphoneFrame = try clock.activeFrame(at: origin + ticks(Double(second) + 0.000001))
            #expect(abs(Int64(microphoneFrame) - Int64(systemFrame)) <= 1)
        }
        let done = try clock.close(at: origin + ticks(7200))
        #expect(done.activeFrameCount == 345_600_000)
        #expect(done.activeDuration.seconds == 7200)
        // This checks clock arithmetic only; it is not the task 4.4 audio-drift gate.
    }

    @Test func durableTimingPauseAndRouteGapSurviveRecovery() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let start = utc("2026-10-08T10:00:00Z"), origin = ticks(100)
        let recording = try Recording(meetingID: UUID(), startedAt: start, timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
        var clock = CaptureIntervalClock()
        try clock.begin(hostTime: origin, wallClock: start, timeZoneIdentifier: "UTC")
        try await writer.updateCaptureTiming(clock.checkpoint(at: origin + ticks(2)), state: .recording)
        let second = [Float](repeating: 0.2, count: 48_000)
        for i in 0..<2 {
            for track in AudioTrack.allCases {
                try await writer.append(track: track, samples: second, activeStartFrame: UInt64(i * 48_000), hostTimeStart: origin + ticks(Double(i)))
            }
        }
        let paused = try clock.close(at: origin + ticks(2))
        try await writer.closeInterval()
        try await writer.updateCaptureTiming(paused, state: .paused)
        try clock.begin(hostTime: origin + ticks(302), wallClock: start.addingTimeInterval(302), timeZoneIdentifier: "UTC")
        try await writer.updateCaptureTiming(clock.checkpoint(at: origin + ticks(304)), state: .recording)
        let beforeBadCheckpoint = await writer.snapshot()
        await #expect(throws: ServiceError.self) {
            try await writer.updateCaptureTiming(paused, state: .recording)
        }
        #expect(await writer.snapshot() == beforeBadCheckpoint)
        for i in 2..<4 {
            try await writer.append(track: .system, samples: second, activeStartFrame: UInt64(i * 48_000), hostTimeStart: origin + ticks(Double(i + 300)))
        }
        let half = [Float](repeating: 0.1, count: 24_000)
        try await writer.append(track: .microphone, samples: half, activeStartFrame: 96_000, hostTimeStart: origin + ticks(302))
        let gap = try MediaInterval(start: MediaTime(seconds: 2.5), end: MediaTime(seconds: 3.5))
        try await writer.recordGap(track: .microphone, active: gap, reason: "Selected input device disconnected")
        await #expect(throws: ServiceError.self) {
            try await writer.append(track: .microphone, samples: half, activeStartFrame: 120_000, hostTimeStart: origin + ticks(302.5))
        }
        try await writer.append(track: .microphone, samples: half, activeStartFrame: 168_000, hostTimeStart: origin + ticks(303.5))
        let timing = try clock.close(at: origin + ticks(304))
        try await writer.updateCaptureTiming(timing, state: .stopping)
        let result = try await writer.finish(interrupted: true)
        #expect(result.recording.activeDuration.seconds == 4)
        #expect(result.recording.captureIntervals == timing.intervals)
        #expect(result.recording.days == timing.days)
        #expect(result.audio.filter { $0.chunk.track == .system }.map(\.encoding.validFrames) == [96_000, 96_000])
        #expect(result.audio.filter { $0.chunk.track == .microphone }.map(\.encoding.validFrames) == [96_000, 24_000, 24_000])
        let recovered = try await RecordingAudioWriter.recover(library: library, meetingID: recording.meetingID, recordingID: recording.id)
        #expect(recovered == result)
        let timeline = try MeetingTimeline(meetingID: recording.meetingID, recordings: [recovered.recording])
        guard case let .recording(point) = try timeline.position(at: MediaTime(seconds: 3)) else { Issue.record("Lost timeline"); return }
        #expect(point.capturedTime?.wallClock == start.addingTimeInterval(303))
        #expect(point.microphone == .gap(active: gap, reason: "Selected input device disconnected"))
        guard case let .audio(system) = point.system else { Issue.record("System audio was shifted"); return }
        #expect(system.decodedFrame == 48_000)
    }
}
