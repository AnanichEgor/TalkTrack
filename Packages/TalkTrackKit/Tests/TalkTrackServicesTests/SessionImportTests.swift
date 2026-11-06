import Compression
import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// Teams transcript parsing and start times (import-teams-session tasks 1.1–1.3).
@Suite struct SessionImportTests {
    static func seconds(_ value: Double) -> MediaTime { try! MediaTime(seconds: value) }

    // MARK: VTT (1.1)

    @Test func vttKeepsVoicesStartsEndsAndText() throws {
        let text = """
        WEBVTT

        3c3f1a2b-1/12-0
        00:00:05.120 --> 00:00:07.480
        <v Mark Davis>Okay, great.</v>

        3c3f1a2b-2/12-0
        00:00:07.900 --> 00:01:02.000
        <v Ana Lee>First line
        second line &amp; more.</v>

        NOTE a comment block

        00:01:03.000 --> 00:01:04.500
        No voice here.

        1:02:03.250 --> 1:02:04.000
        <v.loud Mark Davis>Late reply</v>
        """
        let transcript = try TeamsTranscriptParser.vtt(Data(text.utf8), file: "a.vtt")
        #expect(transcript.format == .vtt)
        #expect(transcript.replies.map(\.name) == ["Mark Davis", "Ana Lee", nil, "Mark Davis"])
        #expect(transcript.replies[0].start == Self.seconds(5.12) && transcript.replies[0].end == Self.seconds(7.48))
        #expect(transcript.replies[1].text == "First line second line & more.")
        #expect(transcript.replies[2].text == "No voice here.")
        #expect(transcript.replies[3].start == Self.seconds(3723.25))
        #expect(transcript.names == ["Mark Davis", "Ana Lee"])
    }

    @Test func vttSortsUnsortedCuesAndHandlesCRLF() throws {
        let text = "\u{FEFF}WEBVTT\r\n\r\n00:00:09.000 --> 00:00:10.000\r\n<v B>second</v>\r\n\r\n00:00:01.000 --> 00:00:02.000\r\n<v A>first</v>\r\n"
        let transcript = try TeamsTranscriptParser.vtt(Data(text.utf8), file: "a.vtt")
        #expect(transcript.replies.map(\.text) == ["first", "second"])
    }

