import Foundation
import TalkTrackDomain

public enum DictationPermission: String, CaseIterable, Sendable {
    case microphone, accessibility, inputMonitoring

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }
}

/// Short messages for the HUD. Refusals start nothing; failures keep the
/// dictated text on the clipboard where it exists.
public enum DictationNotice: Equatable, Sendable {
    case cancelled
    case meetingRecording
    case permissionMissing(DictationPermission)
    case secureInput
    case modelMissing(modelID: String)
    case microphone(String)
    case nothingRecognized
    case pasteManually
    case maximumLength
    case failed(String)

    public var message: String {
        switch self {
        case .cancelled: "Dictation cancelled"
        case .meetingRecording: "A meeting is being recorded. Dictation is available after it stops."
        case .permissionMissing(let permission): "Dictation needs \(permission.title) access. Open Settings ▸ Dictation to grant it."
        case .secureInput: "A password field or another app is blocking keyboard input. Dictation is unavailable here."
        case .modelMissing(let id):
            "\(DictationPreferences.modelTitle(id)) is not downloaded. Download \u{201C}\(DictationPreferences.modelSettingsRow(id))\u{201D} in Settings ▸ Models."
        case .microphone(let message): message
        case .nothingRecognized: "No speech was recognized"
        case .pasteManually: "The window changed. The text is on the clipboard: paste it with ⌘V."
        case .maximumLength: "Maximum length reached; the text was inserted"
        case .failed(let message): "Dictation failed: \(message)"
        }
    }

    /// Offers to open Settings ▸ Models.
    public var opensModelSettings: Bool { if case .modelMissing = self { true } else { false } }
}

public enum DictationHUDState: Equatable, Sendable {
    case hidden
    case recording(waveform: Bool)
    case recognizing
    case notice(DictationNotice)
}

/// Menu-bar state.
public enum DictationActivity: Equatable, Sendable {
    case idle, recording, recognizing
}

public enum DictationDelivery: Equatable, Sendable {
    /// Pasted, or typed as keyboard input, into the starting destination.
    case inserted
    /// The destination changed or could not be verified; the text is on the clipboard.
    case copiedOnly
    case failed(String)
}

public struct DictationHistoryItem: Equatable, Sendable, Identifiable {
    public let id = UUID()
    /// Exactly as delivered, suffix included.
    public let text: String
    public let date: Date
}

/// The AppKit side of dictation: permissions, the focused destination,
/// insertion, HUD, sounds and output muting. Implemented on the main actor.
public protocol DictationHost: Sendable {
    func missingPermission() async -> DictationPermission?
    func isSecureInputActive() async -> Bool
    func isMeetingRecording() async -> Bool
    /// Remembers the frontmost application, window and focused field.
    func captureDestination() async
    /// Pastes into the remembered destination only if it is still focused.
    func deliver(_ text: String, keepPreviousClipboard: Bool) async -> DictationDelivery
    func show(_ state: DictationHUDState) async
    func playStartSound() async
    func playStopSound() async
    /// Mutes system output; returns whether TalkTrack changed it.
    func muteOutput() async -> Bool
    /// Restores only what `muteOutput` changed; calling it again does nothing.
    func restoreOutput() async
}

