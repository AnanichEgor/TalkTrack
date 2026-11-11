import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

@Suite struct SummaryTemplateStoreTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TemplateStore-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func addReplaceKeepingIdAndOrderThenDelete() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SummaryTemplateStore(directory: directory)
        let retro = try await store.save(SummaryTemplateFileTests.retro)
        let example = try await store.save(try #require(SummaryTemplateGuide.exampleText))
        #expect(await store.templates().map(\.name) == ["Sprint Retro", "General Meeting"])
        #expect(retro.contentHash.count == 64 && retro.contentHash != example.contentHash)

        // Same name, other letter case: replaces in place and keeps the id.
        let corrected = SummaryTemplateFileTests.retro
            .replacingOccurrences(of: "name: Sprint Retro", with: "name: sprint retro")
            .replacingOccurrences(of: "one bullet each", with: "one bullet per success")
        #expect(await store.check(corrected, language: .english).replaces == "Sprint Retro")
        let replaced = try await store.save(corrected)
        #expect(replaced.id == retro.id && replaced.contentHash != retro.contentHash)
        #expect(await store.templates().map(\.name) == ["sprint retro", "General Meeting"])
        #expect(await store.hashes()[retro.id] == replaced.contentHash)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".md") }
        #expect(files.count == 2)

        try await store.delete(id: retro.id)
        #expect(await store.templates().map(\.id) == [example.id])
        #expect(await store.template(id: retro.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(retro.id.uuidString).md").path))
    }

    @Test func invalidFileIsRefusedAndNothingIsWritten() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SummaryTemplateStore(directory: directory)
        await #expect(throws: SummaryTemplateStoreError.self) { try await store.save("---\nnmae: X\n---\n## A\nSome text here please.") }
        let written = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(written.isEmpty)
    }

    @Test func hashIsOfNormalizedText() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SummaryTemplateStore(directory: directory)
        let unix = try await store.save(SummaryTemplateFileTests.retro)
        // The same file with Windows line endings and trailing blank lines is the same version.
        let windows = try await store.save("\u{FEFF}" + SummaryTemplateFileTests.retro.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n")
        #expect(windows.id == unix.id && windows.contentHash == unix.contentHash)
        let stored = try String(contentsOf: directory.appendingPathComponent("\(unix.id.uuidString).md"), encoding: .utf8)
        #expect(stored == SummaryTemplateFileTests.retro + "\n")
        #expect(SummaryTemplateStore.hash(stored) == unix.contentHash)
    }

    @Test func reopenedStoreAndDamagedFiles() async throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = SummaryTemplateStore(directory: directory)
        let retro = try await first.save(SummaryTemplateFileTests.retro)
        let example = try await first.save(try #require(SummaryTemplateGuide.exampleText))

        let reopened = SummaryTemplateStore(directory: directory)
        let before = await first.templates()
        #expect(await reopened.templates() == before)
        #expect(await reopened.damaged().isEmpty)

        // A file broken by hand, a missing file and a file no list entry names.
        try "---\nname: Sprint Retro\nicon: star\n---\n## A\nText here please now."
            .write(to: directory.appendingPathComponent("\(retro.id.uuidString).md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(example.id.uuidString).md"))
        let stray = UUID()
        try "anything".write(to: directory.appendingPathComponent("\(stray.uuidString).md"), atomically: true, encoding: .utf8)
        let damagedStore = SummaryTemplateStore(directory: directory)
        #expect(await damagedStore.templates().isEmpty)
        let damaged = await damagedStore.damaged()
        #expect(damaged.map(\.id) == [retro.id, example.id, stray])
        #expect(damaged[0].name == "Sprint Retro" && damaged[0].reason.contains("Unknown header field \"icon\""))
        #expect(damaged[1].reason.contains("missing"))
        // Damaged templates can be deleted.
        for item in damaged { try await damagedStore.delete(id: item.id) }
        #expect(await damagedStore.damaged().isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left == ["Templates.json"])
    }

    @Test func defaultFolderIsInApplicationSupport() {
        #expect(SummaryTemplateStore.defaultDirectory.path.hasSuffix("Library/Application Support/TalkTrack/Templates"))
    }
}
