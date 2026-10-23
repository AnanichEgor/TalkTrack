import AppKit
import SwiftUI
import TalkTrackDomain
import TalkTrackServices

struct WorkspaceView: View {
    let model: AppModel

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                if case .moving(let progress) = model.libraryMove {
                    LibraryMoveProgress(progress: progress, cancel: model.cancelMove)
                        .frame(maxWidth: 360).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView("Opening library…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case let .failed(message, recovery):
                ContentUnavailableView {
                    Label("Library Unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text([message, recovery].compactMap { $0 }.joined(separator: "\n"))
                } actions: {
                    Button("Try Again") { Task { await model.load() } }
                    if model.canLocateLibrary {
                        Button("Locate Library…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.prompt = "Open Library"
                            panel.message = "Choose the folder that contains your TalkTrack library."
                            if panel.runModal() == .OK, let url = panel.url { Task { await model.locateLibrary(at: url) } }
                        }
                        .help("Open the moved library from the folder where it is now")
                    }
                }
            case let .ready(workspace, services):
                WorkspaceSplitView(workspace: workspace, services: services, newMeetingRequests: model.newMeetingRequests)
            }
        }
        .task { await model.load() }
    }
}

/// Progress of a library move; Cancel works until the copy is switched in.
struct LibraryMoveProgress: View {
    let progress: LibraryMigrationProgress?
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress, progress.totalBytes > 0 {
                ProgressView(value: Double(progress.completedBytes), total: Double(progress.totalBytes)) { Text(title) }
                    currentValueLabel: {
                        Text("\(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                    }
            } else {
                ProgressView { Text(title) }
            }
            Text("Recording and processing are paused until the move finishes. The library stays in its old folder until the copy is verified.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel Move", action: cancel)
                    .disabled(progress.map { $0.stage == .switching || $0.stage == .cleaning } ?? false)
                    .help("Stop the move and keep the library in its old folder")
            }
        }
    }

    private var title: String {
        switch progress?.stage {
        case .verifying: "Verifying the copied library…"
        case .switching: "Switching to the new folder…"
        case .cleaning: "Removing the old library files…"
        default: "Moving library…"
        }
    }
}

enum MeetingSheet: Identifiable {
    case create
    case edit(Meeting)
    var id: String {
        switch self {
        case .create: "create"
        case .edit(let meeting): "edit:\(meeting.id)"
        }
    }
}

struct WorkspaceSplitView: View {
    @Bindable var workspace: WorkspacePresentation
    let services: WorkspaceServices
    let newMeetingRequests: Int
    @State private var sheet: MeetingSheet?
    @State private var deleting: Meeting?

