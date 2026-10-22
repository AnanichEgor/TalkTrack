import AppKit
import SwiftUI
import TalkTrackServices

@main
struct TalkTrackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    /// Owned by the delegate, which needs it to decide whether quitting may proceed.
    private var model: AppModel { delegate.model }

    var body: some Scene {
        Window("TalkTrack", id: "main") {
            Group {
                #if DEBUG && TALKTRACK_DEVTOOLS
                if ProcessInfo.processInfo.arguments.contains("--saved-speakers-check") {
                    SavedSpeakersCheckView()
                } else if ProcessInfo.processInfo.arguments.contains("--speaker-rename-check") {
                    SpeakerRenameCheckView()
                } else if ProcessInfo.processInfo.arguments.contains("--live-transcription-check") {
                    LiveTranscriptionCheckView()
                } else if ProcessInfo.processInfo.arguments.contains("--audio-capture-check") {
                    AudioCaptureCheckView()
                } else {
                    WorkspaceView(model: model)
                }
                #else
                WorkspaceView(model: model)
                #endif
            }
            .frame(minWidth: 760, minHeight: 500)
            .background(WindowReader { model.mainWindow = $0 })
            .environment(model)
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Meeting…") {
                    openWindow(id: "main")
                    model.newMeetingRequests += 1
                }
                .keyboardShortcut("n")
            }
            MeetingCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

/// The status-bar menu. While a meeting records it shows which one and offers Stop.
private struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let workspace = model.workspace, let meeting = workspace.activeMeeting {
            Text(workspace.phase == .paused ? "Paused: \(meeting.title)" : "Recording: \(meeting.title)")
            Button("Show Recording") {
                showMainWindow()
                workspace.showActiveMeeting()
            }
            Button("Stop Recording") { Task { await workspace.stop() } }
                .disabled(!workspace.controls(for: meeting.id).primaryEnabled || workspace.controls(for: meeting.id).primary != .stop)
            Divider()
        }
        if let dictation = model.dictation, !dictation.history.isEmpty || dictation.canRestoreClipboard {
            if let last = dictation.history.first {
                Button("Copy Last Transcript") { dictation.copy(last) }
                Menu("Recent Dictations") {
                    ForEach(dictation.history) { item in
                        Button(Self.preview(item.text)) { dictation.copy(item) }
                    }
                }
            }
            if dictation.canRestoreClipboard {
                Button("Restore Previous Clipboard") { dictation.restorePreviousClipboard() }
            }
            Divider()
        }
        if let update = model.updates.available {
            Button("Update Available: TalkTrack \(update.version)…") { NSWorkspace.shared.open(update.pageURL) }
            Divider()
        }
        Button("Open TalkTrack") { showMainWindow() }
        Button("Settings…") {
            model.showSettings(openSettings)
        }
        Divider()
        Button("Quit TalkTrack") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showMainWindow() {
        openWindow(id: "main")
        model.showMainWindow()
    }

    /// One line of a dictation for the menu.
    private static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }
}

/// The menu-bar icon. It is always rendered, so it also hands the Settings and
/// main-window openers to the model (dictation HUD, Dock icon clicks).
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.menuBarSymbol)
            .accessibilityLabel(model.menuBarLabel)
            .onAppear {
                model.openSettingsAction = openSettings
                model.openMainWindowAction = { openWindow(id: "main") }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var quitting = false

    /// Closing the window keeps the app, any recording and processing running.
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.applyDockIcon()
        #if DEBUG && TALKTRACK_DEVTOOLS
        ReviewSupport.model = model
        ReviewSupport.install()
        // Scripted reviews and checks launch with options; an alert would block them.
        if ProcessInfo.processInfo.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) { return }
        #endif
        model.updates.start { [weak self] update in self?.announce(update) }
    }

    /// Once per version, and never over a recording (the menu bar still shows it).
    private func announce(_ update: AvailableUpdate) {
        guard !model.isCapturing else { return }
        let alert = NSAlert()
        alert.messageText = "TalkTrack \(update.version) is available"
        alert.informativeText = "You have version \(model.updates.currentVersion). Download the new TalkTrack.dmg and drag TalkTrack to Applications to replace this copy. Meetings, models and settings are kept."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(update.downloadURL ?? update.pageURL)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(update.pageURL)
        default: break
        }
    }

    /// A click on the Dock icon with no window open shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            model.openMainWindowAction?()
            model.showMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Every quit path (menu bar, app menu, Cmd-Q, logout) comes here. During
    /// capture the user chooses Stop and Quit or Cancel; the app exits only
    /// after capture has stopped and the recording is saved.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A second request while saving: the first one finishes the quit.
        guard !quitting else { return .terminateCancel }
        // Logout, restart and shutdown cannot wait for an answer: save and quit.
        if model.isCapturing, !Self.isSystemQuit, !confirmStopAndQuit() { return .terminateCancel }
        quitting = true
        Task {
            await model.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func confirmStopAndQuit() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        let title = model.workspace?.activeMeeting?.title ?? "A meeting"
        alert.messageText = "Stop recording and quit?"
        alert.informativeText = model.workspace?.phase == .paused
            ? "“\(title)” has a paused recording. TalkTrack saves it before quitting, and transcribes it the next time you open TalkTrack."
            : "“\(title)” is recording. TalkTrack stops and saves the recording before quitting, and transcribes it the next time you open TalkTrack."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Quit Apple events sent by loginwindow carry a reason (logout, restart, shutdown).
    private static var isSystemQuit: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }
}
