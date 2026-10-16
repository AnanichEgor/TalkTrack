import Foundation
import Security
import TalkTrackDomain

/// A user's own text model behind an OpenAI-compatible chat completions API
/// (OpenAI, OpenRouter, LM Studio, Ollama, vLLM…). A summary or translation
/// job that uses it saves the server address and model name in its snapshot;
/// the API key stays in the Keychain and never enters the library.
public struct TextServer: Equatable, Sendable {
    /// `ModelSnapshot.preprocessingVersion` of jobs that run on a text server.
    public static let protocolVersion = "openai-chat-1"

    /// The API base, such as `https://api.openai.com/v1`.
    public let baseURL: URL
    public let model: String

    public init(baseURL: URL, model: String) {
        self.baseURL = baseURL; self.model = model
    }

    /// Accepts the base or a full `…/chat/completions` address; http(s) only.
    public static func normalizedURL(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["/chat/completions", "/completions", "/models"] where value.lowercased().hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    public func snapshot(for role: ModelRole) throws -> ModelSnapshot {
        guard [.summary, .translation].contains(role) else { throw TextServerError.notConfigured }
        return ModelSnapshot(role: role, repository: baseURL.absoluteString, revision: model,
                             directory: try RelativePath("text-server"), preprocessingVersion: Self.protocolVersion)
    }

    /// The server a job was queued for, or nil for a local model.
    public init?(_ snapshot: ModelSnapshot) {
        guard snapshot.preprocessingVersion == Self.protocolVersion, let url = URL(string: snapshot.repository) else { return nil }
        self.init(baseURL: url, model: snapshot.revision)
    }

    public static func isServer(_ snapshot: ModelSnapshot) -> Bool { TextServer(snapshot) != nil }

    /// Names a server in messages without its path or credentials.
    public var displayHost: String {
        (baseURL.host ?? baseURL.absoluteString) + (baseURL.port.map { ":\($0)" } ?? "")
    }
}

public enum TextServerError: Error, Equatable, LocalizedError, Sendable {
    case notConfigured
    /// The saved key belongs to another server address than this job's.
    case keyForAnotherServer(String)
    case unauthorized(String)
    case server(String, Int, String)
    case unreachable(String, String)
    case unreadableResponse(String)
    case contextTooSmall(String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "The text server is not set up. Enter its address and model in Settings ▸ Text."
        case .keyForAnotherServer(let host):
            "This request was queued for \(host), but the saved API key belongs to another server. Generate it again to use the current server."
        case .unauthorized(let host):
            "\(host) refused the API key. Check the key in Settings ▸ Text."
        case .server(let host, let code, let message):
            "\(host) answered with status \(code)" + (message.isEmpty ? "." : ": \(message)")
        case .unreachable(let host, let message):
            "Could not reach \(host): \(message)"
        case .unreadableResponse(let host):
            "\(host) returned a response that is not an OpenAI-compatible chat completion."
        case .contextTooSmall(let host):
            "The request is larger than the model on \(host) accepts. TalkTrack plans server requests for a 128K-token context; choose a model on the server that supports it."
        case .keychain(let status):
            "The API key could not be read from or saved to the Keychain (\(status))."
        }
    }
}

/// Preferences of the text server; the key is in `TextServerKeychain`.
public enum TextServerPreferences {
    public static let urlKey = "textServerURL"
    public static let modelKey = "textServerModel"
    public static let summariesKey = "summariesUseTextServer"
    public static let translationsKey = "translationsUseTextServer"

    public static func server(in defaults: UserDefaults = .standard) -> TextServer? {
        guard let url = TextServer.normalizedURL(defaults.string(forKey: urlKey) ?? ""),
              let model = defaults.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
        return TextServer(baseURL: url, model: model)
    }

    /// Server models are planned with a 128K context (user decision); the
    /// context in Settings ▸ Text applies to the local model only.
    public static let context: ContextLimit = .large

    /// Settings for a new job of `role`: the server's context when it runs there.
    public static func settings(for role: ModelRole, in defaults: UserDefaults = .standard) -> ProcessingSettings {
        var settings = ProcessingPreferences.snapshot(from: defaults)
        if uses(role, in: defaults) { settings.contextLimit = context }
        return settings
    }

    public static func uses(_ role: ModelRole, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: role == .summary ? summariesKey : translationsKey)
    }

    /// The server's snapshot when `role` is set to use it; nil for the local model.
    /// Throws when it is chosen but incomplete, so nothing is queued for a missing server.
    public static func snapshot(for role: ModelRole, in defaults: UserDefaults = .standard) throws -> ModelSnapshot? {
        guard uses(role, in: defaults) else { return nil }
        guard let server = server(in: defaults) else { throw TextServerError.notConfigured }
        return try server.snapshot(for: role)
    }
}

