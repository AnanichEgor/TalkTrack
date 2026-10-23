import AppKit
import SwiftUI
import TalkTrackDomain
import TalkTrackServices

/// Committed transcript content, reusable by the meeting workspace. Live rows
/// remain provisional and use their separate capture presentation.
struct MeetingTranscriptView: View {
    @Bindable var presentation: MeetingTranscriptPresentation
    /// The workspace player. With it, timestamps play from their speech and the
    /// block under the playhead is highlighted; fixtures pass nil.
    var player: MeetingPlayer?
    /// Deletes one recording after confirmation; nil hides the trash buttons.
    var deleteRecording: ((UUID) async -> Void)?
    /// Why a recording cannot be deleted now (it is capturing), or nil.
    var deleteRefusal: (UUID) -> String? = { _ in nil }
    @State private var index: TranscriptPlaybackIndex?
    @State private var confirmClearNames = false
    @State private var deleting: Recording?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if presentation.hasSpeakerNames {
                HStack {
                    Spacer()
                    Button("Apply Names", systemImage: "person.2.wave.2") { Task { await presentation.applyNames() } }
                        .disabled(!presentation.canApplyNames)
                        .help(presentation.applicableRecordings.isEmpty
                              ? "Names can be applied after this meeting's recordings are processed with the current version. Reprocess the meeting first."
                              : "Rebuild voices from your names without transcribing again: one name becomes one voice, different names stay apart, named replies move to their person.")
                    Button("Clear Speaker Names", systemImage: "person.crop.circle.badge.xmark") { confirmClearNames = true }
                        .disabled(presentation.isBusy)
                        .help("Remove every speaker and reply name in this meeting. Voices show as Voice1, Voice2… until you name them again.")
                }
                .padding(.horizontal, 32)
            }
            if let notice = presentation.noticeMessage {
                Text(notice).font(.callout).textSelection(.enabled)
                    .padding(.horizontal, 32)
                    .accessibilityLabel(notice)
            }
            if let error = presentation.errorMessage {
                HStack(alignment: .center, spacing: 8) {
                    Text(error).font(.callout).foregroundStyle(Color.errorText).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { Task { await presentation.refresh() } }
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
                                .font(.title3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(item.id == current ? Color.accentColor.opacity(0.14) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityElement(children: .contain)
                                .accessibilityAddTraits(item.id == current ? .isSelected : [])
                                .modifier(RenameActions(enabled: canRename(block, in: snapshot) && !presentation.isBusy,
                                                        namedFragment: block.isNamedFragment, unidentified: block.isUnidentified,
                                    rename: { Task { await presentation.beginRename(recordingID: block.recordingID, segmentID: block.segments[0].id) } },
                                    nameFragment: { Task { await presentation.beginNameFragment(recordingID: block.recordingID, segmentIDs: block.segments.map(\.id)) } },
                                    removeFragment: { Task { await presentation.removeFragmentName(recordingID: block.recordingID, segmentIDs: block.segments.map(\.id)) } }))
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
        .task { await presentation.refresh() }
        .onChange(of: IndexKey(items: presentation.snapshot?.items, meetingID: player?.meetingID, duration: player?.duration),
                  initial: true) { rebuildIndex() }
    }

    /// A recording's separator carries its delete action; a plain date separator
    /// (continuous capture past midnight) does not.
    @ViewBuilder private func separator(_ day: TranscriptDateSeparator, in snapshot: MeetingTranscriptSnapshot) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(day.text).font(.callout).foregroundStyle(.secondary)
                if day.isRecordingStart, deleteRecording != nil,
                   let recording = snapshot.recordings.first(where: { $0.id == day.recordingID }) {
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

    private struct IndexKey: Equatable { let items: [TranscriptDisplayItem]?; let meetingID: UUID?; let duration: MediaTime? }

    /// Timing comes from the timeline the player is actually playing.
    private func rebuildIndex() {
        guard let player, player.meetingID == presentation.meetingID, let timeline = player.timeline,
              let items = presentation.snapshot?.items else { index = nil; return }
        index = TranscriptPlaybackIndex(timeline: timeline, items: items)
    }

    /// The block under the playhead, once this meeting has been played or sought.
    private var highlighted: String? {
        guard let player, let index, player.meetingID == presentation.meetingID else { return nil }
        switch player.state {
        case .playing: break
        case .paused, .failed: guard player.position > .zero else { return nil }
        case .unavailable, .ended: return nil
        }
        return index.activeItem(at: player.position)
    }

    /// `[time]:`; with timing it plays from that speech.
    @ViewBuilder private func timestamp(_ block: TranscriptBlock, id: String, current: Bool) -> some View {
        let label = Text("[\(block.timestamp)]:").foregroundStyle(.secondary).monospacedDigit()
        if let player, let start = index?.start(of: id) {
            Button { player.play(from: start, meetingID: presentation.meetingID) } label: { label }
                .buttonStyle(.plain)
                .pointerStyle(player.canPlay ? .link : nil)
                .disabled(!player.canPlay)
                .help(player.captureActive ? "Playback is unavailable while TalkTrack is recording" : "Play from \(block.timestamp)")
                .accessibilityLabel("Play from \(block.timestamp)")
                .accessibilityValue(current ? "Now playing" : "")
        } else {
            label
        }
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Voices of this day").font(.callout).foregroundStyle(.secondary)
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
            Text("Current speaker: \(target.label)").foregroundStyle(.secondary)
            if unidentified {
                Text("This phrase is too short, or overlaps another speaker, to match to a voice. Choose a voice of this day or enter a name; only this reply changes.")
                    .font(.callout).foregroundStyle(.secondary)
                dayVoices
            } else {
                Picker("Apply to", selection: $presentation.scope) {
                    Text("This reply").tag(MeetingTranscriptPresentation.NamingScope.reply)
                    Text("All replies of \(target.label)").tag(MeetingTranscriptPresentation.NamingScope.voice)
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
            TextField("Name", text: $presentation.draftName)
                .textFieldStyle(.roundedBorder).focused($nameFocused)
                .accessibilityLabel("Speaker name").disabled(presentation.isBusy)
            if !unidentified { savedVoices }
            if presentation.isRemembering {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking saved speech…").font(.callout)
                    Button("Cancel Remembering") { presentation.cancelRemembering() }
                }
            }
            if let error = presentation.renameError {
                Text(error).foregroundStyle(Color.errorText).font(.callout).textSelection(.enabled)
            }
            HStack {
                if presentation.isBusy { ProgressView().controlSize(.small) }
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved voices").font(.callout).foregroundStyle(.secondary)
                ForEach(suggestions.prefix(6)) { profile in
                    Button {
                        presentation.chooseProfile(profile)
                    } label: {
                        Label(profile.name, systemImage: presentation.effectiveProfileID == profile.id ? "checkmark.circle.fill" : "person.wave.2")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless).disabled(presentation.isBusy)
                    .help("Use the saved voice \(profile.name) and add this speaker's speech to it")
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

/// Rename Speaker and fragment names from the block's context menu and as
/// VoiceOver actions.
private struct RenameActions: ViewModifier {
    let enabled: Bool
    let namedFragment: Bool
    /// An Unidentified reply has no voice to rename.
    let unidentified: Bool
    let rename: () -> Void
    let nameFragment: () -> Void
    let removeFragment: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .contextMenu {
                    if !unidentified { Button("Rename Speaker…", action: rename) }
                    Button(unidentified ? "Who Said This…" : "Name This Reply…", action: nameFragment)
                    if namedFragment { Button("Remove Reply Name", action: removeFragment) }
                }
                .modifier(OptionalAction(name: "Rename Speaker", enabled: !unidentified, action: rename))
                .accessibilityAction(named: unidentified ? "Who Said This" : "Name This Reply", nameFragment)
                .modifier(OptionalAction(name: "Remove Reply Name", enabled: namedFragment, action: removeFragment))
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
