/// One consumer per mailbox, normally one mailbox per source. The recording
/// worker offers bounded window references without awaiting model work. A slow
/// consumer replaces only obsolete live requests; durable audio has its own
/// non-dropping path. The caller reports .replacedObsolete as delayed live text.
public final class LiveInferenceMailbox<Request: Sendable>: Sendable {
    public enum OfferResult: Equatable, Sendable { case accepted, replacedObsolete, closed }
    public let requests: AsyncStream<Request>
    private let continuation: AsyncStream<Request>.Continuation

    public init(capacity: Int = 2) {
        precondition((1...32).contains(capacity))
        let pair = AsyncStream<Request>.makeStream(bufferingPolicy: .bufferingNewest(capacity))
        requests = pair.stream
        continuation = pair.continuation
    }

    @discardableResult public func offer(_ request: Request) -> OfferResult {
        switch continuation.yield(request) {
        case .enqueued: .accepted
        case .dropped: .replacedObsolete
        case .terminated: .closed
        @unknown default: .closed
        }
    }

    public func finish() { continuation.finish() }
    deinit { continuation.finish() }
}
