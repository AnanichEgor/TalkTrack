import CryptoKit
import Foundation
import TalkTrackDomain

/// At most eight normalized clean-speech vectors, tied to immutable adapters.
/// Used only to reconcile revisions of the same recording; never a voice profile.
public struct TranscriptVoiceEvidence: Codable, Equatable, Sendable {
    public let speakerID: UUID
    public let segmentation: ModelSnapshot
    public let embedding: ModelSnapshot
    public let vectors: [[Float]]

    public var fingerprint: String {
        get throws {
            SHA256.hash(data: try DomainCodec.encode(self)).map { String(format: "%02x", $0) }.joined()
        }
    }
}

public enum SpeakerReviewReason: String, Codable, Sendable {
    case splitOrMerge, insufficientEvidence, incompatibleVoice, mixedSpeech
}

public struct SpeakerReconciliationReview: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let previousAssignmentIDs: [UUID]
    public let speakerIDs: [UUID]
    public let blockIDs: [UUID]
    public let reason: SpeakerReviewReason
}

/// Immutable publication provenance. Current names remain separate assignment
/// heads, so a concurrent confirmed rename is read inside the commit transaction.
public struct FinalTranscriptPublication: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let job: ProcessingJobSnapshot
    public let previousRevisionID: UUID?
    public let reconciliationVersion: String
    public let speakers: [DaySpeaker]
    public let voiceEvidence: [TranscriptVoiceEvidence]
    public let assignments: [SpeakerAssignment]
    public let reviews: [SpeakerReconciliationReview]
    /// The merge calibration this publication used; nil before it existed.
    public var mergeCalibration: SpeakerMergeCalibration?
    /// The reply recognition this publication used, and how many replies it named.
    public var replyRecognition: ReplyRecognition.Measurement?
    public var recognizedReplies: Int?
}

struct ReconciledTranscript {
    let revision: TranscriptRevision
    let publication: FinalTranscriptPublication
    /// Names this publication gives voices that hold one person's named speech.
    let linked: [SpeakerAssignment]
    /// Replies named by recognition.
    let recognized: Int
}

enum FinalSpeakerReconciler {
    /// 4: names belong to replies; unnamed replies are recognized from named
    /// ones (guided-speaker-labeling).
    static let version = "named-replies-4"

