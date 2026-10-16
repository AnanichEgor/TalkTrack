import Foundation
import Observation
import TalkTrackDomain

/// Settings ▸ Models ▸ Text Server. The address, model and choices are
/// preferences; the key is saved to the Keychain with the address it was
/// entered for. Use for summaries / translations can be turned on only after
/// Check Connection succeeded with every field as it is now; changing the
/// address, key or model turns both off until the connection is checked again.
/// With summaries on, the server is offered (and preselected) beside Generate
/// Summaries. Changes apply to work queued afterwards.
@MainActor @Observable public final class TextServerSettingsPresentation {
    public enum Check: Equatable {
        case idle, checking
        case succeeded(String)
        case failed(String)
    }

    public var address: String { didSet { if address != oldValue { defaults.set(address, forKey: TextServerPreferences.urlKey); edited() } } }
    public var model: String { didSet { if model != oldValue { defaults.set(model, forKey: TextServerPreferences.modelKey); edited() } } }
    public var key: String { didSet { if key != oldValue, !loadingKey { edited() } } }
    public private(set) var summaries: Bool { didSet { defaults.set(summaries, forKey: TextServerPreferences.summariesKey) } }
    public private(set) var translations: Bool { didSet { defaults.set(translations, forKey: TextServerPreferences.translationsKey) } }

    /// Turns the server on for summaries or translations; on only after a successful check.
    public func use(for role: ModelRole, _ on: Bool) {
        let value = on && verified
        if role == .summary { summaries = value } else if role == .translation { translations = value }
    }

    /// Check Connection succeeded for the current address, key and model.
    public private(set) var verified: Bool { didSet { defaults.set(verified, forKey: TextServerPreferences.verifiedKey) } }
    public private(set) var check: Check = .idle
    /// Filled by Check Connection from the server's model list.
    public private(set) var availableModels: [String] = []
    public private(set) var keyError: String?

    private let defaults: UserDefaults
    private let keychain: TextServerKeychain
    private let transport: TextServerClient.Transport
    private var pendingSave: Task<Void, Never>?
    private var loadingKey = false

    public init(defaults: UserDefaults = .standard, keychain: TextServerKeychain = TextServerKeychain(),
                transport: @escaping TextServerClient.Transport = TextServerClient.urlSession) {
        self.defaults = defaults; self.keychain = keychain; self.transport = transport
        address = defaults.string(forKey: TextServerPreferences.urlKey) ?? ""
        model = defaults.string(forKey: TextServerPreferences.modelKey) ?? ""
        let verified = defaults.bool(forKey: TextServerPreferences.verifiedKey)
        self.verified = verified
        summaries = verified && defaults.bool(forKey: TextServerPreferences.summariesKey)
        translations = verified && defaults.bool(forKey: TextServerPreferences.translationsKey)
        key = ""
    }

    /// Reads the saved key when Settings opens (macOS may ask for Keychain access).
    public func loadKey() {
        loadingKey = true; defer { loadingKey = false }
        do { key = try keychain.load()?.key ?? ""; pendingSave?.cancel(); keyError = nil }
        catch { keyError = error.localizedDescription }
    }

    /// Any change needs a new Check Connection before the server is used.
    private func edited() {
        verified = false; summaries = false; translations = false
        if check != .checking { check = .idle }
        saveKeyLater()
    }

    /// The server as entered.
    public var server: TextServer? {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = TextServer.normalizedURL(address), !name.isEmpty else { return nil }
        return TextServer(baseURL: url, model: name)
    }

    /// The server offered beside Generate Summaries: checked and turned on for summaries.
    public var summaryServer: TextServer? { summaries && verified ? server : nil }

    /// Shown under the fields when the address cannot be used.
    public var addressProblem: String? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return TextServer.normalizedURL(text) == nil ? "Enter an http:// or https:// address, such as https://api.openai.com/v1." : nil
    }

    /// Why Use for summaries / translations cannot be turned on yet.
    public var enableHint: String? {
        if verified { return nil }
        if server == nil { return "Enter the server URL and model, then check the connection to use the server." }
        return "Check the connection to use the server for summaries or translations."
    }

    private func saveKeyLater() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveKey()
        }
    }

    /// The key is bound to the current address; without a valid address it is not saved.
    public func saveKey() {
        pendingSave?.cancel(); pendingSave = nil
        do {
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try keychain.delete() }
            else if let url = TextServer.normalizedURL(address) { try keychain.save(key: key, for: url) }
            keyError = nil
        } catch { keyError = error.localizedDescription }
    }

    /// Lists the server's models, then sends a short request to the chosen one.
    public func checkConnection() async {
        saveKey()
        guard let url = TextServer.normalizedURL(address) else { check = .failed(TextServerError.notConfigured.localizedDescription); return }
        check = .checking
        let checkedAddress = address, checkedModel = model, checkedKey = key
        let chosen = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = TextServerClient(server: TextServer(baseURL: url, model: chosen), key: key, transport: transport)
        let listed = try? await client.models()
        availableModels = listed ?? []
        guard !chosen.isEmpty else {
            check = listed.map { .succeeded("Connected. \($0.count) model(s) available; choose one.") }
                ?? .failed("Could not list the server's models. Enter the model name.")
            return
        }
        do {
            _ = try await client.complete(system: "Reply with the single word OK.", prompt: "OK?", maxTokens: 16, temperature: 0, seed: nil)
            // Fields edited while checking need another check.
            guard address == checkedAddress, model == checkedModel, key == checkedKey else { check = .idle; return }
            check = .succeeded("Connected to \(chosen).")
            verified = true
        } catch {
            check = .failed(error.localizedDescription)
        }
    }
}
