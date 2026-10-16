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

    @Test func translationsUseTheServerOnlyWhenChosen() throws {
        let defaults = try #require(UserDefaults(suiteName: "TextServerTests-\(UUID())"))
        defaults.set(ContextLimit.tokens8K.rawValue, forKey: ProcessingPreferences.contextKey)
        #expect(try TextServerPreferences.snapshot(for: .translation, in: defaults) == nil)
        defaults.set(true, forKey: TextServerPreferences.translationsKey)
        // Not used before Check Connection succeeded.
        #expect(try TextServerPreferences.snapshot(for: .translation, in: defaults) == nil)
        defaults.set(true, forKey: TextServerPreferences.verifiedKey)
        #expect(throws: TextServerError.notConfigured) { try TextServerPreferences.snapshot(for: .translation, in: defaults) }
        defaults.set("https://api.example.com/v1", forKey: TextServerPreferences.urlKey)
        defaults.set("test-model", forKey: TextServerPreferences.modelKey)
        #expect(try TextServerPreferences.snapshot(for: .translation, in: defaults).flatMap(TextServer.init) == Self.server)
        #expect(TextServerPreferences.settings(for: .translation, in: defaults).contextLimit == .unbounded)
        // Summaries choose their model in the Summary tab, not here.
        #expect(try TextServerPreferences.snapshot(for: .summary, in: defaults) == nil)
        #expect(SummaryModelOptions.settings(for: .local("text-qwen35-4b"), in: defaults).contextLimit == .tokens8K)
        #expect(SummaryModelOptions.settings(for: .server, in: defaults).contextLimit == .unbounded)
    }

    /// The server is the default once set up; otherwise the local model for this Mac's memory.
    @Test func summaryModelChoices() {
        let local = [(id: "text-qwen35-9b", title: "Qwen3.5 9B", installed: false), (id: "text-qwen35-4b", title: "Qwen3.5 4B", installed: true)]
        let withServer = SummaryModelOptions.make(server: Self.server, local: local, localDefault: "text-qwen35-4b")
        #expect(withServer.map(\.choice) == [.server, .local("text-qwen35-4b")])
        #expect(withServer[0].title == "test-model (api.example.com)")
        #expect(SummaryModelOptions.defaultChoice(server: Self.server, localDefault: "text-qwen35-4b") == .server)
        let localOnly = SummaryModelOptions.make(server: nil, local: local, localDefault: "text-qwen35-9b")
        #expect(localOnly.map(\.title) == ["Qwen3.5 9B (not downloaded)", "Qwen3.5 4B"])
        #expect(SummaryModelOptions.defaultChoice(server: nil, localDefault: "text-qwen35-9b") == .local("text-qwen35-9b"))
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

    @Test func reasoningIsTurnedOffWhenTheServerAsks() async throws {
        let server = Server([
            (400, #"{"error":{"message":"parameter.enable_thinking must be set to false for non-streaming calls","type":"invalid_request_error"}}"#),
            (200, Self.completion("OK")),
        ])
        let reply = try await TextServerClient(server: Self.server, key: "k", transport: server.transport)
            .complete(system: "S", prompt: "P", temperature: 0, seed: nil)
        #expect(reply.text == "OK" && server.body(0)["enable_thinking"] == nil && server.body(1)["enable_thinking"] as? Bool == false)
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
        #expect(response.text == "text" && response.generatedTokens == 0)
        #expect(response.contextPlan.contextTokens == Int.max && response.contextPlan.outputTokens == 4096)
        #expect(server.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        // No context or output limit is sent to a server.
        #expect(server.body(0)["max_tokens"] == nil && server.body(0)["max_completion_tokens"] == nil)
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

    /// The whole meeting goes in one unlimited request; a server that refuses it
    /// as too large gets the meeting again planned for 32K, and the summary is published.
    @Test func summaryJobFallsBackWhenTheServerContextIsTooSmall() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url)
        var settings = ProcessingSettings(); settings.contextLimit = TextServerPreferences.context
        let template = try #require(SummaryTemplates.template(settings.summaryType))
        let summary = template.sections.map { "## " + $0.title(settings.summaryLanguage) + "\nNone noted." }.joined(separator: "\n\n")
        let server = Server([(400, #"{"error":{"message":"This model's maximum context length is 4096 tokens"}}"#),
                             (200, Self.completion(summary))])
        let inference = RoutedTextInference(local: NoLocal(), key: { _ in nil }, transport: server.transport)
        let job = try await f.store.enqueueSummary(meetingID: f.meeting.id, recordingID: f.recording.id, settings: settings,
                                                   model: try Self.server.snapshot(for: .summary))
        try await SummaryJobPipeline(store: f.store, inference: inference).run(jobID: job.id)
        let output = try #require(try await f.output())
        #expect(output.job.settings.contextLimit == .unbounded && TextServer(output.job.models[0]) == Self.server)
        #expect(server.requests.count == 2 && server.body(1)["max_tokens"] == nil)
        #expect(try await f.store.isOutdated(output, settings: settings) == false)
        // Choosing a local model afterwards does not outdate the server's summary.
        #expect(try await f.store.isOutdated(output, settings: ProcessingSettings()) == false)
    }

    /// Use for summaries / translations need a successful check of the current
    /// fields; any edit turns them off until the next check.
    @MainActor @Test func serverIsUsedOnlyAfterACheckOfTheCurrentFields() async throws {
        let keychain = TextServerKeychain(service: "TalkTrack Text Server Tests \(UUID())")
        defer { try? keychain.delete() }
        let defaults = try #require(UserDefaults(suiteName: "TextServerTests-\(UUID())"))
        let server = Server([(200, #"{"data":[{"id":"test-model"}]}"#), (200, Self.completion("OK")),
                             (200, #"{"data":[{"id":"test-model"}]}"#), (200, Self.completion("OK"))])
        let settings = TextServerSettingsPresentation(defaults: defaults, keychain: keychain, transport: server.transport)
        settings.use(for: .summary, true)
        #expect(!settings.summaries && settings.enableHint?.contains("Enter the server URL") == true)
        settings.address = "https://api.example.com/v1"; settings.model = "test-model"; settings.key = "k"
        settings.use(for: .translation, true)
        #expect(!settings.translations && settings.summaryServer == nil)
        await settings.checkConnection()
        #expect(settings.verified && settings.enableHint == nil)
        settings.use(for: .summary, true); settings.use(for: .translation, true)
        #expect(settings.summaryServer == Self.server && TextServerPreferences.uses(.translation, in: defaults))
        // A new launch keeps the checked choices.
        let reopened = TextServerSettingsPresentation(defaults: defaults, keychain: keychain, transport: server.transport)
        reopened.loadKey()
        #expect(reopened.verified && reopened.summaries && reopened.translations && reopened.key == "k")
        // Editing any field turns both off.
        reopened.model = "other-model"
        #expect(!reopened.verified && !reopened.summaries && !reopened.translations && reopened.summaryServer == nil)
        #expect(!TextServerPreferences.uses(.translation, in: defaults))
        reopened.model = "test-model"
        await reopened.checkConnection()
        reopened.key = "changed"
        #expect(!reopened.verified)
    }
}
