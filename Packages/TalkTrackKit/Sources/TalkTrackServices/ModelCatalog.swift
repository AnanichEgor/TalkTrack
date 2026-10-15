import Foundation
import TalkTrackDomain

public enum ModelCatalogError: Error, Equatable, LocalizedError, Sendable {
    case invalidManifest(String)
    case unsupportedSchema(Int)
    case missingResource
    case sizeMismatch(String)
    case digestMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): "Invalid model manifest: \(reason). Restore the bundled catalog before downloading."
        case .unsupportedSchema(let version): "Model catalog format \(version) requires a newer app."
        case .missingResource: "The model catalog is missing from the app. Reinstall TalkTrack."
        case .sizeMismatch(let path): "Model file has an unexpected length: \(path). Retry or repair the download."
        case .digestMismatch(let path): "Model file failed its integrity check: \(path). Retry or repair the download."
        }
    }
}

public enum ModelDigestAlgorithm: String, Codable, Sendable { case sha256, gitBlobSHA1 }

public struct ModelDigest: Codable, Equatable, Sendable {
    public let algorithm: ModelDigestAlgorithm
    public let value: String

    public init(algorithm: ModelDigestAlgorithm, value: String) throws {
        guard Self.isHex(value, length: algorithm == .sha256 ? 64 : 40) else {
            throw ModelCatalogError.invalidManifest("Malformed file digest")
        }
        self.algorithm = algorithm
        self.value = value
    }

    static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct ModelFile: Codable, Equatable, Sendable {
    public let path: RelativePath
    public let byteCount: Int64
    public let digest: ModelDigest

    public init(path: RelativePath, byteCount: Int64, digest: ModelDigest) throws {
        self.path = path
        self.byteCount = byteCount
        self.digest = digest
        try validate()
    }

    func validate() throws {
        guard byteCount >= 0 else { throw ModelCatalogError.invalidManifest("Negative file length") }
        _ = try ModelDigest(algorithm: digest.algorithm, value: digest.value)
        if path.value.hasSuffix(".safetensors"), digest.algorithm != .sha256 {
            throw ModelCatalogError.invalidManifest("Weights require an upstream SHA-256")
        }
    }
}

public enum ModelAdapter: String, Codable, Sendable {
    case qwen3ASR, qwen3Aligner, pyannoteSegmentation, weSpeaker, qwen3Text

    var allowedRoles: Set<ModelRole> {
        switch self {
        case .qwen3ASR: [.liveASR, .finalASR]
        case .qwen3Aligner: [.alignment]
        case .pyannoteSegmentation: [.segmentation]
        case .weSpeaker: [.embedding]
        case .qwen3Text: [.summary, .translation, .spelling]
        }
    }

    var requiredFiles: Set<String> {
        let common: Set<String> = ["config.json", "README.md"]
        switch self {
        case .qwen3ASR, .qwen3Aligner:
            return common.union(["model.safetensors", "model.safetensors.index.json", "vocab.json", "merges.txt",
                "tokenizer_config.json", "preprocessor_config.json", "chat_template.json", "generation_config.json"])
        case .pyannoteSegmentation, .weSpeaker:
            return common.union(["model.safetensors"])
        case .qwen3Text:
            // The chat template may live in tokenizer_config.json instead of
            // chat_template.jinja; loading applies it once before admission.
            return common.union(["model.safetensors.index.json", "tokenizer.json", "tokenizer_config.json"])
        }
    }
}

public struct GeneratedModelArtifact: Codable, Equatable, Sendable {
    public let path: RelativePath
    public let generatorVersion: String
    public let sourcePaths: [RelativePath]
}

public struct ModelLicense: Codable, Equatable, Sendable {
    public let checkpointLicense: String
    public let baseRepository: String
    public let baseRevision: String
    public let baseLicense: String
    public let baseAccess: String
    public let modelCardURL: URL
}

public struct ModelManifest: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let repository: String
    public let revision: String
    public let roles: [ModelRole]
    public let adapter: ModelAdapter
    public let preprocessingVersion: String
    public let quantization: String
    public let files: [ModelFile]
    public let generatedArtifacts: [GeneratedModelArtifact]
    public let license: ModelLicense
    public let evidenceURL: URL
    public let evidenceSHA256: String
    public let downloadByteCount: Int64
    public let weightByteCount: Int64
    /// Catalog membership is not evidence that the checkpoint executes correctly.
    public let runtimeValidation: String

    /// Shared by all roles. Kept relative to the one application-owned Models root.
    public var installationPath: RelativePath {
        get throws { try RelativePath("\(repository)/\(revision)") }
    }

    public func downloadURL(for file: ModelFile) throws -> URL {
        guard files.contains(file) else { throw ModelCatalogError.invalidManifest("File is outside this manifest") }
        try validate()
        return URL(string: "https://huggingface.co")!
            .appendingPathComponent(repository).appendingPathComponent("resolve")
            .appendingPathComponent(revision).appendingPathComponent(file.path.value)
    }