/// One generic password: the key and the server address it was entered for.
/// A job only sends the key to that address, so a key never reaches a server
/// the user did not enter it for.
public struct TextServerKeychain: Sendable {
    struct Entry: Codable { let url: String; let key: String }
    public let service: String
    public init(service: String = "TalkTrack Text Server") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
    }

    /// The saved key and its server, or nil when none is saved.
    public func load() throws -> (url: URL, key: String)? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw TextServerError.keychain(status) }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data), let url = URL(string: entry.url) else { return nil }
        return (url, entry.key)
    }

    /// Saves `key` for `url`; an empty key removes the entry.
    public func save(key: String, for url: URL) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return try delete() }
        let data = try JSONEncoder().encode(Entry(url: url.absoluteString, key: key))
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw TextServerError.keychain(update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = service
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw TextServerError.keychain(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TextServerError.keychain(status) }
    }

    /// The key for `server`; nil when none is saved (local servers often need none).
    public func key(for server: TextServer) throws -> String? {
        guard let saved = try load() else { return nil }
        guard saved.url == server.baseURL else { throw TextServerError.keyForAnotherServer(server.displayHost) }
        return saved.key
    }
}

public struct TextServerReply: Equatable, Sendable {
    public let text: String
    /// `usage.completion_tokens`, when the server reports it.
    public let completionTokens: Int?
    /// True when the server stopped at `max_tokens` (`finish_reason: "length"`).
    public let truncated: Bool
}

