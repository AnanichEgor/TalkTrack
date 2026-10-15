import CryptoKit
import Foundation
import TalkTrackDomain

/// Whether automatic names may be assigned, derived from manual confirmations.
public struct VoiceRecognitionStatus: Equatable, Sendable {
    /// Distinct meetings with compatible confirmations.
    public let meetings: Int
    /// Saved voices confirmed in two or more meetings.
    public let repeatedPeople: Int
    public let positives: Int
    public let negatives: Int
    /// Held-out confirmations the calibration would have named correctly.
    public let positivesAccepted: Int
    public let calibration: VoiceRecognitionCalibration?
    /// One per compatible confirmation, for review and validation reports.
    public let trials: [VoiceCalibrationTrial]

    public var isCalibrated: Bool { calibration != nil }
}

/// Scores of one confirmed revision. `own`/`others` use banks without the
/// revision's meeting (the calibration data). `sameVoice`/`nearestOther` use
/// all other confirmations, including the same meeting (diagnostics only).
public struct VoiceCalibrationTrial: Codable, Equatable, Sendable {
    public let meetingID: UUID
    public let revisionID: UUID
    public let profileID: UUID
    public let name: String
    public let own: Double?
    public let others: [Double]
    public let sameVoice: Double?
    public let nearestOther: Double?
}

/// Leave-one-meeting-out calibration (user decision, 2026-10-13). Each
/// confirmed revision of a meeting is scored against banks built only from
/// other meetings: its own profile gives a positive, every other profile a
/// negative. The threshold sits above every negative; until the data spans
/// enough meetings and repeated people, recognition stays uncalibrated.
enum VoiceProfileCalibrator {
    static let version = "confirmations-loo-v1"
    static let requiredMeetings = 3
    static let requiredPositives = 2
    static let requiredNegatives = 4
    static let negativeHeadroom = 0.03
    static let margin = 0.05
    /// Never accept below this however few negatives were seen.
    static let minimumThreshold = 0.5

    static func status(_ profiles: [VoiceRecognitionProfile], segmentation: ModelSnapshot, embedding: ModelSnapshot) -> VoiceRecognitionStatus {
        let current = profiles.filter {
            $0.revision.segmentation == segmentation && $0.revision.embedding == embedding &&
            $0.revision.preprocessingVersion == VoiceEnrollmentPolicy.preprocessing &&
            $0.revision.enrollmentPolicyVersion == VoiceEnrollmentPolicy.version
        }
        let confirmations = current.flatMap(\.compatibleHistory)
        let meetings = Set(confirmations.map(\.meetingID))
        let repeated = current.filter { Set($0.compatibleHistory.map(\.meetingID)).count >= 2 }.count
        var trials: [VoiceCalibrationTrial] = []
        for profile in current {
            let rest = current.filter { $0.profile.id != profile.profile.id }
            for revision in profile.compatibleHistory where revision.samples.count >= 2 {
                let own = profile.bank(excluding: revision.meetingID)
                let others = rest.map { $0.bank(excluding: revision.meetingID) }.filter { $0.count >= 2 }
                let sameVoice = VoiceProfileBank.select(profile.compatibleHistory.filter { $0.id != revision.id }.flatMap(\.samples))
                trials.append(VoiceCalibrationTrial(meetingID: revision.meetingID, revisionID: revision.id,
                    profileID: profile.profile.id, name: profile.profile.name,
                    own: own.count >= 2 ? VoiceProfileMatcher.score(revision.samples, bank: own) : nil,
                    others: others.map { VoiceProfileMatcher.score(revision.samples, bank: $0) },
                    sameVoice: sameVoice.count >= 2 ? VoiceProfileMatcher.score(revision.samples, bank: sameVoice) : nil,
                    nearestOther: rest.map { VoiceProfileMatcher.score(revision.samples, bank: $0.bank()) }.max()))
            }
        }
        trials.sort { $0.revisionID.uuidString < $1.revisionID.uuidString }
        let positives = trials.compactMap(\.own), negatives = trials.flatMap(\.others)
        func result(_ calibration: VoiceRecognitionCalibration?, accepted: Int = 0) -> VoiceRecognitionStatus {
            VoiceRecognitionStatus(meetings: meetings.count, repeatedPeople: repeated, positives: positives.count,
                negatives: negatives.count, positivesAccepted: accepted, calibration: calibration, trials: trials)
        }
        guard meetings.count >= requiredMeetings, repeated >= 1, positives.count >= requiredPositives,
              negatives.count >= requiredNegatives, let highest = negatives.max() else { return result(nil) }
        let threshold = min(1, max(minimumThreshold, highest + negativeHeadroom))
        let accepted = trials.filter { trial in
            guard let own = trial.own else { return false }
            return own >= threshold && own - (trial.others.max() ?? -1) >= margin
        }.count
        struct Evidence: Codable { let revisionID: UUID; let profileID: UUID; let own: Double?; let others: [Double] }
        let data = trials.map { Evidence(revisionID: $0.revisionID, profileID: $0.profileID, own: $0.own, others: $0.others) }
        guard let report = try? VoiceProfileMatcher.fingerprint(data) else { return result(nil) }
        let calibration = VoiceRecognitionCalibration(
            version: "\(version):\(meetings.count)m:\(positives.count)p:\(negatives.count)n:\(report.prefix(12))",
            reportSHA256: report, matcherVersion: VoiceProfileMatcher.version, segmentation: segmentation, embedding: embedding,
            preprocessingVersion: VoiceEnrollmentPolicy.preprocessing, enrollmentPolicyVersion: VoiceEnrollmentPolicy.version,
            minimumSimilarity: threshold, minimumMargin: margin)
        return result(calibration.valid ? calibration : nil, accepted: accepted)
    }
}
