import Foundation
import TalkTrackDomain

/// One problem found in a template file. Errors refuse the import; warnings
/// are shown in the confirmation and never block (custom-summary-templates D3).
public struct SummaryTemplateDiagnostic: Equatable, Sendable {
    public enum Level: String, Equatable, Sendable { case error, warning }
    public let level: Level
    /// 1-based line in the file as the user has it; nil for the file as a whole.
    public let line: Int?
    public let message: String

    public init(_ level: Level, line: Int?, _ message: String) {
        self.level = level; self.line = line; self.message = message
    }

    /// "Line 9: …" or the message alone.
    public var text: String { line.map { "Line \($0): \(message)" } ?? message }
}

/// A summary template file (custom-summary-templates D2):
///
///     ---
///     name: Sprint Retro
///     purpose: What went well and what to change
///     rules:
///       - Group items by team.
///     per_person: Updates by Person
///     ---
///     ## What Went Well
///     Successes the team named, one bullet each.
///
/// Only this small subset of YAML is accepted; there is no YAML dependency.
public struct SummaryTemplateFile: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public let heading: String
        /// Empty for a bare shared heading (Decisions, Action Items, Open Questions).
        public let explanation: String
        public let line: Int
    }

    public let name: String
    public let purpose: String
    public let rules: [String]
    public let perPerson: String?
    public let sections: [Section]

    /// The front matter keys, in the order Export writes them.
    public static let keys = ["name", "purpose", "rules", "per_person"]
    public static let maxNameLength = 60
    public static let maxHeadingLength = 60
    public static let maxPurposeLength = 160

    /// The prompt template: the file's sections and rules over the current
    /// prompt core. Headings are used as written in either output language;
    /// a bare shared heading takes the built-in section's current guidance.
    public func template(version: String = SummaryTemplates.currentVersion) -> SummaryTemplate {
        let sections = sections.map { section in
            SummaryTemplate.Section(english: section.heading, russian: section.heading,
                guidance: section.explanation.isEmpty ? SummaryTemplates.sharedGuidance(heading: section.heading) ?? "" : section.explanation)
        }
        var rules = rules
        if let perPerson {
            let rule = Self.perPersonRule(perPerson)
            if !rules.contains(rule) && !rules.contains(SummaryTemplates.standupSubstance) { rules.append(rule) }
        }
        return SummaryTemplate(type: .custom, version: version, title: name, purpose: purpose,
                               icon: CustomSummaryTemplate.icon, sections: sections, rules: rules, perPersonHeading: perPerson)
    }

    /// Standup's rule for its per-person section, naming this template's section.
    static func perPersonRule(_ heading: String) -> String {
        SummaryTemplates.standupSubstance.replacingOccurrences(of: "Updates by Person", with: heading)
    }

    // MARK: Parsing

    /// Parses `text` and reports format errors with their lines. Content
    /// checks (limits, warnings) are `SummaryTemplateValidator`'s.
    public static func parse(_ text: String) -> (file: SummaryTemplateFile?, diagnostics: [SummaryTemplateDiagnostic]) {
        parse(text, keepingErrors: false)
    }

    /// `keepingErrors` returns what was read despite line errors (unless the
    /// header is unreadable), so validation can report every problem at once.
    static func parse(_ text: String, keepingErrors: Bool) -> (file: SummaryTemplateFile?, diagnostics: [SummaryTemplateDiagnostic]) {
        var diagnostics: [SummaryTemplateDiagnostic] = []
        func error(_ line: Int?, _ message: String) { diagnostics.append(.init(.error, line: line, message)) }

        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        // (line number, text) pairs, so diagnostics name the user's lines.
        var lines = normalized.components(separatedBy: "\n").enumerated().map { (number: $0.offset + 1, text: $0.element) }
        // An AI assistant may wrap its whole answer in one code fence.
        let filled = lines.indices.filter { !lines[$0].text.trimmingCharacters(in: .whitespaces).isEmpty }
        if let first = filled.first, let last = filled.last, first < last,
           lines[first].text.trimmingCharacters(in: .whitespaces).wholeMatch(of: /(```|~~~)[\w-]*/) != nil,
           ["```", "~~~"].contains(lines[last].text.trimmingCharacters(in: .whitespaces)) {
            lines = Array(lines[(first + 1)..<last])
        }

        var index = lines.startIndex
        while index < lines.endIndex, lines[index].text.trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        guard index < lines.endIndex else {
            error(nil, "The file is empty.")
            return (nil, diagnostics)
        }
        guard lines[index].text.trimmingCharacters(in: .whitespaces) == "---" else {
            error(lines[index].number, "The file must start with the header line \"---\"; remove any text before it.")
            return (nil, diagnostics)
        }
        let open = lines[index].number
        index += 1

        // Front matter.
        var values: [String: (line: Int, value: String)] = [:]
        var rules: [String] = []
        var listKey: String?
        var closed = false
        while index < lines.endIndex {
            let (number, raw) = lines[index]
            index += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---" { closed = true; break }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("- ") || line == "-" {
                guard listKey == "rules" else { error(number, "A list item must follow \"rules:\"."); continue }
                let item = unquote(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces))
                if item.isEmpty { error(number, "A rule is empty.") } else { rules.append(item) }
                values["rules"] = values["rules"] ?? (number, "")
                continue
            }
            listKey = nil
            guard let colon = line.firstIndex(of: ":") else {
                error(number, "Expected \"key: value\" in the header.")
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = unquote(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            guard keys.contains(key) else {
                let hint = closestKey(key).map { " Did you mean \"\($0)\"?" } ?? ""
                error(number, "Unknown header field \"\(key)\".\(hint) Allowed: \(keys.joined(separator: ", ")).")
                continue
            }
            guard values[key] == nil else { error(number, "\"\(key)\" appears more than once."); continue }
            if key == "rules" {
                if !value.isEmpty && value != "[]" { error(number, "Write each rule on its own line starting with \"  - \" below \"rules:\".") }
                listKey = "rules"
            }
            values[key] = (number, value)
        }
        guard closed else {
            error(open, "The header is not closed: add a line \"---\" after its last field.")
            return (nil, diagnostics)
        }
        let headerEnd = index > lines.startIndex ? lines[index - 1].number : open

        let name = values["name"]?.value ?? ""
        if values["name"] == nil { error(open, "The header has no \"name\".") }
        else if name.isEmpty { error(values["name"]!.line, "\"name\" is empty.") }

        // Sections.
        var sections: [Section] = []
        var heading: (line: Int, text: String)?
        var body: [String] = []
        func closeSection() {
            guard let current = heading else { return }
            while body.last?.isEmpty == true { body.removeLast() }
            sections.append(Section(heading: current.text, explanation: body.joined(separator: "\n"), line: current.line))
            heading = nil; body = []
        }
        while index < lines.endIndex {
            let (number, raw) = lines[index]
            index += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") || line == "##" {
                closeSection()
                heading = (number, String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continue
            }
            guard heading != nil else {
                if !line.isEmpty {
                    error(number, line.hasPrefix("#") ? "Section headings start with \"## \" (two #)."
                                                      : "Text before the first section; every section starts with \"## Heading\".")
                }
                continue
            }
            if line.hasPrefix("#") {
                error(number, "A line in an explanation starts with \"#\"; sections use \"## \" and explanations have no headings.")
                continue
            }
            if line.isEmpty && body.isEmpty { continue }
            body.append(line)
        }
        closeSection()
        if sections.isEmpty && !diagnostics.contains(where: { $0.level == .error && ($0.line ?? 0) > headerEnd }) {
            error(nil, "The template has no sections. Add at least one \"## Heading\" with its explanation.")
        }

        guard keepingErrors || !diagnostics.contains(where: { $0.level == .error }) else { return (nil, diagnostics) }
        let perPerson = values["per_person"]?.value
        return (SummaryTemplateFile(name: name, purpose: values["purpose"]?.value ?? "", rules: rules,
                                    perPerson: perPerson?.isEmpty == true ? nil : perPerson, sections: sections,
                                    lines: Lines(name: values["name"]?.line, purpose: values["purpose"]?.line,
                                                 rules: values["rules"]?.line, perPerson: values["per_person"]?.line)),
                diagnostics)
    }

    /// Where the header fields were, for the validator's messages.
    struct Lines: Equatable, Sendable {
        var name, purpose, rules, perPerson: Int?
    }
    let lines: Lines

    init(name: String, purpose: String, rules: [String], perPerson: String?, sections: [Section], lines: Lines = Lines()) {
        self.name = name; self.purpose = purpose; self.rules = rules; self.perPerson = perPerson
        self.sections = sections; self.lines = lines
    }

    private static func unquote(_ value: String) -> String {
        for quote in ["\"", "'"] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// The allowed key a typo most likely meant (at most two edits away).
    static func closestKey(_ key: String) -> String? {
        let key = key.lowercased()
        return keys.map { ($0, distance(key, $0)) }.filter { $0.1 <= 2 }.min { $0.1 < $1.1 }?.0
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = min(above + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }

    // MARK: Export

    /// The file for `template`: a custom template as imported, a built-in type
    /// with its headings in `language`, as a starting point for a new template.
    public static func render(_ template: SummaryTemplate, language: OutputLanguage) -> String {
        var lines = ["---", "name: \(quoted(template.title))"]
        if !template.purpose.isEmpty { lines.append("purpose: \(quoted(template.purpose))") }
        let perPerson = template.perPersonSection
        let perPersonRule = perPerson.map { perPersonRule($0.title(language)) }
        // A custom template's added per-person rule is implied by `per_person`.
        let rules = template.type == .custom ? template.rules.filter { $0 != perPersonRule } : template.rules
        if !rules.isEmpty {
            lines.append("rules:")
            lines += rules.map { "  - \(quoted($0))" }
        }
        if let perPerson { lines.append("per_person: \(quoted(perPerson.title(language)))") }
        lines.append("---")
        for section in template.sections {
            lines.append("")
            lines.append("## \(section.title(language))")
            lines.append(section.guidance)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes a value the parser would otherwise unquote.
    private static func quoted(_ value: String) -> String {
        let quotes: Set<Character> = ["\"", "'"]
        guard let first = value.first, let last = value.last, value.count >= 2,
              quotes.contains(first), first == last else { return value }
        return "\"\(value)\""
    }
}

/// The guide and example template bundled with TalkTrack, in English only
/// (custom-summary-templates D9). Download Guide & Example… saves them.
public enum SummaryTemplateGuide {
    public static let guideFileName = "TalkTrack Summary Template Guide.md"
    public static let exampleFileName = "Example Template.md"

    public static var guideText: String? { text(guideFileName) }
    public static var exampleText: String? { text(exampleFileName) }

    private static func text(_ fileName: String) -> String? {
        let name = (fileName as NSString).deletingPathExtension
        guard let url = Bundle.module.url(forResource: name, withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
