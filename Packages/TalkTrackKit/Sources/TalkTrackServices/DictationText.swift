import Foundation
import TalkTrackDomain

/// Deterministic text processing between recognition and insertion:
/// trim → replacement rules → spoken formatting commands → filler-sound
/// removal → spacing/punctuation repair → suffix. No language model is
/// involved, so each rule has one auditable result.
public enum DictationText {
    public enum CommandLanguage: Sendable, Equatable {
        case english, russian
    }

    /// Text to insert, or nil when nothing was recognized.
    public static func process(_ recognized: String, settings: DictationSettings, recognizedLanguage: String?) -> String? {
        var text = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = applyReplacements(text, rules: settings.replacements)
        if settings.formattingCommands {
            text = applyCommands(text, language: commandLanguage(setting: settings.language, recognized: recognizedLanguage, text: text))
        }
        if settings.removeFillers { text = removeFillers(text) }
        text = repair(text)
        guard !text.isEmpty else { return nil }
        return text + settings.suffix.text
    }

    /// The fixed language when one is chosen; under Auto the recognized one,
    /// or the script of the text when the model named none.
    public static func commandLanguage(setting: MeetingLanguage, recognized: String?, text: String) -> CommandLanguage {
        switch setting {
        case .english: return .english
        case .russian: return .russian
        case .auto:
            switch recognized?.lowercased() {
            case "russian": return .russian
            case "english": return .english
            default:
                let cyrillic = text.unicodeScalars.filter { (0x0400...0x04FF).contains($0.value) }.count
                let latin = text.unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
                return cyrillic > latin ? .russian : .english
            }
        }
    }

    // MARK: Replacement rules

