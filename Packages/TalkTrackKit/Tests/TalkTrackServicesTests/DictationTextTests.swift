import Testing
import TalkTrackDomain
@testable import TalkTrackServices

@Suite struct DictationTextTests {
    private func settings(_ change: (inout DictationSettings) -> Void = { _ in }) -> DictationSettings {
        var value = DictationSettings()
        change(&value)
        return value
    }

    @Test func defaultsTrimAndAppendSpace() {
        #expect(DictationText.process("  Hello world. \n", settings: settings(), recognizedLanguage: "English") == "Hello world. ")
        #expect(DictationText.process(" \n ", settings: settings(), recognizedLanguage: nil) == nil)
    }

    @Test func suffixes() {
        #expect(DictationText.process("Hi", settings: settings { $0.suffix = .none }, recognizedLanguage: nil) == "Hi")
        #expect(DictationText.process("Hi", settings: settings { $0.suffix = .newline }, recognizedLanguage: nil) == "Hi\n")
    }

    @Test func replacementRules() {
        let rules = [DictationReplacement(heard: "ток трек", written: "TalkTrack"), DictationReplacement(heard: "pi", written: "π")]
        #expect(DictationText.applyReplacements("Открой ток трек", rules: rules) == "Открой TalkTrack")
        #expect(DictationText.applyReplacements("Открой Ток  Трек.", rules: rules) == "Открой TalkTrack.")
        // Whole words only.
        #expect(DictationText.applyReplacements("the pipe and pi", rules: rules) == "the pipe and π")
        // Template characters are literal; the longer rule wins.
        let money = [DictationReplacement(heard: "dollar", written: "$1"), DictationReplacement(heard: "dollar sign", written: "$")]
        #expect(DictationText.applyReplacements("a dollar sign and a dollar", rules: money) == "a $ and a $1")
        // Replacements run before formatting commands.
        let comma = [DictationReplacement(heard: "кома", written: "запятая")]
        #expect(DictationText.process("Привет кома как дела", settings: settings { $0.replacements = comma; $0.formattingCommands = true; $0.suffix = .none },
                                      recognizedLanguage: "Russian") == "Привет, как дела")
    }

    @Test func russianCommands() {
        let on = settings { $0.formattingCommands = true; $0.suffix = .none }
        #expect(DictationText.process("Привет запятая как дела вопросительный знак", settings: on, recognizedLanguage: "Russian") == "Привет, как дела?")
        // Punctuation the recognizer attached to a command is consumed.
        #expect(DictationText.process("Привет, запятая, как дела, вопросительный знак.", settings: on, recognizedLanguage: "Russian") == "Привет, как дела?")
        #expect(DictationText.applyCommands("Итак двоеточие первое точка с запятой второе точка", language: .russian) == "Итак: первое; второе.")
        #expect(DictationText.applyCommands("Первое. Новая строка. второе новый абзац третье", language: .russian) == "Первое.\nВторое\n\nТретье")
        #expect(DictationText.applyCommands("Он сказал открыть кавычки привет закрыть кавычки", language: .russian) == "Он сказал «привет»")
        #expect(DictationText.applyCommands("Ура восклицательный знак", language: .russian) == "Ура!")
        #expect(DictationText.applyCommands("Пример открыть скобку тест закрыть скобку", language: .russian) == "Пример (тест)")
    }

    @Test func englishCommands() {
        #expect(DictationText.applyCommands("Hello comma world period how are you question mark", language: .english) == "Hello, world. How are you?")
        #expect(DictationText.applyCommands("Dear Anna, new line. thanks", language: .english) == "Dear Anna,\nThanks")
        #expect(DictationText.applyCommands("She said open quote yes close quote", language: .english) == "She said “yes”")
        #expect(DictationText.applyCommands("Note colon one semicolon two", language: .english) == "Note: one; two")
    }

    @Test func otherLanguageCommandsAreNotApplied() {
        let on = settings { $0.formattingCommands = true; $0.suffix = .none }
        // "точка" spoken as a name in an English dictation stays a word.
        #expect(DictationText.process("Meet точка at noon period", settings: on, recognizedLanguage: "English") == "Meet точка at noon.")
        #expect(DictationText.process("Скажи comma дважды", settings: settings { $0.formattingCommands = true; $0.language = .russian; $0.suffix = .none },
                                      recognizedLanguage: "English") == "Скажи comma дважды")
        // Commands are off by default.
        #expect(DictationText.process("Привет запятая", settings: settings { $0.suffix = .none }, recognizedLanguage: "Russian") == "Привет запятая")
    }

    @Test func commandLanguage() {
        #expect(DictationText.commandLanguage(setting: .english, recognized: "Russian", text: "") == .english)
        #expect(DictationText.commandLanguage(setting: .auto, recognized: "Russian", text: "hello") == .russian)
        #expect(DictationText.commandLanguage(setting: .auto, recognized: nil, text: "Привет") == .russian)
        #expect(DictationText.commandLanguage(setting: .auto, recognized: nil, text: "Hello") == .english)
    }

    @Test func fillerSounds() {
        #expect(DictationText.removeFillers("Эм, я думаю, ну, это работает") == "Я думаю, ну, это работает")
        #expect(DictationText.removeFillers("I think, um, it works, uhh.") == "I think, it works.")
        #expect(DictationText.removeFillers("Hmm. Ok, э-э, мм, хорошо") == "Ok, хорошо")
        // Meaningful words and words containing filler letters stay.
        #expect(DictationText.removeFillers("Ну типа like err, umbrella, эмоции, мама") == "Ну типа like err, umbrella, эмоции, мама")
        #expect(DictationText.process("Эм, ну да", settings: settings { $0.removeFillers = true; $0.suffix = .none }, recognizedLanguage: nil) == "Ну да")
        // Off by default.
        #expect(DictationText.process("Um, yes", settings: settings { $0.suffix = .none }, recognizedLanguage: nil) == "Um, yes")
    }

    @Test func repairKeepsLineBreaks() {
        #expect(DictationText.repair("  a   b \n  c\n\nd ") == "a b\nc\n\nd")
        // Ordinary punctuation is never respaced.
        #expect(DictationText.process("Pi is 3.14, see example.com", settings: settings { $0.formattingCommands = true; $0.suffix = .none },
                                      recognizedLanguage: "English") == "Pi is 3.14, see example.com")
    }
}
