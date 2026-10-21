import SwiftUI
import TalkTrackDomain
import TalkTrackServices

enum MeetingTab: String, CaseIterable, Identifiable {
    case transcript = "Transcript", notes = "Notes", summary = "Summary", translation = "Translation"
    var id: String { rawValue }
}

struct MeetingDetailView: View {
    @Bindable var workspace: WorkspacePresentation
    let services: WorkspaceServices
    let meeting: Meeting
    @Binding var sheet: MeetingSheet?
    @Binding var deleting: Meeting?
    @SceneStorage("meetingTab") private var tab: MeetingTab = .transcript

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let active = workspace.activeMeeting, active.id != meeting.id {
                ActiveRecordingBanner(workspace: workspace, active: active)
            }
            header
                .padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 12)
            Picker("Content", selection: $tab) {
                ForEach(MeetingTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.horizontal, 32)
            if let status = workspace.selectedStatus {
                StatusRow(workspace: workspace, status: status, policy: services.jobPolicy)
                    .padding(.horizontal, 32).padding(.vertical, 10)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            PlayerBar(player: services.player, meetingID: meeting.id, recordings: workspace.recordings,
                      recordingElsewhere: workspace.activeMeeting.map { $0.id != meeting.id } ?? false)
        }
        .navigationTitle("TalkTrack")
        // Auto playback adds the microphone during the final transcript's own replies.
        .task(id: OwnSpeechKey(meetingID: meeting.id, recordings: workspace.recordings, status: workspace.selectedStatus)) {
            await loadOwnSpeech()
        }
        .focusedSceneValue(\.meetingActions, MeetingActions(
            meetingID: meeting.id, tab: $tab, rename: { sheet = .edit(meeting) },
            delete: { if workspace.canDelete(meeting.id) { deleting = meeting } }, canDelete: workspace.canDelete(meeting.id)))
    }

    private struct OwnSpeechKey: Equatable {
        let meetingID: UUID; let recordings: [Recording]; let status: MeetingProcessingStatus?
    }

    private func loadOwnSpeech() async {
        guard let snapshot = try? await services.store.meetingTranscript(meetingID: meeting.id) else { return }
        var intervals: [UUID: [MediaInterval]] = [:]
        for revision in snapshot.revisions where revision.kind == .final {
            intervals[revision.recordingID] = revision.segments.filter { $0.track == .microphone }.map(\.interval)
        }
        services.player.setOwnSpeech(meetingID: meeting.id, intervals: intervals)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                // Selectable text keeps a stale accessibility value when its
                // string changes; recreate it for another meeting or a rename.
                Text(meeting.title).font(.largeTitle.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                    .help(meeting.title)
                    .id("title-\(meeting.id)-\(meeting.title)")
                if !meeting.description.isEmpty {
                    Text(meeting.description).font(.title3).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        .id("description-\(meeting.id)-\(meeting.description)")
                }
                if workspace.activeMeeting?.id == meeting.id, workspace.phase != .idle {
                    // The open recording's duration is saved only at pause/stop; count it live.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(metadata(live: workspace.levels.read().seconds)).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    Text(metadata(live: nil)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 12) {
                HStack(spacing: 8) {
                    Button { sheet = .edit(meeting) } label: { Image(systemName: "pencil") }
                        .help("Rename meeting")
                        .accessibilityLabel("Rename meeting")
                    Button { deleting = meeting } label: { Image(systemName: "trash") }
                        .disabled(!workspace.canDelete(meeting.id))
                        .help(workspace.canDelete(meeting.id) ? "Delete meeting and its audio" : "Stop the recording before deleting this meeting")
                        .accessibilityLabel("Delete meeting")
                }
                .controlSize(.large)
                RecordButtons(workspace: workspace, meetingID: meeting.id)
                if workspace.activeMeeting?.id == meeting.id, workspace.phase != .idle {
                    RecordingIndicator(workspace: workspace)
                }
            }
        }
    }

    /// `live` replaces the saved duration of the recording being captured.
    private func metadata(live: Double?) -> String {
        let count = workspace.recordings.count
        guard count > 0 else { return "No recordings" }
        let open: Set<RecordingState> = [.preparing, .recording, .paused, .stopping]
        let seconds = workspace.recordings.reduce(0) {
            $0 + (live != nil && open.contains($1.state) ? 0 : $1.activeDuration.seconds)
        } + (live ?? 0)
        return "\(count) recording\(count == 1 ? "" : "s") · \(PlayerBar.clock(seconds))"
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .transcript:
            if workspace.recordings.isEmpty {
                ContentUnavailableView("No Recordings Yet", systemImage: "waveform",
                    description: Text("Press Record to capture system audio and your microphone as separate tracks."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptTab(services: services, meetingID: meeting.id)
                    .id("\(meeting.id)-\(workspace.transcriptGeneration)")
            }
        case .notes:
            NotesTab(notes: services.notes, store: services.store, meetingID: meeting.id).id(meeting.id)
        case .summary:
            SummaryTab(services: services, meetingID: meeting.id, captureActive: workspace.phase != .idle)
                .id(meeting.id)
        case .translation:
            TranslationTab(services: services, meetingID: meeting.id, captureActive: workspace.phase != .idle)
                .id(meeting.id)
        }
    }
}

