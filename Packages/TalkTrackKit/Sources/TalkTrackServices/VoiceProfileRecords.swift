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
    /// How the samples were chosen; nil for the original spread rule. Kept out
    /// of `enrollmentPolicyVersion`, which recognition compatibility uses (D4).
    public var selectionVersion: String? = nil
}

public enum VoiceProfileChoice: Codable, Equatable, Sendable {
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

/// One sample a saved voice currently counts, for Settings. No vector.
public struct SavedVoiceSample: Equatable, Identifiable, Sendable {
    /// Identity and what `VoiceProfileStore.exclude` takes.
    public let key: VoiceSampleExclusion
    public let libraryID: UUID
    public let meetingID: UUID
    public let daySpeakerID: UUID
    /// When the user named the person (the revision's creation).
    public let confirmedAt: Date
    /// In the at most 24 samples recognition compares with.
    public let usedForRecognition: Bool
    public var id: String { "\(key.revisionID)/\(key.recordingID)/\(key.interval.start.microseconds)/\(key.interval.end.microseconds)" }
    public var recordingID: UUID { key.recordingID }
    public var interval: MediaInterval { key.interval }
}

/// Where a saved-voice sample came from, read from the open library for
/// display only.
public enum VoiceSampleContext: Equatable, Sendable {
    public struct Details: Equatable, Sendable {
        public let meetingTitle: String
        /// The recording day, e.g. "October 9, 2026".
        public let date: String
        /// The transcript time of the reply the sample starts in.
        public let time: String?
        /// Current transcript text overlapping the sample, clipped.
        public let text: String?
    }
    case available(Details)
    /// Learned in a library that is not open (moved, another Mac).
    case otherLibrary
    /// Its meeting or recording was deleted.
    case recordingDeleted

    static let maximumText = 160
    static func clipped(_ text: String) -> String {
        text.count <= maximumText ? text : String(text.prefix(maximumText - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
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

// MARK: Background voice learning (background-voice-learning D1)

public enum VoiceLearningState: String, Codable, Sendable {
    case queued, running, awaitingReview, learned, insufficientSpeech, failed, cancelled, superseded
    /// Still able to change saved voices.
    public var isPending: Bool { [.queued, .running, .awaitingReview].contains(self) }
    public var isFinished: Bool { !isPending }
}

/// What a learning task needs to rebuild its confirmation after relaunch:
/// identifiers only, re-read and re-validated from the library when it runs.
public struct VoiceLearningRequest: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let meetingID: UUID
    public let speakerID: UUID
    public let assignment: SpeakerAssignment
    public let recordingIDs: [UUID]
    public let revisionIDs: [UUID]
    public let fragments: [FragmentAnchor]
    public let choice: VoiceProfileChoice
    /// The confirmed name, for display.
    public var name: String { assignment.name ?? "" }

    public init(_ confirmation: VoiceEnrollmentConfirmation, choice: VoiceProfileChoice) {
        libraryID = confirmation.library.manifest.libraryID
        meetingID = confirmation.assignment.meetingID
        speakerID = confirmation.speakerID
        assignment = confirmation.assignment
        recordingIDs = confirmation.recordings.map(\.id)
        revisionIDs = confirmation.revisions.map(\.id)
        fragments = confirmation.fragments
        self.choice = choice
    }
}

/// Speech held back because it does not sound like the chosen saved voice
/// (D5). Nothing is added until the user answers.
public struct VoiceLearningReview: Codable, Equatable, Sendable {
    public let profileID: UUID
    public let profileName: String
    public let segmentation: ModelSnapshot
    public let embedding: ModelSnapshot
    public let samples: [VoiceProfileSample]
    public let score: Double
    public let threshold: Double
}

/// The user's answer to a review.
public enum VoiceReviewAnswer: Equatable, Sendable {
    /// Add the held speech to the saved voice anyway.
    case add
    /// Save it as a new voice with this name; the meeting's names stay.
    case differentPerson(name: String)
    case dontRemember
}

public struct VoiceLearningTask: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let request: VoiceLearningRequest
    public var state: VoiceLearningState
    public let createdAt: Date
    public var updatedAt: Date
    /// After `learned`: the voice after and before (nil: created), for Undo.
    public var created: VoiceProfile?
    public var previous: VoiceProfile?
    public var review: VoiceLearningReview?
    /// Why it failed, for display.
    public var message: String?
    /// Seen by the user; finished acknowledged tasks are hidden and pruned.
    public var acknowledged: Bool

    public var meetingID: UUID { request.meetingID }
    public var name: String { request.name }

    init(id: UUID = UUID(), request: VoiceLearningRequest, at date: Date) {
        self.id = id; self.request = request; state = .queued; createdAt = date; updatedAt = date
        acknowledged = false
    }
}

public enum VoiceLearningError: Error, Equatable, LocalizedError, Sendable {
    /// The task is not in a state that allows this action.
    case changed
    /// The speech was held for review (internal to the runner).
    case needsReview(VoiceLearningReview)
    public var errorDescription: String? {
        switch self {
        case .changed: "This voice learning changed meanwhile. Check Settings ▸ Speakers."
        case .needsReview(let review): "The speech does not sound like the saved voice \(review.profileName)."
        }
    }
}
