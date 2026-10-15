import Dispatch
import Foundation
import TalkTrackAudio
import TalkTrackDomain

public struct LiveTranscriptionOptions: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let language: MeetingLanguage
    public init(enabled: Bool = true, language: MeetingLanguage = .auto) {
        self.enabled = enabled; self.language = language
    }
}
public struct LiveASRResult: Sendable {
    public let text: String
    public let language: String?
    public init(text: String, language: String? = nil) { self.text = text; self.language = language }
}
public protocol LiveTranscriptionInference: SystemSpeakerInference {
    func liveText(_ model: ModelSnapshot, samples: [Float], language: MeetingLanguage) async throws -> LiveASRResult
}
public enum LiveTranscriptionState: Equatable, Sendable {
    case preparing, disabled, ready, paused, stopped
    case unavailable
    case delayed(skippedWindows: Int)
    case failed(track: AudioTrack, message: String)
    public var message: String {
        switch self {
        case .preparing: "Preparing live transcription. Audio recording remains available."
        case .disabled: "Live transcription is off. Audio is still saved."
        case .ready: "Live transcript · provisional text and speakers"
        case .paused: "Live transcription is paused."
        case .stopped: "Live transcription stopped. Final processing uses the saved audio."
        case .unavailable: "Live models are unavailable. Install the live transcription and speaker models in Settings. Audio is still saved."
        case .delayed: "Live text is delayed. Final processing will include the saved audio skipped by live processing."
        case let .failed(track, message): "Live \(track.rawValue) transcription failed: \(message) Audio is still saved; the next window will retry."
        }
    }
}
public struct ProvisionalSpeaker: Codable, Equatable, Sendable {
    public let id: UUID
    public let number: UInt
}
/// Coarse window timing, never forced-aligned word timing. Multiple candidate
/// speakers express uncertainty in mixed audio rather than inventing ownership.
public struct LiveUtterance: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let recordingID: UUID
    public let day: RecordingDay
    public let track: AudioTrack
    public let context: MediaInterval
    public let interval: MediaInterval
    public let wallClockStart: Date
    public let speakers: [ProvisionalSpeaker]
    public let text: String
    public let detectedLanguage: String?
    public var kind: TranscriptKind { .live }
    public var speakerLabel: String {
        if track == .microphone { return "You" }
        return speakers.isEmpty ? "Unknown speaker" : speakers.map { "Voice\($0.number)" }.joined(separator: " / ")
    }
}
public enum LiveTranscriptionEvent: Sendable {
    case state(LiveTranscriptionState)
    case utterance(LiveUtterance)
}
public enum LiveTranscriptionError: Error, Equatable, LocalizedError {
    case invalidPacket, invalidModel, stopped
    public var errorDescription: String? {
        switch self {
        case .invalidPacket: "Live audio or model text is invalid or out of source order. Final processing can use the saved audio."
        case .invalidModel: "Live models are missing or incompatible. Check the selected models in Settings."
        case .stopped: "This live transcription session has stopped. Start a new recording."
        }
    }
}

private final class LiveTranscriptExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "local.talktrack.live-transcription", qos: .userInitiated)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}
private struct LiveRequest: Sendable {
    let sequence: UInt64
    let boundaryID: UUID
    let fragmentID: UUID
    let window: RecordingAudioWindow
}

