import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

@Suite struct DictationPreferencesTests {
    private func defaults() -> UserDefaults {
        let name = "DictationPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func freshInstallDefaults() {
        let settings = DictationPreferences.settings(in: defaults())
        #expect(settings == DictationSettings())
        #expect(settings.enabled)
        #expect(settings.shortcut == .rightModifier(.option))
        #expect(settings.mode == .hold)
        #expect(settings.language == .auto)
        #expect(settings.modelID == "live-asr")
        #expect(settings.idleMinutes == 5)
        #expect(settings.maximumSeconds == 120)
        #expect(settings.suffix == .space)
        #expect(!settings.formattingCommands && !settings.removeFillers)
        #expect(settings.showWaveform && settings.playSounds && settings.muteOutput)
        #expect(!settings.keepPreviousClipboard)
        #expect(settings.historyLength == 5)
    }

    @Test func roundTrip() {
        let store = defaults()
        store.set(false, forKey: DictationPreferences.enabledKey)
        DictationPreferences.setShortcut(.key(code: 2, modifiers: [.control, .option]), in: store)
        store.set("toggle", forKey: DictationPreferences.modeKey)
        store.set("russian", forKey: DictationPreferences.languageKey)
        store.set("final-asr", forKey: DictationPreferences.modelKey)
        store.set(15, forKey: DictationPreferences.idleMinutesKey)
        store.set(600, forKey: DictationPreferences.maximumSecondsKey)
        store.set("newline", forKey: DictationPreferences.suffixKey)
        store.set(true, forKey: DictationPreferences.formattingKey)
        store.set(true, forKey: DictationPreferences.fillersKey)
        store.set(["TalkTrack", "Qwen"], forKey: DictationPreferences.termsKey)
        DictationPreferences.setReplacements([DictationReplacement(heard: "ток трек", written: "TalkTrack")], in: store)
        store.set(false, forKey: DictationPreferences.waveformKey)
        store.set(false, forKey: DictationPreferences.soundsKey)
        store.set(false, forKey: DictationPreferences.muteKey)
        store.set(true, forKey: DictationPreferences.keepClipboardKey)
        store.set(0, forKey: DictationPreferences.historyKey)

        let settings = DictationPreferences.settings(in: store)
        #expect(!settings.enabled)
        #expect(settings.shortcut == .key(code: 2, modifiers: [.control, .option]))
        #expect(settings.mode == .toggle && settings.language == .russian && settings.modelID == "final-asr")
        #expect(settings.idleMinutes == 15 && settings.maximumSeconds == 600 && settings.suffix == .newline)
        #expect(settings.formattingCommands && settings.removeFillers)
        #expect(settings.terms == ["TalkTrack", "Qwen"])
        #expect(settings.replacements == [DictationReplacement(heard: "ток трек", written: "TalkTrack")])
        #expect(!settings.showWaveform && !settings.playSounds && !settings.muteOutput)
        #expect(settings.keepPreviousClipboard && settings.historyLength == 0)
    }

    @Test func invalidStoredValuesFallBack() {
        let store = defaults()
        store.set("sometimes", forKey: DictationPreferences.modeKey)
        store.set("french", forKey: DictationPreferences.languageKey)
        store.set("text", forKey: DictationPreferences.modelKey)
        store.set(7, forKey: DictationPreferences.idleMinutesKey)
        store.set(10, forKey: DictationPreferences.maximumSecondsKey)
        store.set("tab", forKey: DictationPreferences.suffixKey)
        store.set("yes", forKey: DictationPreferences.formattingKey)
        store.set("{not json", forKey: DictationPreferences.replacementsKey)
        store.set(4, forKey: DictationPreferences.historyKey)
        store.set("TalkTrack", forKey: DictationPreferences.termsKey)
        // A plain key, a reserved key, an unknown version and a wrong type.
        for stored: Any in [["version": 1, "kind": "key", "keyCode": 2, "modifiers": 0],
                            ["version": 1, "kind": "key", "keyCode": 53, "modifiers": 1],
                            ["version": 2, "kind": "rightModifier", "modifier": "command"],
                            "rightOption"] {
            store.set(stored, forKey: DictationPreferences.shortcutKey)
            #expect(DictationPreferences.settings(in: store) == DictationSettings())
        }
    }

    @Test func shortcutBindingIsAtomic() {
        let store = defaults()
        DictationPreferences.setShortcut(.key(code: 2, modifiers: [.control, .option]), in: store)
        DictationPreferences.setShortcut(.rightModifier(.command), in: store)
        #expect(DictationPreferences.settings(in: store).shortcut == .rightModifier(.command))
        // One stored value holds key and modifiers together.
        let stored = store.dictionary(forKey: DictationPreferences.shortcutKey)
        #expect(stored?["kind"] as? String == "rightModifier")
        #expect(stored?["keyCode"] == nil)
        DictationPreferences.setShortcut(.key(code: 2, modifiers: [.command]), in: store)
        #expect(DictationPreferences.settings(in: store).shortcut == .key(code: 2, modifiers: [.command]))
    }

    @Test func recognitionContextIsCapped() {
        var settings = DictationSettings()
        settings.terms = ["TalkTrack", "  ", "Qwen3-ASR"]
        #expect(settings.recognitionContext == "TalkTrack, Qwen3-ASR")
        #expect(!settings.dropsTerms)
        settings.terms = (0..<200).map { "term\($0)" }
        #expect(settings.recognitionContext.count <= DictationPreferences.contextCharacterLimit)
        #expect(settings.recognitionContext.hasPrefix("term0, term1, "))
        #expect(settings.dropsTerms)
    }
}
