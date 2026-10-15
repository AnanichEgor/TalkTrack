import Dispatch

/// Native HAL/engine calls may block. Give each driver a serial GCD lane instead
/// of occupying the main actor or Swift's cooperative executor threads.
final class AudioDriverExecutor: SerialExecutor {
    private let queue = DispatchQueue(label: "local.talktrack.audio-driver", qos: .userInitiated)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}