    public func snapshot(for role: ModelRole) throws -> ModelSnapshot {
        try validate()
        guard roles.contains(role) else { throw ModelCatalogError.invalidManifest("Unsupported processing role") }
        return ModelSnapshot(role: role, repository: repository, revision: revision,
            directory: try installationPath, preprocessingVersion: preprocessingVersion)
    }

    func validate() throws {
        func validComponent(_ value: String) -> Bool {
            !value.isEmpty && value != "." && value != ".." && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
            }
        }
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard validComponent(id), parts.count == 2, parts.allSatisfy({ validComponent(String($0)) && !$0.hasPrefix(".") }),
              ModelDigest.isHex(revision, length: 40), ModelDigest.isHex(evidenceSHA256, length: 64),
              !preprocessingVersion.isEmpty, !quantization.isEmpty, runtimeValidation == "pending",
              !roles.isEmpty, Set(roles).count == roles.count, Set(roles).isSubset(of: adapter.allowedRoles),
              !license.checkpointLicense.isEmpty, !license.baseLicense.isEmpty,
              ModelDigest.isHex(license.baseRevision, length: 40), ["public", "gated"].contains(license.baseAccess),
              license.modelCardURL.absoluteString == "https://huggingface.co/\(repository)/blob/\(revision)/README.md",
              evidenceURL.absoluteString == "https://huggingface.co/api/models/\(repository)/revision/\(revision)?blobs=true" else {
            throw ModelCatalogError.invalidManifest("Invalid identity, role, provenance or validation status for \(id)")
        }
        let names = files.map(\.path.value)
        guard !files.isEmpty, Set(names).count == names.count,
              Set(names.map { $0.lowercased() }).count == names.count,
              adapter.requiredFiles.isSubset(of: Set(names)) else {
            throw ModelCatalogError.invalidManifest("Missing or duplicate required files for \(id)")
        }
        var total: Int64 = 0, weights: Int64 = 0
        if adapter == .qwen3Text {
            let shardNames = names.filter { $0.hasSuffix(".safetensors") && !$0.contains("/") }
            // A checkpoint small enough for one file uses the unsharded name.
            let single = shardNames == ["model.safetensors"]
            let pattern = try NSRegularExpression(pattern: #"^model-([0-9]{5})-of-([0-9]{5})\.safetensors$"#)
            var indices: Set<Int> = [], counts: Set<Int> = []
            for name in shardNames where !single {
                let range = NSRange(name.startIndex..., in: name)
                guard let match = pattern.firstMatch(in: name, range: range),
                      let indexRange = Range(match.range(at: 1), in: name),
                      let countRange = Range(match.range(at: 2), in: name),
                      let index = Int(name[indexRange]), let count = Int(name[countRange]),
                      (1...128).contains(count), (1...count).contains(index) else {
                    throw ModelCatalogError.invalidManifest("Invalid text weight shard")
                }
                indices.insert(index); counts.insert(count)
            }
            guard single || (counts.first.map { count in counts.count == 1 && shardNames.count == count && indices == Set(1...count) } ?? false) else { throw ModelCatalogError.invalidManifest("Incomplete text weight shards") }
        }
        for file in files {
            try file.validate()
            let sum = total.addingReportingOverflow(file.byteCount)
            guard !sum.overflow else { throw ModelCatalogError.invalidManifest("File lengths overflow") }
            total = sum.partialValue
            if file.path.value.hasSuffix(".safetensors") { weights += file.byteCount }
        }
        guard total == downloadByteCount, weights > 0, weights == weightByteCount else {
            throw ModelCatalogError.invalidManifest("Inconsistent download/weight sizes for \(id)")
        }
        let generatedNames = generatedArtifacts.map(\.path.value)
        let allNames = names + generatedNames
        guard Set(allNames.map { $0.lowercased() }).count == allNames.count else {
            throw ModelCatalogError.invalidManifest("Generated and downloaded files overlap")
        }
        for name in allNames {
            guard !name.split(separator: "/").contains(where: { $0.lowercased().hasPrefix(".talktrack-") }) else {
                throw ModelCatalogError.invalidManifest("Model files collide with installation metadata")
            }
            guard !allNames.contains(where: { $0 != name && name.lowercased().hasPrefix($0.lowercased() + "/") }) else {
                throw ModelCatalogError.invalidManifest("File and directory paths collide")
            }
        }
        for generated in generatedArtifacts {
            guard generated.generatorVersion == preprocessingVersion, !generated.sourcePaths.isEmpty,
                  generated.sourcePaths.allSatisfy({ names.contains($0.value) }) else {
                throw ModelCatalogError.invalidManifest("Missing derived-file provenance")
            }
        }
        if adapter == .qwen3ASR || adapter == .qwen3Aligner {
            guard generatedArtifacts.count == 1, generatedNames == ["tokenizer.json"],
                  Set(generatedArtifacts[0].sourcePaths.map(\.value)) == ["vocab.json", "merges.txt", "tokenizer_config.json"] else {
                throw ModelCatalogError.invalidManifest("Qwen speech tokenizer preparation is missing")
            }
        } else if !generatedArtifacts.isEmpty {
            throw ModelCatalogError.invalidManifest("Unexpected generated model files")
        }
    }
}

