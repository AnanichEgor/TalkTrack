import Compression
import Foundation
import TalkTrackDomain

/// One reply of an imported transcript (import-teams-session D3). A nil name
/// is a VTT cue without a voice: the day's `Unidentified` speaker.
public struct ImportedReply: Equatable, Sendable {
    public let name: String?
    public let start: MediaTime
    /// VTT cue end; a DOCX reply ends where the next one starts.
    public let end: MediaTime?
    public let text: String

    public init(name: String?, start: MediaTime, end: MediaTime? = nil, text: String) {
        self.name = name; self.start = start; self.end = end; self.text = text
    }
}

public enum TranscriptFileFormat: String, Codable, Sendable { case docx, vtt }

public struct TeamsTranscript: Equatable, Sendable {
    public let format: TranscriptFileFormat
    /// Header of a DOCX: the meeting title, start and length.
    public let title: String?
    public let start: Date?
    public let duration: MediaTime?
    public let replies: [ImportedReply]

    public var names: [String] {
        var seen: Set<String> = [], result: [String] = []
        for name in replies.compactMap(\.name) where seen.insert(name).inserted { result.append(name) }
        return result
    }

    /// Refuses a transcript that does not fit audio of `duration` (spec: a
    /// reply starting more than 2 s after the end, or a longer DOCX header).
    public func validate(audioDuration duration: MediaTime, file: String) throws {
        let limit = duration.microseconds + 2_000_000
        if replies.contains(where: { $0.start.microseconds > limit }) || (self.duration.map { $0.microseconds > limit } ?? false) {
            throw SessionImportError.transcriptLonger(file)
        }
    }

    /// Longest a DOCX reply (which has no end) is assumed to last: one second
    /// plus half a second per word, a slow speaking rate. Without it a short
    /// interjection such as "Mhm" inside a monologue would own the speech up to
    /// the next reply, and naming and voice learning would take the other voice.
    static func estimatedLength(_ text: String) -> Int64 {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return 1_000_000 + Int64(words) * 500_000
    }

    /// Replies with intervals on audio of `duration`: a DOCX reply ends at the
    /// next reply's start or after its estimated length, whichever is first;
    /// every end is clipped to the audio, and no interval is empty.
    public func intervals(audioDuration duration: MediaTime) -> [(reply: ImportedReply, interval: MediaInterval)] {
        let total = duration.microseconds, minimum: Int64 = 200_000
        let starts = replies.map { min($0.start.microseconds, max(0, total - minimum)) }
        return replies.enumerated().compactMap { index, reply in
            let start = starts[index]
            let next = starts[(index + 1)...].first { $0 > start }
            var end = reply.end?.microseconds ?? min(next ?? total, start + Self.estimatedLength(reply.text))
            end = min(max(end, start + minimum), total)
            guard end > start, let interval = try? MediaInterval(start: MediaTime(microseconds: start), end: MediaTime(microseconds: end)) else { return nil }
            return (reply, interval)
        }
    }
}

public enum SessionImportError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat(String), noAudio(String), protected(String), unreadable(String), damaged(String)
    case notTranscript(String), noReplies(String), transcriptLonger(String), transcriptTooLarge(String)
    case recordingMeeting, busy, missingTitle

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let file): "“\(file)” is in a format TalkTrack can’t import."
        case .noAudio(let file): "“\(file)” contains no audio."
        case .protected(let file): "“\(file)” is copy-protected."
        case .unreadable(let file): "“\(file)” can’t be opened."
        case .damaged(let file): "“\(file)” is damaged."
        case .notTranscript(let file): "“\(file)” is not a recognized Teams transcript."
        case .noReplies(let file): "“\(file)” contains no replies."
        case .transcriptLonger(let file): "The transcript “\(file)” is longer than the audio."
        case .transcriptTooLarge(let file): "“\(file)” is too large to be a transcript."
        case .recordingMeeting: "This meeting is recording."
        case .busy: "Another import is in progress."
        case .missingTitle: "The new meeting needs a title."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedFormat: "Choose an MP4, M4V, MOV, M4A, AAC, MP3, WAV, AIFF or CAF file."
        case .noAudio, .protected: "Choose a file with a readable audio track."
        case .unreadable, .damaged: "Download or export the file again and import the new copy."
        case .notTranscript, .noReplies: "Choose the DOCX or VTT transcript downloaded from Teams, or import without a transcript."
        case .transcriptLonger: "Check that the transcript belongs to this recording."
        case .transcriptTooLarge: "Choose the DOCX or VTT transcript downloaded from Teams."
        case .recordingMeeting: "Stop recording first, or import into another meeting."
        case .busy: "Wait for it to finish or cancel it."
        case .missingTitle: "Enter a title."
        }
    }
}

