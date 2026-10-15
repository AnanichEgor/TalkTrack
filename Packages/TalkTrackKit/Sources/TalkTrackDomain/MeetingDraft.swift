import Foundation

public enum MeetingLanguage: String, CaseIterable, Codable, Sendable {
    case auto, english, russian

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .english: "English"
        case .russian: "Russian"
        }
    }
}

/// Validated user input. Persistence assigns identity and creation time later.
public struct MeetingDraft: Equatable, Sendable {
    public let title: String
    public let description: String
    public let language: MeetingLanguage

    public init(title: String, description: String = "", language: MeetingLanguage = .auto) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ValidationError.emptyTitle }
        self.title = title
        self.description = description
        self.language = language
    }

    public enum ValidationError: LocalizedError, Equatable {
        case emptyTitle

        public var errorDescription: String? { "Enter a meeting title." }
    }
}
