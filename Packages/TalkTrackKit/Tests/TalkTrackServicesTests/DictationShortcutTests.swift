import Testing
@testable import TalkTrackServices

@Suite struct DictationShortcutTests {
    @Test func freshInstallUsesRightOption() {
        #expect(DictationShortcut.default == .rightModifier(.option))
        #expect(DictationShortcut.default.displayName() == "Right Option")
    }

    @Test func keyWithModifiersIsAccepted() throws {
        // Control-Option-D
        let shortcut = try DictationShortcut.validate(keyCode: 2, modifiers: [.control, .option]).get()
        #expect(shortcut == .key(code: 2, modifiers: [.control, .option]))
        #expect(shortcut.displayName() == "⌃⌥D")
        #expect(try DictationShortcut.validate(keyCode: 122, modifiers: [.command, .shift]).get().displayName() == "⇧⌘F1")
    }

    @Test func plainKeysNeedAModifier() {
        #expect(DictationShortcut.validate(keyCode: 2, modifiers: []) == .failure(.modifierRequired))
        // Shift alone types a capital letter.
        #expect(DictationShortcut.validate(keyCode: 2, modifiers: [.shift]) == .failure(.modifierRequired))
        #expect(DictationShortcut.validate(keyCode: 122, modifiers: []) == .failure(.modifierRequired))
    }

    @Test func dialogKeysAreRefused() {
        for code: UInt16 in [36, 76, 48, 49, 53] {
            #expect(DictationShortcut.validate(keyCode: code, modifiers: []) == .failure(.reservedKey))
            #expect(DictationShortcut.validate(keyCode: code, modifiers: [.command, .option]) == .failure(.reservedKey))
        }
        #expect(DictationShortcutRefusal.modifierRequired.message.contains("modifier is required"))
    }

    @Test func rightModifierNames() {
        #expect(DictationShortcut.rightModifier(.command).displayName() == "Right Command")
        #expect(DictationShortcut.rightModifier(.control).displayName() == "Right Control")
        #expect(DictationShortcut.rightModifier(.control).keyCode == nil)
    }

    @Test func storageRoundTrip() {
        for shortcut: DictationShortcut in [.rightModifier(.option), .rightModifier(.command), .rightModifier(.control),
                                            .key(code: 2, modifiers: [.control, .option]), .key(code: 122, modifiers: [.command, .shift])] {
            #expect(DictationShortcut(stored: shortcut.stored) == shortcut)
        }
        #expect(DictationShortcut.key(code: 99, modifiers: [.option]).displayName(keyName: { _ in "Ж" }) == "⌥Ж")
    }
}
