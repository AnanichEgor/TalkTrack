import Foundation

/// How a notes revision's text is written. Revisions saved before the
/// formatted editor have no format and are plain text.
public enum NotesFormat: String, Codable, Sendable {
    case markdown
}

/// Formatted meeting notes: paragraphs with a block style and bold/italic
/// runs. Stored as a small Markdown subset — `# ` title, `## ` heading,
/// `- ` bullet, `- [ ] ` / `- [x] ` checklist item, `**bold**`, `*italic*` —
/// so the saved text stays readable outside TalkTrack.
public struct NotesDocument: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case title, heading, body, bullet
        case task(done: Bool)

        public var isList: Bool {
            switch self {
            case .bullet, .task: true
            case .title, .heading, .body: false
            }
        }
    }

    public struct Run: Equatable, Sendable {
        public var text: String
        public var bold: Bool
        public var italic: Bool

        public init(_ text: String, bold: Bool = false, italic: Bool = false) {
            self.text = text
            self.bold = bold
            self.italic = italic
        }
    }

    public struct Paragraph: Equatable, Sendable {
        public var style: Style
        public var runs: [Run]

        public init(_ style: Style = .body, runs: [Run] = []) {
            self.style = style
            self.runs = runs
        }

        public var text: String { runs.map(\.text).joined() }
    }

    public var paragraphs: [Paragraph]

    public init(paragraphs: [Paragraph]) {
        self.paragraphs = paragraphs.isEmpty ? [Paragraph()] : paragraphs
    }

    /// Loads a revision's text according to its format.
    public init(text: String, format: NotesFormat?) {
        switch format {
        case .markdown: self.init(markdown: text)
        case nil: self.init(plainText: text)
        }
    }

    /// Text written before formatting existed: asterisks and hashes stay
    /// literal; only lines typed with a `• ` bullet become list items.
    public init(plainText: String) {
        self.init(paragraphs: Self.lines(plainText).map { line in
            if line.hasPrefix("• ") { return Paragraph(.bullet, runs: [Run(String(line.dropFirst(2)))].filter { !$0.text.isEmpty }) }
            return Paragraph(.body, runs: line.isEmpty ? [] : [Run(line)])
        })
    }

    public init(markdown: String) {
        self.init(paragraphs: Self.lines(markdown).map(Self.paragraph))
    }

    public var markdown: String {
        paragraphs.map { paragraph in
            let prefix = switch paragraph.style {
            case .title: "# "
            case .heading: "## "
            case .body: ""
            case .bullet: "- "
            case .task(let done): done ? "- [x] " : "- [ ] "
            }
            // Headings are bold by their style, so only italic is written.
            let heading = paragraph.style == .title || paragraph.style == .heading
            var inline = Self.merged(paragraph.runs).map { run in
                let text = Self.escaped(run.text)
                return switch (run.bold && !heading, run.italic) {
                case (true, true): "***\(text)***"
                case (true, false): "**\(text)**"
                case (false, true): "*\(text)*"
                case (false, false): text
                }
            }.joined()
            // A body line must not be read back as a block marker.
            if paragraph.style == .body, let first = inline.first, first == "#" || first == "-" || first == "•" {
                inline = "\\" + inline
            } else if paragraph.style == .bullet, inline.hasPrefix("[") {
                inline = "\\" + inline
            }
            return prefix + inline
        }.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    private static func paragraph(_ line: String) -> Paragraph {
        let blocks: [(String, Style)] = [
            ("# ", .title), ("## ", .heading),
            ("- [ ] ", .task(done: false)), ("- [x] ", .task(done: true)), ("- [X] ", .task(done: true)),
            ("* [ ] ", .task(done: false)), ("* [x] ", .task(done: true)),
            ("- ", .bullet), ("* ", .bullet), ("• ", .bullet),
        ]
        for (marker, style) in blocks where line.hasPrefix(marker) {
            var runs = inline(String(line.dropFirst(marker.count)))
            if style == .title || style == .heading { runs = runs.map { Run($0.text, italic: $0.italic) } }
            return Paragraph(style, runs: merged(runs))
        }
        return Paragraph(.body, runs: merged(inline(line)))
    }

    /// Asterisk runs toggle emphasis: `***` both, `**` bold, `*` italic;
    /// a backslash makes the next character literal.
    private static func inline(_ text: String) -> [Run] {
        var runs: [Run] = []
        var current = ""
        var bold = false, italic = false
        var characters = Array(text)[...]
        func flush() {
            if !current.isEmpty { runs.append(Run(current, bold: bold, italic: italic)) }
            current = ""
        }
        while let character = characters.popFirst() {
            if character == "\\", let next = characters.popFirst() {
                current.append(next)
            } else if character == "*" {
                var count = 1
                while characters.first == "*" { characters.removeFirst(); count += 1 }
                flush()
                // Read greedily as `***` groups, then `**` or `*`; toggles commute,
                // so `**a***b*` closes bold and opens italic.
                if (count / 3) % 2 == 1 { bold.toggle(); italic.toggle() }
                if count % 3 == 2 { bold.toggle() }
                if count % 3 == 1 { italic.toggle() }
            } else {
                current.append(character)
            }
        }
        flush()
        return runs
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*")
    }

    private static func merged(_ runs: [Run]) -> [Run] {
        runs.reduce(into: []) { result, run in
            guard !run.text.isEmpty else { return }
            if let last = result.last, last.bold == run.bold, last.italic == run.italic {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
    }
}
