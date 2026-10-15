import Foundation
import TalkTrackDomain

public enum ProcessingPreferences {
    public static let contextKey = "textContextLimit"
    public static let liveEnabledKey = "liveTranscriptionEnabled"
    public static let meetingLanguageKey = "defaultMeetingLanguage"
    public static let voiceRecognitionKey = "savedVoiceRecognitionEnabled"
    public static let summaryLanguageKey = "summaryOutputLanguage"
    public static let translationLanguageKey = "translationTargetLanguage"
    public static let spellingCorrectionKey = "finalSpellingCorrection"
    /// Saved Core Audio device UID; absent means the system default input.
    public static let microphoneUIDKey = "microphoneDeviceUID"
    /// Display name remembered with the UID, for a device that is not connected.
    public static let microphoneNameKey = "microphoneDeviceName"
    /// Catalog id of the text model for new jobs; absent means chosen by memory.
    public static let textModelKey = "textModel"

    public static func textModel(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: textModelKey)
    }

    public static func voiceRecognitionEnabled(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: voiceRecognitionKey) as? Bool) ?? true
    }

    public static func liveOptions(meetingLanguage: MeetingLanguage? = nil, in defaults: UserDefaults = .standard) -> LiveTranscriptionOptions {
        let enabled = (defaults.object(forKey: liveEnabledKey) as? Bool) ?? true
        let language = meetingLanguage ?? MeetingLanguage(rawValue: defaults.string(forKey: meetingLanguageKey) ?? "") ?? .auto
        return LiveTranscriptionOptions(enabled: enabled, language: language)
    }

    public static func meetingDraft(title: String, description: String = "", in defaults: UserDefaults = .standard) throws -> MeetingDraft {
        try MeetingDraft(title: title, description: description, language: liveOptions(in: defaults).language)
    }

    /// Summary and translation languages are independent preferences.
    public static func summaryLanguage(in defaults: UserDefaults = .standard) -> OutputLanguage {
        OutputLanguage(rawValue: defaults.string(forKey: summaryLanguageKey) ?? "") ?? ProcessingSettings().summaryLanguage
    }

    public static func translationLanguage(in defaults: UserDefaults = .standard) -> OutputLanguage {
        OutputLanguage(rawValue: defaults.string(forKey: translationLanguageKey) ?? "") ?? ProcessingSettings().translationLanguage
    }

    /// The selected microphone, or nil for the system default input.
    public static func microphone(in defaults: UserDefaults = .standard) -> (uid: String, name: String)? {
        guard let uid = defaults.string(forKey: microphoneUIDKey), !uid.isEmpty else { return nil }
        return (uid, defaults.string(forKey: microphoneNameKey) ?? uid)
    }

    /// Off by default: on a real meeting it changed about 1% of words and took
    /// most of the processing time.
    public static func spellingCorrection(in defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: spellingCorrectionKey) as? Bool) ?? false
    }

    public static func context(in defaults: UserDefaults = .standard) -> ContextLimit {
        let raw = (defaults.object(forKey: contextKey) as? Int) ?? ContextLimit.defaultSelection.rawValue
        let decoded = ContextLimit(rawValue: raw) ?? .defaultSelection
        let selected: ContextLimit = ContextLimit.allCases.contains(decoded) ? decoded : .maximumSelectable
        if selected.rawValue != raw { defaults.set(selected.rawValue, forKey: contextKey) }
        return selected
    }

    /// Call when enqueueing a new job. Existing value snapshots are independent
    /// from subsequent UserDefaults/AppStorage changes.
    public static func snapshot(from defaults: UserDefaults = .standard) -> ProcessingSettings {
        ProcessingSettings(meetingLanguage: liveOptions(in: defaults).language, summaryLanguage: summaryLanguage(in: defaults),
                           translationLanguage: translationLanguage(in: defaults), contextLimit: context(in: defaults),
                           spellingCorrection: spellingCorrection(in: defaults))
    }
}
