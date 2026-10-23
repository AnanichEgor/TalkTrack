import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

struct ProcessingProgressTests {
    typealias E = FinalTranscriptionEstimate

    @Test func theStoredRateGivesWayToTheJobsOwnOverItsFirstTenthOfAudio() {
        // Nothing measured yet: the stored rate.
        let none = FinalJobProgress(jobID: UUID(), processed: 0, total: 1200)
        #expect(E.rate(progress: none, elapsed: 0, stored: 0.04) == 0.04)
        #expect(abs(E.remaining(progress: none, elapsed: 0, stored: 0.04, queuedAudio: []) - (1200 * 0.04 + 5)) < 1e-9)
        // 30 s of 1200 s at 0.2 s/s is a quarter of the way to trusting it.
        let early = FinalJobProgress(jobID: UUID(), processed: 30, total: 1200)
        #expect(abs(E.rate(progress: early, elapsed: 6, stored: 0.04) - (0.04 * 0.75 + 0.2 * 0.25)) < 1e-9)
        // From 10 % on, the job's own rate.
        let converged = FinalJobProgress(jobID: UUID(), processed: 240, total: 1200)
        #expect(abs(E.rate(progress: converged, elapsed: 24, stored: 0.04) - 0.1) < 1e-9)
        // Resumed audio took no time in this run and never counts as measured.
        let resumed = FinalJobProgress(jobID: UUID(), processed: 600, total: 1200, resumed: 600)
        #expect(E.rate(progress: resumed, elapsed: 3, stored: 0.04) == 0.04)
    }

    @Test func theFirstReportIsTheBaseline() {
        // Loading models made the first 30 s take 20 s; the next 270 s took 30 s.
        let progress = FinalJobProgress(jobID: UUID(), processed: 300, total: 1452)
        #expect(abs(E.rate(progress: progress, elapsed: 30, stored: 0.14, baseline: 30) - 30.0 / 270) < 1e-9)
        // Microphone audio counts a tenth.
        #expect(abs(FinalJobProgress.audio(try! MediaTime(seconds: 1320)) - 1452) < 1e-6)
    }

    @Test func remainingCoversTheMeetingsQueuedRecordings() {
        let progress = FinalJobProgress(jobID: UUID(), processed: 600, total: 1200)
        let seconds = E.remaining(progress: progress, elapsed: 30, stored: 0.04, queuedAudio: [1200, 600])
        // 0.05 s/s: 600 s left, then 1800 s queued, each job with its finishing allowance.
        #expect(abs(seconds - (600 * 0.05 + 5 + 1800 * 0.05 + 10)) < 1e-9)
    }

    @Test func minutesRoundUpAndDoNotJitter() {
        #expect(E.minutes(30, shown: nil) == 1 && E.label(minutes: 1) == "less than a minute left")
        #expect(E.minutes(61, shown: nil) == 2 && E.label(minutes: 2) == "about 2 min left")
        // Counts down by whole minutes only.
        #expect(E.minutes(119, shown: 3) == 2)
        // A small increase keeps what is shown; more than half a minute goes up.
        #expect(E.minutes(140, shown: 2) == 2)
        #expect(E.minutes(160, shown: 2) == 3)
        #expect(abs(E.updated(stored: 0.04, measured: 0.06) - 0.05) < 1e-9)
        #expect(E.updated(stored: 0.04, measured: .nan) == 0.04)
    }

    @Test func queueStatesFollowRunnerOrderByMeeting() throws {
        let a = UUID(), b = UUID(), c = UUID()
        func job(_ meeting: UUID, _ stage: JobStage) -> ProcessingJob {
            ProcessingJob(snapshot: ProcessingJobSnapshot(kind: .finalTranscription, recordingID: UUID(),
                source: SourceSnapshot(meetingID: meeting, meetingGeneration: 1, cancellationGeneration: 0,
                                       recordingGenerations: [:], transcriptRevisionIDs: [], notesRevisionID: nil),
                settings: ProcessingSettings(meetingLanguage: .auto), models: []), stage: stage)
        }
        let titles = [a: "Daily 5", b: "Weekly", c: "Retro"]
        let running = job(a, .transcribing)
        let states = FinalQueueState.states(queue: [running, job(b, .queued), job(a, .queued), job(c, .queued)], titles: titles,
                                            runningJobID: running.id)
        #expect(states == [a: .running, b: .queued(position: 2, after: "Daily 5"), c: .queued(position: 3, after: "Weekly")])
        #expect(states[b]?.message == "In queue: 2nd, after “Daily 5”")
        #expect(states[c]?.accessibilityLabel == "Waiting to transcribe, 3rd in queue")
        // The job the runner just started counts as running before its first save.
        let started = job(b, .queued)
        let next = FinalQueueState.states(queue: [job(a, .queued), started], titles: titles, runningJobID: started.id)
        #expect(next == [b: .running, a: .queued(position: 2, after: "Weekly")])
        // Nothing ahead: the plain waiting message. A job left validating by a failed
        // publication is not running.
        #expect(FinalQueueState.states(queue: [job(a, .validating), job(c, .queued)], titles: titles, runningJobID: nil)
                == [c: .queued(position: 1, after: nil)])
        #expect(FinalQueueState.states(queue: [job(c, .queued)], titles: titles, runningJobID: nil)[c]?.message == "Waiting to transcribe")
        #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 101, 111].map(FinalQueueState.ordinal)
                == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "101st", "111th"])
    }
}
