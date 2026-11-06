import AppKit
import SwiftUI
import TalkTrackDomain
import TalkTrackServices
import UniformTypeIdentifiers

/// Imports a Teams session: an audio or video file and, optionally, its DOCX
/// or VTT transcript, into a new meeting or an existing one (import-teams-session).
struct ImportSessionView: View {
    let workspace: WorkspacePresentation
    let policy: FinalJobPolicy?
    /// The meeting to import into when opened from it; nil offers a new meeting first.
    let meetingID: UUID?
    @Environment(\.dismiss) private var dismiss

    private enum Destination: Hashable { case new, existing(UUID) }
    @State private var destination: Destination = .new
    @State private var title = ""
    @State private var titleEdited = false
    @State private var description = ""

    @State private var media: URL?
    @State private var probe: MediaProbe?
    @State private var mediaError: String?
    @State private var probing = false

    @State private var transcriptURL: URL?
    @State private var transcript: TeamsTranscript?
    @State private var transcriptError: String?

    @State private var start = Date()
    @State private var startSource: ImportStartTime?
    @State private var startEdited = false
    @State private var rememberVoices = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Session").font(.title2.bold())
                Text("Add a Teams recording and, optionally, its transcript. You can drop files here.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            card {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Meeting").gridColumnAlignment(.trailing)
                        Picker("Meeting", selection: $destination) {
                            Text("New Meeting").tag(Destination.new)
                            if !workspace.allMeetings.isEmpty { Divider() }
                            ForEach(workspace.allMeetings) { meeting in
                                Text(meeting.title).tag(Destination.existing(meeting.id))
                            }
                        }
                        .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if destination == .new {
                        GridRow {
                            Text("Title")
                            TextField("Title", text: Binding(get: { title }, set: { if $0 != title { title = $0; titleEdited = true } }),
                                      prompt: Text("Required"))
                        }
                        GridRow {
                            Text("Description")
                            TextField("Description", text: $description, prompt: Text("Optional"), axis: .vertical)
                                .lineLimit(2...4)
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            card {
                fileTile(icon: "film", kind: "Recording", url: media, detail: mediaDetail, error: mediaError,
                         busy: probing, choose: chooseMedia, remove: nil)
                Divider()
                fileTile(icon: "doc.text", kind: "Transcript", url: transcriptURL, detail: transcriptDetail,
                         error: transcriptError, busy: false, choose: chooseTranscript,
                         remove: transcriptURL == nil ? nil : { setTranscript(nil) })
            }
            card {
                HStack(alignment: .center, spacing: 8) {
                    Text("Started")
                    Spacer(minLength: 8)
                    if let label = startSourceLabel {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                    DatePicker("Started", selection: Binding(get: { start }, set: { if $0 != start { start = $0; startEdited = true } }))
                        .labelsHidden()
                }
                if transcript != nil {
                    Divider()
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Remember participants’ voices")
                            Text("Learn each named voice in the background, so later meetings recognize it.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .layoutPriority(1)
                        Spacer(minLength: 8)
                        Toggle("Remember participants’ voices", isOn: $rememberVoices)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
            }
            Text(footnote).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(Color.errorText).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { startImport() }
                    .keyboardShortcut(.defaultAction).disabled(!canImport)
            }
        }
        .padding(20).frame(width: 520)
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls where url.isFileURL { accept(url) }
            return !urls.isEmpty
        }
        .onAppear {
            if let meetingID { destination = .existing(meetingID) }
        }
        #if DEBUG && TALKTRACK_DEVTOOLS
        .onReceive(NotificationCenter.default.publisher(for: .reviewImportFile)) { note in
            if let url = note.object as? URL { accept(url) }
        }
        #endif
    }

    // MARK: Layout

    /// One rounded group; every card shares the sheet's left edge.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    /// A file slot: its icon, the file (or what belongs here) and its details or error, then the buttons.
    private func fileTile(icon: String, kind: String, url: URL?, detail: String?, error: String?, busy: Bool,
                          choose: @escaping () -> Void, remove: (() -> Void)?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.title2).frame(width: 28)
                .foregroundStyle(url == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(url?.lastPathComponent ?? kind).lineLimit(1).truncationMode(.middle)
                    .help(url?.lastPathComponent ?? "")
                if let error {
                    Text(error).font(.caption).foregroundStyle(Color.errorText)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else if let detail {
                    Text(url == nil ? detail : "\(kind) · \(detail)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Import without a transcript").accessibilityLabel("Remove transcript")
            }
            Button(url == nil ? "Choose…" : "Change…", action: choose).fixedSize()
        }
    }

    private var mediaDetail: String? {
        guard let probe else { return media == nil ? "Teams audio or video · MP4, MOV, M4A, MP3, WAV" : nil }
        return "\(probe.kind) · \(Self.duration(probe.duration.seconds))"
    }

    private var transcriptDetail: String? {
        guard let transcript else { return transcriptURL == nil ? "Optional · DOCX or VTT from Teams" : nil }
        let replies = transcript.replies.count, names = transcript.names.count
        return "\(replies) \(replies == 1 ? "reply" : "replies") · \(names) \(names == 1 ? "speaker" : "speakers")"
    }

    private var startSourceLabel: String? {
        if startEdited { return "Set by you" }
        return startSource?.label
    }

    private var footnote: String {
        if transcript != nil {
            return "The transcript becomes the meeting’s transcript with its speakers’ names. Only the audio is kept from a video."
        }
        return "The recording is transcribed after import. Only the audio is kept from a video."
    }

    private var canImport: Bool {
        guard probe != nil, mediaError == nil, transcriptError == nil, !probing else { return false }
        if destination == .new, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        let target: UUID? = if case .existing(let id) = destination { id } else { nil }
        return workspace.importRefusal(into: target) == nil
    }

    // MARK: Files

    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SessionMedia.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose the meeting’s audio or video recording."
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { setMedia(url) }
    }

