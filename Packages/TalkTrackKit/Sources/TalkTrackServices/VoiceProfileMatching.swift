import CryptoKit
import Foundation
import TalkTrackDomain

/// Thresholds belong to a separate, versioned calibration artifact, never to
/// clustering defaults or editable UI preferences. Production calibration is
/// derived from the user's own confirmations (`VoiceProfileCalibrator`).
public struct VoiceRecognitionCalibration: Codable, Equatable, Sendable {
    public let version: String
    public let reportSHA256: String
    public let matcherVersion: String
    public let segmentation: ModelSnapshot
    public let embedding: ModelSnapshot
    public let preprocessingVersion: String
    public let enrollmentPolicyVersion: String
    public let minimumSimilarity: Double
    public let minimumMargin: Double

    var valid: Bool {
        !version.isEmpty && version.utf8.count <= 200 && reportSHA256.count == 64 &&
        reportSHA256.allSatisfy { "0123456789abcdef".contains($0) } &&
        matcherVersion == VoiceProfileMatcher.version && segmentation.role == .segmentation &&
        embedding.role == .embedding && preprocessingVersion == VoiceEnrollmentPolicy.preprocessing &&
        enrollmentPolicyVersion == VoiceEnrollmentPolicy.version &&
        minimumSimilarity.isFinite && (0...1).contains(minimumSimilarity) && minimumSimilarity > 0 &&
        minimumMargin.isFinite && (0...2).contains(minimumMargin) && minimumMargin > 0
    }
}

public enum VoiceRecognitionDisposition: String, Codable, Sendable {
    case matched, disabled, uncalibrated, noProfiles, incompatibleProfiles
    case insufficientSpeech, incompatibleEvidence, belowThreshold, ambiguous
    case simultaneousConflict, manualName, existingAutomaticName
}

public struct VoiceRecognitionDecision: Equatable, Sendable {
    public let speakerID: UUID
    public let disposition: VoiceRecognitionDisposition
}

public struct VoiceRecognitionReport: Equatable, Sendable {
    public let assignments: [SpeakerAssignment]
    public let decisions: [VoiceRecognitionDecision]
}

public enum VoiceRecognitionError: Error, Equatable, LocalizedError, Sendable {
    case busy, changed, invalidCalibration, disabled
    public var errorDescription: String? {
        switch self {
        case .busy: "Saved voice recognition is already running. Wait for it to finish."
        case .changed: "The transcript or saved voices changed during recognition. Refresh and retry with the current recordings."
        case .invalidCalibration: "Saved voice recognition needs a validated calibration for these speaker models. Unknown speakers keep their Voice labels."
        case .disabled: "Saved voice recognition was turned off. No new automatic name was saved."
        }
    }
}

/// Historical proof contains hashes and source intervals, not reusable voice
/// vectors. Removing a profile can therefore remove its reusable representations
/// without removing an already committed day-specific name or its explanation.
public struct VoiceMatchSample: Codable, Equatable, Sendable {
    public let recordingID: UUID
    public let transcriptRevisionID: UUID
    public let dayID: UUID
    public let interval: MediaInterval
    public let embeddingSHA256: String
}

public struct VoiceProfileScore: Codable, Equatable, Sendable {
    public let profileID: UUID
    public let revisionID: UUID
    public let similarity: Double
}

public struct AutomaticVoiceMatch: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { assignment.id }
    public let assignment: SpeakerAssignment
    public let profile: VoiceProfile
    public let profileRevisionSHA256: String
    public let calibration: VoiceRecognitionCalibration
    public let samples: [VoiceMatchSample]
    public let rankedProfiles: [VoiceProfileScore]
}

/// Speech the user named as someone else after it had been confirmed for a
/// voice (a corrected fragment). Saved samples inside it leave every other
/// person's bank, so a wrong name stops teaching recognition.
public struct VoiceCorrection: Equatable, Sendable {
    public let libraryID: UUID
    public let recordingID: UUID
    public let interval: MediaInterval
    /// The name the user gave it, trimmed and lowercased.
    public let person: String
    public init(libraryID: UUID, recordingID: UUID, interval: MediaInterval, person: String) {
        self.libraryID = libraryID; self.recordingID = recordingID; self.interval = interval; self.person = person
    }
    func covers(_ sample: VoiceProfileSample, libraryID: UUID) -> Bool {
        guard libraryID == self.libraryID, sample.recordingID == recordingID, sample.interval.duration > .zero else { return false }
        let start = max(sample.interval.start, interval.start), end = min(sample.interval.end, interval.end)
        // A fifth of someone else's speech already colours a sample's vector.
        return end > start && (end.microseconds - start.microseconds) * 5 >= sample.interval.duration.microseconds
    }
}

struct VoiceRecognitionProfile: Equatable, Sendable {
    let profile: VoiceProfile
    let revision: VoiceProfileRevision
    /// The head first, then earlier revisions along `previousRevisionID`,
    /// without confirmations the user later gave another name. May be empty.
    let history: [VoiceProfileRevision]

