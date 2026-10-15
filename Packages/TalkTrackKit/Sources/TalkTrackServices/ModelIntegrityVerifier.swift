import CryptoKit
import Foundation

/// Verifies an already-open file supplied by the confined model store. This
/// actor never opens a path or downloads data, and does not grant readiness.
/// The caller must keep its file lease until verification/loader preparation ends.
public actor ModelIntegrityVerifier {
    public init() {}

    public func verify(_ file: ModelFile, reading handle: FileHandle) throws {
        try file.validate()
        try handle.seek(toOffset: 0)
        var sha256 = SHA256()
        var gitBlob = Insecure.SHA1()
        if file.digest.algorithm == .gitBlobSHA1 {
            // Git object IDs include the blob header; raw SHA-1 is different.
            gitBlob.update(data: Data("blob \(file.byteCount)\0".utf8))
        }
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            // FileHandle bridges through autoreleased Foundation buffers on macOS.
            // An actor's long synchronous loop has no guaranteed pool drain;
            // bound those temporary buffers to one block, even for 20 GB models.
            let consumed = try autoreleasepool {
                guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
                guard Int64(data.count) <= file.byteCount - count else {
                    throw ModelCatalogError.sizeMismatch(file.path.value)
                }
                count += Int64(data.count)
                switch file.digest.algorithm {
                case .sha256: sha256.update(data: data)
                case .gitBlobSHA1: gitBlob.update(data: data)
                }
                return true
            }
            if !consumed { break }
        }
        guard count == file.byteCount else { throw ModelCatalogError.sizeMismatch(file.path.value) }
        let digest: String
        switch file.digest.algorithm {
        case .sha256: digest = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        case .gitBlobSHA1: digest = gitBlob.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard digest == file.digest.value else { throw ModelCatalogError.digestMismatch(file.path.value) }
    }
}
