import Foundation
import TalkTrackDomain

/// A name the user gave draft speech (`live-draft-naming`): one draft row
/// (`reply`) or one live voice (`voice`, all of its single-voice rows). It is
/// speech the user named, in the recording's active media time, until final
/// publication turns the blocks it covers into fragment names.
public struct LiveName: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case reply, voice }
    public let id: UUID
    public let meetingID: UUID
    public let recordingID: UUID
    public let dayID: UUID
    public let kind: Kind
    /// The named draft row (reply names).
    public let utteranceID: UUID?
    /// The named live voice (voice names).
    public let liveSpeakerID: UUID?
    /// The row's interval when it was named; a newer revision of the row wins.
    public let intervals: [MediaInterval]
    public let name: String
    public let createdAt: Date

    /// The head scope: one current name per row and per live voice.
    var scope: String { Self.scope(recordingID: recordingID, kind: kind, target: utteranceID ?? liveSpeakerID ?? id) }
    static func scope(recordingID: UUID, kind: Kind, target: UUID) -> String { "\(recordingID):\(kind.rawValue):\(target)" }
}

/// What final publication did with a recording's draft names.
public struct DraftNamingSummary: Codable, Equatable, Sendable {
    /// Final replies named from the draft.
    public let namedReplies: Int
    /// Draft names that named no final reply.
    public let unplaced: [String]
    /// Names that named at least one reply, for Remember Voices….
    public let placed: [String]
}

public enum LiveDraftError: Error, Equatable, LocalizedError, Sendable {
    /// The recording already has its final transcript; name replies there.
    case finalized
    case unavailable
    public var errorDescription: String? {
        switch self {
        case .finalized: "This recording's final transcript is ready. Name the replies in the final transcript."
        case .unavailable: "This draft row is no longer available. Refresh the transcript and select it again."
        }
    }
}

extension SessionStore {
    // MARK: Draft (live revision)

    /// Saves the recording's draft as its live revision (one record per
    /// recording, replaced in place). Never changes the meeting generation, a
    /// final transcript or a job's source. A draft arriving after the final
    /// transcript, or an older draft after the complete one, is ignored.
    public func saveLiveDraft(_ draft: LiveDraft) throws {
        try db.transaction {
            _ = try meeting(draft.meetingID)
            guard let recording: Recording = try record(.recording, id: draft.recordingID),
                  recording.meetingID == draft.meetingID,
                  draft.utterances.allSatisfy({ $0.recordingID == draft.recordingID }) else { throw StoreError.invalidResult }
            if let final: TranscriptRevision = try head(.transcript, meetingID: draft.meetingID, scope: draft.recordingID.uuidString),
               final.kind == .final { return }
            if let current: LiveDraft = try record(.liveDraft, id: draft.recordingID), current.complete, !draft.complete { return }
            let stored = LiveDraft(id: draft.recordingID, meetingID: draft.meetingID, recordingID: draft.recordingID,
                                   utterances: draft.utterances, savedAt: draft.savedAt, complete: draft.complete)
            try put(.liveDraft, id: draft.recordingID, meetingID: draft.meetingID, scope: draft.recordingID.uuidString, value: stored)
            try setHead(.liveDraft, meetingID: draft.meetingID, scope: draft.recordingID.uuidString, id: draft.recordingID)
        }
    }

    /// Current drafts of the meeting: recordings without a final transcript.
    public func liveDrafts(meetingID: UUID) throws -> [LiveDraft] {
        _ = try meeting(meetingID)
        return try db.rows("SELECT r.payload FROM heads h JOIN records r ON r.kind=h.kind AND r.id=h.id WHERE h.meeting_id=? AND h.kind='liveDraft'",
            [.text(meetingID.uuidString)]).map {
                guard case .blob(let data) = $0[0] else { throw StoreError.invalidResult }
                return try DomainCodec.decode(LiveDraft.self, from: data)
            }.sorted { $0.recordingID.uuidString < $1.recordingID.uuidString }
    }

    // MARK: Draft names

