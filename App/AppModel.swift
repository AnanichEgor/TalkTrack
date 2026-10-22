import AppKit
import Foundation
import SwiftUI
import Observation
import TalkTrackAudio
import TalkTrackDomain
import TalkTrackInferenceRuntime
import TalkTrackServices

/// Services shared by the main window for the opened library.
struct WorkspaceServices {
    let store: SessionStore
    let notes: NotesAutosave
    let enrollment: VoiceProfileEnrollment
    let jobPolicy: FinalJobPolicy
    let player: MeetingPlayer
    let summaries: SummaryJobPipeline
    let runner: FinalJobRunner
    /// The text model for new jobs, read when they are queued (Settings may change it).
    let summaryModel: @MainActor (SummaryModelChoice?) throws -> ModelSnapshot
    let translations: TranslationJobPipeline
    let translationModel: @MainActor () throws -> ModelSnapshot
}

/// Application-lifetime state. It belongs to the App, not to the window, so
/// closing the window never stops a recording or background processing.
@MainActor @Observable final class AppModel {
    enum State {
        case loading
        case failed(String, recovery: String?)
        case ready(WorkspacePresentation, WorkspaceServices)
    }

    enum SettingsTab: Hashable { case general, audio, models, text, speakers, dictation }

    /// Moving the library to another folder (Settings ▸ General).
    enum LibraryMove: Equatable {
        case idle
        case moving(LibraryMigrationProgress?)
        case finished(String)
        case failed(String)
    }

