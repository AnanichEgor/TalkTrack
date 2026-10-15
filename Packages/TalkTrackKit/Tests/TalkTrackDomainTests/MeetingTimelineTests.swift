import Foundation
import Testing
@testable import TalkTrackDomain

private func time(_ seconds: Double) throws -> MediaTime { try MediaTime(seconds: seconds) }
private func span(_ start: Double, _ end: Double) throws -> MediaInterval {
    try MediaInterval(start: time(start), end: time(end))
}
private func timelineRecording(meeting: UUID, duration: Double, date: Date) throws -> Recording {
    var recording = try Recording(meetingID: meeting, startedAt: date, timeZoneIdentifier: "Europe/London")
    recording.activeDuration = try time(duration)
    recording.state = .complete
    return recording
}
private func audioChunk(recording: Recording, track: AudioTrack, start: Double, duration: Double,
                        leading: UInt64 = 0, trailing: UInt64 = 0) throws -> TrackChunk {
    try TrackChunk(track: track, file: RelativePath("audio/\(UUID()).m4a"),
        active: span(start, start + duration), sampleRate: 48_000,
        decodedFrameCount: UInt64((duration * 48_000).rounded()) + leading + trailing,
        leadingTrimFrames: leading, trailingTrimFrames: trailing, hostTimeStart: 42)
}
private func playback(_ timeline: MeetingTimeline, _ seconds: Double) throws -> TimelinePlaybackPosition {
    guard case let .recording(position) = try timeline.position(at: time(seconds)) else {
        throw TimelineError.positionOutOfRange
    }
    return position
}
private func audioPosition(_ position: TimelineTrackPosition) throws -> TimelineAudioPosition {
    guard case let .audio(audio) = position else { throw TimelineError.positionOutOfRange }
    return audio
}

@Suite struct MeetingTimelineTests {
    @Test func emptyZeroDurationsAndTotalEnd() throws {
        let meeting = UUID(), date = Date(timeIntervalSince1970: 1_791_465_600)
        let empty = try MeetingTimeline(meetingID: meeting, recordings: [])
        #expect(empty.totalDuration == .zero)
        #expect(try empty.position(at: .zero) == .empty)
        #expect(throws: TimelineError.positionOutOfRange) { try empty.position(at: time(1)) }
        let zero = try timelineRecording(meeting: meeting, duration: 0, date: date)
        let onlyZeros = try MeetingTimeline(meetingID: meeting, recordings: [zero])
        #expect(try onlyZeros.position(at: .zero) == .empty)
        #expect(try onlyZeros.globalTime(recordingID: zero.id, activeTime: .zero) == .zero)
        let actual = try timelineRecording(meeting: meeting, duration: 1, date: date.addingTimeInterval(10))
        var trailingZero = zero
        trailingZero = try timelineRecording(meeting: meeting, duration: 0, date: date.addingTimeInterval(20))
        let timeline = try MeetingTimeline(meetingID: meeting, recordings: [trailingZero, actual, zero])
        #expect(try playback(timeline, 0).recordingID == actual.id)
        #expect(try timeline.position(at: time(1)) == .end)
        #expect(throws: TimelineError.positionOutOfRange) { try timeline.position(at: time(1.000001)) }
    }

    @Test func captureOrderExactRecordingBoundaryAnd605SecondSeek() throws {
        let meeting = UUID(), date = Date(timeIntervalSince1970: 1_791_465_600)
        var first = try timelineRecording(meeting: meeting, duration: 600, date: date)
        var second = try timelineRecording(meeting: meeting, duration: 1200, date: date.addingTimeInterval(3 * 86_400))
        for track in AudioTrack.allCases {
            first.chunks.append(try audioChunk(recording: first, track: track, start: 0, duration: 600))
            second.chunks.append(try audioChunk(recording: second, track: track, start: 0, duration: 1200))
        }
        let timeline = try MeetingTimeline(meetingID: meeting, recordings: [second, first])
        #expect(timeline.totalDuration == (try time(1800)))
        #expect(timeline.recordings.map(\.recordingID) == [first.id, second.id])
        #expect(try playback(timeline, 599.999999).recordingID == first.id)
        let boundary = try playback(timeline, 600)
        #expect(boundary.recordingID == second.id)
        #expect(boundary.activeTime == .zero)
        let sought = try playback(timeline, 605)
        #expect(sought.recordingID == second.id)
        #expect(sought.activeTime == (try time(5)))
        #expect(try audioPosition(sought.system).decodedFrame == 240_000)
        #expect(try audioPosition(sought.microphone).decodedFrame == 240_000)
        #expect(sought.capturedTime == nil)
        #expect(try timeline.globalTime(recordingID: first.id, activeTime: time(600)) == time(600))
        #expect(try timeline.position(at: time(1800)) == .end)
    }

