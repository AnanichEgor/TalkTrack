import Foundation

public enum SpeakerReference: Codable, Equatable, Sendable {
    case microphone
    case system(daySpeakerID: UUID)
}

public struct SpeechEvidence: Codable, Equatable, Sendable {
    public let recordingID: UUID
    public let interval: MediaInterval
    public let embeddingFingerprint: String?

    public init(recordingID: UUID, interval: MediaInterval, embeddingFingerprint: String? = nil) {
        self.recordingID = recordingID
        self.interval = interval
        self.embeddingFingerprint = embeddingFingerprint
    }
}

public enum SpeakerAssignmentOrigin: Codable, Equatable, Sendable {
    case unknown
    case manual
    case automatic(profileID: UUID, profileRevision: UUID, similarity: Double, margin: Double, calibrationVersion: String)
    /// The voice holds speech the user named this person (a named voice or
    /// fragment) and no one else's; derived, so never confirmation evidence.
    case linked
}

/// A name the user gave one system speech block, independent of its voice
/// (`Name This Fragment…`). The interval keeps it valid when the recording is
/// transcribed again and its blocks change.
public struct FragmentAnchor: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let recordingID: UUID
    public let dayID: UUID
    /// The named block when it was named; the head scope.
    public let segmentID: UUID
    public let interval: MediaInterval
    public let name: String
    public let createdAt: Date

    public init(id: UUID = UUID(), meetingID: UUID, recordingID: UUID, dayID: UUID, segmentID: UUID,
                interval: MediaInterval, name: String, createdAt: Date = Date()) {
        self.id = id; self.meetingID = meetingID; self.recordingID = recordingID; self.dayID = dayID
        self.segmentID = segmentID; self.interval = interval; self.name = name; self.createdAt = createdAt
    }

    /// Whether `segment` is this fragment's speech: same recording, and the
    /// fragment covers more than half of the segment.
    public func covers(_ segment: TranscriptSegment) -> Bool {
        guard segment.recordingID == recordingID, segment.track == .system, segment.interval.duration > .zero else { return false }
        let start = max(segment.interval.start, interval.start), end = min(segment.interval.end, interval.end)
        guard end > start else { return false }
        return (end.microseconds - start.microseconds) * 2 > segment.interval.duration.microseconds
    }
}

public struct SpeakerAssignment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let dayID: UUID
    public let daySpeakerID: UUID
    public let name: String?
    public let origin: SpeakerAssignmentOrigin
    public let evidence: [SpeechEvidence]
    public let createdAt: Date

    public init(id: UUID = UUID(), meetingID: UUID, dayID: UUID, daySpeakerID: UUID,
                name: String?, origin: SpeakerAssignmentOrigin, evidence: [SpeechEvidence], createdAt: Date = Date()) {
        self.id = id
        self.meetingID = meetingID
        self.dayID = dayID
        self.daySpeakerID = daySpeakerID
        self.name = name
        self.origin = origin
        self.evidence = evidence
        self.createdAt = createdAt
    }
}

public struct DaySpeaker: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let dayID: UUID
    public let number: UInt
    /// Capture-time day UUIDs may differ between recordings of the same day.
    /// dayID remains the canonical identity scope; aliases retain provenance.
    public let recordingDayIDs: [UUID]

    public init(id: UUID = UUID(), meetingID: UUID, dayID: UUID, number: UInt, recordingDayIDs: [UUID]? = nil) {
        self.id = id
        self.meetingID = meetingID
        self.dayID = dayID
        self.number = number
        self.recordingDayIDs = Set((recordingDayIDs ?? []) + [dayID]).sorted { $0.uuidString < $1.uuidString }
    }

    private enum CodingKeys: String, CodingKey { case id, meetingID, dayID, number, recordingDayIDs }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), meetingID: c.decode(UUID.self, forKey: .meetingID),
            dayID: c.decode(UUID.self, forKey: .dayID), number: c.decode(UInt.self, forKey: .number),
            recordingDayIDs: c.decodeIfPresent([UUID].self, forKey: .recordingDayIDs))
    }
}

public struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let recordingID: UUID
    public let dayID: UUID
    public let track: AudioTrack
    public let interval: MediaInterval
    public let wallClockStart: Date
    public let speaker: SpeakerReference
    public let originalText: String
    public let correctedText: String?
    public let alignmentModelRevision: String?

    public init(id: UUID = UUID(), recordingID: UUID, dayID: UUID, track: AudioTrack,
                interval: MediaInterval, wallClockStart: Date, speaker: SpeakerReference,
                originalText: String, correctedText: String? = nil, alignmentModelRevision: String? = nil) {
        self.id = id
        self.recordingID = recordingID
        self.dayID = dayID
        self.track = track
        self.interval = interval
        self.wallClockStart = wallClockStart
        self.speaker = track == .microphone ? .microphone : speaker
        self.originalText = originalText
        self.correctedText = correctedText
        self.alignmentModelRevision = alignmentModelRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id, recordingID, dayID, track, interval, wallClockStart, speaker
        case originalText, correctedText, alignmentModelRevision
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id),
            recordingID: c.decode(UUID.self, forKey: .recordingID), dayID: c.decode(UUID.self, forKey: .dayID),
            track: c.decode(AudioTrack.self, forKey: .track), interval: c.decode(MediaInterval.self, forKey: .interval),
            wallClockStart: c.decode(Date.self, forKey: .wallClockStart),
            speaker: c.decode(SpeakerReference.self, forKey: .speaker),
            originalText: c.decode(String.self, forKey: .originalText),
            correctedText: c.decodeIfPresent(String.self, forKey: .correctedText),
            alignmentModelRevision: c.decodeIfPresent(String.self, forKey: .alignmentModelRevision))
    }
}

public enum TranscriptKind: String, Codable, Sendable { case live, final }

public struct TranscriptRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let recordingID: UUID
    public let sourceGeneration: UInt64
    public let kind: TranscriptKind
    public let segments: [TranscriptSegment]
    public let modelRevisions: [ModelSnapshot]
    public let createdAt: Date

    public init(id: UUID = UUID(), recordingID: UUID, sourceGeneration: UInt64,
                kind: TranscriptKind, segments: [TranscriptSegment], modelRevisions: [ModelSnapshot], createdAt: Date = Date()) {
        self.id = id
        self.recordingID = recordingID
        self.sourceGeneration = sourceGeneration
        self.kind = kind
        self.segments = segments
        self.modelRevisions = modelRevisions
        self.createdAt = createdAt
    }
}