/// One dictation at a time: idle → recording → recognizing → idle, with
/// refusals, cancellation and the meeting precedence of the spec. All AppKit
/// glue sits behind `DictationHost`, so every path is tested with fakes.
public actor DictationController {
    private enum Phase {
        case idle
        case recording(Session)
        case recognizing(Session, Task<Void, Never>)
    }
    private struct Session {
        let id: UUID
        let settings: DictationSettings
        let lease: InferenceScheduler.InteractiveLease
        let preparation: Task<Void, any Error>
        var reachedLimit = false
    }

    private let inference: DictationInference
    private let audio: DictationAudioSource
    private let host: DictationHost
    private let readSettings: @Sendable () -> DictationSettings
    private var changed: @Sendable (DictationActivity, [DictationHistoryItem]) -> Void
    private var phase = Phase.idle
    /// A press arriving while the previous one is still starting.
    private var starting = false
    private var releasedWhileStarting = false
    public private(set) var history: [DictationHistoryItem] = []

    public init(inference: DictationInference, audio: DictationAudioSource, host: DictationHost,
                settings: @escaping @Sendable () -> DictationSettings = { DictationPreferences.settings() },
                changed: @escaping @Sendable (DictationActivity, [DictationHistoryItem]) -> Void = { _, _ in }) {
        self.inference = inference
        self.audio = audio
        self.host = host
        self.readSettings = settings
        self.changed = changed
    }

    public var activity: DictationActivity {
        switch phase {
        case .idle: .idle
        case .recording: .recording
        case .recognizing: .recognizing
        }
    }

    // MARK: Shortcut events

    public func shortcutPressed() async {
        switch phase {
        case .idle:
            guard !starting else { return }
            await start()
        case .recording(let session):
            // Key repeat in Hold mode; the second press in Toggle mode.
            if session.settings.mode == .toggle { await stop() }
        case .recognizing: break
        }
    }

    public func shortcutReleased() async {
        if starting { releasedWhileStarting = true; return }
        guard case .recording(let session) = phase, session.settings.mode == .hold else { return }
        await stop()
    }

    /// Escape: cancels without inserting. Returns whether a dictation was active,
    /// so the tap passes Escape through otherwise.
    @discardableResult
    public func cancel(notice: DictationNotice = .cancelled) async -> Bool {
        switch phase {
        case .idle: return false
        case .recording(let session):
            phase = .idle
            await audio.cancel()
            await finish(session, notice: notice)
        case .recognizing(let session, let work):
            phase = .idle
            work.cancel()
            await finish(session, notice: notice)
        }
        return true
    }

    /// The meeting recorder calls this before it takes the capture lease.
    public func meetingWillStart() async {
        await cancel()
    }

    /// Turning dictation off cancels a dictation and unloads the model.
    public func disabled() async {
        await cancel()
        await inference.unloadDictation()
    }

    /// Receives the menu-bar state and history after every change.
    public func setChanged(_ changed: @escaping @Sendable (DictationActivity, [DictationHistoryItem]) -> Void) {
        self.changed = changed
        publish()
    }

    /// Quit: no history survives.
    public func clearHistory() {
        history.removeAll()
        publish()
    }

    // MARK: Flow

    private func start() async {
        starting = true
        releasedWhileStarting = false
        defer { starting = false }
        let settings = readSettings()
        if let notice = await refusal(settings) {
            await host.show(.notice(notice))
            return
        }
        let lease: InferenceScheduler.InteractiveLease
        do { lease = try await inference.beginInteractive() }
        catch InferenceSchedulingError.captureActive { await host.show(.notice(.meetingRecording)); return }
        catch { await host.show(.notice(.failed(error.localizedDescription))); return }
        // Loading overlaps speech; preemption of background work starts now too.
        let preparation = Task { [inference] in try await inference.prepareDictation(modelID: settings.modelID, lease: lease) }
        await host.captureDestination()
        let id = UUID()
        // Recording starts first so the first word is never lost to the sound.
        do {
            try await audio.start(maximumSeconds: settings.maximumSeconds) { [weak self] in
                Task { await self?.limitReached(id) }
            }
        } catch {
            preparation.cancel()
            await inference.endInteractive(lease, idleMinutes: settings.idleMinutes)
            await host.show(.notice(.microphone(error.localizedDescription)))
            return
        }
        phase = .recording(Session(id: id, settings: settings, lease: lease, preparation: preparation))
        await host.show(.recording(waveform: settings.showWaveform))
        publish()
        if settings.playSounds { await host.playStartSound() }
        // A dictation that already ended (a very short press, Escape) must not leave output muted.
        if settings.muteOutput, await host.muteOutput(), !isActive(id) { await host.restoreOutput() }
        // A Hold press released before recording started still ends it.
        if releasedWhileStarting, settings.mode == .hold {
            starting = false
            await stop()
        }
    }

    private func isActive(_ id: UUID) -> Bool {
        switch phase {
        case .idle: false
        case .recording(let session), .recognizing(let session, _): session.id == id
        }
    }

    private func refusal(_ settings: DictationSettings) async -> DictationNotice? {
        if await host.isMeetingRecording() { return .meetingRecording }
        if let permission = await host.missingPermission() { return .permissionMissing(permission) }
        if await host.isSecureInputActive() { return .secureInput }
        if await !inference.isInstalled(dictationModel: settings.modelID) { return .modelMissing(modelID: settings.modelID) }
        return nil
    }

    private func limitReached(_ id: UUID) async {
        guard case .recording(var session) = phase, session.id == id else { return }
        session.reachedLimit = true
        phase = .recording(session)
        await stop()
    }

    private func stop() async {
        guard case .recording(let session) = phase else { return }
        let work = Task { await self.recognize(session) }
        phase = .recognizing(session, work)
        publish()
        await work.value
    }

    private func recognize(_ session: Session) async {
        let capture = await audio.finish()
        if session.settings.muteOutput { await host.restoreOutput() }
        if session.settings.playSounds { await host.playStopSound() }
        guard isCurrent(session) else { return }
        // An accidental tap: nothing is recognized or inserted.
        guard capture.spokenSeconds >= DictationMicrophone.minimumSeconds else {
            if capture.deviceFailed { return await complete(session, notice: .microphone("The microphone stopped delivering audio.")) }
            return await complete(session, notice: nil)
        }
        await host.show(.recognizing)
        let recognition: DictationRecognition
        do {
            try await session.preparation.value
            recognition = try await inference.dictate(modelID: session.settings.modelID, samples: capture.samples,
                language: session.settings.language, context: session.settings.recognitionContext, lease: session.lease)
        } catch {
            guard isCurrent(session), !(error is CancellationError) else { return }
            return await complete(session, notice: .failed(error.localizedDescription))
        }
        // Background work resumes before insertion.
        await inference.endInteractive(session.lease, idleMinutes: session.settings.idleMinutes)
        guard isCurrent(session) else { return }
        guard let text = DictationText.process(recognition.text, settings: session.settings, recognizedLanguage: recognition.language) else {
            return await complete(session, notice: .nothingRecognized, leaseEnded: true)
        }
        let delivery = await host.deliver(text, keepPreviousClipboard: session.settings.keepPreviousClipboard)
        if case .failed = delivery {} else {
            history.insert(DictationHistoryItem(text: text, date: Date()), at: 0)
        }
        history = Array(history.prefix(session.settings.historyLength))
        let notice: DictationNotice? = switch delivery {
        case .inserted: capture.reachedLimit || session.reachedLimit ? .maximumLength : nil
        case .copiedOnly: .pasteManually
        case .failed(let message): .failed(message)
        }
        await complete(session, notice: notice, leaseEnded: true)
    }

    private func isCurrent(_ session: Session) -> Bool {
        if case .recognizing(let current, _) = phase { return current.id == session.id }
        return false
    }

    private func complete(_ session: Session, notice: DictationNotice?, leaseEnded: Bool = false) async {
        guard isCurrent(session) else { return }
        phase = .idle
        if !leaseEnded { await inference.endInteractive(session.lease, idleMinutes: session.settings.idleMinutes) }
        await host.show(notice.map { .notice($0) } ?? .hidden)
        publish()
    }

    /// Cancellation path: the session already left `phase`.
    private func finish(_ session: Session, notice: DictationNotice) async {
        session.preparation.cancel()
        if session.settings.muteOutput { await host.restoreOutput() }
        await inference.endInteractive(session.lease, idleMinutes: session.settings.idleMinutes)
        await host.show(.notice(notice))
        publish()
    }

    private func publish() {
        changed(activity, history)
    }
}