public enum TeamsTranscriptParser {
    static let maximumBytes = 20 * 1_024 * 1_024

    public static func load(_ url: URL) throws -> TeamsTranscript {
        let file = url.lastPathComponent
        let format: TranscriptFileFormat
        switch url.pathExtension.lowercased() {
        case "docx": format = .docx
        case "vtt": format = .vtt
        default: throw SessionImportError.notTranscript(file)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumBytes else { throw SessionImportError.transcriptTooLarge(file) }
        guard let data = try? Data(contentsOf: url) else { throw SessionImportError.unreadable(file) }
        guard data.count <= maximumBytes else { throw SessionImportError.transcriptTooLarge(file) }
        return format == .vtt ? try vtt(data, file: file) : try docx(data, file: file)
    }

    // MARK: VTT

    public static func vtt(_ data: Data, file: String) throws -> TeamsTranscript {
        guard var text = String(data: data, encoding: .utf8) else { throw SessionImportError.notTranscript(file) }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first == "WEBVTT" || first.hasPrefix("WEBVTT ") || first.hasPrefix("WEBVTT\t") else {
            throw SessionImportError.notTranscript(file)
        }
        var replies: [ImportedReply] = []
        var block: [String] = []
        func flush() {
            defer { block = [] }
            guard let timing = block.firstIndex(where: { $0.contains("-->") }) else { return }
            let parts = block[timing].components(separatedBy: "-->")
            guard parts.count == 2, let start = vttTime(parts[0]),
                  let end = vttTime(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "") else { return }
            var name: String?
            var words: [String] = []
            for line in block[(timing + 1)...] {
                if name == nil, let voice = vttVoice(line) { name = voice }
                let plain = stripTags(line).trimmingCharacters(in: .whitespaces)
                if !plain.isEmpty { words.append(plain) }
            }
            let joined = collapse(words.joined(separator: " "))
            guard !joined.isEmpty else { return }
            replies.append(ImportedReply(name: name, start: start, end: max(end, start), text: decodeEntities(joined)))
        }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { block.append(line) }
        }
        flush()
        guard !replies.isEmpty else { throw SessionImportError.noReplies(file) }
        let sorted = replies.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        return TeamsTranscript(format: .vtt, title: nil, start: nil, duration: nil, replies: sorted)
    }

