import Foundation

public enum ModelRole: String, Codable, CaseIterable, Sendable {
    case liveASR, finalASR, alignment, segmentation, embedding, summary, translation, spelling
}

public struct ModelSnapshot: Codable, Equatable, Sendable {
    public let role: ModelRole
    public let repository: String
    public let revision: String
    public let directory: RelativePath
    public let preprocessingVersion: String

    public init(role: ModelRole, repository: String, revision: String, directory: RelativePath, preprocessingVersion: String) {
        self.role = role
        self.repository = repository
        self.revision = revision
        self.directory = directory
        self.preprocessingVersion = preprocessingVersion
    }
}

public enum OutputLanguage: String, Codable, CaseIterable, Sendable { case english, russian }
public enum ContextLimit: Int, Codable, CaseIterable, Sendable {
    case automatic = 0
    case tokens4K = 4096, tokens8K = 8192, tokens16K = 16384
    case small = 32768, standard = 65536, large = 131072
    // Preserve historical immutable jobs; neither large budget is selectable.
    case legacy126K = 129024

    public static let defaultSelection: ContextLimit = .small
    public static let maximumSelectable: ContextLimit = .standard
    public static let allCases: [ContextLimit] = [.automatic, .tokens4K, .tokens8K, .tokens16K, .small, .standard]
    public static var manualOptions: [ContextLimit] { allCases.filter { $0 != .automatic } }
    public static func supports(tokenCount: Int) -> Bool { tokenCount > 0 && Self(rawValue: tokenCount) != nil }
    public var label: String { self == .automatic ? "Auto" : "\(rawValue / 1024)K" }
}
public enum SummaryType: String, Codable, CaseIterable, Sendable {
    case auto, oneToOne, customerDiscovery, hiringInterview, standup, weeklyReview
}

public struct ProcessingSettings: Codable, Equatable, Sendable {
    public var meetingLanguage: MeetingLanguage
    public var summaryLanguage: OutputLanguage
    public var translationLanguage: OutputLanguage
    public var contextLimit: ContextLimit
    public var summaryType: SummaryType
    public var templateVersion: String
    /// Final transcripts run the text model's spelling pass. Snapshots saved
    /// before this setting existed always ran it, so a missing value is true.
    public var spellingCorrection: Bool

    public init(meetingLanguage: MeetingLanguage = .auto, summaryLanguage: OutputLanguage = .english,
                translationLanguage: OutputLanguage = .russian, contextLimit: ContextLimit = .defaultSelection,
                summaryType: SummaryType = .auto, templateVersion: String = "3", spellingCorrection: Bool = true) {
        self.spellingCorrection = spellingCorrection
        self.meetingLanguage = meetingLanguage
        self.summaryLanguage = summaryLanguage
        self.translationLanguage = translationLanguage
        self.contextLimit = contextLimit
        self.summaryType = summaryType
        self.templateVersion = templateVersion
    }

    private enum CodingKeys: String, CodingKey {
        case meetingLanguage, summaryLanguage, translationLanguage, contextLimit, summaryType, templateVersion, spellingCorrection
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meetingLanguage = try c.decode(MeetingLanguage.self, forKey: .meetingLanguage)
        summaryLanguage = try c.decode(OutputLanguage.self, forKey: .summaryLanguage)
        translationLanguage = try c.decode(OutputLanguage.self, forKey: .translationLanguage)
        contextLimit = try c.decode(ContextLimit.self, forKey: .contextLimit)
        summaryType = try c.decode(SummaryType.self, forKey: .summaryType)
        templateVersion = try c.decode(String.self, forKey: .templateVersion)
        spellingCorrection = try c.decodeIfPresent(Bool.self, forKey: .spellingCorrection) ?? true
    }
}

public struct SourceSnapshot: Codable, Equatable, Sendable {
    public let meetingID: UUID
    public let meetingGeneration: UInt64
    public let cancellationGeneration: UInt64
    public let recordingGenerations: [UUID: UInt64]
    public let transcriptRevisionIDs: [UUID]
    public let notesRevisionID: UUID?

