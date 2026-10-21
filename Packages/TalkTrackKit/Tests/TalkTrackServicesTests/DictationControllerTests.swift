import Foundation
import os
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

private final class Log: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String]())
    func add(_ value: String) { lock.withLock { $0.append(value) } }
    var values: [String] { lock.withLock { $0 } }
}

/// Blocks until opened; used to hold recognition while the test acts.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

private final class FakeInference: DictationInference {
    let log: Log
    let installed: Bool
    let captureActive: Bool
    let text: String
    let gate: Gate?
    let scheduler = InferenceScheduler()
    init(log: Log, installed: Bool = true, captureActive: Bool = false, text: String = "Hello world", gate: Gate? = nil) {
        self.log = log; self.installed = installed; self.captureActive = captureActive; self.text = text; self.gate = gate
    }
    func isInstalled(dictationModel id: String) async -> Bool { installed }
    func beginInteractive() async throws -> InferenceScheduler.InteractiveLease {
        if captureActive { throw InferenceSchedulingError.captureActive }
        log.add("begin")
        return try await scheduler.beginInteractive()
    }
    func prepareDictation(modelID: String, lease: InferenceScheduler.InteractiveLease) async throws { log.add("prepare \(modelID)") }
    func dictate(modelID: String, samples: [Float], language: MeetingLanguage, context: String,
                 lease: InferenceScheduler.InteractiveLease) async throws -> DictationRecognition {
        log.add("dictate \(modelID) \(language.rawValue) [\(context)]")
        try await scheduler.run(priority: .interactive(lease)) { [gate] in
            await gate?.wait()
            try Task.checkCancellation()
        }
        return DictationRecognition(text: text, language: "English")
    }
    func endInteractive(_ lease: InferenceScheduler.InteractiveLease, idleMinutes: Int) async {
        if (try? await scheduler.endInteractive(lease)) != nil { log.add("end \(idleMinutes)") }
    }
    func unloadDictation() async { log.add("unload") }
}

private final class FakeAudio: DictationAudioSource {
    let log: Log
    let spoken: Double
    let failure: (any Error)?
    private let limit = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    init(log: Log, spoken: Double = 2, failure: (any Error)? = nil) { self.log = log; self.spoken = spoken; self.failure = failure }
    func start(maximumSeconds: Int, limitReached: @escaping @Sendable () -> Void) async throws {
        if let failure { throw failure }
        limit.withLock { $0 = limitReached }
        log.add("record \(maximumSeconds)")
    }
    func finish() async -> DictationCapture {
        log.add("finish")
        return DictationCapture(samples: [Float](repeating: 0, count: Int(spoken * 16_000)), spokenSeconds: spoken,
                                tailSeconds: 0.1, reachedLimit: false)
    }
    func cancel() async { log.add("discard audio") }
    func level() -> Float { 0 }
    func reachLimit() { limit.withLock { $0 }?() }
}

private final class FakeHost: DictationHost {
    let log: Log
    let meeting: Bool
    let permission: DictationPermission?
    let delivery: DictationDelivery
    private let state = OSAllocatedUnfairLock(initialState: (hud: [DictationHUDState](), delivered: [String]()))
    init(log: Log, meeting: Bool = false, permission: DictationPermission? = nil, delivery: DictationDelivery = .inserted) {
        self.log = log; self.meeting = meeting; self.permission = permission; self.delivery = delivery
    }
    var hud: [DictationHUDState] { state.withLock { $0.hud } }
    var delivered: [String] { state.withLock { $0.delivered } }
    func missingPermission() async -> DictationPermission? { permission }
    func isSecureInputActive() async -> Bool { false }
    func isMeetingRecording() async -> Bool { meeting }
    func captureDestination() async { log.add("destination") }
    func deliver(_ text: String, keepPreviousClipboard: Bool) async -> DictationDelivery {
        state.withLock { $0.delivered.append(text) }
        return delivery
    }
    func show(_ hud: DictationHUDState) async { state.withLock { $0.hud.append(hud) } }
    func playStartSound() async { log.add("start sound") }
    func playStopSound() async { log.add("stop sound") }
    func muteOutput() async -> Bool { log.add("mute"); return true }
    func restoreOutput() async { log.add("restore") }
}

private struct Rig {
    let log = Log()
    let inference: FakeInference
    let audio: FakeAudio
    let host: FakeHost
    let controller: DictationController