    init(profile: VoiceProfile, revision: VoiceProfileRevision, history: [VoiceProfileRevision]? = nil) {
        self.profile = profile; self.revision = revision; self.history = history ?? [revision]
    }

    /// Revisions comparable with the head: same models, preprocessing and policy.
    var compatibleHistory: [VoiceProfileRevision] {
        history.filter {
            $0.profileID == revision.profileID && $0.segmentation == revision.segmentation && $0.embedding == revision.embedding &&
            $0.preprocessingVersion == revision.preprocessingVersion && $0.enrollmentPolicyVersion == revision.enrollmentPolicyVersion
        }
    }

    /// Every confirmation adds to the profile: the bank is drawn from all
    /// compatible revisions, optionally leaving one meeting out (calibration).
    func bank(excluding meetingID: UUID? = nil) -> [VoiceProfileSample] {
        VoiceProfileBank.select(compatibleHistory.filter { $0.meetingID != meetingID }.flatMap(\.samples))
    }

    /// Enough speech across all confirmations; a short correction added to an
    /// adequate voice keeps it adequate.
    var isAdequate: Bool { VoiceProfileMatcher.adequateBank(bank()) }

    /// Without samples that a correction names as someone else.
    func applying(_ corrections: [VoiceCorrection]) -> VoiceRecognitionProfile {
        let person = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let relevant = corrections.filter { $0.person != person }
        guard !relevant.isEmpty else { return self }
        func clean(_ revision: VoiceProfileRevision) -> VoiceProfileRevision {
            let kept = revision.samples.filter { sample in !relevant.contains { $0.covers(sample, libraryID: revision.libraryID) } }
            guard kept.count != revision.samples.count else { return revision }
            return VoiceProfileRevision(id: revision.id, profileID: revision.profileID, previousRevisionID: revision.previousRevisionID,
                createdAt: revision.createdAt, libraryID: revision.libraryID, meetingID: revision.meetingID, daySpeakerID: revision.daySpeakerID,
                assignmentID: revision.assignmentID, segmentation: revision.segmentation, embedding: revision.embedding,
                preprocessingVersion: revision.preprocessingVersion, enrollmentPolicyVersion: revision.enrollmentPolicyVersion,
                calibrationVersion: revision.calibrationVersion, samples: kept)
        }
        return VoiceRecognitionProfile(profile: profile, revision: clean(revision), history: history.map(clean))
    }
}

enum VoiceProfileBank {
    static let maximumSamples = 24

    /// Farthest-point selection keeps the most diverse samples (different
    /// days, microphones, moods) instead of the newest ones. Deterministic:
    /// starts from the first candidate (the head's first sample).
    static func select(_ candidates: [VoiceProfileSample]) -> [VoiceProfileSample] {
        let valid = candidates.filter { VoiceEnrollmentPolicy.validVector($0.vector) }
        guard valid.count > maximumSamples else { return valid }
        var chosen = [valid[0]]
        var nearest = valid.map { VoiceProfileMatcher.cosine($0.vector, valid[0].vector) }
        while chosen.count < maximumSamples {
            var pick = 0, lowest = Double.infinity
            for (index, value) in nearest.enumerated() where value < lowest { pick = index; lowest = value }
            chosen.append(valid[pick])
            for index in valid.indices { nearest[index] = max(nearest[index], VoiceProfileMatcher.cosine(valid[index].vector, valid[pick].vector)) }
        }
        return chosen
    }
}

struct VoiceRecognitionSource: Sendable {
    let library: OpenedLibrary
    let snapshot: MeetingTranscriptSnapshot

    var speakers: [DaySpeaker] {
        snapshot.speakers.filter { speaker in snapshot.revisions.contains { revision in
            revision.kind == .final && revision.segments.contains { $0.track == .system && $0.speaker == .system(daySpeakerID: speaker.id) }
        } }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func coactive(_ left: UUID, _ right: UUID) -> Bool {
        guard left != right else { return false }
        return snapshot.revisions.contains { revision in
            let a = revision.segments.filter { $0.track == .system && $0.speaker == .system(daySpeakerID: left) }
            let b = revision.segments.filter { $0.track == .system && $0.speaker == .system(daySpeakerID: right) }
            return a.contains { l in b.contains { r in max(l.interval.start, r.interval.start) < min(l.interval.end, r.interval.end) } }
        }
    }
}

struct VoiceProfileMatchEvaluation: Sendable {
    let disposition: VoiceRecognitionDisposition
    let winner: VoiceRecognitionProfile?
    let ranked: [VoiceProfileScore]
    var similarity: Double { ranked.first?.similarity ?? -1 }
    var margin: Double { similarity - (ranked.dropFirst().first?.similarity ?? -1) }
}

enum VoiceProfileMatcher {
    /// v2 (2026-10-13): each evidence sample takes its best cosine in the
    /// profile's accumulated bank; the score is the lower median. v1 used the
    /// minimum over all pairs, which one atypical confirmation sample sank.
    static let version = "exclusive-median-best-cosine-v2"

