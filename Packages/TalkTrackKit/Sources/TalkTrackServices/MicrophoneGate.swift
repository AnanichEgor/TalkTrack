import Foundation
import TalkTrackDomain

/// System audio is the primary final source (user decision, 2026-10-13). The
/// microphone contributes only where it is louder than the system track at
/// the same active time; quieter stretches mostly carry loudspeaker playback.
/// Both tracks share the recording's active timeline, measured on a fixed grid
/// of 100 ms frames. Stored audio is never changed: only recognized words.
public enum MicrophoneGate {
    public static let frame: Int64 = 100_000
    /// Frames kept on each side of a louder stretch, so word edges survive.
    static let hangover = 3
    /// About −46 dBFS. While the system track is silent, room noise alone is
    /// "louder"; on a real call such frames let echo fragments through.
    static let floor: Float = 0.005
    /// The microphone must be this many times (6 dB) louder than the system
    /// track, for at least `minimumRun` consecutive frames. Merely louder single
    /// frames were mostly loudspeaker echo: on four real calls (2026-10-22) they
    /// kept 82–464 echo words each and left 90% of windows to recognize; this
    /// keeps 3–19 echo words and as many of the user's own.
    static let margin: Float = 2
    static let minimumRun = 3

    /// Records the RMS of every whole or partial grid frame the window covers.
    public static func record(_ samples: [Float], start: MediaTime, into levels: inout [Float]) {
        for (index, rms, whole) in frames(samples, start: start) {
            // A window's partial first frame keeps the previous window's whole measurement.
            if !whole, index < levels.count, levels[index] > 0 { continue }
            if levels.count <= index { levels += Array(repeating: 0, count: index + 1 - levels.count) }
            levels[index] = rms
        }
    }

    /// Grid frames of stretches where the microphone is clearly louder than the
    /// system track, with `hangover` neighbours. Empty when nothing in the
    /// window qualifies, and then the window is not recognized at all.
    public static func louderFrames(_ samples: [Float], start: MediaTime, system: [Float]) -> Set<Int> {
        var keep: Set<Int> = [], run: [Int] = []
        func flush() {
            if run.count >= minimumRun, let first = run.first, let last = run.last {
                for index in (first - hangover)...(last + hangover) { keep.insert(index) }
            }
            run.removeAll()
        }
        for frame in frames(samples, start: start) {
            let other = system.indices.contains(frame.index) ? system[frame.index] : 0
            if frame.rms > floor && frame.rms > margin * other { run.append(frame.index) } else { flush() }
        }
        flush()
        return keep
    }

    /// Words mostly spoken in louder frames. Recognition runs on the whole
    /// microphone window (silencing frames made the model invent sentences);
    /// the quieter loudspeaker playback is removed word by word afterwards.
    public static func keep(_ word: MediaInterval, louder: Set<Int>) -> Bool {
        let first = Int(word.start.microseconds / frame), last = Int(max(word.start.microseconds, word.end.microseconds - 1) / frame)
        let covered = (first...last).filter(louder.contains).count
        return covered * 2 >= last - first + 1
    }

    private static let rate = Int64(RecordingAudioWindow.sampleRate)

    /// Sample ranges of consecutive grid frames, aligned to absolute active time.
    private static func ranges(_ count: Int, start: MediaTime) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var lower = 0
        while lower < count {
            let time = start.microseconds + Int64(lower) * 1_000_000 / rate
            let next = (time / frame + 1) * frame
            // The first sample at or after the frame boundary. Rounding down left
            // one sample of the next frame overwriting each level whenever the
            // window did not start on the sample grid.
            let upper = min(count, max(lower + 1, Int(((next - start.microseconds) * rate + 999_999) / 1_000_000)))
            result.append(lower..<upper); lower = upper
        }
        return result
    }

    private static func frames(_ samples: [Float], start: MediaTime) -> [(index: Int, rms: Float, whole: Bool)] {
        ranges(samples.count, start: start).map { range in
            let time = start.microseconds + Int64(range.lowerBound) * 1_000_000 / rate
            let energy = range.reduce(Float(0)) { $0 + samples[$1] * samples[$1] }
            return (Int(time / frame), (energy / Float(range.count)).squareRoot(), Int64(range.count) >= frame * rate / 1_000_000)
        }
    }
}
