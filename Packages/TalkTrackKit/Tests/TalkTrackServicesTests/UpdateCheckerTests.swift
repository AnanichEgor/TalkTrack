import Foundation
import Testing
@testable import TalkTrackServices

@MainActor @Suite struct UpdateCheckerTests {
    nonisolated static func release(_ tag: String, prerelease: Bool = false) -> Data {
        Data("""
        {"tag_name": "\(tag)", "html_url": "https://github.com/AnanichEgor/TalkTrack/releases/tag/\(tag)",
         "draft": false, "prerelease": \(prerelease),
         "assets": [{"name": "TalkTrack.dmg.sha256", "browser_download_url": "https://example.invalid/a.sha256"},
                    {"name": "TalkTrack.dmg", "browser_download_url": "https://example.invalid/TalkTrack.dmg"}]}
        """.utf8)
    }

    @Test func versionsCompareNumerically() {
        #expect(AppVersion("v0.10.0")! > AppVersion("0.9.9")!)
        #expect(AppVersion("0.2")! == AppVersion("v0.2.0")!)
        #expect(AppVersion("1.0.0")! > AppVersion("0.99")!)
        #expect(AppVersion("0.1.0-beta") == nil && AppVersion("") == nil && AppVersion("1..2") == nil)
    }

    @Test func onlyANewerPublishedReleaseIsAnUpdate() throws {
        let update = try #require(try UpdateChecker.newer(than: "0.1.0", release: Self.release("v0.2.0")))
        #expect(update.version == "0.2.0")
        #expect(update.downloadURL?.lastPathComponent == "TalkTrack.dmg")
        #expect(update.pageURL.absoluteString.hasSuffix("/tag/v0.2.0"))
        #expect(try UpdateChecker.newer(than: "0.1.0", release: Self.release("v0.1.0")) == nil)
        #expect(try UpdateChecker.newer(than: "0.3.0", release: Self.release("v0.2.0")) == nil)
        #expect(throws: UpdateCheckError.unreadableRelease) {
            try UpdateChecker.newer(than: "0.1.0", release: Self.release("v0.2.0", prerelease: true))
        }
    }

    @Test func eachVersionIsAnnouncedOnceAndFailuresAreReported() async throws {
        let defaults = try #require(UserDefaults(suiteName: "UpdateCheckerTests-\(UUID())"))
        let checker = UpdateChecker(currentVersion: "0.1.0", defaults: defaults) { _ in Self.release("v0.2.0") }
        #expect(checker.automatic)
        var found: [String] = []
        checker.start { found.append($0.version) }
        while found.isEmpty { await Task.yield() }
        #expect(found == ["0.2.0"] && checker.available?.version == "0.2.0")
        // Later checks of the same version stay silent.
        #expect(!checker.announce(try #require(checker.available)))

        checker.automatic = false
        #expect(UpdateChecker(currentVersion: "0.1.0", defaults: defaults).automatic == false)

        let failing = UpdateChecker(currentVersion: "0.1.0", defaults: defaults) { _ in throw UpdateCheckError.server(403) }
        #expect(await failing.check() == nil)
        guard case .failed(let message) = failing.status else { Issue.record("expected failure"); return }
        #expect(message.contains("403"))
    }
}
