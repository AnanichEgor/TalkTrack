import SwiftUI
import TalkTrackServices

struct SavedSpeakersView: View {
    @Bindable var presentation: SavedSpeakersPresentation
    /// Plays samples; nil while no library is open.
    var preview: VoiceSamplePreview? = nil
    @State private var deleting: VoiceProfile?
    @State private var removingDay: (profile: VoiceProfile, day: SavedVoiceSampleDay)?
    @State private var recovery: VoiceProfile?

    var body: some View {
        Section("Saved Speakers") {
            Toggle("Recognize saved voices", isOn: $presentation.recognitionEnabled)
                .help("Controls automatic names in future processing. Existing meeting names stay unchanged.")
            Text(presentation.statusText)
                .font(.callout).foregroundStyle(.secondary)
            Text("Voices stay on this Mac. A voice is saved when you name a speaker in a transcript; naming the same person again adds to it. Microphone speech always stays You.")
                .font(.callout).foregroundStyle(.secondary)
            if let merge = presentation.mergeText {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Joining split voices")
                    Text(merge).font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .help("One name is one person: voices you give the same name are joined, different names never are. Pairs of named voices teach how alike one person's voices are.")
            }
            if presentation.voices.isEmpty && presentation.errorMessage == nil {
                Text("No saved speakers").foregroundStyle(.secondary)
            }
            ForEach(presentation.voices) { voice in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            // Recreate selectable text on rename so its accessibility value is not stale.
                            Text(voice.profile.name).fontWeight(.medium).textSelection(.enabled)
                                .lineLimit(1).truncationMode(.tail)
                                .id(voice.profile.name)
                            Text(voice.needsNewSpeech ? "Needs new confirmed speech" : "Voice saved")
                                .font(.caption).foregroundStyle(.secondary)
                        }.layoutPriority(1)
                        Spacer(minLength: 8)
                        HStack(spacing: 8) {
                            if voice.needsNewSpeech {
                                Button("How to Update…") { recovery = voice.profile }
                                    .accessibilityLabel("Update saved voice \(voice.profile.name)")
                            }
                            Button("Rename…") { presentation.beginRename(voice.profile) }
                                .accessibilityLabel("Rename saved speaker \(voice.profile.name)")
                            Button("Delete…", role: .destructive) { deleting = voice.profile }
                                .accessibilityLabel("Delete saved speaker \(voice.profile.name)")
                        }.fixedSize().disabled(presentation.isBusy)
                    }
                    samples(voice.profile)
                }.padding(.vertical, 2)
            }
            Text("Renaming changes future automatic names. Deleting removes all saved voice versions and stops future matches. Existing meeting names and recordings are kept.")
                .font(.callout).foregroundStyle(.secondary)
            if let error = presentation.errorMessage {
                Text(error).foregroundStyle(Color.errorText).textSelection(.enabled)
            }
            HStack {
                Button("Refresh Saved Speakers") { Task { await presentation.refresh() } }
                    .disabled(presentation.isBusy)
                if presentation.isBusy { ProgressView().controlSize(.small) }
            }
        }
        .task { await presentation.refresh() }
        .sheet(isPresented: Binding(get: { presentation.editing != nil }, set: { if !$0 { presentation.cancelRename() } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename Saved Speaker").font(.title2.bold())
                Text("Applies to future automatic names. Names already saved in meetings stay unchanged.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Name", text: $presentation.draftName).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Saved speaker name").disabled(presentation.isBusy)
                if let error = presentation.errorMessage { Text(error).foregroundStyle(Color.errorText) }
                HStack {
                    Spacer()
                    Button("Cancel") { presentation.cancelRename() }.keyboardShortcut(.cancelAction).disabled(presentation.isBusy)
                    Button("Save") { Task { await presentation.saveRename() } }.keyboardShortcut(.defaultAction).disabled(!presentation.canSave)
                }
            }.padding(24).frame(width: 420).fixedSize(horizontal: false, vertical: true)
                .interactiveDismissDisabled(presentation.isBusy)
        }
        .alert("Delete saved speaker?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { profile in
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { deleting = nil; Task { await presentation.delete(profile) } }
        } message: { profile in
            Text("Delete \(profile.name) and all its saved voice versions? Existing meeting names and recordings will be kept.")
        }
        .alert("Remove these samples?", isPresented: Binding(get: { removingDay != nil }, set: { if !$0 { removingDay = nil } }),
               presenting: removingDay) { item in
            Button("Cancel", role: .cancel) { removingDay = nil }
            Button("Remove", role: .destructive) {
                removingDay = nil
                Task { await presentation.remove(item.day.samples, from: item.profile) }
            }
        } message: { item in
            Text("\(item.profile.name) stops learning from all \(item.day.samples.count) samples of \(title(item.day)). Names in the meeting and its recordings are kept.")
        }
        .onDisappear { preview?.stop() }
        .sheet(item: $recovery) { profile in
            VStack(alignment: .leading, spacing: 16) {
                Text("Update \(profile.name)").font(.title2.bold())
                Text("This voice needs fresh speech confirmed with the current speaker models.")
                Text("Open a finalized transcript, select the person's system-audio speaker, and choose Rename Speaker. Pick this saved voice from the suggestions, select Replace incompatible voice evidence, and Save.")
                Text("At least 10 seconds of clean speech in two samples is needed. The saved profile name and previous meeting names are kept. If remembering fails, the existing profile is kept.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { recovery = nil }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 460).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Samples

    @ViewBuilder private func samples(_ profile: VoiceProfile) -> some View {
        let shown = presentation.expanded.contains(profile.id)
        Button {
            Task { await presentation.toggleSamples(profile) }
        } label: {
            Label(presentation.sampleCount(profile.id).map { "Samples (\($0))" } ?? "Samples", systemImage: shown ? "chevron.down" : "chevron.right")
        }
        .buttonStyle(.borderless)
        .help("Speech this voice learned from. Remove a sample that is not this person or is too noisy.")
        .accessibilityLabel(shown ? "Hide samples of \(profile.name)" : "Show samples of \(profile.name)")
        if let undo = presentation.removalUndo, undo.profile.id == profile.id {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text(undo.text).font(.callout).layoutPriority(1)
                Spacer(minLength: 0)
                Button("Undo", systemImage: "arrow.uturn.backward") { Task { await presentation.undoRemoval() } }
                    .fixedSize().disabled(presentation.isBusy)
                    .help("Count the removed samples for \(profile.name) again")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        if shown, let days = presentation.sampleDays[profile.id] {
            if days.isEmpty {
                Text("No samples count for this voice. Name the person in a transcript to teach it again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title(day)).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove All…") { removingDay = (profile, day) }
                            .buttonStyle(.borderless).disabled(presentation.isBusy)
                            .help("Stop \(profile.name) learning from every sample of this day")
                            .accessibilityLabel("Remove all samples of \(title(day)) from \(profile.name)")
                    }
                    ForEach(day.samples) { sample in row(sample, profile: profile) }
                }
                .padding(.leading, 18).padding(.vertical, 2)
            }
            if let error = preview?.errorMessage {
                Text(error).font(.callout).foregroundStyle(Color.errorText)
            }
        }
    }

    private func row(_ sample: SavedVoiceSample, profile: VoiceProfile) -> some View {
        let context = presentation.contexts[sample.id]
        let playing = preview?.playing == sample.id
        return HStack(alignment: .top, spacing: 8) {
            if case .available = context, let preview {
                Button {
                    if playing { preview.stop() } else { Task { await preview.play(sample) } }
                } label: { Image(systemName: playing ? "stop.fill" : "play.fill").frame(width: 14) }
                .buttonStyle(.borderless)
                .help(playing ? "Stop" : "Play this sample's system audio")
                .accessibilityLabel(playing ? "Stop sample" : "Play sample at \(time(sample, context))")
            } else {
                Image(systemName: "speaker.slash").foregroundStyle(.secondary).frame(width: 14)
                    .help(unavailableText(context)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(time(sample, context)) · \(String(format: "%.1f", sample.interval.duration.seconds)) s")
                        .font(.callout.monospacedDigit())
                    if sample.usedForRecognition {
                        Text("Used for recognition").font(.caption).foregroundStyle(.secondary)
                            .help("One of the samples recognition compares new voices with")
                    }
                }
                switch context {
                case .available(let details):
                    if let text = details.text {
                        Text("“\(text)”").font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            .help("From the current transcript")
                    }
                default:
                    // The day's title already names why it cannot play.
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
            Button("Remove") { Task { await presentation.remove([sample], from: profile) } }
                .buttonStyle(.borderless).disabled(presentation.isBusy)
                .help("Stop \(profile.name) learning from this sample")
                .accessibilityLabel("Remove sample at \(time(sample, context)) from \(profile.name)")
        }
        .accessibilityElement(children: .contain)
    }

    private func title(_ day: SavedVoiceSampleDay) -> String {
        guard let first = day.samples.first, case .available(let details) = presentation.contexts[first.id] else {
            return unavailableText(day.samples.first.flatMap { presentation.contexts[$0.id] })
        }
        return "\(details.meetingTitle) · \(details.date)"
    }

    private func time(_ sample: SavedVoiceSample, _ context: VoiceSampleContext?) -> String {
        if case .available(let details) = context, let time = details.time { return "[\(time)]" }
        return MeetingPlaybackClock.text(sample.interval.start)
    }

    private func unavailableText(_ context: VoiceSampleContext?) -> String {
        switch context {
        case .otherLibrary: "From another library"
        case .recordingDeleted: "Recording deleted"
        case .available, nil: "Library not open"
        }
    }
}