    static func reconcile(checkpoint: FinalTranscriptionCheckpoint, recording: Recording,
                          previous: TranscriptRevision?, previousPublication: FinalTranscriptPublication?,
                          existingSpeakers: [DaySpeaker], speakersInUse: Set<UUID>? = nil, assignments: [SpeakerAssignment],
                          historicalEvidence: [TranscriptVoiceEvidence],
                          captureDays: [RecordingDay],
                          named: [NamedSpeech] = [], calibration: SpeakerMergeCalibration? = nil,
                          recognition: ReplyRecognition? = nil,
                          revisionID: UUID, at date: Date) throws -> ReconciledTranscript {
        let models = Dictionary(uniqueKeysWithValues: checkpoint.job.models.map { ($0.role, $0) })
        let clustering: SystemSpeakerClustering? = try checkpoint.speakerCheckpoint.map {
            try SystemSpeakerClustering(restoring: $0, meetingID: recording.meetingID,
                segmentation: models[.segmentation]!, embedding: models[.embedding]!)
        }
        let merged = SpeakerConsolidation(clustering: clustering, blocks: checkpoint.blocks, windows: checkpoint.windows,
                                          named: named, learned: calibration?.threshold)
        let candidates = merged.speakers
        let banks = merged.evidence
        let allBlocks = merged.blocks
        func sameCaptureDay(_ a: DaySpeaker, _ b: DaySpeaker) -> Bool {
            guard let left = captureDays.first(where: { $0.id == a.dayID }),
                  let right = captureDays.first(where: { $0.id == b.dayID }) else { return false }
            return left.localDate == right.localDate && left.timeZoneIdentifier == right.timeZoneIdentifier &&
                left.calendarIdentifier == right.calendarIdentifier
        }
        var reviews: [SpeakerReconciliationReview] = []
        // Names belong to replies (user decision, 2026-10-14): diarization
        // groups stay VoiceN; a reply gets a name only when the user named it
        // or its voice matches the user's named replies (`ReplyRecognition`).
        let current = Dictionary(assignments.map { ($0.daySpeakerID, $0) }, uniquingKeysWith: { first, _ in first })
        var linkedNames: [UUID: String] = [:]
        var speakers: [DaySpeaker] = []
        var evidence: [TranscriptVoiceEvidence] = []
        var finalIDs: [UUID: UUID] = [:]
        // Numbers continue only after voices other current transcripts show, so
        // a meeting's unknown voices start at Voice1 even after reprocessing
        // replaced earlier speakers (user request, 2026-10-13).
        func number(for candidate: DaySpeaker) throws -> UInt {
            let shown = speakersInUse.map { ids in existingSpeakers.filter { ids.contains($0.id) } } ?? existingSpeakers
            let lastNumber = (shown + speakers).filter { !$0.unidentified && sameCaptureDay($0, candidate) }.map(\.number).max() ?? 0
            guard lastNumber < UInt.max else { throw StoreError.invalidResult }
            return lastNumber + 1
        }
        func addSpeaker(_ candidate: DaySpeaker) throws -> UUID {
            if let id = finalIDs[candidate.id] { return id }
            var id = candidate.id
            if let old = existingSpeakers.first(where: { $0.id == candidate.id }) {
                // Re-publishing the same clusters (Apply Names) keeps an unnamed
                // voice with its number. A voice that carried a name becomes a new
                // identity, so the name cannot move onto speech nobody named.
                if current[old.id] == nil && candidate.recordingDayIDs.allSatisfy(old.recordingDayIDs.contains) {
                    finalIDs[candidate.id] = old.id
                    speakers.append(old)
                    if let bank = banks.first(where: { $0.speakerID == candidate.id }) { evidence.append(bank) }
                    return old.id
                }
                id = UUID()
            }
            finalIDs[candidate.id] = id
            if speakers.contains(where: { $0.id == id }) { return id }
            let speaker = DaySpeaker(id: id, meetingID: candidate.meetingID, dayID: candidate.dayID,
                number: candidate.unidentified ? 1 : try number(for: candidate), recordingDayIDs: candidate.recordingDayIDs,
                unidentified: candidate.unidentified)
            speakers.append(speaker)
            if let bank = banks.first(where: { $0.speakerID == candidate.id }) {
                evidence.append(TranscriptVoiceEvidence(speakerID: id, segmentation: bank.segmentation, embedding: bank.embedding, vectors: bank.vectors))
            }
            return speaker.id
        }
        // A person's replies of a day share one voice: replies the user named
        // go to the voice the user named so (the lowest-numbered), recognized
        // replies to a linked voice of that person (shown as recognized); with
        // no such named voice both share the linked one. Earlier linked voices
        // of the person are reused, so re-applying names keeps their records.
        var personVoices: [String: UUID] = [:]
        func voice(of person: String, day: RecordingDay, recognized: Bool) throws -> UUID {
            func manual(_ old: DaySpeaker) -> Bool {
                guard let assignment = current[old.id], assignment.origin == .manual, let name = assignment.name else { return false }
                return NamedSpeech.person(name) == person && old.recordingDayIDs.contains(day.id)
            }
            let own = existingSpeakers.filter(manual).min { $0.number < $1.number }
            let key = person + "@" + day.id.uuidString + (recognized && own != nil ? "#recognized" : "")
            if let id = personVoices[key] { return id }
            let id: UUID
            if !recognized, let own {
                id = own.id
                if !speakers.contains(where: { $0.id == own.id }) { speakers.append(own) }
            } else if let old = existingSpeakers.first(where: { old in
                guard let assignment = current[old.id], assignment.origin == .linked, let name = assignment.name else { return false }
                return NamedSpeech.person(name) == person && old.recordingDayIDs.contains(day.id) && !personVoices.values.contains(old.id)
            }) {
                id = old.id
                if !speakers.contains(where: { $0.id == old.id }) { speakers.append(old) }
            } else {
                let fresh = DaySpeaker(meetingID: recording.meetingID, dayID: day.id, number: 1)
                id = try addSpeaker(fresh)
                linkedNames[fresh.id] = named.first { $0.person == person }?.name ?? recognition?.names[person] ?? person
            }
            personVoices[key] = id
            return id
        }
        // A reply's own streaming clusters, before consolidation.
        let original = Dictionary(checkpoint.blocks.map { ($0.id, $0.speakerCandidates) }, uniquingKeysWith: { first, _ in first })
        let vectors = Dictionary((clustering?.voiceEvidence ?? []).map { ($0.speakerID, $0.vectors) }, uniquingKeysWith: { first, _ in first })
        let ordered = allBlocks.sorted {
            if $0.interval.start != $1.interval.start { return $0.interval.start < $1.interval.start }
            if $0.track != $1.track { return $0.track == .system }
            return $0.id.uuidString < $1.id.uuidString
        }
        let echoes = MicrophoneEcho.blocks(in: allBlocks)
        // Who each system reply is: named by the user, else recognized by voice.
        func own(_ block: FinalTextBlock) -> [[Float]]? {
            original[block.id].flatMap { ids in ids.count == 1 ? vectors[ids[0]].flatMap { $0.isEmpty ? nil : $0 } : nil }
        }
        var namedPerson: [UUID: String] = [:], recognizedPerson: [UUID: String] = [:]
        for block in ordered where block.track == .system && !echoes.contains(block.id) {
            if let person = SpeakerLinks.person(of: [block.interval], recordingID: recording.id, named: named) { namedPerson[block.id] = person }
            else if let vectors = own(block), let person = recognition?.person(for: vectors) { recognizedPerson[block.id] = person }
        }
        // A reply below the threshold still takes person P when the standard
        // diarization keeps its voice with replies that are all P's (named or
        // recognized) and its voice is closest to P (at least `groupFloor`). On
        // the user's Daily this named 50 more replies as their 13 October names
        // did and none otherwise; mixed replies are never named this way.
        if let recognition, recognition.measurement.isActive, let clustering {
            let standard = clustering.consolidation(apart: SpeakerConsolidation.apart(checkpoint.windows),
                                                    speech: SpeakerConsolidation.speech(checkpoint.windows))
            func group(_ block: FinalTextBlock) -> UUID? {
                original[block.id].flatMap { ids in ids.count == 1 ? standard[ids[0]] ?? ids[0] : nil }
            }
            var people: [UUID: Set<String>] = [:]
            for block in ordered {
                guard let person = namedPerson[block.id] ?? recognizedPerson[block.id], let id = group(block) else { continue }
                people[id, default: []].insert(person)
            }
            for block in ordered where block.track == .system && !echoes.contains(block.id) &&
                namedPerson[block.id] == nil && recognizedPerson[block.id] == nil {
                guard let id = group(block), let only = people[id], only.count == 1, let person = only.first,
                      let vectors = own(block), let best = recognition.ranked(for: vectors).first,
                      best.person == person, best.score >= ReplyRecognition.groupFloor else { continue }
                recognizedPerson[block.id] = person
            }
        }
        // Words each voice keeps once named and recognized replies went to
        // their people: a voice left with a word or two is brief too.
        var kept: [UUID: Int] = [:]
        for block in ordered where block.track == .system && !echoes.contains(block.id) && block.speakerCandidates.count == 1 &&
            namedPerson[block.id] == nil && recognizedPerson[block.id] == nil {
            kept[block.speakerCandidates[0], default: 0] += block.words.count
        }
        func brief(_ id: UUID) -> Bool {
            merged.brief.contains(id) || merged.timed && kept[id] ?? 0 < SpeakerConsolidation.briefVoiceWords
        }
        var recognizedBlocks = 0
        var segments: [TranscriptSegment] = []
        var unknownSpeakers: [UUID: UUID] = [:]
        for block in ordered where !echoes.contains(block.id) {
            let reference: SpeakerReference
            let person = namedPerson[block.id]
            let recognized = recognizedPerson[block.id]
            if block.track == .microphone { reference = .microphone }
            else if let person {
                reference = .system(daySpeakerID: try voice(of: person, day: block.day, recognized: false))
            } else if let recognized {
                recognizedBlocks += 1
                reference = .system(daySpeakerID: try voice(of: recognized, day: block.day, recognized: true))
            } else if block.speakerCandidates.count == 1, !brief(block.speakerCandidates[0]),
                    let candidate = candidates.first(where: { $0.id == block.speakerCandidates[0] }),
                    candidate.recordingDayIDs.contains(block.day.id) {
                reference = .system(daySpeakerID: try addSpeaker(candidate))
            } else {
                guard block.speakerCandidates.allSatisfy({ id in candidates.contains { $0.id == id && $0.recordingDayIDs.contains(block.day.id) } }) else {
                    throw StoreError.invalidResult
                }
                // One Unidentified speaker per day, not a new voice for every such block.
                let id: UUID
                if let existing = unknownSpeakers[block.day.id] { id = existing } else {
                    id = try addSpeaker(DaySpeaker(meetingID: recording.meetingID, dayID: block.day.id, number: 1, unidentified: true))
                    unknownSpeakers[block.day.id] = id
                }
                reference = .system(daySpeakerID: id)
                reviews.append(SpeakerReconciliationReview(id: UUID(), previousAssignmentIDs: [],
                    speakerIDs: [id], blockIDs: [block.id],
                    reason: block.speakerCandidates.count > 1 ? .mixedSpeech : .insufficientEvidence))
            }
            segments.append(TranscriptSegment(id: block.id, recordingID: recording.id, dayID: block.day.id,
                track: block.track, interval: block.interval, wallClockStart: block.words[0].wallClockStart,
                speaker: reference, originalText: block.originalText, correctedText: block.correctedText,
                alignmentModelRevision: models[.alignment]!.revision))
        }
        let referenced = Set(speakers.map(\.id))
        let linked = try linkedNames.compactMap { candidateID, name -> SpeakerAssignment? in
            guard let id = finalIDs[candidateID], let speaker = speakers.first(where: { $0.id == id }) else { return nil }
            // Evidence: the voice's replies in this revision.
            let intervals = segments.filter { $0.speaker == .system(daySpeakerID: id) }.map(\.interval)
            guard !intervals.isEmpty else { throw StoreError.invalidResult }
            return SpeakerAssignment(meetingID: recording.meetingID, dayID: speaker.dayID, daySpeakerID: id, name: name, origin: .linked,
                evidence: intervals.map { SpeechEvidence(recordingID: recording.id, interval: $0, embeddingFingerprint: nil) }, createdAt: date)
        }.sorted { $0.daySpeakerID.uuidString < $1.daySpeakerID.uuidString }
        let applied = assignments.filter { referenced.contains($0.daySpeakerID) } + linked
        let resolvedReviews = reviews.map { review in
            let ids = segments.filter { review.blockIDs.contains($0.id) }.compactMap { segment -> UUID? in
                guard case .system(let id) = segment.speaker else { return nil }; return id
            }
            return SpeakerReconciliationReview(id: review.id, previousAssignmentIDs: review.previousAssignmentIDs,
                speakerIDs: Set(ids).sorted { $0.uuidString < $1.uuidString }, blockIDs: review.blockIDs, reason: review.reason)
        }
        let publication = FinalTranscriptPublication(id: revisionID, job: checkpoint.job, previousRevisionID: previous?.id, reconciliationVersion: version,
            speakers: speakers, voiceEvidence: evidence, assignments: applied, reviews: resolvedReviews,
            mergeCalibration: calibration, replyRecognition: recognition?.measurement, recognizedReplies: recognizedBlocks)
        let revision = TranscriptRevision(id: revisionID, recordingID: recording.id, sourceGeneration: recording.generation,
            kind: .final, segments: segments, modelRevisions: checkpoint.job.models, createdAt: date)
        return ReconciledTranscript(revision: revision, publication: publication, linked: linked, recognized: recognizedBlocks)
    }

