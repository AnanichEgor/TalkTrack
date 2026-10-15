import Darwin
import Foundation
import Testing
import TalkTrackAudio
import TalkTrackDomain
@testable import TalkTrackServices

private actor LiveGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
private enum LiveFixtureFailure: Error { case modelFailed }

@Suite struct LiveInferenceMailboxTests {
    @Test func replacesOnlyObsoleteRequestsAndFinishDrainsNewest() async {
        let mailbox = LiveInferenceMailbox<Int>(capacity: 2)
        #expect(mailbox.offer(1) == .accepted)
        #expect(mailbox.offer(2) == .accepted)
        #expect(mailbox.offer(3) == .replacedObsolete)
        #expect(mailbox.offer(4) == .replacedObsolete)
        mailbox.finish()
        #expect(mailbox.offer(5) == .closed)
        var received: [Int] = []
        for await request in mailbox.requests { received.append(request) }
        #expect(received == [3, 4])
    }

    @Test func stalledThenFailedLiveConsumerCannotDelayOrEraseDurableAudio() async throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let library = try await OwnedLibrary().open(root: folder.url)
        let recording = try Recording(meetingID: UUID(), timeZoneIdentifier: "UTC")
        let writer = try await RecordingAudioWriter.create(library: library, recording: recording)
        let mailbox = LiveInferenceMailbox<Int>(capacity: 2), started = LiveGate(), release = LiveGate()
        let consumer = Task {
            for await _ in mailbox.requests {
                await started.open()
                await release.wait()
                throw LiveFixtureFailure.modelFailed
            }
        }
        mailbox.offer(0)
        await started.wait()
        var replaced = 0
        do {
            let samples = (0..<4096).map { Float(0.2 * sin(2 * .pi * 331 * Double($0) / 48_000)) }
            for i in 0..<24 {
                for track in AudioTrack.allCases {
                    try await writer.append(track: track, samples: samples, activeStartFrame: UInt64(i * 4096), hostTimeStart: 1)
                }
                if mailbox.offer(i + 1) == .replacedObsolete { replaced += 1 }
            }
            // Model worker is still blocked. Both independent files are already
            // committed and decodable before it is allowed to fail.
            let result = try await writer.finish()
            #expect(replaced == 22)
            #expect(result.audio.count == 2)
            for receipt in result.audio {
                let fd = open(library.directory.appendingPathComponent(receipt.chunk.file.value).path, O_RDONLY | O_NOFOLLOW)
                #expect(fd >= 0)
                guard fd >= 0 else { continue }
                defer { close(fd) }
                var frames = 0
                _ = try AACChunkEncoder.decode(fileDescriptor: fd, expectedFrames: 98_304) { frames += $0.count }
                #expect(frames == 98_304)
            }
            await release.open()
            await #expect(throws: LiveFixtureFailure.self) { try await consumer.value }
            mailbox.finish()
            let recovered = try await RecordingAudioWriter.recover(library: library, meetingID: recording.meetingID, recordingID: recording.id)
            #expect(recovered == result)
        } catch {
            await release.open(); mailbox.finish()
            _ = try? await consumer.value
            _ = try? await writer.finish(interrupted: true)
            throw error
        }
    }
}