struct RecordButtons: View {
    let workspace: WorkspacePresentation
    let meetingID: UUID

    var body: some View {
        let controls = workspace.controls(for: meetingID)
        HStack(spacing: 8) {
            Button {
                Task { controls.primary == .record ? await workspace.record() : await workspace.stop() }
            } label: {
                if controls.primary == .record {
                    // A bright red dot would look active on a disabled button.
                    Label { Text("Record") } icon: {
                        Image(systemName: "record.circle.fill").foregroundStyle(controls.primaryEnabled ? Color.red : Color.secondary)
                    }
                } else {
                    Label("Stop", systemImage: "stop.fill")
                }
            }
            .disabled(!controls.primaryEnabled)
            .help(controls.primaryHelp)
            Button {
                Task { controls.secondary == .pause ? await workspace.pause() : await workspace.resume() }
            } label: {
                if controls.secondary == .pause { Label("Pause", systemImage: "pause.fill") }
                else { Label("Resume", systemImage: "play.fill") }
            }
            .disabled(!controls.secondaryEnabled)
            .help(controls.secondaryHelp)
        }
        .controlSize(.large)
    }
}

/// Elapsed recording time and live input levels, so it is obvious that
/// capture is running and both sources deliver sound.
struct RecordingIndicator: View {
    let workspace: WorkspacePresentation
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let reading = workspace.levels.read()
            let paused = workspace.phase == .paused
            HStack(spacing: 10) {
                if !compact {
                    Circle().fill(paused ? Color.orange : Color.red)
                        .frame(width: 10, height: 10)
                        // Pulses with the louder source while recording.
                        .scaleEffect(paused ? 1 : 1 + CGFloat(max(reading.microphone, reading.system)) * 0.6)
                        .opacity(paused ? 1 : 0.55 + Double(max(reading.microphone, reading.system)) * 0.45)
                        .animation(.easeOut(duration: 0.1), value: reading)
                        .accessibilityHidden(true)
                    Text(paused ? "Paused" : "REC").font(.callout.weight(.semibold))
                        .foregroundStyle(paused ? Color.pausedText : Color.errorText)
                }
                Text(PlayerBar.clock(reading.seconds)).font(.callout.monospacedDigit())
                LevelBar(symbol: "mic.fill", level: paused ? 0 : reading.microphone, label: "Microphone")
                LevelBar(symbol: "speaker.wave.2.fill", level: paused ? 0 : reading.system, label: "System audio")
                if !paused, reading.systemSilentWhileSpeaking {
                    Label(compact ? "" : "System audio silent", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Color.pausedText)
                        .help(WorkspacePresentation.systemAudioHintText)
                        .accessibilityLabel(WorkspacePresentation.systemAudioHintText)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(paused ? "Paused" : "Recording") \(PlayerBar.clock(reading.seconds))")
        }
        .help("Recording time and input levels: microphone (you) and system audio (other participants)")
    }
}

private struct LevelBar: View {
    let symbol: String
    let level: Float
    let label: String
    private static let segments = 8

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.caption).foregroundStyle(.secondary).frame(width: 14)
            HStack(spacing: 2) {
                ForEach(0..<Self.segments, id: \.self) { index in
                    let lit = Float(index) < level * Float(Self.segments)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(lit ? color(index) : Color.secondary.opacity(0.25))
                        .frame(width: 4, height: 6 + CGFloat(index))
                }
            }
            .frame(height: 14, alignment: .bottom)
            .animation(.easeOut(duration: 0.1), value: level)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(level > 0.05 ? "Sound" : "Silent")
    }

    private func color(_ index: Int) -> Color {
        index >= Self.segments - 1 ? .red : index >= Self.segments - 3 ? .yellow : .green
    }
}

