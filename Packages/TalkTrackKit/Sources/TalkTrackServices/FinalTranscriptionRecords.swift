import Foundation
import TalkTrackDomain

public struct FinalASRText: Codable, Equatable, Sendable {
    public let text: String
    public let language: MeetingLanguage
    public init(text: String, language: MeetingLanguage) { self.text = text; self.language = language }
}

public struct FinalAlignmentItem: Sendable {
    public let text: String
    public let relative: MediaInterval
    public init(text: String, relative: MediaInterval) { self.text = text; self.relative = relative }
}

/// Original words only. Correction never assigns timestamps to new text.
public struct FinalAlignedWord: Codable, Equatable, Sendable {
    public let text: String
    public let active: MediaInterval
    public let wallClockStart: Date
}

public struct FinalTextBlock: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let recordingID: UUID
    public let day: RecordingDay
    public let track: AudioTrack
    public let words: [FinalAlignedWord]
    public let interval: MediaInterval
    public let speakerCandidates: [UUID]
    public let originalText: String
    public var correctedText: String?
    public var speakerLabel: String { track == .microphone ? "You" : "Unconfirmed system speaker" }
}

public struct IndexedCorrection: Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public init(id: UUID, text: String) { self.id = id; self.text = text }
}

public struct FinalCorrectionResponse: Codable, Sendable {
    public let text: String
    public let contextPlan: TextContextPlan
    public let generatedTokens: Int
    public init(text: String, contextPlan: TextContextPlan, generatedTokens: Int) {
        self.text = text; self.contextPlan = contextPlan; self.generatedTokens = generatedTokens
    }
}

public struct FinalCorrectionBatch: Codable, Equatable, Sendable {
    public let blockIDs: [UUID]
    public let contextPlan: TextContextPlan
    public let generatedTokens: Int
}

public protocol FinalTranscriptionInference: SystemSpeakerInference {
    /// Never downloads. Missing roles leave a durable waiting state.
    func unavailableFinalModels(_ models: [ModelSnapshot]) async throws -> [ModelRole]
    func finalText(_ model: ModelSnapshot, samples: [Float], language: MeetingLanguage) async throws -> FinalASRText
    func finalAlignment(_ model: ModelSnapshot, samples: [Float], text: String, language: MeetingLanguage) async throws -> [FinalAlignmentItem]
    func correctIndexed(_ model: ModelSnapshot, settings: ProcessingSettings, blocks: [IndexedCorrection]) async throws -> FinalCorrectionResponse
}

public enum FinalTranscriptionError: Error, Equatable, LocalizedError, Sendable {
    case invalidJob, busy, invalidCheckpoint, invalidAlignment, incompleteCoverage, invalidCorrection
    case missingModels([ModelRole]), correctionBudget, undetectedLanguage
    public var errorDescription: String? {
        switch self {
        case .invalidJob: "The final-transcription source or model snapshot is no longer valid. Create a new processing job."
        case .busy: "This final-transcription pipeline is already running."
        case .invalidCheckpoint: "The saved transcription checkpoint does not match this source. Keep the audio and start a new job."
        case .invalidAlignment: "Speech alignment did not cover the original words with valid source timing. Retry this recording."
        case .incompleteCoverage: "Final transcription did not cover every source interval. The previous transcript is preserved."
        case .invalidCorrection: "Spelling correction changed protected content or returned incomplete block IDs. The previous transcript is preserved."
        case .missingModels(let roles): "Download the required models before retrying: \(roles.map(\.rawValue).joined(separator: ", "))."
        case .correctionBudget: "A complete correction block cannot fit this context. Choose a larger context and start a new job."
        case .undetectedLanguage: "The speech language could not be detected as English or Russian. Set the meeting language, then transcribe the recording again."
        }
    }
}

public struct FinalWindowCheckpoint: Codable, Equatable, Sendable {
    public let id: UUID
    public let track: AudioTrack
    public let day: RecordingDay
    public let active: MediaInterval
    public let owned: MediaInterval
    public let wallClockStart: Date
    public let gapReason: String?
    public var asr: FinalASRText?
    public var words: [FinalAlignedWord]?
    public var speakers: [DiarizedSystemSegment]?
    public var blocks: [FinalTextBlock]?
    public var complete: Bool
    /// Microphone words the level gate removed (quieter than the system track).
    /// Nil in windows staged before the gate and on the system track.
    public var gatedWords: [FinalAlignedWord]? = nil
}

/// SQLite stores this staging artifact atomically with each job-stage change.
/// No PCM, absolute paths, or mutable application preferences enter it.
public struct FinalTranscriptionCheckpoint: Codable, Equatable, Sendable {
    public let version: Int
    public let correctionPromptVersion: String
    public let job: ProcessingJobSnapshot
    public let recordingFingerprint: String
    public var windows: [FinalWindowCheckpoint]
    public var completedTracks: [AudioTrack]
    public var speakerCheckpoint: Data?
    public var correctionBatches: [FinalCorrectionBatch]
    public var readyForPublication: Bool
    /// The system track's RMS per `MicrophoneGate.frame` of active time. Nil in
    /// checkpoints saved before the gate; their microphone is not gated.
    public var systemLevels: [Float]? = nil
    public var blocks: [FinalTextBlock] { windows.flatMap { $0.blocks ?? [] } }
}
