import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

@Suite struct TextServerTests {
    /// Records requests and answers each with the next canned response.
    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [(Int, String)]
        private(set) var requests: [URLRequest] = []
        init(_ responses: [(Int, String)]) { self.responses = responses }

        var transport: TextServerClient.Transport {
            { request in
                let (code, body) = self.next(request)
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
            }
        }
        private func next(_ request: URLRequest) -> (Int, String) {
            lock.withLock {
                requests.append(request)
                return responses.isEmpty ? (500, "{}") : responses.removeFirst()
            }
        }
        func body(_ index: Int) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data())) as? [String: Any] ?? [:]
        }
    }

    struct NoLocal: SummaryTextInference, TranslationTextInference {
        func tokenCounts(_ model: ModelSnapshot, settings: ProcessingSettings, texts: [String]) async throws -> [Int] { Issue.record("local"); return [] }
        func formattedTokenCount(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String) async throws -> Int { Issue.record("local"); return 0 }
        func summaryText(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String, outputTokens: Int?, attempt: Int) async throws -> SummaryTextResponse {
            Issue.record("local"); throw CancellationError()
        }
        func translationTokenCount(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String) async throws -> Int { Issue.record("local"); return 0 }
        func translationText(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String, outputTokens: Int) async throws -> TranslationTextResponse {
            Issue.record("local"); throw CancellationError()
        }
    }

    static func completion(_ content: String, finish: String = "stop", tokens: Int? = 12) -> String {
        let text = String(decoding: try! JSONEncoder().encode(content), as: UTF8.self)
        return #"{"choices":[{"message":{"role":"assistant","content":\#(text)},"finish_reason":"\#(finish)"}]"#
            + (tokens.map { #","usage":{"completion_tokens":\#($0)}}"# } ?? "}")
    }

    static let server = TextServer(baseURL: URL(string: "https://api.example.com/v1")!, model: "test-model")

    @Test func addressesAndSnapshots() throws {
        #expect(TextServer.normalizedURL(" https://api.openai.com/v1/ ")?.absoluteString == "https://api.openai.com/v1")
        #expect(TextServer.normalizedURL("http://localhost:1234/v1/chat/completions")?.absoluteString == "http://localhost:1234/v1")
        #expect(TextServer.normalizedURL("ftp://example.com") == nil && TextServer.normalizedURL("api.openai.com") == nil)
        let snapshot = try Self.server.snapshot(for: .summary)
        #expect(TextServer(snapshot) == Self.server && TextServer.isServer(snapshot))
        #expect(!snapshot.repository.contains("key"))
        #expect(throws: TextServerError.notConfigured) { try Self.server.snapshot(for: .finalASR) }
    }

    @Test func serverJobsUseA128KContextAndOnlyWhenChosen() throws {
        let defaults = try #require(UserDefaults(suiteName: "TextServerTests-\(UUID())"))
        defaults.set(ContextLimit.tokens8K.rawValue, forKey: ProcessingPreferences.contextKey)
        #expect(try TextServerPreferences.snapshot(for: .summary, in: defaults) == nil)
        #expect(TextServerPreferences.settings(for: .summary, in: defaults).contextLimit == .tokens8K)
        defaults.set(true, forKey: TextServerPreferences.summariesKey)
        #expect(throws: TextServerError.notConfigured) { try TextServerPreferences.snapshot(for: .summary, in: defaults) }
        defaults.set("https://api.example.com/v1", forKey: TextServerPreferences.urlKey)
        defaults.set("test-model", forKey: TextServerPreferences.modelKey)
        #expect(try TextServerPreferences.snapshot(for: .summary, in: defaults).flatMap(TextServer.init) == Self.server)
        #expect(TextServerPreferences.settings(for: .summary, in: defaults).contextLimit == .large)
        // Translations keep the local model and context until chosen separately.
        #expect(try TextServerPreferences.snapshot(for: .translation, in: defaults) == nil)
        #expect(TextServerPreferences.settings(for: .translation, in: defaults).contextLimit == .tokens8K)
    }

    @Test func requestShapeAndRejectedParameters() async throws {
        let server = Server([
            (400, #"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."}}"#),
            (400, #"{"error":{"message":"Unsupported value: 'temperature' does not support 0.2"}}"#),
            (200, Self.completion("<think>plan</think>\n```markdown\n## Summary\nDone.\n```")),
        ])
        let reply = try await TextServerClient(server: Self.server, key: "sk-test", transport: server.transport)
            .complete(system: "S", prompt: "P", maxTokens: 100, temperature: 0.2, seed: 2)
        #expect(reply == TextServerReply(text: "## Summary\nDone.", completionTokens: 12, truncated: false))
        #expect(server.requests.count == 3)
        #expect(server.requests[0].url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(server.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let first = server.body(0), last = server.body(2)
        #expect(first["model"] as? String == "test-model" && first["max_tokens"] as? Int == 100 && first["seed"] as? Int == 2)
        #expect((first["messages"] as? [[String: String]])?.map { $0["role"] } == ["system", "user"])
        #expect(last["max_tokens"] == nil && last["max_completion_tokens"] as? Int == 100 && last["temperature"] == nil)
    }

    @Test func errorsNameTheServer() async {
        for (code, body, expected) in [
            (401, #"{"error":{"message":"bad key"}}"#, TextServerError.unauthorized("api.example.com")),
            (400, #"{"error":{"message":"This model's maximum context length is 8192 tokens"}}"#, .contextTooSmall("api.example.com")),
            (500, #"{"error":"overloaded"}"#, .server("api.example.com", 500, "overloaded")),
            (200, "<html>", .unreadableResponse("api.example.com")),
        ] {
            let client = TextServerClient(server: Self.server, key: nil, transport: Server([(code, body)]).transport)
            await #expect(throws: expected) { try await client.complete(system: "S", prompt: "P", maxTokens: 8, temperature: 0, seed: nil) }
        }
    }

    @Test func summariesRunOnTheServerWithinThePlannedContext() async throws {
        let server = Server([(200, Self.completion("text")), (200, Self.completion("cut", finish: "length", tokens: nil))])
        let inference = RoutedTextInference(local: NoLocal(), key: { _ in nil }, transport: server.transport)
        let model = try Self.server.snapshot(for: .summary)
        var settings = ProcessingSettings(); settings.contextLimit = TextServerPreferences.context
        let count = try await inference.formattedTokenCount(model, settings: settings, system: "System", prompt: "Привет, мир")
        #expect(count == RoutedTextInference.estimatedTokens("System") + RoutedTextInference.estimatedTokens("Привет, мир") + 16)
        let response = try await inference.summaryText(model, settings: settings, system: "System", prompt: "Привет, мир", outputTokens: 4096, attempt: 1)
        #expect(response.text == "text" && response.generatedTokens == 12)
        #expect(response.contextPlan.contextTokens == 131072 && response.contextPlan.outputTokens == 4096)
        #expect(server.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(server.body(0)["seed"] as? Int == 2)
        // A reply stopped at max_tokens reports the whole reserve, which the summarizer treats as capped.
        let capped = try await inference.summaryText(model, settings: settings, system: "S", prompt: "P", outputTokens: 4096, attempt: 0)
        #expect(capped.generatedTokens == 4096)
    }

    @Test func translationThroughTheServerKeepsEveryRow() async throws {
        let segments = try (0..<3).map { index in
            TranscriptSegment(recordingID: UUID(), dayID: UUID(), track: .microphone,
                interval: try MediaInterval(start: .zero, end: MediaTime(seconds: 2)), wallClockStart: Date(),
                speaker: .microphone, originalText: "Hello number \(index)")
        }
        let json = #"{"translations":[{"id":"0","text":"Привет номер 0"},{"id":"1","text":"Привет номер 1"},{"id":"2","text":"Привет номер 2"}]}"#
        let server = Server([(200, Self.completion("```json\n" + json + "\n```"))])
        let inference = RoutedTextInference(local: NoLocal(), key: { _ in "k" }, transport: server.transport)
        var settings = ProcessingSettings(translationLanguage: .russian, templateVersion: IndexedTranslation.version)
        settings.contextLimit = TextServerPreferences.context
        let result = try await TranscriptTranslator(model: try Self.server.snapshot(for: .translation), settings: settings,
                                                    inference: inference).translate(segments)
        #expect(result.map(\.text) == ["Привет номер 0", "Привет номер 1", "Привет номер 2"])
        #expect(server.body(0)["temperature"] as? Double == 0)
    }
}
