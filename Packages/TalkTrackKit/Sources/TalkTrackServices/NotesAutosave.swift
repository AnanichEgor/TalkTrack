import Foundation
import TalkTrackDomain

public actor NotesAutosave {
    private let store: SessionStore
    private let delay: Duration
    private var pending: [UUID: NotesRevision] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var errors: [UUID: String] = [:]

    public init(store: SessionStore, delay: Duration = .milliseconds(350)) {
        self.store = store
        self.delay = delay
    }

    public func edit(meetingID: UUID, text: String, format: NotesFormat? = nil) async throws {
        let revision = NotesRevision(meetingID: meetingID, text: text, format: format)
        pending[meetingID] = revision
        timers[meetingID]?.cancel()
        do {
            try await store.stageNotes(revision)
            guard pending[meetingID]?.id == revision.id else { return }
            errors[meetingID] = nil
            timers[meetingID] = Task { [weak self, delay] in
                do {
                    try await Task.sleep(for: delay)
                    try await self?.flush(meetingID: meetingID)
                } catch { /* flush retains pending text and exposes its error */ }
            }
        } catch {
            errors[meetingID] = error.localizedDescription
            throw error
        }
    }

    public func recover(meetingID: UUID) async throws -> String? {
        try await recoverRevision(meetingID: meetingID)?.text
    }

    /// The unsaved revision, with its format, if one is pending.
    public func recoverRevision(meetingID: UUID) async throws -> NotesRevision? {
        if let revision = pending[meetingID] { return revision }
        if let revision = try await store.pendingNotes(meetingID: meetingID) {
            pending[meetingID] = revision
            return revision
        }
        return nil
    }

    public func lastError(meetingID: UUID) -> String? { errors[meetingID] }

    public func flush(meetingID: UUID) async throws {
        timers.removeValue(forKey: meetingID)?.cancel()
        while let revision = pending[meetingID] {
            do {
                try await store.stageNotes(revision)
                try await store.commitNotes(revision)
                if pending[meetingID]?.id == revision.id {
                    pending[meetingID] = nil
                    errors[meetingID] = nil
                }
            } catch {
                errors[meetingID] = error.localizedDescription
                throw error
            }
        }
    }

    public func flushForNavigation(leaving meetingID: UUID) async throws { try await flush(meetingID: meetingID) }

    public func flushForQuit() async throws {
        for id in Array(pending.keys) { try await flush(meetingID: id) }
    }
}