    var body: some View {
        NavigationSplitView {
            MeetingSidebar(workspace: workspace, sheet: $sheet, deleting: $deleting)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
        } detail: {
            if let meeting = workspace.selected {
                MeetingDetailView(workspace: workspace, services: services, meeting: meeting,
                                  sheet: $sheet, deleting: $deleting)
            } else if workspace.isLoaded {
                ContentUnavailableView("No Meeting Selected", systemImage: "waveform",
                                       description: Text(workspace.hasMeetings
                                           ? "Select a meeting in the sidebar."
                                           : "Create a meeting to record and transcribe it."))
            }
        }
        .onChange(of: newMeetingRequests) { if sheet == nil { sheet = .create } }
        .onChange(of: workspace.selectedID) { if workspace.selectedID == nil { services.player.load(meetingID: nil, recordings: []) } }
        .sheet(item: $sheet) { sheet in
            MeetingFormView(workspace: workspace, sheet: sheet)
        }
        .confirmationDialog(deleting.map { "Delete “\($0.title)”?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { meeting in
            Button("Delete Meeting", role: .destructive) {
                // Never keep playing files that are about to be removed.
                if services.player.meetingID == meeting.id { services.player.load(meetingID: nil, recordings: []) }
                Task { await workspace.deleteMeeting(meeting.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { meeting in
            Text(deleteMessage(meeting))
        }
        .alert(workspace.issue?.message ?? "",
               isPresented: Binding(get: { workspace.issue != nil }, set: { if !$0 { workspace.issue = nil } }),
               presenting: workspace.issue) { issue in
            if let url = issue.settingsURL {
                Button("Open System Settings") { NSWorkspace.shared.open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: { issue in
            Text(issue.recovery ?? "")
        }
    }

    private func deleteMessage(_ meeting: Meeting) -> String {
        let count = workspace.selected?.id == meeting.id ? workspace.recordings.count : nil
        if count == 0 { return "This permanently removes the meeting and its notes. It has no recordings. This cannot be undone." }
        let audio = count.map { $0 == 1 ? "its recording" : "all \($0) recordings" } ?? "all of its recordings"
        return "This permanently removes the meeting and \(audio) — audio, transcripts, notes and generated text. This cannot be undone."
    }
}

// MARK: Sidebar

struct MeetingSidebar: View {
    @Environment(AppModel.self) private var app
    @Bindable var workspace: WorkspacePresentation
    @Binding var sheet: MeetingSheet?
    @Binding var deleting: Meeting?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Meetings").font(.title2.bold())
                Button { sheet = .create } label: {
                    Label("New Meeting", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .help("Create a meeting (⌘N)")
                SearchField(text: $workspace.search, prompt: "Search meetings (⌘F)", focusRequests: app.searchFocusRequests)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

            if !workspace.isLoaded {
                Spacer()
            } else if !workspace.hasMeetings {
                ContentUnavailableView("No Meetings", systemImage: "waveform",
                                       description: Text("Create a meeting, then record its system audio and microphone."))
                    .frame(maxHeight: .infinity)
            } else if workspace.meetings.isEmpty {
                ContentUnavailableView.search(text: workspace.search).frame(maxHeight: .infinity)
            } else {
                // Selection can change from elsewhere (Show Recording, a cleared
                // search); keep the selected card visible.
                ScrollViewReader { proxy in
                    List(selection: $workspace.selectedID) {
                        ForEach(workspace.meetings) { meeting in
                            MeetingRow(meeting: meeting, isRecording: workspace.activeMeeting?.id == meeting.id,
                                       isPaused: workspace.phase == .paused, queue: workspace.queueStates[meeting.id])
                                .tag(meeting.id)
                                .contextMenu {
                                    Button("Rename…") { sheet = .edit(meeting) }
                                    Button("Delete…", role: .destructive) { deleting = meeting }
                                        .disabled(!workspace.canDelete(meeting.id))
                                }
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: workspace.selectedID) { _, id in
                        // After the list lays out the new selection; lazy rows estimate heights first.
                        if let id { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }

            Divider()
            SettingsLink {
                Label("Settings", systemImage: "gear")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let isRecording: Bool
    let isPaused: Bool
    /// Final transcription running or waiting, shown while another meeting is selected.
    var queue: FinalQueueState?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(.headline).lineLimit(1)
            Text(meeting.description).font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
            HStack(spacing: 6) {
                Text(Self.date(meeting.sortDate))
                if isRecording {
                    Label(isPaused ? "Paused" : "Recording", systemImage: isPaused ? "pause.circle.fill" : "record.circle.fill")
                        .labelStyle(.titleAndIcon).foregroundStyle(isPaused ? Color.pausedText : Color.errorText)
                } else if let queue {
                    Image(systemName: queue == .running ? "waveform" : "clock")
                        .accessibilityLabel(queue.accessibilityLabel)
                        .help(queue == .running ? "Transcribing" : queue.message)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// "Sep 28 · 10:00 AM" in the interface language.
    static func date(_ date: Date) -> String {
        let locale = Locale(identifier: "en_US")
        return date.formatted(.dateTime.month(.abbreviated).day().locale(locale)) + " · "
            + date.formatted(.dateTime.hour().minute().locale(locale))
    }
}

/// The native AppKit search field, placed in the sidebar as in the mockup.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    /// A change focuses the field (Edit ▸ Find Meetings).
    var focusRequests = 0

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.setAccessibilityLabel("Search meetings")
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        // The clear button and Return send the action, not a text change.
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if focusRequests != context.coordinator.focusRequests {
            context.coordinator.focusRequests = focusRequests
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(text: $text)
        coordinator.focusRequests = focusRequests
        return coordinator
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        var focusRequests = 0
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
        @objc func search(_ sender: NSSearchField) { text.wrappedValue = sender.stringValue }
    }
}

// MARK: New Meeting / Rename

struct MeetingFormView: View {
    let workspace: WorkspacePresentation
    let sheet: MeetingSheet
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var titleFocused: Bool

    private var isNew: Bool { if case .create = sheet { true } else { false } }
    private var canSave: Bool { !saving && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "New Meeting" : "Rename Meeting").font(.title2.bold())
            Form {
                TextField("Title", text: $title, prompt: Text("Required"))
                    .focused($titleFocused)
                TextField("Description", text: $description, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(2...5)
            }
            .formStyle(.columns)
            if let error {
                Text(error).foregroundStyle(Color.errorText).font(.callout).textSelection(.enabled)
            }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(24).frame(width: 440)
        .interactiveDismissDisabled(saving)
        .onAppear {
            if case .edit(let meeting) = sheet { title = meeting.title; description = meeting.description }
            titleFocused = true
        }
    }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            switch sheet {
            case .create: try await workspace.createMeeting(title: title, description: description)
            case .edit(let meeting): try await workspace.renameMeeting(meeting.id, title: title, description: description)
            }
            dismiss()
        } catch {
            self.error = [error.localizedDescription, (error as? LocalizedError)?.recoverySuggestion]
                .compactMap { $0 }.joined(separator: " ")
        }
    }
}