/// Feed normalized mono 48 kHz packets from the recording worker, independently
/// of the durable writer. No inference is awaited by append. At most one active
/// and one newest pending window per track are retained. The audio callback must
/// continue using the preallocated capture handoff, never call this actor.
public actor LiveTranscriptionSession {
    private nonisolated let executor = LiveTranscriptExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    public nonisolated let events: AsyncStream<LiveTranscriptionEvent>
    private let continuation: AsyncStream<LiveTranscriptionEvent>.Continuation
    public let options: LiveTranscriptionOptions
    private let meetingID: UUID, recordingID: UUID
    private let asr: ModelSnapshot?
    private let inference: (any LiveTranscriptionInference)?
    private let diarization: SystemDiarizationSession?
    private var speakerEnd = MediaTime.zero
    private var builders: [AudioTrack: LiveWindowBuilder] = [:]
    private var sourceEnds: [AudioTrack: UInt64] = [:]
    private var pending: [AudioTrack: LiveRequest] = [:]
    private var previous: [AudioTrack: (boundary: UUID, utterance: LiveUtterance, rawText: String)] = [:]
    private var worker: Task<Void, Never>?
    private var sequence: UInt64 = 0, generation: UInt64 = 0
    private var skipped = 0, stopped = false, paused = false
    public private(set) var state: LiveTranscriptionState
    public private(set) var lastFailureMessage: String?
    public private(set) var publishedCount = 0
    /// Text metadata can grow with the meeting; PCM and inference queues cannot.
    /// A coalescing UI reads this snapshot after an event to recover slow delivery.
    public private(set) var utterances: [LiveUtterance] = []
    public var orderedUtterances: [LiveUtterance] {
        utterances.sorted {
            if $0.wallClockStart != $1.wallClockStart { return $0.wallClockStart < $1.wallClockStart }
            if $0.track != $1.track { return $0.track.rawValue < $1.track.rawValue }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    public var pendingWindowCount: Int { pending.count }
    public var retainedSourceFrames: Int { builders.values.reduce(0) { $0 + $1.samples.count } }

    public init(meetingID: UUID, recordingID: UUID, options: LiveTranscriptionOptions,
                asr: ModelSnapshot? = nil, segmentation: ModelSnapshot? = nil, embedding: ModelSnapshot? = nil,
                inference: (any LiveTranscriptionInference)? = nil) throws {
        self.meetingID = meetingID; self.recordingID = recordingID; self.options = options
        let stream = AsyncStream<LiveTranscriptionEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        events = stream.stream; continuation = stream.continuation
        if let asr, asr.role != .liveASR { throw LiveTranscriptionError.invalidModel }
        self.asr = asr; self.inference = inference
        if let segmentation, let embedding, let inference {
            diarization = try SystemDiarizationSession(meetingID: meetingID, segmentation: segmentation,
                embedding: embedding, inference: inference)
        } else { diarization = nil }
        let initial: LiveTranscriptionState = !options.enabled ? .disabled :
            (asr == nil || segmentation == nil || embedding == nil || inference == nil ? .unavailable : .ready)
        state = initial
        stream.continuation.yield(.state(initial))
    }

    /// boundaryID is the capture interval's ID; changes on Resume, midnight or
    /// route discontinuity. Active frames exclude pauses, wall time does not.
    public func append(track: AudioTrack, samples: [Float], activeStartFrame: UInt64,
                       day: RecordingDay, wallClockStart: Date, boundaryID: UUID) throws {
        guard !stopped else { throw LiveTranscriptionError.stopped }
        guard options.enabled, asr != nil, diarization != nil, !paused else { return }
        if let end = sourceEnds[track], activeStartFrame < end { throw LiveTranscriptionError.invalidPacket }
        var builder = builders[track] ?? LiveWindowBuilder()
        let requests = try builder.append(samples, start: activeStartFrame, day: day,
            wallClock: wallClockStart, boundary: boundaryID, meetingID: meetingID, recordingID: recordingID, track: track)
        builders[track] = builder
        sourceEnds[track] = activeStartFrame + UInt64(samples.count)
        for request in requests { enqueue(request) }
    }
    public func pause() {
        guard !stopped, options.enabled, asr != nil, diarization != nil else { return }
        flushBuilders(); paused = true
        setState(.paused)
    }
    public func resume() {
        guard !stopped, paused else { return }
        paused = false; builders.removeAll(); previous.removeAll()
        setState(skipped == 0 ? .ready : .delayed(skippedWindows: skipped))
    }
    /// Drain the bounded tail before releasing the runtime's capture lease.
    public func finish() async {
        guard !stopped else { await worker?.value; return }
        stopped = true; flushBuilders()
        await worker?.value
        builders.removeAll(); previous.removeAll()
        setState(.stopped); continuation.finish()
    }
    /// Stop/deletion cannot publish an in-flight result after invalidation.
    public func cancel() async {
        generation &+= 1; stopped = true; pending.removeAll(); builders.removeAll()
        worker?.cancel(); await worker?.value
        previous.removeAll(); setState(.stopped); continuation.finish()
    }
    private func flushBuilders() {
        for track in AudioTrack.allCases {
            guard var builder = builders[track] else { continue }
            do { if let request = try builder.flush(meetingID: meetingID, recordingID: recordingID, track: track) { enqueue(request) } }
            catch { setState(.failed(track: track, message: error.localizedDescription)) }
            builders[track] = builder
        }
    }
    private func enqueue(_ value: (UUID, UUID, RecordingAudioWindow)) {
        sequence &+= 1
        let track = value.2.track
        if pending[track] != nil {
            skipped += 1
            setState(.delayed(skippedWindows: skipped))
        }
        pending[track] = LiveRequest(sequence: sequence, boundaryID: value.0, fragmentID: value.1, window: value.2)
        if worker == nil {
            let token = generation
            worker = Task { await self.drain(generation: token) }
        }
    }
    private func drain(generation token: UInt64) async {
        while let request = pending.values.min(by: { $0.sequence < $1.sequence }) {
            pending.removeValue(forKey: request.window.track)
            do {
                try Task.checkCancellation()
                let value = try await recognize(request)
                try Task.checkCancellation()
                guard token == generation else { break }
                if let value {
                    publishedCount += 1
                    if let index = utterances.firstIndex(where: { $0.id == value.id }) { utterances[index] = value }
                    else { utterances.append(value) }
                    continuation.yield(.utterance(value))
                }
                if !paused { setState(skipped == 0 ? .ready : .delayed(skippedWindows: skipped)) }
            } catch is CancellationError { break }
            catch {
                guard token == generation else { break }
                skipped += 1
                previous.removeValue(forKey: request.window.track)
                lastFailureMessage = error.localizedDescription
                setState(.failed(track: request.window.track, message: error.localizedDescription))
            }
        }
        worker = nil
    }
    private func recognize(_ request: LiveRequest) async throws -> LiveUtterance? {
        guard let inference, let asr, let diarization else { return nil }
        let window = request.window
        var candidates: [ProvisionalSpeaker] = []
        if window.track == .system {
            let speakerStart = max(speakerEnd, window.active.start)
            if speakerEnd < speakerStart {
                try await diarization.process(RecordingAudioGap(meetingID: meetingID, recordingID: recordingID,
                    track: .system, day: window.day, active: try MediaInterval(start: speakerEnd, end: speakerStart),
                    wallClockStart: window.wallClockStart, reason: "Live processing skipped audio; the durable track is complete."))
                speakerEnd = speakerStart
            }
            // A newest growing window can recover an obsolete request's audio.
            // Assign all still-unprocessed context rather than only its tail.
            let speakerWindow = RecordingAudioWindow(meetingID: meetingID, recordingID: recordingID, track: .system,
                day: window.day, sourceFrames: window.sourceFrames, active: window.active,
                owned: try MediaInterval(start: speakerStart, end: window.owned.end), wallClockStart: window.wallClockStart,
                samples: window.samples, validSampleFrames: window.validSampleFrames)
            let result = try await diarization.process(speakerWindow)
            speakerEnd = window.owned.end
            let unique = Dictionary(result.segments.map { ($0.speakerID, $0.number) }, uniquingKeysWith: { first, _ in first })
            candidates = unique.map { ProvisionalSpeaker(id: $0.key, number: $0.value) }.sorted { $0.number < $1.number }
            // No model-detected system speech: do not hallucinate silence text.
            if candidates.isEmpty { previous.removeValue(forKey: .system); return nil }
        }
        let result = try await inference.liveText(asr, samples: window.samples, language: options.language)
        try Task.checkCancellation()
        let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 8192 else { throw LiveTranscriptionError.invalidPacket }
        var text = raw
        var interval = window.owned
        if window.active.start < window.owned.start,
           (utterances.last(where: { $0.track == window.track })?.interval.end ?? .zero) <= window.active.start {
            // No earlier visible fragment owns this context. A growing retry
            // may recover speech from before its newest publication region.
            interval = window.active
        }
        // Growing windows revise one provisional row, including punctuation or
        // word refinements. At six seconds the ring rolls forward; only then
        // reconcile the shared prefix against the settled previous fragment.
        if let old = utterances.last(where: { $0.id == request.fragmentID }), old.context.start == window.active.start {
            interval = try MediaInterval(start: old.interval.start, end: window.owned.end)
            let unique = Dictionary((old.speakers + candidates).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            candidates = unique.values.sorted { $0.number < $1.number }
        }
        if let old = previous[window.track], old.boundary == request.boundaryID,
           old.utterance.id != request.fragmentID,
           old.utterance.day.id == window.day.id, old.utterance.speakers == candidates,
           old.utterance.context.end > window.active.start, old.utterance.interval.end == window.owned.start {
            text = LiveOverlapDeduplicator.removingSharedPrefix(previous: old.rawText, current: raw)
        }
        let utterance = LiveUtterance(id: request.fragmentID, recordingID: recordingID, day: window.day, track: window.track,
            context: window.active, interval: interval,
            wallClockStart: window.wallClockStart.addingTimeInterval(interval.start.seconds - window.active.start.seconds),
            speakers: candidates, text: text, detectedLanguage: result.language)
        previous[window.track] = (request.boundaryID, utterance, raw)
        return text.isEmpty ? nil : utterance
    }
    private func setState(_ new: LiveTranscriptionState) {
        guard state != new else { return }
        state = new; continuation.yield(.state(new))
    }
}

/// Match only a token suffix/prefix on overlapping source windows. Punctuation
/// and case may change on refinement. A single repeated word is insufficient
/// evidence; preserve it rather than deleting an intentional repetition.
public enum LiveOverlapDeduplicator {
    public static func removingSharedPrefix(previous: String, current: String) -> String {
        func words(_ text: String) -> [(String, String.Index)] {
            var result: [(String, String.Index)] = [], start: String.Index?
            for i in text.indices {
                if text[i].isLetter || text[i].isNumber {
                    if start == nil { start = i }
                } else if let first = start {
                    result.append((String(text[first..<i]).lowercased(), i)); start = nil
                }
            }
            if let first = start { result.append((String(text[first...]).lowercased(), text.endIndex)) }
            return result
        }
        let left = Array(words(previous).suffix(64)), right = words(current)
        guard min(left.count, right.count) >= 2 else { return current }
        for count in stride(from: min(left.count, right.count), through: 2, by: -1) {
            if left.suffix(count).map(\.0) == right.prefix(count).map(\.0) {
                var index = right[count - 1].1
                while index < current.endIndex, !current[index].isLetter, !current[index].isNumber { index = current.index(after: index) }
                return String(current[index...])
            }
        }
        return current
    }
}

/// Growing windows at 3-second cadence, rolling at six seconds with 1.5 seconds
/// of shared context; 300 ms energy endpoint. Revisions retain their row UUID.
/// Energy is a scheduling hint, not a permission gate or speaker detector.
private struct LiveWindowBuilder {
    var samples: [Float] = []
    var start: UInt64 = 0, end: UInt64 = 0, ownedStart: UInt64 = 0
    var day: RecordingDay?, wallClock: Date?, boundary: UUID?
    var voiced = false, silenceFrames = 0
    var fragmentID = UUID()
    var rolled = false
    mutating func append(_ packet: [Float], start frame: UInt64, day: RecordingDay, wallClock: Date, boundary: UUID,
                         meetingID: UUID, recordingID: UUID, track: AudioTrack) throws -> [(UUID, UUID, RecordingAudioWindow)] {
        guard (1...4800).contains(packet.count), frame <= UInt64(Int64.max / 1_000_000) * 48_000,
              frame <= UInt64.max - UInt64(packet.count), wallClock.timeIntervalSinceReferenceDate.isFinite,
              packet.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw LiveTranscriptionError.invalidPacket }
        var output: [(UUID, UUID, RecordingAudioWindow)] = []
        if let oldDay = self.day, let oldClock = self.wallClock, let oldBoundary = self.boundary {
            guard frame >= end else { throw LiveTranscriptionError.invalidPacket }
            if frame != end || day != oldDay || boundary != oldBoundary ||
               abs(oldClock.addingTimeInterval(Double(frame - self.start) / 48_000).timeIntervalSince(wallClock)) > 0.001 {
                if let tail = try flush(meetingID: meetingID, recordingID: recordingID, track: track) { output.append(tail) }
                self.day = nil
            }
        }
        if self.day == nil {
            self.start = frame; end = frame; ownedStart = frame; self.day = day; self.wallClock = wallClock; self.boundary = boundary
        }
        // Split a packet at the cadence boundary. Arbitrary native packet
        // lengths cannot grow the six-second ring by repeated overshoots.
        let untilStep = Int(144_000 - (end - ownedStart))
        if packet.count > untilStep {
            output += try append(Array(packet.prefix(untilStep)), start: frame, day: day, wallClock: wallClock,
                boundary: boundary, meetingID: meetingID, recordingID: recordingID, track: track)
            output += try append(Array(packet.dropFirst(untilStep)), start: frame + UInt64(untilStep), day: day,
                wallClock: wallClock.addingTimeInterval(Double(untilStep) / 48_000), boundary: boundary,
                meetingID: meetingID, recordingID: recordingID, track: track)
            return output
        }
        samples += packet; end = frame + UInt64(packet.count)
        let rms = sqrt(packet.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(packet.count))
        if rms >= 0.002 { voiced = true; silenceFrames = 0 } else { silenceFrames += packet.count }
        let endpoint = silenceFrames >= 14_400
        // A silence boundary also settles a just-published fragment with no
        // new speech. Otherwise a later utterance can inherit its old context.
        if endpoint {
            if voiced { output.append(try window(meetingID: meetingID, recordingID: recordingID, track: track)) }
            reset()
        } else if end - ownedStart >= 144_000 {
            if voiced { output.append(try window(meetingID: meetingID, recordingID: recordingID, track: track)) }
            ownedStart = end
            if rolled || samples.count >= 288_000 {
                let keep = 72_000, dropped = samples.count - keep
                samples = Array(samples.suffix(keep)); self.start += UInt64(dropped)
                self.wallClock = self.wallClock!.addingTimeInterval(Double(dropped) / 48_000)
                fragmentID = UUID()
                rolled = true
            }
            voiced = false; silenceFrames = 0
        }
        return output
    }
    mutating func flush(meetingID: UUID, recordingID: UUID, track: AudioTrack) throws -> (UUID, UUID, RecordingAudioWindow)? {
        let value = voiced && end > ownedStart ? try window(meetingID: meetingID, recordingID: recordingID, track: track) : nil
        reset(); return value
    }
    private func window(meetingID: UUID, recordingID: UUID, track: AudioTrack) throws -> (UUID, UUID, RecordingAudioWindow) {
        let converted = try AudioWindowResampler.convert48K(samples)
        return (boundary!, fragmentID, RecordingAudioWindow(meetingID: meetingID, recordingID: recordingID, track: track, day: day!,
            sourceFrames: start..<end, active: try MediaInterval(start: MediaTime(seconds: Double(start) / 48_000), end: MediaTime(seconds: Double(end) / 48_000)),
            owned: try MediaInterval(start: MediaTime(seconds: Double(ownedStart) / 48_000), end: MediaTime(seconds: Double(end) / 48_000)),
            wallClockStart: wallClock!, samples: converted.samples, validSampleFrames: converted.validFrameCount))
    }
    private mutating func reset() { samples.removeAll(); day = nil; wallClock = nil; boundary = nil; voiced = false; silenceFrames = 0; fragmentID = UUID(); rolled = false }
}