    /// Whole words, case-insensitive, longest heard phrase first so a longer
    /// rule wins over one contained in it.
    public static func applyReplacements(_ text: String, rules: [DictationReplacement]) -> String {
        var result = text
        let ordered = rules.filter { !$0.heard.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.heard.count > $1.heard.count }
        for rule in ordered {
            guard let regex = wordRegex(phrases: [rule.heard]) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.written))
        }
        return result
    }

    // MARK: Spoken formatting commands

    private struct Command {
        let phrases: [String]
        let replacement: String
        /// Punctuation marks replace a mark the model put just before the command.
        var punctuation: Bool { replacement.count == 1 && ",.?!:;".contains(replacement) }
        /// The next word starts a sentence or line.
        var capitalizesNext: Bool { [".", "?", "!", "\n", "\n\n"].contains(replacement) }
    }

    // Longer phrases first: "точка с запятой" before "точка".
    private static let english: [Command] = [
        Command(phrases: ["new paragraph"], replacement: "\n\n"),
        Command(phrases: ["new line"], replacement: "\n"),
        Command(phrases: ["open quote", "open quotes"], replacement: "“"),
        Command(phrases: ["close quote", "close quotes", "end quote", "unquote"], replacement: "”"),
        Command(phrases: ["open parenthesis", "open parentheses", "open bracket"], replacement: "("),
        Command(phrases: ["close parenthesis", "close parentheses", "close bracket"], replacement: ")"),
        Command(phrases: ["question mark"], replacement: "?"),
        Command(phrases: ["exclamation mark", "exclamation point"], replacement: "!"),
        Command(phrases: ["semicolon"], replacement: ";"),
        Command(phrases: ["colon"], replacement: ":"),
        Command(phrases: ["full stop", "period"], replacement: "."),
        Command(phrases: ["comma"], replacement: ","),
    ]
    private static let russian: [Command] = [
        Command(phrases: ["новый абзац", "новый параграф"], replacement: "\n\n"),
        Command(phrases: ["новая строка", "новую строку", "с новой строки"], replacement: "\n"),
        Command(phrases: ["открыть кавычки", "открыть кавычку", "открывающая кавычка", "кавычки открываются"], replacement: "«"),
        Command(phrases: ["закрыть кавычки", "закрыть кавычку", "закрывающая кавычка", "кавычки закрываются"], replacement: "»"),
        Command(phrases: ["открыть скобку", "открывающая скобка", "скобка открывается"], replacement: "("),
        Command(phrases: ["закрыть скобку", "закрывающая скобка", "скобка закрывается"], replacement: ")"),
        Command(phrases: ["вопросительный знак"], replacement: "?"),
        Command(phrases: ["восклицательный знак"], replacement: "!"),
        Command(phrases: ["точка с запятой"], replacement: ";"),
        Command(phrases: ["двоеточие"], replacement: ":"),
        Command(phrases: ["точка"], replacement: "."),
        Command(phrases: ["запятая"], replacement: ","),
    ]

    /// Marks the position after a command that ends a sentence or line.
    private static let capitalMarker = "\u{E000}"

    public static func applyCommands(_ text: String, language: CommandLanguage) -> String {
        var result = text
        var applied = false
        for command in language == .russian ? russian : english {
            // The recognizer often punctuates a spoken command ("запятая,",
            // "new line."); that punctuation belongs to the command.
            let before = command.punctuation ? #"(?:[\p{Zs}\t]*[,.;:])?[\p{Zs}\t]*"# : ""
            guard let regex = wordRegex(phrases: command.phrases, prefix: before, suffix: #"[.,;:!?]?"#) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            guard regex.firstMatch(in: result, range: range) != nil else { continue }
            let replacement = (command.punctuation ? "" : " ") + command.replacement + (command.capitalizesNext ? capitalMarker : "")
            result = regex.stringByReplacingMatches(in: result, range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
            applied = true
        }
        guard applied else { return text }
        result = replace(result, #"[\p{Zs}\t]*\n[\p{Zs}\t]*"#, "\n")
        result = replace(result, #"\n{3,}"#, "\n\n")
        result = replace(result, #"([“«(])[\p{Zs}\t]+"#, "$1")
        result = replace(result, #"[\p{Zs}\t]+([”»)])"#, "$1")
        result = replace(result, #"[\p{Zs}\t]+([,.;:!?])"#, "$1")
        return repair(capitalizingAfterMarkers(result))
    }

    private static func capitalizingAfterMarkers(_ text: String) -> String {
        var output = ""
        var capitalizeNext = false
        for character in text {
            if String(character) == capitalMarker { capitalizeNext = true; continue }
            if capitalizeNext, character.isLetter {
                output += character.uppercased()
                capitalizeNext = false
            } else {
                if capitalizeNext, !(character.isWhitespace || "«“(\"".contains(character)) { capitalizeNext = false }
                output.append(character)
            }
        }
        return output
    }

    // MARK: Filler sounds

    /// Hesitation sounds only. Words with meaning ("ну", "типа", "like", "you
    /// know") are never removed. "er"/"erm" take no repeat so "err" survives.
    private static let fillers = ["um+", "uh+", "er", "erm", "hm+", "э+м*", "э+(?:-э+)+", "м{2,}", "хм+"]

    public static func removeFillers(_ text: String) -> String {
        let pattern = #"(?i)(?<![\p{L}\p{N}'\-])(?:"# + fillers.joined(separator: "|") + #")(?![\p{L}\p{N}'\-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        // A removed capitalized filler that started a sentence passes its capital on.
        let capitalize = matches.contains { match in
            guard let range = Range(match.range, in: text), text[range].first?.isUppercase == true else { return false }
            return startsSentence(text, at: range.lowerBound)
        }
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let range = Range(match.range, in: text)!
            mutable.replaceCharacters(in: match.range, with: startsSentence(text, at: range.lowerBound) && capitalize ? capitalMarker : "")
        }
        var result = mutable as String
        result = replace(result, #"[\p{Zs}\t]*,(?:[\p{Zs}\t]*,)+"#, ",")
        result = replace(result, #"([.!?])[\p{Zs}\t]+[,;:]+"#, "$1")
        result = replace(result, "(^|\n)(" + capitalMarker + #")?[\p{Zs}\t]*[,;:.!?]+"#, "$1$2")
        result = replace(result, capitalMarker + #"[\p{Zs}\t]*[,;:]+"#, capitalMarker)
        result = replace(result, #"[\p{Zs}\t]+([,.;:!?])"#, "$1")
        result = replace(result, #",+([.!?;:])"#, "$1")
        return repair(capitalizingAfterMarkers(result))
    }

    private static func startsSentence(_ text: String, at index: String.Index) -> Bool {
        var position = index
        while position > text.startIndex {
            let previous = text.index(before: position)
            let character = text[previous]
            if character == "\n" { return true }
            if character.isWhitespace || "«“(\"".contains(character) { position = previous; continue }
            return ".!?".contains(character)
        }
        return true
    }

    // MARK: Repair

    /// Horizontal whitespace collapsed, no spaces around line breaks, trimmed.
    public static func repair(_ text: String) -> String {
        var result = text.replacingOccurrences(of: capitalMarker, with: "")
        result = replace(result, #"[\p{Zs}\t]+"#, " ")
        result = replace(result, #" *\n *"#, "\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    /// Whole-word, case-insensitive match of any phrase; spaces in a phrase
    /// match any horizontal whitespace.
    private static func wordRegex(phrases: [String], prefix: String = "", suffix: String = "") -> NSRegularExpression? {
        let alternatives = phrases.map { phrase in
            phrase.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"[\p{Zs}\t]+"#)
        }.joined(separator: "|")
        let pattern = prefix + #"(?<![\p{L}\p{N}_])(?:"# + alternatives + #")(?![\p{L}\p{N}_])"# + suffix
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
