import Foundation
import TalkTrackDomain

/// How far a running final transcription is, in weighted audio seconds: system
/// audio counts fully, microphone audio by `microphoneWeight`. Reported in memory only.
public struct FinalJobProgress: Sendable, Equatable {
    /// The microphone track costs about a tenth of the system track: most of its
    /// windows are quieter than the system audio and skip recognition (Daily 5:
    /// about 20 of 205 s).
    public static let microphoneWeight = 0.1

    public static func weight(_ track: AudioTrack) -> Double { track == .microphone ? microphoneWeight : 1 }

    /// The weighted audio of a recording with this active duration.
    public static func audio(_ duration: MediaTime) -> Double {
        AudioTrack.allCases.reduce(0) { $0 + weight($1) * duration.seconds }
    }

    public let jobID: UUID
    public let processed: Double
    public let total: Double
    /// Audio counted as processed because a resumed job's checkpoint already held
    /// it; it took no time in this run, so it never enters the measured rate.
    public let resumed: Double

    public init(jobID: UUID, processed: Double, total: Double, resumed: Double = 0) {
        self.jobID = jobID; self.processed = min(processed, total); self.total = total; self.resumed = min(resumed, processed)
    }
}

/// Where a meeting's final transcription stands among all meetings' work.
public enum FinalQueueState: Sendable, Equatable {
    case running
    /// `position` counts meetings, the running one first; `after` is the title of
    /// the meeting directly ahead, nil when nothing is ahead.
    case queued(position: Int, after: String?)

    public var message: String {
        switch self {
        case .running: "Transcribing…"
        case .queued(let position, let after?): "In queue: \(Self.ordinal(position)), after “\(after)”"
        case .queued: "Waiting to transcribe"
        }
    }

    /// Spoken by the sidebar row.
    public var accessibilityLabel: String {
        switch self {
        case .running: "Transcribing"
        case .queued(let position, _): "Waiting to transcribe, \(Self.ordinal(position)) in queue"
        }
    }

    static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }

    /// Per meeting, from final jobs in runner order (`SessionStore.finalQueue`).
    /// Only `runningJobID`, the job the runner started, runs: it may still be
    /// `queued` until its first save, and a job the runner left in a working
    /// stage (a failed publication keeps `validating`) is neither running nor waiting.
    static func states(queue: [ProcessingJob], titles: [UUID: String], runningJobID: UUID?) -> [UUID: FinalQueueState] {
        let isRunning = { (job: ProcessingJob) in job.id == runningJobID }
        var order: [UUID] = []
        var running: Set<UUID> = []
        for job in queue.filter(isRunning) + queue.filter({ !isRunning($0) && $0.stage == .queued }) {
            let meetingID = job.snapshot.source.meetingID
            if isRunning(job) { running.insert(meetingID) }
            if !order.contains(meetingID) { order.append(meetingID) }
        }
        var states: [UUID: FinalQueueState] = [:]
        for (index, meetingID) in order.enumerated() {
            states[meetingID] = running.contains(meetingID) ? .running
                : .queued(position: index + 1, after: index == 0 ? nil : titles[order[index - 1]] ?? "another meeting")
        }
        return states
    }
}

/// What the status row shows under a running meeting's message.
public struct FinalProgressDisplay: Sendable, Equatable {
    public let fraction: Double
    /// `about 3 min left`, `less than a minute left`, or nil before an estimate exists.
    public let remaining: String?
}

/// The approximate remaining time of one meeting's final transcription.
public struct FinalTranscriptionEstimate: Sendable {
    /// Seconds per weighted audio second before the running job has measured its own
    /// (Daily 5 reprocessed in 205 s for 1452 weighted seconds).
    public static let defaultRate = 0.14
    /// Seconds added per job for correction and publication, which report no audio.
    public static let finishing = 5.0
    /// A completed job teaches the stored rate only after this much new audio.
    static let minimumMeasured = 30.0
    /// The job's own rate takes over gradually until this share of it is done.
    static let minimumFraction = 0.1

    /// The rate to extrapolate with: the stored rate at first, moving linearly to
    /// the job's own until 10 % of its new audio is done, so an early slow or fast
    /// window cannot swing the estimate. The display corrects itself as the job
    /// runs; it is never meant to be exact. `elapsed` and
    /// `baseline` start at the job's first report, so loading models and the
    /// first window, which take far longer than later ones, are not extrapolated.
    public static func rate(progress: FinalJobProgress, elapsed: Double, stored: Double, baseline: Double = 0) -> Double {
        let measured = progress.processed - max(progress.resumed, baseline)
        guard measured > 0, elapsed > 0 else { return stored }
        let share = min(1, measured / max(minimumFraction * (progress.total - max(progress.resumed, baseline)), 1))
        return stored * (1 - share) + elapsed / measured * share
    }

    /// Seconds left for the running job and the meeting's queued audio.
    public static func remaining(progress: FinalJobProgress, elapsed: Double, stored: Double, baseline: Double = 0,
                                 queuedAudio: [Double]) -> Double {
        let rate = rate(progress: progress, elapsed: elapsed, stored: stored, baseline: baseline)
        return (progress.total - progress.processed) * rate + finishing
            + queuedAudio.reduce(0) { $0 + $1 * rate + finishing }
    }

    /// Whole minutes to show. Rounds up, and goes up only when the estimate is at
    /// least half a minute above what is shown, so it never flickers between two values.
    public static func minutes(_ seconds: Double, shown: Int?) -> Int {
        let minutes = max(0, Int((seconds / 60).rounded(.up)))
        guard let shown, minutes > shown, seconds <= Double(shown) * 60 + 30 else { return minutes }
        return shown
    }

    public static func label(minutes: Int) -> String {
        minutes <= 1 ? "less than a minute left" : "about \(minutes) min left"
    }

    /// Exponential average with the measured rate of a completed job.
    public static func updated(stored: Double, measured: Double) -> Double {
        guard measured.isFinite, measured > 0 else { return stored }
        return stored * 0.5 + measured * 0.5
    }
}
