import CryptoKit
import Foundation
import TalkTrackDomain

/// A pair of voices of one recording day that the user named.
public struct NamedVoicePair: Codable, Equatable, Sendable {
    public let recordingID: UUID
    public let similarity: Double
    public let apart: Bool
    /// Both voices carry one person's name.
    public let samePerson: Bool
}

/// The voice-merge threshold learned from the user's names (user decision,
/// 2026-10-14). Same-named voices of a day are pairs that should have merged,
/// differently named ones pairs that must not. The threshold sits above the most
/// similar different pair; once active, consolidation also merges voices the
/// segmentation heard in one window, the ban that kept one person's voices apart
/// on the user's Daily meeting.
public struct SpeakerMergeCalibration: Codable, Equatable, Sendable {
    public static let version = "names-max-negative-v1"
    /// Headroom above the most similar different pair.
    public static let headroom = 0.05
    /// Never below this, whatever the names show: unrelated voices of a call
    /// average about 0.25 (measured on a real call).
    public static let floor = 0.3
    public static let minimumPositives = 2
    public static let minimumNegatives = 10

    public let version: String
    public let positives: Int
    public let negatives: Int
    /// Positives at or above the threshold: split voices the threshold would merge.
    public let mergeable: Int
    public let threshold: Double?
    /// Covers the scores that produced the threshold.
    public let hash: String

    public var isActive: Bool { threshold != nil }

    public init(pairs: [NamedVoicePair]) {
        let positive = pairs.filter(\.samePerson).map(\.similarity), negative = pairs.filter { !$0.samePerson }.map(\.similarity)
        let candidate = max(Self.floor, (negative.max() ?? 1) + Self.headroom)
        let mergeable = positive.filter { $0 >= candidate }.count
        version = Self.version; positives = positive.count; negatives = negative.count; self.mergeable = mergeable
        threshold = positive.count >= Self.minimumPositives && negative.count >= Self.minimumNegatives && mergeable > 0 ? candidate : nil
        let text = pairs.map { String(format: "%@:%.6f:%d:%d", $0.recordingID.uuidString, $0.similarity, $0.apart ? 1 : 0, $0.samePerson ? 1 : 0) }
            .sorted().joined(separator: "\n")
        hash = SHA256.hash(data: Data((Self.version + "\n" + text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Labeled pairs of each recording's standard voices; unnamed voices take no part.
    public static func pairs(_ groups: SpeakerVoiceGroups, named: [NamedSpeech]) -> [NamedVoicePair] {
        let persons = groups.persons(named)
        let recording = Dictionary(uniqueKeysWithValues: groups.groups.map { ($0.id, $0.recordingID) })
        return groups.pairs.compactMap { pair in
            guard let a = persons[pair.first], let b = persons[pair.second] else { return nil }
            return NamedVoicePair(recordingID: recording[pair.first]!, similarity: pair.similarity, apart: pair.apart, samePerson: a == b)
        }
    }
}
