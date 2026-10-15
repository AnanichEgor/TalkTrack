import Foundation
import Testing
import TalkTrackDomain

@Suite struct NotesDocumentTests {
    typealias Run = NotesDocument.Run
    typealias Paragraph = NotesDocument.Paragraph

    @Test func blockStylesAndEmphasisRoundTrip() {
        let document = NotesDocument(paragraphs: [
            Paragraph(.title, runs: [Run("Итоги встречи")]),
            Paragraph(.heading, runs: [Run("Решения "), Run("предварительно", italic: true)]),
            Paragraph(.body, runs: [Run("Релиз "), Run("переносится", bold: true), Run(" на "), Run("ноябрь", bold: true, italic: true)]),
            Paragraph(.bullet, runs: [Run("Бюджет 42 млн")]),
            Paragraph(.task(done: false), runs: [Run("Предупредить продажи")]),
            Paragraph(.task(done: true), runs: [Run("Разослать запись")]),
            Paragraph(),
        ])
        #expect(document.markdown == """
            # Итоги встречи
            ## Решения *предварительно*
            Релиз **переносится** на ***ноябрь***
            - Бюджет 42 млн
            - [ ] Предупредить продажи
            - [x] Разослать запись

            """)
        #expect(NotesDocument(markdown: document.markdown) == document)
    }

    @Test func adjacentEmphasisAndLiteralMarkersSurvive() {
        let document = NotesDocument(paragraphs: [
            Paragraph(.body, runs: [Run("a", bold: true), Run("b", italic: true), Run("c", bold: true, italic: true), Run("d", italic: true)]),
            Paragraph(.body, runs: [Run("# not a title, 2*3*4 \\ path")]),
            Paragraph(.body, runs: [Run("- not a bullet")]),
            Paragraph(.body, runs: [Run("• not a bullet either")]),
            Paragraph(.bullet, runs: [Run("[ ] not a task")]),
        ])
        #expect(NotesDocument(markdown: document.markdown) == document)
    }

    @Test func notesWithoutFormatStayPlainText() {
        let revision = NotesRevision(meetingID: UUID(), text: "# 2*3*4\n• пункт")
        #expect(revision.document.paragraphs == [
            Paragraph(.body, runs: [Run("# 2*3*4")]),
            Paragraph(.bullet, runs: [Run("пункт")]),
        ])
        #expect(NotesRevision(meetingID: UUID(), text: "- тире\n•без пробела").document.paragraphs == [
            Paragraph(.body, runs: [Run("- тире")]),
            Paragraph(.body, runs: [Run("•без пробела")]),
        ])
        let formatted = NotesRevision(meetingID: UUID(), text: "# 2*3*4\n• пункт", format: .markdown)
        #expect(formatted.document.paragraphs == [
            Paragraph(.title, runs: [Run("2"), Run("3", italic: true), Run("4")]),
            Paragraph(.bullet, runs: [Run("пункт")]),
        ])
    }

    @Test func formatIsOmittedForPlainRevisionsAndDecodesWhenAbsent() throws {
        let plain = NotesRevision(meetingID: UUID(), text: "x", createdAt: Date(timeIntervalSince1970: 0))
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("format"))
        #expect(try JSONDecoder().decode(NotesRevision.self, from: Data(json.utf8)) == plain)
        let formatted = NotesRevision(meetingID: UUID(), text: "x", format: .markdown)
        #expect(try JSONDecoder().decode(NotesRevision.self, from: JSONEncoder().encode(formatted)).format == .markdown)
    }

    @Test func emptyNotesAreOneEmptyParagraph() {
        #expect(NotesDocument(markdown: "").paragraphs == [Paragraph()])
        #expect(NotesDocument(paragraphs: []).markdown == "")
    }
}
