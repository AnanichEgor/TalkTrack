import Foundation
import Testing
import TalkTrackDomain

private func time(_ seconds: Double) throws -> MediaTime { try MediaTime(seconds: seconds) }

/// A three-day meeting: 60 s, then 30 s two days later, then a recording still
/// being captured that is not on the playback timeline.
private struct MultiDayFixture {
    let meetingID = UUID()
    var recordings: [Recording] = []
    var speakers: [DaySpeaker] = []
    var segments: [TranscriptSegment] = []

    init() throws {
        let base = Date(timeIntervalSince1970: 1_790_251_200)
        for (index, duration) in [60.0, 30.0, 20.0].enumerated() {
            var recording = try Recording(meetingID: meetingID, startedAt: base.addingTimeInterval(Double(index) * 2 * 86_400),
                                          timeZoneIdentifier: "UTC")
            recording.activeDuration = try time(duration)
            recording.state = .complete
            recordings.append(recording)
            speakers.append(DaySpeaker(meetingID: meetingID, dayID: recording.days[0].id, number: 1))
        }
    }

    mutating func say(_ text: String, recording index: Int, _ start: Double, _ end: Double, track: AudioTrack = .system) throws {
        let recording = recordings[index]
        segments.append(TranscriptSegment(recordingID: recording.id, dayID: recording.days[0].id, track: track,
            interval: try MediaInterval(start: time(start), end: time(end)),
            wallClockStart: recording.startedAt.addingTimeInterval(start),
            speaker: .system(daySpeakerID: speakers[index].id), originalText: text))
    }

    func items() throws -> [TranscriptDisplayItem] {
        try TranscriptFormatter.format(meetingID: meetingID, recordings: recordings, segments: segments, speakers: speakers)
    }

    /// The display item whose block begins with `text`.
    func id(_ text: String, in items: [TranscriptDisplayItem]) -> String? {
        items.first { if case .speech(let block) = $0 { block.segments[0].originalText == text } else { false } }?.id
    }
}

@Suite struct TranscriptPlaybackIndexTests {
    @Test func multiDayBlocksMapToTheContinuousTimelineInBothDirections() throws {
        var fixture = try MultiDayFixture()
        try fixture.say("Opening.", recording: 0, 0, 10)
        try fixture.say("Interjection.", recording: 0, 5, 8, track: .microphone)
        try fixture.say("Until the boundary.", recording: 0, 20, 60)
        try fixture.say("Next day.", recording: 1, 0, 4, track: .microphone)
        // A final alignment may end past the recorded audio; it is clamped.
        try fixture.say("Later.", recording: 1, 10, 31)
        try fixture.say("Still recording.", recording: 2, 0, 3)
        let items = try fixture.items()
        // The third recording is still being captured: not on the timeline.
        let timeline = try MeetingTimeline(meetingID: fixture.meetingID, recordings: Array(fixture.recordings.prefix(2)))
        let index = TranscriptPlaybackIndex(timeline: timeline, items: items)
        let id = { (text: String) in fixture.id(text, in: items) }

        #expect(index.entries.count == 5)
        #expect(index.start(of: id("Still recording.")!) == nil)
        #expect(index.start(of: id("Next day.")!) == (try time(60)))
        #expect(index.start(of: id("Later.")!) == (try time(70)))
        #expect(index.entries.last?.global.end == (try time(90)))

        // Position → highlighted block.
        #expect(index.activeItem(at: .zero) == id("Opening."))
        #expect(index.activeItem(at: try time(6)) == id("Interjection."))
        #expect(index.activeItem(at: try time(9)) == id("Opening."))
        #expect(index.activeItem(at: try time(15)) == nil)
        #expect(index.activeItem(at: try time(59.999999)) == id("Until the boundary."))
        // An exact boundary belongs to the next recording.
        #expect(index.activeItem(at: try time(60)) == id("Next day."))
        #expect(index.activeItem(at: try time(65)) == nil)
        #expect(index.activeItem(at: try time(89.999999)) == id("Later."))
        #expect(index.activeItem(at: try time(90)) == nil)

        // Timestamp → seek → the same block is highlighted, both forwards
        // across days and backwards again.
        for text in ["Later.", "Opening.", "Next day.", "Interjection.", "Until the boundary."] {
            let target = try #require(index.start(of: id(text)!))
            #expect(index.activeItem(at: target) == id(text))
            guard case let .recording(position) = try timeline.position(at: target) else { Issue.record("\(text) not playable"); continue }
            let block = items.compactMap { if case .speech(let b) = $0, $0.id == id(text) { b } else { nil } }.first!
            #expect(position.recordingID == block.recordingID)
            #expect(position.activeTime == block.segments[0].interval.start)
        }
    }

    @Test func emptyTimelineAndZeroLengthSpeechHaveNoHighlight() throws {
        var fixture = try MultiDayFixture()
        try fixture.say("Instant.", recording: 0, 3, 3)
        let items = try fixture.items()
        let empty = TranscriptPlaybackIndex(timeline: try MeetingTimeline(meetingID: fixture.meetingID, recordings: []), items: items)
        #expect(empty.entries.isEmpty)
        #expect(empty.activeItem(at: .zero) == nil)
        let index = TranscriptPlaybackIndex(timeline: try MeetingTimeline(meetingID: fixture.meetingID, recordings: [fixture.recordings[0]]),
                                            items: items)
        // Still seekable, but an empty interval is never "being heard".
        #expect(index.start(of: fixture.id("Instant.", in: items)!) == (try time(3)))
        #expect(index.activeItem(at: try time(3)) == nil)
    }
}
