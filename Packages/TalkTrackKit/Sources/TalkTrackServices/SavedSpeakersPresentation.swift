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
    /// The open library's named fragments, so listed samples match recognition.
    @ObservationIgnored public var voiceCorrections: (@Sendable () async throws -> [VoiceCorrection])?
    /// Meeting, day, time and reply text of samples, from the open library.
    @ObservationIgnored public var sampleContexts: (@Sendable ([SavedVoiceSample]) async -> [String: VoiceSampleContext])?
    /// Voices whose samples are shown, and their samples by meeting day.
    public private(set) var expanded: Set<UUID> = []
    public private(set) var sampleDays: [UUID: [SavedVoiceSampleDay]] = [:]
    public private(set) var contexts: [String: VoiceSampleContext] = [:]
    /// The latest removal, offered as Undo until anything else changes.
    public private(set) var removalUndo: SampleRemovalUndo?
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
        removalUndo = nil
        do { voices = try await store.savedVoices(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        status = try? await store.recognitionStatus()
        merge = try? await mergeCalibration?()
        expanded = expanded.filter { id in voices.contains { $0.id == id } }
        sampleDays = sampleDays.filter { expanded.contains($0.key) }
        for id in expanded { await reloadSamples(id) }
    }

    /// Shows or hides a voice's samples; they are read when first shown.
    public func toggleSamples(_ profile: VoiceProfile) async {
        if expanded.remove(profile.id) != nil { sampleDays[profile.id] = nil; return }
        expanded.insert(profile.id)
        await reloadSamples(profile.id)
    }

    public func sampleCount(_ profileID: UUID) -> Int? { sampleDays[profileID].map { $0.reduce(0) { $0 + $1.samples.count } } }

    private func reloadSamples(_ id: UUID) async {
        guard let profile = voices.first(where: { $0.id == id })?.profile else { expanded.remove(id); sampleDays[id] = nil; return }
        do {
            let corrections = try await voiceCorrections?() ?? []
            let samples = try await store.samples(of: profile, corrections: corrections)
            let found = await sampleContexts?(samples) ?? [:]
            contexts.merge(found) { _, new in new }
            sampleDays[id] = SavedVoiceSampleDay.group(samples)
        } catch { errorMessage = error.localizedDescription }
    }

    /// Removes samples from this voice only; Undo takes them back.
    public func remove(_ samples: [SavedVoiceSample], from profile: VoiceProfile) async {
        guard !isBusy, !samples.isEmpty else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let removed = try await store.exclude(samples.map(\.key), from: profile)
            removalUndo = SampleRemovalUndo(profile: profile, removed: removed)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        await afterSampleChange(profile.id)
    }

    public func undoRemoval() async {
        guard !isBusy, let undo = removalUndo else { return }
        isBusy = true; defer { isBusy = false }
        do { try await store.restore(undo.removed, to: undo.profile); removalUndo = nil; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        await afterSampleChange(undo.profile.id)
    }

    private func afterSampleChange(_ id: UUID) async {
        if let fresh = try? await store.savedVoices() { voices = fresh }
        status = try? await store.recognitionStatus()
        merge = try? await mergeCalibration?()
        await reloadSamples(id)
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
            self.editing = nil; draftName = ""; removalUndo = nil
            voices = try await store.savedVoices(); errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    public func delete(_ profile: VoiceProfile) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        removalUndo = nil
        do { try await store.delete(profile); voices = try await store.savedVoices(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        status = try? await store.recognitionStatus()
        merge = try? await mergeCalibration?()
        expanded.remove(profile.id); sampleDays[profile.id] = nil
    }
}

/// The samples one naming (a meeting day) taught a voice.
public struct SavedVoiceSampleDay: Equatable, Identifiable, Sendable {
    public let meetingID: UUID
    public let daySpeakerID: UUID
    public let samples: [SavedVoiceSample]
    public var id: String { "\(meetingID)/\(daySpeakerID)" }
    public var confirmedAt: Date { samples.map(\.confirmedAt).max() ?? .distantPast }

    static func group(_ samples: [SavedVoiceSample]) -> [SavedVoiceSampleDay] {
        Dictionary(grouping: samples) { "\($0.meetingID)/\($0.daySpeakerID)" }.values.map {
            SavedVoiceSampleDay(meetingID: $0[0].meetingID, daySpeakerID: $0[0].daySpeakerID, samples: $0.sorted { $0.interval.start < $1.interval.start })
        }.sorted { ($0.confirmedAt, $0.id) > ($1.confirmedAt, $1.id) }
    }
}

/// Undo of the latest sample removal in Settings.
public struct SampleRemovalUndo: Equatable, Sendable {
    public let profile: VoiceProfile
    public let removed: [VoiceSampleExclusion]
    public var text: String {
        removed.count == 1 ? "Removed 1 sample from \(profile.name)." : "Removed \(removed.count) samples from \(profile.name)."
    }
}
