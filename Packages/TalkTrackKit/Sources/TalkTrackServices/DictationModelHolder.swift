import Foundation

/// Keeps at most one dictation recognition model loaded between dictations.
/// Loading happens under the dictation's interactive lease; unloading happens
/// after the idle period, when a meeting starts, when the model is removed or
/// when dictation is turned off, but never while a dictation uses the model.
public actor DictationModelHolder<Model: Sendable> {
    public typealias Load = @Sendable (String) async throws -> Model
    public typealias Unload = @Sendable (Model) async -> Void

    private let load: Load
    private let unload: Unload
    private var loaded: (key: String, model: Model)?
    private var users = 0
    private var generation = 0

    public init(load: @escaping Load, unload: @escaping Unload) {
        self.load = load
        self.unload = unload
    }

    public var loadedKey: String? { loaded?.key }

    /// Runs `operation` on the model for `key`, loading it (and unloading a
    /// different one) first when needed. The model cannot be unloaded meanwhile.
    public func use<T: Sendable>(_ key: String, _ operation: @Sendable (Model) async throws -> T) async throws -> T {
        users += 1
        defer { users -= 1; generation += 1 }
        let model: Model
        if let loaded, loaded.key == key { model = loaded.model }
        else {
            if let previous = loaded {
                self.loaded = nil
                await unload(previous.model)
            }
            model = try await load(key)
            loaded = (key, model)
        }
        return try await operation(model)
    }

    /// The token an idle unload must still match; any later use invalidates it.
    public func touch() -> Int {
        generation += 1
        return generation
    }

    public func unloadIfIdle(since token: Int) async {
        guard token == generation else { return }
        await unloadAll()
    }

    /// Unloads now unless a dictation is using the model.
    public func unloadAll() async {
        guard users == 0, let current = loaded else { return }
        loaded = nil
        generation += 1
        await unload(current.model)
    }
}
