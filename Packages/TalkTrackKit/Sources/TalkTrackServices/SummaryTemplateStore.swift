import Foundation
import CryptoKit
import TalkTrackDomain

/// An imported summary template: the file as imported, parsed.
public struct CustomSummaryTemplate: Equatable, Identifiable, Sendable {
    /// Custom templates share one icon, a person silhouette.
    public static let icon = "person.crop.circle"

    public let id: UUID
    public let text: String
    /// SHA-256 of `text` (normalized), hex; it changes when the template is replaced.
    public let contentHash: String
    public let importedAt: Date
    public let file: SummaryTemplateFile

    public var name: String { file.name }
    public var template: SummaryTemplate { file.template() }
    public var reference: CustomTemplateReference { CustomTemplateReference(id: id, name: name, contentHash: contentHash) }
}

/// A stored template that no longer parses (edited by hand, or written by a
/// newer TalkTrack); it can only be deleted.
public struct DamagedSummaryTemplate: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let reason: String
}

public enum SummaryTemplateStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalid([String])
    case notFound
    public var errorDescription: String? {
        switch self {
        case .invalid(let problems): "The template cannot be imported:\n" + problems.joined(separator: "\n")
        case .notFound: "The template no longer exists."
        }
    }
}

/// Custom templates in `~/Library/Application Support/TalkTrack/Templates`
/// (custom-summary-templates D6): `<id>.md` holds each imported file and
/// `Templates.json` their names and order. Independent of the library, so all
/// libraries on the Mac share them. Only the current version is kept.
public actor SummaryTemplateStore {
    struct Entry: Codable, Equatable {
        let id: UUID
        var name: String
        var importedAt: Date
    }

    public nonisolated let directory: URL
    private var entries: [Entry] = []
    private var loaded: [UUID: CustomSummaryTemplate] = [:]
    private var damagedEntries: [DamagedSummaryTemplate] = []
    private var didLoad = false

    public init(directory: URL) { self.directory = directory }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TalkTrack", isDirectory: true)
            .appendingPathComponent("Templates", isDirectory: true)
    }

    private var indexURL: URL { directory.appendingPathComponent("Templates.json") }
    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).md") }

    /// Valid templates in import order.
    public func templates() -> [CustomSummaryTemplate] {
        loadIfNeeded()
        return entries.compactMap { loaded[$0.id] }
    }

    public func damaged() -> [DamagedSummaryTemplate] {
        loadIfNeeded()
        return damagedEntries
    }

    public func template(id: UUID) -> CustomSummaryTemplate? {
        loadIfNeeded()
        return loaded[id]
    }

    /// The current content hash of each valid template.
    public func hashes() -> [UUID: String] {
        loadIfNeeded()
        return loaded.mapValues(\.contentHash)
    }

    /// Re-reads the folder (another window or a hand edit may have changed it).
    public func reload() {
        didLoad = false
        loadIfNeeded()
    }

    /// Checks `text` against the current templates' names.
    public func check(_ text: String, language: OutputLanguage) -> SummaryTemplateCheck {
        loadIfNeeded()
        return SummaryTemplateValidator.validate(text, existingNames: entries.compactMap { loaded[$0.id]?.name }, language: language)
    }

    /// Adds the template, or replaces the one with the same name (keeping its
    /// id and place). The file is validated again; errors refuse it.
    @discardableResult
    public func save(_ text: String) throws -> CustomSummaryTemplate {
        loadIfNeeded()
        let normalized = Self.normalize(text)
        let check = SummaryTemplateValidator.validate(normalized, existingNames: entries.compactMap { loaded[$0.id]?.name })
        guard let file = check.file else { throw SummaryTemplateStoreError.invalid(check.errors.map(\.text)) }
        let existing = entries.first { loaded[$0.id]?.name.compare(file.name, options: .caseInsensitive) == .orderedSame }
        let id = existing?.id ?? UUID()
        let now = Date()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(normalized.utf8).write(to: fileURL(id), options: .atomic)
        var next = entries
        if let index = next.firstIndex(where: { $0.id == id }) {
            next[index].name = file.name; next[index].importedAt = now
        } else { next.append(Entry(id: id, name: file.name, importedAt: now)) }
        try writeIndex(next)
        entries = next
        let value = CustomSummaryTemplate(id: id, text: normalized, contentHash: Self.hash(normalized), importedAt: now, file: file)
        loaded[id] = value
        return value
    }

    /// Removes the template for good.
    public func delete(id: UUID) throws {
        loadIfNeeded()
        let next = entries.filter { $0.id != id }
        try writeIndex(next)
        entries = next
        try? FileManager.default.removeItem(at: fileURL(id))
        loaded[id] = nil
        damagedEntries.removeAll { $0.id == id }
    }

    private func writeIndex(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: indexURL, options: .atomic)
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        loaded = [:]; damagedEntries = []
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: indexURL) {
            entries = (try? decoder.decode([Entry].self, from: data)) ?? []
        } else { entries = [] }
        for entry in entries {
            guard let data = try? Data(contentsOf: fileURL(entry.id)), let text = String(data: data, encoding: .utf8) else {
                damagedEntries.append(DamagedSummaryTemplate(id: entry.id, name: entry.name, reason: "The template file is missing or unreadable."))
                continue
            }
            let (file, diagnostics) = SummaryTemplateFile.parse(text)
            let errors = SummaryTemplateValidator.validate(text).errors
            guard let file, errors.isEmpty else {
                let first = (errors.first ?? diagnostics.first).map(\.text) ?? "The template file cannot be read."
                damagedEntries.append(DamagedSummaryTemplate(id: entry.id, name: entry.name, reason: first))
                continue
            }
            let normalized = Self.normalize(text)
            loaded[entry.id] = CustomSummaryTemplate(id: entry.id, text: normalized, contentHash: Self.hash(normalized),
                                                     importedAt: entry.importedAt, file: file)
        }
        // Template files no index entry names (an interrupted import): listed so they can be deleted.
        let known = Set(entries.map(\.id))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".md") {
            guard let id = UUID(uuidString: String(name.dropLast(3))), !known.contains(id) else { continue }
            damagedEntries.append(DamagedSummaryTemplate(id: id, name: name, reason: "The template is not in the template list."))
        }
    }

    /// LF line endings, no byte-order mark, one trailing newline.
    public static func normalize(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if value.hasPrefix("\u{FEFF}") { value.removeFirst() }
        while value.last?.isWhitespace == true { value.removeLast() }
        return value + "\n"
    }

    public static func hash(_ normalized: String) -> String {
        SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
