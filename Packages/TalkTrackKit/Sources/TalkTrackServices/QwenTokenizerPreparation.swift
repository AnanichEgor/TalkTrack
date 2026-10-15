// Adapted from Blaizzy/mlx-audio-swift, revision 01dec7c9bdce3088a6b6b7ab9f2e403458195efb.
// MIT; see ThirdParty/MLXAudio-LICENSE and source provenance.
// TalkTrack: deterministic tokenizer construction with descriptor-confined IO.
import Foundation
import TalkTrackDomain

public enum QwenTokenizerPreparation {
    public static func prepare(in context: ModelPreparationContext) async throws {
        // Read vocab.json as raw JSON
        let vocabData = try await context.read(RelativePath("vocab.json"))
        _ = try JSONSerialization.jsonObject(with: vocabData)

        // Read merges.txt, skip header line
        let mergesData = try await context.read(RelativePath("merges.txt"))
        guard let mergesText = String(data: mergesData, encoding: .utf8) else { throw ModelDownloadError.incompletePreparation }
        let mergeLines = mergesText.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }

        // Build merges JSON array (legacy string format: "token1 token2")
        let mergesJSON = mergeLines.map { line -> String in
            let escaped = line
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: ",")

        // Read added_tokens_decoder from tokenizer_config.json
        var addedTokensJSON = "[]"
        do {
            let configData = try await context.read(RelativePath("tokenizer_config.json"))
            if let configDict = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
               let addedTokensDecoder = configDict["added_tokens_decoder"] as? [String: Any] {
                var tokens: [(Int, [String: Any])] = []
                for (idStr, value) in addedTokensDecoder {
                    if let id = Int(idStr), let tokenDict = value as? [String: Any] {
                        let entry: [String: Any] = [
                            "id": id,
                            "content": tokenDict["content"] ?? "",
                            "single_word": tokenDict["single_word"] ?? false,
                            "lstrip": tokenDict["lstrip"] ?? false,
                            "rstrip": tokenDict["rstrip"] ?? false,
                            "normalized": tokenDict["normalized"] ?? false,
                            "special": tokenDict["special"] ?? false,
                        ]
                        tokens.append((id, entry))
                    }
                }
                tokens.sort { $0.0 < $1.0 }
                let tokenData = try JSONSerialization.data(
                    withJSONObject: tokens.map { $0.1 }, options: [])
                addedTokensJSON = String(data: tokenData, encoding: .utf8) ?? "[]"
            }
        }

        // Qwen2 BPE pre-tokenizer pattern
        let preTokenizerPattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"

        // Escape for JSON embedding
        let escapedPattern = preTokenizerPattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let vocabString = String(data: vocabData, encoding: .utf8) ?? "{}"

        // Construct tokenizer.json
        let tokenizerJSON = """
        {
          "version": "1.0",
          "truncation": null,
          "padding": null,
          "added_tokens": \(addedTokensJSON),
          "normalizer": {"type": "NFC"},
          "pre_tokenizer": {
            "type": "Sequence",
            "pretokenizers": [
              {
                "type": "Split",
                "pattern": {"Regex": "\(escapedPattern)"},
                "behavior": "Isolated",
                "invert": false
              },
              {
                "type": "ByteLevel",
                "add_prefix_space": false,
                "trim_offsets": true,
                "use_regex": false
              }
            ]
          },
          "post_processor": null,
          "decoder": {
            "type": "ByteLevel",
            "add_prefix_space": true,
            "trim_offsets": true,
            "use_regex": true
          },
          "model": {
            "type": "BPE",
            "dropout": null,
            "unk_token": null,
            "continuing_subword_prefix": "",
            "end_of_word_suffix": "",
            "fuse_unk": false,
            "byte_fallback": false,
            "vocab": \(vocabString),
            "merges": [\(mergesJSON)]
          }
        }
        """

        let data = Data(tokenizerJSON.utf8)
        _ = try JSONSerialization.jsonObject(with: data)
        try await context.writeGenerated(RelativePath("tokenizer.json"), data: data)
    }

}