    /// A saved voice's whole bank: at least two valid samples of 1–10 s and ten
    /// seconds in all, from any of its confirmations.
    static func adequateBank(_ samples: [VoiceProfileSample]) -> Bool {
        samples.count >= 2 && samples.allSatisfy({ VoiceEnrollmentPolicy.validVector($0.vector) &&
            (1_000_000...10_000_000).contains($0.interval.duration.microseconds) }) &&
            samples.reduce(0, { $0 + $1.interval.duration.microseconds }) >= VoiceEnrollmentPolicy.minimumMicroseconds
    }

    static func adequate(_ samples: [VoiceProfileSample]) -> Bool {
        guard (2...VoiceEnrollmentPolicy.maximumSamples).contains(samples.count),
              samples.allSatisfy({ VoiceEnrollmentPolicy.validVector($0.vector) &&
                  (1_000_000...10_000_000).contains($0.interval.duration.microseconds) }),
              samples.reduce(0, { $0 + $1.interval.duration.microseconds }) >= VoiceEnrollmentPolicy.minimumMicroseconds else { return false }
        for (index, a) in samples.enumerated() {
            for b in samples.dropFirst(index + 1) where a.recordingID == b.recordingID {
                if max(a.interval.start, b.interval.start) < min(a.interval.end, b.interval.end) { return false }
            }
        }
        return true
    }

    static func evaluate(_ evidence: VoiceProfileEvidence, profiles: [VoiceRecognitionProfile],
                         calibration: VoiceRecognitionCalibration) throws -> VoiceProfileMatchEvaluation {
        guard calibration.valid else { throw VoiceRecognitionError.invalidCalibration }
        func result(_ status: VoiceRecognitionDisposition, _ ranked: [VoiceProfileScore] = [],
                    _ winner: VoiceRecognitionProfile? = nil) -> VoiceProfileMatchEvaluation {
            VoiceProfileMatchEvaluation(disposition: status, winner: winner, ranked: ranked)
        }
        guard evidence.segmentation == calibration.segmentation, evidence.embedding == calibration.embedding,
              evidence.samples.allSatisfy({ VoiceEnrollmentPolicy.validVector($0.vector) }) else { return result(.incompatibleEvidence) }
        guard adequate(evidence.samples) else { return result(.insufficientSpeech) }
        let candidates = profiles.filter {
            $0.revision.segmentation == calibration.segmentation && $0.revision.embedding == calibration.embedding &&
            $0.revision.preprocessingVersion == calibration.preprocessingVersion &&
            $0.revision.enrollmentPolicyVersion == calibration.enrollmentPolicyVersion
        }
        guard !candidates.isEmpty else { return result(profiles.isEmpty ? .noProfiles : .incompatibleProfiles) }
        // A corrupt compatible competitor cannot be silently dropped to make
        // the winner's margin look larger. Refuse the whole comparison.
        guard candidates.allSatisfy({ $0.revision.profileID == $0.profile.id && $0.revision.id == $0.profile.revisionID &&
            $0.compatibleHistory.allSatisfy { $0.samples.allSatisfy { VoiceEnrollmentPolicy.validVector($0.vector) } } &&
            (try? SpeakerRenameError.validatedName($0.profile.name)) == $0.profile.name }) else {
            return result(.incompatibleProfiles)
        }
        // A voice whose confirmations were all given other names, or corrected
        // below enough speech, has nothing to match against: it takes no part.
        let compatible = candidates.filter(\.isAdequate)
        guard !compatible.isEmpty else { return result(.noProfiles) }
        let scores = compatible.map { profile in
            VoiceProfileScore(profileID: profile.profile.id, revisionID: profile.revision.id,
                similarity: score(evidence.samples, bank: profile.bank()))
        }.sorted {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            return $0.profileID.uuidString < $1.profileID.uuidString
        }
        let best = scores[0], second = scores.dropFirst().first?.similarity ?? -1
        guard best.similarity >= calibration.minimumSimilarity else { return result(.belowThreshold, scores) }
        guard best.similarity - second >= calibration.minimumMargin else { return result(.ambiguous, scores) }
        return result(.matched, scores, compatible.first { $0.profile.id == best.profileID })
    }

    static func fingerprint<T: Codable>(_ value: T) throws -> String {
        SHA256.hash(data: try DomainCodec.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    /// Lower median over evidence samples of their best match in the bank:
    /// with two samples this is the worse one, so a single good vector cannot
    /// make a match. An empty bank scores -1.
    static func score(_ evidence: [VoiceProfileSample], bank: [VoiceProfileSample]) -> Double {
        guard !evidence.isEmpty, !bank.isEmpty else { return -1 }
        let best = evidence.map { sample in bank.map { cosine(sample.vector, $0.vector) }.max()! }.sorted()
        return best[(best.count - 1) / 2]
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let norm = sqrt(a.reduce(0.0) { $0 + Double($1) * Double($1) } * b.reduce(0.0) { $0 + Double($1) * Double($1) })
        return min(1, max(-1, dot / norm))
    }
}
