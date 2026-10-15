import Foundation
import TalkTrackDomain

/// Speech of one recording the user named, by person: a whole voice's segments
/// or a named fragment. `person` is the name trimmed and lowercased; the user's
/// names are unique, so equal names are one person (user decision, 2026-10-14).
public struct NamedSpeech: Equatable, Sendable {
    public let person: String
    public let name: String
    public let recordingID: UUID
    public let intervals: [MediaInterval]

    public init(name: String, recordingID: UUID, intervals: [MediaInterval]) {
        self.person = Self.person(name); self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recordingID = recordingID; self.intervals = intervals
    }
    public static func person(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}

/// Which person's named speech covers a stretch of voice activity.
enum SpeakerLinks {
    /// Named speech of one person must cover at least this share of the activity,
    /// and everyone else's at most `foreign`; mixed activity has no person.
    static let covered = 0.5
    static let foreign = 0.2

    static func person(of activity: [MediaInterval], recordingID: UUID, named: [NamedSpeech]) -> String? {
        let own = SpeakerVoiceGroups.union(activity)
        let total = own.reduce(0) { $0 + $1.duration.seconds }
        guard total > 0 else { return nil }
        var shares: [String: Double] = [:]
        for speech in named where speech.recordingID == recordingID {
            shares[speech.person, default: 0] += SpeakerIntervals.intersection(own, SpeakerVoiceGroups.union(speech.intervals))
                .reduce(0) { $0 + $1.duration.seconds }
        }
        guard let best = shares.max(by: { $0.value < $1.value }), best.value >= covered * total,
              shares.filter({ $0.key != best.key }).values.reduce(0, +) <= foreign * total else { return nil }
        return best.key
    }

    /// The person whose named clusters hold most of these clusters' speech
    /// (`speech` seconds; each cluster counts 1 without it), with at most
    /// `foreign` of it named for others.
    static func owner(of members: [UUID], links: [UUID: String], speech: [UUID: Double]) -> String? {
        func weight(_ id: UUID) -> Double { speech.isEmpty ? 1 : speech[id] ?? 0 }
        let total = members.reduce(0) { $0 + weight($1) }
        guard total > 0 else { return nil }
        var shares: [String: Double] = [:]
        for id in members { if let person = links[id] { shares[person, default: 0] += weight(id) } }
        guard let best = shares.max(by: { $0.value < $1.value }), best.value >= covered * total,
              shares.filter({ $0.key != best.key }).values.reduce(0, +) <= foreign * total else { return nil }
        return best.key
    }

    /// Streaming clusters linked to a person, from the checkpoint's system windows.
    static func links(windows: [FinalWindowCheckpoint], named: [NamedSpeech]) -> [UUID: String] {
        guard !named.isEmpty else { return [:] }
        return activity(windows).compactMapValues { person(of: $0.1, recordingID: $0.0, named: named) }
    }

    /// Each cluster's recording and the transcribed part of its activity: where
    /// segmentation heard it and recognized words exist. Silence inside an
    /// activity span carries no name and must not dilute coverage.
    static func activity(_ windows: [FinalWindowCheckpoint]) -> [UUID: (UUID, [MediaInterval])] {
        let words = SpeakerVoiceGroups.union(windows.filter { $0.track == .system }.flatMap { $0.blocks ?? [] }.map(\.interval))
        var result: [UUID: (UUID, [MediaInterval])] = [:]
        for window in windows where window.track == .system {
            for segment in window.speakers ?? [] {
                result[segment.speakerID, default: (segment.recordingID, [])].1 += SpeakerIntervals.intersection([segment.active], words)
            }
        }
        return result
    }
}

/// Two voices of one recording day as the standard whole-recording
/// consolidation forms them, compared the way it compares groups: the average
/// cosine between every retained vector of one and every vector of the other.
public struct SpeakerVoicePair: Codable, Equatable, Sendable {
    public let first: UUID
    public let second: UUID
    public let similarity: Double
    /// The segmentation heard both within one window.
    public let apart: Bool
}

/// The standard consolidation's voices rebuilt from a final checkpoint, with
/// their activity, so named speech can label them independently of how the
/// recording was later published: merging two voices of one person must not
/// remove the evidence that taught the merge. Only clusters with vectors take
/// part, as in consolidation.
public struct SpeakerVoiceGroups: Sendable {
    public struct Group: Sendable {
        public let id: UUID
        public let dayID: UUID
        public let recordingID: UUID
        public let clusterIDs: [UUID]
        public let vectors: [[Float]]
        public let activity: [MediaInterval]
    }
    public let groups: [Group]
    public let pairs: [SpeakerVoicePair]

    public init(checkpoint: FinalTranscriptionCheckpoint) throws {
        let models = Dictionary(uniqueKeysWithValues: checkpoint.job.models.map { ($0.role, $0) })
        guard let data = checkpoint.speakerCheckpoint, let segmentation = models[.segmentation],
              let embedding = models[.embedding], let recordingID = checkpoint.job.recordingID else { groups = []; pairs = []; return }
        let clustering = try SystemSpeakerClustering(restoring: data, meetingID: checkpoint.job.source.meetingID,
                                                     segmentation: segmentation, embedding: embedding)
        let apart = SpeakerConsolidation.apart(checkpoint.windows)
        let mapping = clustering.consolidation(apart: apart, speech: SpeakerConsolidation.speech(checkpoint.windows))
        let activity = SpeakerLinks.activity(checkpoint.windows).mapValues(\.1)
        let vectors = Dictionary(clustering.voiceEvidence.map { ($0.speakerID, $0.vectors) }, uniquingKeysWith: { first, _ in first })
        var members: [UUID: [DaySpeaker]] = [:], order: [UUID] = []
        for speaker in clustering.speakers where !(vectors[speaker.id] ?? []).isEmpty {
            let rep = mapping[speaker.id] ?? speaker.id
            if members[rep] == nil { order.append(rep) }
            members[rep, default: []].append(speaker)
        }
        groups = order.map { rep in
            let clusters = members[rep]!
            return Group(id: rep, dayID: clusters[0].dayID, recordingID: recordingID, clusterIDs: clusters.map(\.id),
                         vectors: clusters.flatMap { vectors[$0.id]! }, activity: Self.union(clusters.flatMap { activity[$0.id] ?? [] }))
        }
        var result: [SpeakerVoicePair] = []
        for a in groups.indices { for b in groups.indices where b > a && groups[a].dayID == groups[b].dayID {
            let left = groups[a], right = groups[b]
            result.append(SpeakerVoicePair(first: left.id, second: right.id, similarity: Self.average(left.vectors, right.vectors),
                apart: left.clusterIDs.contains { !(apart[$0] ?? []).isDisjoint(with: right.clusterIDs) }))
        } }
        pairs = result
    }

    /// Each group's person, when named speech covers it (`SpeakerLinks`).
    public func persons(_ named: [NamedSpeech]) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: groups.compactMap { group in
            SpeakerLinks.person(of: group.activity, recordingID: group.recordingID, named: named).map { (group.id, $0) }
        })
    }

    static func union(_ ranges: [MediaInterval]) -> [MediaInterval] {
        var result: [MediaInterval] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1] = try! MediaInterval(start: last.start, end: max(last.end, range.end))
            } else { result.append(range) }
        }
        return result
    }

    static func average(_ a: [[Float]], _ b: [[Float]]) -> Double {
        var total = 0.0
        for x in a { for y in b { total += zip(x, y).reduce(0.0) { $0 + Double($1.0) * Double($1.1) } } }
        return total / Double(a.count * b.count)
    }
}
