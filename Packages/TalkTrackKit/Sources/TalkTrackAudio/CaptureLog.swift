import Foundation
import os

/// Capture lifecycle diagnostics in the unified log (design D1). Entries carry
/// only identifiers, phases, sources, fixed operation keys, durations and OSStatus
/// codes as public values. Free-text errors can name devices, so they are private
/// (redacted in collected logs). Meeting titles, transcript, note and dictation text
/// never reach a log call. Lifecycle events use the default level so they persist;
/// nothing is logged per audio packet.
public enum CaptureLog {
    public static let subsystem = "local.talktrack.app"
    /// Coordinator and drivers.
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    /// Recorder phases, Stop and Quit outcomes.
    public static let recorder = Logger(subsystem: subsystem, category: "recorder")

    /// Logs `begin`, then `end`, `timeout`, `cancelled` or `failed` with the duration
    /// in milliseconds. An operation that never returns stays visible as a `begin`
    /// without an `end`.
    public static func timed<T>(_ operation: String, run: UUID? = nil, logger: Logger = capture,
                                isolation: isolated (any Actor)? = #isolation,
                                _ body: () async throws -> T) async throws -> T {
        let tag = Self.id(run)
        logger.log("\(operation, privacy: .public) begin run=\(tag, privacy: .public)")
        let start = ContinuousClock.now
        do {
            let value = try await body()
            logger.log("\(operation, privacy: .public) end run=\(tag, privacy: .public) ms=\(milliseconds(since: start), privacy: .public)")
            return value
        } catch {
            failure(operation, run: run, ms: milliseconds(since: start), error: error, logger: logger)
            throw error
        }
    }

    public static func failure(_ operation: String, run: UUID?, ms: Int, error: Error, logger: Logger = capture) {
        let tag = Self.id(run)
        let outcome = switch error {
        case HALWorkerError.timedOut: "timeout"
        case HALWorkerError.busy: "refused"
        case is CancellationError: "cancelled"
        default: "failed"
        }
        let status = (error as? AudioCaptureError)?.status.map { String($0) } ?? "-"
        logger.error("\(operation, privacy: .public) \(outcome, privacy: .public) run=\(tag, privacy: .public) ms=\(ms, privacy: .public) status=\(status, privacy: .public) error=\(String(describing: error), privacy: .private)")
    }

    public static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// A short public form of an identifier; enough to follow one recording.
    public static func id(_ value: UUID?) -> String { value.map { String($0.uuidString.prefix(8)) } ?? "-" }
}
