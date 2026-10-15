import CryptoKit
import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

private enum DownloadFixtureError: Error { case preparation }

private actor FixtureModelTransport: ModelDownloadTransport {
    enum Behavior { case normal, interrupted, changedETag, wrongRange, corrupt, truncated, paused, ignoresRange }
    private var behavior: Behavior
    private let content: [String: Data]
    private(set) var requests: [URLRequest] = []
    private var counts: [String: Int] = [:]
    private var activeCount = 0
    private(set) var peakCount = 0
    private(set) var pausedAfterWrite = false

    init(content: [String: Data], behavior: Behavior = .normal) { self.content = content; self.behavior = behavior }
    func setBehavior(_ behavior: Behavior) { self.behavior = behavior }

    func stream(_ request: URLRequest,
                response: @escaping @Sendable (ModelHTTPResponse) async throws -> Void,
                data: @escaping @Sendable (Data) async throws -> Void) async throws {
        requests.append(request)
        let name = request.url!.lastPathComponent
        let body = content[name]!
        counts[name, default: 0] += 1
        let attempt = counts[name]!
        activeCount += 1
        peakCount = max(peakCount, activeCount)
        defer { activeCount -= 1 }
        let range = request.value(forHTTPHeaderField: "Range")
        let requestedOffset = range.flatMap { Int($0.dropFirst(6).dropLast()) } ?? 0
        let ignoresRange = behavior == .ignoresRange && requestedOffset > 0
        let offset = ignoresRange ? 0 : requestedOffset
        let isWeights = name == "model.safetensors"
        let changed = behavior == .changedETag && attempt > 1 && isWeights
        let wrong = behavior == .wrongRange && offset > 0
        try await response(ModelHTTPResponse(status: offset > 0 ? 206 : 200,
            contentLength: Int64(body.count - offset),
            contentRange: offset > 0 ? "bytes \(offset + (wrong ? 1 : 0))-\(body.count - 1)/\(body.count)" : nil,
            etag: changed ? "\"two\"" : "\"one\""))
        // Give independent transfers a chance to overlap, as a real stream does.
        try await Task.sleep(for: .milliseconds(10))
        let interrupt = isWeights && attempt == 1 && [.interrupted, .changedETag, .wrongRange, .ignoresRange].contains(behavior)
        if interrupt || (isWeights && behavior == .paused) {
            try await data(body.prefix(body.count / 2))
            if behavior == .paused {
                pausedAfterWrite = true
                try await Task.sleep(for: .seconds(30))
            }
            throw URLError(.networkConnectionLost)
        }
        var sent = Data(body.dropFirst(offset))
        if isWeights && behavior == .corrupt { sent[0] ^= 1 }
        if isWeights && behavior == .truncated { sent.removeLast() }
        try await data(sent)
    }
}

private actor PreparationProbe {
    private(set) var count = 0
    func prepared() { count += 1 }
}

@Suite struct ModelDownloadTests {
    private func fixture() throws -> (ModelManifest, [String: Data]) {
        let original = try ModelCatalog.bundled().model(for: .segmentation)
        let bodies = ["config.json": Data(#"{"fixture":true}"#.utf8),
                      "README.md": Data("Local deterministic download fixture".utf8),
                      "model.safetensors": Data("This is synthetic fixture data, not model weights.".utf8)]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["files"] = bodies.sorted(by: { $0.key < $1.key }).map { name, data in
            ["path": name, "byteCount": data.count,
             "digest": ["algorithm": "sha256", "value": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]] as [String: Any]
        }
        json["downloadByteCount"] = bodies.values.reduce(0) { $0 + $1.count }
        json["weightByteCount"] = bodies["model.safetensors"]!.count
        return (try JSONDecoder().decode(ModelManifest.self, from: JSONSerialization.data(withJSONObject: json)), bodies)
    }

    @Test func duplicateRequestsShareBoundedTransfersAndPreparation() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (manifest, bodies) = try fixture()
        let files = ModelDownloadFiles(testRoot: folder.url.appendingPathComponent("Models"))
        let transport = FixtureModelTransport(content: bodies)
        let coordinator = ModelDownloadCoordinator(files: files, transport: transport)
        let probe = PreparationProbe()
        let prepare: ModelDownloadCoordinator.Preparation = { _, context in
            let config = try await context.read(RelativePath("config.json"))
            #expect(config == bodies["config.json"])
            await probe.prepared()
        }
        async let first: Void = coordinator.download(manifest, prepare: prepare)
        async let second: Void = coordinator.download(manifest, prepare: prepare)
        _ = try await (first, second)
        #expect(await transport.requests.count == 3)
        #expect(await transport.peakCount <= 2)
        #expect(await transport.peakCount == 2)
        #expect(await probe.count == 1)
        #expect(try await files.isReady(manifest))
        let status = try #require(await coordinator.status(manifest))
        #expect(status.phase == .ready)
        #expect(status.completedFiles == 3)
        #expect(status.completedBytes == manifest.downloadByteCount)
    }

