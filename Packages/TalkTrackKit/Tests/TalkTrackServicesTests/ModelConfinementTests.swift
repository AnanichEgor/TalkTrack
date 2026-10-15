import CryptoKit
import Darwin
import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

@Suite struct ModelConfinementTests {
    private func fixture(speech: Bool = false, nested: Bool = false) throws -> (ModelManifest, [String: Data]) {
        let original = try ModelCatalog.bundled().model(for: speech ? .liveASR : .segmentation)
        var bodies = Dictionary(uniqueKeysWithValues: original.files.map { ($0.path.value, Data("fixture".utf8)) })
        if speech {
            bodies["vocab.json"] = Data(#"{"a":0,"b":1}"#.utf8)
            bodies["merges.txt"] = Data("#version: 0.2\na b\n".utf8)
            bodies["tokenizer_config.json"] = Data(#"{"added_tokens_decoder":{}}"#.utf8)
        }
        if nested { bodies["nested/auxiliary.json"] = Data("{}".utf8) }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["files"] = bodies.sorted(by: { $0.key < $1.key }).map { name, data in
            ["path": name, "byteCount": data.count,
             "digest": ["algorithm": "sha256", "value": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]] as [String: Any]
        }
        json["downloadByteCount"] = bodies.values.reduce(0) { $0 + $1.count }
        json["weightByteCount"] = bodies.filter { $0.key.hasSuffix(".safetensors") }.values.reduce(0) { $0 + $1.count }
        return (try JSONDecoder().decode(ModelManifest.self, from: JSONSerialization.data(withJSONObject: json)), bodies)
    }

    private func seed(_ manifest: ModelManifest, bodies: [String: Data], files: ModelDownloadFiles) async throws -> ModelDownloadTicket {
        let ticket = try await files.begin(manifest)
        do {
            for file in manifest.files {
                let writer = try await files.writer(file, ticket: ticket, append: false, etag: "\"fixture\"")
                try writer.write(contentsOf: #require(bodies[file.path.value]))
                try writer.synchronize()
                try writer.close()
                try await files.publishFile(file, ticket: ticket)
            }
            return ticket
        } catch { await files.end(ticket); throw error }
    }

    private func ready(_ manifest: ModelManifest, bodies: [String: Data], files: ModelDownloadFiles) async throws {
        let ticket = try await seed(manifest, bodies: bodies, files: files)
        do {
            if !manifest.generatedArtifacts.isEmpty {
                try await QwenTokenizerPreparation.prepare(in: ModelPreparationContext(files: files, ticket: ticket))
            }
            try await files.publishReady(ticket)
            await files.end(ticket)
        } catch { await files.end(ticket); throw error }
    }

    @Test(arguments: ["root", "missingParent", "owner", "downloads", "locks"])
    func downloadRejectsParentLinksBeforeCreatingMissingLeaves(_ target: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let outside = folder.url.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        var root = folder.url.appendingPathComponent("Models")
        let (manifest, _) = try fixture()
        var link = root
        if target == "missingParent" {
            link = folder.url.appendingPathComponent("linkedParent")
            root = link.appendingPathComponent("not-created/Models")
        } else if target != "root" {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let component = target == "owner" ? String(manifest.repository.split(separator: "/")[0]) : "." + target
            link = root.appendingPathComponent(component)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let files = ModelDownloadFiles(testRoot: root)
        await #expect(throws: (any Error).self) { _ = try await files.begin(manifest) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test(arguments: ["symlink", "hardlink", "fifo", "missing", "corrupt", "extraWeights"])
    func readyMarkerCannotAuthorizeUnsafeOrChangedFiles(_ mutation: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let root = folder.url.appendingPathComponent("Models")
        let files = ModelDownloadFiles(testRoot: root)
        let (manifest, bodies) = try fixture()
        try await ready(manifest, bodies: bodies, files: files)
        let installed = root.appendingPathComponent(try manifest.installationPath.value)
        let config = installed.appendingPathComponent("config.json")
        let external = folder.url.appendingPathComponent("external.json")
        try bodies["config.json"]!.write(to: external)
        if mutation != "extraWeights" { try FileManager.default.removeItem(at: config) }
        switch mutation {
        case "symlink": try FileManager.default.createSymbolicLink(at: config, withDestinationURL: external)
        case "hardlink": try FileManager.default.linkItem(at: external, to: config)
        case "fifo": #expect(mkfifo(config.path, 0o600) == 0)
        case "corrupt": try Data("changed".utf8).write(to: config)
        case "extraWeights": try FileManager.default.createSymbolicLink(at: installed.appendingPathComponent("extra.safetensors"), withDestinationURL: external)
        default: break
        }
        await #expect(throws: (any Error).self) { _ = try await files.acquireLocalModel(manifest) }
        #expect(try Data(contentsOf: external) == bodies["config.json"])
        if mutation == "missing" { #expect(!FileManager.default.fileExists(atPath: config.path)) }
        try await files.remove(manifest)
        #expect(try Data(contentsOf: external) == bodies["config.json"])
    }

    @Test func nestedReadAndPublishRejectExternalParent() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let root = folder.url.appendingPathComponent("Models")
        let files = ModelDownloadFiles(testRoot: root)
        let (manifest, bodies) = try fixture(nested: true)
        let ticket = try await seed(manifest, bodies: bodies, files: files)
        let nested = root.appendingPathComponent(try manifest.installationPath.value).appendingPathComponent("nested")
        let outside = folder.url.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: nested)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
        let file = try #require(manifest.files.first { $0.path.value == "nested/auxiliary.json" })
        let writer = try await files.writer(file, ticket: ticket, append: false, etag: nil)
        try writer.write(contentsOf: #require(bodies[file.path.value]))
        try writer.close()
        await #expect(throws: (any Error).self) { try await files.publishFile(file, ticket: ticket) }
        await #expect(throws: (any Error).self) { _ = try await files.readForPreparation(file.path, ticket: ticket) }
        await files.end(ticket)
        try await files.remove(manifest)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func generatedTokenizerUsesConfinedIOAndExpiringAccess() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let root = folder.url.appendingPathComponent("Models")
        let files = ModelDownloadFiles(testRoot: root)
        let (manifest, bodies) = try fixture(speech: true)
        let ticket = try await seed(manifest, bodies: bodies, files: files)
        let context = ModelPreparationContext(files: files, ticket: ticket)
        let installed = root.appendingPathComponent(try manifest.installationPath.value)
        let generated = installed.appendingPathComponent("tokenizer.json")
        let external = folder.url.appendingPathComponent("external.json")
        try Data("unchanged".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: generated, withDestinationURL: external)
        await #expect(throws: (any Error).self) { try await QwenTokenizerPreparation.prepare(in: context) }
        #expect(try String(contentsOf: external, encoding: .utf8) == "unchanged")
        try FileManager.default.removeItem(at: generated)
        try await QwenTokenizerPreparation.prepare(in: context)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: generated)) as? [String: Any])
        #expect(json["version"] as? String == "1.0")
        let access = try await context.localDirectory()
        #expect(try await access.validatedURL().standardizedFileURL == installed.standardizedFileURL)
        await #expect(throws: ModelDownloadError.busy) { try await context.writeGenerated(RelativePath("tokenizer.json"), data: Data()) }
        try await files.publishReady(ticket)
        await files.end(ticket)
        await #expect(throws: ModelDownloadError.invalidLease) { _ = try await access.validatedURL() }
        await #expect(throws: ModelDownloadError.invalidLease) { _ = try await context.read(RelativePath("config.json")) }
        let acquired = try await files.acquireLocalModel(manifest)
        await acquired.release()
    }

    @Test func activeLoadExcludesRemovalAndRedownloadAcrossServiceInstances() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let root = folder.url.appendingPathComponent("Models")
        let files = ModelDownloadFiles(testRoot: root)
        let other = ModelDownloadFiles(testRoot: root)
        let (manifest, bodies) = try fixture()
        try await ready(manifest, bodies: bodies, files: files)
        let access = try await files.acquireLocalModel(manifest)
        _ = try await access.validatedURL()
        await #expect(throws: ModelDownloadError.busy) { try await files.remove(manifest) }
        await #expect(throws: ModelDownloadError.busy) { try await other.remove(manifest) }
        await #expect(throws: ModelDownloadError.busy) { _ = try await other.begin(manifest) }
        await #expect(throws: ModelDownloadError.busy) { _ = try await other.acquireLocalModel(manifest) }
        await access.release()
        try await other.remove(manifest)
        #expect(try await !files.isReady(manifest))
        await #expect(throws: ModelDownloadError.invalidLease) { _ = try await access.validatedURL() }
    }

    @Test(arguments: ["partialLink", "partialHardlink", "validatorLink"])
    func partialFilesCannotRedirectWritesOrReads(_ mutation: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let root = folder.url.appendingPathComponent("Models")
        let files = ModelDownloadFiles(testRoot: root)
        let (manifest, _) = try fixture()
        let ticket = try await files.begin(manifest)
        let file = try #require(manifest.files.first)
        let key = SHA256.hash(data: Data(file.path.value.utf8)).map { String(format: "%02x", $0) }.joined()
        let stage = root.appendingPathComponent(".downloads/" + ticket.fingerprint)
        let external = folder.url.appendingPathComponent("untouched")
        let bytes = Data("\"original\"".utf8)
        try bytes.write(to: external)
        if mutation == "validatorLink" {
            let writer = try await files.writer(file, ticket: ticket, append: false, etag: nil)
            try writer.write(contentsOf: Data("f".utf8))
            try writer.close()
            try FileManager.default.createSymbolicLink(at: stage.appendingPathComponent(key + ".etag.json"), withDestinationURL: external)
            await #expect(throws: (any Error).self) { _ = try await files.partial(file, ticket: ticket) }
        } else {
            let partial = stage.appendingPathComponent(key + ".part")
            if mutation == "partialLink" { try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: external) }
            else { try FileManager.default.linkItem(at: external, to: partial) }
            await #expect(throws: (any Error).self) { _ = try await files.writer(file, ticket: ticket, append: false, etag: nil) }
        }
        await files.end(ticket)
        try await files.remove(manifest)
        #expect(try Data(contentsOf: external) == bytes)
    }

