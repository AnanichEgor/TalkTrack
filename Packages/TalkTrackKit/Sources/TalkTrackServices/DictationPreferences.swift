import Foundation
import TalkTrackDomain

public enum DictationMode: String, CaseIterable, Sendable {
    /// Records while the shortcut is held.
    case hold
    /// One press starts, the next press stops.
    case toggle

    public var title: String {
        switch self {
        case .hold: "Hold to Talk"
        case .toggle: "Press to Toggle"
        }
    }
}

public enum DictationSuffix: String, CaseIterable, Sendable {
    case space, none, newline

    public var text: String {
        switch self {
        case .space: " "
        case .none: ""
        case .newline: "\n"
        }
    }

    public var title: String {
        switch self {
        case .space: "Space"
        case .none: "Nothing"
        case .newline: "New Line"
        }
    }
}

/// A heard phrase and the written form that replaces it.
public struct DictationReplacement: Codable, Hashable, Sendable {
    public var heard: String
    public var written: String

    public init(heard: String, written: String) {
        self.heard = heard
        self.written = written
    }
}

/// Everything one dictation needs, read once when the shortcut is pressed so
/// changes apply to the next dictation without restarting.
public struct DictationSettings: Equatable, Sendable {
    public var enabled = true
    public var shortcut = DictationShortcut.default
    public var mode = DictationMode.hold
    public var language = MeetingLanguage.auto
    public var modelID = DictationPreferences.defaultModelID
    public var idleMinutes = 5
    public var maximumSeconds = 120
    public var suffix = DictationSuffix.space
    public var formattingCommands = false
    public var removeFillers = false
    public var terms: [String] = []
    public var replacements: [DictationReplacement] = []
    public var showWaveform = true
    public var playSounds = true
    public var muteOutput = true
    public var keepPreviousClipboard = false
    public var historyLength = 5

    public init() {}

    /// Dictionary terms as recognition context, joined in list order and capped
    /// at `DictationPreferences.contextCharacterLimit`; later terms are dropped.
    public var recognitionContext: String { termContext.text }

    /// Whether some dictionary terms do not fit into the recognition context.
    public var dropsTerms: Bool { termContext.dropped }

    private var termContext: (text: String, dropped: Bool) {
        var context = ""
        let terms = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for term in terms {
            let next = context.isEmpty ? term : context + ", " + term
            guard next.count <= DictationPreferences.contextCharacterLimit else { return (context, true) }
            context = next
        }
        return (context, false)
    }
}

/// Dictation preferences, beside `ProcessingPreferences` in the same defaults
/// domain. Invalid stored values read as defaults. Dictated audio and text are
/// never stored; dictionary terms and replacement rules are user configuration.
public enum DictationPreferences {
    public static let enabledKey = "dictationEnabled"
    public static let shortcutKey = "dictationShortcut"
    public static let modeKey = "dictationMode"
    public static let languageKey = "dictationLanguage"
    public static let modelKey = "dictationModel"
    public static let idleMinutesKey = "dictationIdleMinutes"
    public static let maximumSecondsKey = "dictationMaximumSeconds"
    public static let suffixKey = "dictationSuffix"
    public static let formattingKey = "dictationFormattingCommands"
    public static let fillersKey = "dictationRemoveFillers"
    public static let termsKey = "dictationTerms"
    public static let replacementsKey = "dictationReplacements"
    public static let waveformKey = "dictationShowWaveform"
    public static let soundsKey = "dictationPlaySounds"
    public static let muteKey = "dictationMuteOutput"
    public static let keepClipboardKey = "dictationKeepPreviousClipboard"
    public static let historyKey = "dictationHistoryLength"

    /// Catalog ids of the selectable recognition models.
    public static let defaultModelID = "live-asr"
    public static let modelIDs = ["live-asr", "final-asr"]
    public static let idleMinuteOptions = [1, 5, 15, 60]
    public static let maximumSecondsRange = 30...600
    public static let historyOptions = [0, 3, 5, 10]
    public static let contextCharacterLimit = 1_000

    public static func modelTitle(_ id: String) -> String {
        id == "final-asr" ? "Qwen3-ASR 1.7B" : "Qwen3-ASR 0.6B"
    }

    public static func modelRole(_ id: String) -> ModelRole {
        id == "final-asr" ? .finalASR : .liveASR
    }

    /// The model's row in Settings ▸ Models.
    public static func modelSettingsRow(_ id: String) -> String {
        id == "final-asr" ? "Final transcription" : "Live transcription"
    }

    public static func settings(in defaults: UserDefaults = .standard) -> DictationSettings {
        var value = DictationSettings()
        value.enabled = (defaults.object(forKey: enabledKey) as? Bool) ?? value.enabled
        value.shortcut = DictationShortcut(stored: defaults.object(forKey: shortcutKey)) ?? value.shortcut
        value.mode = DictationMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? value.mode
        value.language = MeetingLanguage(rawValue: defaults.string(forKey: languageKey) ?? "") ?? value.language
        if let id = defaults.string(forKey: modelKey), modelIDs.contains(id) { value.modelID = id }
        if let minutes = defaults.object(forKey: idleMinutesKey) as? Int, idleMinuteOptions.contains(minutes) { value.idleMinutes = minutes }
        if let seconds = defaults.object(forKey: maximumSecondsKey) as? Int, maximumSecondsRange.contains(seconds) { value.maximumSeconds = seconds }
        value.suffix = DictationSuffix(rawValue: defaults.string(forKey: suffixKey) ?? "") ?? value.suffix
        value.formattingCommands = (defaults.object(forKey: formattingKey) as? Bool) ?? value.formattingCommands
        value.removeFillers = (defaults.object(forKey: fillersKey) as? Bool) ?? value.removeFillers
        value.terms = (defaults.object(forKey: termsKey) as? [String]) ?? value.terms
        value.replacements = replacements(in: defaults)
        value.showWaveform = (defaults.object(forKey: waveformKey) as? Bool) ?? value.showWaveform
        value.playSounds = (defaults.object(forKey: soundsKey) as? Bool) ?? value.playSounds
        value.muteOutput = (defaults.object(forKey: muteKey) as? Bool) ?? value.muteOutput
        value.keepPreviousClipboard = (defaults.object(forKey: keepClipboardKey) as? Bool) ?? value.keepPreviousClipboard
        if let length = defaults.object(forKey: historyKey) as? Int, historyOptions.contains(length) { value.historyLength = length }
        return value
    }

    public static func setShortcut(_ shortcut: DictationShortcut, in defaults: UserDefaults = .standard) {
        defaults.set(shortcut.stored, forKey: shortcutKey)
    }

    public static func setReplacements(_ rules: [DictationReplacement], in defaults: UserDefaults = .standard) {
        let data = (try? JSONEncoder().encode(rules)) ?? Data("[]".utf8)
        defaults.set(String(decoding: data, as: UTF8.self), forKey: replacementsKey)
    }

    static func replacements(in defaults: UserDefaults) -> [DictationReplacement] {
        guard let text = defaults.string(forKey: replacementsKey),
              let rules = try? JSONDecoder().decode([DictationReplacement].self, from: Data(text.utf8)) else { return [] }
        return rules
    }
}
