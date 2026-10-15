import Foundation
import TalkTrackDomain

/// System audio is the primary final source (user decision, 2026-10-13). The
/// microphone contributes only where it is louder than the system track at
/// the same active time; quieter stretches mostly carry loudspeaker playback.
/// Both tracks share the recording's active timeline, measured on a fixed grid
/// of 100 ms frames. Stored audio is never changed: only recognized words.
public enum MicrophoneGate {
    public static let frame: Int64 = 100_000
    /// Frames kept on each side of a louder frame, so word edges survive.
    static let hangover = 1
    /// About −46 dBFS. While the system track is silent, room noise alone is
    /// "louder"; on a real call such frames let echo fragments through.
    static let floor: Float = 0.005

    /// Records the RMS of every whole or partial grid frame the window covers.
    public static func record(_ samples: [Float], start: MediaTime, into levels: inout [Float]) {
        for (index, rms) in frames(samples, start: start) {
            if levels.count <= index { levels += Array(repeating: 0, count: index + 1 - levels.count) }
            levels[index] = rms
        }
    }

    /// Grid frames where the microphone is louder than the system track, with
    /// `hangover` neighbours. Empty when nothing in the window qualifies.
    public static func louderFrames(_ samples: [Float], start: MediaTime, system: [Float]) -> Set<Int> {
        let measured = frames(samples, start: start)
        var keep: Set<Int> = []
        for frame in measured where frame.rms > floor && frame.rms > (system.indices.contains(frame.index) ? system[frame.index] : 0) {
            for index in (frame.index - hangover)...(frame.index + hangover) { keep.insert(index) }
        }
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
            let upper = min(count, max(lower + 1, Int((next - start.microseconds) * rate / 1_000_000)))
            result.append(lower..<upper); lower = upper
        }
        return result
    }

    private static func frames(_ samples: [Float], start: MediaTime) -> [(index: Int, rms: Float)] {
        ranges(samples.count, start: start).map { range in
            let time = start.microseconds + Int64(range.lowerBound) * 1_000_000 / rate
            let energy = range.reduce(Float(0)) { $0 + samples[$1] * samples[$1] }
            return (Int(time / frame), (energy / Float(range.count)).squareRoot())
        }
    }
}