    @Test func generatedArtifactIsRecheckedBeforeLoading() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let root = folder.url.appendingPathComponent("Models")
        let files = ModelDownloadFiles(testRoot: root)
        let (manifest, bodies) = try fixture(speech: true)
        try await ready(manifest, bodies: bodies, files: files)
        let generated = root.appendingPathComponent(try manifest.installationPath.value).appendingPathComponent("tokenizer.json")
        try Data("{}".utf8).write(to: generated)
        await #expect(throws: ModelCatalogError.self) { _ = try await files.acquireLocalModel(manifest) }
    }

    @Test func replacedRootIsRejectedWithoutRecreatingMissingModels() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let root = folder.url.appendingPathComponent("Models")
        let files = ModelDownloadFiles(testRoot: root)
        let (manifest, bodies) = try fixture()
        try await ready(manifest, bodies: bodies, files: files)
        let access = try await files.acquireLocalModel(manifest)
        try FileManager.default.moveItem(at: root, to: folder.url.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await #expect(throws: LibraryError.self) { _ = try await access.validatedURL() }
        await access.release()
        await #expect(throws: LibraryError.self) { try await files.remove(manifest) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func preparationRejectsHardlinksUndeclaredFilesAndTraversal() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let root = folder.url.appendingPathComponent("Models")
        let files = ModelDownloadFiles(testRoot: root)
        let (manifest, bodies) = try fixture()
        let ticket = try await seed(manifest, bodies: bodies, files: files)
        let config = root.appendingPathComponent(try manifest.installationPath.value).appendingPathComponent("config.json")
        let external = folder.url.appendingPathComponent("config.json")
        try FileManager.default.linkItem(at: config, to: external)
        let context = ModelPreparationContext(files: files, ticket: ticket)
        await #expect(throws: LibraryError.self) { _ = try await context.read(RelativePath("config.json")) }
        await #expect(throws: ModelDownloadError.incompletePreparation) { _ = try await context.read(RelativePath("undeclared.json")) }
        await #expect(throws: ModelDownloadError.incompletePreparation) { try await context.writeGenerated(RelativePath("undeclared.json"), data: Data()) }
        for path in ["../outside", "/tmp/outside", "a/../../outside", "~/cache", "file:/cache"] {
            #expect(throws: (any Error).self) { _ = try RelativePath(path) }
        }
        await files.end(ticket)
        #expect(try Data(contentsOf: external) == bodies["config.json"])
        #expect(ModelDownloadFiles.defaultRoot.path == FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support/TalkTrack/Models")
    }
}