    static func vttTime(_ raw: String) -> MediaTime? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let main = value.split(separator: ".", maxSplits: 1)
        guard main.count == 2, main[1].count == 3, let millis = Int64(main[1]) else { return nil }
        let fields = main[0].split(separator: ":").map { Int64($0) }
        guard fields.count == 2 || fields.count == 3, fields.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = fields.map { $0! }
        let hours = numbers.count == 3 ? numbers[0] : 0
        let minutes = numbers[numbers.count - 2], seconds = numbers[numbers.count - 1]
        guard minutes < 60, seconds < 60, hours >= 0 else { return nil }
        return try? MediaTime(microseconds: ((hours * 3600 + minutes * 60 + seconds) * 1000 + millis) * 1000)
    }

    static func vttVoice(_ line: String) -> String? {
        guard let open = line.range(of: "<v") else { return nil }
        let rest = line[open.upperBound...]
        guard let first = rest.first, first == " " || first == "." || first == "\t",
              let close = rest.firstIndex(of: ">") else { return nil }
        var inner = rest[..<close]
        if inner.first == "." { inner = inner.drop { $0 != " " && $0 != "\t" } }
        let name = collapse(decodeEntities(String(inner)))
        return name.isEmpty ? nil : name
    }

    static func stripTags(_ line: String) -> String {
        var result = "", inTag = false
        for character in line {
            if character == "<" { inTag = true } else if character == ">" && inTag { inTag = false } else if !inTag { result.append(character) }
        }
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: DOCX

    struct Run: Equatable { var bold: Bool; var breakBefore: Bool; var text: String }

    public static func docx(_ data: Data, file: String) throws -> TeamsTranscript {
        let archive: ZipArchive
        do { archive = try ZipArchive(data) } catch { throw SessionImportError.damaged(file) }
        guard archive.contains("word/document.xml") else { throw SessionImportError.notTranscript(file) }
        let xml: Data
        do { xml = try archive.extract("word/document.xml", maximum: 64 * 1_024 * 1_024) } catch { throw SessionImportError.damaged(file) }
        guard let paragraphs = DocumentRuns.parse(xml) else { throw SessionImportError.damaged(file) }
        return try transcript(paragraphs, file: file)
    }

    static func transcript(_ paragraphs: [[Run]], file: String) throws -> TeamsTranscript {
        var replies: [ImportedReply] = []
        var header: [String] = []
        var statusLines = 0
        for paragraph in paragraphs {
            let runs = paragraph.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if runs.count >= 2, runs[0].bold, let time = docxTime(runs[1].text) {
                let name = collapse(runs[0].text)
                var text = ""
                for run in runs.dropFirst(2) {
                    if run.breakBefore && !text.isEmpty { text += " " }
                    text += run.text
                }
                let reply = collapse(text)
                if !name.isEmpty, !reply.isEmpty { replies.append(ImportedReply(name: name, start: time, text: reply)) }
                continue
            }
            if runs.count >= 2, runs[0].bold, ["started transcription", "stopped transcription"].contains(collapse(runs[1].text).lowercased()) {
                statusLines += 1; continue
            }
            if replies.isEmpty {
                let line = collapse(runs.map(\.text).joined())
                if !line.isEmpty { header.append(line) }
            }
        }
        guard !replies.isEmpty else {
            throw statusLines > 0 ? SessionImportError.noReplies(file) : SessionImportError.notTranscript(file)
        }
        let sorted = replies.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        let start = header.lazy.compactMap { ImportStartTime.headerDate($0) }.first
        let duration = header.lazy.compactMap { docxDuration($0) }.first
        let title = header.first { ImportStartTime.headerDate($0) == nil && docxDuration($0) == nil }
        return TeamsTranscript(format: .docx, title: title, start: start, duration: duration, replies: sorted)
    }

    /// `m:ss` or `h:mm:ss`, the whole run.
    static func docxTime(_ raw: String) -> MediaTime? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              fields.dropFirst().allSatisfy({ $0.count == 2 }) else { return nil }
        let numbers = fields.compactMap { Int64($0) }
        guard numbers.count == fields.count, numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        let seconds = numbers.reduce(0) { $0 * 60 + $1 }
        return try? MediaTime(microseconds: seconds * 1_000_000)
    }

    /// `27m 33s`, `1h 2m 3s`, `45s`.
    static func docxDuration(_ raw: String) -> MediaTime? {
        let parts = raw.split(separator: " ")
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var seconds: Int64 = 0, lastUnit = 4
        for part in parts {
            guard let unit = part.last, let index = ["s", "m", "h"].firstIndex(of: String(unit)), index < lastUnit,
                  let value = Int64(part.dropLast()), value >= 0 else { return nil }
            seconds += value * [1, 60, 3600][index]; lastUnit = index
        }
        return try? MediaTime(microseconds: seconds * 1_000_000)
    }

    /// A meeting title from a Teams title or file name, without the
    /// `-yyyyMMdd_HHmmss-Meeting Recording` suffix and extension.
    public static func suggestedTitle(_ raw: String) -> String {
        var title = raw
        for suffix in [".mp4", ".m4v", ".mov", ".m4a", ".aac", ".mp3", ".wav", ".aiff", ".aif", ".caf", ".docx", ".vtt"]
        where title.lowercased().hasSuffix(suffix) { title = String(title.dropLast(suffix.count)) }
        if let range = title.range(of: #"-\d{8}_\d{6}-.*$"#, options: .regularExpression) { title.removeSubrange(range) }
        for suffix in ["Meeting Recording", "Meeting Transcript", "Transcript"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        return collapse(title.trimmingCharacters(in: CharacterSet(charactersIn: " -_")))
    }
}

/// `word/document.xml` as paragraphs of runs, keeping bold and line breaks.
final class DocumentRuns: NSObject, XMLParserDelegate {
    private var paragraphs: [[TeamsTranscriptParser.Run]] = []
    private var paragraph: [TeamsTranscriptParser.Run]?
    private var run: TeamsTranscriptParser.Run?
    private var inProperties = false, inText = false, pendingBreak = false

    static func parse(_ data: Data) -> [[TeamsTranscriptParser.Run]]? {
        let delegate = DocumentRuns()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.paragraphs
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch element {
        case "w:p": paragraph = []; pendingBreak = false
        case "w:r": run = TeamsTranscriptParser.Run(bold: false, breakBefore: pendingBreak, text: ""); pendingBreak = false
        case "w:rPr": inProperties = true
        case "w:b" where inProperties:
            let value = attributes["w:val"]?.lowercased()
            run?.bold = value == nil || !(value == "0" || value == "false" || value == "off")
        case "w:t": inText = true
        case "w:br", "w:cr":
            // A break before any text belongs to this run; after text, it starts
            // a new segment with the same formatting.
            guard let current = run else { pendingBreak = true; break }
            if current.text.isEmpty { run?.breakBefore = true } else {
                paragraph?.append(current)
                run = TeamsTranscriptParser.Run(bold: current.bold, breakBefore: true, text: "")
            }
        case "w:tab": run?.text += " "
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "w:rPr": inProperties = false
        case "w:t": inText = false
        case "w:r": endRun()
        case "w:p":
            endRun()
            if let paragraph { paragraphs.append(paragraph) }
            paragraph = nil
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { run?.text += string }
    }

    private func endRun() {
        guard let current = run else { return }
        if !current.text.isEmpty { paragraph?.append(current) } else if current.breakBefore { pendingBreak = true }
        run = nil
    }
}

/// The few ZIP features a DOCX uses: the central directory, stored and
/// deflated entries. ZIP64, encryption and multi-disk archives are refused.
struct ZipArchive {
    struct Entry { let method: UInt16; let compressedSize: Int; let size: Int; let offset: Int; let flags: UInt16 }
    enum ZipError: Error { case damaged, unsupported, tooLarge, missing }
    private let data: Data
    private var entries: [String: Entry] = [:]

    init(_ data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipError.damaged }
        var end = -1
        var index = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while index >= lowest {
            if Self.u32(bytes, index) == 0x0605_4b50 { end = index; break }
            index -= 1
        }
        guard end >= 0 else { throw ZipError.damaged }
        let count = Int(Self.u16(bytes, end + 10)), size = Int(Self.u32(bytes, end + 12)), start = Int(Self.u32(bytes, end + 16))
        guard Self.u16(bytes, end + 4) == 0, Self.u16(bytes, end + 6) == 0, count != 0xFFFF, start != 0xFFFF_FFFF else { throw ZipError.unsupported }
        guard start + size <= end else { throw ZipError.damaged }
        var position = start
        for _ in 0..<count {
            guard position + 46 <= end, Self.u32(bytes, position) == 0x0201_4b50 else { throw ZipError.damaged }
            let flags = Self.u16(bytes, position + 8), method = Self.u16(bytes, position + 10)
            let compressed = Int(Self.u32(bytes, position + 20)), plain = Int(Self.u32(bytes, position + 24))
            let nameLength = Int(Self.u16(bytes, position + 28)), extra = Int(Self.u16(bytes, position + 30)), comment = Int(Self.u16(bytes, position + 32))
            let offset = Int(Self.u32(bytes, position + 42))
            guard position + 46 + nameLength <= end else { throw ZipError.damaged }
            let name = String(decoding: bytes[(position + 46)..<(position + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(method: method, compressedSize: compressed, size: plain, offset: offset, flags: flags)
            position += 46 + nameLength + extra + comment
        }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    func extract(_ name: String, maximum: Int) throws -> Data {
        guard let entry = entries[name] else { throw ZipError.missing }
        guard entry.flags & 1 == 0 else { throw ZipError.unsupported }
        guard entry.size <= maximum else { throw ZipError.tooLarge }
        let bytes = data
        guard entry.offset + 30 <= bytes.count, Self.u32(bytes, entry.offset) == 0x0403_4b50 else { throw ZipError.damaged }
        let start = entry.offset + 30 + Int(Self.u16(bytes, entry.offset + 26)) + Int(Self.u16(bytes, entry.offset + 28))
        guard start + entry.compressedSize <= bytes.count else { throw ZipError.damaged }
        let payload = bytes.subdata(in: (bytes.startIndex + start)..<(bytes.startIndex + start + entry.compressedSize))
        switch entry.method {
        case 0:
            guard payload.count == entry.size else { throw ZipError.damaged }
            return payload
        case 8:
            guard entry.size > 0 else { return Data() }
            var output = Data(count: entry.size + 1)
            let written = output.withUnsafeMutableBytes { target in
                payload.withUnsafeBytes { source in
                    compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, entry.size + 1,
                                              source.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw ZipError.damaged }
            return output.prefix(written)
        default: throw ZipError.unsupported
        }
    }

    private static func u16<C: RandomAccessCollection>(_ bytes: C, _ at: Int) -> UInt16 where C.Element == UInt8, C.Index == Int {
        let base = bytes.startIndex + at
        return UInt16(bytes[base]) | UInt16(bytes[base + 1]) << 8
    }
    private static func u32<C: RandomAccessCollection>(_ bytes: C, _ at: Int) -> UInt32 where C.Element == UInt8, C.Index == Int {
        let base = bytes.startIndex + at
        return UInt32(bytes[base]) | UInt32(bytes[base + 1]) << 8 | UInt32(bytes[base + 2]) << 16 | UInt32(bytes[base + 3]) << 24
    }
}

/// The prefilled start of an imported recording and where it came from (D5).
public struct ImportStartTime: Equatable, Sendable {
    public enum Source: String, Sendable { case transcript, fileName, metadata, modificationDate }
    public let date: Date
    public let source: Source

    public var label: String {
        switch source {
        case .transcript: "From the transcript"
        case .fileName: "From the file name"
        case .metadata: "From the file’s recording date"
        case .modificationDate: "From the file’s modification date"
        }
    }

    public static func resolve(transcript: TeamsTranscript?, fileName: String, metadataDate: Date?, modificationDate: Date,
                               timeZone: TimeZone = .current) -> ImportStartTime {
        if let date = transcript?.start { return ImportStartTime(date: date, source: .transcript) }
        if let date = fileNameDate(fileName, timeZone: timeZone) { return ImportStartTime(date: date, source: .fileName) }
        if let metadataDate { return ImportStartTime(date: metadataDate, source: .metadata) }
        return ImportStartTime(date: modificationDate, source: .modificationDate)
    }

    /// `October 27, 2026, 2:04PM` (Teams DOCX header), with or without the space before AM/PM.
    public static func headerDate(_ line: String, timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["MMMM d, yyyy, h:mma", "MMMM d, yyyy, h:mm a", "MMMM d, yyyy h:mma", "MMMM d, yyyy h:mm a"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: line.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }

    /// The Teams recording name pattern `-yyyyMMdd_HHmmss-`.
    public static func fileNameDate(_ name: String, timeZone: TimeZone = .current) -> Date? {
        guard let range = name.range(of: #"-\d{8}_\d{6}-"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.date(from: String(name[range].dropFirst().dropLast()))
    }
}
