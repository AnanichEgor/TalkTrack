import Foundation
import TalkTrackDomain

/// A generated summary read back into parts for display: section headings,
/// bullets, action items with their owner and deadline, and the transcript
/// times each line cites. Only the shapes the summary prompt asks for are
/// recognized (`SummaryPrompt`); anything else stays a paragraph, so no text
/// is ever lost. The stored Markdown is unchanged.
public struct SummaryDocument: Equatable, Sendable {
    public enum Block: Equatable, Sendable {
        case heading(String)
        case item(Item)
        case paragraph(String)
        /// The fixed "none noted" phrase of an empty section.
        case empty(String)
    }

    public struct Item: Equatable, Sendable {
        /// 0 for a top-level bullet, 1 for a bullet indented under it, ...
        public let level: Int
        /// nil for a plain bullet; whether it is checked for an action item.
        public let task: Bool?
        /// A leading "**Name**:" or "Name:" (a person's group or update).
        public let person: String?
        /// Inline Markdown (bold, italics) without the person, fields and times.
        public let text: String
        public let owner: String?
        public let due: String?
        /// Cited transcript times without brackets, e.g. "14:03:22".
        public let times: [String]
    }

    public let blocks: [Block]

    public init(markdown: String) {
        var blocks: [Block] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let heading = Self.heading(line) {
                blocks.append(.heading(heading))
            } else if Self.nonePhrases.contains(line) {
                blocks.append(.empty(line))
            } else if let item = Self.item(raw) {
                blocks.append(.item(item))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        self.blocks = blocks
    }

    static let nonePhrases: Set<String> = Set(OutputLanguage.allCases.map { SummaryPrompt.phrases($0).noneNoted })
    static let ownerLabels = OutputLanguage.allCases.map { SummaryPrompt.phrases($0).owner }
    static let dueLabels = OutputLanguage.allCases.map { SummaryPrompt.phrases($0).due }

    static func heading(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let text = line.drop { $0 == "#" }
        guard text.first == " " else { return nil }
        let title = text.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title.replacingOccurrences(of: "**", with: "")
    }

    static func item(_ raw: String) -> Item? {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        var line = Substring(raw.trimmingCharacters(in: .whitespaces))
        guard let marker = line.first, "-*•".contains(marker), line.dropFirst().first == " " else { return nil }
        line = line.dropFirst(2)
        var task: Bool?
        for (box, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where line.hasPrefix(box) {
            task = checked; line = line.dropFirst(box.count)
        }
        var text = String(line)
        let times = Self.times(in: text)
        text = Self.removingTimes(text)
        // Action-item fields, separated by an em or en dash.
        var owner: String?, due: String?
        let parts = text.components(separatedBy: " — ").flatMap { $0.components(separatedBy: " – ") }
        var kept: [String] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if let value = Self.field(trimmed, labels: ownerLabels) { owner = value }
            else if let value = Self.field(trimmed, labels: dueLabels) { due = value }
            else { kept.append(part) }
        }
        text = kept.joined(separator: " — ").trimmingCharacters(in: .whitespaces)
        var person: String?
        (person, text) = Self.person(text)
        return Item(level: indent / 2, task: task, person: person, text: text, owner: owner, due: due, times: times)
    }

    static func field(_ part: String, labels: [String]) -> String? {
        for label in labels {
            for prefix in [label + ":", "**\(label):**", "**\(label)**:"] where part.hasPrefix(prefix) {
                let value = part.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// "**Name**: rest", "**Name:** rest", "**Name** - rest" or a plain
    /// "Name - rest" of one or two capitalized words.
    static func person(_ text: String) -> (String?, String) {
        for separator in [" - ", " – ", " — "] {
            guard let range = text.range(of: separator) else { continue }
            let name = text[..<range.lowerBound].replacingOccurrences(of: "**", with: "")
            let words = name.split(separator: " ")
            guard (1...2).contains(words.count), name.count <= 30,
                  words.allSatisfy({ ($0.first?.isUppercase == true || $0.allSatisfy(\.isNumber)) && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." } })
            else { break }
            return (name, String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        if text.hasPrefix("**"), let close = text.range(of: "**", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex) {
            var name = String(text[text.index(text.startIndex, offsetBy: 2)..<close.lowerBound])
            var rest = text[close.upperBound...]
            if name.hasSuffix(":") { name.removeLast() } else if rest.hasPrefix(":") { rest = rest.dropFirst() } else { return (nil, text) }
            name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 40 else { return (nil, text) }
            return (name, rest.trimmingCharacters(in: .whitespaces))
        }
        return (nil, text)
    }

    /// "[14:03:22]", "(14:03)" or "(14:03:22, 14:05:10)".
    static var timePattern: Regex<(Substring, Substring)> {
        /[\[(]\s*(\d{1,2}:\d{2}(?::\d{2})?(?:\s*[,;]\s*\d{1,2}:\d{2}(?::\d{2})?)*)\s*[\])]/
    }

    static func times(in text: String) -> [String] {
        text.matches(of: timePattern).flatMap {
            $0.output.1.split(whereSeparator: { ",; ".contains($0) }).map(String.init)
        }
    }

    static func removingTimes(_ text: String) -> String {
        text.replacing(timePattern, with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: " .", with: ".").replacingOccurrences(of: " ,", with: ",")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;")))
    }
}