    private static func score(_ a: TranscriptVoiceEvidence, _ b: TranscriptVoiceEvidence) -> Double {
        guard [a, b].allSatisfy({ bank in
            (1...8).contains(bank.vectors.count) && bank.vectors.allSatisfy { vector in
                vector.count == 256 && vector.allSatisfy(\.isFinite) &&
                abs(sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) }) - 1) < 0.001
            }
        }) else { return -1 }
        return a.vectors.flatMap { left in b.vectors.map { right in
            let dot = zip(left, right).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            let norms = sqrt(left.reduce(0.0) { $0 + Double($1) * Double($1) }) *
                sqrt(right.reduce(0.0) { $0 + Double($1) * Double($1) })
            return min(1, max(-1, dot / norms))
        } }.min() ?? -1
    }
    private static func union(_ ranges: [MediaInterval]) -> [MediaInterval] {
        var result: [MediaInterval] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, range.start <= last.end {
                result[result.count - 1] = try! MediaInterval(start: last.start, end: max(last.end, range.end))
            } else { result.append(range) }
        }
        return result
    }
    private static func intersection(_ a: [MediaInterval], _ b: [MediaInterval]) -> [MediaInterval] {
        SpeakerIntervals.intersection(a, b)
    }
    private static func duration(_ ranges: [MediaInterval]) -> Double { ranges.reduce(0) { $0 + $1.duration.seconds } }
}

