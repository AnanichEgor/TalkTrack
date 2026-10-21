import AppKit
import Carbon.HIToolbox
import SwiftUI
import TalkTrackDomain
import TalkTrackServices

/// Settings ▸ Dictation. Every control is a preference read when the next
/// dictation starts; Enable Dictation and the shortcut apply immediately.
struct DictationSettingsView: View {
    @Bindable var model: AppModel
    let dictation: DictationModel
    @AppStorage(DictationPreferences.enabledKey) private var enabled = true
    @AppStorage(DictationPreferences.modeKey) private var mode = DictationMode.hold.rawValue
    @AppStorage(DictationPreferences.languageKey) private var language = MeetingLanguage.auto.rawValue
    @AppStorage(DictationPreferences.modelKey) private var modelID = DictationPreferences.defaultModelID
    @AppStorage(DictationPreferences.idleMinutesKey) private var idleMinutes = 5
    @AppStorage(DictationPreferences.maximumSecondsKey) private var maximumSeconds = 120
    @AppStorage(DictationPreferences.suffixKey) private var suffix = DictationSuffix.space.rawValue
    @AppStorage(DictationPreferences.formattingKey) private var formatting = false
    @AppStorage(DictationPreferences.fillersKey) private var fillers = false
    @AppStorage(DictationPreferences.waveformKey) private var waveform = true
    @AppStorage(DictationPreferences.soundsKey) private var sounds = true
    @AppStorage(DictationPreferences.muteKey) private var mute = true
    @AppStorage(DictationPreferences.keepClipboardKey) private var keepClipboard = false
    @AppStorage(DictationPreferences.historyKey) private var historyLength = 5

