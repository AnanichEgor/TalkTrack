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
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel(model.menuBarLabel)
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
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var quitting = false

    /// Closing the window keeps the app, any recording and processing running.
    func applicationDidFinishLaunching(_ notification: Notification) {
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