/// Without headphones the microphone also records the loudspeakers, so other
/// participants' speech would appear twice: once as theirs and once as `You`.
/// A microphone block is an echo when most of its words were also recognized
/// in system audio around the same time. The audio itself is kept unchanged.
enum MicrophoneEcho {
    /// Speaker playback and processing delay tolerated between the two tracks.
    static let tolerance: Int64 = 1_500_000
    /// Share of a microphone block's words that must also be heard from the system.
    static let shared = 0.5

    static func blocks(in blocks: [FinalTextBlock]) -> Set<UUID> {
        let system = blocks.filter { $0.track == .system }.flatMap { block in
            block.words.map { (block.recordingID, $0.active, IndexedSpellingCorrection.lexicalKey($0.text)) }
        }
        var echoes: Set<UUID> = []
        for block in blocks where block.track == .microphone {
            let start = block.interval.start.microseconds - tolerance, end = block.interval.end.microseconds + tolerance
            let heard = Set(system.filter { $0.0 == block.recordingID && $0.1.start.microseconds < end && $0.1.end.microseconds > start }.map(\.2))
            let words = block.words.map { IndexedSpellingCorrection.lexicalKey($0.text) }.filter { !$0.isEmpty }
            guard !words.isEmpty else { continue }
            if Double(words.filter(heard.contains).count) / Double(words.count) >= shared { echoes.insert(block.id) }
        }
        return echoes
    }
}