    var body: some View {
        Form {
            Section {
                Toggle("Enable dictation", isOn: $enabled)
                if enabled { availability }
            } footer: {
                Text("Hold the shortcut and speak; the text is typed where the cursor was when you pressed it. Speech is recognized on this Mac; audio and text are never saved.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Shortcut") {
                ShortcutRecorder(dictation: dictation)
                Picker("Mode", selection: $mode) {
                    ForEach(DictationMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Text(mode == DictationMode.toggle.rawValue
                     ? "Press once to start and again to stop. Escape cancels."
                     : "Recording lasts while the shortcut is held. Escape cancels.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Maximum length", selection: $maximumSeconds) {
                    ForEach([30, 60, 120, 300, 600], id: \.self) { Text(Self.duration($0)).tag($0) }
                }
            }
            Section("Recognition") {
                Picker("Language", selection: $language) {
                    ForEach(MeetingLanguage.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Model", selection: $modelID) {
                    ForEach(DictationPreferences.modelIDs, id: \.self) { id in
                        Text(DictationPreferences.modelTitle(id) + (id == DictationPreferences.defaultModelID ? " (faster)" : " (more accurate)")).tag(id)
                    }
                }
                if !isInstalled(modelID) {
                    HStack {
                        Label("\(DictationPreferences.modelTitle(modelID)) is not downloaded.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Color.pausedText)
                        Spacer()
                        Button("Open Models") {
                            model.models?.request([DictationPreferences.modelRole(modelID)])
                            model.settingsTab = .models
                        }
                    }
                }
                Picker("Unload model after", selection: $idleMinutes) {
                    ForEach(DictationPreferences.idleMinuteOptions, id: \.self) { Text(Self.duration($0 * 60) + " idle").tag($0) }
                }
                Text("The model loads when you press the shortcut and stays in memory until dictation is unused for this long. A running summary or transcription pauses for the dictation and then continues.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DictionarySection()
            Section("Text") {
                Picker("After the text, add", selection: $suffix) {
                    ForEach(DictationSuffix.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                if suffix == DictationSuffix.newline.rawValue {
                    Label("In chat apps a new line may send the message.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Color.pausedText)
                }
                Toggle("Spoken formatting commands", isOn: $formatting)
                Text("Say \u{201C}comma\u{201D}, \u{201C}period\u{201D}, \u{201C}new line\u{201D} or \u{201C}запятая\u{201D}, \u{201C}точка\u{201D}, \u{201C}новая строка\u{201D}. Only the commands of the dictation's language apply.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Remove hesitation sounds (um, uh, эм, мм)", isOn: $fillers)
            }
            Section("Feedback") {
                Toggle("Show recording waveform", isOn: $waveform)
                Toggle("Play start and stop sounds", isOn: $sounds)
                Toggle("Mute other audio while recording", isOn: $mute)
            }
            Section("Clipboard and History") {
                Toggle("Keep previous clipboard", isOn: $keepClipboard)
                Text("The dictated text stays on the clipboard. With this on, what was there before is kept in memory for five minutes and can be restored from the menu bar.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Recent dictations in the menu", selection: $historyLength) {
                    ForEach(DictationPreferences.historyOptions, id: \.self) { Text($0 == 0 ? "None" : "\($0)").tag($0) }
                }
                Text("Kept in memory only and cleared when TalkTrack quits.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { dictation.refresh() }
    }

    @ViewBuilder private var availability: some View {
        if dictation.needsRestart {
            Label("macOS applies the new permission after TalkTrack restarts. Quit and open TalkTrack again.", systemImage: "arrow.clockwise")
                .foregroundStyle(Color.pausedText)
        } else if let missing = DictationPermission.allCases.first(where: { dictation.permissions[$0] != true }) {
            Label("Dictation is unavailable: \(missing.title) access is missing.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.pausedText)
            Button("Show Permissions in General") { model.settingsTab = .general }
        } else {
            Label("Ready", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
    }

    private func isInstalled(_ id: String) -> Bool {
        model.models?.items.first { $0.id == id }?.state.isInstalled ?? false
    }

    static func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : seconds % 3600 == 0 ? "\(seconds / 3600) hour" : seconds == 60 ? "1 minute" : "\(seconds / 60) minutes"
    }
}

/// Records a shortcut by pressing it. The global shortcut is paused meanwhile.
private struct ShortcutRecorder: View {
    let dictation: DictationModel
    @State private var shortcut = DictationPreferences.settings().shortcut
    @State private var recording = false
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        LabeledContent("Shortcut") {
            HStack {
                Button(recording ? "Press a shortcut…" : shortcut.displayName(keyName: Self.keyName)) {
                    recording ? stop() : start()
                }
                .frame(minWidth: 160)
                if shortcut != .default {
                    Button("Reset") { save(.default) }
                }
            }
        }
        if let message {
            Text(message).font(.callout).foregroundStyle(Color.pausedText)
        } else {
            Text("A right-side modifier pressed alone (such as Right Option), or a key with ⌃, ⌥ or ⌘.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func start() {
        recording = true
        message = nil
        dictation.recordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        recording = false
        dictation.recordingShortcut = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged {
            let rights: [(UInt16, DictationRightModifier, NSEvent.ModifierFlags)] = [
                (UInt16(kVK_RightOption), .option, .option), (UInt16(kVK_RightCommand), .command, .command),
                (UInt16(kVK_RightControl), .control, .control)]
            // A right-side modifier pressed with no other modifier.
            if let (_, modifier, flag) = rights.first(where: { $0.0 == event.keyCode }),
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == flag {
                save(.rightModifier(modifier))
            }
            return
        }
        var modifiers: DictationModifiers = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        switch DictationShortcut.validate(keyCode: event.keyCode, modifiers: modifiers) {
        case .success(let shortcut): save(shortcut)
        case .failure(let refusal):
            message = refusal.message
            stop()
        }
    }

    private func save(_ new: DictationShortcut) {
        DictationPreferences.setShortcut(new)
        shortcut = new
        message = nil
        stop()
    }

    /// The key's character on the current keyboard layout, falling back to ANSI names.
    static func keyName(_ code: UInt16) -> String? {
        if let named = DictationShortcut.keyName(code), named.count > 1 { return named }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return DictationShortcut.keyName(code) }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var dead: UInt32 = 0, length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes in
            UCKeyTranslate(bytes.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self), code, UInt16(kUCKeyActionDisplay),
                           0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &characters)
        }
        guard status == noErr, length > 0 else { return DictationShortcut.keyName(code) }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// Terms passed to the model as context, and replacement rules applied after recognition.
private struct DictionarySection: View {
    @State private var terms = DictationPreferences.settings().terms.joined(separator: "\n")
    @State private var rules = DictationPreferences.settings().replacements

    var body: some View {
        Section("Dictionary") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Terms, one per line")
                TextEditor(text: $terms)
                    .font(.body)
                    .frame(minHeight: 70, maxHeight: 120)
                    .onChange(of: terms) { _, value in
                        UserDefaults.standard.set(value.split(separator: "\n").map {
                            $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, forKey: DictationPreferences.termsKey)
                    }
                Text(contextNote).font(.callout).foregroundStyle(dropsTerms ? Color.pausedText : .secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Replacements")
                ForEach(rules.indices, id: \.self) { index in
                    HStack {
                        TextField("Heard", text: rule(index, \.heard))
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Written", text: rule(index, \.written))
                        Button {
                            rules.remove(at: index)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove this rule")
                    }
                }
                Button("Add Replacement") { rules.append(DictationReplacement(heard: "", written: "")) }
                Text("Whole words, ignoring case, after recognition: for example \u{201C}ток трек\u{201D} → \u{201C}TalkTrack\u{201D}.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .onChange(of: rules) { _, value in DictationPreferences.setReplacements(value) }
        }
    }

    /// Bound by position; a removed row's late edit is ignored.
    private func rule(_ index: Int, _ field: WritableKeyPath<DictationReplacement, String>) -> Binding<String> {
        Binding(get: { index < rules.count ? rules[index][keyPath: field] : "" },
                set: { if index < rules.count { rules[index][keyPath: field] = $0 } })
    }

    private var dropsTerms: Bool {
        var settings = DictationSettings()
        settings.terms = terms.split(separator: "\n").map(String.init)
        return settings.dropsTerms
    }

    private var contextNote: String {
        dropsTerms
            ? "The list is longer than \(DictationPreferences.contextCharacterLimit) characters; terms at the end are not used."
            : "Names, products and jargon the model should spell as written here."
    }
}