    init(settings: DictationSettings = DictationSettings(), installed: Bool = true, captureActive: Bool = false, gate: Gate? = nil,
         text: String = "Hello world", spoken: Double = 2, audioFailure: (any Error)? = nil, meeting: Bool = false,
         permission: DictationPermission? = nil, delivery: DictationDelivery = .inserted) {
        inference = FakeInference(log: log, installed: installed, captureActive: captureActive, text: text, gate: gate)
        audio = FakeAudio(log: log, spoken: spoken, failure: audioFailure)
        host = FakeHost(log: log, meeting: meeting, permission: permission, delivery: delivery)
        controller = DictationController(inference: inference, audio: audio, host: host, settings: { settings })
    }
}

private func settings(_ change: (inout DictationSettings) -> Void) -> DictationSettings {
    var value = DictationSettings()
    change(&value)
    return value
}

@Suite struct DictationControllerTests {
    @Test func holdToTalkInsertsText() async {
        let rig = Rig(settings: settings { $0.terms = ["TalkTrack"] })
        await rig.controller.shortcutPressed()
        #expect(await rig.controller.activity == .recording)
        await rig.controller.shortcutPressed() // key repeat while held
        await rig.controller.shortcutReleased()
        #expect(rig.host.delivered == ["Hello world "])
        #expect(rig.host.hud == [.recording(waveform: true), .recognizing, .hidden])
        // The lease spans key down to the end of recognition; output is restored.
        // Loading starts concurrently at key down.
        #expect(rig.log.values.contains("prepare live-asr"))
        // Recording starts before the sound, so the first word is kept.
        #expect(rig.log.values.filter { !$0.hasPrefix("prepare") } == ["begin", "destination", "record 120", "start sound", "mute",
            "finish", "restore", "stop sound", "dictate live-asr auto [TalkTrack]", "end 5"])
        #expect(await rig.controller.activity == .idle)
        #expect(await rig.controller.history.map(\.text) == ["Hello world "])
    }

    @Test func pressToToggle() async {
        let rig = Rig(settings: settings { $0.mode = .toggle; $0.language = .russian; $0.modelID = "final-asr" })
        await rig.controller.shortcutPressed()
        await rig.controller.shortcutReleased()
        #expect(await rig.controller.activity == .recording)
        await rig.controller.shortcutPressed()
        #expect(rig.host.delivered == ["Hello world "])
        #expect(rig.log.values.contains("dictate final-asr russian []"))
    }

    @Test func escapeWhileRecordingInsertsNothing() async {
        let rig = Rig()
        await rig.controller.shortcutPressed()
        #expect(await rig.controller.cancel())
        await rig.controller.shortcutReleased()
        #expect(rig.host.delivered.isEmpty)
        #expect(rig.host.hud.last == .notice(.cancelled))
        #expect(rig.log.values.contains("discard audio") && rig.log.values.contains("restore") && rig.log.values.contains("end 5"))
        #expect(!rig.log.values.contains { $0.hasPrefix("dictate") })
        // Escape passes through when nothing is active.
        #expect(await !rig.controller.cancel())
    }

    @Test func escapeWhileRecognizingInsertsNothing() async throws {
        let gate = Gate()
        let rig = Rig(gate: gate)
        await rig.controller.shortcutPressed()
        let release = Task { await rig.controller.shortcutReleased() }
        while !rig.log.values.contains(where: { $0.hasPrefix("dictate") }) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await rig.controller.activity == .recognizing)
        #expect(await rig.controller.cancel())
        await gate.release()
        await release.value
        #expect(rig.host.delivered.isEmpty)
        #expect(rig.host.hud.last == .notice(.cancelled))
        #expect(await rig.controller.history.isEmpty)
    }

    @Test func accidentalTapIsDiscarded() async {
        let rig = Rig(spoken: 0.1)
        await rig.controller.shortcutPressed()
        await rig.controller.shortcutReleased()
        #expect(rig.host.delivered.isEmpty)
        #expect(!rig.log.values.contains { $0.hasPrefix("dictate") })
        #expect(rig.host.hud.last == .hidden)
        #expect(rig.log.values.contains("end 5"))
    }

    @Test func maximumLengthStopsAndInserts() async throws {
        let rig = Rig(settings: settings { $0.mode = .toggle; $0.maximumSeconds = 30 })
        await rig.controller.shortcutPressed()
        rig.audio.reachLimit()
        while await rig.controller.activity != .idle { try await Task.sleep(for: .milliseconds(5)) }
        #expect(rig.log.values.contains("record 30"))
        #expect(rig.host.delivered == ["Hello world "])
        #expect(rig.host.hud.last == .notice(.maximumLength))
    }

    @Test func meetingRecordingRefuses() async {
        let rig = Rig(meeting: true)
        await rig.controller.shortcutPressed()
        #expect(rig.host.hud == [.notice(.meetingRecording)])
        #expect(rig.log.values.isEmpty)
        // The scheduler refuses too when the meeting began meanwhile.
        let racing = Rig(captureActive: true)
        await racing.controller.shortcutPressed()
        #expect(racing.host.hud == [.notice(.meetingRecording)])
        #expect(!racing.log.values.contains { $0.hasPrefix("record") })
    }

    @Test func meetingStartingCancelsDictation() async {
        let rig = Rig()
        await rig.controller.shortcutPressed()
        await rig.controller.meetingWillStart()
        await rig.controller.shortcutReleased()
        #expect(rig.host.delivered.isEmpty)
        #expect(await rig.controller.activity == .idle)
        #expect(rig.log.values.contains("end 5"))
    }

    @Test func missingModelRefusesWithItsName() async {
        let rig = Rig(settings: settings { $0.modelID = "final-asr" }, installed: false)
        await rig.controller.shortcutPressed()
        #expect(rig.host.hud == [.notice(.modelMissing(modelID: "final-asr"))])
        #expect(DictationNotice.modelMissing(modelID: "final-asr").message.contains("Qwen3-ASR 1.7B"))
        #expect(DictationNotice.modelMissing(modelID: "final-asr").opensModelSettings)
        #expect(rig.log.values.isEmpty)
    }

    @Test func missingPermissionRefuses() async {
        let rig = Rig(permission: .accessibility)
        await rig.controller.shortcutPressed()
        #expect(rig.host.hud == [.notice(.permissionMissing(.accessibility))])
        #expect(rig.log.values.isEmpty)
    }

    @Test func disconnectedMicrophoneRefuses() async {
        let rig = Rig(audioFailure: AudioFailure())
        await rig.controller.shortcutPressed()
        #expect(rig.host.hud == [.notice(.microphone("The selected microphone “USB Mic” is not connected"))])
        #expect(!rig.log.values.contains("mute") && rig.log.values.contains("end 5"))
        #expect(await rig.controller.activity == .idle)
    }

    @Test func changedWindowLeavesTextOnClipboard() async {
        let rig = Rig(delivery: .copiedOnly)
        await rig.controller.shortcutPressed()
        await rig.controller.shortcutReleased()
        #expect(rig.host.hud.last == .notice(.pasteManually))
        #expect(await rig.controller.history.map(\.text) == ["Hello world "])
    }

    @Test func historyLengthAndClear() async {
        let rig = Rig(settings: settings { $0.historyLength = 3; $0.suffix = .newline })
        for _ in 0..<4 {
            await rig.controller.shortcutPressed()
            await rig.controller.shortcutReleased()
        }
        #expect(await rig.controller.history.map(\.text) == ["Hello world\n", "Hello world\n", "Hello world\n"])
        await rig.controller.clearHistory()
        #expect(await rig.controller.history.isEmpty)

        let none = Rig(settings: settings { $0.historyLength = 0 })
        await none.controller.shortcutPressed()
        await none.controller.shortcutReleased()
        #expect(none.host.delivered == ["Hello world "])
        #expect(await none.controller.history.isEmpty)
    }

    @Test func nothingRecognized() async {
        let rig = Rig(text: "  ")
        await rig.controller.shortcutPressed()
        await rig.controller.shortcutReleased()
        #expect(rig.host.delivered.isEmpty)
        #expect(rig.host.hud.last == .notice(.nothingRecognized))
    }

    @Test func soundsAndMuteFollowSettings() async {
        let rig = Rig(settings: settings { $0.playSounds = false; $0.muteOutput = false; $0.showWaveform = false })
        await rig.controller.shortcutPressed()
        await rig.controller.shortcutReleased()
        #expect(!rig.log.values.contains { $0.contains("sound") || $0 == "mute" || $0 == "restore" })
        #expect(rig.host.hud.first == .recording(waveform: false))
    }

    @Test func disablingUnloadsTheModel() async {
        let rig = Rig()
        await rig.controller.shortcutPressed()
        await rig.controller.disabled()
        #expect(rig.host.delivered.isEmpty)
        #expect(rig.log.values.last == "unload")
    }
}

private struct AudioFailure: LocalizedError {
    var errorDescription: String? { "The selected microphone “USB Mic” is not connected" }
}