/// Applies the whole-recording voice merge to the staged blocks before names
/// are reconciled, so a renamed or previously published identity follows its
/// merged voice. Blocks without a single voice (too little clean speech, a
/// voice with no vector, or two voices) take the voice of the nearest block
/// within `reach` when that voice is among their candidates or they have none.
struct SpeakerConsolidation {
    /// 3 s left 24 fragment voices on a 16.7-minute call; 10 s attaches most of
    /// them while `apart` still keeps a separated neighbour's voice away.
    static let reach: Int64 = 10_000_000
    /// A voice with less segmented speech than this (all its clusters
    /// together) is too short to match: its replies are `Unidentified`. A
    /// two-person video gained voices of 0.6–0.7 s.
    static let briefVoiceSeconds = 3.0
    /// So is a voice left with fewer words than this once named and recognized
    /// replies went to their people: on the user's calls such voices showed a
    /// single "huh." or "what?" and the two-person video "Дорого стоил?".
    static let briefVoiceWords = 4

    /// Seconds of segmented speech per cluster, from the system windows.
    static func speech(_ windows: [FinalWindowCheckpoint]) -> [UUID: Double] {
        var result: [UUID: Double] = [:]
        for window in windows where window.track == .system {
            for speaker in window.speakers ?? [] { result[speaker.speakerID, default: 0] += speaker.active.duration.seconds }
        }
        return result
    }

    /// Speakers the segmentation told apart within one system window.
    static func apart(_ windows: [FinalWindowCheckpoint]) -> [UUID: Set<UUID>] {
        var result: [UUID: Set<UUID>] = [:]
        for window in windows where window.track == .system {
            let ids = Set((window.speakers ?? []).map(\.speakerID))
            for id in ids { result[id, default: []].formUnion(ids.subtracting([id])) }
        }
        return result
    }
    let speakers: [DaySpeaker]
    let evidence: [TranscriptVoiceEvidence]
    let blocks: [FinalTextBlock]
    /// Consolidated speaker → the person whose named speech it holds.
    let persons: [UUID: String]
    /// Consolidated speakers below `briefVoiceSeconds` of segmented speech.
    let brief: Set<UUID>
    /// Segmentation timings exist, so brief voices can be told.
    let timed: Bool

