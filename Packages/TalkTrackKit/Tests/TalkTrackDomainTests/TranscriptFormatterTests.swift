import Foundation
import Testing
import TalkTrackDomain

private struct TranscriptFixture {
    let meetingID = UUID()
    var recording: Recording
    var speaker: DaySpeaker
    init() throws {
        recording = try Recording(meetingID: meetingID, startedAt: Date(timeIntervalSince1970: 1_790_251_200),
            timeZoneIdentifier: "UTC") // 2026-09-24 12:00:00 UTC
        speaker = DaySpeaker(meetingID: meetingID, dayID: recording.days[0].id, number: 1)
    }
    func segment(_ start: Int64, _ end: Int64, text: String, track: AudioTrack = .system,
                 identity: UUID? = nil, wall: Date? = nil) throws -> TranscriptSegment {
        TranscriptSegment(recordingID: recording.id, dayID: recording.days[0].id, track: track,
            interval: try MediaInterval(start: MediaTime(microseconds: start), end: MediaTime(microseconds: end)),
            wallClockStart: wall ?? recording.startedAt.addingTimeInterval(Double(start) / 1_000_000),
            speaker: .system(daySpeakerID: identity ?? speaker.id), originalText: text)
    }
    func render(_ segments: [TranscriptSegment], speakers: [DaySpeaker]? = nil,
                assignments: [SpeakerAssignment] = []) throws -> [TranscriptDisplayItem] {
        try TranscriptFormatter.format(meetingID: meetingID, recordings: [recording], segments: segments,
            speakers: speakers ?? [speaker], assignments: assignments)
    }
}

private func blocks(_ items: [TranscriptDisplayItem]) -> [TranscriptBlock] {
    items.compactMap { if case .speech(let block) = $0 { block } else { nil } }
}
private func dates(_ items: [TranscriptDisplayItem]) -> [TranscriptDateSeparator] {
    items.compactMap { if case .date(let day) = $0 { day } else { nil } }
}

