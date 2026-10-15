import Foundation
import Testing
import TalkTrackServices

struct TemporaryFolder {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite struct OwnedLibraryTests {
    @Test func firstRunBookmarkRelaunchPreservesUnrelatedFiles() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let document = folder.url.appendingPathComponent("prompt.md")
        let bytes = Data("untouched repository\nисходник".utf8)
        try bytes.write(to: document)
        let manager = OwnedLibrary()
        let first = try await manager.open(root: folder.url)
        #expect(FileManager.default.fileExists(atPath: first.directory.appendingPathComponent("manifest.json").path))
        let location = try first.makeLocation()
        let reopened = try await OwnedLibrary().resume(location)
        #expect(first.manifest == reopened.manifest)
        #expect(try Data(contentsOf: document) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted() == [".talktrack-library", "prompt.md"])
    }

    @Test func defaultCreatesOnlyItsOwnedSubfolder() async throws {
        let home = try TemporaryFolder()
        defer { home.remove() }
        try FileManager.default.createDirectory(at: home.url.appendingPathComponent("Documents"), withIntermediateDirectories: false)
        let first = try await OwnedLibrary().openDefault(home: home.url)
        let next = try await OwnedLibrary().openDefault(home: home.url)
        #expect(first.manifest.libraryID == next.manifest.libraryID)
        #expect(first.directory.path.hasSuffix("Documents/TalkTrack/.talktrack-library"))
    }

    @Test func missingConfiguredLibraryIsNeverRecreated() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let manager = OwnedLibrary()
        let first = try await manager.open(root: folder.url)
        try FileManager.default.removeItem(at: first.directory)
        await #expect(throws: LibraryError.self) {
            try await manager.open(root: folder.url, expectedID: first.manifest.libraryID, allowCreate: false)
        }
        #expect(!FileManager.default.fileExists(atPath: first.directory.path))
        await #expect(throws: LibraryError.self) {
            try await manager.open(root: folder.url.appendingPathComponent("disconnected"))
        }
    }

    @Test func unmarkedWrongAndFutureLibrariesAreUntouched() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let owned = folder.url.appendingPathComponent(".talktrack-library")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
        await #expect(throws: LibraryError.unmarkedLibrary) { try await OwnedLibrary().open(root: folder.url) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: owned.path).isEmpty)
        try FileManager.default.removeItem(at: owned)
        let manager = OwnedLibrary()
        let library = try await manager.open(root: folder.url)
        await #expect(throws: LibraryError.wrongIdentity) { try await manager.open(root: folder.url, expectedID: UUID()) }
        let file = owned.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: file)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["formatVersion"] = 99
        let future = try JSONSerialization.data(withJSONObject: json)
        try future.write(to: file)
        await #expect(throws: LibraryError.unsupportedVersion(99)) {
            try await manager.open(root: folder.url, expectedID: library.manifest.libraryID)
        }
        #expect(try Data(contentsOf: file) == future)
    }

    @Test(arguments: ["root", "owned", "manifest", "meetings"])
    func symlinksCannotEscape(_ target: String) async throws {
        let folder = try TemporaryFolder()
        let outside = try TemporaryFolder()
        defer { folder.remove(); outside.remove() }
        let manager = OwnedLibrary()
        var root = folder.url
        if target == "root" {
            root = folder.url.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside.url)
        } else if target == "owned" {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".talktrack-library"), withDestinationURL: outside.url)
        } else {
            let library = try await manager.open(root: root)
            let entry = library.directory.appendingPathComponent(target == "manifest" ? "manifest.json" : "Meetings")
            try FileManager.default.removeItem(at: entry)
            try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: outside.url)
        }
        await #expect(throws: LibraryError.self) { try await manager.open(root: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.url.path).isEmpty)
    }

    @Test func modelsOverlapAndNestedLibrariesAreRejected() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let manager = OwnedLibrary(modelsRoot: folder.url.appendingPathComponent("Models"))
        await #expect(throws: LibraryError.self) { try await manager.open(root: folder.url) }
        await #expect(throws: LibraryError.self) { try await manager.open(root: folder.url.appendingPathComponent("Models/child")) }
        await #expect(throws: LibraryError.self) { try await manager.open(root: folder.url.appendingPathComponent(".talktrack-library/child")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
    }
}
