import Foundation
import TalkTrackAudio
import TalkTrackDomain

/// What the application's inference runtime provides for live text during one
/// recording. `begin` takes the runtime's capture lease, which cancels the
/// active background operation and unloads resident job and dictation models.
public struct LiveCaptureHost: Sendable {
    public let begin: @Sendable () async throws -> LiveCaptureLease
    public init(begin: @escaping @Sendable () async throws -> LiveCaptureLease) { self.begin = begin }
}

/// One capture lease: builds the recording's live session in its lane and
/// releases the lease (unloading the live models) at the end.
public struct LiveCaptureLease: Sendable {
    public let makeSession: @Sendable (_ meetingID: UUID, _ recordingID: UUID, _ options: LiveTranscriptionOptions)
        async throws -> LiveTranscriptionSession
    public let end: @Sendable () async -> Void
    public init(makeSession: @escaping @Sendable (UUID, UUID, LiveTranscriptionOptions) async throws -> LiveTranscriptionSession,
                end: @escaping @Sendable () async -> Void) {
        self.makeSession = makeSession; self.end = end
    }
}

/// Owns the live session of one recording (design D1). The recorder offers
/// normalized fragments to `mailbox` without awaiting anything here; this actor
/// moves them into the session, mirrors Pause/Resume, saves the draft every
/// `saveInterval` and at Pause and Stop, and releases the capture lease.
/// Capture never depends on it: missing models or failures only change the
/// session's state, and audio is saved either way.
public actor LiveCaptureBridge {
    public nonisolated let mailbox = LiveInferenceMailbox<LiveCaptureFragment>(capacity: 32)
    public let options: LiveTranscriptionOptions
    public private(set) var session: LiveTranscriptionSession?
    private let host: LiveCaptureHost?
    private let save: (@Sendable (LiveDraft) async -> Void)?
    private let saveInterval: Duration
    private var lease: LiveCaptureLease?
    private var consumer: Task<Void, Never>?
    private var saver: Task<Void, Never>?
    private var savedCount = -1
    private var ended = false
    private var draftID = UUID()
    private var meetingID: UUID?, recordingID: UUID?

    public init(host: LiveCaptureHost?, options: LiveTranscriptionOptions,
                saveInterval: Duration = .seconds(10), save: (@Sendable (LiveDraft) async -> Void)? = nil) {
        self.host = host; self.options = options; self.saveInterval = saveInterval; self.save = save
    }

    /// Takes the capture lease before the recorder starts, so live models load
    /// while background work is paused. Without a host, or when live text is
    /// off, nothing is taken. A failure leaves the session unavailable.
    public func begin() async {
        guard options.enabled, let host, lease == nil, !ended else { return }
        lease = try? await host.begin()
    }

    /// Builds the session for the started recording and starts consuming.
    @discardableResult
    public func attach(meetingID: UUID, recordingID: UUID) async -> LiveTranscriptionSession? {
        guard session == nil, !ended else { return session }
        self.meetingID = meetingID; self.recordingID = recordingID
        var value: LiveTranscriptionSession?
        if let lease { value = try? await lease.makeSession(meetingID, recordingID, options) }
        // Off or unavailable: a model-less session still reports why.
        if value == nil { value = try? LiveTranscriptionSession(meetingID: meetingID, recordingID: recordingID, options: options) }
        guard let session = value else { return nil }
        self.session = session
        let mailbox = mailbox
        consumer = Task { await Self.consume(mailbox, into: session) }
        if save != nil, options.enabled {
            let interval = saveInterval
            saver = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { return }
                    await self?.saveDraft(complete: false)
                }
            }
        }
        return session
    }

    /// A gap inside one capture interval means the handoff replaced fragments.
    private static func consume(_ mailbox: LiveInferenceMailbox<LiveCaptureFragment>, into session: LiveTranscriptionSession) async {
        var ends: [AudioTrack: (boundary: UUID, end: UInt64)] = [:]
        for await fragment in mailbox.requests {
            if let last = ends[fragment.track], last.boundary == fragment.boundaryID, fragment.activeStartFrame > last.end {
                await session.noteSkippedAudio()
            }
            ends[fragment.track] = (fragment.boundaryID, fragment.activeStartFrame + UInt64(fragment.samples.count))
            // The session takes at most 100 ms per append; the recorder hands
            // over larger normalized blocks. Invalid audio only affects live text.
            var offset = 0
            while offset < fragment.samples.count {
                let count = min(4800, fragment.samples.count - offset)
                try? await session.append(track: fragment.track, samples: Array(fragment.samples[offset..<(offset + count)]),
                    activeStartFrame: fragment.activeStartFrame + UInt64(offset), day: fragment.day,
                    wallClockStart: fragment.wallClockStart.addingTimeInterval(Double(offset) / 48_000), boundaryID: fragment.boundaryID)
                offset += count
            }
        }
    }

    public func pause() async {
        await session?.pause()
        await saveDraft(complete: false)
    }

    public func resume() async { await session?.resume() }

    /// Stop: drains the bounded tail, saves the complete draft, then releases
    /// the lease. Interrupted or abandoned stops use `cancel()` instead.
    public func finish() async {
        guard !ended else { return }
        ended = true
        saver?.cancel()
        mailbox.finish()
        await consumer?.value
        await session?.finish()
        await saveDraft(complete: true)
        await endLease()
    }

    /// Does not wait for in-flight inference; keeps the rows published so far.
    public func cancel() async {
        guard !ended else { return }
        ended = true
        saver?.cancel(); consumer?.cancel()
        mailbox.finish()
        await session?.cancel()
        await saveDraft(complete: true)
        await endLease()
    }

    private func endLease() async {
        guard let lease else { return }
        self.lease = nil
        await lease.end()
    }

    /// Writes only when rows changed since the last save; a complete save always writes.
    private func saveDraft(complete: Bool) async {
        guard let save, options.enabled, let session, let meetingID, let recordingID else { return }
        let rows = await session.orderedUtterances
        let count = await session.publishedCount
        guard complete || count != savedCount else { return }
        guard !rows.isEmpty || complete && savedCount > 0 else { return }
        savedCount = count
        await save(LiveDraft(id: draftID, meetingID: meetingID, recordingID: recordingID, utterances: rows,
                             savedAt: Date(), complete: complete))
        draftID = UUID()
    }
}

/// The saved draft of one recording: the live session's rows, kept as the
/// recording's live revision until a final transcript replaces it.
public struct LiveDraft: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let recordingID: UUID
    public let utterances: [LiveUtterance]
    public let savedAt: Date
    /// Saved after the session finished (Stop): rows no longer change.
    public let complete: Bool

    public init(id: UUID = UUID(), meetingID: UUID, recordingID: UUID, utterances: [LiveUtterance],
                savedAt: Date = Date(), complete: Bool) {
        self.id = id; self.meetingID = meetingID; self.recordingID = recordingID
        self.utterances = utterances; self.savedAt = savedAt; self.complete = complete
    }
}
