import Foundation
import TalkTrackDomain

public enum SpeakerClusteringError: Error, Equatable, LocalizedError, Sendable {
    case invalidInput, incompatibleModel, invalidCheckpoint, outOfOrder, speakerLimit, busy
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Speaker processing received invalid audio, intervals or voice evidence. Retry the recording."
        case .incompatibleModel: "The voice evidence uses a different model or preprocessing revision. Reprocess with the selected model."
        case .invalidCheckpoint: "The speaker checkpoint is incompatible or damaged. Restart processing from saved audio."
        case .outOfOrder: "Speaker windows must be processed once, in source order. Resume from the matching checkpoint."
        case .speakerLimit: "Speaker tracking reached its resource limit. Review the noisy recording or retry with a larger tracking limit."
        case .busy: "Speaker processing is already active. Wait for it to finish or cancel it."
        }
    }
}

/// Window-local slots never escape as meeting identities. Runtime bridges the
/// MLX adapter to these framework-independent service values.
public struct SpeakerWindowActivity: Sendable {
    public let slot: Int
    public let relative: MediaInterval
    public init(slot: Int, relative: MediaInterval) { self.slot = slot; self.relative = relative }
}
public struct SpeakerWindowEmbedding: Sendable {
    public let values: [Float]
    public let model: ModelSnapshot
    public init(values: [Float], model: ModelSnapshot) { self.values = values; self.model = model }
}
public protocol SystemSpeakerInference: Sendable {
    func speakerActivity(_ model: ModelSnapshot, samples: [Float]) async throws -> [SpeakerWindowActivity]
    func speakerEmbedding(_ model: ModelSnapshot, samples: [Float]) async throws -> SpeakerWindowEmbedding
}

public struct SpeakerClusteringPolicy: Codable, Equatable, Sendable {
    public let minimumSimilarity: Double
    public let ambiguityMargin: Double
    public let maximumSpeakersPerDay: Int
    /// The limit bounds the streaming bank, not real voices: it holds every
    /// provisional cluster (including short replies without a vector) before
    /// whole-recording consolidation, about 17 per 100 s of a real call
    /// (measured). 128 failed a 16.7-minute call;
    /// 4096 (≤ 8 vectors each) covers several hours.
    public static let standard = Self(similarity: 0.85, margin: 0.1, limit: 4096)
    public init(minimumSimilarity: Double = 0.85, ambiguityMargin: Double = 0.1, maximumSpeakersPerDay: Int = 4096) throws {
        guard minimumSimilarity.isFinite, (0...1).contains(minimumSimilarity), ambiguityMargin.isFinite,
              (0...1).contains(ambiguityMargin), (1...4096).contains(maximumSpeakersPerDay) else {
            throw SpeakerClusteringError.invalidInput
        }
        self.init(similarity: minimumSimilarity, margin: ambiguityMargin, limit: maximumSpeakersPerDay)
    }
    private init(similarity: Double, margin: Double, limit: Int) {
        minimumSimilarity = similarity; ambiguityMargin = margin; maximumSpeakersPerDay = limit
    }
}

public struct SpeakerClusteringObservation: Sendable {
    public let slot: Int
    public let activity: [MediaInterval]
    public let cleanSpeech: [MediaInterval]
    public let embedding: SpeakerWindowEmbedding?
    public init(slot: Int, activity: [MediaInterval], cleanSpeech: [MediaInterval] = [], embedding: SpeakerWindowEmbedding? = nil) {
        self.slot = slot; self.activity = activity; self.cleanSpeech = cleanSpeech; self.embedding = embedding
    }
}
public struct ClusteredSpeakerActivity: Sendable {
    public let slot: Int
    public let speakerID: UUID
    public let number: UInt
    public let active: MediaInterval
}

