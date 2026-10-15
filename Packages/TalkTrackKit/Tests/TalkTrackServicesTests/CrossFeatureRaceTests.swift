import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// Task 11.4: one feature interrupts another, then the store is reopened as
/// after a restart. Each test checks that the previously committed result is
/// still the visible one and that the interrupted work can finish afterwards.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// The number of this call, from 1.
    func next() -> Int { lock.withLock { count += 1; return count } }
}

private func waitUntilHeld(_ probe: FinalProbe) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await !probe.held, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await probe.held)
}

@Suite struct CrossFeatureRaceTests {
    @Test func modelRemovedDuringTranscriptionWaitsForItAndKeepsThePreviousTranscript() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let meetingID = fixture.recording.meetingID, recordingID = fixture.recording.id
        let probe = FinalProbe(); await probe.configure(hold: true)
        let work = Task {
            try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
                .runAndPublish(jobID: fixture.job.id)
        }
        try await waitUntilHeld(probe)
        // Settings removes the aligner: the next load fails like a missing file.
        await probe.configure(missing: [.alignment], fail: true)
        await #expect(throws: FinalTranscriptionError.missingModels([.alignment])) { try await work.value }
        #expect(try await fixture.store.job(fixture.job.id).stage == .waitingForModels)
        #expect(try await fixture.store.transcript(meetingID: meetingID, recordingID: recordingID) == fixture.previous)