    @Test func pauseExclusionFrozenDayAndWallClockInverse() throws {
        let meeting = UUID(), start = Date(timeIntervalSince1970: 1_791_465_600)
        var recording = try timelineRecording(meeting: meeting, duration: 120, date: start)
        recording.captureIntervals = [
            CaptureInterval(active: try span(0, 60), wallClockStart: start, hostTimeStart: 10, dayID: recording.days[0].id),
            CaptureInterval(active: try span(60, 120), wallClockStart: start.addingTimeInterval(360), hostTimeStart: 99,
                            dayID: recording.days[0].id)
        ]
        let timeline = try MeetingTimeline(meetingID: meeting, recordings: [recording])
        let resumed = try playback(timeline, 60)
        #expect(resumed.capturedTime?.wallClock == start.addingTimeInterval(360))
        #expect(resumed.capturedTime?.day == recording.days[0])
        #expect(resumed.capturedTime?.hostTimeStart == 99)
        #expect(try timeline.globalTimes(recordingID: recording.id, wallClock: start.addingTimeInterval(180)).isEmpty)
        #expect(try timeline.globalTimes(recordingID: recording.id, wallClock: start.addingTimeInterval(365)) == [time(65)])
        #expect(try timeline.globalTimes(recordingID: recording.id, wallClock: start.addingTimeInterval(420)).isEmpty)
    }

    @Test func explicitSourceGapsDoNotShiftOtherTrack() throws {
        let meeting = UUID()
        var recording = try timelineRecording(meeting: meeting, duration: 30, date: Date())
        let system1 = try audioChunk(recording: recording, track: .system, start: 0, duration: 10)
        let system2 = try audioChunk(recording: recording, track: .system, start: 20, duration: 10)
        let mic = try audioChunk(recording: recording, track: .microphone, start: 5, duration: 25)
        recording.chunks = [system2, mic, system1]
        recording.trackIntervals = [
            TrackInterval(track: .system, active: system1.active, content: .chunk(id: system1.id, firstDecodedFrame: 0, frameCount: 480_000)),
            TrackInterval(track: .system, active: try span(10, 20), content: .gap(reason: "Output device disconnected")),
            TrackInterval(track: .system, active: system2.active, content: .chunk(id: system2.id, firstDecodedFrame: 0, frameCount: 480_000))
        ]
        let timeline = try MeetingTimeline(meetingID: meeting, recordings: [recording])
        #expect(try playback(timeline, 0).microphone == .gap(active: span(0, 5), reason: "No captured audio for this source"))
        let inGap = try playback(timeline, 15)
        #expect(inGap.system == .gap(active: try span(10, 20), reason: "Output device disconnected"))
        #expect(try audioPosition(inGap.microphone).decodedFrame == 480_000)
        #expect(try audioPosition(playback(timeline, 20).system).chunkID == system2.id)
        #expect(timeline.totalDuration == (try time(30)))
    }

