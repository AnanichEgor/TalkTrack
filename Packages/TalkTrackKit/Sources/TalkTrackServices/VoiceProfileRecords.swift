import Foundation
import TalkTrackDomain

public struct VoiceProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let revisionID: UUID
    public let updatedAt: Date
}

public struct VoiceProfileSample: Codable, Equatable, Sendable {
    public let recordingID: UUID
    public let transcriptRevisionID: UUID
    public let dayID: UUID
    public let interval: MediaInterval
    public let vector: [Float]
}

/// Immutable manually confirmed evidence, independent of the session location.
/// Enrollment itself provides no automatic-name authority. Recognition requires
/// a separately validated calibration bound to these exact adapters and policy.
public struct VoiceProfileRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let profileID: UUID
    public let previousRevisionID: UUID?
    public let createdAt: Date
    public let libraryID: UUID
    public let meetingID: UUID
    public let daySpeakerID: UUID
    public let assignmentID: UUID
    public let segmentation: ModelSnapshot
    public let embedding: ModelSnapshot
    public let preprocessingVersion: String
    public let enrollmentPolicyVersion: String
    public let calibrationVersion: String?
    public let samples: [VoiceProfileSample]
}

public enum VoiceProfileChoice: Equatable, Sendable {
    case newProfile
    case existing(profileID: UUID, revisionID: UUID)
    /// Explicitly selected in the rename dialog; requires a fresh manual Save.
    case replaceIncompatible(profileID: UUID, revisionID: UUID)
}

public struct SavedVoice: Equatable, Identifiable, Sendable {
    public var id: UUID { profile.id }
    public let profile: VoiceProfile
    public let needsNewSpeech: Bool
}

public enum VoiceProfileSettingsError: Error, Equatable, LocalizedError, Sendable {
    case changed, busy
    public var errorDescription: String? {
        switch self {
        case .changed: "This saved voice changed or was deleted. Refresh Saved Speakers and try again."
        case .busy: "A voice match is being saved. Wait for it to finish, then retry."
        }
    }
}

/// Constructed only by SessionStore as part of an explicit native rename save.
/// Automatic assignments and arbitrary caller-supplied audio cannot enroll.
public struct VoiceEnrollmentConfirmation: Sendable {
    public let library: OpenedLibrary
    /// The voice, or for named fragments the person of that meeting day.
    public let speakerID: UUID
    public let assignment: SpeakerAssignment
    public let recordings: [Recording]
    public let revisions: [TranscriptRevision]
    /// Named fragments that are the confirmed speech (per recording), instead
    /// of the voice's segments; their records must still be current.
    public var fragments: [FragmentAnchor] = []
    var selection: [UUID: [MediaInterval]]? {
        fragments.isEmpty ? nil : Dictionary(grouping: fragments, by: \.recordingID).mapValues { $0.map(\.interval) }
    }
}

public struct ConfirmedSpeakerRename: Sendable {
    public let snapshot: MeetingTranscriptSnapshot
    public let confirmation: VoiceEnrollmentConfirmation
}

public enum VoiceEnrollmentError: Error, Equatable, LocalizedError, Sendable {
    case insufficientSpeech, incompatibleModels, changed, busy, unavailable, damagedProfile
    case profileLibrary(String)
    public var errorDescription: String? {
        switch self {
        case .insufficientSpeech: "Saving a voice needs at least 10 seconds of clean system speech in two or more separate samples. Overlapping voices, silence, clipped audio and short samples are excluded. Try again after recording more suitable speech."
        case .incompatibleModels: "This transcript or saved profile uses incompatible speaker models or preprocessing. Reprocess the recording or create a new profile from confirmed speech."
        case .changed: "The recording, confirmed name or saved profile changed. Select the speaker and profile again before remembering."
        case .busy: "Voice remembering is already running. Wait for it to finish."
        case .unavailable: "Voice remembering is unavailable. Restore saved audio and speaker models, then try again."
        case .damagedProfile: "The saved voice database is damaged or belongs to another application. Restore its backup before remembering voices."
        case .profileLibrary(let message): "Saved voices are unavailable. \(message)"
        }
    }
}

enum VoiceEnrollmentPolicy {
    static let version = "clean-system-10s-2samples-v1"
    static let preprocessing = "aac48k-native16k-mono-exclusive-50ms-v1"
    static let minimumMicroseconds: Int64 = 10_000_000
    static let maximumSamples = 8
    /// Named fragments added to an existing voice: they need no ten seconds.
    static func isCorrection(_ confirmation: VoiceEnrollmentConfirmation, _ choice: VoiceProfileChoice) -> Bool {
        guard !confirmation.fragments.isEmpty, case .existing = choice else { return false }
        return true
    }
    static func validVector(_ vector: [Float]) -> Bool {
        guard vector.count == 256, vector.allSatisfy(\.isFinite) else { return false }
        let norm = vector.reduce(0.0) { $0 + Double($1) * Double($1) }
        return abs(norm - 1) <= 0.02
    }
}