        try await fixture.store.close()
        let store = try await SessionStore.open(fixture.library)
        #expect(try await store.job(fixture.job.id).stage == .waitingForModels)
        #expect(try await store.transcript(meetingID: meetingID, recordingID: recordingID) == fixture.previous)
        // Downloaded again: Retry finishes the same job from its checkpoint.
        await probe.configure()
        _ = try await store.retryJob(fixture.job.id)
        let published = try await FinalTranscriptionPipeline(store: store, library: fixture.library, inference: probe)
            .runAndPublish(jobID: fixture.job.id)
        #expect(try await store.transcript(meetingID: meetingID, recordingID: recordingID)?.id == published.id)
        #expect(try await store.transcriptRevision(fixture.previous.id) == fixture.previous)
        try await store.close()
    }

    @Test func summaryModelRemovedDuringGenerationWaitsAndKeepsThePreviousSummary() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url)
        try await f.pipeline.run(jobID: f.enqueue().id)
        let previous = try #require(await f.output())
        // Present when the job starts, gone when generation fails.
        let calls = Calls()
        let missing: @Sendable ([ModelSnapshot]) async throws -> [ModelRole] = { _ in calls.next() == 1 ? [] : [.summary] }
        let job = try await f.enqueue()
        await f.inference.set(.failure)
        await #expect(throws: SummaryJobError.missingModel) {
            try await SummaryJobPipeline(store: f.store, inference: f.inference, missing: missing).run(jobID: job.id)
        }
        #expect(try await f.store.job(job.id).stage == .waitingForModels)
        #expect(try await f.output() == previous)

        try await f.store.close()
        let store = try await SessionStore.open(f.library)
        #expect(try await store.job(job.id).stage == .waitingForModels)
        #expect(try await store.summary(meetingID: f.meeting.id, recordingID: f.recording.id) == previous)
        await f.inference.set(.success)
        _ = try await store.retryJob(job.id)
        try await SummaryJobPipeline(store: store, inference: f.inference).run(jobID: job.id)
        #expect(try await store.summary(meetingID: f.meeting.id, recordingID: f.recording.id)?.job.id == job.id)
        try await store.close()
    }

    @Test func captureDuringSummaryKeepsThePreviousSummaryAcrossARestart() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let f = try await SummaryFixture.make(folder.url), pipeline = f.pipeline
        try await pipeline.run(jobID: f.enqueue().id)
        let previous = try #require(await f.output())
        let runner = FinalJobRunner(store: f.store, kinds: [.summary]) { try await pipeline.run(jobID: $0) }
        await f.inference.set(.wait)
        let job = try await f.enqueue()
        await runner.wake(); try await f.inference.waitForStart()
        await runner.setCaptureActive(true)
        await runner.idle()
        #expect(try await f.store.job(job.id).stage == .interrupted)
        #expect(try await f.output() == previous)
        _ = await runner.shutDown()

        try await f.store.close()
        let store = try await SessionStore.open(f.library)
        #expect(try await store.job(job.id).stage == .interrupted)
        #expect(try await store.summary(meetingID: f.meeting.id, recordingID: f.recording.id) == previous)
        await f.inference.set(.success)
        _ = try await store.retryJob(job.id)
        try await SummaryJobPipeline(store: store, inference: f.inference).run(jobID: job.id)
        #expect(try await store.summary(meetingID: f.meeting.id, recordingID: f.recording.id)?.job.id == job.id)
        try await store.close()
    }

    @Test func deletingAMeetingDuringTranscriptionStaysDeletedAfterARestart() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        let other = try await fixture.store.createMeeting(MeetingDraft(title: "Other meeting"))
        try await fixture.store.commitNotes(NotesRevision(meetingID: other.id, text: "Other notes stay"))
        let probe = FinalProbe(); await probe.configure(hold: true)
        let work = Task {
            try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
                .runAndPublish(jobID: fixture.job.id)
        }
        try await waitUntilHeld(probe)
        try await fixture.store.deleteMeeting(fixture.recording.meetingID)
        await probe.configure()
        await #expect(throws: StoreError.self) { try await work.value }

        try await fixture.store.close()
        let store = try await SessionStore.open(fixture.library)
        #expect(try await store.meetings().map(\.id) == [other.id])
        #expect(try await store.notes(meetingID: other.id)?.text == "Other notes stay")
        #expect(try await store.queuedJobs(kind: .finalTranscription).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.library.directory
            .appendingPathComponent("Meetings/\(fixture.recording.meetingID)").path))
        try await store.close()
    }

    @Test func renameDuringTranscriptionIsPublishedAndSurvivesARestart() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder)
        _ = try await stageFinal(fixture)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        let identity = try #require(first.speakers.first)
        _ = try await fixture.store.confirmSpeakerName(meetingID: identity.meetingID, speakerID: identity.id, name: "Alex")
        let job = try await nextFinalJob(fixture)
        let probe = FinalProbe()
        await probe.configure(hold: true, microphoneText: "Sure, I will send it tomorow")
        let work = Task {
            try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
                .runAndPublish(jobID: job.id)
        }
        try await waitUntilHeld(probe)
        let latest = try await fixture.store.confirmSpeakerName(meetingID: identity.meetingID, speakerID: identity.id, name: "Алексей")
        await probe.configure(microphoneText: "Sure, I will send it tomorow")
        let published = try await work.value
        #expect(published.assignments == [latest])

        try await fixture.store.close()
        let store = try await SessionStore.open(fixture.library)
        let snapshot = try await store.meetingTranscript(meetingID: identity.meetingID)
        #expect(snapshot.revisions.map(\.id) == [published.id])
        #expect(snapshot.assignments.map(\.name) == ["Алексей"])
        #expect(try await store.transcriptRevision(first.id) != nil)
        try await store.close()
    }

    @Test func movingTheLibraryAfterAnInterruptedJobResumesItThere() async throws {
        let folder = try TemporaryFolder(), destination = try TemporaryFolder(), support = try TemporaryFolder()
        defer { folder.remove(); destination.remove(); support.remove() }
        let fixture = try await finalFixture(folder)
        let meetingID = fixture.recording.meetingID, recordingID = fixture.recording.id
        let probe = FinalProbe(); await probe.configure(hold: true)
        let work = Task {
            try await FinalTranscriptionPipeline(store: fixture.store, library: fixture.library, inference: probe)
                .run(jobID: fixture.job.id)
        }
        try await waitUntilHeld(probe)
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try await fixture.store.job(fixture.job.id).stage == .interrupted)
        let checkpoint = try #require(await fixture.store.finalCheckpoint(jobID: fixture.job.id))
        try await fixture.store.close()

        let locations = LibraryLocationStore(support: support.url)
        let migrator = LibraryMigrator(locations: locations, modelsRoot: support.url.appendingPathComponent("Models"),
                                       availableSpace: { _ in 1 << 40 })
        let outcome = try await migrator.migrate(source: fixture.library, destination: destination.url)
        #expect(outcome.cleanupPending == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.library.directory.path))

        let location = try #require(try locations.load())
        let moved = try await OwnedLibrary().resume(location)
        #expect(moved.manifest.libraryID == fixture.library.manifest.libraryID)
        let store = try await SessionStore.open(moved)
        #expect(try await store.job(fixture.job.id).stage == .interrupted)
        #expect(try await store.finalCheckpoint(jobID: fixture.job.id) == checkpoint)
        #expect(try await store.transcript(meetingID: meetingID, recordingID: recordingID) == fixture.previous)
        await probe.configure()
        let textCalls = await probe.textCalls
        _ = try await store.retryJob(fixture.job.id)
        let published = try await FinalTranscriptionPipeline(store: store, library: moved, inference: probe)
            .runAndPublish(jobID: fixture.job.id)
        // Audio moved with the library; the recognized window was not redone
        // (three seconds: one window per track).
        let recognized = checkpoint.windows.filter { $0.asr != nil }.count
        #expect(recognized >= 1)
        #expect(await probe.textCalls - textCalls == 2 - recognized)
        #expect(try await store.transcript(meetingID: meetingID, recordingID: recordingID)?.id == published.id)
        try await store.close()
    }
}