    init(clustering: SystemSpeakerClustering?, blocks input: [FinalTextBlock], windows: [FinalWindowCheckpoint] = [],
         named: [NamedSpeech] = [], learned: Double? = nil) {
        self.init(clustering: clustering, blocks: input, apart: Self.apart(windows), speech: Self.speech(windows),
                  links: SpeakerLinks.links(windows: windows, named: named), learned: learned)
    }

    init(clustering: SystemSpeakerClustering?, blocks input: [FinalTextBlock], apart: [UUID: Set<UUID>], speech: [UUID: Double] = [:],
         links: [UUID: String] = [:], learned: Double? = nil) {
        guard let clustering else { speakers = []; evidence = []; blocks = input; persons = [:]; brief = []; timed = false; return }
        let mapping = clustering.consolidation(apart: apart, speech: speech, links: links, learned: learned)
        let members = Dictionary(grouping: clustering.speakers.map(\.id), by: { mapping[$0] ?? $0 })
        self.persons = members.compactMapValues { SpeakerLinks.owner(of: $0, links: links, speech: speech) }
        func mapped(_ block: FinalTextBlock) -> [UUID] {
            var seen: [UUID] = []
            for id in block.speakerCandidates { let to = mapping[id] ?? id; if !seen.contains(to) { seen.append(to) } }
            return seen
        }
        // Without segmentation timings (fixtures) nothing counts as brief.
        timed = !speech.isEmpty
        let brief = speech.isEmpty ? [] : Set(members.filter { _, ids in
            ids.reduce(0) { $0 + (speech[$1] ?? 0) } < Self.briefVoiceSeconds
        }.keys)
        self.brief = brief
        let all = clustering.voiceEvidence
        // Merged-away clusters disappear; representatives and vectorless clusters remain.
        speakers = clustering.speakers.filter { mapping[$0.id] == nil || mapping[$0.id] == $0.id }
        evidence = speakers.map { speaker in
            let members = all.filter { (mapping[$0.speakerID] ?? $0.speakerID) == speaker.id }
                .sorted { $0.speakerID == speaker.id && $1.speakerID != speaker.id }
            return TranscriptVoiceEvidence(speakerID: speaker.id, segmentation: members[0].segmentation,
                embedding: members[0].embedding, vectors: Array(members.flatMap(\.vectors).prefix(8)))
        }
        func voiced(_ ids: [UUID]) -> [UUID] { ids.filter { mapping[$0] != nil } }
        // A brief voice is no evidence for its neighbours either.
        let decided = input.filter { $0.track == .system && mapped($0).count == 1 && voiced(mapped($0)).count == 1 &&
            !brief.contains(mapped($0)[0]) }
        blocks = input.map { block in
            guard block.track == .system else { return block }
            var ids = mapped(block)
            let voices = voiced(ids)
            if ids.count != 1 || voices.isEmpty {
                // A short reply has no clean voice vector; it must not take the
                // voice of a neighbour the segmentation heard as someone else.
                let others = block.speakerCandidates.reduce(into: Set<UUID>()) { $0.formUnion(apart[$1] ?? []) }
                let near = decided.filter { $0.id != block.id && $0.recordingID == block.recordingID && $0.day == block.day }
                    .map { other -> (Int64, UUID) in
                        let gap = max(other.interval.start.microseconds - block.interval.end.microseconds,
                                      block.interval.start.microseconds - other.interval.end.microseconds, 0)
                        return (gap, mapped(other)[0])
                    }
                    .filter { candidate in
                        candidate.0 <= Self.reach && (voices.isEmpty || voices.contains(candidate.1)) &&
                            !others.contains { (mapping[$0] ?? $0) == candidate.1 }
                    }
                    .min { $0.0 < $1.0 }
                if let near { ids = [near.1] }
            }
            return FinalTextBlock(id: block.id, recordingID: block.recordingID, day: block.day, track: block.track,
                words: block.words, interval: block.interval, speakerCandidates: ids,
                originalText: block.originalText, correctedText: block.correctedText)
        }
    }
}
