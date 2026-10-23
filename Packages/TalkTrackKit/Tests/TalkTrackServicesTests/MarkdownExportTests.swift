import Foundation
import Testing
@testable import TalkTrackDomain
@testable import TalkTrackServices

@Suite(.serialized) struct MarkdownExportTests {
    // MARK: Snapshot from a library

    @Test func snapshotReadsEveryTabFromTheLibrary() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url)
        try await f.store.commitNotes(NotesRevision(meetingID: f.meeting.id, text: "# Agenda\n- [ ] Budget", format: .markdown))
        let before = try await f.store.meetingTranscript(meetingID: f.meeting.id)

        let snapshot = try await f.store.meetingExport(meetingID: f.meeting.id, settings: f.settings)

        #expect(snapshot.meeting.title == "Planning")
        #expect(snapshot.transcript == before.items && !snapshot.provisional)
        #expect(snapshot.notes?.text == "# Agenda\n- [ ] Budget")
        #expect(snapshot.summaries.map(\.number) == [1, 2, 3])
        #expect(snapshot.summaries.map(\.recording.id) == f.recordings.map(\.id))
        #expect(snapshot.summaries.allSatisfy { !$0.outdated })
        #expect(snapshot.translation?.language == f.settings.translationLanguage)
        #expect(snapshot.translation?.outdated == false)
        #expect(try await f.store.exportableSections(meetingID: f.meeting.id) == Set(MeetingExportSection.allCases))
        // Reading changes nothing.
        #expect(try await f.store.meetingTranscript(meetingID: f.meeting.id) == before)
    }

    @Test func renamingAVoiceMarksOnlyItsSummaryAndTheTranslationOutdated() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url)
        let revision = try #require(try await f.store.transcript(meetingID: f.meeting.id, recordingID: f.recordings[0].id))
        let target = try await f.store.speakerRenameTarget(meetingID: f.meeting.id, recordingID: f.recordings[0].id,
                                                           segmentID: revision.segments[0].id)
        _ = try await f.store.renameSpeaker(target, name: "Anna K")

        let snapshot = try await f.store.meetingExport(meetingID: f.meeting.id, settings: f.settings)

        #expect(snapshot.summaries.map(\.outdated) == [true, false, false])
        #expect(snapshot.translation?.outdated == true)
        let summary = try #require(MeetingMarkdownExport.markdown(snapshot, section: .summary))
        let first = try #require(summary.range(of: "## Recording 1"))
        let second = try #require(summary.range(of: "## Recording 2"))
        #expect(summary[first.upperBound..<second.lowerBound].contains("_Outdated._"))
        #expect(!summary[second.upperBound...].contains("_Outdated._"))
    }

    @Test func emptyMeetingHasNothingToExport() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let store = try await SessionStore.open(library)
        let meeting = try await store.createMeeting(MeetingDraft(title: "Kickoff", description: ""))

        #expect(try await store.exportableSections(meetingID: meeting.id).isEmpty)
        let snapshot = try await store.meetingExport(meetingID: meeting.id, settings: ProcessingSettings())
        for section in MeetingExportSection.allCases { #expect(MeetingMarkdownExport.markdown(snapshot, section: section) == nil) }
        #expect(MeetingMarkdownExport.markdown(all: snapshot) == "# Kickoff\n")
        try await store.close()
    }

    // MARK: Transcript and translation

    @Test func transcriptOfTwoDaysMatchesTheTab() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url, translate: false)
        let snapshot = try await f.store.meetingExport(meetingID: f.meeting.id, settings: f.settings)

        let markdown = try #require(MeetingMarkdownExport.markdown(snapshot, section: .transcript))

        #expect(markdown == "# Planning - Transcript\n\n" + snapshot.transcript.map { item in
            if case .speech = item { "\\" + item.text } else { item.text }
        }.joined(separator: "\n\n") + "\n")
        #expect(markdown.contains("------------ [September 25, 2026 · 09:00] ------------"))
        #expect(markdown.contains("------------ [September 28, 2026 · 09:00] resumption ------------"))
        #expect(markdown.contains("\\[09:00:00]: Anna - Call 1 opens."))
        #expect(markdown.contains("\\[09:00:05]: You - Reply 1."))
        #expect(MeetingMarkdownExport.markdown(snapshot, section: .translation) == nil)
    }

    @Test func utteranceLinesCannotBecomeMarkdown() {
        let day = UUID(), recording = UUID()
        let segment = TranscriptSegment(recordingID: recording, dayID: day, track: .microphone,
            interval: try! MediaInterval(start: .zero, end: MediaTime(seconds: 1)), wallClockStart: Date(),
            speaker: .microphone, originalText: "Point one\n# not a heading\n- not a list\n2. not numbered")
        let block = TranscriptBlock(recordingID: recording, dayID: day, speaker: .microphone, speakerLabel: "You",
                                    timestamp: "00:00:01", segments: [segment])

        let text = MeetingMarkdownExport.items([.speech(block)])[0]

        #expect(text == "\\[00:00:01]: You - Point one\n\\# not a heading\n\\- not a list\n2\\. not numbered")
    }

    @Test func provisionalTranscriptAndTranslationAreMarked() throws {
        let day = UUID(), recording = UUID()
        let segment = TranscriptSegment(recordingID: recording, dayID: day, track: .system,
            interval: try! MediaInterval(start: .zero, end: MediaTime(seconds: 1)), wallClockStart: Date(),
            speaker: .microphone, originalText: "Hello")
        let items: [TranscriptDisplayItem] = [
            .date(TranscriptDateSeparator(recordingID: recording, dayID: day, date: "2026-10-05", isResumption: false, time: "16:00")),
            .speech(TranscriptBlock(recordingID: recording, dayID: day, speaker: .microphone, speakerLabel: "You",
                                    timestamp: "00:00:00", segments: [segment]))
        ]
        let snapshot = MeetingExportSnapshot(meeting: try Meeting(draft: MeetingDraft(title: "Daily", description: "")),
            transcript: items, provisional: true, notes: nil, summaries: [],
            translation: .init(items: items, language: .russian, outdated: true))

        #expect(MeetingMarkdownExport.markdown(snapshot, section: .transcript) == """
            # Daily - Transcript

            _Provisional live transcript._

            ------------ [October 5, 2026 · 16:00] ------------

            \\[00:00:00]: You - Hello

            """)
        #expect(MeetingMarkdownExport.markdown(snapshot, section: .translation)?.hasPrefix(
            "# Daily - Translation\n\n_Translated to Russian._\n\n_Outdated._\n\n------------ [October 5, 2026") == true)
    }

    @Test func emptyRecordingKeepsItsNote() {
        let separator = TranscriptDateSeparator(recordingID: UUID(), dayID: UUID(), date: "2026-10-05",
                                                isResumption: false, time: "16:00", note: "Not transcribed")
        #expect(MeetingMarkdownExport.items([.date(separator)]) == ["------------ [October 5, 2026 · 16:00] ------------\n_Not transcribed_"])
    }

    // MARK: Notes and summaries

    @Test func notesKeepMarkdownAndNestBelowTheirSection() {
        let notes = NotesRevision(meetingID: UUID(), text: "# Agenda\nIntro\n- One\n- Two\n## Later\n- [x] Done", format: .markdown)
        #expect(MeetingMarkdownExport.notesMarkdown(notes, below: 1) == "## Agenda\n\nIntro\n\n- One\n- Two\n\n### Later\n\n- [x] Done")
        #expect(MeetingMarkdownExport.notesMarkdown(notes, below: 2).hasPrefix("### Agenda"))
    }

    @Test func legacyPlainTextNotesStayLiteral() {
        let notes = NotesRevision(meetingID: UUID(), text: "# not a title\nBuy *two*\n\n• Item", format: nil)
        #expect(MeetingMarkdownExport.notesMarkdown(notes, below: 1) == "\\# not a title\n\nBuy \\*two\\*\n\n- Item")
    }

    @Test func summariesOfThreeRecordingsWithOneOutdatedAndOneMissing() throws {
        let meeting = try Meeting(draft: MeetingDraft(title: "Planning", description: ""))
        let recordings = try ["2026-10-05T16:00:00Z", "2026-10-05T18:30:00Z", "2026-10-08T09:15:00Z"].map {
            try Recording(meetingID: meeting.id, startedAt: ISO8601DateFormatter().date(from: $0)!, timeZoneIdentifier: "UTC")
        }
        let snapshot = MeetingExportSnapshot(meeting: meeting, transcript: [], provisional: false, notes: nil, summaries: [
            .init(recording: recordings[0], number: 1, text: "## Decisions\n- Ship\n#### Deep\n```\n# code\n```", outdated: false),
            .init(recording: recordings[2], number: 3, text: "# Daily\nAll good", outdated: true),
        ], translation: nil)

        #expect(MeetingMarkdownExport.markdown(snapshot, section: .summary) == """
            # Planning - Summary

            ## Recording 1 · October 5, 2026 at 16:00

            ### Decisions
            - Ship
            ##### Deep
            ```
            # code
            ```

            ## Recording 3 · October 8, 2026 at 09:15

            _Outdated._

            ### Daily
            All good

            """)
        // Under Export All every heading moves one level further; deep ones stop at six.
        let all = MeetingMarkdownExport.markdown(all: snapshot)
        #expect(all.contains("### Recording 1 · October 5, 2026 at 16:00\n\n#### Decisions"))
        #expect(all.contains("###### Deep"))
        #expect(MeetingMarkdownExport.nested("# A\n###### B", below: 3) == "#### A\n###### B")
    }

    // MARK: Export All and file names

    @Test func exportAllOmitsEmptySectionsInOrder() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await DeletionFixture.make(folder.url, translate: false)
        try await f.store.commitNotes(NotesRevision(meetingID: f.meeting.id, text: "Remember the budget", format: .markdown))
        let snapshot = try await f.store.meetingExport(meetingID: f.meeting.id, settings: f.settings)

        let all = MeetingMarkdownExport.markdown(all: snapshot)

        #expect(all.hasPrefix("# Planning\n\nThree calls\n\n## Notes\n\nRemember the budget\n\n## Summary\n\n### Recording 1 · "))
        let notes = try #require(all.range(of: "## Notes")), summary = try #require(all.range(of: "## Summary"))
        let transcript = try #require(all.range(of: "## Transcript"))
        #expect(notes.lowerBound < summary.lowerBound && summary.lowerBound < transcript.lowerBound)
        #expect(!all.contains("## Translation"))
        #expect(all.hasSuffix("\\[15:00:05]: You - Reply 3.\n"))
    }

    @Test func titleOnlyMeetingExportsItsHeading() throws {
        let snapshot = MeetingExportSnapshot(meeting: try Meeting(draft: MeetingDraft(title: "Kickoff", description: "  ")),
            transcript: [], provisional: false, notes: NotesRevision(meetingID: UUID(), text: "\n\n", format: .markdown),
            summaries: [], translation: nil)
        #expect(MeetingMarkdownExport.markdown(all: snapshot) == "# Kickoff\n")
        #expect(MeetingMarkdownExport.markdown(snapshot, section: .notes) == nil)
    }

    @Test func fileNamesReplaceInvalidCharacters() {
        #expect(MeetingMarkdownExport.fileName(title: "Q3/Q4 planning", section: .notes) == "Q3-Q4 planning - Notes.md")
        #expect(MeetingMarkdownExport.fileName(title: "Q3/Q4 planning", section: nil) == "Q3-Q4 planning.md")
        #expect(MeetingMarkdownExport.fileName(title: "a:b\\c", section: .transcript) == "a-b-c - Transcript.md")
        #expect(MeetingMarkdownExport.fileName(title: " .. ", section: .summary) == "Meeting - Summary.md")
    }
}
