import AppKit
import SwiftUI
import TalkTrackAudio
import TalkTrackDomain
import TalkTrackServices

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            Tab("General", systemImage: "gearshape", value: AppModel.SettingsTab.general) {
                StorageSettings(model: model)
            }
            Tab("Audio", systemImage: "waveform", value: AppModel.SettingsTab.audio) {
                AudioSettings()
            }
            Tab("Models", systemImage: "square.and.arrow.down", value: AppModel.SettingsTab.models) {
                if let models = model.models {
                    ModelSettings(models: models, server: model.textServer)
                } else {
                    Form {
                        Text(model.setupError ?? "Models are unavailable.").foregroundStyle(.secondary)
                        TextServerSection(server: model.textServer)
                    }
                    .formStyle(.grouped)
                    .onAppear { model.textServer.loadKey() }
                }
            }
            Tab("Text", systemImage: "text.alignleft", value: AppModel.SettingsTab.text) {
                TextSettings()
            }
            Tab("Speakers", systemImage: "person.2", value: AppModel.SettingsTab.speakers) {
                Form { SavedSpeakersView(presentation: model.speakers) }.formStyle(.grouped)
            }
            Tab("Dictation", systemImage: "mic", value: AppModel.SettingsTab.dictation) {
                if let dictation = model.dictation {
                    DictationSettingsView(model: model, dictation: dictation)
                } else {
                    Form { Text(model.setupError ?? "Dictation is unavailable.").foregroundStyle(.secondary) }.formStyle(.grouped)
                }
            }
        }
        .frame(width: 600, height: 560)
        .background(WindowReader { model.settingsWindow = $0 })
    }
}

/// Reports the hosting window once the view is in it.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Reader(found: found) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Reader: NSView {
        let found: (NSWindow) -> Void
        init(found: @escaping (NSWindow) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { self.found(window) } }
        }
    }
}

// MARK: General

private struct UpdateSettings: View {
    @Bindable var updates: UpdateChecker

