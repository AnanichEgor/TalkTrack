// Adapted from mlx-audio-swift, revision 01dec7c9bdce3088a6b6b7ab9f2e403458195efb.
// Copyright (c) 2025 Prince Canuma. MIT; see ThirdParty/MLXAudio-LICENSE.
import Foundation

enum ParakeetTokenizer {
    static func isSpecialToken(_ tokenId: Int, vocabulary: [String]) -> Bool {
        guard tokenId >= 0, tokenId < vocabulary.count else { return false }
        let piece = vocabulary[tokenId]
        return (piece.hasPrefix("<|") && piece.hasSuffix("|>"))
            || piece == "<unk>" || piece == "<pad>"
    }

    static func decode(tokens: [Int], vocabulary: [String]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(tokens.count)

        for token in tokens {
            guard token >= 0, token < vocabulary.count else { continue }
            if isSpecialToken(token, vocabulary: vocabulary) { continue }
            parts.append(vocabulary[token].replacingOccurrences(of: "▁", with: " "))
        }

        return parts.joined()
    }
}
