import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

@Suite struct ModelCatalogTests {
    private func catalogJSON() throws -> [String: Any] {
        let catalog = try ModelCatalog.bundled()
        let models = try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog.models))
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog.legacyModels))
        return ["schemaVersion": 1, "models": models, "legacyModels": legacy]
    }

    @Test func bundledRolesReuseTextWeightsAndRetainProvenance() throws {
        let catalog = try ModelCatalog.bundled().selecting(textModel: nil, physicalMemory: 64 << 30)
        #expect(catalog.models.count == 7)
        #expect(catalog.models.flatMap(\.files).count == 57)
        let summary = try catalog.model(for: .summary)
        #expect(try summary == catalog.model(for: .translation))
        #expect(try summary == catalog.model(for: .spelling))
        #expect(summary.weightByteCount == 7_100_711_638)
        #expect(summary.repository == "mlx-community/Qwen3.5-9B-OptiQ-4bit")
        #expect(summary.files.filter { $0.path.value.hasSuffix(".safetensors") }.count == 2)
        #expect(!summary.files.contains { $0.path.value.hasPrefix("optiq/") })
        #expect(summary.runtimeValidation == "pending")
        #expect(try summary.snapshot(for: .summary).directory == summary.snapshot(for: .spelling).directory)
        let embedding = try catalog.model(for: .embedding)
        #expect(embedding.license.checkpointLicense == "mit")
        #expect(embedding.license.baseLicense == "cc-by-4.0")
        #expect(try catalog.model(for: .segmentation).license.baseAccess == "gated")
        // The 16 GB alternative: one text shard, same roles, its own folder.
        let small = try catalog.selecting(textModel: nil, physicalMemory: 16 << 30).model(for: .summary)
        #expect(small.repository == "mlx-community/Qwen3.5-4B-OptiQ-4bit" && small.weightByteCount == 3_269_669_552)
        #expect(small.files.filter { $0.path.value.hasSuffix(".safetensors") }.map(\.path.value) == ["model.safetensors"])
        #expect(small.license.checkpointLicense == "apache-2.0")
        #expect(try small.snapshot(for: .summary) != summary.snapshot(for: .summary))
        #expect(try catalog.model(for: small.snapshot(for: .translation)) == small)
        for role in [ModelRole.liveASR, .finalASR, .alignment] {
            let model = try catalog.model(for: role)
            #expect(model.generatedArtifacts.map(\.path.value) == ["tokenizer.json"])
            #expect(!model.files.contains { $0.path.value == "tokenizer.json" })
            let config = try #require(model.files.first { $0.path.value == "config.json" })
            #expect(config.digest.algorithm == .gitBlobSHA1)
            #expect(try model.downloadURL(for: config).absoluteString ==
                    "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/config.json")
        }
    }

    @Test func legacySnapshotsResolveExactlyAndNewRolesShareTheSmallerModel() throws {
        let catalog = try ModelCatalog.bundled().selecting(textModel: nil, physicalMemory: 64 << 30)
        let legacy = try #require(catalog.legacyModels.first)
        #expect(legacy.repository == "mlx-community/Qwen3.6-35B-A3B-4bit")
        #expect(legacy.id == "text" && legacy.weightByteCount == 20_402_204_271)
        for role in [ModelRole.summary, .translation, .spelling] {
            let snapshot = try legacy.snapshot(for: role)
            #expect(try catalog.model(for: snapshot) == legacy)
            #expect(try catalog.model(for: role).snapshot(for: role) != snapshot)
            let incompatible = ModelSnapshot(role: role, repository: snapshot.repository, revision: snapshot.revision,
                directory: snapshot.directory, preprocessingVersion: "wrong")
            #expect(throws: ModelCatalogError.self) { try catalog.model(for: incompatible) }
        }
    }

    @Test func incompleteTextShardSetFailsEvenWhenAggregateLengthsAreConsistent() throws {
        var json = try catalogJSON()
        var models = json["models"] as! [[String: Any]]
        let index = models.firstIndex { $0["adapter"] as? String == "qwen3Text" }!
        var files = models[index]["files"] as! [[String: Any]]
        files.removeAll { $0["path"] as? String == "model-00002-of-00002.safetensors" }
        models[index]["files"] = files
        models[index]["downloadByteCount"] = files.reduce(Int64(0)) { $0 + ($1["byteCount"] as! NSNumber).int64Value }
        models[index]["weightByteCount"] = files.filter { ($0["path"] as! String).hasSuffix(".safetensors") }
            .reduce(Int64(0)) { $0 + ($1["byteCount"] as! NSNumber).int64Value }
        json["models"] = models
        #expect(throws: ModelCatalogError.self) { try ModelCatalog(data: JSONSerialization.data(withJSONObject: json)) }
    }

    @Test(arguments: ["missingWeights", "missingTokenizer", "badHash", "wrongTotal", "duplicate", "caseCollision", "mutableRevision", "escape", "wrongSource", "missingGenerator", "wrongRole"])
    func malformedCatalogIsRejected(_ mutation: String) throws {
        var json = try catalogJSON()
        var models = try #require(json["models"] as? [[String: Any]])
        var files = try #require(models[0]["files"] as? [[String: Any]])
        switch mutation {
        case "missingWeights": files.removeAll { ($0["path"] as? String) == "model.safetensors" }
        case "missingTokenizer": files.removeAll { ($0["path"] as? String) == "merges.txt" }
        case "badHash": files[0]["digest"] = ["algorithm": "sha256", "value": "not-a-digest"]
        case "wrongTotal": models[0]["downloadByteCount"] = 1
        case "duplicate": files.append(files[0])
        case "caseCollision":
            var extra = files[0]
            extra["path"] = (extra["path"] as? String)?.uppercased()
            files.append(extra)
        case "mutableRevision": models[0]["revision"] = "main"
        case "escape": files[0]["path"] = "../config.json"
        case "wrongSource": models[0]["evidenceURL"] = "https://example.com/model"
        case "missingGenerator": models[0]["generatedArtifacts"] = []
        case "wrongRole": models[0]["roles"] = ["summary"]
        default: Issue.record("Unknown fixture mutation")
        }
        models[0]["files"] = files
        json["models"] = models
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try ModelCatalog(data: data) }
    }

    @Test func unsupportedCatalogVersionIsRejected() throws {
        var json = try catalogJSON()
        json["schemaVersion"] = 2
        #expect(throws: ModelCatalogError.unsupportedSchema(2)) {
            try ModelCatalog(data: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func streamingSHA256AndGitBlobVectors() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let verifier = ModelIntegrityVerifier()
        let fixtures: [(Data, ModelDigestAlgorithm, String)] = [
            (Data("abc".utf8), .sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (Data("hello\n".utf8), .gitBlobSHA1, "ce013625030ba8dba906f756967f9e9ca394464a"),
            (Data(repeating: 97, count: 1_048_593), .sha256, "c26032d5154f96bd29c799447d715ab681d8d0aa308ecc6f321a35d98f0672da"),
        ]
        for (index, fixture) in fixtures.enumerated() {
            let path = folder.url.appendingPathComponent("\(index).bin")
            try fixture.0.write(to: path)
            let handle = try FileHandle(forReadingFrom: path)
            defer { try? handle.close() }
            let file = try ModelFile(path: RelativePath("fixture.bin"), byteCount: Int64(fixture.0.count),
                                     digest: ModelDigest(algorithm: fixture.1, value: fixture.2))
            try await verifier.verify(file, reading: handle)
        }
    }

    @Test(arguments: ["length", "digest", "truncated"])
    func corruptFilesFailBeforeReadiness(_ corruption: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let path = folder.url.appendingPathComponent("bad.bin")
        try Data((corruption == "truncated" ? "ab" : corruption == "digest" ? "abd" : "abcd").utf8).write(to: path)
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let file = try ModelFile(path: RelativePath("bad.bin"), byteCount: 3,
            digest: ModelDigest(algorithm: .sha256, value: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        let expected: ModelCatalogError = corruption == "digest" ? .digestMismatch("bad.bin") : .sizeMismatch("bad.bin")
        await #expect(throws: expected) { try await ModelIntegrityVerifier().verify(file, reading: handle) }
    }
}
