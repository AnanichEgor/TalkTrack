import Foundation
import Observation

/// Native Settings projection; registry I/O remains on VoiceProfileStore.
@MainActor @Observable public final class SavedSpeakersPresentation {
    public private(set) var voices: [SavedVoice] = []
    /// Calibration from the user's confirmations; nil until loaded or unreadable.
    public private(set) var status: VoiceRecognitionStatus?
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?
    public private(set) var editing: VoiceProfile?
    public var draftName = ""
    public var recognitionEnabled: Bool {
        didSet { if oldValue != recognitionEnabled { defaults.set(recognitionEnabled, forKey: ProcessingPreferences.voiceRecognitionKey) } }
    }
    /// How voices are merged, learned from the current library's names.
    public private(set) var merge: SpeakerMergeCalibration?
    /// Reads the merge calibration of the open library; set by the app.
    @ObservationIgnored public var mergeCalibration: (@Sendable () async throws -> SpeakerMergeCalibration)?
    @ObservationIgnored private let defaults: UserDefaults
    private let store: VoiceProfileStore

    public init(store: VoiceProfileStore = VoiceProfileStore(), defaults: UserDefaults = .standard) {
        self.store = store; self.defaults = defaults
        recognitionEnabled = ProcessingPreferences.voiceRecognitionEnabled(in: defaults)
    }
    public var canSave: Bool { !isBusy && (try? SpeakerRenameError.validatedName(draftName)) != nil }
    public func refresh() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        recognitionEnabled = ProcessingPreferences.voiceRecognitionEnabled(in: defaults)
        do { voices = try await store.savedVoices(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        status = try? await store.recognitionStatus()
        merge = try? await mergeCalibration?()
    }

    /// Learning until named pairs calibrate merging, then active.
    public var mergeText: String? {
        guard let merge else { return nil }
        if let threshold = merge.threshold {
            return "Active. Learned from \(merge.positives + merge.negatives) pairs of voices you named: voices at least \(String(format: "%.2f", threshold)) alike are joined into one, also when heard at the same moment. Two voices with different names are never joined."
        }
        let positives = SpeakerMergeCalibration.minimumPositives, negatives = SpeakerMergeCalibration.minimumNegatives
        if merge.positives >= positives && merge.negatives >= negatives {
            return "Learning. Your names show no split voices that a safe threshold would join; voices with one name are still joined when you apply names."
        }
        return "Learning: \(min(merge.positives, positives)) of \(positives) people named on two voices, \(min(merge.negatives, negatives)) of \(negatives) pairs of different people. When one person shows as two voices, give both the same name and apply names."
    }

    /// "Learning" with progress until calibrated, then "Active".
    public var statusText: String {
        guard let status else { return "Recognition status is unavailable." }
        if let calibration = status.calibration {
            return "Active. Calibrated from your names in \(status.meetings) meetings: a saved name is used only when the voice scores at least \(String(format: "%.2f", calibration.minimumSimilarity)) and clearly beats every other saved voice."
        }
        let required = VoiceProfileCalibrator.requiredMeetings
        var text = "Learning from your names: \(min(status.meetings, required)) of \(required) meetings."
        if status.meetings >= required && status.repeatedPeople == 0 {
            text += " Name a saved person again in another meeting so recognition can compare the same voice."
        } else if status.meetings >= required {
            text += " Name more speakers so recognition can compare different voices."
        } else {
            text += " Speakers keep their Voice labels until then."
        }
        return text
    }
    public func beginRename(_ profile: VoiceProfile) {
        guard !isBusy else { return }
        editing = profile; draftName = profile.name; errorMessage = nil
    }
    public func cancelRename() { guard !isBusy else { return }; editing = nil; draftName = "" }
    public func saveRename() async {
        guard canSave, let editing else { return }
        isBusy = true; defer { isBusy = false }
        do {
            _ = try await store.rename(editing, name: draftName)
            self.editing = nil; draftName = ""
            voices = try await store.savedVoices(); errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    public func delete(_ profile: VoiceProfile) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { try await store.delete(profile); voices = try await store.savedVoices(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        status = try? await store.recognitionStatus()
        merge = try? await mergeCalibration?()
    }
}