public struct ModelCatalog: Sendable {
    private struct Envelope: Decodable { let schemaVersion: Int; let models: [ModelManifest]; let legacyModels: [ModelManifest]? }
    /// Every active installation; text models are alternatives for the same roles.
    public let models: [ModelManifest]
    public let legacyModels: [ModelManifest]
    /// The text model new jobs use: the user's choice, else the default for this Mac's memory.
    public private(set) var selectedTextModelID: String

    /// Text models that serve summaries, translation and spelling, largest first.
    public var textModels: [ModelManifest] {
        models.filter { $0.adapter == .qwen3Text }.sorted { $0.weightByteCount > $1.weightByteCount }
    }

    public init(data: Data, textModel: String? = nil,
                physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schemaVersion == 1 else { throw ModelCatalogError.unsupportedSchema(envelope.schemaVersion) }
        let models = envelope.models
        let legacy = envelope.legacyModels ?? []
        let all = models + legacy
        for model in all { try model.validate() }
        let textModels = models.filter { $0.adapter == .qwen3Text }
        let roles = models.filter { $0.adapter != .qwen3Text }.flatMap(\.roles)
        let textRoles: Set<ModelRole> = [.summary, .translation, .spelling]
        guard Set(models.map(\.id)).count == models.count,
              Set(try models.map { try $0.installationPath.value.lowercased() }).count == models.count,
              roles.count == Set(roles).count, Set(roles).union(textRoles) == Set(ModelRole.allCases),
              Set(roles).isDisjoint(with: textRoles) else {
            throw ModelCatalogError.invalidManifest("Catalog must assign every role exactly once")
        }
        guard !textModels.isEmpty, textModels.allSatisfy({ Set($0.roles) == textRoles }) else {
            throw ModelCatalogError.invalidManifest("Text roles must share one installation")
        }
        guard legacy.count <= 1, legacy.allSatisfy({ $0.adapter == .qwen3Text &&
            Set($0.roles) == textRoles }),
            Set(all.map(\.id)).count == all.count,
            Set(try all.map { try $0.installationPath.value.lowercased() }).count == all.count else {
            throw ModelCatalogError.invalidManifest("Invalid legacy model catalog")
        }
        self.models = models
        self.legacyModels = legacy
        selectedTextModelID = ""
        selectedTextModelID = Self.resolve(textModel, among: self.textModels, physicalMemory: physicalMemory)
    }

    /// The installed text model is chosen by memory unless the user picked one:
    /// the largest model from 32 GiB, the smallest below.
    public static let largeTextModelMemory: UInt64 = 32 << 30

    public static func defaultTextModel(among textModels: [ModelManifest], physicalMemory: UInt64) -> ModelManifest? {
        let sorted = textModels.sorted { $0.weightByteCount > $1.weightByteCount }
        return physicalMemory >= largeTextModelMemory ? sorted.first : sorted.last
    }

    private static func resolve(_ id: String?, among textModels: [ModelManifest], physicalMemory: UInt64) -> String {
        if let id, textModels.contains(where: { $0.id == id }) { return id }
        return defaultTextModel(among: textModels, physicalMemory: physicalMemory)?.id ?? ""
    }

    /// The same catalog with another text model for new jobs; an unknown id
    /// (for example from an older release) falls back to the memory default.
    public func selecting(textModel id: String?, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> ModelCatalog {
        var copy = self
        copy.selectedTextModelID = Self.resolve(id, among: textModels, physicalMemory: physicalMemory)
        return copy
    }

    /// The catalog with the text model saved in preferences.
    public static func bundled(in defaults: UserDefaults = .standard) throws -> ModelCatalog {
        guard let url = Bundle.module.url(forResource: "ModelCatalog", withExtension: "json") else {
            throw ModelCatalogError.missingResource
        }
        return try ModelCatalog(data: Data(contentsOf: url), textModel: ProcessingPreferences.textModel(in: defaults))
    }

    /// An active installation by its catalog id.
    public func model(id: String) throws -> ModelManifest {
        guard let model = models.first(where: { $0.id == id }) else {
            throw ModelCatalogError.invalidManifest("Unknown model \(id)")
        }
        return model
    }

    public func model(for role: ModelRole) throws -> ModelManifest {
        if role.isTextRole { return try model(id: selectedTextModelID) }
        guard let model = models.first(where: { $0.roles.contains(role) }) else {
            throw ModelCatalogError.invalidManifest("No model for \(role.rawValue)")
        }
        return model
    }

    /// Exact immutable matching, including retained models; never substitute
    /// today's selected model into an older job.
    public func model(for snapshot: ModelSnapshot) throws -> ModelManifest {
        guard let model = try (models + legacyModels).first(where: {
            guard $0.roles.contains(snapshot.role) else { return false }
            return try $0.snapshot(for: snapshot.role) == snapshot
        }) else { throw ModelCatalogError.invalidManifest("The immutable model snapshot is unavailable") }
        return model
    }
}
