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
                WorkspaceSplitView(workspace: workspace, services: services, newMeetingRequests: model.newMeetingRequests,
                                   importRequests: model.importRequests)
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
    /// A new meeting for a recording of the selected meeting, which moves into it.
    case moveRecording(UUID)
    /// Import a Teams session into a new meeting (nil) or this meeting.
    case importSession(UUID?)
    var id: String {
        switch self {
        case .create: "create"
        case .edit(let meeting): "edit:\(meeting.id)"
        case .moveRecording(let recording): "move:\(recording)"
        case .importSession(let meeting): "import:\(meeting?.uuidString ?? "new")"
        }
    }
}

struct WorkspaceSplitView: View {
    @Bindable var workspace: WorkspacePresentation
    let services: WorkspaceServices
    let newMeetingRequests: Int
    let importRequests: Int
    @State private var sheet: MeetingSheet?
    @State private var deleting: Meeting?

    var body: some View {
        NavigationSplitView {
            MeetingSidebar(workspace: workspace, services: services, sheet: $sheet, deleting: $deleting)
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
        .onChange(of: importRequests) { if sheet == nil { sheet = .importSession(nil) } }
        .onChange(of: workspace.selectedID) { if workspace.selectedID == nil { services.player.load(meetingID: nil, recordings: []) } }
        .sheet(item: $sheet) { sheet in
            if case .importSession(let meetingID) = sheet {
                ImportSessionView(workspace: workspace, policy: services.jobPolicy, meetingID: meetingID)
            } else {
                MeetingFormView(workspace: workspace, sheet: sheet, policy: services.jobPolicy)
            }
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
    @Environment(\.openSettings) private var openSettings
    @Bindable var workspace: WorkspacePresentation
    let services: WorkspaceServices
    @Binding var sheet: MeetingSheet?
    @Binding var deleting: Meeting?

    private func meetingButtons(quickRecord: some LabelStyle, newMeeting: some LabelStyle) -> some View {
        HStack(spacing: 8) {
            Button { Task { await workspace.quickRecord() } } label: {
                Label {
                    Text("Quick Record")
                } icon: {
                    Image(systemName: "record.circle.fill").foregroundStyle(workspace.canQuickRecord ? Color.red : Color.secondary)
                }
                .labelStyle(quickRecord)
            }
            .controlSize(.large)
            .disabled(!workspace.canQuickRecord)
            .help(workspace.canQuickRecord ? "Create a meeting and start recording it now" : "Stop the current recording first")
            .accessibilityLabel("Quick Record")
            Button { sheet = .create } label: {
                Label("New Meeting", systemImage: "plus").labelStyle(newMeeting).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .help("Create a meeting (⌘N)")
            Button { sheet = .importSession(nil) } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .controlSize(.large)
            .disabled(workspace.importStatus != nil)
            .help(workspace.importStatus != nil ? "Wait for the running import to finish" : "Import a Teams recording and transcript (⇧⌘I)")
            .accessibilityLabel("Import Session")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Meetings").font(.title2.bold())
                // The sidebar can be narrower than both labels with their icons.
                ViewThatFits(in: .horizontal) {
                    meetingButtons(quickRecord: .titleAndIcon, newMeeting: .titleAndIcon)
                    meetingButtons(quickRecord: .titleOnly, newMeeting: .titleOnly)
                    meetingButtons(quickRecord: .iconOnly, newMeeting: .titleAndIcon)
                }
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
                            MeetingRow(meeting: meeting,
                                       capture: workspace.activeMeeting?.id == meeting.id ? workspace.activeCaptureStatus : nil,
                                       queue: workspace.queueStates[meeting.id])
                                .tag(meeting.id)
                                .contextMenu {
                                    Button("Rename…") { sheet = .edit(meeting) }
                                    Button("Import Recording…") { sheet = .importSession(meeting.id) }
                                        .disabled(workspace.importRefusal(into: meeting.id) != nil)
                                    Button("Export All…") {
                                        Task { await MarkdownExporter.export(meetingID: meeting.id, section: nil, services: services, workspace: workspace) }
                                    }
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

            if let status = workspace.importStatus {
                Divider()
                ImportProgressRow(status: status, cancel: workspace.cancelImport)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            if let learning = workspace.importVoiceLearning {
                Divider()
                ImportVoiceLearningRow(learning: learning, recording: workspace.phase != .idle)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            Divider()
            HStack {
                SettingsLink {
                    Label("Settings", systemImage: "gear")
                }
                .buttonStyle(.borderless)
                Spacer()
                // Settings tabs cannot show badges: voices waiting for an answer
                // are counted here and open Settings ▸ Speakers.
                let reviews = app.speakers.reviewCount
                if reviews > 0 {
                    Button { app.showSettings(openSettings, tab: .speakers) } label: {
                        Text(reviews == 1 ? "1 voice to review" : "\(reviews) voices to review")
                            .font(.caption.weight(.medium)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.orange))
                    }
                    .buttonStyle(.plain)
                    .help("Saved voices waiting for your answer in Settings ▸ Speakers")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    /// Recording, paused or saving, when this meeting has the active recording.
    let capture: MeetingProcessingStatus?
    /// Final transcription running or waiting, shown while another meeting is selected.
    var queue: FinalQueueState?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(.headline).lineLimit(1)
            Text(meeting.description).font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
            HStack(spacing: 6) {
                Text(Self.date(meeting.sortDate))
                if let capture {
                    Label(capture.captureTitle, systemImage: capture.captureSymbol).labelStyle(.titleAndIcon)
                        .foregroundStyle(capture == .paused ? Color.pausedText : capture == .saving ? Color.secondary : Color.errorText)
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
    /// Queues transcription of a moved recording that has none yet.
    var policy: FinalJobPolicy?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var titleFocused: Bool

    private var heading: String {
        switch sheet {
        case .create: "New Meeting"
        case .edit: "Rename Meeting"
        case .moveRecording: "Move to New Meeting"
        case .importSession: "Import Session"
        }
    }
    private var action: String {
        switch sheet {
        case .create: "Create"
        case .edit: "Save"
        case .moveRecording: "Create and Move"
        case .importSession: "Import"
        }
    }
    private var canSave: Bool { !saving && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(heading).font(.title2.bold())
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
                Button(action) { Task { await save() } }
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
            case .moveRecording(let recording):
                try await workspace.moveRecordingToNewMeeting(recording, title: title, description: description, policy: policy)
            case .importSession: break
            }
            dismiss()
        } catch {
            self.error = [error.localizedDescription, (error as? LocalizedError)?.recoverySuggestion]
                .compactMap { $0 }.joined(separator: " ")
        }
    }
}