    private(set) var state: State = .loading
    /// Incremented by the File ▸ New Meeting command; the window presents the sheet.
    var newMeetingRequests = 0
    /// Incremented by Edit ▸ Find Meetings; the sidebar focuses its search field.
    var searchFocusRequests = 0
    var settingsTab: SettingsTab = .general
    /// The opened library's root, shown in Settings.
    private(set) var libraryRoot: URL?
    /// Model management lives for the app lifetime, so downloads continue
    /// while the Settings window is closed.
    let models: ModelSettingsPresentation?
    let speakers: SavedSpeakersPresentation
    /// New releases on GitHub (Settings ▸ General ▸ Updates, menu bar).
    let updates = UpdateChecker(currentVersion: AppModel.version)
    /// The user's OpenAI-compatible text server (Settings ▸ Models).
    let textServer = TextServerSettingsPresentation()
    let setupError: String?
    /// System-wide dictation into other apps (Settings ▸ Dictation).
    private(set) var dictation: DictationModel?
    /// Captured from the menu-bar label, so the dictation HUD can open Settings.
    @ObservationIgnored var openSettingsAction: OpenSettingsAction?
    /// Captured from the menu-bar label, so a click on the Dock icon can open the main window.
    @ObservationIgnored var openMainWindowAction: (() -> Void)?
    /// Settings ▸ General: the Dock icon makes TalkTrack easy to find among many
    /// open apps. On by default; off leaves only the menu-bar icon.
    var showsDockIcon = UserDefaults.standard.object(forKey: AppModel.showsDockIconKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsDockIcon, forKey: Self.showsDockIconKey)
            applyDockIcon()
        }
    }
    static let showsDockIconKey = "showsDockIcon"
    private(set) var libraryMove: LibraryMove = .idle
    /// What launch recovery did with an unfinished move, shown in Settings.
    private(set) var moveRecovery: String?
    private var moveTask: Task<Void, Never>?
    private let runtime: InferenceRuntime?
    private let catalog: ModelCatalog?
    private var loading = false

    init() {
        do {
            let runtime = try InferenceRuntime(), catalog = try ModelCatalog.bundled()
            self.runtime = runtime; self.catalog = catalog
            let models = ModelSettingsPresentation(catalog: catalog, control: runtime)
            self.models = models
            setupError = nil
            // The Summary tab's model menu needs installation states before Settings opens.
            Task { await models.refresh() }
        } catch {
            runtime = nil; catalog = nil; models = nil
            setupError = error.localizedDescription
        }
        speakers = SavedSpeakersPresentation(store: VoiceProfileStore(home: Self.profilesHome))
        if let runtime {
            let dictation = DictationModel(inference: runtime, meetingRecording: { [weak self] in self?.isCapturing ?? false })
            dictation.system.hud.openModels = { [weak self] in
                guard let self, let open = openSettingsAction else { return }
                showMissingModels([DictationPreferences.modelRole(DictationPreferences.settings().modelID)])
                showSettings(open, tab: .models)
            }
            self.dictation = dictation
        }
    }

    /// Leaving the Dock deactivates the app; Settings, where the switch is, stays in front.
    func applyDockIcon() {
        NSApp.setActivationPolicy(showsDockIcon ? .regular : .accessory)
        if let settingsWindow, settingsWindow.isVisible { present { [weak self] in self?.settingsWindow } }
    }

    /// Opens Settings in front of every other window. TalkTrack is a menu-bar
    /// app, so it may not be active, and SwiftUI would otherwise leave the
    /// window behind the main window or another app.
    func showSettings(_ open: OpenSettingsAction, tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        NSApp.activate()
        open()
        present { [weak self] in self?.settingsWindow }
    }

    /// Brings the main window (opened by the caller) in front of every other window.
    func showMainWindow() {
        NSApp.activate()
        present { [weak self] in self?.mainWindow }
    }

    /// Set by each window when it appears (see `WindowReader`).
    /// Settings floats above every window in the system, also after switching
    /// to another app; full-screen spaces show it too. Open and save panels run
    /// at the higher modal level, so they still appear over it.
    @ObservationIgnored weak var settingsWindow: NSWindow? {
        didSet {
            guard let settingsWindow else { return }
            settingsWindow.level = .floating
            settingsWindow.hidesOnDeactivate = false
            settingsWindow.collectionBehavior.insert(.fullScreenAuxiliary)
            Self.bringToFront(settingsWindow)
        }
    }
    @ObservationIgnored weak var mainWindow: NSWindow? {
        didSet { mainWindow.map(Self.bringToFront) }
    }

    /// A menu-bar action runs while its menu is still closing, SwiftUI may create
    /// the window later, and macOS may decline or delay activation. Raising the
    /// window again over the next moments keeps it in front in every case.
    private func present(_ window: @escaping @MainActor () -> NSWindow?) {
        Task { @MainActor in
            for delay in [0, 50, 150, 400] {
                try? await Task.sleep(for: .milliseconds(delay))
                window().map(Self.bringToFront)
            }
        }
    }

    /// `orderFrontRegardless` raises the window even when macOS keeps another
    /// app active; it becomes key once activation completes.
    private static func bringToFront(_ window: NSWindow) {
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// From a "needs models" status: show the Models tab with those rows marked.
    func showMissingModels(_ roles: [ModelRole]) {
        models?.request(roles)
        settingsTab = .models
    }

    var player: MeetingPlayer? {
        if case .ready(_, let services) = state { services.player } else { nil }
    }

    var workspace: WorkspacePresentation? {
        if case .ready(let workspace, _) = state { workspace } else { nil }
    }

    /// Quitting must ask first: a recording is starting, running, paused or saving.
    var isCapturing: Bool { (workspace?.phase ?? .idle) != .idle }
    private(set) var isQuitting = false

    var menuBarLabel: String {
        switch workspace?.phase ?? .idle {
        case .idle:
            switch dictation?.activity ?? .idle {
            case .idle: "TalkTrack"
            case .recording: "TalkTrack, dictating"
            case .recognizing: "TalkTrack, recognizing dictation"
            }
        case .paused: "TalkTrack, recording paused"
        default: "TalkTrack, recording"
        }
    }

    var menuBarSymbol: String {
        switch workspace?.phase ?? .idle {
        case .idle:
            switch dictation?.activity ?? .idle {
            case .idle: "waveform"
            case .recording: "mic.fill"
            case .recognizing: "ellipsis.circle"
            }
        case .paused: "pause.circle"
        default: "record.circle"
        }
    }

    /// Called once the user agreed to quit. Downloads pause with their verified
    /// partial files; the workspace stops and saves capture, stops processing
    /// at a checkpoint and writes notes. Returns when exiting is safe.
    func prepareToQuit() async {
        isQuitting = true
        // Output muted by a dictation is restored; dictation history is forgotten.
        await dictation?.shutdown()
        async let downloads: Void = { await self.models?.cancelAll() }()
        if case .ready(let workspace, let services) = state {
            await workspace.prepareToQuit(notes: services.notes)
        }
        await downloads
    }

    func load() async {
        guard !loading else { return }
        if case .ready = state { return }
        if moveTask != nil, case .moving = libraryMove { return }
        loading = true; defer { loading = false }
        state = .loading
        do {
            guard let runtime, let catalog else { throw ServiceError(message: setupError ?? "The model catalog is unavailable", recovery: "Reinstall TalkTrack.") }
            await recoverMoves()
            let library = try await openLibrary()
            libraryRoot = library.root
            let store = try await SessionStore.open(library)
            // The text model saved in Settings, read for every new job.
            let current: @Sendable () -> ModelCatalog = { catalog.selecting(textModel: ProcessingPreferences.textModel()) }
            let policy = FinalJobPolicy.catalog(current, missing: { try await runtime.unavailableFinalModels($0) },
                                                settings: { meeting in
                // The meeting's own language; other options are frozen from current preferences.
                var settings = ProcessingPreferences.snapshot()
                settings.meetingLanguage = meeting.language
                return settings
            })
            // The recorder stops this player before every capture.
            let player = MeetingPlayer(library: library)
            // The tap starts even when denied, so access is confirmed before Record.
            let systemAudioAccess: @Sendable () async throws -> Void = { try await SystemAudioAccess.shared.requireAllowed() }
            let recorder = MeetingRecorder(library: library, store: store,
                                           capture: MeetingRecorder.nativeCapture(selection: { ProcessingPreferences.microphone() }),
                                           playback: player, jobs: policy, systemAudioAccess: systemAudioAccess)
            let pipeline = FinalTranscriptionPipeline(store: store, library: library, inference: runtime)
            // Summaries and translations may run on the user's own text server (Settings ▸ Models);
            // a server has nothing to download.
            let text = RoutedTextInference(local: runtime)
            let localMissing: @Sendable ([ModelSnapshot]) async throws -> [ModelRole] = {
                try await runtime.unavailableFinalModels($0.filter { !TextServer.isServer($0) })
            }
            let summaries = SummaryJobPipeline(store: store, inference: text, missing: localMissing)
            let translations = TranslationJobPipeline(store: store, inference: text, missing: localMissing)
            // Calibrated from the user's own confirmations; until then it
            // returns without reading audio or loading models.
            let recognition = VoiceProfileRecognition(store: store, profiles: VoiceProfileStore(home: Self.profilesHome),
                                                      inference: runtime, calibrateFromConfirmations: true)
            let runner = FinalJobRunner(store: store, kinds: [.finalTranscription, .summary, .translation]) { id in
                let job = try await store.job(id)
                switch job.snapshot.kind {
                case .finalTranscription:
                    _ = try await pipeline.runAndPublish(jobID: id)
                    // Names are optional: a failed match never fails the published transcript.
                    do { _ = try await recognition.recognize(meetingID: job.snapshot.source.meetingID) }
                    catch is CancellationError { throw CancellationError() }
                    catch { NSLog("TalkTrack: saved voice recognition skipped: %@", error.localizedDescription) }
                case .summary: try await summaries.run(jobID: id)
                case .translation: try await translations.run(jobID: id)
                }
            }
            let workspace = WorkspacePresentation(store: store, recorder: recorder, runner: runner)
            // A meeting takes precedence: an active dictation is cancelled before capture.
            workspace.beforeCapture = { [weak self] in await self?.dictation?.meetingWillStart() }
            workspace.unavailableModels = { snapshots in
                var missing: [ModelRole] = []
                for snapshot in snapshots where !TextServer.isServer(snapshot) {
                    // Active models answer without waiting for running inference;
                    // an older job's exact snapshot is checked by the runtime.
                    if let model = catalog.models.first(where: {
                        $0.roles.contains(snapshot.role) && (try? $0.snapshot(for: snapshot.role)) == snapshot }) {
                        if try await !runtime.installState(model.id).isInstalled { missing.append(snapshot.role) }
                    } else if try await !runtime.unavailableFinalModels([snapshot]).isEmpty {
                        missing.append(snapshot.role)
                    }
                }
                return missing
            }
            models?.onChange = { [weak workspace] in Task { await workspace?.refreshMissingModels() } }
            let enrollment = VoiceProfileEnrollment(store: store, profiles: VoiceProfileStore(home: Self.profilesHome), inference: runtime)
            speakers.mergeCalibration = { try await store.mergeCalibration() }
            state = .ready(workspace, WorkspaceServices(store: store, notes: NotesAutosave(store: store),
                                                        enrollment: enrollment, jobPolicy: policy, player: player,
                                                        summaries: summaries, runner: runner,
                                                        summaryModel: { choice in
                                                            switch choice {
                                                            case .server:
                                                                guard let server = TextServerPreferences.server() else { throw TextServerError.notConfigured }
                                                                return try server.snapshot(for: .summary)
                                                            case .local(let id):
                                                                return try catalog.selecting(textModel: id).model(for: .summary).snapshot(for: .summary)
                                                            case nil:
                                                                return try current().model(for: .summary).snapshot(for: .summary)
                                                            }
                                                        },
                                                        translations: translations,
                                                        translationModel: {
                                                            try TextServerPreferences.snapshot(for: .translation)
                                                                ?? current().model(for: .translation).snapshot(for: .translation) }))
            await workspace.start()
        } catch {
            state = .failed(error.localizedDescription, recovery: (error as? LocalizedError)?.recoverySuggestion)
        }
    }

    /// The library the location record names (after a move); otherwise the
    /// default owned library, or in Debug a fixture root given with
    /// `--workspace-library <dir>`. A recorded location that cannot be opened
    /// is an error, never a reason to open another library.
    private func openLibrary() async throws -> OpenedLibrary {
        if let location = try Self.locations.load() {
            let library = try await OwnedLibrary().resume(location)
            if library.bookmarkWasStale { try Self.locations.save(library.makeLocation()) }
            return library
        }
        if let root = Self.fixtureRoot { return try await OwnedLibrary().open(root: root) }
        return try await OwnedLibrary().openDefault()
    }

    private static var locations: LibraryLocationStore {
        LibraryLocationStore(support: profilesHome.appendingPathComponent("Library/Application Support/TalkTrack", isDirectory: true))
    }

    private static var migrator: LibraryMigrator {
        LibraryMigrator(locations: locations, modelsRoot: ModelDownloadFiles.defaultRoot)
    }

    /// Finishes or rolls back a move interrupted by a crash, before any library opens.
    private func recoverMoves() async {
        do {
            let results = try await Self.migrator.recover()
            moveRecovery = results.map { result in
                switch result {
                case .discarded(let source): "An interrupted library move was undone. The library stays in \(source)."
                case .completed(let destination): "An interrupted library move was completed. The library is now in \(destination)."
                case .cleanupPending(let source, let items):
                    "The library was moved, but \(items) item(s) in the old library folder in \(source) were not created by TalkTrack and were kept. Remove them yourself if you no longer need them."
                case .sourceUnavailable(let source):
                    "The library was moved. The old library folder in \(source) is unavailable; its files will be removed after it is reconnected and TalkTrack is relaunched."
                case .destinationUnavailable(let destination):
                    "An interrupted library move left a partial copy in \(destination), which is unavailable. Reconnect it and relaunch TalkTrack to remove the copy. The library stays where it was."
                }
            }.joined(separator: "\n").nilIfEmpty
        } catch {
            moveRecovery = "Could not check for an interrupted library move: \(error.localizedDescription)"
        }
    }

    /// Checks a destination while the library stays open.
    func planMove(to destination: URL) async throws -> LibraryMigrationPlan {
        guard case .ready(_, let services) = state else { throw LibraryMigrationError.destinationUnavailable(destination.path) }
        return try await Self.migrator.plan(source: services.store.library, destination: destination, recording: isCapturing)
    }

    /// Stops processing and closes the library, moves it, then reopens the
    /// authoritative one: the new folder on success, the old one otherwise.
    /// Interrupted processing is queued again and continues after reopening.
    func moveLibrary(to destination: URL) {
        guard moveTask == nil, case .ready(let workspace, let services) = state, !isCapturing else { return }
        libraryMove = .moving(nil)
        moveTask = Task {
            defer { moveTask = nil }
            services.player.pause()
            await workspace.prepareToQuit(notes: services.notes)
            let source = services.store.library
            do {
                try await services.store.close()
                state = .loading
                let outcome = try await Self.migrator.migrate(source: source, destination: destination) { progress in
                    Task { @MainActor in
                        if case .moving = self.libraryMove { self.libraryMove = .moving(progress) }
                    }
                }
                libraryMove = .finished(outcome.cleanupPending == 0
                    ? "The library was moved to \(destination.path)."
                    : "The library was moved to \(destination.path). \(outcome.cleanupPending) item(s) in the old library folder were not created by TalkTrack and were kept.")
            } catch LibraryMigrationError.cancelled {
                libraryMove = .finished("The move was cancelled. The library stays in \(source.root.path).")
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                libraryMove = .failed("The library was not moved and stays in \(source.root.path). \(reason)")
            }
            state = .loading
            await load()
        }
    }

    func cancelMove() { moveTask?.cancel() }

    /// A moved library whose folder cannot be opened (renamed, on a disk that
    /// was reconnected elsewhere): the user points at it again. Only the same
    /// library is accepted; nothing is created.
    var canLocateLibrary: Bool { (try? Self.locations.load()) != nil }

    func locateLibrary(at folder: URL) async {
        let root = folder.lastPathComponent == OwnedLibrary.directoryName ? folder.deletingLastPathComponent() : folder
        do {
            guard let location = try Self.locations.load() else { return }
            let library = try await OwnedLibrary().open(root: root, expectedID: location.libraryID, allowCreate: false)
            try Self.locations.save(library.makeLocation())
            state = .loading
            await load()
        } catch {
            state = .failed(error.localizedDescription, recovery: "Choose the folder that contains this library's .talktrack-library folder.")
        }
    }

    func dismissMoveResult() { if moveTask == nil { libraryMove = .idle } }

    private static var fixtureRoot: URL? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--workspace-library"), index + 1 < args.count {
            return URL(fileURLWithPath: args[index + 1])
        }
        #endif
        return nil
    }

    /// Voice profiles stay inside a fixture library, never in the real home.
    private static var profilesHome: URL {
        fixtureRoot?.appendingPathComponent("fixture-home") ?? FileManager.default.homeDirectoryForCurrentUser
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
