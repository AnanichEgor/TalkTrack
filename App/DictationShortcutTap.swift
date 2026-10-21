import AppKit
import Carbon.HIToolbox
import TalkTrackServices

/// The global dictation shortcut: a session event tap at head insertion on
/// the main run loop. Only the configured key shortcut is suppressed, and
/// Escape only while a dictation is active; everything else passes through.
/// Right-side modifiers are recognized from `flagsChanged` by their device
/// flags and are passed through, so other apps never see a stuck modifier.
@MainActor final class DictationShortcutTap {
    var shortcut = DictationShortcut.default
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// Returns whether a dictation was active (Escape is then suppressed).
    var onEscape: () -> Bool = { false }
    /// While Settings records a new shortcut, every event passes through.
    var paused = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = false
    private var listenOnly = false

    var isRunning: Bool { tap != nil }

    /// Returns false when macOS refused the tap (permission missing or not yet
    /// effective). Without Accessibility only a listening tap is possible: the
    /// shortcut is observed (to explain the missing permission) but not suppressed.
    @discardableResult
    func start(listenOnly: Bool) -> Bool {
        if let tap, listenOnly == self.listenOnly { CGEvent.tapEnable(tap: tap, enable: true); return true }
        stop()
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: listenOnly ? .listenOnly : .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<DictationShortcutTap>.fromOpaque(info).takeUnretainedValue()
                let suppress = MainActor.assumeIsolated { listener.handle(type, event) }
                return suppress ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        self.listenOnly = listenOnly
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        if held { held = false; onRelease() }
    }

    /// Constant work only: the callback enqueues and returns.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A release may have been lost while the tap was disabled.
            if held { held = false; onRelease() }
            return false
        }
        guard !paused else { return false }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            if code == UInt16(kVK_Escape), !event.flags.containsShortcutModifiers { return onEscape() }
            guard case .key(let key, let modifiers) = shortcut, code == key,
                  Self.modifiers(event.flags) == modifiers else { return false }
            if !held { held = true; onPress() }
            return true
        case .keyUp:
            guard case .key(let key, _) = shortcut, code == key, held else { return false }
            held = false
            onRelease()
            return true
        case .flagsChanged:
            guard case .rightModifier(let modifier) = shortcut, code == Self.keyCode(modifier) else { return false }
            let down = event.flags.rawValue & Self.deviceMask(modifier) != 0
            if down, !held { held = true; onPress() }
            else if !down, held { held = false; onRelease() }
            return false
        default:
            return false
        }
    }

    static func modifiers(_ flags: CGEventFlags) -> DictationModifiers {
        var value: DictationModifiers = []
        if flags.contains(.maskControl) { value.insert(.control) }
        if flags.contains(.maskAlternate) { value.insert(.option) }
        if flags.contains(.maskShift) { value.insert(.shift) }
        if flags.contains(.maskCommand) { value.insert(.command) }
        return value
    }

    static func keyCode(_ modifier: DictationRightModifier) -> UInt16 {
        switch modifier {
        case .option: UInt16(kVK_RightOption)
        case .command: UInt16(kVK_RightCommand)
        case .control: UInt16(kVK_RightControl)
        }
    }

    static func deviceMask(_ modifier: DictationRightModifier) -> UInt64 {
        switch modifier {
        case .option: UInt64(NX_DEVICERALTKEYMASK)
        case .command: UInt64(NX_DEVICERCMDKEYMASK)
        case .control: UInt64(NX_DEVICERCTLKEYMASK)
        }
    }
}

private extension CGEventFlags {
    var containsShortcutModifiers: Bool { !intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty }
}
