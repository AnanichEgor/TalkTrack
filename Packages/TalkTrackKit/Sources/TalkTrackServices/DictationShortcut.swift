import Foundation

/// Modifier keys of a dictation shortcut, independent of AppKit/CoreGraphics.
public struct DictationModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = DictationModifiers(rawValue: 1 << 0)
    public static let option = DictationModifiers(rawValue: 1 << 1)
    public static let shift = DictationModifiers(rawValue: 1 << 2)
    public static let command = DictationModifiers(rawValue: 1 << 3)

    /// Symbols in the order macOS menus show them.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// A right-side modifier that starts dictation when pressed alone.
public enum DictationRightModifier: String, CaseIterable, Hashable, Sendable {
    case option, command, control

    public var title: String {
        switch self {
        case .option: "Right Option"
        case .command: "Right Command"
        case .control: "Right Control"
        }
    }
}

public enum DictationShortcutRefusal: Error, Equatable, Sendable {
    /// Return, Tab, Space and Escape stay available for dialogs.
    case reservedKey
    /// A plain key (or Shift only) would type text instead of starting dictation.
    case modifierRequired

    public var message: String {
        switch self {
        case .reservedKey: "Return, Tab, Space and Escape can't be used. Press a key with ⌃, ⌥ or ⌘, or a right-side modifier alone."
        case .modifierRequired: "A modifier is required: press a key with ⌃, ⌥ or ⌘, or a right-side modifier alone."
        }
    }
}

/// The global dictation shortcut: a right-side modifier alone, or a key with
/// at least one of Control, Option or Command. Shared by the event tap and the
/// Settings recorder so both accept exactly the same shortcuts.
public enum DictationShortcut: Hashable, Sendable {
    case rightModifier(DictationRightModifier)
    case key(code: UInt16, modifiers: DictationModifiers)

    public static let `default` = DictationShortcut.rightModifier(.option)

    /// macOS virtual key codes refused for dialog navigation: Return, keypad
    /// Enter, Tab, Space, Escape.
    public static let reservedKeyCodes: Set<UInt16> = [36, 76, 48, 49, 53]
    public static let escapeKeyCode: UInt16 = 53

    /// Validates a key press (not a modifier change) for use as the shortcut.
    public static func validate(keyCode: UInt16, modifiers: DictationModifiers) -> Result<DictationShortcut, DictationShortcutRefusal> {
        if reservedKeyCodes.contains(keyCode) { return .failure(.reservedKey) }
        guard !modifiers.intersection([.control, .option, .command]).isEmpty else { return .failure(.modifierRequired) }
        return .success(.key(code: keyCode, modifiers: modifiers))
    }

    /// The key of a key shortcut; nil for a right-side modifier.
    public var keyCode: UInt16? {
        if case .key(let code, _) = self { return code }
        return nil
    }

    public func displayName(keyName: (UInt16) -> String? = DictationShortcut.keyName) -> String {
        switch self {
        case .rightModifier(let modifier): modifier.title
        case .key(let code, let modifiers): modifiers.symbols + (keyName(code) ?? "Key \(code)")
        }
    }

    /// Names of keys on the ANSI layout; the app may pass the current layout's.
    public static func keyName(_ code: UInt16) -> String? {
        if let letter = letters[code] { return letter }
        if let name = named[code] { return name }
        return nil
    }

    private static let letters: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
        46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W",
        7: "X", 16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".",
        44: "/", 50: "`",
    ]
    private static let named: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖",
        119: "↘", 116: "⇞", 121: "⇟", 36: "↩", 48: "⇥", 49: "Space", 53: "⎋",
    ]

    // MARK: Storage

    /// Stored as one versioned dictionary so key and modifiers change together.
    static let storageVersion = 1

    var stored: [String: Any] {
        switch self {
        case .rightModifier(let modifier):
            ["version": Self.storageVersion, "kind": "rightModifier", "modifier": modifier.rawValue]
        case .key(let code, let modifiers):
            ["version": Self.storageVersion, "kind": "key", "keyCode": Int(code), "modifiers": modifiers.rawValue]
        }
    }

    init?(stored: Any?) {
        guard let value = stored as? [String: Any], value["version"] as? Int == Self.storageVersion else { return nil }
        switch value["kind"] as? String {
        case "rightModifier":
            guard let modifier = DictationRightModifier(rawValue: value["modifier"] as? String ?? "") else { return nil }
            self = .rightModifier(modifier)
        case "key":
            guard let code = value["keyCode"] as? Int, let raw = value["modifiers"] as? Int,
                  let key = UInt16(exactly: code), raw & ~0b1111 == 0,
                  case .success(let shortcut) = Self.validate(keyCode: key, modifiers: DictationModifiers(rawValue: raw))
            else { return nil }
            self = shortcut
        default: return nil
        }
    }
}
