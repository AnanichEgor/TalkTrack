import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import CoreAudio
import TalkTrackServices

/// Permission status for Settings ▸ Dictation and the controller's refusals.
enum DictationPermissions {
    static func isGranted(_ permission: DictationPermission) -> Bool {
        switch permission {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: AXIsProcessTrusted()
        case .inputMonitoring: CGPreflightListenEventAccess()
        }
    }

    static var missing: DictationPermission? {
        DictationPermission.allCases.first { !isGranted($0) }
    }

    /// Shows the system prompt where macOS offers one; otherwise opens the pane.
    @MainActor static func request(_ permission: DictationPermission) async {
        switch permission {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else { openSettings(permission) }
        case .accessibility:
            // The documented value of kAXTrustedCheckOptionPrompt, which Swift 6 refuses as shared mutable state.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openSettings(permission) }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openSettings(permission) }
        }
    }

    static func openSettings(_ permission: DictationPermission) {
        let pane = switch permission {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

/// The application, window and field that had focus at key down. Only
/// identities are kept: no field value, title or URL is read.
private struct DictationDestination {
    let pid: pid_t
    let window: AXUIElement?
    let element: AXUIElement?

    static let timeout: Float = 0.25

    @MainActor static func current() -> DictationDestination? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, timeout)
        return DictationDestination(pid: app.processIdentifier, window: attribute(element, kAXFocusedWindowAttribute),
                                    element: attribute(element, kAXFocusedUIElementAttribute))
    }

    /// The same application, window and (when one was known) field still have focus.
    @MainActor func isStillFocused() -> Bool {
        guard let window, let now = Self.current(), now.pid == pid, let nowWindow = now.window,
              CFEqual(window, nowWindow) else { return false }
        guard let element else { return true }
        guard let nowElement = now.element else { return false }
        return CFEqual(element, nowElement)
    }

    /// The window's frame in AppKit screen coordinates, to place the HUD.
    @MainActor var screen: NSScreen? {
        guard let window,
              let position: AXValue = Self.attribute(window, kAXPositionAttribute),
              let size: AXValue = Self.attribute(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        // AX uses top-left origin coordinates of the primary screen.
        let center = CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = NSPoint(x: center.x, y: primaryHeight - center.y)
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        // AX returns AXUIElement/AXValue CF types; the cast is checked by CFGetTypeID below.
        if T.self == AXUIElement.self, CFGetTypeID(value) == AXUIElementGetTypeID() { return (value as! T) }
        if T.self == AXValue.self, CFGetTypeID(value) == AXValueGetTypeID() { return (value as! T) }
        return nil
    }
}

/// Implements `DictationHost` with Accessibility, the general pasteboard,
/// synthetic key events, Core Audio output mute, system sounds and the HUD.
@MainActor final class DictationSystem: DictationHost {
    let hud: DictationHUD
    /// Set by the app: whether a meeting is being recorded.
    var meetingRecording: () -> Bool = { false }
    /// Kept only with Keep Previous Clipboard, for at most five minutes.
    private(set) var clipboard: ClipboardSnapshot?
    var onClipboardChange: () -> Void = {}
    private var destination: DictationDestination?
    private var clipboardWatch: Task<Void, Never>?
    private let mute = OutputMute()

    init(level: @escaping @Sendable () -> Float) {
        hud = DictationHUD(level: level)
    }

    func missingPermission() async -> DictationPermission? { DictationPermissions.missing }
    func isSecureInputActive() async -> Bool { IsSecureEventInputEnabled() }
    func isMeetingRecording() async -> Bool { meetingRecording() }

    func captureDestination() async {
        destination = DictationDestination.current()
        hud.screen = destination?.screen
    }

    func deliver(_ text: String, keepPreviousClipboard: Bool) async -> DictationDelivery {
        let pasteboard = NSPasteboard.general
        var snapshot = keepPreviousClipboard ? ClipboardSnapshot(items: Self.items(pasteboard)) : nil
        pasteboard.clearContents()
        let written = pasteboard.setString(text, forType: .string)
        if written { snapshot?.dictatedTextWritten(changeCount: pasteboard.changeCount) }
        keep(written ? snapshot : nil)
        guard let destination, destination.isStillFocused(), AXIsProcessTrusted() else {
            return written ? .copiedOnly : .failed("The clipboard could not be written.")
        }
        if written, Self.postPaste() { return .inserted }
        // The text is not lost: it is typed into the verified destination.
        return Self.type(text) ? .inserted : (written ? .copiedOnly : .failed("The text could not be inserted."))
    }

    func show(_ state: DictationHUDState) async { hud.show(state) }

    func playStartSound() async {
        NSSound(named: "Tink")?.play()
        // Muting starts after the sound, which would otherwise be cut off.
        try? await Task.sleep(for: .milliseconds(150))
    }

    func playStopSound() async { NSSound(named: "Pop")?.play() }
    func muteOutput() async -> Bool { mute.mute() }
    func restoreOutput() async { mute.restore() }

    /// Launch and quit: output muted by an interrupted dictation is restored.
    func restoreInterruptedMute() { mute.recover() }

    // MARK: Clipboard

    var canRestoreClipboard: Bool {
        clipboard?.isRestorable(changeCount: NSPasteboard.general.changeCount) == true
    }

    func restorePreviousClipboard() {
        guard let snapshot = clipboard, snapshot.isRestorable(changeCount: NSPasteboard.general.changeCount) else {
            keep(nil); return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(snapshot.items.map { representations in
            let item = NSPasteboardItem()
            for representation in representations { item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type)) }
            return item
        })
        keep(nil)
    }

    func discardClipboard() { keep(nil) }

    /// The offer disappears when the user copies something else or after five minutes.
    private func keep(_ snapshot: ClipboardSnapshot?) {
        clipboard = snapshot
        clipboardWatch?.cancel()
        onClipboardChange()
        guard snapshot != nil else { return }
        clipboardWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let current = clipboard else { return }
                if current.isStale(changeCount: NSPasteboard.general.changeCount) {
                    clipboard = nil
                    onClipboardChange()
                    return
                }
            }
        }
    }

    private static func items(_ pasteboard: NSPasteboard) -> [[(type: String, data: Data)]] {
        var total = 0, count = 0
        var result: [[(type: String, data: Data)]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [(type: String, data: Data)] = []
            for type in item.types {
                // Reading stops as soon as the bounds are exceeded; the snapshot is then refused.
                guard count < ClipboardSnapshot.maximumRepresentations + 1, total <= ClipboardSnapshot.maximumBytes else { break }
                guard let data = item.data(forType: type) else { continue }
                representations.append((type.rawValue, data))
                total += data.count; count += 1
            }
            result.append(representations)
        }
        return result
    }

    // MARK: Synthetic input

    private static func postPaste() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Keyboard input in chunks; macOS limits one event's Unicode string.
    private static func type(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            var chunk = Array(units[start..<min(start + 16, units.count)])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }
}

