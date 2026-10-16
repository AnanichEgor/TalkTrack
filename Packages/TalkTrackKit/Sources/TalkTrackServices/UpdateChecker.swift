import Foundation
import Observation

/// A dotted numeric version such as `0.2.0`; a leading `v` (release tags) is ignored.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        components = parts.compactMap { $0 }
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// Missing components count as zero: 0.2 == 0.2.0.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let a = index < lhs.components.count ? lhs.components[index] : 0
            let b = index < rhs.components.count ? rhs.components[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// A published release newer than the running app.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    /// The GitHub release page with notes and the DMG.
    public let pageURL: URL
    public let downloadURL: URL?

    public init(version: String, pageURL: URL, downloadURL: URL?) {
        self.version = version; self.pageURL = pageURL; self.downloadURL = downloadURL
    }
}

/// Asks GitHub for the latest published release of TalkTrack and compares it
/// with the running version. Only the version, page and asset links are read;
/// nothing about the user or their meetings is sent. Updates are installed by
/// the user from the release page.
@MainActor @Observable public final class UpdateChecker {
    public enum Status: Equatable {
        case idle, checking
        case upToDate(checkedAt: Date)
        case available(AvailableUpdate)
        case failed(String)
    }

    public static let automaticKey = "checkForUpdatesAutomatically"
    /// The last version announced with an alert, so each version alerts once.
    public static let announcedKey = "announcedUpdateVersion"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/AnanichEgor/TalkTrack/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/AnanichEgor/TalkTrack/releases")!

    public let currentVersion: String
    public private(set) var status: Status = .idle
    public var automatic: Bool {
        didSet { defaults.set(automatic, forKey: Self.automaticKey) }
    }
    public var available: AvailableUpdate? {
        if case .available(let update) = status { update } else { nil }
    }

    private let defaults: UserDefaults
    private let fetch: @Sendable (URL) async throws -> Data
    private var periodic: Task<Void, Never>?

    public init(currentVersion: String, defaults: UserDefaults = .standard,
                fetch: @escaping @Sendable (URL) async throws -> Data = UpdateChecker.download) {
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.fetch = fetch
        automatic = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    /// Checks now (unless automatic checks are off) and then once a day while
    /// the app runs; `found` is called with each newer version not yet announced.
    public func start(found: @escaping @MainActor (AvailableUpdate) -> Void) {
        periodic?.cancel()
        periodic = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.automatic, let update = await self.check(), self.announce(update) { found(update) }
                do { try await Task.sleep(for: .seconds(24 * 60 * 60)) } catch { return }
            }
        }
    }

    /// Returns the newer release, if any; a failure is kept in `status`.
    @discardableResult public func check() async -> AvailableUpdate? {
        guard status != .checking else { return available }
        status = .checking
        do {
            let data = try await fetch(Self.latestReleaseURL)
            if let update = try Self.newer(than: currentVersion, release: data) {
                status = .available(update)
                return update
            }
            status = .upToDate(checkedAt: .now)
        } catch {
            status = .failed("Could not check for updates: \(error.localizedDescription)")
        }
        return nil
    }

    /// True the first time a version is seen; later checks stay silent.
    func announce(_ update: AvailableUpdate) -> Bool {
        guard defaults.string(forKey: Self.announcedKey) != update.version else { return false }
        defaults.set(update.version, forKey: Self.announcedKey)
        return true
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?
    }

    /// Parses GitHub's latest-release response; nil when it is not newer.
    public static func newer(than current: String, release data: Data) throws -> AvailableUpdate? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.draft != true, release.prerelease != true,
              let latest = AppVersion(release.tag_name), let running = AppVersion(current) else {
            throw UpdateCheckError.unreadableRelease
        }
        guard running < latest else { return nil }
        let dmg = release.assets?.first { $0.name.hasSuffix(".dmg") }?.browser_download_url
        return AvailableUpdate(version: latest.description, pageURL: release.html_url, downloadURL: dmg)
    }

    public nonisolated static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TalkTrack", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateCheckError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}

public enum UpdateCheckError: Error, LocalizedError, Equatable {
    case unreadableRelease
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .unreadableRelease: "The latest release has no readable version."
        case .server(let code): "GitHub answered with status \(code)."
        }
    }
}
