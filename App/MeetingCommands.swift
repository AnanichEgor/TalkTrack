import AppKit
import SwiftUI
import TalkTrackServices

/// What the focused meeting window offers to the menu bar commands.
struct MeetingActions {
    let meetingID: UUID
    let tab: Binding<MeetingTab>
    let rename: () -> Void
    let delete: () -> Void
    let canDelete: Bool
}

/// The Undo of the transcript's last naming Save, while it is offered.
struct NamingUndoAction {
    let title: String
    let enabled: Bool
    let perform: () -> Void
}

extension FocusedValues {
    @Entry var meetingActions: MeetingActions?
    @Entry var namingUndo: NamingUndoAction?
}

/// Keyboard access to every main action without Full Keyboard Access: the
/// Meeting menu (record, pause, playback, rename, delete), tabs in View and
/// Find for the meeting search.
struct MeetingCommands: Commands {
    let model: AppModel
    @FocusedValue(\.meetingActions) private var actions
    @FocusedValue(\.namingUndo) private var namingUndo

    var body: some Commands {
        // ⌘Z undoes the last naming Save while the transcript offers it; in a
        // text field or the notes editor it stays the ordinary text Undo.
        CommandGroup(replacing: .undoRedo) {
            Button(namingUndo?.title ?? "Undo") {
                // Never disabled: the naming sheet's field must keep its text Undo
                // while the transcript (whose Undo waits) is behind it.
                if let namingUndo, !Self.editingText { if namingUndo.enabled { namingUndo.perform() } }
                else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
            }
            .keyboardShortcut("z")
            Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Find Meetings") { model.searchFocusRequests += 1 }
                .keyboardShortcut("f")
                .disabled(model.workspace == nil)
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(MeetingTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.rawValue) { actions?.tab.wrappedValue = tab }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(actions == nil)
            }
            Divider()
        }
        CommandMenu("Meeting") {
            let controls = actions.flatMap { actions in model.workspace.map { $0.controls(for: actions.meetingID) } }
            Button(controls?.primary == .stop ? "Stop Recording" : "Record") {
                guard let workspace = model.workspace, let controls else { return }
                Task { controls.primary == .record ? await workspace.record() : await workspace.stop() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!(controls?.primaryEnabled ?? false))
            Button(controls?.secondary == .resume ? "Resume Recording" : "Pause Recording") {
                guard let workspace = model.workspace, let controls else { return }
                Task { controls.secondary == .pause ? await workspace.pause() : await workspace.resume() }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!(controls?.secondaryEnabled ?? false))
            Divider()
            let player = model.player
            Button(player?.state == .playing ? "Pause Playback" : "Play") { player?.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(actions == nil || !(player?.canPlay ?? false))
            Divider()
            Button("Rename Meeting…") { actions?.rename() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Delete Meeting…") { actions?.delete() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!(actions?.canDelete ?? false))
        }
    }

    /// A text view (a field's editor or the notes editor) has keyboard focus.
    @MainActor private static var editingText: Bool { NSApp.keyWindow?.firstResponder is NSTextView }
}