    var body: some View {
        Section("Updates") {
            LabeledContent("Version", value: updates.currentVersion)
            Toggle("Check for updates automatically", isOn: $updates.automatic)
            HStack(alignment: .center, spacing: 8) {
                status
                Spacer()
                if let update = updates.available {
                    Button("Release Notes") { NSWorkspace.shared.open(update.pageURL) }
                    Button("Download") { NSWorkspace.shared.open(update.downloadURL ?? update.pageURL) }
                }
                Button("Check Now") { Task { await updates.check() } }
                    .disabled(updates.status == .checking)
            }
            Text("TalkTrack asks GitHub for the latest release at launch and once a day. Nothing about you or your meetings is sent. To update, download the new TalkTrack.dmg and replace the app in Applications.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch updates.status {
        case .idle:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
        case .upToDate(let date):
            Label("Up to date (checked \(date.formatted(date: .omitted, time: .shortened)))", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .available(let update):
            Label("TalkTrack \(update.version) is available", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.errorText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One line, shortened in the middle; the full path is the tooltip and the
/// accessibility value.
private struct PathText: View {
    let url: URL

    var body: some View {
        Text(StorageSettings.display(url))
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            .help(url.path)
            .id(url.path)
    }
}

struct StorageSettings: View {
    let model: AppModel
    @State private var confirmation: LibraryMigrationPlan?
    @State private var planError: String?
    @State private var checking = false
    private var libraryRoot: URL? { model.libraryRoot }

    var body: some View {
        Form {
            PermissionsSection(dictation: model.dictation)
            Section("Meeting Library") {
                LabeledContent("Location") {
                    if let libraryRoot { PathText(url: libraryRoot) } else { Text("Not opened") }
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { libraryRoot.map(Self.reveal) }
                        .disabled(libraryRoot == nil)
                        .help("Show the folder that contains the meeting library")
                    Button("Move Library…", action: chooseDestination)
                        .disabled(!canMove)
                        .help(model.isCapturing ? "Stop recording before moving the library" : "Move all meetings, audio and notes to another folder")
                }
                Text("Meetings, audio, transcripts, notes and speaker names are saved in the TalkTrack library inside this folder. Only that library folder belongs to TalkTrack.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.isCapturing {
                    Text("Stop recording before moving the library.").font(.callout).foregroundStyle(.secondary)
                }
                moveStatus
            }
            Section("Models") {
                LabeledContent("Location") {
                    PathText(url: ModelDownloadFiles.defaultRoot)
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { Self.reveal(ModelDownloadFiles.defaultRoot) }
                        .disabled(!FileManager.default.fileExists(atPath: ModelDownloadFiles.defaultRoot.path))
                        .help("Show the folder that holds downloaded models")
                }
                Text("Models are stored separately from meetings and stay on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            UpdateSettings(updates: model.updates)
        }
        .formStyle(.grouped)
        .alert("Move the library?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
               presenting: confirmation) { plan in
            Button("Move") { model.moveLibrary(to: plan.destinationRoot) }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(Self.confirmationText(plan))
        }
    }

    private var canMove: Bool {
        guard libraryRoot != nil, !model.isCapturing, !checking, model.workspace != nil else { return false }
        if case .moving = model.libraryMove { return false }
        return true
    }

    @ViewBuilder private var moveStatus: some View {
        switch model.libraryMove {
        case .moving(let progress):
            LibraryMoveProgress(progress: progress, cancel: model.cancelMove)
        case .finished(let message):
            Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.errorText)
        case .idle:
            EmptyView()
        }
        if let planError {
            Label(planError, systemImage: "exclamationmark.triangle").foregroundStyle(Color.errorText)
        }
        if let recovery = model.moveRecovery {
            Label(recovery, systemImage: "info.circle").foregroundStyle(.secondary)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        panel.message = "Choose a folder for the TalkTrack library. Other files in it are not changed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        planError = nil
        model.dismissMoveResult()
        checking = true
        Task {
            defer { checking = false }
            do { confirmation = try await model.planMove(to: url) }
            catch { planError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    static func confirmationText(_ plan: LibraryMigrationPlan) -> String {
        let size = ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)
        let free = plan.availableBytes.map { ", \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) free there" } ?? ""
        return """
            \(plan.files) files (\(size)) will be copied to \(display(plan.destinationRoot))\(free). \
            Processing pauses during the move and continues afterwards. The old copy is removed only after the new one is verified; \
            other files in both folders are not changed.
            """
    }

    static func display(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

// MARK: Audio

private struct AudioSettings: View {
    @AppStorage(ProcessingPreferences.liveEnabledKey) private var liveEnabled = true
    @AppStorage(ProcessingPreferences.meetingLanguageKey) private var meetingLanguage = MeetingLanguage.auto.rawValue
    @AppStorage(ProcessingPreferences.microphoneUIDKey) private var microphoneUID = ""
    @AppStorage(ProcessingPreferences.microphoneNameKey) private var microphoneName = ""
    @AppStorage(ProcessingPreferences.spellingCorrectionKey) private var spellingCorrection = false
    @State private var devices: [AudioInputDevice] = []
    @State private var listError: String?
    @State private var observer: AudioDeviceObserver?

    var body: some View {
        Form {
            Section("Microphone") {
                Picker("Microphone", selection: selection) {
                    Text("System Default").tag("")
                    ForEach(devices, id: \.uid) { device in
                        Text(label(device)).tag(device.uid)
                    }
                    if !microphoneUID.isEmpty && !devices.contains(where: { $0.uid == microphoneUID }) {
                        Text("\(microphoneName.isEmpty ? "Saved microphone" : microphoneName) (not connected)").tag(microphoneUID)
                    }
                }
                Text(microphoneHelp).font(.callout).foregroundStyle(.secondary)
                // Speaker playback reaches a separate microphone, so the microphone track
                // also hears the other participants (echo the transcript must filter out).
                (Text("Note: ").bold() + Text("A headset gives the best transcription. When meeting audio plays through speakers and a separate microphone records you, the microphone also picks up the other participants, so your speech and the speakers are recognized less reliably."))
                    .font(.callout).foregroundStyle(.secondary)
                if let listError {
                    Label(listError, systemImage: "exclamationmark.triangle").foregroundStyle(Color.errorText)
                }
            }
            Section("Transcription") {
                Toggle("Live transcription", isOn: $liveEnabled)
                Picker("Default meeting language", selection: $meetingLanguage) {
                    ForEach(MeetingLanguage.allCases, id: \.rawValue) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
                Text("New meetings inherit this language. Live text and speakers are provisional; saved audio is processed again after recording.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Spelling correction", isOn: $spellingCorrection)
                    .help("After recording, the text model corrects obvious spelling, capitalization and punctuation.")
                if spellingCorrection {
                    Label("Processing will be much slower: about twice as long. The text model checks every utterance, and on a real meeting it changed about 1% of words.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Color.pausedText)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reload()
            observer = NativeAudioDevices.observe { reload() }
        }
        .onDisappear { observer = nil }
    }

    private var selection: Binding<String> {
        Binding(get: { microphoneUID }, set: { uid in
            microphoneUID = uid
            // Remember the name so a disconnected device stays identifiable.
            if let device = devices.first(where: { $0.uid == uid }) { microphoneName = device.name }
            if uid.isEmpty { microphoneName = "" }
        })
    }

    /// Devices can share a name (e.g. two Continuity microphones); number repeats.
    private func label(_ device: AudioInputDevice) -> String {
        let same = devices.filter { $0.name == device.name }
        guard same.count > 1, let index = same.firstIndex(where: { $0.uid == device.uid }) else { return device.name }
        return index == 0 ? device.name : "\(device.name) (\(index + 1))"
    }

    private var microphoneHelp: String {
        if !microphoneUID.isEmpty && !devices.contains(where: { $0.uid == microphoneUID }) {
            return "This microphone is not connected. Recording will not start until it is connected or another microphone is chosen."
        }
        return "System audio is always recorded as a separate track. The choice applies to the next recording and dictation."
    }

    private func reload() {
        do {
            devices = try NativeAudioDevices.inputs().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }
}

// MARK: Models

private struct ModelSettings: View {
    let models: ModelSettingsPresentation
    let server: TextServerSettingsPresentation
    @State private var removing: ModelSettingsPresentation.Item?

    var body: some View {
        Form {
            Section {
                ForEach(models.items.filter { !$0.isTextModel }) { item in
                    ModelRow(item: item, requested: models.requested.contains(item.id), models: models,
                             remove: { removing = item })
                }
            } header: {
                Text("Speech and Speakers")
            } footer: {
                Text("Models are downloaded only when you choose Download, and run entirely on this Mac. Recordings never leave it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Picker("Use for new summaries and translations", selection: Binding(
                    get: { models.textModelChoice ?? "" }, set: { models.chooseTextModel($0.isEmpty ? nil : $0) })) {
                    Text("Automatic (\(textName(models.automaticTextModel)))").tag("")
                    ForEach(models.items.filter(\.isTextModel)) { Text(textName($0.id)).tag($0.id) }
                }
                if models.selectedTextModelExceedsMemory {
                    Label("This model is larger than recommended for \(Self.memory(models.physicalMemory)) of memory. Summaries and translations can take much longer, slow down other apps, or stop with a memory error. Recording and transcription are not affected.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(models.items.filter(\.isTextModel)) { item in
                    ModelRow(item: item, requested: models.requested.contains(item.id), models: models,
                             remove: { removing = item }, inUse: item.id == models.selectedTextModel)
                }
            } header: {
                Text("Text Model")
            } footer: {
                Text("Automatic uses the larger model on Macs with 32 GB of memory or more (this Mac has \(Self.memory(models.physicalMemory))). Summaries choose their model beside Generate Summaries: the text server below when it is used for summaries, otherwise this one. Summaries and translations already queued keep the model they were started with.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextServerSection(server: server)
        }
        .formStyle(.grouped)
        .task { await models.refresh() }
        .onAppear { server.loadKey() }
        .confirmationDialog(removing.map { "Remove \($0.title)?" } ?? "", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { item in
            Button("Remove", role: .destructive) { Task { await models.remove(item.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("Its files (\(ModelRow.size(item.downloadBytes))) are deleted from this Mac. Meetings and transcripts are kept. Features that need this model stay unavailable until you download it again.")
        }
    }
}

extension ModelSettings {
    private func textName(_ id: String) -> String {
        let title = models.items.first { $0.id == id }?.title ?? id
        return title.replacingOccurrences(of: "Text processing: ", with: "")
    }

    static func memory(_ bytes: UInt64) -> String { "\(bytes >> 30) GB" }
}

private struct ModelRow: View {
    let item: ModelSettingsPresentation.Item
    let requested: Bool
    let models: ModelSettingsPresentation
    let remove: () -> Void
    /// The text model new jobs use.
    var inUse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title).fontWeight(.medium)
                        if inUse {
                            Text("Selected").font(.caption).foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(item.purpose).font(.callout).foregroundStyle(.secondary)
                    if inUse && !item.state.isInstalled && !item.state.isDownloading {
                        Text("Download it to generate summaries and translations.")
                            .font(.callout).foregroundStyle(Color.accentColor)
                    }
                }
                Spacer()
                actions
            }
            status
            if requested {
                Label(item.state.isInstalled ? "Installed; retry the waiting transcription from its meeting"
                      : "Needed by a transcription waiting for models", systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(Color.accentColor)
            }
            if let message = errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Color.errorText).textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, requested ? 6 : 0)
        .background(requested ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title) model")
    }

    @ViewBuilder private var actions: some View {
        switch item.state {
        case .checking, .removing:
            ProgressView().controlSize(.small)
        case .missing, .failed:
            Button("Download") { models.download(item.id) }
                .help("Download \(item.title) (\(Self.size(item.downloadBytes)))")
                .accessibilityLabel("Download \(item.title)")
        case .paused:
            Button("Resume") { models.download(item.id) }
                .help("Continue the download; files already verified are kept")
                .accessibilityLabel("Resume \(item.title) download")
        case .downloading:
            Button("Cancel") { Task { await models.cancel(item.id) } }
                .help("Stop the download; verified files are kept for Resume")
                .accessibilityLabel("Cancel \(item.title) download")
        case .ready, .inUse:
            Button("Remove…", role: .destructive, action: remove)
                .help("Delete this model's files from this Mac")
                .accessibilityLabel("Remove \(item.title)")
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .downloading(let phase, let completed, let total):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    .accessibilityLabel("\(item.title) download progress")
                Text(phase == .preparing ? "Preparing…" : phase == .checking ? "Checking files…"
                     : "\(Self.size(completed)) of \(Self.size(total))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        default:
            Text(statusText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch item.state {
        case .checking: "Checking…"
        case .missing: "Not downloaded · \(Self.size(item.downloadBytes))"
        case .paused: "Download paused · \(Self.size(item.downloadBytes))"
        case .failed: "Download failed · \(Self.size(item.downloadBytes))"
        case .ready: "Ready · \(Self.size(item.downloadBytes))"
        case .inUse: "Ready · in use"
        case .removing: "Removing… (waits for processing that uses this model)"
        case .downloading: ""
        }
    }

    private var errorMessage: String? {
        if let error = item.error { return error }
        if case .failed(let message) = item.state { return message }
        return nil
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: Text

private struct TextSettings: View {
    @AppStorage(ProcessingPreferences.summaryLanguageKey) private var summaryLanguage = OutputLanguage.english.rawValue
    @AppStorage(ProcessingPreferences.translationLanguageKey) private var translationLanguage = OutputLanguage.russian.rawValue
    @AppStorage(ProcessingPreferences.contextKey) private var selectedContext = ContextLimit.defaultSelection.rawValue

    var body: some View {
        Form {
            Section("Languages") {
                Picker("Summary language", selection: $summaryLanguage) { languages }
                Picker("Translation language", selection: $translationLanguage) { languages }
                Text("Summaries are written in the summary language and transcripts are translated into the translation language, whatever language the meeting was in. Changing a language does not regenerate existing results.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Context") {
                Picker("Context size", selection: $selectedContext) {
                    ForEach(ContextLimit.allCases, id: \.rawValue) { limit in
                        Text(limit.label).tag(limit.rawValue)
                    }
                }
                if selectedContext == ContextLimit.automatic.rawValue {
                    Text("Auto chooses the smallest context that fits the complete task and its response. Available memory is checked before processing.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Includes the source text, instructions and response. The maximum selectable context is 64K. Available memory is checked before processing. A text server (Settings ▸ Models) uses its own limits instead.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // Show (and keep) only supported values; unchanged values are not rewritten.
            selectedContext = ProcessingPreferences.context().rawValue
            let summary = ProcessingPreferences.summaryLanguage().rawValue, translation = ProcessingPreferences.translationLanguage().rawValue
            if summaryLanguage != summary { summaryLanguage = summary }
            if translationLanguage != translation { translationLanguage = translation }
        }
    }

    @ViewBuilder private var languages: some View {
        ForEach(OutputLanguage.allCases, id: \.rawValue) { language in
            Text(language == .english ? "English" : "Russian").tag(language.rawValue)
        }
    }
}

/// An OpenAI-compatible server for summaries and translations instead of the local model.
private struct TextServerSection: View {
    @Bindable var server: TextServerSettingsPresentation

    var body: some View {
        Section("Text Server") {
            TextField("Server URL", text: $server.address, prompt: Text(""))
                .textContentType(.URL).autocorrectionDisabled()
            SecureField("API key", text: $server.key, prompt: Text(""))
                .onSubmit { server.saveKey() }
            HStack {
                TextField("Model", text: $server.model, prompt: Text("")).autocorrectionDisabled()
                if !server.availableModels.isEmpty {
                    Menu("Choose") {
                        ForEach(server.availableModels, id: \.self) { name in Button(name) { server.model = name } }
                    }
                    .fixedSize()
                }
            }
            HStack(alignment: .center, spacing: 8) {
                status
                Spacer()
                Button("Check Connection") { Task { await server.checkConnection() } }
                    .disabled(server.check == .checking || TextServer.normalizedURL(server.address) == nil)
            }
            Toggle("Use for summaries", isOn: Binding(get: { server.summaries }, set: { server.use(for: .summary, $0) }))
                .disabled(!server.verified)
            Toggle("Use for translations", isOn: Binding(get: { server.translations }, set: { server.use(for: .translation, $0) }))
                .disabled(!server.verified)
            if let problem = server.addressProblem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Color.errorText)
            } else if let hint = server.enableHint {
                Text(hint).font(.callout).foregroundStyle(.secondary)
            }
            if let error = server.keyError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.errorText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Examples stay out of the fields, where they looked like entered values.
            Text("For example, Server URL https://api.openai.com/v1 with model gpt-4.1-mini, or http://localhost:11434/v1 (Ollama) with qwen3:14b. Local servers usually need no API key.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Any server with the OpenAI chat completions API: OpenAI, OpenRouter, LM Studio, Ollama, vLLM. The meeting title, description and transcript of each summary or translation are sent to this server; use only one you trust. TalkTrack sets no context or response limit; the server's own limits apply. The API key is kept in your Keychain. Recording and transcription always stay on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        switch server.check {
        case .idle: EmptyView()
        case .checking: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
        case .succeeded(let message): Label(message, systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.errorText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
