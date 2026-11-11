import Foundation
import TalkTrackDomain

/// The result of checking a file before import.
public struct SummaryTemplateCheck: Equatable, Sendable {
    /// Nil when the file has errors.
    public let file: SummaryTemplateFile?
    public let diagnostics: [SummaryTemplateDiagnostic]
    /// The existing custom template with the same name, which importing replaces.
    public let replaces: String?

    public var errors: [SummaryTemplateDiagnostic] { diagnostics.filter { $0.level == .error } }
    public var warnings: [SummaryTemplateDiagnostic] { diagnostics.filter { $0.level == .warning } }
    public var canImport: Bool { file != nil && errors.isEmpty }
}

/// Checks a template file without a model (custom-summary-templates D3, D4):
/// errors refuse the import, warnings inform.
public enum SummaryTemplateValidator {
    public static let maxSections = 12
    /// More sections than this make long summaries thin and slow; warned only.
    public static let manySections = 8
    public static let maxRules = 10
    public static let maxExplanationLength = 600
    public static let maxRuleLength = 400
    /// The estimated tokens of a template's sections, explanations and rules
    /// (UTF-8 bytes / 3). Chosen so a template left room for the recording even in
    /// 4K (removed since); with 8K, the smallest context, the room is ample. Measured with the
    /// 9B and 4B tokenizers; see docs/summaries.md.
    public static let tokenBudget = 700

    public static func validate(_ text: String, existingNames: [String] = [],
                                language: OutputLanguage = .english) -> SummaryTemplateCheck {
        let (parsed, parseDiagnostics) = SummaryTemplateFile.parse(text, keepingErrors: true)
        guard let file = parsed else { return SummaryTemplateCheck(file: nil, diagnostics: parseDiagnostics, replaces: nil) }
        var diagnostics = parseDiagnostics
        func error(_ line: Int?, _ message: String) { diagnostics.append(.init(.error, line: line, message)) }
        func warning(_ line: Int?, _ message: String) { diagnostics.append(.init(.warning, line: line, message)) }

        if file.name.count > SummaryTemplateFile.maxNameLength {
            error(file.lines.name, "\"name\" is longer than \(SummaryTemplateFile.maxNameLength) characters.")
        }
        if file.purpose.count > SummaryTemplateFile.maxPurposeLength {
            error(file.lines.purpose, "\"purpose\" is longer than \(SummaryTemplateFile.maxPurposeLength) characters.")
        }
        if file.rules.count > maxRules { error(file.lines.rules, "More than \(maxRules) rules.") }
        for (offset, rule) in file.rules.enumerated() where rule.count > maxRuleLength {
            error(file.lines.rules.map { $0 + offset + 1 }, "A rule is longer than \(maxRuleLength) characters.")
        }

        if file.sections.count > maxSections {
            error(file.sections[maxSections].line, "More than \(maxSections) sections.")
        } else if file.sections.count > manySections {
            warning(file.sections[manySections].line, "More than \(manySections) sections make summaries longer and thinner; consider merging some.")
        }
        var seen: [String: Int] = [:]
        for section in file.sections {
            let heading = section.heading
            if heading.isEmpty { error(section.line, "The heading is empty."); continue }
            if heading.contains("#") || heading.contains("**") || heading.contains("__") {
                error(section.line, "Write the heading as plain text, without \"#\" or bold marks.")
            }
            if heading.prefixMatch(of: /([-*+•]|\d+[.)])\s/) != nil {
                error(section.line, "The heading starts with a list mark or number; write it as plain text.")
            }
            if heading.count > SummaryTemplateFile.maxHeadingLength {
                error(section.line, "The heading is longer than \(SummaryTemplateFile.maxHeadingLength) characters.")
            }
            if let first = seen[heading.lowercased()] {
                error(section.line, "The heading \"\(heading)\" repeats line \(first).")
            } else { seen[heading.lowercased()] = section.line }
            if section.explanation.isEmpty {
                if SummaryTemplates.sharedGuidance(heading: heading) == nil {
                    error(section.line, "The section \"\(heading)\" has no explanation. Only Decisions, Action Items and Open Questions may have none.")
                }
            } else {
                if section.explanation.count > maxExplanationLength {
                    error(section.line, "The explanation of \"\(heading)\" is longer than \(maxExplanationLength) characters.")
                }
                if section.explanation.split(whereSeparator: \.isWhitespace).count < 4 {
                    warning(section.line, "The explanation of \"\(heading)\" is very short; say what belongs in the section.")
                }
            }
        }
        if let perPerson = file.perPerson, !file.sections.contains(where: { $0.heading == perPerson }) {
            error(file.lines.perPerson, "\"per_person\" names \"\(perPerson)\", which is not one of the section headings.")
        }