@Suite struct TranscriptFormatterTests {
    @Test func exactTwoSecondGapMergesAndOneMicrosecondMoreSplits() throws {
        let fixture = try TranscriptFixture()
        let first = try fixture.segment(0, 1_000_000, text: "First.")
        for (start, expectedCount) in [(Int64(3_000_000), 1), (Int64(3_000_001), 2)] {
            let second = try fixture.segment(start, start + 1_000_000, text: "Второе.")
            let result = try fixture.render([second, first])
            #expect(blocks(result).count == expectedCount)
            #expect(blocks(result).first?.segments.first?.id == first.id)
            if expectedCount == 1 { #expect(blocks(result).first?.text.hasSuffix("First. Второе.") == true) }
            #expect(dates(result).count == 1)
            #expect(result == (try fixture.render([first, second])))
        }
    }

    @Test func speakerChangesSplitButSameNamedVoicesShareBlocks() throws {
        let fixture = try TranscriptFixture()
        let other = DaySpeaker(meetingID: fixture.meetingID, dayID: fixture.speaker.dayID, number: 2)
        let segments = [
            try fixture.segment(0, 10_000_000, text: "Voice1 mentioned Voice2."),
            try fixture.segment(1_000_000, 2_000_000, text: "Local.", track: .microphone),
            try fixture.segment(2_000_000, 3_000_000, text: "Other.", identity: other.id),
            try fixture.segment(3_000_000, 4_000_000, text: "Remote again.")
        ]
        let assignments = [fixture.speaker, other].map {
            SpeakerAssignment(meetingID: fixture.meetingID, dayID: $0.dayID, daySpeakerID: $0.id,
                name: "Alex", origin: .manual, evidence: [])
        }
        let result = blocks(try fixture.render(segments, speakers: [fixture.speaker, other], assignments: assignments))
        // Voice1 and Voice2 were both named Alex: one person (user decision, 2026-10-13).
        #expect(result.map(\.speakerLabel) == ["Alex", "You", "Alex"])
        #expect(result[2].segments.count == 2)
        let unnamed = blocks(try fixture.render(segments, speakers: [fixture.speaker, other]))
        #expect(unnamed.map(\.speakerLabel) == ["Voice1", "You", "Voice2", "Voice1"])
        #expect(result.first?.text.hasSuffix("Voice1 mentioned Voice2.") == true)
        #expect(result.flatMap(\.segments).map(\.id) == segments.map(\.id))
    }

    @Test func overlappingSameSpeakerUsesTheFurthestSpeechEnd() throws {
        let fixture = try TranscriptFixture()
        let result = try fixture.render([
            fixture.segment(0, 10_000_000, text: "Long."),
            fixture.segment(1_000_000, 2_000_000, text: "Overlap."),
            fixture.segment(5_000_000, 6_000_000, text: "Still inside.")
        ])
        #expect(blocks(result).count == 1)
        #expect(blocks(result).first?.segments.count == 3)
    }

    @Test func wallClockPauseSplitsEvenWhenActiveTimeIsContiguous() throws {
        let fixture = try TranscriptFixture()
        let result = try fixture.render([
            fixture.segment(0, 1_000_000, text: "Before."),
            fixture.segment(1_000_000, 2_000_000, text: "After.", wall: fixture.recording.startedAt.addingTimeInterval(301))
        ])
        #expect(blocks(result).count == 2)
    }

    @Test func everyRecordingStartsWithItsOwnSeparatorEvenOnTheSameDay() throws {
        let fixture = try TranscriptFixture()
        var second = try Recording(meetingID: fixture.meetingID,
            startedAt: fixture.recording.startedAt.addingTimeInterval(2), timeZoneIdentifier: "UTC")
        second.days = fixture.recording.days
        let segment = TranscriptSegment(recordingID: second.id, dayID: fixture.speaker.dayID, track: .system,
            interval: try MediaInterval(start: .zero, end: MediaTime(seconds: 1)), wallClockStart: second.startedAt,
            speaker: .system(daySpeakerID: fixture.speaker.id), originalText: "New file.")
        let result = try TranscriptFormatter.format(meetingID: fixture.meetingID,
            recordings: [second, fixture.recording], segments: [segment, fixture.segment(0, 1_000_000, text: "First file.")],
            speakers: [fixture.speaker])
        #expect(blocks(result).count == 2)
        // Each recording has its own separator with its start time; same day, no resumption.
        #expect(dates(result).map(\.text) == ["------------ [September 24, 2026 · 12:00] ------------",
                                              "------------ [September 24, 2026 · 12:00] ------------"])
        #expect(dates(result).map(\.recordingID) == [fixture.recording.id, second.id])
        #expect(dates(result).allSatisfy { $0.isRecordingStart && !$0.isResumption })
        #expect(Set(result.map(\.id)).count == result.count)
    }

    @Test func recordingsWithoutTextKeepTheirPlaceWithANote() throws {
        let fixture = try TranscriptFixture()
        func recording(after hours: Double) throws -> Recording {
            var value = try Recording(meetingID: fixture.meetingID,
                startedAt: fixture.recording.startedAt.addingTimeInterval(hours * 3600), timeZoneIdentifier: "UTC")
            value.days = fixture.recording.days
            return value
        }
        let failed = try recording(after: 1), third = try recording(after: 3)
        let unnoted = try recording(after: 2)
        let last = TranscriptSegment(recordingID: third.id, dayID: fixture.speaker.dayID, track: .system,
            interval: try MediaInterval(start: .zero, end: MediaTime(seconds: 1)), wallClockStart: third.startedAt,
            speaker: .system(daySpeakerID: fixture.speaker.id), originalText: "Third.")
        let result = try TranscriptFormatter.format(meetingID: fixture.meetingID,
            recordings: [third, unnoted, failed, fixture.recording],
            segments: [last, fixture.segment(0, 1_000_000, text: "First.")], speakers: [fixture.speaker],
            emptyNotes: [failed.id: "Transcription failed"])
        // The failed middle recording sits between the others' text; one without a note is left out.
        #expect(result.map(\.text) == [
            "------------ [September 24, 2026 · 12:00] ------------",
            "[12:00:00]: Voice1 - First.",
            "------------ [September 24, 2026 · 13:00] ------------",
            "------------ [September 24, 2026 · 15:00] ------------",
            "[15:00:00]: Voice1 - Third."
        ])
        #expect(dates(result)[1].note == "Transcription failed" && dates(result)[1].recordingID == failed.id)
        // A transcript of only text-less recordings still lists them.
        let empty = try TranscriptFormatter.format(meetingID: fixture.meetingID, recordings: [failed], segments: [],
            speakers: [], emptyNotes: [failed.id: "Not transcribed"])
        #expect(dates(empty).map(\.note) == ["Not transcribed"])
    }

    @Test func midnightIsOrdinaryButLaterRecordingGetsResumption() throws {
        var fixture = try TranscriptFixture()
        fixture.recording = try Recording(meetingID: fixture.meetingID,
            startedAt: Date(timeIntervalSince1970: 1_790_294_399), timeZoneIdentifier: "UTC")
        fixture.speaker = DaySpeaker(meetingID: fixture.meetingID, dayID: fixture.recording.days[0].id, number: 1)
        let laterDay = try RecordingDay(capturedAt: fixture.recording.startedAt.addingTimeInterval(2), timeZoneIdentifier: "UTC")
        fixture.recording.days.append(laterDay)
        let continuing = TranscriptSegment(recordingID: fixture.recording.id, dayID: laterDay.id, track: .microphone,
            interval: try MediaInterval(start: MediaTime(seconds: 2), end: MediaTime(seconds: 3)),
            wallClockStart: fixture.recording.startedAt.addingTimeInterval(2), speaker: .microphone, originalText: "Next day.")
        let resumed = try Recording(meetingID: fixture.meetingID,
            startedAt: fixture.recording.startedAt.addingTimeInterval(3 * 86_400), timeZoneIdentifier: "UTC")
        let resumeSegment = TranscriptSegment(recordingID: resumed.id, dayID: resumed.days[0].id, track: .microphone,
            interval: try MediaInterval(start: .zero, end: MediaTime(seconds: 1)), wallClockStart: resumed.startedAt,
            speaker: .microphone, originalText: "Resumed.")
        let result = try TranscriptFormatter.format(meetingID: fixture.meetingID, recordings: [resumed, fixture.recording],
            segments: [resumeSegment, continuing, fixture.segment(0, 1_000_000, text: "First day.")], speakers: [fixture.speaker])
        #expect(dates(result).map(\.isResumption) == [false, false, true])
        #expect(dates(result).map(\.isRecordingStart) == [true, false, true])
        #expect(dates(result).map(\.text) == [
            "------------ [September 24, 2026 · 23:59] ------------",
            "------------ [September 25, 2026] ------------",
            "------------ [September 27, 2026 · 23:59] resumption ------------"
        ])
        #expect(blocks(result).count == 3)
    }

    @Test func frozenZoneCorrectedTextAndRenameDoNotRewriteSourceOrMicrophone() throws {
        let meetingID = UUID(), start = Date(timeIntervalSince1970: 1_790_294_400)
        let recording = try Recording(meetingID: meetingID, startedAt: start, timeZoneIdentifier: "Asia/Tokyo")
        let speaker = DaySpeaker(meetingID: meetingID, dayID: recording.days[0].id, number: 1)
        let segment = TranscriptSegment(recordingID: recording.id, dayID: speaker.dayID, track: .microphone,
            interval: try MediaInterval(start: .zero, end: MediaTime(seconds: 1)), wallClockStart: start,
            speaker: .system(daySpeakerID: speaker.id), originalText: "Voice1 said no 42", correctedText: "Voice1 said no 42.")
        let assignment = SpeakerAssignment(meetingID: meetingID, dayID: speaker.dayID, daySpeakerID: speaker.id,
            name: "Alex", origin: .manual, evidence: [])
        let result = try TranscriptFormatter.format(meetingID: meetingID, recordings: [recording], segments: [segment],
            speakers: [speaker], assignments: [assignment])
        #expect(dates(result).first?.date == recording.days[0].localDate)
        #expect(blocks(result).first?.speakerLabel == "You")
        #expect(blocks(result).first?.timestamp == "09:00:00")
        #expect(blocks(result).first?.text == "[09:00:00]: You - Voice1 said no 42.")
        #expect(segment.originalText == "Voice1 said no 42")
        #expect(blocks(result).first?.segments == [segment])
    }

    @Test func missingOrDuplicateProvenanceFailsAndEmptyTranscriptIsEmpty() throws {
        let fixture = try TranscriptFixture(), segment = try fixture.segment(0, 1_000_000, text: "Hello")
        #expect(try fixture.render([]).isEmpty)
        #expect(throws: TranscriptFormattingError.missingSpeaker) { try fixture.render([segment], speakers: []) }
        #expect(throws: TranscriptFormattingError.inconsistentMetadata) { try fixture.render([segment, segment]) }
        #expect(throws: TranscriptFormattingError.missingRecording) {
            try TranscriptFormatter.format(meetingID: fixture.meetingID, recordings: [], segments: [segment], speakers: [fixture.speaker])
        }
    }
}
