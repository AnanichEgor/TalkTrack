import Foundation
import Testing
import TalkTrackDomain

@Suite struct DaySpeakerProvenanceTests {
    @Test func olderSpeakerPayloadRestoresCanonicalDayAndNewAliasesRoundTrip() throws {
        let dayID = UUID(), speaker = DaySpeaker(meetingID: UUID(), dayID: dayID, number: 1, recordingDayIDs: [UUID(), dayID])
        #expect(try DomainCodec.decode(DaySpeaker.self, from: DomainCodec.encode(speaker)) == speaker)
        var json = try #require(JSONSerialization.jsonObject(with: DomainCodec.encode(speaker)) as? [String: Any])
        var value = try #require(json["value"] as? [String: Any])
        value.removeValue(forKey: "recordingDayIDs")
        json["value"] = value
        let legacy = try DomainCodec.decode(DaySpeaker.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.recordingDayIDs == [dayID])
        #expect(legacy.id == speaker.id)
    }

    @Test func forgedAliasCannotCarryVoiceOrNameToAnotherCalendarDay() throws {
        let meetingID = UUID(), date = ISO8601DateFormatter().date(from: "2026-10-08T10:00:00Z")!
        let first = try Recording(meetingID: meetingID, startedAt: date, timeZoneIdentifier: "UTC")
        let second = try Recording(meetingID: meetingID, startedAt: date.addingTimeInterval(86400), timeZoneIdentifier: "UTC")
        let speaker = DaySpeaker(meetingID: meetingID, dayID: first.days[0].id, number: 1, recordingDayIDs: [second.days[0].id])
        let segment = TranscriptSegment(recordingID: second.id, dayID: second.days[0].id, track: .system,
            interval: try MediaInterval(start: .zero, end: MediaTime(seconds: 1)), wallClockStart: second.startedAt,
            speaker: .system(daySpeakerID: speaker.id), originalText: "Different day")
        #expect(throws: TranscriptFormattingError.inconsistentMetadata) {
            try TranscriptFormatter.format(meetingID: meetingID, recordings: [first, second], segments: [segment], speakers: [speaker])
        }
    }
}
