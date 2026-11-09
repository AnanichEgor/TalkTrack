import Foundation
import MLX

/// One recognized word with the model's own timing, in seconds from the start
/// of the recognized window.
public struct ParakeetWord: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double
}

public struct ParakeetRecognition: Sendable {
    public let text: String
    public let words: [ParakeetWord]
}

extension ParakeetModel {
    /// Recognizes several chunk-sized windows in one batch and returns text with
    /// word timings. Tokens that start with a space begin a new word; punctuation
    /// stays with the word before it.
    public func recognize(audios: [MLXArray]) throws -> [ParakeetRecognition] {
        guard !audios.isEmpty else { throw STTError.invalidInput("Parakeet needs at least one window.") }
        let previousDecoder = tdtDecoderImplementation
        let previousEncoder = encoderExecutionImplementation
        if previousDecoder == nil { tdtDecoderImplementation = audios.count > 1 ? .hybrid : .serial }
        if previousEncoder == nil { encoderExecutionImplementation = .compiled }
        defer {
            tdtDecoderImplementation = previousDecoder
            encoderExecutionImplementation = previousEncoder
        }
        let batch = makeBatchFeatures(audios)
        return decode(mel: batch.features, lengths: batch.lengths).map { result in
            ParakeetRecognition(text: result.text, words: Self.words(from: result.sentences.flatMap(\.tokens)))
        }
    }

    static func words(from tokens: [ParakeetAlignedToken]) -> [ParakeetWord] {
        var words: [ParakeetWord] = []
        var text = "", start = 0.0, end = 0.0
        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { words.append(ParakeetWord(text: trimmed, start: start, end: max(start, end))) }
            text = ""
        }
        for token in tokens {
            let startsWord = token.text.hasPrefix(" ") || text.isEmpty
            if startsWord { flush(); start = token.start }
            text += token.text
            end = max(end, token.end)
        }
        flush()
        return words
    }
}
