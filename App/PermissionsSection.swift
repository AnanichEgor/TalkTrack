import AppKit
import SwiftUI
import TalkTrackAudio
import TalkTrackServices

/// Every macOS permission TalkTrack uses, in Settings ▸ General.
enum AppPermission: CaseIterable {
    /// ScreenCaptureKit needs the full Screen & System Audio Recording grant;
    /// "System Audio Recording Only" covers Core Audio taps, which TalkTrack does not use.
    case systemAudio
    case microphone
    case accessibility
    case inputMonitoring

    var title: String {
        switch self {
        case .systemAudio: "Screen & System Audio Recording"
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var purpose: String {
        switch self {
        case .systemAudio: "Records other participants from the Mac's audio output during meetings."
        case .microphone: "Records your voice in meetings and while the dictation shortcut is held."
        case .accessibility: "Dictation: checks that the same field still has focus and pastes the text."
        case .inputMonitoring: "Dictation: notices the shortcut in other apps."
        }
    }

    private var dictation: DictationPermission? {
        switch self {
        case .systemAudio: nil
        case .microphone: .microphone
        case .accessibility: .accessibility
        case .inputMonitoring: .inputMonitoring
        }
    }

    var isGranted: Bool {
        guard let dictation else { return SystemAudioCapture.hasAccess }
        return DictationPermissions.isGranted(dictation)
    }

    /// Shows the system prompt where macOS offers one; otherwise opens the pane.
    @MainActor func request() async {
        guard let dictation else {
            if !CGRequestScreenCaptureAccess() { openSettings() }
            return
        }
        await DictationPermissions.request(dictation)
    }

    func openSettings() {
        guard let dictation else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            return
        }
        DictationPermissions.openSettings(dictation)
    }
}

struct PermissionsSection: View {
    let dictation: DictationModel?
    @State private var granted: [AppPermission: Bool] = [:]

    var body: some View {
        Section {
            ForEach(AppPermission.allCases, id: \.self) { permission in
                HStack {
                    Image(systemName: granted[permission] == true ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(granted[permission] == true ? Color.green : Color.pausedText)
                    VStack(alignment: .leading) {
                        Text(permission.title)
                        Text(permission.purpose).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if granted[permission] != true {
                        Button("Grant…") {
                            Task {
                                await permission.request()
                                refresh()
                            }
                        }
                    }
                    Button("Open System Settings") { permission.openSettings() }
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("macOS applies Screen & System Audio Recording and Input Monitoring after TalkTrack restarts.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        granted = Dictionary(uniqueKeysWithValues: AppPermission.allCases.map { ($0, $0.isGranted) })
        dictation?.refresh()
    }
}