    public init(meetingID: UUID, meetingGeneration: UInt64, cancellationGeneration: UInt64,
                recordingGenerations: [UUID: UInt64], transcriptRevisionIDs: [UUID], notesRevisionID: UUID?) {
        self.meetingID = meetingID
        self.meetingGeneration = meetingGeneration
        self.cancellationGeneration = cancellationGeneration
        self.recordingGenerations = recordingGenerations
        self.transcriptRevisionIDs = transcriptRevisionIDs
        self.notesRevisionID = notesRevisionID
    }

    private enum CodingKeys: String, CodingKey {
        case meetingID, meetingGeneration, cancellationGeneration, recordingGenerations, transcriptRevisionIDs, notesRevisionID
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(meetingID, forKey: .meetingID)
        try c.encode(meetingGeneration, forKey: .meetingGeneration)
        try c.encode(cancellationGeneration, forKey: .cancellationGeneration)
        try c.encode(Dictionary(uniqueKeysWithValues: recordingGenerations.map { ($0.key.uuidString, $0.value) }), forKey: .recordingGenerations)
        try c.encode(transcriptRevisionIDs, forKey: .transcriptRevisionIDs)
        try c.encodeIfPresent(notesRevisionID, forKey: .notesRevisionID)
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var generations: [UUID: UInt64] = [:]
        for (key, value) in try c.decode([String: UInt64].self, forKey: .recordingGenerations) {
            guard let id = UUID(uuidString: key), generations[id] == nil else {
                throw DecodingError.dataCorruptedError(forKey: .recordingGenerations, in: c, debugDescription: "Invalid or duplicate recording ID")
            }
            generations[id] = value
        }
        try self.init(meetingID: c.decode(UUID.self, forKey: .meetingID),
            meetingGeneration: c.decode(UInt64.self, forKey: .meetingGeneration),
            cancellationGeneration: c.decode(UInt64.self, forKey: .cancellationGeneration),
            recordingGenerations: generations, transcriptRevisionIDs: c.decode([UUID].self, forKey: .transcriptRevisionIDs),
            notesRevisionID: c.decodeIfPresent(UUID.self, forKey: .notesRevisionID))
    }
}

public enum JobKind: String, Codable, Sendable { case finalTranscription, summary, translation }
public enum JobStage: String, Codable, Sendable {
    case queued, waitingForModels, decoding, transcribing, aligning, diarizing, correcting
    case generating, validating, publishing, completed, interrupted, failed, cancelled
}

public struct ProcessingJobSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: JobKind
    public let recordingID: UUID?
    public let source: SourceSnapshot
    public let settings: ProcessingSettings
    public let models: [ModelSnapshot]
    public let createdAt: Date

    public init(id: UUID = UUID(), kind: JobKind, recordingID: UUID? = nil, source: SourceSnapshot,
                settings: ProcessingSettings, models: [ModelSnapshot], createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.recordingID = recordingID
        self.source = source
        self.settings = settings
        self.models = models
        self.createdAt = createdAt
    }
}

public struct ProcessingJob: Codable, Equatable, Identifiable, Sendable {
    public let snapshot: ProcessingJobSnapshot
    public var stage: JobStage
    public var checkpoint: RelativePath?
    public var lastError: String?
    public var id: UUID { snapshot.id }

    public init(snapshot: ProcessingJobSnapshot, stage: JobStage = .queued, checkpoint: RelativePath? = nil, lastError: String? = nil) {
        self.snapshot = snapshot
        self.stage = stage
        self.checkpoint = checkpoint
        self.lastError = lastError
    }
}

public enum GeneratedOutputKind: String, Codable, Sendable { case summary, translation }

public struct TranslatedSegment: Codable, Equatable, Sendable {
    public let sourceSegmentID: UUID
    public let text: String

    public init(sourceSegmentID: UUID, text: String) {
        self.sourceSegmentID = sourceSegmentID
        self.text = text
    }
}

public struct GeneratedOutput: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: GeneratedOutputKind
    public let job: ProcessingJobSnapshot
    public let text: String
    public let translatedSegments: [TranslatedSegment]
    public let createdAt: Date

    public init(id: UUID = UUID(), kind: GeneratedOutputKind, job: ProcessingJobSnapshot,
                text: String, translatedSegments: [TranslatedSegment] = [], createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.job = job
        self.text = text
        self.translatedSegments = translatedSegments
        self.createdAt = createdAt
    }
}