        let template = file.template()
        let tokens = estimatedTokens(template)
        if tokens > tokenBudget {
            let percent = (tokens - tokenBudget) * 100 / tokenBudget
            error(nil, "The template is too large: about \(tokens) tokens of sections, explanations and rules, \(max(percent, 1))% over the limit of \(tokenBudget). Shorten explanations or remove sections.")
        }

        // Warnings: heuristics, never blocking.
        for section in file.sections where !section.explanation.isEmpty {
            for problem in requestProblems(section.explanation) {
                warning(section.line, "The explanation of \"\(section.heading)\" \(problem)")
            }
        }
        for (offset, rule) in file.rules.enumerated() {
            let line = file.lines.rules.map { $0 + offset + 1 }
            for problem in requestProblems(rule) { warning(line, "A rule \(problem)") }
            if rule.contains(coreRepeat) {
                warning(line, "A rule repeats what TalkTrack always tells the model (accuracy, output language or time citations); it can be removed.")
            }
        }
        let cyrillic = file.sections.filter { $0.heading.contains(/\p{Script=Cyrillic}/) }.count
        let latin = file.sections.filter { !$0.heading.contains(/\p{Script=Cyrillic}/) && $0.heading.contains(/\p{Script=Latin}/) }.count
        if language == .english && cyrillic > 0 || language == .russian && latin > 0 {
            warning(nil, "Some headings are not in \(language == .russian ? "Russian" : "English"), the summary language in Settings. Headings appear exactly as written, whatever the summary language.")
        }
        let explained = file.sections.filter { $0.explanation.split(whereSeparator: \.isWhitespace).count >= 4 }
        for (i, a) in explained.enumerated() {
            for b in explained[(i + 1)...] where similar(a.explanation, b.explanation) {
                warning(b.line, "The explanations of \"\(a.heading)\" and \"\(b.heading)\" are nearly the same; the model cannot tell what goes where.")
            }
        }

        let replaces = existingNames.first { $0.compare(file.name, options: .caseInsensitive) == .orderedSame }
        let hasErrors = diagnostics.contains { $0.level == .error }
        // In file order; problems without a line (the whole file) last.
        diagnostics = diagnostics.enumerated().sorted { ($0.element.line ?? .max, $0.offset) < ($1.element.line ?? .max, $1.offset) }.map(\.element)
        return SummaryTemplateCheck(file: hasErrors ? nil : file, diagnostics: diagnostics, replaces: hasErrors ? nil : replaces)
    }

    /// The tokens a template adds to the prompt, estimated from UTF-8 bytes,
    /// as the text-server path estimates them: sections, explanations and rules.
    public static func estimatedTokens(_ template: SummaryTemplate) -> Int {
        let text = template.sections.map { "## \($0.english)\n\($0.guidance)" }.joined(separator: "\n\n")
            + "\n" + template.rules.map { "- \($0)" }.joined(separator: "\n")
        return (text.utf8.count + 2) / 3
    }

    private static func requestProblems(_ text: String) -> [String] {
        var problems: [String] = []
        if text.contains(formatRequest) {
            problems.append("asks for tables, JSON, numbering or headings; summaries are always headings with bullets, and such requests make the model break the format.")
        }
        if text.contains(timeRequest) {
            problems.append("asks to compute times or durations; the model only copies the times written in the transcript.")
        }
        if text.contains(identityRequest) {
            problems.append("asks to identify speakers; unidentified voices keep their labels (Voice1, …) and are never guessed.")
        }
        return problems
    }

    nonisolated(unsafe) private static let formatRequest =
        /(?i)\b(tables?|json|yaml|csv|numbered|numbering|sub-?headings?|headings?|h[1-6])\b|таблиц|нумер|заголов|подзаголов/
    nonisolated(unsafe) private static let timeRequest =
        /(?i)\b(duration|how long|minutes spent|time spent|calculate|compute)\b|длительност|сколько времени|сколько минут|посчита|вычисл/
    nonisolated(unsafe) private static let identityRequest =
        /(?i)\b(guess|real names?|identify (the )?speakers?|who (each )?voice\d* (is|was))\b|угада|настоящ\w* имен|определи,? кто/
    nonisolated(unsafe) private static let coreRepeat =
        /(?i)\b(do not|don't|never) (invent|make up|fabricate|hallucinate)|\bwrite (it |the summary |everything )?in (english|russian)\b|\bcite (the )?times?\b|\btime citations?\b|не (выдумыва|придумыва|сочиня)|пиши на (русском|английском)|на (русском|английском) языке|указывай время/

    /// Nearly the same words: at least 85% shared (Jaccard) after lowercasing.
    private static func similar(_ a: String, _ b: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.85
    }
}
