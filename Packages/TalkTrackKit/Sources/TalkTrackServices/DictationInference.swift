import Foundation
import TalkTrackDomain

public struct DictationRecognition: Sendable, Equatable {
    public var text: String
    /// The language the model recognized, such as "English" or "Russian".
    public var language: String?

    public init(text: String, language: String?) {
        self.text = text
        self.language = language
    }
}

/// The application runtime's dictation entry points. Every call except
/// `isInstalled` and `unloadDictation` runs under the dictation's interactive
/// lease, which preempts background work and is refused during a meeting.
public protocol DictationInference: Sendable {
    func isInstalled(dictationModel id: String) async -> Bool
    /// Throws `InferenceSchedulingError.captureActive` while a meeting records.
    func beginInteractive() async throws -> InferenceScheduler.InteractiveLease
    /// Loads the model while the user speaks.
    func prepareDictation(modelID: String, lease: InferenceScheduler.InteractiveLease) async throws
    func dictate(modelID: String, samples: [Float], language: MeetingLanguage, context: String,
                 lease: InferenceScheduler.InteractiveLease) async throws -> DictationRecognition
    /// Ends the lease and starts the idle countdown that unloads the model.
    func endInteractive(_ lease: InferenceScheduler.InteractiveLease, idleMinutes: Int) async
    func unloadDictation() async
}

/// Splits long dictation audio for recognition at the quietest moment near
/// each boundary, so one model call stays within its token limit.
public enum DictationAudio {
    public static let sampleRate = 16_000
    public static let pieceSeconds = 60
    /// The boundary is searched in the last part of each piece.
    static let searchSeconds = 10
    static let frame = 1_600

    public static func pieces(_ samples: [Float]) -> [ArraySlice<Float>] {
        let limit = pieceSeconds * sampleRate
        var pieces: [ArraySlice<Float>] = []
        var start = 0
        while samples.count - start > limit {
            let searchStart = start + limit - searchSeconds * sampleRate
            var best = start + limit, quietest = Float.infinity
            var position = searchStart
            while position + frame <= start + limit {
                var energy: Float = 0
                for index in position..<(position + frame) { energy += samples[index] * samples[index] }
                if energy < quietest { quietest = energy; best = position + frame / 2 }
                position += frame
            }
            pieces.append(samples[start..<best])
            start = best
        }
        pieces.append(samples[start...])
        return pieces
    }
}