/// Shown while another meeting records: identifies it and leads back to Stop.
struct ActiveRecordingBanner: View {
    let workspace: WorkspacePresentation
    let active: Meeting

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: workspace.phase == .paused ? "pause.circle.fill" : "record.circle.fill")
                .foregroundStyle(workspace.phase == .paused ? Color.orange : Color.red)
            Text("\(workspace.phase == .paused ? "Paused" : "Recording"): \(active.title)").lineLimit(1)
            Spacer()
            RecordingIndicator(workspace: workspace, compact: true)
            Button("Show Recording Meeting") { workspace.showActiveMeeting() }
        }
        .padding(.horizontal, 32).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5))
        .accessibilityElement(children: .contain)
    }
}

struct StatusRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    let workspace: WorkspacePresentation
    let status: MeetingProcessingStatus
    let policy: FinalJobPolicy

    var body: some View {
        HStack(spacing: 8) {
            icon.accessibilityHidden(true)
            // Recreated per message: selectable text keeps a stale accessibility value.
            Text(status.message).font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                .id(status.message)
            if case .waitingForModels(_, let roles) = status, !roles.isEmpty {
                Button("Download Models…") {
                    app.showMissingModels(roles)
                    app.showSettings(openSettings)
                }
                .controlSize(.small)
                .help("Open Settings to download the missing models, then retry")
            }
            if let id = status.retryJobID {
                Button("Retry") { Task { await workspace.retry(jobID: id) } }.controlSize(.small)
                    .help("Process this recording again with its saved settings")
            }
            if case .ready = status {
                Button("Reprocess") { Task { await workspace.reprocess(policy: policy) } }
                    .controlSize(.small)
                    .disabled(!workspace.canReprocess)
                    .help("Transcribe all recordings again with the current models and settings. The current transcript stays until the new one is ready.")
            }
            if case .notProcessed(let recordingID) = status {
                Button("Transcribe") { Task { await workspace.process(recordingID: recordingID, policy: policy) } }
                    .controlSize(.small)
            }
        }
        // Contain, not combine: each action must stay a separate button.
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var icon: some View {
        switch status {
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .recording: Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .queued, .processing: ProgressView().controlSize(.small)
        case .waitingForModels: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
        case .failed, .interrupted: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .notProcessed, .noRecordings: Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }
}

struct TranscriptTab: View {
    @State private var presentation: MeetingTranscriptPresentation
    let player: MeetingPlayer

    init(services: WorkspaceServices, meetingID: UUID) {
        player = services.player
        _presentation = State(initialValue: MeetingTranscriptPresentation(store: services.store, meetingID: meetingID,
                                                                         enrollment: services.enrollment))
    }

    var body: some View {
        MeetingTranscriptView(presentation: presentation, player: player).padding(.top, 4)
    }
}

/// Editable formatted notes; edits autosave and flush when leaving the meeting.
struct NotesTab: View {
    let notes: NotesAutosave
    let store: SessionStore
    let meetingID: UUID
    @StateObject private var controller = NotesEditorController()
    @State private var document = NotesDocument(paragraphs: [])
    @State private var loadID = UUID()
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotesToolbar(controller: controller, isEnabled: loaded)
            if let error {
                Text(error).font(.callout).foregroundStyle(Color.errorText).textSelection(.enabled)
            }
            NotesEditor(document: document, loadID: loadID, isEditable: loaded, controller: controller) { markdown in
                Task {
                    do { try await notes.edit(meetingID: meetingID, text: markdown, format: .markdown); error = nil }
                    catch { self.error = "Notes are not saved yet: \(error.localizedDescription) Your text stays here; keep editing to retry." }
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(controller.isFocused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor),
                                  lineWidth: controller.isFocused ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 16)
        .task {
            do {
                if let pending = try await notes.recoverRevision(meetingID: meetingID) { document = pending.document }
                else { document = try await store.notes(meetingID: meetingID)?.document ?? NotesDocument(paragraphs: []) }
            } catch { self.error = error.localizedDescription }
            loadID = UUID()
            loaded = true
            controller.focus()
        }
        .onDisappear {
            Task { try? await notes.flushForNavigation(leaving: meetingID) }
        }
    }
}

/// The fixed bottom player over the meeting's continuous timeline, with
/// recording boundaries and the date where each new day starts.
struct PlayerBar: View {
    let player: MeetingPlayer
    let meetingID: UUID
    let recordings: [Recording]
    let recordingElsewhere: Bool
    /// The slider value while the user drags; the player seeks on release.
    @State private var scrub: Double?
    @AppStorage(PlaybackTracks.preferenceKey) private var tracks = PlaybackTracks.auto.rawValue

    private struct Marker: Identifiable { let id: UUID; let fraction: Double; let label: String? }

    var body: some View {
        let total = player.duration.seconds
        let shown = scrub ?? player.position.seconds
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 16) {
            Button { player.toggle() } label: {
                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill").frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .disabled(!player.canPlay)
            .help(playHelp)
            .accessibilityLabel(player.state == .playing ? "Pause" : "Play")
            Text("\(Self.clock(shown)) / \(Self.clock(total))").monospacedDigit().foregroundStyle(.secondary)
                .accessibilityLabel("\(Self.clock(shown)) of \(Self.clock(total))")
            // The slider shares the row's center line with the buttons and
            // time; boundary markers and dates hang below it in an overlay.
            Slider(value: Binding(get: { shown }, set: { scrub = $0 }), in: 0...max(total, 1)) { editing in
                guard !editing, let value = scrub else { return }
                if let time = try? MediaTime(seconds: min(value, total)) { player.seek(to: time) }
                scrub = nil
            }
                .disabled(total == 0 || player.captureActive)
                .accessibilityLabel("Playback position")
                .overlay(alignment: .bottom) {
                    GeometryReader { geometry in
                        // Damaged stretches keep their place on the timeline.
                        ForEach(Array(player.damagedAudio.enumerated()), id: \.offset) { _, damage in
                            let start = damage.interval.start.seconds / max(total, 1), end = damage.interval.end.seconds / max(total, 1)
                            Rectangle().fill(.red.opacity(0.7))
                                .frame(width: max(2, geometry.size.width * (end - start)), height: 3)
                                .position(x: geometry.size.width * (start + end) / 2, y: 1.5)
                        }
                        ForEach(markers(total: total)) { marker in
                            ZStack {
                                if marker.fraction > 0 {
                                    Rectangle().fill(.secondary).frame(width: 1, height: 8)
                                        .position(x: geometry.size.width * marker.fraction, y: 4)
                                }
                                if let label = marker.label {
                                    Text(label).font(.caption).foregroundStyle(.secondary).fixedSize()
                                        .position(x: geometry.size.width * marker.fraction + 28, y: 14)
                                }
                            }
                        }
                    }
                    .frame(height: 22)
                    .offset(y: 24)
                    .accessibilityHidden(true)
                }
                // After the overlay, so the slider itself carries the tooltip.
                .help(total == 0 || player.captureActive ? playHelp : "Drag to move through the meeting")
            Menu {
                Picker("Play", selection: $tracks) {
                    ForEach(PlaybackTracks.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: Self.tracksIcon(player.tracks))
            }
            .fixedSize()
            .disabled(total == 0)
            .help(total == 0 ? "Track choice is available once the meeting has recorded audio"
                  : player.tracks == .auto ? "Tracks to play: Auto. The microphone is added only during your own replies in the final transcript, so speaker echo is left out."
                  : "Tracks to play: \(player.tracks.label). When the meeting played through speakers, the microphone repeats it with room echo.")
            .accessibilityLabel("Tracks to play: \(player.tracks.label)")
            Menu(player.speed.label) {
                Picker("Playback speed", selection: Binding(get: { player.speed }, set: { player.speed = $0 })) {
                    ForEach(PlaybackSpeed.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            }
            .fixedSize()
            .disabled(total == 0)
            .help(total == 0 ? "Playback speed is available once the meeting has recorded audio" : "Playback speed")
            .accessibilityLabel("Playback speed \(player.speed.label)")
        }
            PlaybackNotice(player: player, capturing: player.captureActive).padding(.top, 30)
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
        .background(.bar)
        .onChange(of: tracks, initial: true) { player.tracks = PlaybackTracks(rawValue: tracks) ?? .auto }
        .onChange(of: recordings, initial: true) { player.load(meetingID: meetingID, recordings: recordings) }
        .onChange(of: meetingID) { player.load(meetingID: meetingID, recordings: recordings) }
        .onChange(of: recordingElsewhere, initial: true) { player.captureActive = recordingElsewhere || isRecordingHere }
        .onChange(of: isRecordingHere) { player.captureActive = recordingElsewhere || isRecordingHere }
    }

    static func tracksIcon(_ tracks: PlaybackTracks) -> String {
        switch tracks {
        case .auto: "wand.and.stars"
        case .system: "speaker.wave.2"
        case .both: "waveform.and.mic"
        case .microphone: "mic"
        }
    }

    private var isRecordingHere: Bool {
        recordings.contains { [.preparing, .recording, .paused, .stopping].contains($0.state) }
    }

    private var playHelp: String {
        if player.captureActive { return "Playback is unavailable while TalkTrack is recording" }
        if let reason = player.unavailability { return reason.message }
        return player.state == .playing ? "Pause" : "Play"
    }

    /// One marker per recording boundary; a date label where the day changes.
    private func markers(total: Double) -> [Marker] {
        guard total > 0, let timeline = try? MeetingTimeline(meetingID: meetingID,
                                                             recordings: MeetingPlayer.playable(recordings, meetingID: meetingID)) else { return [] }
        var lastDay: String?
        return timeline.recordings.compactMap { item in
            guard let recording = recordings.first(where: { $0.id == item.recordingID }) else { return nil }
            let day = recording.days.first?.localDate
            let label = day != lastDay ? day.flatMap(Self.shortDate) : nil
            lastDay = day
            return Marker(id: item.recordingID, fraction: item.global.start.seconds / total, label: label)
        }
    }

    /// "Recording 2 of 3 · Oct 9, 2026 at 14:03", in the recording's own time zone.
    static func describe(_ info: PlaybackRecordingInfo) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US"); formatter.dateFormat = "MMM d, yyyy 'at' HH:mm"
        formatter.timeZone = TimeZone(identifier: info.timeZoneIdentifier)
        return "Recording \(info.number) of \(info.count) · \(formatter.string(from: info.startedAt))"
    }

    static func shortDate(_ localDate: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: localDate) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US"); formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    static func clock(_ seconds: Double) -> String {
        let value = Int(seconds.rounded(.down))
        let hours = value / 3_600, minutes = value / 60 % 60, rest = value % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// The line under the player: why nothing can play, which recording failed
/// and how to continue, or which stretches are known to be unreadable.
struct PlaybackNotice: View {
    let player: MeetingPlayer
    let capturing: Bool

    var body: some View {
        HStack(spacing: 8) {
            if case let .failed(message, recovery, recordingID) = player.state {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(failure(message, recovery, recordingID)).font(.callout).lineLimit(3).textSelection(.enabled)
                    .id("failure-\(message)-\(recordingID?.uuidString ?? "")")
                Spacer(minLength: 8)
                Button("Try Again") { player.play() }.controlSize(.small)
                    .disabled(!player.canPlay)
                    .help("Play from the same position, for example after restoring the recording files")
                if let next = player.readablePositionAfterFailure {
                    Button("Skip to \(PlayerBar.clock(next.seconds))") { player.seek(to: next); player.play() }
                        .controlSize(.small).disabled(!player.canPlay)
                        .help("Continue after the unreadable audio")
                }
            } else if !player.damagedAudio.isEmpty {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(damage).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    .id("damage-\(damage)")
            } else if let reason = player.unavailability, reason != .noMeeting, !capturing {
                Text(reason.message).font(.callout).foregroundStyle(.secondary)
                    .id("reason-\(reason.message)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func failure(_ message: String, _ recovery: String?, _ recordingID: UUID?) -> String {
        let location = recordingID.flatMap(player.recordingInfo).map { PlayerBar.describe($0) + ": " } ?? ""
        return location + ([message, recovery].compactMap { $0 }.joined(separator: " "))
    }

    private var damage: String {
        let lines = player.damagedAudio.prefix(2).map { item -> String in
            let name = player.recordingInfo(item.recordingID).map(PlayerBar.describe) ?? "A recording"
            let track = item.track == .system ? "system audio" : "microphone"
            return "\(name): \(track) \(PlayerBar.clock(item.interval.start.seconds))–\(PlayerBar.clock(item.interval.end.seconds)) is missing or damaged"
        }
        let more = player.damagedAudio.count > 2 ? " and \(player.damagedAudio.count - 2) more" : ""
        return lines.joined(separator: "; ") + more + ". Playback stops there; the transcript is unaffected."
    }
}

