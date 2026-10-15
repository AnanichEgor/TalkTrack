import Foundation

struct ModelHTTPResponse: Sendable {
    let status: Int
    let contentLength: Int64?
    let contentRange: String?
    let etag: String?
}

protocol ModelDownloadTransport: Sendable {
    func stream(_ request: URLRequest,
                response: @escaping @Sendable (ModelHTTPResponse) async throws -> Void,
                data: @escaping @Sendable (Data) async throws -> Void) async throws
}

/// Ephemeral data streaming: URLSession never creates a download temp file or
/// shared disk cache. The consumer writes only through the Models-root service.
final class URLSessionModelTransport: ModelDownloadTransport, Sendable {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }

    func stream(_ request: URLRequest,
                response: @escaping @Sendable (ModelHTTPResponse) async throws -> Void,
                data: @escaping @Sendable (Data) async throws -> Void) async throws {
        let (bytes, raw) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = raw as? HTTPURLResponse, http.url?.scheme == "https" else { throw ModelDownloadError.invalidResponse }
        try await withTaskCancellationHandler {
            try await response(ModelHTTPResponse(status: http.statusCode,
                contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                etag: http.value(forHTTPHeaderField: "ETag")))
            var chunk = Data()
            chunk.reserveCapacity(65536)
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == 65536 {
                    try Task.checkCancellation()
                    try await data(chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            if !chunk.isEmpty { try await data(chunk) }
        } onCancel: { bytes.task.cancel() }
    }
}
