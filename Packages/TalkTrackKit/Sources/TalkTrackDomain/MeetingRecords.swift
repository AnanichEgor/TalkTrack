import Foundation

public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var description: String
    public var language: MeetingLanguage
    public let createdAt: Date
    public var latestRecordingStartedAt: Date?
    public var generation: UInt64
    public var cancellationGeneration: UInt64
    public var deletedAt: Date?
    public var sortDate: Date { latestRecordingStartedAt ?? createdAt }

    public init(id: UUID = UUID(), draft: MeetingDraft, createdAt: Date = Date()) {
        self.id = id
        title = draft.title
        description = draft.description
        language = draft.language
        self.createdAt = createdAt
        generation = 0
        cancellationGeneration = 0
    }
}

public enum AudioTrack: String, Codable, CaseIterable, Sendable { case system, microphone }
public enum RecordingState: String, Codable, Sendable {
    case preparing, recording, paused, stopping, complete, interrupted
}

public struct CaptureInterval: Codable, Equatable, Sendable {
    public let active: MediaInterval
    public let wallClockStart: Date
    public let hostTimeStart: UInt64
    public let dayID: UUID

    public init(active: MediaInterval, wallClockStart: Date, hostTimeStart: UInt64, dayID: UUID) {
        self.active = active
        self.wallClockStart = wallClockStart
        self.hostTimeStart = hostTimeStart
        self.dayID = dayID
    }
}

public struct TrackChunk: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let track: AudioTrack
    public let file: RelativePath
    public let active: MediaInterval
    public let sampleRate: UInt32
    public let decodedFrameCount: UInt64
    public let leadingTrimFrames: UInt64
    public let trailingTrimFrames: UInt64
    public let hostTimeStart: UInt64

    public init(id: UUID = UUID(), track: AudioTrack, file: RelativePath, active: MediaInterval,
                sampleRate: UInt32, decodedFrameCount: UInt64, leadingTrimFrames: UInt64,
                trailingTrimFrames: UInt64, hostTimeStart: UInt64) throws {
        guard sampleRate > 0, leadingTrimFrames <= decodedFrameCount,
              trailingTrimFrames <= decodedFrameCount - leadingTrimFrames else {
            throw DomainError.invalidAudioFrames
        }
        self.id = id
        self.track = track
        self.file = file
        self.active = active
        self.sampleRate = sampleRate
        self.decodedFrameCount = decodedFrameCount
        self.leadingTrimFrames = leadingTrimFrames
        self.trailingTrimFrames = trailingTrimFrames
        self.hostTimeStart = hostTimeStart
    }

    private enum CodingKeys: String, CodingKey {
        case id, track, file, active, sampleRate, decodedFrameCount
        case leadingTrimFrames, trailingTrimFrames, hostTimeStart
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), track: c.decode(AudioTrack.self, forKey: .track),
            file: c.decode(RelativePath.self, forKey: .file), active: c.decode(MediaInterval.self, forKey: .active),
            sampleRate: c.decode(UInt32.self, forKey: .sampleRate),
            decodedFrameCount: c.decode(UInt64.self, forKey: .decodedFrameCount),
            leadingTrimFrames: c.decode(UInt64.self, forKey: .leadingTrimFrames),
            trailingTrimFrames: c.decode(UInt64.self, forKey: .trailingTrimFrames),
            hostTimeStart: c.decode(UInt64.self, forKey: .hostTimeStart))
    }
}

/// Missing audio is explicit and keeps its position on the active timeline.
public enum TrackIntervalContent: Codable, Equatable, Sendable {
    case chunk(id: UUID, firstDecodedFrame: UInt64, frameCount: UInt64)
    case gap(reason: String)
}

public struct TrackInterval: Codable, Equatable, Sendable {
    public let track: AudioTrack
    public let active: MediaInterval
    public let content: TrackIntervalContent

    public init(track: AudioTrack, active: MediaInterval, content: TrackIntervalContent) {
        self.track = track
        self.active = active
        self.content = content
    }
}

public struct Recording: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let startedAt: Date
    public let timeZoneIdentifier: String
    public var state: RecordingState
    public var endedAt: Date?
    public var activeDuration: MediaTime
    public var days: [RecordingDay]
    public var captureIntervals: [CaptureInterval]
    public var trackIntervals: [TrackInterval]
    public var chunks: [TrackChunk]
    public var generation: UInt64

    public init(id: UUID = UUID(), meetingID: UUID, startedAt: Date = Date(), timeZoneIdentifier: String) throws {
        self.id = id
        self.meetingID = meetingID
        self.startedAt = startedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        days = [try RecordingDay(capturedAt: startedAt, timeZoneIdentifier: timeZoneIdentifier)]
        state = .preparing
        activeDuration = .zero
        captureIntervals = []
        trackIntervals = []
        chunks = []
        generation = 0
    }
}

public struct NotesRevision: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let text: String
    /// Absent for plain-text notes written before the formatted editor.
    public let format: NotesFormat?
    public let createdAt: Date

    public init(id: UUID = UUID(), meetingID: UUID, text: String, format: NotesFormat? = nil, createdAt: Date = Date()) {
        self.id = id
        self.meetingID = meetingID
        self.text = text
        self.format = format
        self.createdAt = createdAt
    }

    public var document: NotesDocument { NotesDocument(text: text, format: format) }
}
