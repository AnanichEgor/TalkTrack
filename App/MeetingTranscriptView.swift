import AppKit
import SwiftUI
import TalkTrackDomain
import TalkTrackServices

/// Committed transcript content, reusable by the meeting workspace. Live rows
/// remain provisional and use their separate capture presentation.
/// What a recording separator's move menu offers.
struct RecordingMoveActions {
    let destinations: [Meeting]
    /// Why a recording cannot move now (it is capturing), or nil.
    let refusal: (UUID) -> String?
    let toMeeting: (UUID, UUID) async -> Void
    /// Opens the New Meeting sheet for the recording.
    let toNewMeeting: (UUID) -> Void
}

/// Splitting a recording in two at a time of its active timeline.
struct RecordingSplitActions {
    /// Why the recording cannot be split at that time, or nil.
    let refusal: (UUID, MediaTime) -> String?
    let split: (UUID, MediaTime) async -> Void
}

/// A split waiting for confirmation.
struct PendingSplit: Identifiable {
    let id = UUID()
    let recordingID: UUID
    let time: MediaTime
    /// `HH:mm:ss` where the new recording will start.
    let label: String

    var title: String { label.isEmpty ? "Split Recording?" : "Split Recording at \(label)?" }
    var message: String {
        "The part from \(label.isEmpty ? "this point" : label) becomes a separate recording in this meeting, with its own separator. "
            + "Its text and speaker names stay; the recording's summary becomes outdated. Use the separator's move menu to send it to another meeting. Splitting cannot be undone."
    }
}

