import Accelerate
import CryptoKit
import Foundation
import TalkTrackDomain

/// The streaming clusters of one final checkpoint: each cluster's clean-speech
/// vectors and transcribed activity, and each system block's clusters. Built
/// without models; one cluster is a few seconds of one voice.
public struct ReplyClusters: Sendable {
    public struct Cluster: Sendable {
        public let id: UUID
        public let vectors: [[Float]]
        public let activity: [MediaInterval]
    }
    public let recordingID: UUID
    public let embedding: ModelSnapshot
    public let clusters: [UUID: Cluster]
    /// System block → its streaming clusters (before consolidation).
    public let blocks: [UUID: [UUID]]
    /// Clusters the segmentation heard within one window.
    public let apart: [UUID: Set<UUID>]

    public init?(checkpoint: FinalTranscriptionCheckpoint) throws {
        let models = Dictionary(uniqueKeysWithValues: checkpoint.job.models.map { ($0.role, $0) })
        guard let data = checkpoint.speakerCheckpoint, let segmentation = models[.segmentation],
              let embedding = models[.embedding], let recordingID = checkpoint.job.recordingID else { return nil }
        let clustering = try SystemSpeakerClustering(restoring: data, meetingID: checkpoint.job.source.meetingID,
                                                     segmentation: segmentation, embedding: embedding)
        let activity = SpeakerLinks.activity(checkpoint.windows)
        self.recordingID = recordingID; self.embedding = embedding
        clusters = Dictionary(uniqueKeysWithValues: clustering.voiceEvidence.map {
            ($0.speakerID, Cluster(id: $0.speakerID, vectors: $0.vectors, activity: activity[$0.speakerID]?.1 ?? []))
        })
        blocks = Dictionary(checkpoint.blocks.filter { $0.track == .system }.map { ($0.id, $0.speakerCandidates) },
                            uniquingKeysWith: { first, _ in first })
        apart = SpeakerConsolidation.apart(checkpoint.windows)
    }

    /// Unnamed clusters heard together with `person`'s named clusters: other
    /// people, as far as anyone can tell without names. They give a threshold
    /// even before a second person is named; if one is the person after all,
    /// the threshold only gets stricter.
    public func strangers(of person: String, links: [UUID: String]) -> [[[Float]]] {
        let own = links.filter { $0.value == person }.map(\.key)
        let heard = Set(own.flatMap { apart[$0] ?? [] })
        return heard.filter { links[$0] == nil }.sorted { $0.uuidString < $1.uuidString }
            .compactMap { clusters[$0]?.vectors }.filter { !$0.isEmpty }
    }

    /// Clusters whose transcribed speech is one person's named speech.
    public func links(_ named: [NamedSpeech]) -> [UUID: String] {
        clusters.compactMapValues { cluster in
            cluster.vectors.isEmpty ? nil : SpeakerLinks.person(of: cluster.activity, recordingID: recordingID, named: named)
        }
    }
}

/// One named cluster: a held-out unit of the leave-one-reply-out measurement.
public struct NamedCluster: Sendable {
    public let person: String
    public let recordingID: UUID
    public let id: UUID
    public let vectors: [[Float]]
    /// Clusters sharing a block with this one: the same reply, excluded when
    /// it is held out so neighbouring windows of one reply cannot vouch for it.
    public let neighbours: Set<UUID>
    public init(person: String, recordingID: UUID, id: UUID, vectors: [[Float]], neighbours: Set<UUID>) {
        self.person = person; self.recordingID = recordingID; self.id = id; self.vectors = vectors; self.neighbours = neighbours
    }
}

/// Names unnamed replies by comparing their voice with the user's named
/// replies (user decision, 2026-10-14). Each reply's clusters score against
/// each named person's clusters: the lower median, over the reply's vectors,
/// of the best cosine in the person's bank (matcher v2). The threshold is
/// measured leaving one reply out at a time: above every score a held-out reply
/// reached for someone else, so on the user's names no reply gets a wrong name.
public struct ReplyRecognition: Sendable {
    public static let version = "named-replies-loo-v2"
    public static let headroom = 0.03
    public static let margin = 0.05
    /// Never below this, whatever the names show. On the user's Daily names
    /// (2026-10-14) different people's replies scored up to about 0.64, and
    /// both wrong names in simulation came from thresholds below 0.65.
    public static let floor = 0.65
    /// A reply below the threshold may take the only person its diarization
    /// group was named or recognized as, if its voice is closest to that person
    /// and scores at least this (measured on the user's Daily, 2026-10-14).
    public static let groupFloor = 0.4
    /// Scores of other people needed before any reply is named.
    public static let minimumNegatives = 5

    public struct Measurement: Codable, Equatable, Sendable {
        public let version: String
        public let people: Int
        public let positives: Int
        public let negatives: Int
        /// Held-out named clusters the threshold and margin would name, all correctly.
        public let accepted: Int
        public let threshold: Double?
        public let hash: String
        public var isActive: Bool { threshold != nil }
    }