    private func chooseTranscript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["docx", "vtt"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose the transcript downloaded from Teams (DOCX or VTT)."
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { setTranscript(url) }
    }

    /// A dropped file goes to the row its extension belongs to; with both
    /// transcript formats dropped, VTT wins because it carries reply ends.
    private func accept(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "vtt": setTranscript(url)
        case "docx": if transcriptURL?.pathExtension.lowercased() != "vtt" || transcript == nil { setTranscript(url) }
        default: setMedia(url)
        }
    }

    private func setMedia(_ url: URL) {
        media = url; probe = nil; mediaError = nil; probing = true; error = nil
        Task {
            do {
                let result = try await SessionMedia.probe(url)
                guard media == url else { return }
                probe = result
            } catch {
                guard media == url else { return }
                mediaError = Self.message(error)
            }
            if media == url { probing = false; refresh() }
        }
    }

    private func setTranscript(_ url: URL?) {
        transcriptURL = url; transcript = nil; transcriptError = nil; error = nil
        guard let url else { refresh(); return }
        Task {
            let loaded = await Task.detached { Result { try TeamsTranscriptParser.load(url) } }.value
            guard transcriptURL == url else { return }
            switch loaded {
            case .success(let value): transcript = value
            case .failure(let error): transcriptError = Self.message(error)
            }
            refresh()
        }
    }

    /// Re-checks the pair and updates the suggested title and start time.
    private func refresh() {
        // A parse error leaves `transcript` nil and stays; a length mismatch is re-checked.
        if let transcript, let transcriptURL {
            transcriptError = nil
            if let probe {
                do { try transcript.validate(audioDuration: probe.duration, file: transcriptURL.lastPathComponent) }
                catch { transcriptError = Self.message(error) }
            }
        }
        if !titleEdited {
            if let header = transcript?.title.map(TeamsTranscriptParser.suggestedTitle), !header.isEmpty { title = header }
            else if let media { title = TeamsTranscriptParser.suggestedTitle(media.lastPathComponent) }
        }
        if !startEdited, let media {
            let resolved = ImportStartTime.resolve(transcript: transcript, fileName: media.lastPathComponent,
                                                   metadataDate: probe?.creationDate,
                                                   modificationDate: probe?.modificationDate ?? Date())
            start = resolved.date; startSource = resolved
        }
    }

    // MARK: Import

    private func startImport() {
        guard let media else { return }
        do {
            let target: SessionImportRequest.Destination = switch destination {
            case .new: .newMeeting(try ProcessingPreferences.meetingDraft(title: title, description: description))
            case .existing(let id): .existing(id)
            }
            let request = SessionImportRequest(destination: target, media: media, transcript: transcript,
                                               transcriptFile: transcript == nil ? nil : transcriptURL, start: start,
                                               rememberVoices: rememberVoices && transcript != nil,
                                               speakerModels: (try? policy?.models()) ?? [])
            try workspace.importSession(request, policy: policy)
            dismiss()
        } catch {
            self.error = Self.message(error)
        }
    }

    private static func message(_ error: Error) -> String {
        [error.localizedDescription, (error as? LocalizedError)?.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The running import in the sidebar, with its decoded share and Cancel.
struct ImportProgressRow: View {
    let status: WorkspacePresentation.ImportStatus
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Importing “\(status.title)”").font(.callout).lineLimit(1).truncationMode(.middle)
            // The cancel button sits on the bar's line, centered on it.
            HStack(alignment: .center, spacing: 8) {
                ProgressView(value: min(max(status.fraction, 0), 1)).controlSize(.small)
                Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Cancel the import; nothing is added").accessibilityLabel("Cancel import")
            }
        }
    }
}