extension View {
    /// Asks before splitting a recording at the chosen time.
    func splitConfirmation(_ splitting: Binding<PendingSplit?>, split: RecordingSplitActions?) -> some View {
        alert(splitting.wrappedValue?.title ?? "",
              isPresented: Binding(get: { splitting.wrappedValue != nil }, set: { if !$0 { splitting.wrappedValue = nil } }),
              presenting: splitting.wrappedValue) { pending in
            Button("Split") { Task { await split?.split(pending.recordingID, pending.time) } }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { pending in
            Text(pending.message)
        }
    }

    /// Layout of one speech block in Transcript and Translation, highlighted
    /// while it is under the playhead.
    func speechBlock(current: Bool) -> some View {
        font(.title3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(current ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(current ? .isSelected : [])
    }
}

extension TranscriptPlaybackIndex {
    /// The block under the playhead, once this meeting has been played or sought.
    @MainActor func highlightedItem(player: MeetingPlayer, meetingID: UUID) -> String? {
        guard player.meetingID == meetingID else { return nil }
        switch player.state {
        case .playing: break
        case .paused, .failed: guard player.position > .zero else { return nil }
        case .unavailable, .ended: return nil
        }
        return activeItem(at: player.position)
    }
}

/// `[time]:`; with timing it plays from that speech.
struct PlaybackTimestamp: View {
    let timestamp: String
    let start: MediaTime?
    let player: MeetingPlayer?
    let meetingID: UUID
    let current: Bool
    let help: String

    var body: some View {
        let label = Text("[\(timestamp)]:").foregroundStyle(.secondary).monospacedDigit()
        if let player, let start {
            Button { player.play(from: start, meetingID: meetingID) } label: { label }
                .buttonStyle(.plain)
                .pointerStyle(player.canPlay ? .link : nil)
                .disabled(!player.canPlay)
                .help(player.captureActive ? "Playback is unavailable while TalkTrack is recording" : help)
                .accessibilityLabel("Play from \(timestamp)")
                .accessibilityValue(current ? "Now playing" : "")
        } else {
            label
        }
    }
}

struct MeetingTranscriptView: View {
    @Bindable var presentation: MeetingTranscriptPresentation
    /// The workspace player. With it, timestamps play from their speech and the
    /// block under the playhead is highlighted; fixtures pass nil.
    var player: MeetingPlayer?
    /// Deletes one recording after confirmation; nil hides the trash buttons.
    var deleteRecording: ((UUID) async -> Void)?
    /// Why a recording cannot be deleted now (it is capturing), or nil.
    var deleteRefusal: (UUID) -> String? = { _ in nil }
    /// Moves one recording to another or a new meeting; nil hides the move buttons.
    var move: RecordingMoveActions?
    /// Splits a recording at a speech block; nil hides the action.
    var split: RecordingSplitActions?
    /// Shown at the left of the action row.
    var export: ExportButton?
    /// The capturing recording's live session, shown as draft rows after its separator.
    var live: LiveTranscriptPresentation?
    var liveRecordingID: UUID?
    /// Opens Settings ▸ Models from the live "models unavailable" message.
    var openModels: (() -> Void)?
    @State private var index: TranscriptPlaybackIndex?
    /// The newest live row is visible; new rows keep it in view.
    @State private var followsLive = true
    @State private var confirmClearNames = false
    @State private var deleting: Recording?
    @State private var splitting: PendingSplit?
    /// `Different Person…` of a review: the name of the new saved voice.
    @State private var differentPerson: VoiceLearningTask?
    @State private var differentName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if presentation.hasSpeakerNames || export != nil {
                HStack {
                    export
                    Spacer()
                    if presentation.hasSpeakerNames {
                        Button("Apply Names", systemImage: "person.2.wave.2") { Task { await presentation.applyNames() } }
                            .disabled(!presentation.canApplyNames)
                            .help(presentation.applicableRecordings.isEmpty
                                  ? "Names can be applied after this meeting's recordings are processed with the current version. Reprocess the meeting first."
                                  : "Rebuild voices from your names without transcribing again: one name becomes one voice, different names stay apart, named replies move to their person.")
                        Button("Clear Speaker Names", systemImage: "person.crop.circle.badge.xmark") { confirmClearNames = true }
                            .disabled(presentation.isBusy)
                            .help("Remove every speaker and reply name in this meeting. Voices show as Voice1, Voice2… until you name them again.")
                    }
                }
                .padding(.horizontal, 32)
            }
            if presentation.noticeMessage != nil || presentation.undo != nil {
                let notice = presentation.noticeMessage ?? "Name saved."
                // A tinted banner, so the Undo of the last Save is noticed.
                // Never give the text `.fixedSize(horizontal: false, vertical: true)`
                // beside the button: that blanked the whole window.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(notice).font(.callout).textSelection(.enabled)
                        .layoutPriority(1)
                        .accessibilityLabel(notice)
                    Spacer(minLength: 0)
                    if let undo = presentation.undo {
                        Button(undo.profileUndone ? "Retry Undo" : "Undo", systemImage: "arrow.uturn.backward") {
                            Task { await presentation.undoLastNaming() }
                        }
                        .fixedSize()
                        .disabled(!presentation.canUndo)
                        .help((undo.created.map { undo.previous == nil
                                ? "Restore the previous names and remove the saved voice \($0.name) created by this Save"
                                : "Restore the previous names and take this Save's speech out of the saved voice \($0.name)" }
                              ?? "Restore the previous names") + " (⌘Z, Edit ▸ Undo Naming)")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.35)))
                .padding(.horizontal, 32)
            }
            draftNamingStatus
            learningStatus
            if let error = presentation.errorMessage {
                HStack(alignment: .center, spacing: 8) {
                    Text(error).font(.callout).foregroundStyle(Color.errorText).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { Task { await presentation.retry() } }
                        .disabled(presentation.isBusy)
                }
                .padding(.horizontal, 32)
            }
            if let snapshot = presentation.snapshot, snapshot.items.isEmpty {
                Text("No transcript yet.").foregroundStyle(.secondary).padding(.horizontal, 40).padding(.top, 12)
            } else if let snapshot = presentation.snapshot {
                let current = highlighted
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(snapshot.items) { item in
                            switch item {
                            case .date(let day):
                                separator(day, in: snapshot)
                                if day.isRecordingStart { draftSection(day.recordingID) }
                            case .speech(let block):
                                // The name flows with the speech, so long names and
                                // text wrap under the timestamp instead of a narrow column.
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    timestamp(block, id: item.id, current: item.id == current)
                                    VStack(alignment: .leading, spacing: 2) {
                                        speech(block, in: snapshot)
                                        annotations(block, in: snapshot)
                                    }
                                }
                                .speechBlock(current: item.id == current)
                                .modifier(RenameActions(enabled: canRename(block, in: snapshot) && !presentation.isBusy,
                                                        namedFragment: block.isNamedFragment, unidentified: block.isUnidentified,
                                    rename: { Task { await presentation.beginRename(recordingID: block.recordingID, segmentID: block.segments[0].id) } },
                                    nameFragment: { Task { await presentation.beginNameFragment(recordingID: block.recordingID, segmentIDs: block.segments.map(\.id)) } },
                                    removeFragment: { Task { await presentation.removeFragmentName(recordingID: block.recordingID, segmentIDs: block.segments.map(\.id)) } },
                                    split: splitAction(block, in: snapshot)))
                                .id(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 32).padding(.vertical, 16)
                }
                // Follow the playhead while playing; a paused or sought
                // position does not move the reader's scroll position.
                .onChange(of: current) { _, id in
                    guard let id, player?.state == .playing else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
                // Live rows: follow the newest unless the reader scrolled up.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
                } action: { _, atEnd in
                    if live != nil { followsLive = atEnd }
                }
                .onChange(of: live?.rows.last?.id) { _, id in
                    guard followsLive, let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let id = live?.rows.last?.id, !followsLive {
                        Button("Newest", systemImage: "arrow.down.circle.fill") {
                            followsLive = true
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                        }
                        .controlSize(.large).padding(20)
                        .help("Show the newest draft text and keep following it")
                    }
                }
                }
            } else if presentation.isBusy { ProgressView("Loading transcript…") }
        }
        .alert("Delete Recording?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { recording in
            Button("Delete", role: .destructive) {
                Task { await deleteRecording?(recording.id) }
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { recording in
            Text(deletionMessage(recording))
        }
        .splitConfirmation($splitting, split: split)
        .confirmationDialog("Clear all speaker names in this meeting?", isPresented: $confirmClearNames) {
            Button("Clear Names", role: .destructive) { Task { await presentation.clearSpeakerNames() } }
        } message: {
            Text("Removes every voice and reply name of this meeting; applying names or reprocessing will not bring them back. Transcript text and saved voices stay unchanged.")
        }
        .sheet(isPresented: Binding(get: { presentation.renameTarget != nil }, set: { if !$0 { presentation.cancelRename() } })) {
            if let target = presentation.renameTarget {
                RenameSpeakerView(presentation: presentation, target: target)
            }
        }
        .sheet(isPresented: Binding(get: { presentation.draftTarget != nil }, set: { if !$0 { presentation.cancelDraftNaming() } })) {
            if let row = presentation.draftTarget {
                DraftNameView(presentation: presentation, row: row)
            }
        }
        .task { await presentation.refresh() }
        .task { await presentation.observeLearning() }
        .alert("Different Person", isPresented: Binding(get: { differentPerson != nil }, set: { if !$0 { differentPerson = nil } })) {
            TextField("Name", text: $differentName)
            Button("Save Voice") {
                if let task = differentPerson {
                    let name = differentName.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await presentation.resolveLearning(task.id, .differentPerson(name: name)) }
                }
            }
            .disabled(differentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves this speech as a new saved voice. The names in this meeting stay unchanged.")
        }
        .onChange(of: IndexKey(items: presentation.snapshot?.items, meetingID: player?.meetingID, duration: player?.duration),
                  initial: true) { rebuildIndex() }
    }

    /// `Split Recording Here`: the new part starts at the block's first speech.
    private func splitAction(_ block: TranscriptBlock, in snapshot: MeetingTranscriptSnapshot) -> SplitMenuItem? {
        guard let split, let recording = snapshot.recordings.first(where: { $0.id == block.recordingID }),
              let time = block.segments.map(\.interval.start).min() else { return nil }
        let refusal = presentation.isBusy ? "Wait until the transcript finishes updating." : split.refusal(recording.id, time)
        return SplitMenuItem(refusal: refusal) {
            splitting = PendingSplit(recordingID: recording.id, time: time, label: recording.clockLabel(at: time))
        }
    }

    /// A recording's separator carries its delete action; a plain date separator
    /// (continuous capture past midnight) does not.
    @ViewBuilder private func separator(_ day: TranscriptDateSeparator, in snapshot: MeetingTranscriptSnapshot) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(day.text).font(.callout).foregroundStyle(.secondary)
                if day.isRecordingStart, deleteRecording != nil,
                   let recording = snapshot.recordings.first(where: { $0.id == day.recordingID }) {
                    if let move { moveMenu(move, recording: recording, day: day) }
                    let refusal = deleteRefusal(recording.id)
                    let enabled = refusal == nil && !presentation.isBusy
                    Button { deleting = recording } label: {
                        Image(systemName: "trash").font(.callout).frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(enabled ? .secondary : .tertiary)
                    .pointerStyle(enabled ? .link : nil)
                    .disabled(!enabled)
                    .help(refusal ?? "Delete Recording")
                    .accessibilityLabel("Delete recording of \(TranscriptDateSeparator.display(day.date)) at \(day.time ?? "")")
                }
            }
            if let note = day.note {
                Text(note).font(.callout).italic().foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }

    /// `New Meeting…` and the other meetings, newest first.
    @ViewBuilder private func moveMenu(_ move: RecordingMoveActions, recording: Recording, day: TranscriptDateSeparator) -> some View {
        let refusal = move.refusal(recording.id)
        let enabled = refusal == nil && !presentation.isBusy
        Menu {
            Button("New Meeting…", systemImage: "plus") { move.toNewMeeting(recording.id) }
            if !move.destinations.isEmpty {
                Section("Move to") {
                    ForEach(move.destinations) { meeting in
                        Button(meeting.title) { Task { await move.toMeeting(recording.id, meeting.id) } }
                    }
                }
            }
        } label: {
            Image(systemName: "arrowshape.turn.up.right").font(.callout).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(enabled ? .secondary : .tertiary)
        .pointerStyle(enabled ? .link : nil)
        .disabled(!enabled)
        .help(refusal ?? "Move Recording to Another Meeting")
        .accessibilityLabel("Move recording of \(TranscriptDateSeparator.display(day.date)) at \(day.time ?? "") to another meeting")
    }

    /// Names the recording by position, date, start time and length, and says what goes and what stays.
    private func deletionMessage(_ recording: Recording) -> String {
        let recordings = (presentation.snapshot?.recordings ?? []).sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
        }
        let position = (recordings.firstIndex { $0.id == recording.id } ?? 0) + 1
        // The same capture-time date and start as its separator shows.
        let start = presentation.snapshot?.items.lazy.compactMap { item -> TranscriptDateSeparator? in
            if case .date(let day) = item, day.recordingID == recording.id, day.isRecordingStart { day } else { nil }
        }.first
        let date = start.map { TranscriptDateSeparator.display($0.date) } ?? ""
        let time = start?.time ?? ""
        let seconds = Int(recording.activeDuration.seconds.rounded())
        let length = seconds < 60 ? "\(seconds) s" : "\(Int((Double(seconds) / 60).rounded())) min"
        return "Recording \(position) of \(recordings.count) · \(date) at \(time) · \(length). "
            + "Its audio, transcript, summary and speaker names for that day are deleted permanently and cannot be recovered. "
            + "The translation keeps only the other recordings. Notes and saved voices stay."
    }

    // MARK: Draft (live-draft-naming)

    /// Draft rows of one recording: the live session while it captures, else its saved draft.
    @ViewBuilder private func draftSection(_ recordingID: UUID) -> some View {
        if let live, liveRecordingID == recordingID {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(live.state.message).font(.callout).foregroundStyle(.secondary)
                    if live.state == .unavailable, let openModels {
                        Button("Open Settings ▸ Models", action: openModels).controlSize(.small)
                    }
                }
                if let issue = live.lastFailureMessage {
                    Text("Live processing issue: \(issue)").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            ForEach(presentation.liveRows(live.rows)) { row in draftRow(row).id(row.id) }
        } else if let rows = presentation.savedDraftRows[recordingID], !rows.isEmpty {
            Text("Draft from the live transcript. The final transcript replaces it and keeps your names.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            ForEach(rows) { row in draftRow(row).id(row.id) }
        }
    }

    /// `[time]: Name - text` with a Draft caption. Selecting a system row's
    /// name opens the draft naming sheet, so voices can be named during a call.
    private func draftRow(_ row: LiveDraftRow) -> some View {
        let canName = row.canNameReply && !presentation.isBusy
        var name = AttributedString(row.label)
        name.font = Self.nameFont
        name.foregroundColor = row.isNamed ? Color.primary : Color.secondary
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("[\(row.timestamp)]:").foregroundStyle(.secondary).monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(name + AttributedString(" - " + row.utterance.text))
                    .lineSpacing(5).textSelection(.enabled)
                    .overlay(alignment: .topLeading) {
                        if row.canNameReply {
                            Button {
                                Task { await presentation.beginDraftNaming(row, scope: row.canNameVoice ? .voice : .reply) }
                            } label: {
                                Text(row.label).font(Self.nameFont).lineSpacing(5).foregroundStyle(.clear).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).pointerStyle(.link).disabled(!canName)
                            .help(row.canNameVoice ? "Name \(row.voiceLabel ?? row.label) now; you can correct it after the meeting"
                                                   : "Several voices overlap here: name only this reply")
                            .accessibilityLabel("Name Speaker: \(row.label), \(row.timestamp)")
                        }
                    }
                Text(draftCaption(row)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.title3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .opacity(0.85)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.text)
        .modifier(DraftActions(enabled: canName, row: row,
            nameReply: { Task { await presentation.beginDraftNaming(row, scope: .reply) } },
            nameVoice: { Task { await presentation.beginDraftNaming(row, scope: .voice) } },
            remove: { Task { await presentation.removeDraftName(row) } }))
    }

    private func draftCaption(_ row: LiveDraftRow) -> String {
        if row.utterance.track == .microphone { return "Draft · microphone" }
        if row.replyName != nil { return "Draft · named reply" }
        if row.voiceName != nil, let voice = row.voiceLabel { return "Draft · \(voice) named" }
        return row.utterance.speakers.count > 1 ? "Draft · overlapping voices" : "Draft"
    }

    /// After publication: what happened to the draft's names, with Remember Voices… per person.
    /// Background voice learning of this meeting (D7): progress lines, a
    /// remembered line that fades, and tinted banners that need the user.
    @ViewBuilder private var learningStatus: some View {
        let notices = presentation.learningNotices
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notices) { task in learningRow(task) }
            }
            .padding(.horizontal, 32)
        }
    }

    @ViewBuilder private func learningRow(_ task: VoiceLearningTask) -> some View {
        let message = MeetingTranscriptPresentation.learningMessage(task)
        let needsUser = [.awaitingReview, .insufficientSpeech, .failed, .superseded].contains(task.state)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch task.state {
            case .running, .queued: ProgressView().controlSize(.mini).accessibilityHidden(true)
            case .learned: Image(systemName: "checkmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            default: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            }
            Text(message).font(.callout).foregroundStyle(needsUser ? .primary : .secondary)
                .textSelection(.enabled).layoutPriority(1).accessibilityLabel(message)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                switch task.state {
                case .queued, .running:
                    Button("Cancel") { Task { await presentation.cancelLearning(task.id) } }
                        .help("Stop learning this voice. The name stays.")
                case .awaitingReview:
                    playMenu(task)
                    Button("Add to \(task.review?.profileName ?? task.name)") {
                        Task { await presentation.resolveLearning(task.id, .add) }
                    }
                    .help("Add this speech to the saved voice anyway")
                    Button("Different Person…") { differentName = ""; differentPerson = task }
                        .help("Save this speech as a new saved voice. The meeting's names stay unchanged.")
                    Button("Don't Remember") { Task { await presentation.resolveLearning(task.id, .dontRemember) } }
                        .help("Keep the name; no saved voice changes")
                case .insufficientSpeech, .failed:
                    Button("Retry") { Task { await presentation.retryLearning(task.id) } }
                    Button("Dismiss") { Task { await presentation.dismissLearning(task.id) } }
                case .learned, .superseded, .cancelled:
                    Button("Dismiss") { Task { await presentation.dismissLearning(task.id) } }
                }
            }
            .fixedSize().controlSize(.small)
        }
        .padding(.horizontal, needsUser ? 12 : 0).padding(.vertical, needsUser ? 8 : 0)
        .background(needsUser ? Color.orange.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .task(id: task.state) {
            // "Remembered" fades after a moment.
            guard task.state == .learned else { return }
            try? await Task.sleep(for: .seconds(5))
            await presentation.dismissLearning(task.id)
        }
    }

    /// Play for a review: each held clip from its start in the meeting's playback.
    @ViewBuilder private func playMenu(_ task: VoiceLearningTask) -> some View {
        let clips = (task.review?.samples ?? []).sorted { ($0.recordingID.uuidString, $0.interval.start) < ($1.recordingID.uuidString, $1.interval.start) }
        let timeline = player?.meetingID == presentation.meetingID ? player?.timeline : nil
        let starts: [(label: String, time: MediaTime)] = clips.compactMap { clip in
            guard let timeline, let time = try? timeline.globalTime(recordingID: clip.recordingID, activeTime: clip.interval.start) else { return nil }
            let recording = presentation.snapshot?.recordings.first { $0.id == clip.recordingID }
            return (recording?.clockLabel(at: clip.interval.start) ?? "", time)
        }.sorted { $0.time < $1.time }
        Menu("Play") {
            ForEach(Array(starts.enumerated()), id: \.offset) { index, start in
                Button("Speech \(index + 1)" + (start.label.isEmpty ? "" : " · \(start.label)")) {
                    player?.play(from: start.time, meetingID: presentation.meetingID)
                }
            }
        }
        .disabled(starts.isEmpty)
        .help(starts.isEmpty ? "Play the meeting once, then play the held speech from here" : "Play the held speech in the meeting")
    }

    @ViewBuilder private var draftNamingStatus: some View {
        let messages = presentation.draftNamingMessages
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(messages, id: \.recordingID) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "person.text.rectangle").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(entry.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        if !entry.people.isEmpty {
                            Menu("Remember Voices…") {
                                ForEach(entry.people, id: \.self) { person in
                                    Button(person) { Task { await presentation.beginRememberDraftVoice(recordingID: entry.recordingID, name: person) } }
                                }
                            }
                            .fixedSize().controlSize(.small)
                            .disabled(presentation.isBusy)
                            .help("Names from the draft are not learned as saved voices. Choose a person to confirm and remember their voice.")
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
        }
    }

    private struct IndexKey: Equatable { let items: [TranscriptDisplayItem]?; let meetingID: UUID?; let duration: MediaTime? }

    /// Timing comes from the timeline the player is actually playing.
    private func rebuildIndex() {
        guard let player, player.meetingID == presentation.meetingID, let timeline = player.timeline,
              let items = presentation.snapshot?.items else { index = nil; return }
        index = TranscriptPlaybackIndex(timeline: timeline, items: items)
    }

    private var highlighted: String? {
        guard let player else { return nil }
        return index?.highlightedItem(player: player, meetingID: presentation.meetingID)
    }

    private func timestamp(_ block: TranscriptBlock, id: String, current: Bool) -> some View {
        PlaybackTimestamp(timestamp: block.timestamp, start: index?.start(of: id), player: player, meetingID: presentation.meetingID,
                          current: current, help: "Play from \(block.timestamp)")
    }
    private func canRename(_ block: TranscriptBlock, in snapshot: MeetingTranscriptSnapshot) -> Bool {
        guard case .system = block.speaker else { return false }
        return snapshot.revisions.contains { $0.recordingID == block.recordingID && $0.kind == .final }
    }

    /// `Name - speech` as one selectable paragraph. Links do not work in
    /// selectable text, so a final system speaker's name gets a transparent
    /// button laid over it: same font, same first-line start, same wrapping.
    private func speech(_ block: TranscriptBlock, in snapshot: MeetingTranscriptSnapshot) -> some View {
        let renamable = canRename(block, in: snapshot)
        let color = block.isUnidentified ? Color.secondary : speakerColor(block.speaker, in: snapshot)
        var name = AttributedString(block.speakerLabel)
        name.font = Self.nameFont
        name.foregroundColor = color
        let text = block.segments.map { $0.correctedText ?? $0.originalText }.joined(separator: " ")
        return Text(name + AttributedString(" - " + text))
            .lineSpacing(5)
            .textSelection(.enabled)
            .help(block.speaker == .microphone ? "Microphone speech always uses You"
                  : block.isUnidentified ? Self.unidentifiedHelp
                  : renamable ? "Select \(block.speakerLabel) to name this voice or correct this reply"
                  : "Provisional speakers can be named after final processing")
            .overlay(alignment: .topLeading) {
                if renamable {
                    Button {
                        Task { await presentation.beginNaming(recordingID: block.recordingID, segmentIDs: block.segments.map(\.id)) }
                    } label: {
                        Text(block.speakerLabel).font(Self.nameFont).lineSpacing(5).foregroundStyle(.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .disabled(presentation.isBusy)
                    .help(block.isUnidentified ? Self.unidentifiedHelp : "Name or correct this speaker")
                    .accessibilityLabel("Name Speaker: \(block.speakerLabel), \(block.timestamp)")
                }
            }
    }

    static let nameFont = Font.title3.weight(.semibold)
    static let unidentifiedHelp = "This phrase is too short, or overlaps another speaker, to match to a voice. Select Unidentified to choose who said it."

    @ViewBuilder private func annotations(_ block: TranscriptBlock, in snapshot: MeetingTranscriptSnapshot) -> some View {
        if case .system(let id) = block.speaker {
            if !snapshot.revisions.contains(where: { $0.recordingID == block.recordingID && $0.kind == .final }) {
                Text("Provisional speaker").font(.caption).foregroundStyle(.secondary)
            } else if block.isAssignedFragment {
                Text("Assigned reply").font(.caption).foregroundStyle(.secondary)
                    .help("You chose this reply's voice. Reprocessing the meeting returns it to Unidentified.")
                    .accessibilityLabel("Assigned reply")
            } else if block.isNamedFragment {
                Text("Named reply").font(.caption).foregroundStyle(.secondary)
                    .help("You named this reply. Apply Names joins it with this person's voice; the other replies of its voice keep their name.")
                    .accessibilityLabel("Named reply")
            } else if let assignment = snapshot.assignments.first(where: { $0.daySpeakerID == id }) {
                switch assignment.origin {
                case .automatic:
                    Text("Automatic").font(.caption).foregroundStyle(.secondary)
                        .help("Matched from a saved voice. Select the speaker name to review or correct it.")
                        .accessibilityLabel("Automatic saved voice match")
                case .linked:
                    Text("Recognized").font(.caption).foregroundStyle(.secondary)
                        .help("Named by comparing this reply's voice with the replies you named. Select the name to confirm or correct it.")
                        .accessibilityLabel("Recognized from your named replies")
                default: EmptyView()
                }
            }
        }
    }

    private func speakerColor(_ speaker: SpeakerReference, in snapshot: MeetingTranscriptSnapshot) -> Color {
        Color.speaker(speaker, order: snapshot.speakers.map(\.id))
    }
}

struct RenameSpeakerView: View {
    @Bindable var presentation: MeetingTranscriptPresentation
    let target: SpeakerRenameTarget
    @FocusState private var nameFocused: Bool
    private var fragment: Bool { presentation.fragmentSegmentIDs != nil }
    private var unidentified: Bool { presentation.namingUnidentified }

    /// The day's voices; choosing one gives this reply to it.
    @ViewBuilder private var dayVoices: some View {
        let voices = presentation.dayVoices
        if !voices.isEmpty {
            VoiceList(title: "Voices of this day (\(voices.count))", count: voices.count) {
                ForEach(voices) { voice in
                    let chosen = presentation.chosenVoiceID == voice.id || (voice.name != nil && presentation.draftName == voice.name)
                    Button { presentation.chooseVoice(voice) } label: {
                        Label(voice.label, systemImage: chosen ? "checkmark.circle.fill" : "person.wave.2")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless).disabled(presentation.isBusy)
                    .help("Give this reply to \(voice.label)")
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(unidentified ? "Who Said This?" : fragment ? "Name This Reply" : "Rename Speaker").font(.title2.bold())
            Text("Current speaker: \(presentation.currentName ?? target.label)").foregroundStyle(.secondary)
            if unidentified {
                Text(presentation.namingLongUnidentified
                     ? "This speech has no speaker yet. Choose a voice of this day or enter a name; only this block changes. Name it only if one person speaks here, because a saved voice learns from all of it."
                     : "This phrase is too short, or overlaps another speaker, to match to a voice. Choose a voice of this day or enter a name; only this reply changes.")
                    .font(.callout).foregroundStyle(.secondary)
                dayVoices
            } else {
                Picker("Apply to", selection: $presentation.scope) {
                    Text("This reply").tag(MeetingTranscriptPresentation.NamingScope.reply)
                    Text("All replies of this voice").tag(MeetingTranscriptPresentation.NamingScope.voice)
                }
                .pickerStyle(.segmented).disabled(presentation.isBusy)
                .help("Correct only this reply, or name every reply of this voice on this meeting day")
            }
            if case .automatic = target.assignmentOrigin {
                Text("This name was matched automatically from a saved voice. Save your correction to make it the confirmed name for this meeting day.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow { Text("Meeting").foregroundStyle(.secondary); Text(target.meetingTitle).textSelection(.enabled) }
                GridRow { Text("Recording day").foregroundStyle(.secondary); Text("\(target.day.localDate) · \(target.day.timeZoneIdentifier)") }
            }
            if !unidentified {
                Text(fragment ? "Only this reply gets the name; the other replies of \(target.label) keep theirs. The correction also teaches recognition, and Apply Names moves the reply to this person's voice."
                              : "Applies to every reply of this voice throughout this meeting day, including matching recordings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextField("Name", text: $presentation.draftName,
                      prompt: Text(presentation.currentName.map { "Current: \($0)" } ?? "Name").foregroundStyle(.tertiary))
                .textFieldStyle(.roundedBorder).focused($nameFocused)
                .accessibilityLabel("Speaker name").disabled(presentation.isBusy)
            if !unidentified || presentation.namingLongUnidentified { savedVoices }
            if presentation.isRemembering {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Learning this voice…").font(.callout)
                    Button("Cancel Remembering") { presentation.cancelRemembering() }
                        .help("Stop learning this voice. The name stays.")
                }
            }
            if let error = presentation.renameError {
                Text(error).foregroundStyle(Color.errorText).font(.callout).textSelection(.enabled)
            }
            HStack {
                if presentation.isBusy && !presentation.isRemembering { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { presentation.cancelRename() }
                    .keyboardShortcut(.cancelAction).disabled(presentation.isBusy)
                Button("Save") { Task { await presentation.saveRename() } }
                    .keyboardShortcut(.defaultAction).disabled(!presentation.canSave)
            }
        }
        .padding(24).frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(presentation.isBusy)
        .onAppear { nameFocused = true }
        .onChange(of: presentation.draftName) { _, name in
            presentation.draftNameChanged()
            // Editing away from a picked suggestion's name lets the typed name decide again.
            if let id = presentation.selectedProfileID, presentation.profiles.first(where: { $0.id == id })?.name != name {
                presentation.clearProfileChoice()
            }
        }
    }

    /// Saved voices first, filtered by the typed name; what Save will do with the voice.
    @ViewBuilder private var savedVoices: some View {
        let suggestions = presentation.suggestions
        if !suggestions.isEmpty {
            let total = presentation.profiles.count
            VoiceList(title: suggestions.count == total ? "Saved voices (\(total))" : "Saved voices (\(suggestions.count) of \(total))",
                      count: suggestions.count) {
                ForEach(suggestions) { profile in
                    let current = presentation.currentProfileID == profile.id
                    Button {
                        presentation.chooseProfile(profile)
                    } label: {
                        HStack {
                            Label(profile.name, systemImage: presentation.effectiveProfileID == profile.id ? "checkmark.circle.fill" : "person.wave.2")
                            Spacer()
                            if current { Text("Current").font(.caption).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).disabled(presentation.isBusy)
                    .help("Use the saved voice \(profile.name) and add this speaker's speech to it")
                    .accessibilityLabel(current ? "\(profile.name), current speaker" : profile.name)
                }
            }
        }
        let typed = presentation.draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = presentation.effectiveProfileID, let profile = presentation.profiles.first(where: { $0.id == id }) {
            Text(fragment ? "Save adds this person's named replies to the saved voice \(profile.name), however short, and removes them from any other saved voice." : "Save adds this speaker's speech to the saved voice \(profile.name).")
                .font(.callout).foregroundStyle(.secondary)
            if presentation.selectedProfileNeedsNewSpeech {
                Toggle("Replace incompatible voice evidence", isOn: $presentation.replaceIncompatibleVoice)
                    .disabled(presentation.isBusy)
                Text("This profile needs new confirmed speech. Save creates a replacement voice version; its saved name and previous meeting names stay unchanged.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if !typed.isEmpty {
            Text("Save also remembers this voice locally as a new saved voice, \(typed), when there is enough clear speech (10 seconds in two samples). The name is saved either way.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if let error = presentation.profileLoadError {
            Text(error).font(.callout).foregroundStyle(Color.errorText).textSelection(.enabled)
        }
    }
}

/// A titled list of voices, about six rows tall, scrolling when longer, so
/// every voice can be reached however many are saved.
private struct VoiceList<Rows: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let rows: Rows
    private static var rowHeight: CGFloat { 24 }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { rows.frame(height: Self.rowHeight) }
                    .padding(.horizontal, 6)
            }
            // A half row past six shows that the list continues.
            .frame(height: Self.rowHeight * (count > 6 ? 6.5 : CGFloat(max(count, 1))))
            .scrollIndicators(count > 6 ? .visible : .never)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(title)
        }
    }
}

/// `Split Recording Here` in a block's menu; disabled with its reason.
struct SplitMenuItem {
    let refusal: String?
    let action: () -> Void
}

/// Rename Speaker, fragment names and Split Recording Here from the block's
/// context menu and as VoiceOver actions.
private struct RenameActions: ViewModifier {
    let enabled: Bool
    let namedFragment: Bool
    /// An Unidentified reply has no voice to rename.
    let unidentified: Bool
    let rename: () -> Void
    let nameFragment: () -> Void
    let removeFragment: () -> Void
    var split: SplitMenuItem?

    func body(content: Content) -> some View {
        if enabled || split != nil {
            content
                .contextMenu {
                    if enabled {
                        if !unidentified { Button("Rename Speaker…", action: rename) }
                        Button(unidentified ? "Who Said This…" : "Name This Reply…", action: nameFragment)
                        if namedFragment { Button("Remove Reply Name", action: removeFragment) }
                    }
                    if let split {
                        if enabled { Divider() }
                        Button("Split Recording Here…", systemImage: "scissors", action: split.action)
                            .disabled(split.refusal != nil)
                            .help(split.refusal ?? "Make a separate recording that starts at this reply")
                    }
                }
                .modifier(OptionalAction(name: "Rename Speaker", enabled: enabled && !unidentified, action: rename))
                .modifier(OptionalAction(name: unidentified ? "Who Said This" : "Name This Reply", enabled: enabled, action: nameFragment))
                .modifier(OptionalAction(name: "Remove Reply Name", enabled: enabled && namedFragment, action: removeFragment))
                .modifier(OptionalAction(name: "Split Recording Here", enabled: split != nil && split?.refusal == nil, action: { split?.action() }))
        } else {
            content
        }
    }
}

private struct OptionalAction: ViewModifier {
    let name: String
    let enabled: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(named: name, action) } else { content }
    }
}

/// Draft row actions: context menu and VoiceOver. `You` rows have none.
private struct DraftActions: ViewModifier {
    let enabled: Bool
    let row: LiveDraftRow
    let nameReply: () -> Void
    let nameVoice: () -> Void
    let remove: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .contextMenu {
                    Button("Name This Reply…", action: nameReply)
                    if let voice = row.voiceLabel { Button("Name \(voice)…", action: nameVoice) }
                    if row.isNamed { Button("Remove Name", action: remove) }
                }
                .accessibilityAction(named: "Name This Reply", nameReply)
                .modifier(OptionalAction(name: "Name Voice", enabled: row.canNameVoice, action: nameVoice))
                .modifier(OptionalAction(name: "Remove Name", enabled: row.isNamed, action: remove))
        } else {
            content
        }
    }
}

/// The naming sheet for a draft row: a name, chosen from saved voices and
/// this meeting's names or typed. Draft names never teach saved voices.
struct DraftNameView: View {
    @Bindable var presentation: MeetingTranscriptPresentation
    let row: LiveDraftRow
    @FocusState private var nameFocused: Bool
    private var voice: Bool { presentation.draftScope == .voice }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(voice ? "Name \(row.voiceLabel ?? "Voice")" : "Name This Reply").font(.title2.bold())
            Text("Current speaker: \(presentation.currentName ?? (voice ? row.voiceLabel : nil) ?? row.utterance.speakerLabel)")
                .foregroundStyle(.secondary)
            Text(voice ? "Names every draft reply of this live voice. The final transcript moves the name to the matching voice; you can correct it there."
                       : "Names only this draft reply. The final transcript moves the name to the matching speech.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Name", text: $presentation.draftName,
                      prompt: Text(presentation.currentName.map { "Current: \($0)" } ?? "Name").foregroundStyle(.tertiary))
                .textFieldStyle(.roundedBorder).focused($nameFocused)
                .accessibilityLabel("Speaker name").disabled(presentation.isBusy)
                .onSubmit { Task { await presentation.saveDraftName() } }
            let names = presentation.draftSuggestions
            if !names.isEmpty {
                VoiceList(title: "Saved voices and names in this meeting (\(names.count))", count: names.count) {
                    ForEach(names, id: \.self) { name in
                        Button { presentation.draftName = name } label: {
                            Label(name, systemImage: presentation.draftName == name ? "checkmark.circle.fill" : "person")
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless).disabled(presentation.isBusy)
                        .help("Use the name \(name)")
                    }
                }
            }
            Text("Saved voices learn from this name only after the final transcript, through Remember Voices…")
                .font(.callout).foregroundStyle(.secondary)
            if let error = presentation.renameError {
                Text(error).foregroundStyle(Color.errorText).font(.callout).textSelection(.enabled)
            }
            HStack {
                if presentation.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { presentation.cancelDraftNaming() }
                    .keyboardShortcut(.cancelAction).disabled(presentation.isBusy)
                Button("Save") { Task { await presentation.saveDraftName() } }
                    .keyboardShortcut(.defaultAction).disabled(!presentation.canSaveDraftName)
            }
        }
        .padding(24).frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(presentation.isBusy)
        .onAppear { nameFocused = true }
    }
}