    @Test func nonVTTTextIsRefused() {
        #expect(throws: SessionImportError.notTranscript("notes.vtt")) {
            try TeamsTranscriptParser.vtt(Data("Just some notes\n00:00:01.000 --> 00:00:02.000\nhi".utf8), file: "notes.vtt")
        }
        #expect(throws: SessionImportError.noReplies("empty.vtt")) {
            try TeamsTranscriptParser.vtt(Data("WEBVTT\n\nNOTE nothing\n".utf8), file: "empty.vtt")
        }
    }

    // MARK: DOCX (1.2)

    /// The run structure of the real Teams export (title, start, length, status
    /// line, avatar drawing, bold name after a break, time run, text runs each
    /// after a break), with invented text.
    static func teamsDocumentXML(replies: [(String, String, [String])], header: [String] = [
        "Weekly Sync-20261027_150444-Meeting Recording", "October 27, 2026, 2:04PM", "27m 33s",
    ]) -> String {
        let props = #"<w:rPr><w:color w:val="605e5c"/><w:sz w:val="3mm"/></w:rPr>"#
        let bold = #"<w:rPr><w:b/><w:bCs/><w:color w:val="605e5c"/></w:rPr>"#
        let drawing = #"<w:r><w:drawing><wp:anchor><wp:docPr id="1" name="" descr=""/><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rId6"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r>"#
        var body = header.map { #"<w:p><w:pPr><w:spacing w:after="100"/></w:pPr><w:r>\#(props)<w:t xml:space="preserve">\#($0)</w:t></w:r></w:p>"# }.joined()
        func status(_ name: String, _ text: String) -> String {
            #"<w:p>\#(drawing)<w:r>\#(bold)<w:br/><w:t xml:space="preserve">\#(name) </w:t></w:r><w:r>\#(props)<w:t xml:space="preserve">\#(text)</w:t></w:r></w:p>"#
        }
        body += status(replies.first?.0 ?? "Someone", "started transcription")
        for (name, time, lines) in replies {
            body += #"<w:p><w:pPr><w:spacing w:line="300"/></w:pPr>\#(drawing)<w:r>\#(bold)<w:br/><w:t xml:space="preserve">\#(name)   </w:t></w:r><w:r>\#(props)<w:t xml:space="preserve">\#(time)</w:t></w:r>"#
            body += lines.map { #"<w:r><w:rPr><w:color w:val="323130"/></w:rPr><w:br/><w:t xml:space="preserve">\#($0)</w:t></w:r>"# }.joined()
            body += "</w:p>"
        }
        body += status(replies.first?.0 ?? "Someone", "stopped transcription")
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\#(body)<w:sectPr/></w:body></w:document>"#
    }

    static let sampleReplies: [(String, String, [String])] = [
        ("Ana Lee", "0:05", ["Yep, everything is working."]),
        ("Mark Davis", "0:06", ["Okay, great. Let's start.", "Primary subscriptions are partner content only.", "We use one distributor."]),
        ("Ana Lee", "0:40", ["Mhm."]),
        ("Mark Davis", "1:02:04", ["Bye &amp; thanks."]),
    ]

    @Test func teamsDocxGivesNamesTimesAndSplitText() throws {
        let data = Self.zip(["[Content_Types].xml": Data("<Types/>".utf8),
                             "word/document.xml": Data(Self.teamsDocumentXML(replies: Self.sampleReplies).utf8)])
        let transcript = try TeamsTranscriptParser.docx(data, file: "t.docx")
        #expect(transcript.format == .docx)
        #expect(transcript.replies.map(\.name) == ["Ana Lee", "Mark Davis", "Ana Lee", "Mark Davis"])
        #expect(transcript.replies.map(\.start) == [5, 6, 40, 3724].map { Self.seconds($0) })
        // The time run and the text run join as `0:05Yep` in plain text; runs keep them apart.
        #expect(transcript.replies[0].text == "Yep, everything is working.")
        #expect(transcript.replies[1].text == "Okay, great. Let's start. Primary subscriptions are partner content only. We use one distributor.")
        #expect(transcript.replies[3].text == "Bye & thanks.")
        #expect(transcript.title == "Weekly Sync-20261027_150444-Meeting Recording")
        #expect(transcript.duration == Self.seconds(27 * 60 + 33))
        let expected = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                      year: 2026, month: 10, day: 27, hour: 14, minute: 4).date
        #expect(transcript.start == expected)
    }

    @Test func storedEntriesAndBoldOffAreRead() throws {
        let xml = Self.teamsDocumentXML(replies: [("Ana Lee", "0:05", ["Hi."])])
            .replacingOccurrences(of: "<w:t xml:space=\"preserve\">27m 33s</w:t>", with: "<w:t>27m 33s</w:t>")
        let data = Self.zip(["word/document.xml": Data(xml.utf8)], deflate: false)
        #expect(try TeamsTranscriptParser.docx(data, file: "t.docx").replies.count == 1)
        let notBold = Self.teamsDocumentXML(replies: [("Ana Lee", "0:05", ["Hi."])]).replacingOccurrences(of: "<w:b/>", with: "<w:b w:val=\"0\"/>")
        #expect(throws: SessionImportError.notTranscript("t.docx")) {
            try TeamsTranscriptParser.docx(Self.zip(["word/document.xml": Data(notBold.utf8)]), file: "t.docx")
        }
    }

    @Test func ordinaryDamagedAndOversizedDocumentsAreRefused() throws {
        let ordinary = #"<?xml version="1.0"?><w:document xmlns:w="w"><w:body><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Agenda</w:t></w:r></w:p><w:p><w:r><w:t>Discuss the budget at 10:30.</w:t></w:r></w:p></w:body></w:document>"#
        #expect(throws: SessionImportError.notTranscript("letter.docx")) {
            try TeamsTranscriptParser.docx(Self.zip(["word/document.xml": Data(ordinary.utf8)]), file: "letter.docx")
        }
        #expect(throws: SessionImportError.notTranscript("sheet.docx")) {
            try TeamsTranscriptParser.docx(Self.zip(["xl/workbook.xml": Data("<x/>".utf8)]), file: "sheet.docx")
        }
        var damaged = Self.zip(["word/document.xml": Data(Self.teamsDocumentXML(replies: Self.sampleReplies).utf8)])
        damaged.replaceSubrange(40..<80, with: Data(repeating: 0x55, count: 40))
        #expect(throws: SessionImportError.damaged("cut.docx")) { try TeamsTranscriptParser.docx(damaged, file: "cut.docx") }
        #expect(throws: SessionImportError.damaged("half.docx")) {
            try TeamsTranscriptParser.docx(Data(damaged.prefix(damaged.count / 2)), file: "half.docx")
        }

        let folder = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = folder.appending(path: "big.docx")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(TeamsTranscriptParser.maximumBytes + 1)); try handle.close()
        #expect(throws: SessionImportError.transcriptTooLarge("big.docx")) { try TeamsTranscriptParser.load(big) }
        let pdf = folder.appending(path: "notes.pdf")
        try Data("%PDF".utf8).write(to: pdf)
        #expect(throws: SessionImportError.notTranscript("notes.pdf")) { try TeamsTranscriptParser.load(pdf) }
    }

    /// The real export in `tmp/`, when present (local only, not in the repository).
    @Test func realTeamsDocxWhenPresent() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "tmp/AI Assistant_ ISO distributors Q&A.docx")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let transcript = try TeamsTranscriptParser.load(url)
        #expect(transcript.names.sorted() == ["Aliaksandra Trykhminava", "Mark Davis"])
        #expect(transcript.replies.count == 101, "\(transcript.replies.count)")
        #expect(transcript.replies.first?.text == "Yep, everything is working.")
        #expect(transcript.replies.first?.start == Self.seconds(5))
        #expect(transcript.replies.last?.start == Self.seconds(27 * 60 + 32))
        try transcript.validate(audioDuration: Self.seconds(27 * 60 + 34), file: "t")
    }

    @Test func transcriptMustFitTheAudio() throws {
        let transcript = TeamsTranscript(format: .docx, title: nil, start: nil, duration: nil, replies: [
            ImportedReply(name: "A", start: Self.seconds(10), text: "a"), ImportedReply(name: "B", start: Self.seconds(45 * 60), text: "b"),
        ])
        #expect(throws: SessionImportError.transcriptLonger("t.docx")) {
            try transcript.validate(audioDuration: Self.seconds(27 * 60), file: "t.docx")
        }
        try transcript.validate(audioDuration: Self.seconds(45 * 60 - 1.5), file: "t.docx")
        let intervals = transcript.intervals(audioDuration: Self.seconds(45 * 60 - 1.5))
        #expect(intervals.map(\.interval.start) == [Self.seconds(10), Self.seconds(45 * 60 - 1.7)])
        // A one-word DOCX reply lasts its estimate (1 s + 0.5 s per word), not up to the next reply.
        #expect(intervals[0].interval.end == Self.seconds(11.5))
        #expect(intervals[1].interval.end == Self.seconds(45 * 60 - 1.5))
        let monologue = TeamsTranscript(format: .docx, title: nil, start: nil, duration: nil, replies: [
            ImportedReply(name: "A", start: Self.seconds(0), text: Array(repeating: "word", count: 100).joined(separator: " ")),
            ImportedReply(name: "B", start: Self.seconds(20), text: "Mhm."),
            ImportedReply(name: "A", start: Self.seconds(44), text: "And so on."),
        ]).intervals(audioDuration: Self.seconds(60))
        // A long reply still ends at the next one; the interjection does not take the monologue after it.
        #expect(monologue.map(\.interval.end) == [Self.seconds(20), Self.seconds(21.5), Self.seconds(46.5)])
        let long = TeamsTranscript(format: .docx, title: nil, start: nil, duration: Self.seconds(40 * 60), replies: [
            ImportedReply(name: "A", start: Self.seconds(10), text: "a"),
        ])
        #expect(throws: SessionImportError.transcriptLonger("t.docx")) { try long.validate(audioDuration: Self.seconds(27 * 60), file: "t.docx") }
    }

    // MARK: Start time (1.3)

    @Test func startTimeSourcesInOrder() throws {
        let zone = TimeZone(identifier: "Europe/Warsaw")!
        func date(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
            DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: zone, year: 2026, month: 10, day: 27, hour: h, minute: m, second: s).date!
        }
        let header = ImportStartTime.headerDate("October 27, 2026, 2:04PM", timeZone: zone)
        #expect(header == date(14, 4))
        #expect(ImportStartTime.headerDate("October 27, 2026, 2:04 PM", timeZone: zone) == date(14, 4))
        let transcript = TeamsTranscript(format: .docx, title: nil, start: header, duration: nil, replies: [])
        let name = "AI Assistant ISO distributors Q_A-20261027_150444-Meeting Recording.mp4"
        let modified = date(18, 0), metadata = date(9, 30)

        let fromTranscript = ImportStartTime.resolve(transcript: transcript, fileName: name, metadataDate: metadata, modificationDate: modified, timeZone: zone)
        #expect(fromTranscript == ImportStartTime(date: date(14, 4), source: .transcript) && fromTranscript.label == "From the transcript")
        let fromName = ImportStartTime.resolve(transcript: nil, fileName: name, metadataDate: metadata, modificationDate: modified, timeZone: zone)
        #expect(fromName == ImportStartTime(date: date(15, 4, 44), source: .fileName) && fromName.label == "From the file name")
        let fromMetadata = ImportStartTime.resolve(transcript: nil, fileName: "call.m4a", metadataDate: metadata, modificationDate: modified, timeZone: zone)
        #expect(fromMetadata.source == .metadata && fromMetadata.date == metadata && fromMetadata.label == "From the file’s recording date")
        let fromModified = ImportStartTime.resolve(transcript: nil, fileName: "call.m4a", metadataDate: nil, modificationDate: modified, timeZone: zone)
        #expect(fromModified.source == .modificationDate && fromModified.date == modified && fromModified.label == "From the file’s modification date")
    }

    @Test func suggestedTitles() {
        #expect(TeamsTranscriptParser.suggestedTitle("AI Assistant ISO distributors Q_A-20261027_150444-Meeting Recording.mp4") == "AI Assistant ISO distributors Q_A")
        #expect(TeamsTranscriptParser.suggestedTitle("AI Assistant_ ISO distributors Q&A.docx") == "AI Assistant_ ISO distributors Q&A")
        #expect(TeamsTranscriptParser.suggestedTitle("standup.m4a") == "standup")
    }

    // MARK: ZIP writer for fixtures

    static func zip(_ files: [String: Data], deflate: Bool = true) -> Data {
        var archive = Data(), central = Data()
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) { Data($0) } }
        for (name, content) in files.sorted(by: { $0.key < $1.key }) {
            var payload = content, method = 0
            if deflate, !content.isEmpty {
                var buffer = [UInt8](repeating: 0, count: content.count + 1024)
                let size = content.withUnsafeBytes { compression_encode_buffer(&buffer, buffer.count, $0.bindMemory(to: UInt8.self).baseAddress!, content.count, nil, COMPRESSION_ZLIB) }
                payload = Data(buffer.prefix(size)); method = 8
            }
            let offset = archive.count, nameData = Data(name.utf8)
            let local: [Data] = [le32(0x0403_4b50), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                                 le32(payload.count), le32(content.count), le16(nameData.count), le16(0), nameData, payload]
            let entry: [Data] = [le32(0x0201_4b50), le16(20), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                                 le32(payload.count), le32(content.count), le16(nameData.count), le16(0), le16(0), le16(0), le16(0),
                                 le32(0), le32(offset), nameData]
            for part in local { archive.append(part) }
            for part in entry { central.append(part) }
        }
        let start = archive.count
        archive.append(central)
        let end: [Data] = [le32(0x0605_4b50), le16(0), le16(0), le16(files.count), le16(files.count), le32(central.count), le32(start), le16(0)]
        for part in end { archive.append(part) }
        return archive
    }
}