/// Incremental meeting/day clustering. Retains eight verified vectors per
/// speaker and one ten-second context, never PCM or complete embedding history.
/// Thresholds here govern unnamed clusters, not calibrated saved-person names.
public struct SystemSpeakerClustering: Sendable {
    private struct DayKey: Codable, Equatable, Sendable {
        let date: String, zone: String, calendar: String
        init(_ day: RecordingDay) { date = day.localDate; zone = day.timeZoneIdentifier; calendar = day.calendarIdentifier }
    }
    private struct Cluster: Codable, Sendable {
        let id: UUID
        var vectors: [[Float]]
    }
    private struct DayState: Codable, Sendable {
        let key: DayKey
        let canonicalID: UUID
        var aliases: [UUID]
        var clusters: [Cluster]
    }
    private struct Cursor: Codable, Sendable { let recordingID: UUID; var end: MediaTime }
    private struct ContextSlot: Codable, Sendable { let slot: Int; let id: UUID?; let activity: [MediaInterval] }
    private struct Context: Codable, Sendable {
        let recordingID: UUID, dayID: UUID
        let active: MediaInterval
        let slots: [ContextSlot]
    }
    private struct State: Codable, Sendable {
        let version: Int
        let meetingID: UUID
        let segmentation: ModelSnapshot
        let embedding: ModelSnapshot
        var policy: SpeakerClusteringPolicy
        var days: [DayState] = []
        var cursors: [Cursor] = []
        var context: Context?
    }
    private var state: State
    public init(meetingID: UUID, segmentation: ModelSnapshot, embedding: ModelSnapshot, policy: SpeakerClusteringPolicy = .standard) throws {
        guard segmentation.role == .segmentation, embedding.role == .embedding else { throw SpeakerClusteringError.incompatibleModel }
        state = State(version: 1, meetingID: meetingID, segmentation: segmentation, embedding: embedding, policy: policy)
    }
    public var speakers: [DaySpeaker] {
        state.days.flatMap { day in day.clusters.enumerated().map {
            DaySpeaker(id: $1.id, meetingID: state.meetingID, dayID: day.canonicalID, number: UInt($0 + 1), recordingDayIDs: day.aliases)
        } }
    }
    public var retainedVectorCount: Int { state.days.reduce(0) { $0 + $1.clusters.reduce(0) { $0 + $1.vectors.count } } }
    /// Bounded clean-speech banks for same-source revision reconciliation.
    /// These are not trained or calibrated saved-person profiles.
    public var voiceEvidence: [TranscriptVoiceEvidence] {
        speakers.map { speaker in
            let cluster = state.days.flatMap(\.clusters).first { $0.id == speaker.id }!
            return TranscriptVoiceEvidence(speakerID: speaker.id, segmentation: state.segmentation,
                embedding: state.embedding, vectors: cluster.vectors)
        }
    }
    /// Same-day clusters whose voices belong together, as cluster → representative.
    /// The streaming pass only joins near-certain matches, so one real voice ends
    /// up in many clusters; this whole-recording pass merges them by average
    /// cosine similarity between their retained clean-speech vectors (average
    /// linkage). Clusters without vectors are left alone. Measured on a real
    /// 8-9-person call: 87 embeddings, nearest-neighbour median 0.73, between-
    /// voice median 0.25; average linkage at 0.4 gave 9 groups.
    /// `apart` lists clusters known to be different people (the segmentation
    /// separated them within one window); groups containing such a pair never
    /// merge. Without it, a quick question and its answer by voices of similar
    /// timbre were joined into one speaker on that call.
    ///
    /// `speech` (seconds per cluster) enables a second step (task 5.9): a group
    /// with less than `minorSeconds` of speech has too few vectors to stand as
    /// its own voice and joins the most similar group with more speech when
    /// their average similarity reaches `absorbFloor` and they are not apart, or
    /// reaches `apartOverride` although apart from a group with at least
    /// `minorSeconds` of speech: the segmentation also splits one
    /// voice inside a window (a pause, a cut in a video), leaving a 1–2 s fragment
    /// as a voice of its own. Such fragments measured 0.63–0.76 to their speaker,
    /// while differently named people on the user's calls stayed at or below 0.293.
    /// On a 16.7-minute call with at most 8 people this left 10 voices instead
    /// of 28.
    ///
    /// `links` (cluster → person, from the user's names): groups of different
    /// persons never merge, and after the standard steps all groups of one
    /// person merge, even against `apart`. `learned` (`SpeakerMergeCalibration`)
    /// then merges the resulting groups at or above it, also against `apart`.
    /// It was calibrated on the standard steps' groups, so it is applied to
    /// groups, not to the streaming clusters they are built from.
    public func consolidation(threshold: Double = 0.4, apart: [UUID: Set<UUID>] = [:], apartOverride: Double = 0.6,
                              speech: [UUID: Double] = [:], minorSeconds: Double = 8, absorbFloor: Double = 0.2,
                              links: [UUID: String] = [:], learned: Double? = nil) -> [UUID: UUID] {
        typealias Group = (ids: [UUID], vectors: [[Float]])
        var mapping: [UUID: UUID] = [:]
        func separated(_ a: Group, _ b: Group) -> Bool { a.ids.contains { !(apart[$0] ?? []).isDisjoint(with: b.ids) } }
        /// Clusters named for two different people never share a voice.
        func conflict(_ a: Group, _ b: Group) -> Bool { Set((a.ids + b.ids).compactMap { links[$0] }).count > 1 }
        func owner(_ group: Group) -> String? { SpeakerLinks.owner(of: group.ids, links: links, speech: speech) }
        func average(_ a: [[Float]], _ b: [[Float]]) -> Double {
            var total = 0.0
            for x in a { for y in b { total += Self.cosine(x, y) } }
            return total / Double(a.count * b.count)
        }
        func join(_ groups: inout [Group], _ a: Int, _ b: Int) {
            groups[a].ids += groups[b].ids
            groups[a].vectors += groups[b].vectors
            groups.remove(at: b)
        }
        /// Average linkage, best pair first, down to `limit`. Sums of cosines
        /// between groups are kept and added on each join, so a step costs no
        /// vector arithmetic (the same averages, far faster on long calls).
        func agglomerate(_ groups: inout [Group], limit: Double, acrossApart: Bool) {
            var sums = groups.map { a in groups.map { b in
                var total = 0.0
                for x in a.vectors { for y in b.vectors { total += Self.cosine(x, y) } }
                return total
            } }
            while groups.count > 1 {
                var best: (score: Double, a: Int, b: Int)?
                for a in groups.indices { for b in groups.indices where b > a {
                    let score = sums[a][b] / Double(groups[a].vectors.count * groups[b].vectors.count)
                    guard score >= limit, best == nil || score > best!.score,
                          !conflict(groups[a], groups[b]), acrossApart || !separated(groups[a], groups[b]) else { continue }
                    best = (score, a, b)
                } }
                guard let best else { break }
                for k in groups.indices { sums[best.a][k] += sums[best.b][k] }
                for k in groups.indices { sums[k][best.a] = sums[best.a][k] }
                sums.remove(at: best.b)
                for k in sums.indices { sums[k].remove(at: best.b) }
                join(&groups, best.a, best.b)
            }
        }
        for day in state.days {
            var groups: [Group] = day.clusters.filter { !$0.vectors.isEmpty }.map { ([$0.id], $0.vectors) }
            agglomerate(&groups, limit: threshold, acrossApart: false)
            if !speech.isEmpty {
                func seconds(_ group: Group) -> Double { group.ids.reduce(0) { $0 + (speech[$1] ?? 0) } }
                var majors = groups.filter { seconds($0) >= minorSeconds }
                // Only a voice with enough speech outweighs the segmentation's split;
                // minors appended below never do.
                let established = majors.count
                // Smallest first, each against the majors as they stand; an
                // absorbed minor's vectors join its major only afterwards.
                var absorbed: [Int: [[Float]]] = [:]
                for minor in groups.filter({ seconds($0) < minorSeconds }).sorted(by: { seconds($0) < seconds($1) }) {
                    let target = majors.indices.filter { !conflict(minor, majors[$0]) }
                        .map { (index: $0, score: average(minor.vectors, majors[$0].vectors)) }
                        .filter { ($0.index < established && $0.score >= apartOverride) || !separated(minor, majors[$0.index]) }
                        .max { $0.score < $1.score }
                    if let target, target.score >= absorbFloor {
                        majors[target.index].ids += minor.ids
                        absorbed[target.index, default: []] += minor.vectors
                    } else { majors.append(minor) }
                }
                for (index, vectors) in absorbed { majors[index].vectors += vectors }
                groups = majors
            }
            // One person, one voice: groups whose speech is mostly one
            // person's named speech merge.
            var index = 0
            while index < groups.count {
                if let person = owner(groups[index]),
                   let other = groups.indices.first(where: { $0 > index && owner(groups[$0]) == person && !conflict(groups[index], groups[$0]) }) {
                    join(&groups, index, other)
                } else { index += 1 }
            }
            if let learned { agglomerate(&groups, limit: learned, acrossApart: true) }
            for group in groups {
                // The earliest cluster of the day represents the group.
                let representative = day.clusters.first { group.ids.contains($0.id) }!.id
                for id in group.ids { mapping[id] = representative }
            }
            // A named cluster without vectors follows its person's voice.
            for cluster in day.clusters where cluster.vectors.isEmpty {
                guard let person = links[cluster.id] else { continue }
                if let group = groups.first(where: { owner($0) == person }) {
                    mapping[cluster.id] = day.clusters.first { group.ids.contains($0.id) }!.id
                } else {
                    mapping[cluster.id] = day.clusters.first { $0.vectors.isEmpty && links[$0.id] == person }!.id
                }
            }
        }
        return mapping
    }
    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
    }
    public func checkpoint() throws -> Data { try DomainCodec.encode(state) }
    public init(restoring data: Data, meetingID: UUID, segmentation: ModelSnapshot, embedding: ModelSnapshot,
                policy: SpeakerClusteringPolicy = .standard) throws {
        var value = try DomainCodec.decode(State.self, from: data)
        // A checkpoint saved under a smaller bank limit resumes under a larger
        // one; matching thresholds keep earlier assignments valid.
        guard value.version == 1, value.meetingID == meetingID, value.segmentation == segmentation,
              value.embedding == embedding, value.policy.minimumSimilarity == policy.minimumSimilarity,
              value.policy.ambiguityMargin == policy.ambiguityMargin,
              value.policy.maximumSpeakersPerDay <= policy.maximumSpeakersPerDay,
              segmentation.role == .segmentation, embedding.role == .embedding,
              Set(value.cursors.map(\.recordingID)).count == value.cursors.count,
              Set(value.days.flatMap(\.aliases)).count == value.days.flatMap(\.aliases).count,
              Set(value.days.flatMap { $0.clusters.map(\.id) }).count == value.days.flatMap(\.clusters).count else {
            throw SpeakerClusteringError.invalidCheckpoint
        }
        for (i, day) in value.days.enumerated() {
            guard !value.days[..<i].contains(where: { $0.key == day.key }), !day.aliases.isEmpty,
                  day.aliases.contains(day.canonicalID), day.clusters.count <= policy.maximumSpeakersPerDay else {
                throw SpeakerClusteringError.invalidCheckpoint
            }
            for cluster in day.clusters {
                guard cluster.vectors.count <= 8, cluster.vectors.allSatisfy(Self.validVector) else { throw SpeakerClusteringError.invalidCheckpoint }
            }
        }
        if let context = value.context {
            guard context.active.duration > .zero, context.active.duration.seconds <= 10.000001, context.slots.count <= 3,
                  Set(context.slots.map(\.slot)).count == context.slots.count,
                  let day = value.days.first(where: { $0.aliases.contains(context.dayID) }),
                  let cursor = value.cursors.first(where: { $0.recordingID == context.recordingID }),
                  cursor.end <= context.active.end, cursor.end > context.active.start else { throw SpeakerClusteringError.invalidCheckpoint }
            for slot in context.slots {
                guard (1...3).contains(slot.slot), Self.validIntervals(slot.activity, within: context.active),
                      slot.id == nil || day.clusters.contains(where: { $0.id == slot.id }) else { throw SpeakerClusteringError.invalidCheckpoint }
                guard !context.slots.contains(where: { $0.slot != slot.slot && slot.id != nil && $0.id == slot.id && Self.overlaps($0.activity, slot.activity) }) else {
                    throw SpeakerClusteringError.invalidCheckpoint
                }
            }
        }
        value.policy = policy
        state = value
    }

    public mutating func process(recordingID: UUID, day: RecordingDay, context: MediaInterval, owned: MediaInterval,
                                 observations: [SpeakerClusteringObservation]) throws -> [ClusteredSpeakerActivity] {
        try Task.checkCancellation()
        guard context.duration > .zero, context.duration.seconds <= 10.000001, owned.duration > .zero,
              owned.start >= context.start, owned.end <= context.end, observations.count <= 3,
              Set(observations.map(\.slot)).count == observations.count else { throw SpeakerClusteringError.invalidInput }
        for observation in observations {
            guard (1...3).contains(observation.slot), Self.validIntervals(observation.activity, within: context),
                  Self.validIntervals(observation.cleanSpeech, within: owned) else { throw SpeakerClusteringError.invalidInput }
            for clean in observation.cleanSpeech {
                guard observation.activity.contains(where: { $0.start <= clean.start && clean.end <= $0.end }),
                      !observations.filter({ $0.slot != observation.slot }).contains(where: { Self.overlaps($0.activity, [clean]) }) else {
                    throw SpeakerClusteringError.invalidInput
                }
            }
            if let embedding = observation.embedding {
                guard embedding.model == state.embedding else { throw SpeakerClusteringError.incompatibleModel }
                guard Self.validVector(embedding.values), observation.cleanSpeech.reduce(0, { $0 + $1.duration.microseconds }) >= 1_000_000 else {
                    throw SpeakerClusteringError.invalidInput
                }
            }
        }
        var next = state
        try Self.advance(recordingID, range: owned, state: &next)
        let dayIndex = try Self.dayIndex(day, state: &next)
        let original = next.days[dayIndex].clusters
        let ordered = observations.filter { Self.overlaps($0.activity, [owned]) }.sorted {
            let left = $0.activity.first { Self.overlaps([$0], [owned]) }!.start
            let right = $1.activity.first { Self.overlaps([$0], [owned]) }!.start
            return left == right ? $0.slot < $1.slot : left < right
        }
        var proposed: [Int: UUID] = [:]
        for observation in ordered {
            let temporal = continuity(observation, peers: observations, recordingID: recordingID, dayID: day.id, context: context)
            if let temporal, let cluster = original.first(where: { $0.id == temporal }),
               observation.embedding == nil || cluster.vectors.isEmpty || Self.similarity(observation.embedding!.values, cluster) >= state.policy.minimumSimilarity {
                proposed[observation.slot] = temporal
            } else if let vector = observation.embedding?.values {
                let measured: [(id: UUID, score: Double)] = original.filter { !$0.vectors.isEmpty }.map {
                    (id: $0.id, score: Self.similarity(vector, $0))
                }
                let scores = measured.sorted { left, right in
                    left.score == right.score ? left.id.uuidString < right.id.uuidString : left.score > right.score
                }
                if let best = scores.first, best.1 >= state.policy.minimumSimilarity,
                   best.1 - (scores.dropFirst().first?.1 ?? -1) >= state.policy.ambiguityMargin { proposed[observation.slot] = best.0 }
            }
        }
        // Evaluate against the pre-window bank. Competing simultaneous slots
        // cannot greedily inherit one identity, even with identical vectors.
        let candidates = proposed
        for observation in ordered {
            guard let id = candidates[observation.slot] else { continue }
            let conflicting = ordered.contains { $0.slot != observation.slot && candidates[$0.slot] == id && Self.overlaps($0.activity, observation.activity) }
            let previousConflict = state.context.map { previous in
                previous.recordingID == recordingID && previous.dayID == day.id && previous.slots.contains {
                    $0.id != nil && $0.id != id && Self.overlaps($0.activity, observation.activity)
                }
            } ?? false
            if conflicting || previousConflict { proposed.removeValue(forKey: observation.slot) }
        }
        var result: [ClusteredSpeakerActivity] = []
        for observation in ordered {
            try Task.checkCancellation()
            let index: Int
            if let id = proposed[observation.slot], let found = next.days[dayIndex].clusters.firstIndex(where: { $0.id == id }) { index = found }
            else {
                guard next.days[dayIndex].clusters.count < state.policy.maximumSpeakersPerDay else { throw SpeakerClusteringError.speakerLimit }
                index = next.days[dayIndex].clusters.count
                next.days[dayIndex].clusters.append(Cluster(id: UUID(), vectors: []))
                proposed[observation.slot] = next.days[dayIndex].clusters[index].id
            }
            if let vector = observation.embedding?.values {
                next.days[dayIndex].clusters[index].vectors.append(vector)
                // Preserve the first verified anchor. Recent evidence cannot
                // walk a cluster gradually toward a different voice.
                if next.days[dayIndex].clusters[index].vectors.count > 8 { next.days[dayIndex].clusters[index].vectors.remove(at: 1) }
            }
            for active in SpeakerIntervals.intersection(observation.activity, [owned]) {
                result.append(ClusteredSpeakerActivity(slot: observation.slot, speakerID: next.days[dayIndex].clusters[index].id,
                    number: UInt(index + 1), active: active))
            }
        }
        next.context = Context(recordingID: recordingID, dayID: day.id, active: context,
            slots: observations.map { ContextSlot(slot: $0.slot, id: proposed[$0.slot], activity: $0.activity) })
        try Task.checkCancellation()
        state = next
        return result.sorted { $0.active.start == $1.active.start ? $0.number < $1.number : $0.active.start < $1.active.start }
    }

    public mutating func gap(recordingID: UUID, day: RecordingDay, active: MediaInterval) throws {
        try Task.checkCancellation()
        guard active.duration > .zero else { throw SpeakerClusteringError.invalidInput }
        var next = state
        try Self.advance(recordingID, range: active, state: &next)
        _ = try Self.dayIndex(day, state: &next)
        next.context = nil
        try Task.checkCancellation()
        state = next
    }

    private func continuity(_ observation: SpeakerClusteringObservation, peers: [SpeakerClusteringObservation],
                            recordingID: UUID, dayID: UUID, context: MediaInterval) -> UUID? {
        guard let previous = state.context, previous.recordingID == recordingID, previous.dayID == dayID,
              Self.overlaps([context], [previous.active]) else { return nil }
        let clean = SpeakerIntervals.subtract(observation.activity, removing: peers.filter { $0.slot != observation.slot }.flatMap(\.activity))
        var supports: [UUID: Int64] = [:]
        for slot in previous.slots {
            guard let id = slot.id else { continue }
            let oldClean = SpeakerIntervals.subtract(slot.activity, removing: previous.slots.filter { $0.slot != slot.slot }.flatMap(\.activity))
            supports[id, default: 0] += SpeakerIntervals.intersection(clean, oldClean).reduce(0) { $0 + $1.duration.microseconds }
        }
        let sorted = supports.sorted { $0.value == $1.value ? $0.key.uuidString < $1.key.uuidString : $0.value > $1.value }
        guard let best = sorted.first, best.value >= 200_000,
              best.value - (sorted.dropFirst().first?.value ?? 0) >= 200_000 else { return nil }
        return best.key
    }
    private static func advance(_ recordingID: UUID, range: MediaInterval, state: inout State) throws {
        if let i = state.cursors.firstIndex(where: { $0.recordingID == recordingID }) {
            guard state.cursors[i].end == range.start else { throw SpeakerClusteringError.outOfOrder }
            state.cursors[i].end = range.end
        } else {
            guard range.start == .zero else { throw SpeakerClusteringError.outOfOrder }
            state.cursors.append(Cursor(recordingID: recordingID, end: range.end))
        }
    }
    private static func dayIndex(_ day: RecordingDay, state: inout State) throws -> Int {
        let key = DayKey(day)
        if let existing = state.days.first(where: { $0.aliases.contains(day.id) }), existing.key != key { throw SpeakerClusteringError.invalidInput }
        if let i = state.days.firstIndex(where: { $0.key == key }) {
            if !state.days[i].aliases.contains(day.id) { state.days[i].aliases.append(day.id) }
            return i
        }
        state.days.append(DayState(key: key, canonicalID: day.id, aliases: [day.id], clusters: []))
        return state.days.count - 1
    }
    private static func validVector(_ values: [Float]) -> Bool {
        values.count == 256 && values.allSatisfy(\.isFinite) && abs(sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) }) - 1) < 0.001
    }
    private static func similarity(_ vector: [Float], _ cluster: Cluster) -> Double {
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        return cluster.vectors.map { reference in
            let referenceNorm = sqrt(reference.reduce(0.0) { $0 + Double($1) * Double($1) })
            let dot = zip(vector, reference).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            return min(1, max(-1, dot / (norm * referenceNorm)))
        }.min() ?? -1
    }
    private static func validIntervals(_ intervals: [MediaInterval], within context: MediaInterval) -> Bool {
        guard intervals.count <= 1800 else { return false }
        var end = context.start
        for interval in intervals {
            guard interval.start >= end, interval.end <= context.end, interval.duration > .zero else { return false }
            end = interval.end
        }
        return true
    }
    private static func overlaps(_ left: [MediaInterval], _ right: [MediaInterval]) -> Bool {
        left.contains { a in right.contains { a.start < $0.end && $0.start < a.end } }
    }
}

/// Small interval sets from a native segmentation window, not PCM buffers.
enum SpeakerIntervals {
    static func intersection(_ left: [MediaInterval], _ right: [MediaInterval]) -> [MediaInterval] {
        left.flatMap { a in right.compactMap { b in
            let start = max(a.start, b.start), end = min(a.end, b.end)
            return end > start ? try? MediaInterval(start: start, end: end) : nil
        } }.sorted { $0.start < $1.start }
    }
    static func subtract(_ source: [MediaInterval], removing: [MediaInterval]) -> [MediaInterval] {
        var result = source
        for cut in removing {
            result = result.flatMap { interval in
                guard interval.start < cut.end, cut.start < interval.end else { return [interval] }
                var pieces: [MediaInterval] = []
                if interval.start < cut.start { pieces.append(try! MediaInterval(start: interval.start, end: cut.start)) }
                if cut.end < interval.end { pieces.append(try! MediaInterval(start: cut.end, end: interval.end)) }
                return pieces
            }
        }
        return result
    }
}
