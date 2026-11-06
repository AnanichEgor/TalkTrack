import AVFoundation
import Foundation
import Observation
import TalkTrackDomain

/// Plays one saved-voice sample in Settings: only its system audio, from the
/// verified committed chunks of its single recording, on its own engine so the
/// main window's player keeps its meeting and position. Capture stops it first.
@MainActor @Observable public final class VoiceSamplePreview: CapturePlaybackExclusion {
    /// The longest stretch one Play decodes; samples are a few seconds.
    static let maximumDuration: Int64 = 60_000_000

    /// `SavedVoiceSample.id` while it plays.
    public private(set) var playing: String?
    public private(set) var errorMessage: String?
    /// True while TalkTrack records; set by the app. Plays are refused.
    @ObservationIgnored public var isCapturing: @MainActor () -> Bool = { false }
    /// Pauses the main window's player before a sample plays.
    @ObservationIgnored public var beforePlay: @MainActor () -> Void = {}

    private let library: OpenedLibrary
    private let store: SessionStore
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var node: AVAudioPlayerNode?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    public init(library: OpenedLibrary, store: SessionStore) {
        self.library = library; self.store = store
    }

    public static let capturingMessage = "Stop recording to play a sample."

    /// The sample's system audio, 48 kHz mono. Explicit gaps are silence.
    public static func audio(of sample: SavedVoiceSample, library: OpenedLibrary, store: SessionStore) async throws -> [Float] {
        guard sample.libraryID == library.manifest.libraryID else { throw VoiceSamplePreviewError.unavailable }
        // A moved recording is read from the meeting it is in now, a split one from its part.
        let (recordingID, interval) = await store.resolveRecordingTime(sample.recordingID, sample.interval)
        let meetingID = try await store.recordingMeetingID(recordingID) ?? sample.meetingID
        guard let recording = try await store.recordings(meetingID: meetingID).first(where: { $0.id == recordingID }),
              try await !store.isDeletedRecording(recording.id) else { throw VoiceSamplePreviewError.unavailable }
        let source = try MeetingAudioSource(library: library, meetingID: meetingID, recordings: [recording])
        let end = min(interval.end.microseconds, interval.start.microseconds + maximumDuration)
        let first = try PlaybackFrames.frame(interval.start)
        let last = min(try PlaybackFrames.frame(MediaTime(microseconds: end)), source.totalFrames)
        guard last > first else { return [] }
        await source.seek(toFrame: first)
        var system: [Float] = []
        system.reserveCapacity(Int(last - first))
        while UInt64(system.count) < last - first,
              let block = try await source.next(maximumFrames: min(MeetingPlayer.blockFrames, Int(last - first) - system.count)) {
            system += block.system
        }
        return system
    }

    public func play(_ sample: SavedVoiceSample) async {
        stop()
        errorMessage = nil
        guard !isCapturing() else { errorMessage = Self.capturingMessage; return }
        beforePlay()
        generation += 1
        let current = generation
        playing = sample.id
        do {
            let samples = try await Self.audio(of: sample, library: library, store: store)
            guard current == generation else { return }
            // Recording may have started while the audio was read.
            guard !isCapturing() else { playing = nil; errorMessage = Self.capturingMessage; return }
            guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                playing = nil; return
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            let (engine, node) = try prepare()
            node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in if self?.generation == current { self?.stop() } }
            }
            if !engine.isRunning { try engine.start() }
            node.play()
        } catch {
            guard current == generation else { return }
            playing = nil
            errorMessage = (error as? VoiceSamplePreviewError)?.errorDescription
                ?? "This sample's audio cannot be played: \(error.localizedDescription)"
        }
    }

    public func stop() {
        generation += 1
        node?.stop()
        engine?.stop()
        playing = nil
    }

    nonisolated public func stopPlaybackBeforeCapture() async {
        await MainActor.run { self.stop() }
    }

    private func prepare() throws -> (AVAudioEngine, AVAudioPlayerNode) {
        if let engine, let node { return (engine, node) }
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        self.engine = engine; self.node = node
        return (engine, node)
    }
}

public enum VoiceSamplePreviewError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    public var errorDescription: String? {
        switch self {
        case .unavailable: "This sample's recording is not in the open library."
        }
    }
}

/// Stops every TalkTrack player before capture (meeting player, sample preview).
public struct CombinedPlaybackExclusion: CapturePlaybackExclusion {
    let parts: [any CapturePlaybackExclusion]
    public init(_ parts: [any CapturePlaybackExclusion]) { self.parts = parts }
    public func stopPlaybackBeforeCapture() async {
        for part in parts { await part.stopPlaybackBeforeCapture() }
    }
}