    @Test(arguments: ["interrupted", "changedETag", "ignoresRange"])
    func resumesOrRestartsWithoutMixingVersions(_ behavior: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (manifest, bodies) = try fixture()
        let files = ModelDownloadFiles(testRoot: folder.url.appendingPathComponent("Models"))
        let mode: FixtureModelTransport.Behavior = behavior == "interrupted" ? .interrupted : behavior == "changedETag" ? .changedETag : .ignoresRange
        let transport = FixtureModelTransport(content: bodies, behavior: mode)
        let coordinator = ModelDownloadCoordinator(files: files, transport: transport)
        try await coordinator.download(manifest) { _, _ in }
        let requests = await transport.requests.filter { $0.url?.lastPathComponent == "model.safetensors" }
        #expect(requests.count == (behavior == "changedETag" ? 3 : 2))
        #expect(requests[1].value(forHTTPHeaderField: "Range") == "bytes=\(bodies["model.safetensors"]!.count / 2)-")
        #expect(requests[1].value(forHTTPHeaderField: "If-Range") == "\"one\"")
        if behavior == "changedETag" { #expect(requests[2].value(forHTTPHeaderField: "Range") == nil) }
        #expect(try await files.isReady(manifest))
    }

    @Test(arguments: ["corrupt", "truncated", "wrongRange"])
    func badResponsesNeverBecomeReady(_ behavior: String) async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (manifest, bodies) = try fixture()
        let files = ModelDownloadFiles(testRoot: folder.url.appendingPathComponent("Models"))
        let mode: FixtureModelTransport.Behavior = behavior == "corrupt" ? .corrupt : behavior == "truncated" ? .truncated : .wrongRange
        let transport = FixtureModelTransport(content: bodies, behavior: mode)
        let coordinator = ModelDownloadCoordinator(files: files, transport: transport)
        await #expect(throws: (any Error).self) { try await coordinator.download(manifest) { _, _ in } }
        #expect(try await !files.isReady(manifest))
        #expect(try await coordinator.status(manifest)?.phase == .failed)
        await transport.setBehavior(.normal)
        try await coordinator.download(manifest) { _, _ in }
        #expect(try await files.isReady(manifest))
    }

    @Test func cancellationWaitsForWritesAndRetainsResumablePartial() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (manifest, bodies) = try fixture()
        let files = ModelDownloadFiles(testRoot: folder.url.appendingPathComponent("Models"))
        let transport = FixtureModelTransport(content: bodies, behavior: .paused)
        let coordinator = ModelDownloadCoordinator(files: files, transport: transport)
        let task = Task { try await coordinator.download(manifest) { _, _ in } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await transport.pausedAfterWrite), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await transport.pausedAfterWrite)
        await #expect(throws: ModelDownloadError.busy) { try await files.remove(manifest) }
        try await coordinator.cancelAndWait(manifest)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await coordinator.status(manifest)?.phase == .paused)
        #expect(try await !files.isReady(manifest))
        await transport.setBehavior(.normal)
        try await coordinator.download(manifest) { _, _ in }
        #expect(await transport.requests.contains { $0.value(forHTTPHeaderField: "Range") != nil })
        #expect(try await files.isReady(manifest))
    }

    @Test func preparationFailureKeepsVerifiedFilesWithoutReadyMarker() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (manifest, bodies) = try fixture()
        let files = ModelDownloadFiles(testRoot: folder.url.appendingPathComponent("Models"))
        let transport = FixtureModelTransport(content: bodies)
        let coordinator = ModelDownloadCoordinator(files: files, transport: transport)
        await #expect(throws: DownloadFixtureError.self) {
            try await coordinator.download(manifest) { _, _ in throw DownloadFixtureError.preparation }
        }
        #expect(try await !files.isReady(manifest))
        let requestsBeforeRetry = await transport.requests.count
        try await coordinator.download(manifest) { _, _ in }
        #expect(await transport.requests.count == requestsBeforeRetry)
        #expect(try await files.isReady(manifest))
        try await coordinator.remove(manifest)
        #expect(try await !files.isReady(manifest))
    }

    @Test func spaceAndManifestFailuresDoNotStartNetworkRequests() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let (manifest, bodies) = try fixture()
        let files = ModelDownloadFiles(testRoot: folder.url.appendingPathComponent("Models"), availableBytes: 0)
        let transport = FixtureModelTransport(content: bodies)
        let coordinator = ModelDownloadCoordinator(files: files, transport: transport)
        await #expect(throws: ModelDownloadError.insufficientSpace) { try await coordinator.download(manifest) { _, _ in } }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        json["files"] = []
        let invalid = try JSONDecoder().decode(ModelManifest.self, from: JSONSerialization.data(withJSONObject: json))
        await #expect(throws: ModelCatalogError.self) { try await coordinator.download(invalid) { _, _ in } }
        #expect(await transport.requests.isEmpty)
    }
}
