import SwiftUI
import TalkTrackServices

struct SavedSpeakersView: View {
    @Bindable var presentation: SavedSpeakersPresentation
    @State private var deleting: VoiceProfile?
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
                VStack(alignment: .leading, spacing: 6) {
                    // Recreate selectable text on rename so its accessibility value is not stale.
                    Text(voice.profile.name).fontWeight(.medium).textSelection(.enabled)
                        .id(voice.profile.name)
                    Text(voice.needsNewSpeech ? "Needs new confirmed speech" : "Voice saved")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Rename…") { presentation.beginRename(voice.profile) }
                            .accessibilityLabel("Rename saved speaker \(voice.profile.name)")
                        if voice.needsNewSpeech {
                            Button("How to Update…") { recovery = voice.profile }
                                .accessibilityLabel("Update saved voice \(voice.profile.name)")
                        }
                        Spacer()
                        Button("Delete…", role: .destructive) { deleting = voice.profile }
                            .accessibilityLabel("Delete saved speaker \(voice.profile.name)")
                    }.disabled(presentation.isBusy)
                }.padding(.vertical, 4)
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
}