/// Mutes the default output device during a dictation. Only a device that was
/// unmuted is muted, and only what TalkTrack changed is restored. A marker in
/// preferences survives a crash so the next launch restores the output.
@MainActor final class OutputMute {
    private static let markerKey = "dictationMutedOutputUID"
    private var muted: AudioObjectID?

    func mute() -> Bool {
        guard muted == nil, let device = Self.defaultOutput(), Self.isMuted(device) == false,
              let uid = Self.uid(device), Self.setMuted(device, true) else { return false }
        UserDefaults.standard.set(uid, forKey: Self.markerKey)
        muted = device
        return true
    }

    func restore() {
        guard let device = muted else { return }
        muted = nil
        _ = Self.setMuted(device, false)
        UserDefaults.standard.removeObject(forKey: Self.markerKey)
    }

    /// Restores a mute left by a dictation that never finished.
    func recover() {
        if muted != nil { restore(); return }
        guard let uid = UserDefaults.standard.string(forKey: Self.markerKey) else { return }
        if let device = Self.device(uid: uid) { _ = Self.setMuted(device, false) }
        UserDefaults.standard.removeObject(forKey: Self.markerKey)
    }

    private static func address(_ selector: AudioObjectPropertySelector, output: Bool = false) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool? {
        var address = address(kAudioDevicePropertyMute, output: true)
        var value = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMuted(_ device: AudioObjectID, _ muted: Bool) -> Bool {
        var address = address(kAudioDevicePropertyMute, output: true)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        var value = UInt32(muted ? 1 : 0)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func uid(_ device: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func device(uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { Self.uid($0) == uid }
    }
}