    /// Current, not yet published draft names of the meeting.
    public func liveNames(meetingID: UUID) throws -> [LiveName] {
        _ = try meeting(meetingID)
        return try db.rows("SELECT r.payload FROM heads h JOIN records r ON r.kind=h.kind AND r.id=h.id WHERE h.meeting_id=? AND h.kind='liveName'",
            [.text(meetingID.uuidString)]).map {
                guard case .blob(let data) = $0[0] else { throw StoreError.invalidResult }
                return try DomainCodec.decode(LiveName.self, from: data)
            }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// Name This Reply… on a draft row. `utterance` is the row as shown, which
    /// may be newer than the saved draft while recording.
    @discardableResult
    public func nameDraftReply(meetingID: UUID, utterance: LiveUtterance, name: String, at date: Date = Date()) throws -> MeetingTranscriptSnapshot {
        try writeLiveName(meetingID: meetingID, utterance: utterance, kind: .reply, name: name, at: date)
    }

    /// Name Voice… on a single-voice draft row: the row's live voice, including its later rows.
    @discardableResult
    public func nameDraftVoice(meetingID: UUID, utterance: LiveUtterance, name: String, at date: Date = Date()) throws -> MeetingTranscriptSnapshot {
        try writeLiveName(meetingID: meetingID, utterance: utterance, kind: .voice, name: name, at: date)
    }

    private func writeLiveName(meetingID: UUID, utterance: LiveUtterance, kind: LiveName.Kind, name: String,
                               at date: Date) throws -> MeetingTranscriptSnapshot {
        let trimmed = try SpeakerRenameError.validatedName(name)
        guard utterance.track == .system else { throw SpeakerRenameError.microphone }
        return try db.transaction {
            var owner = try meeting(meetingID)
            try requireDraftRecording(meetingID: meetingID, recordingID: utterance.recordingID)
            let voice: UUID? = kind == .voice ? utterance.speakers.first?.id : nil
            guard kind == .reply || (utterance.speakers.count == 1 && voice != nil) else { throw LiveDraftError.unavailable }
            let value = LiveName(id: UUID(), meetingID: meetingID, recordingID: utterance.recordingID, dayID: utterance.day.id,
                                 kind: kind, utteranceID: kind == .reply ? utterance.id : nil, liveSpeakerID: voice,
                                 intervals: [utterance.interval], name: trimmed, createdAt: date)
            try put(.liveName, id: value.id, meetingID: meetingID, scope: utterance.recordingID.uuidString, value: value)
            try setHead(.liveName, meetingID: meetingID, scope: value.scope, id: value.id)
            owner.generation += 1; try update(owner)
            return try meetingTranscript(meetingID: meetingID)
        }
    }

    /// Removes the reply name of a draft row, or the name of a live voice.
    @discardableResult
    public func removeDraftName(meetingID: UUID, recordingID: UUID, kind: LiveName.Kind, target: UUID) throws -> MeetingTranscriptSnapshot {
        try db.transaction {
            var owner = try meeting(meetingID)
            let scope = LiveName.scope(recordingID: recordingID, kind: kind, target: target)
            guard try db.rows("SELECT 1 FROM heads WHERE meeting_id=? AND kind='liveName' AND scope=?",
                              [.text(meetingID.uuidString), .text(scope)]).first != nil else { throw SpeakerRenameError.changed }
            try db.execute("DELETE FROM heads WHERE meeting_id=? AND kind='liveName' AND scope=?", [.text(meetingID.uuidString), .text(scope)])
            owner.generation += 1; try update(owner)
            return try meetingTranscript(meetingID: meetingID)
        }
    }

    private func requireDraftRecording(meetingID: UUID, recordingID: UUID) throws {
        guard let recording: Recording = try record(.recording, id: recordingID), recording.meetingID == meetingID else {
            throw LiveDraftError.unavailable
        }
        if let final: TranscriptRevision = try head(.transcript, meetingID: meetingID, scope: recordingID.uuidString),
           final.kind == .final { throw LiveDraftError.finalized }
    }

    /// Speech named in drafts, by person and recording (design D3). A reply name
    /// takes its row; a voice name takes its live voice's single-voice rows that
    /// carry no reply name, less any speech another person's reply covers.
    func draftNamedSpeech(meetingID: UUID) throws -> [NamedSpeech] {
        let names = try liveNames(meetingID: meetingID)
        guard !names.isEmpty else { return [] }
        let drafts = Dictionary(try liveDrafts(meetingID: meetingID).map { ($0.recordingID, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [NamedSpeech] = []
        for recordingID in Set(names.map(\.recordingID)) {
            let own = names.filter { $0.recordingID == recordingID }
            let rows = drafts[recordingID]?.utterances ?? []
            let replies = own.filter { $0.kind == .reply }
            let repliedRows = Set(replies.compactMap(\.utteranceID))
            func replyIntervals(_ name: LiveName) -> [MediaInterval] {
                rows.first { $0.id == name.utteranceID }.map { [$0.interval] } ?? name.intervals
            }
            for reply in replies {
                result.append(NamedSpeech(name: reply.name, recordingID: recordingID, intervals: replyIntervals(reply)))
            }
            for voice in own where voice.kind == .voice {
                let person = NamedSpeech.person(voice.name)
                var intervals = rows.filter { $0.track == .system && $0.speakers.map(\.id) == [voice.liveSpeakerID]
                    && !repliedRows.contains($0.id) }.map(\.interval)
                // A row the session has not saved yet still counts.
                if intervals.isEmpty { intervals = voice.intervals }
                let others = replies.filter { NamedSpeech.person($0.name) != person }.flatMap(replyIntervals)
                intervals = SpeakerIntervals.subtract(intervals, removing: others)
                if !intervals.isEmpty { result.append(NamedSpeech(name: voice.name, recordingID: recordingID, intervals: intervals)) }
            }
        }
        return result
    }

    /// At final publication of `recordingID`: each final system block the
    /// user's named speech gives to a draft person becomes a fragment name,
    /// the draft names and the draft are retired, and what happened is
    /// returned for the publication. Runs inside the publication transaction.
    func consumeDraftNames(meetingID: UUID, recordingID: UUID, revision: TranscriptRevision,
                           named: [NamedSpeech], at date: Date) throws -> DraftNamingSummary? {
        let m = SQLValue.text(meetingID.uuidString)
        defer {
            try? db.execute("DELETE FROM heads WHERE meeting_id=? AND kind='liveDraft' AND scope=?", [m, .text(recordingID.uuidString)])
        }
        let draft = try draftNamedSpeech(meetingID: meetingID).filter { $0.recordingID == recordingID }
        let names = try liveNames(meetingID: meetingID).filter { $0.recordingID == recordingID }
        guard !names.isEmpty else { return nil }
        let persons = Dictionary(draft.map { ($0.person, $0.name) }, uniquingKeysWith: { first, _ in first })
        let existing = try fragmentAnchors(meetingID: meetingID)
        var placed: [String: Int] = [:]
        for segment in revision.segments where segment.track == .system {
            guard let person = SpeakerLinks.person(of: [segment.interval], recordingID: recordingID, named: named),
                  let name = persons[person], !existing.contains(where: { $0.covers(segment) }) else { continue }
            let anchor = FragmentAnchor(meetingID: meetingID, recordingID: recordingID, dayID: segment.dayID, segmentID: segment.id,
                                        interval: segment.interval, name: name, createdAt: date)
            try put(.fragmentAnchor, id: anchor.id, meetingID: meetingID, scope: segment.id.uuidString, value: anchor)
            try setHead(.fragmentAnchor, meetingID: meetingID, scope: segment.id.uuidString, id: anchor.id)
            placed[person, default: 0] += 1
        }
        for name in names {
            try db.execute("DELETE FROM heads WHERE meeting_id=? AND kind='liveName' AND scope=?", [m, .text(name.scope)])
        }
        // Each person once, under the name given last.
        var people: [String: String] = [:]
        for name in names { people[NamedSpeech.person(name.name)] = name.name }
        let order = people.keys.sorted()
        return DraftNamingSummary(namedReplies: placed.values.reduce(0, +),
                                  unplaced: order.filter { placed[$0] == nil }.map { people[$0]! },
                                  placed: order.filter { placed[$0] != nil }.map { people[$0]! })
    }
}

/// One draft row as the Transcript tab shows it: `[time]: <label> · Draft`.
public struct LiveDraftRow: Identifiable, Equatable, Sendable {
    public let utterance: LiveUtterance
    /// The reply name, else the live voice's name (single-voice rows), else
    /// `VoiceN`, `Voice1 / Voice2` or `You`.
    public let label: String
    public let timestamp: String
    /// The reply name on this row, which Remove Name… removes.
    public let replyName: String?
    /// The name of this row's live voice (single-voice rows).
    public let voiceName: String?
    public var id: UUID { utterance.id }
    public var isNamed: Bool { replyName != nil || voiceName != nil }
    /// Microphone rows stay `You`.
    public var canNameReply: Bool { utterance.track == .system }
    /// Only a row with exactly one live voice names that voice.
    public var canNameVoice: Bool { utterance.track == .system && utterance.speakers.count == 1 }
    public var voiceLabel: String? { canNameVoice ? "Voice\(utterance.speakers[0].number)" : nil }
    public var text: String { "[\(timestamp)]: \(label) · Draft - \(utterance.text)" }
}

public enum LiveDraftRows {
    public static func rows(drafts: [LiveDraft], names: [LiveName]) -> [LiveDraftRow] {
        drafts.flatMap { draft in rows(utterances: draft.utterances, names: names.filter { $0.recordingID == draft.recordingID }) }
    }

    /// Rows in capture order. A reply name wins over its voice's name.
    public static func rows(utterances: [LiveUtterance], names: [LiveName]) -> [LiveDraftRow] {
        let replies = Dictionary(names.filter { $0.kind == .reply }.compactMap { name in name.utteranceID.map { ($0, name.name) } },
                                 uniquingKeysWith: { _, last in last })
        let voices = Dictionary(names.filter { $0.kind == .voice }.compactMap { name in name.liveSpeakerID.map { ($0, name.name) } },
                                uniquingKeysWith: { _, last in last })
        return utterances.map { row in
            let reply = row.track == .system ? replies[row.id] : nil
            let voice = row.track == .system && row.speakers.count == 1 ? voices[row.speakers[0].id] : nil
            let time = (try? TranscriptFormatter.timestamp(row.wallClockStart, day: row.day)) ?? ""
            return LiveDraftRow(utterance: row, label: reply ?? voice ?? row.speakerLabel, timestamp: time,
                                replyName: reply, voiceName: voice)
        }
    }
}