    public let banks: [String: [[Float]]]
    public let names: [String: String]
    public let measurement: Measurement

    /// `strangers`: per person, clusters known to be someone else (heard at the
    /// same time); their scores against the person's whole bank are negatives too.
    public init(named clusters: [NamedCluster], names: [String: String], strangers: [String: [[[Float]]]] = [:]) {
        var banks: [String: [[Float]]] = [:]
        for cluster in clusters { banks[cluster.person, default: []] += cluster.vectors }
        self.banks = banks; self.names = names
        var positives: [Double] = [], negatives: [Double] = []
        var trials: [(own: Double, other: Double)] = []
        // Every named vector against every other, once.
        let all = clusters.flatMap(\.vectors)
        let owner = clusters.indices.flatMap { index in Array(repeating: index, count: clusters[index].vectors.count) }
        let similarity = Self.cosines(all, all)
        var start = 0
        let persons = Set(clusters.map(\.person))
        for (index, held) in clusters.enumerated() {
            let rows = start..<(start + held.vectors.count); start += held.vectors.count
            var best = -1.0, own = -1.0
            for person in persons {
                let usable = owner.indices.filter { column in
                    let other = clusters[owner[column]]
                    return other.person == person && owner[column] != index &&
                        !(other.recordingID == held.recordingID && held.neighbours.contains(other.id))
                }
                guard !usable.isEmpty else { continue }
                let perVector = rows.map { row in usable.map { Double(similarity[row * all.count + $0]) }.max()! }.sorted()
                let score = perVector[(perVector.count - 1) / 2]
                if person == held.person { own = score; positives.append(score) } else { negatives.append(score); best = max(best, score) }
            }
            if own > -1 { trials.append((own, best)) }
        }
        // Voices heard at the same time stand in for other people only until
        // someone else is named: they include the person's own split voices
        // often enough to make the threshold needlessly strict.
        if negatives.count < Self.minimumNegatives {
            for (person, others) in strangers {
                guard let bank = banks[person] else { continue }
                negatives += others.map { Self.score($0, bank: bank) }
            }
        }
        let people = Set(clusters.map(\.person)).filter { person in Set(clusters.filter { $0.person == person }.map(\.id)).count >= 2 }.count
        let candidate = max(Self.floor, (negatives.max() ?? 1) + Self.headroom)
        let accepted = trials.filter { $0.own >= candidate && $0.own - $0.other >= Self.margin }.count
        let threshold = people >= 1 && negatives.count >= Self.minimumNegatives && accepted > 0 ? candidate : nil
        let text = (positives.map { String(format: "p%.6f", $0) } + negatives.map { String(format: "n%.6f", $0) }).sorted().joined(separator: ",")
        measurement = Measurement(version: Self.version, people: people, positives: positives.count, negatives: negatives.count,
            accepted: accepted, threshold: threshold,
            hash: SHA256.hash(data: Data((Self.version + text).utf8)).map { String(format: "%02x", $0) }.joined())
    }

    /// Every named person's score for these vectors, best first.
    public func ranked(for vectors: [[Float]]) -> [(person: String, score: Double)] {
        banks.map { (person: $0.key, score: Self.score(vectors, bank: $0.value)) }.sorted { $0.score > $1.score }
    }

    /// The named person a reply's vectors match, if the measurement allows it.
    public func person(for vectors: [[Float]]) -> String? {
        guard let threshold = measurement.threshold, !vectors.isEmpty else { return nil }
        let ranked = banks.map { ($0.key, Self.score(vectors, bank: $0.value)) }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= threshold,
              best.1 - (ranked.dropFirst().first?.1 ?? -1) >= Self.margin else { return nil }
        return best.0
    }

    /// Lower median over `vectors` of the best cosine in `bank`.
    static func score(_ vectors: [[Float]], bank: [[Float]]) -> Double {
        guard !vectors.isEmpty, !bank.isEmpty else { return -1 }
        let matrix = cosines(vectors, bank)
        let best = vectors.indices.map { row in Double(matrix[(row * bank.count)..<((row + 1) * bank.count)].max()!) }.sorted()
        return best[(best.count - 1) / 2]
    }

    /// Row-major |a| × |b| dot products of unit vectors (Accelerate, so it is
    /// fast in Debug builds too).
    static func cosines(_ a: [[Float]], _ b: [[Float]]) -> [Float] {
        guard let width = a.first?.count, !b.isEmpty, a.allSatisfy({ $0.count == width }), b.allSatisfy({ $0.count == width }) else {
            return a.flatMap { x in b.map { y in zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } } }
        }
        let left = a.flatMap { $0 }
        var right = [Float](repeating: 0, count: width * b.count)
        for (column, vector) in b.enumerated() { for (row, value) in vector.enumerated() { right[row * b.count + column] = value } }
        var result = [Float](repeating: 0, count: a.count * b.count)
        vDSP_mmul(left, 1, right, 1, &result, 1, vDSP_Length(a.count), vDSP_Length(b.count), vDSP_Length(width))
        return result
    }
}
