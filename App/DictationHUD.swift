import AppKit
import SwiftUI
import TalkTrackServices

/// A small non-activating panel near the bottom of the screen with keyboard
/// focus: the input waveform while recording, a busy state while recognizing,
/// and short notices. It never takes focus from the destination application.
@MainActor final class DictationHUD {
    /// The screen of the destination window, set when a dictation starts.
    var screen: NSScreen?
    /// Opens Settings ▸ Models from a missing-model notice.
    var openModels: () -> Void = {}
    private let model: HUDModel
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private let level: @Sendable () -> Float

    init(level: @escaping @Sendable () -> Float) {
        self.level = level
        model = HUDModel()
    }

    func show(_ state: DictationHUDState) {
        hideTask?.cancel()
        levelTask?.cancel()
        switch state {
        case .hidden:
            panel?.orderOut(nil)
            return
        case .recording(let waveform):
            model.content = .recording(waveform: waveform)
            model.levels = Array(repeating: 0, count: HUDModel.bars)
            if waveform {
                levelTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        model.levels = Array(model.levels.dropFirst()) + [level()]
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
        case .recognizing:
            model.content = .recognizing
        case .notice(let notice):
            model.content = .notice(notice)
            // Refusals stay a little longer than confirmations.
            let seconds = notice == .cancelled || notice == .maximumLength ? 2.0 : 4.5
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.panel?.orderOut(nil)
            }
        }
        present()
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Only a notice with an action receives clicks.
        if case .notice(let notice) = model.content { panel.ignoresMouseEvents = !notice.opensModelSettings }
        else { panel.ignoresMouseEvents = true }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 56)
        let frame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 80, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(model: model, openModels: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.openModels()
        }))
        return panel
    }
}

@MainActor @Observable private final class HUDModel {
    static let bars = 24
    enum Content: Equatable {
        case recording(waveform: Bool)
        case recognizing
        case notice(DictationNotice)
    }
    var content = Content.recognizing
    var levels = [Float](repeating: 0, count: bars)
}

private struct HUDView: View {
    let model: HUDModel
    let openModels: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch model.content {
            case .recording(let waveform):
                Image(systemName: "mic.fill").foregroundStyle(.red)
                if waveform {
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                            Capsule().fill(.primary.opacity(0.8))
                                .frame(width: 3, height: max(3, CGFloat(level) * 26))
                        }
                    }
                    .frame(height: 28)
                    .animation(.linear(duration: 0.05), value: model.levels)
                } else {
                    Text("Listening…")
                }
            case .recognizing:
                ProgressView().controlSize(.small)
                Text("Recognizing…")
            case .notice(let notice):
                Image(systemName: notice == .cancelled ? "xmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Text(notice.message)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .leading)
                if notice.opensModelSettings {
                    Button("Open Settings", action: openModels)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