/// Chat completions over HTTP. Only the request's instructions and source
/// text are sent; the key goes in the `Authorization` header.
public struct TextServerClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public let server: TextServer
    let key: String?
    let transport: Transport

    public init(server: TextServer, key: String?, transport: @escaping Transport = TextServerClient.urlSession) {
        self.server = server; self.key = key; self.transport = transport
    }

    public static let urlSession: Transport = { request in
        let configuration = URLSessionConfiguration.ephemeral
        // A long meeting can take minutes on a slow server; the response is not streamed.
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    /// Sends one system and one user message. Optional parameters the server
    /// rejects by name are dropped (newer OpenAI models take
    /// `max_completion_tokens` instead of `max_tokens` and only the default temperature).
    public func complete(system: String, prompt: String, maxTokens: Int, temperature: Double, seed: Int?) async throws -> TextServerReply {
        var body: [String: Any] = [
            "model": server.model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            "max_tokens": maxTokens, "temperature": temperature, "stream": false,
        ]
        if let seed { body["seed"] = seed }
        for _ in 0..<4 {
            do {
                let data = try await send(path: "chat/completions", body: body)
                return try Self.reply(data, host: server.displayHost)
            } catch TextServerError.server(_, 400, let message) where Self.rejected(message, in: body) != nil {
                let name = Self.rejected(message, in: body)!
                if name == "max_tokens" { body["max_completion_tokens"] = body["max_tokens"] }
                body[name] = nil
            }
        }
        throw TextServerError.unreadableResponse(server.displayHost)
    }

    /// Model identifiers from `GET /models`, sorted.
    public func models() async throws -> [String] {
        let data = try await send(path: "models", body: nil)
        struct List: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else {
            throw TextServerError.unreadableResponse(server.displayHost)
        }
        return list.data.map(\.id).sorted()
    }

    static func rejected(_ message: String, in body: [String: Any]) -> String? {
        let text = message.lowercased()
        return ["max_tokens", "temperature", "seed"].first { body[$0] != nil && text.contains($0) }
    }

    private func send(path: String, body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: server.baseURL.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TalkTrack", forHTTPHeaderField: "User-Agent")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let host = server.displayHost
        let data: Data, response: URLResponse
        do { (data, response) = try await transport(request) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch is CancellationError { throw CancellationError() }
        catch { throw TextServerError.unreachable(host, error.localizedDescription) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw TextServerError.unreadableResponse(host) }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.errorMessage(data)
            if [401, 403].contains(http.statusCode) { throw TextServerError.unauthorized(host) }
            let lower = message.lowercased()
            if http.statusCode == 400 || http.statusCode == 413,
               lower.contains("context") && (lower.contains("length") || lower.contains("window") || lower.contains("exceed")) || http.statusCode == 413 {
                throw TextServerError.contextTooSmall(host)
            }
            throw TextServerError.server(host, http.statusCode, message)
        }
        return data
    }

    /// `{"error": {"message": …}}` or `{"error": "…"}`, shortened.
    static func errorMessage(_ data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((object?["error"] as? [String: Any])?["message"] as? String) ?? (object?["error"] as? String)
            ?? (object?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
        let line = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }

    static func reply(_ data: Data, host: String) throws -> TextServerReply {
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            struct Usage: Decodable { let completion_tokens: Int? }
            let choices: [Choice]
            let usage: Usage?
        }
        guard let completion = try? JSONDecoder().decode(Completion.self, from: data), let choice = completion.choices.first else {
            throw TextServerError.unreadableResponse(host)
        }
        return TextServerReply(text: cleaned(choice.message.content ?? ""), completionTokens: completion.usage?.completion_tokens,
                               truncated: choice.finish_reason == "length")
    }

    /// Removes a reasoning block and one Markdown code fence around the whole answer.
    static func cleaned(_ text: String) -> String {
        var value = text
        if let end = value.range(of: "</think>"), value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<think>") {
            value = String(value[end.upperBound...])
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```"), value.hasSuffix("```"), value.count >= 6, let firstLine = value.firstIndex(of: "\n") {
            value = String(value[value.index(after: firstLine)..<value.index(value.endIndex, offsetBy: -3)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }
}

/// Sends a job to its text server when its snapshot names one, otherwise to
/// the local model. A server's tokenizer is unknown, so its token counts are
/// estimated generously (a token for every three UTF-8 bytes; real tokenizers
/// use more bytes per token in English and Russian), which keeps every
/// request within the job's context (128K for servers).
public struct RoutedTextInference: SummaryTextInference, TranslationTextInference {
    let local: any SummaryTextInference & TranslationTextInference
    let key: @Sendable (TextServer) throws -> String?
    let transport: TextServerClient.Transport

    public init(local: any SummaryTextInference & TranslationTextInference,
                key: @escaping @Sendable (TextServer) throws -> String? = { try TextServerKeychain().key(for: $0) },
                transport: @escaping TextServerClient.Transport = TextServerClient.urlSession) {
        self.local = local; self.key = key; self.transport = transport
    }

    /// Chat formatting overhead of one system and one user message.
    static let messageOverhead = 16

    public static func estimatedTokens(_ text: String) -> Int { (text.utf8.count + 2) / 3 + 1 }

    static func formatted(system: String, prompt: String) -> Int {
        estimatedTokens(system) + estimatedTokens(prompt) + messageOverhead
    }

    private func client(_ server: TextServer) throws -> TextServerClient {
        TextServerClient(server: server, key: try key(server), transport: transport)
    }

    /// The reply within the planned reserve; `generatedTokens` never claims the
    /// whole reserve unless the server stopped at it.
    private func run(_ server: TextServer, settings: ProcessingSettings, role: ModelRole, system: String, prompt: String,
                     outputTokens: Int?, temperature: Double, seed: Int?) async throws -> (String, TextContextPlan, Int) {
        let plan = try TextContextPlanner.resolve(selection: settings.contextLimit, role: role,
            inputTokens: Self.formatted(system: system, prompt: prompt), outputTokens: outputTokens)
        let reply = try await client(server).complete(system: system, prompt: prompt, maxTokens: plan.outputTokens,
                                                      temperature: temperature, seed: seed)
        let generated = reply.truncated ? plan.outputTokens
            : min(reply.completionTokens ?? Self.estimatedTokens(reply.text), plan.outputTokens - 1)
        return (reply.text, plan, generated)
    }

    // MARK: Summaries

    public func tokenCounts(_ model: ModelSnapshot, settings: ProcessingSettings, texts: [String]) async throws -> [Int] {
        guard TextServer(model) != nil else { return try await local.tokenCounts(model, settings: settings, texts: texts) }
        return texts.map(Self.estimatedTokens)
    }

    public func formattedTokenCount(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String) async throws -> Int {
        guard TextServer(model) != nil else {
            return try await local.formattedTokenCount(model, settings: settings, system: system, prompt: prompt)
        }
        return Self.formatted(system: system, prompt: prompt)
    }

    public func summaryText(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String,
                            outputTokens: Int?, attempt: Int) async throws -> SummaryTextResponse {
        guard let server = TextServer(model) else {
            return try await local.summaryText(model, settings: settings, system: system, prompt: prompt, outputTokens: outputTokens, attempt: attempt)
        }
        guard model.role == .summary else { throw SummaryGenerationError.invalidRequest }
        do {
            // The local summary sampling; another seed for each format retry.
            let (text, plan, generated) = try await run(server, settings: settings, role: .summary, system: system, prompt: prompt,
                outputTokens: outputTokens, temperature: 0.2, seed: 1 + max(0, attempt))
            return SummaryTextResponse(text: text, contextPlan: plan, generatedTokens: generated)
        } catch is TextContextPlanningError { throw SummaryGenerationError.budget }
    }

    // MARK: Translations

    public func translationTokenCount(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String) async throws -> Int {
        guard TextServer(model) != nil else {
            return try await local.translationTokenCount(model, settings: settings, system: system, prompt: prompt)
        }
        return Self.formatted(system: system, prompt: prompt)
    }

    public func translationText(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String,
                                outputTokens: Int) async throws -> TranslationTextResponse {
        guard let server = TextServer(model) else {
            return try await local.translationText(model, settings: settings, system: system, prompt: prompt, outputTokens: outputTokens)
        }
        guard model.role == .translation else { throw TranslationError.invalidRequest }
        let (text, plan, generated) = try await run(server, settings: settings, role: .translation, system: system, prompt: prompt,
            outputTokens: outputTokens, temperature: 0, seed: 1)
        return TranslationTextResponse(text: text, contextPlan: plan, generatedTokens: generated)
    }
}
