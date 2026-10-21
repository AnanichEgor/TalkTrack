import AppKit
import Foundation
import Observation
import TalkTrackInferenceRuntime
import TalkTrackServices

/// Application-lifetime dictation: the shortcut tap, the controller and the
/// in-memory history. Preferences are read for every dictation; the tap
/// follows Enable Dictation and the shortcut as soon as they change.
@MainActor @Observable final class DictationModel {
    private(set) var activity: DictationActivity = .idle
    /// In memory only; cleared on quit.
    private(set) var history: [DictationHistoryItem] = []
    private(set) var canRestoreClipboard = false
    private(set) var permissions: [DictationPermission: Bool] = [:]
    /// Permissions are granted but macOS still refuses the tap: a restart is needed.
    private(set) var needsRestart = false
    var isAvailable: Bool { permissions.values.allSatisfy { $0 } && !needsRestart }
    /// Settings is recording a new shortcut; the global shortcut is paused.
    var recordingShortcut = false { didSet { tap.paused = recordingShortcut } }

    @ObservationIgnored let system: DictationSystem
    @ObservationIgnored private let controller: DictationController
    @ObservationIgnored private let tap = DictationShortcutTap()
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var enabled = false

    init(inference: DictationInference, meetingRecording: @escaping () -> Bool) {
        let audio = DictationMicrophone()
        let system = DictationSystem(level: { audio.level() })
        self.system = system
        system.meetingRecording = meetingRecording
        controller = DictationController(inference: inference, audio: audio, host: system)
        system.restoreInterruptedMute()
        // `controller` is set; callbacks may now reference self.
        let controller = self.controller
        let changed: @Sendable (DictationActivity, [DictationHistoryItem]) -> Void = { [weak self] activity, history in
            Task { @MainActor in self?.activity = activity; self?.history = history }
        }
        Task { await controller.setChanged(changed) }
        system.onClipboardChange = { [weak self] in self?.canRestoreClipboard = self?.system.clipboard != nil }
        tap.onPress = { Task { await controller.shortcutPressed() } }
        tap.onRelease = { Task { await controller.shortcutReleased() } }
        tap.onEscape = { [weak self] in
            guard let self, activity != .idle else { return false }
            Task { await controller.cancel() }
            return true
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        refresh()
    }

    /// Re-reads Enable Dictation, the shortcut and the permissions.
    func refresh() {
        let settings = DictationPreferences.settings()
        permissions = Dictionary(uniqueKeysWithValues: DictationPermission.allCases.map { ($0, DictationPermissions.isGranted($0)) })
        tap.shortcut = settings.shortcut
        if settings.enabled, permissions[.inputMonitoring] == true {
            let started = tap.start(listenOnly: permissions[.accessibility] != true)
            needsRestart = !started
        } else {
            tap.stop()
            needsRestart = false
        }
        if enabled, !settings.enabled { Task { [controller] in await controller.disabled() } }
        enabled = settings.enabled
    }

    func request(_ permission: DictationPermission) async {
        await DictationPermissions.request(permission)
        refresh()
    }

    func copy(_ item: DictationHistoryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        // The kept clipboard no longer matches; its offer ends.
        system.discardClipboard()
    }

    func restorePreviousClipboard() { system.restorePreviousClipboard() }

    /// A meeting is about to record: an active dictation is cancelled first.
    func meetingWillStart() async { await controller.meetingWillStart() }

    /// Quit: cancel, restore output and forget history and the kept clipboard.
    func shutdown() async {
        tap.stop()
        await controller.cancel()
        await controller.clearHistory()
        system.discardClipboard()
        system.restoreInterruptedMute()
    }
}