    @Test func trimAwareFrameRoundTripsAndChunkBoundaries() throws {
        let meeting = UUID()
        var recording = try timelineRecording(meeting: meeting, duration: 20, date: Date())
        let first = try audioChunk(recording: recording, track: .system, start: 0, duration: 10, leading: 2112, trailing: 192)
        let second = try audioChunk(recording: recording, track: .system, start: 10, duration: 10)
        recording.chunks = [first, second]
        let timeline = try MeetingTimeline(meetingID: meeting, recordings: [recording])
        #expect(try audioPosition(playback(timeline, 0).system).decodedFrame == 2112)
        #expect(try audioPosition(playback(timeline, 10).system).chunkID == second.id)
        for offset in stride(from: UInt64(0), to: 480_000, by: 1373) {
            let global = try timeline.globalTime(recordingID: recording.id, track: .system,
                chunkID: first.id, decodedFrame: 2112 + offset)
            guard case let .recording(point) = try timeline.position(at: global) else { Issue.record("Frame resolved outside recording"); return }
            let audio = try audioPosition(point.system)
            #expect(audio.decodedFrame == 2112 + offset)
            #expect(audio.remainingFrames == 480_000 - offset)
        }
        #expect(throws: TimelineError.positionOutOfRange) {
            try timeline.globalTime(recordingID: recording.id, track: .system, chunkID: first.id, decodedFrame: 0)
        }
        #expect(throws: TimelineError.positionOutOfRange) {
            try timeline.globalTime(recordingID: recording.id, track: .system, chunkID: first.id, decodedFrame: 482_112)
        }
    }

    @Test func aSliceOfDecodedChunkMapsBothDirections() throws {
        let meeting = UUID()
        var recording = try timelineRecording(meeting: meeting, duration: 10, date: Date())
        let chunk = try audioChunk(recording: recording, track: .microphone, start: 0, duration: 10, leading: 2112)
        recording.chunks = [chunk]
        recording.trackIntervals = [TrackInterval(track: .microphone, active: try span(2, 8),
            content: .chunk(id: chunk.id, firstDecodedFrame: 98_112, frameCount: 288_000))]
        let timeline = try MeetingTimeline(meetingID: meeting, recordings: [recording])
        #expect(try audioPosition(playback(timeline, 5).microphone).decodedFrame == 242_112)
        #expect(try timeline.globalTime(recordingID: recording.id, track: .microphone,
                                       chunkID: chunk.id, decodedFrame: 242_112) == time(5))
        #expect(throws: TimelineError.positionOutOfRange) {
            try timeline.globalTime(recordingID: recording.id, track: .microphone, chunkID: chunk.id, decodedFrame: 2112)
        }
    }

    @Test func roundedMicrosecondChunkOffsetsRetainExactDecodedFrames() throws {
        let meeting = UUID()
        for firstFrame in [1, 2, 127, 1024, 1373] {
            var recording = try timelineRecording(meeting: meeting, duration: Double(firstFrame + 4096) / 48_000, date: Date())
            let chunk = try TrackChunk(track: .system, file: RelativePath("audio/rounding.m4a"),
                active: span(Double(firstFrame) / 48_000, Double(firstFrame + 4096) / 48_000),
                sampleRate: 48_000, decodedFrameCount: 4096, leadingTrimFrames: 0, trailingTrimFrames: 0, hostTimeStart: 0)
            recording.chunks = [chunk]
            let timeline = try MeetingTimeline(meetingID: meeting, recordings: [recording])
            for frame in stride(from: UInt64(0), to: 4096, by: 17) {
                let time = try timeline.globalTime(recordingID: recording.id, track: .system, chunkID: chunk.id, decodedFrame: frame)
                guard case let .recording(point) = try timeline.position(at: time) else { Issue.record("Invalid rounded frame position"); return }
                #expect(try audioPosition(point.system).decodedFrame == frame)
            }
        }
    }

    @Test func invalidProvenanceNeverSilentlyShortensOrSelectsAnotherRecording() throws {
        let meeting = UUID()
        var recording = try timelineRecording(meeting: meeting, duration: 10, date: Date())
        let chunk = try audioChunk(recording: recording, track: .system, start: 0, duration: 10)
        recording.chunks = [chunk]
        #expect(throws: TimelineError.inconsistentMetadata(recordingID: recording.id)) {
            try MeetingTimeline(meetingID: meeting, recordings: [recording, recording])
        }
        let absent = UUID()
        recording.trackIntervals = [TrackInterval(track: .system, active: chunk.active,
            content: .chunk(id: absent, firstDecodedFrame: 0, frameCount: 480_000))]
        #expect(throws: TimelineError.missingChunk(recordingID: recording.id, chunkID: absent)) {
            try MeetingTimeline(meetingID: meeting, recordings: [recording])
        }
        recording.trackIntervals = [TrackInterval(track: .system, active: chunk.active,
            content: .chunk(id: chunk.id, firstDecodedFrame: 0, frameCount: 480_001))]
        #expect(throws: TimelineError.inconsistentMetadata(recordingID: recording.id)) {
            try MeetingTimeline(meetingID: meeting, recordings: [recording])
        }
        recording.trackIntervals = [TrackInterval(track: .system, active: try span(0, 8), content: .gap(reason: "Lost")),
            TrackInterval(track: .system, active: try span(7, 10), content: .gap(reason: "Lost"))]
        #expect(throws: TimelineError.inconsistentMetadata(recordingID: recording.id)) {
            try MeetingTimeline(meetingID: meeting, recordings: [recording])
        }
        recording.trackIntervals = []
        #expect(throws: TimelineError.inconsistentMetadata(recordingID: recording.id)) {
            try MeetingTimeline(meetingID: UUID(), recordings: [recording])
        }
        let timeline = try MeetingTimeline(meetingID: meeting, recordings: [recording])
        #expect(throws: TimelineError.unknownRecording(absent)) { try timeline.globalTime(recordingID: absent, activeTime: .zero) }
        #expect(throws: TimelineError.positionOutOfRange) { try timeline.globalTime(recordingID: recording.id, activeTime: time(11)) }
        #expect(throws: TimelineError.unknownChunk(absent)) {
            try timeline.globalTime(recordingID: recording.id, track: .system, chunkID: absent, decodedFrame: 0)
        }
    }

    @Test func durationOverflowAndInvalidCaptureCoverageAreErrors() throws {
        let meeting = UUID()
        var first = try timelineRecording(meeting: meeting, duration: 1, date: Date())
        var second = try timelineRecording(meeting: meeting, duration: 1, date: Date().addingTimeInterval(10))
        first.activeDuration = try MediaTime(microseconds: Int64.max)
        second.activeDuration = try MediaTime(microseconds: 1)
        #expect(throws: TimelineError.durationOverflow) { try MeetingTimeline(meetingID: meeting, recordings: [first, second]) }
        first.activeDuration = try time(60)
        first.captureIntervals = [CaptureInterval(active: try span(5, 60), wallClockStart: first.startedAt,
                                                 hostTimeStart: 0, dayID: first.days[0].id)]
        #expect(throws: TimelineError.inconsistentMetadata(recordingID: first.id)) {
            try MeetingTimeline(meetingID: meeting, recordings: [first])
        }
    }
}
