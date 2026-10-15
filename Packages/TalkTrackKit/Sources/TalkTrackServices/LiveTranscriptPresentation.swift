import Foundation
import Observation
import TalkTrackDomain

/// Small main-actor projection. Model invocation, PCM conversion and capture
/// remain in services. Coalesced notifications refresh the complete text snapshot.
@MainActor @Observable public final class LiveTranscriptPresentation {
    public private(set) var state: LiveTranscriptionState = .preparing
    public private(set) var rows: [LiveUtterance] = []
    public private(set) var lastFailureMessage: String?
    public init() {}
    public func observe(_ session: LiveTranscriptionSession,
                        onPublication: (@MainActor @Sendable (LiveUtterance) -> Void)? = nil) async {
        for await event in session.events {
            guard !Task.isCancelled else { return }
            lastFailureMessage = await session.lastFailureMessage
            switch event {
            case let .state(value): state = value
            case let .utterance(value):
                state = await session.state
                rows = await session.orderedUtterances
                onPublication?(value)
            }
        }
        state = await session.state
        rows = await session.orderedUtterances
        lastFailureMessage = await session.lastFailureMessage
    }
}
