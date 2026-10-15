import Foundation

/// A service failure carries both a readable cause and the next recovery step.
public struct ServiceError: LocalizedError, Sendable {
    public let errorDescription: String?
    public let recoverySuggestion: String?

    public init(message: String, recovery: String) {
        errorDescription = message
        recoverySuggestion = recovery
    }
}
