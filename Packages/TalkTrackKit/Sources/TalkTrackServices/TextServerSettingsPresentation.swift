import Foundation
import Observation
import TalkTrackDomain

/// Settings ▸ Models ▸ Text Server. The address, model and choices are
/// preferences; the key is saved to the Keychain with the address it was
/// entered for. Changes apply to summaries and translations queued afterwards.
@MainActor @Observable public final class TextServerSettingsPresentation {
    public enum Check: Equatable {
        case idle, checking
        case succeeded(String)
        case failed(String)
    }

    public var address: String { didSet { defaults.set(address, forKey: TextServerPreferences.urlKey); saveKeyLater() } }
    public var model: String { didSet { defaults.set(model, forKey: TextServerPreferences.modelKey) } }
    public var key: String { didSet { saveKeyLater() } }
    public var summaries: Bool { didSet { defaults.set(summaries, forKey: TextServerPreferences.summariesKey) } }
    public var translations: Bool { didSet { defaults.set(translations, forKey: TextServerPreferences.translationsKey) } }
    public private(set) var check: Check = .idle
    /// Filled by Check Connection from the server's model list.
    public private(set) var availableModels: [String] = []
    public private(set) var keyError: String?

    private let defaults: UserDefaults
    private let keychain: TextServerKeychain
    private let transport: TextServerClient.Transport
    private var pendingSave: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard, keychain: TextServerKeychain = TextServerKeychain(),
                transport: @escaping TextServerClient.Transport = TextServerClient.urlSession) {
        self.defaults = defaults; self.keychain = keychain; self.transport = transport
        address = defaults.string(forKey: TextServerPreferences.urlKey) ?? ""
        model = defaults.string(forKey: TextServerPreferences.modelKey) ?? ""
        summaries = defaults.bool(forKey: TextServerPreferences.summariesKey)
        translations = defaults.bool(forKey: TextServerPreferences.translationsKey)
        key = ""
    }

    /// Reads the saved key when Settings opens (macOS may ask for Keychain access).
    public func loadKey() {
        do { key = try keychain.load()?.key ?? ""; pendingSave?.cancel(); keyError = nil }
        catch { keyError = error.localizedDescription }
    }

    public var server: TextServer? { TextServerPreferences.server(in: defaults) }

    /// Shown under the fields when the address cannot be used.
    public var addressProblem: String? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return TextServer.normalizedURL(text) == nil ? "Enter an http:// or https:// address, such as https://api.openai.com/v1." : nil
    }

    /// True when a task is set to use the server but it is incomplete.
    public var incomplete: Bool { (summaries || translations) && server == nil }

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
            check = .succeeded("Connected to \(chosen).")
        } catch {
            check = .failed(error.localizedDescription)
        }
    }
}
