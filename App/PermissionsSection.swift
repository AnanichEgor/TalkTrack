import AppKit
import SwiftUI
import TalkTrackAudio
import TalkTrackServices

/// Every macOS permission TalkTrack uses, in Settings ▸ General.
enum AppPermission: CaseIterable {
    /// "System Audio Recording Only" for the Core Audio tap.
    case systemAudio
    case microphone
    case accessibility
    case inputMonitoring

    var title: String {
        switch self {
        case .systemAudio: "System Audio Recording Only"
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

    /// System audio has no status API; its row shows the active check instead.
    var isGranted: Bool {
        guard let dictation else { return false }
        return DictationPermissions.isGranted(dictation)
    }

    /// Shows the system prompt where macOS offers one; otherwise opens the pane.
    @MainActor func request() async {
        guard let dictation else { openSettings(); return }
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

/// The tap starts even when denied, so its status comes from the active check.
private enum SystemAudioStatus: Equatable {
    case checking, allowed, notAllowed, notConfirmed(String?)
}

struct PermissionsSection: View {
    let dictation: DictationModel?
    @State private var granted: [AppPermission: Bool] = [:]
    @State private var systemAudio = SystemAudioStatus.checking
    @State private var checkRunning = false

    var body: some View {
        Section {
            ForEach(AppPermission.allCases, id: \.self) { permission in
                if permission == .systemAudio {
                    systemAudioRow(permission)
                } else {
                    row(permission)
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("macOS may apply System Audio Recording Only and Input Monitoring only after TalkTrack restarts.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    /// macOS shows no prompt for taps, so there is nothing to grant from here:
    /// the user switches TalkTrack on in System Settings and checks again.
    private func systemAudioRow(_ permission: AppPermission) -> some View {
        HStack {
            Group {
                switch systemAudio {
                case .checking: ProgressView().controlSize(.small)
                case .allowed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                case .notAllowed, .notConfirmed: Image(systemName: "xmark.circle").foregroundStyle(Color.pausedText)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading) {
                Text(permission.title)
                Text(permission.purpose).font(.callout).foregroundStyle(.secondary)
                switch systemAudio {
                case .checking: Text("Checking…").font(.callout).foregroundStyle(.secondary)
                case .allowed: Text("Allowed").font(.callout).foregroundStyle(.secondary)
                case .notAllowed:
                    Text("Not allowed. Switch TalkTrack on under System Audio Recording Only, then click Check Again.")
                        .font(.callout).foregroundStyle(Color.pausedText)
                case .notConfirmed(let detail):
                    Text("Not confirmed" + (detail.map { ": \($0)." } ?? ".") + " Check that an output device is available, then click Check Again.")
                        .font(.callout).foregroundStyle(Color.pausedText)
                }
            }
            Spacer()
            if systemAudio != .allowed {
                Button("Check Again") { checkSystemAudio() }.disabled(systemAudio == .checking)
            }
            Button("Open System Settings") { permission.openSettings() }
        }
    }

    private func row(_ permission: AppPermission) -> some View {
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

    private func refresh() {
        granted = Dictionary(uniqueKeysWithValues: AppPermission.allCases.map { ($0, $0.isGranted) })
        dictation?.refresh()
        // Allowed is cached for the launch; otherwise check again (TalkTrack's inaudible tone, ~0.5 s).
        checkSystemAudio()
    }

    private func checkSystemAudio() {
        guard !checkRunning else { return }
        checkRunning = true
        systemAudio = .checking
        Task {
            let report = await SystemAudioAccess.shared.check()
            checkRunning = false
            switch report.state {
            case .allowed: systemAudio = .allowed
            case .denied: systemAudio = .notAllowed
            case .undetermined: systemAudio = .notConfirmed(report.detail)
            }
        }
    }
}
