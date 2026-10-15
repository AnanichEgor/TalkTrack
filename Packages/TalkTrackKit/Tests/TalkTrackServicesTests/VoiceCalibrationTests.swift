import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// One person's sample `k`: their own direction plus a small per-sample tilt,
/// so samples of one person are similar (~0.92) and people are orthogonal.
private func voice(_ person: Int, _ k: Int, tilt: Float = 0.4) -> [Float] {
    clusterVector(person, second: 128 + (person * 16 + k) % 120, coefficient: tilt)
}

private func samples(_ vectors: [[Float]]) throws -> [VoiceProfileSample] {
    let recording = UUID(), revision = UUID(), day = UUID()
    return try vectors.enumerated().map { index, vector in
        VoiceProfileSample(recordingID: recording, transcriptRevisionID: revision, dayID: day,
            interval: try clusterRange(Double(index) * 6, Double(index) * 6 + 5), vector: vector)
    }
}

/// A saved voice confirmed once per given meeting, newest confirmation first.
private func person(_ name: String, meetings: [UUID], vectors: (Int) -> [[Float]]) throws -> VoiceRecognitionProfile {
    let id = UUID(), (segmentation, embedding) = try clusteringModels()
    var history: [VoiceProfileRevision] = [], previous: UUID?
    for (index, meeting) in meetings.enumerated() {
        let revision = VoiceProfileRevision(id: UUID(), profileID: id, previousRevisionID: previous, createdAt: Date(),
            libraryID: UUID(), meetingID: meeting, daySpeakerID: UUID(), assignmentID: UUID(), segmentation: segmentation,
            embedding: embedding, preprocessingVersion: VoiceEnrollmentPolicy.preprocessing,
            enrollmentPolicyVersion: VoiceEnrollmentPolicy.version, calibrationVersion: nil, samples: try samples(vectors(index)))
        history.insert(revision, at: 0); previous = revision.id
    }
    return VoiceRecognitionProfile(profile: VoiceProfile(id: id, name: name, revisionID: history[0].id, updatedAt: Date()),
        revision: history[0], history: history)
}

private func status(_ profiles: [VoiceRecognitionProfile]) throws -> VoiceRecognitionStatus {
    let (segmentation, embedding) = try clusteringModels()
    return VoiceProfileCalibrator.status(profiles, segmentation: segmentation, embedding: embedding)
}

@Suite struct VoiceCalibrationTests {
    @Test func bankAccumulatesEveryConfirmationBoundedAndCanLeaveAMeetingOut() throws {
        let meetings = (0..<4).map { _ in UUID() }
        let alex = try person("Alex", meetings: meetings) { revision in (0..<8).map { voice(0, revision * 8 + $0) } }
        #expect(alex.history.count == 4)
        #expect(alex.bank().count == VoiceProfileBank.maximumSamples)
        #expect(Set(alex.bank().map(\.vector)).count == VoiceProfileBank.maximumSamples)
        let small = try person("Bob", meetings: Array(meetings.prefix(2))) { revision in (0..<2).map { voice(1, revision * 2 + $0) } }
        #expect(small.bank().count == 4)
        #expect(small.bank(excluding: meetings[0]).map(\.vector) == small.history[0].samples.map(\.vector))
        // Farthest-point selection keeps an outlying confirmation instead of the newest near-duplicates.
        let outlier = try person("Carol", meetings: meetings) { revision in
            revision == 0 ? [voice(2, 0, tilt: 0.9), voice(2, 1, tilt: 0.9)] : (0..<8).map { _ in voice(2, 50, tilt: 0.1) }
        }
        #expect(outlier.bank().contains { $0.vector == voice(2, 0, tilt: 0.9) })
    }

    @Test func earlierConfirmationsStillMatchAfterANewOneWithAnotherMicrophone() throws {
        let (segmentation, embedding) = try clusteringModels()
        // The newest confirmation sounds different (another device); v1 compared only it.
        let alex = try person("Alex", meetings: [UUID(), UUID()]) { revision in
            revision == 0 ? [voice(0, 1), voice(0, 2)] : [voice(5, 1), voice(5, 2)]
        }
        let evidence = VoiceProfileEvidence(segmentation: segmentation, embedding: embedding,
            samples: try samples([voice(0, 3), voice(0, 4)]))
        let bob = try person("Bob", meetings: [UUID()]) { _ in [voice(1, 1), voice(1, 2)] }
        let result = try VoiceProfileMatcher.evaluate(evidence, profiles: [alex, bob], calibration: recognitionTestCalibration(similarity: 0.8, margin: 0.2))
        #expect(result.disposition == .matched && result.winner?.profile.name == "Alex")
        #expect(VoiceProfileMatcher.version == "exclusive-median-best-cosine-v2")
    }

    @Test func lowerMedianNeedsMostSamplesToMatch() throws {
        let bank = try samples([voice(0, 1), voice(0, 2)])
        let good = try samples([voice(0, 3), voice(0, 4), voice(0, 5)])
        let mixed = try samples([voice(0, 3), voice(1, 4), voice(1, 5)])
        #expect(VoiceProfileMatcher.score(good, bank: bank) > 0.8)
        #expect(VoiceProfileMatcher.score(mixed, bank: bank) < 0.2)
        #expect(VoiceProfileMatcher.score(try samples([voice(0, 3), voice(1, 4)]), bank: bank) < 0.2)
        #expect(VoiceProfileMatcher.score(good, bank: []) == -1)
    }

    @Test func learningUntilThreeMeetingsAndOnePersonConfirmedTwice() throws {
        let m = (0..<3).map { _ in UUID() }
        let two = [try person("Alex", meetings: [m[0], m[1]]) { r in [voice(0, r * 2), voice(0, r * 2 + 1)] },
                   try person("Bob", meetings: [m[1]]) { _ in [voice(1, 0), voice(1, 1)] }]
        let early = try status(two)
        #expect(early.meetings == 2 && early.repeatedPeople == 1 && !early.isCalibrated)
        let once = [try person("Alex", meetings: [m[0]]) { _ in [voice(0, 0), voice(0, 1)] },
                    try person("Bob", meetings: [m[1]]) { _ in [voice(1, 0), voice(1, 1)] },
                    try person("Carol", meetings: [m[2]]) { _ in [voice(2, 0), voice(2, 1)] }]
        let noRepeat = try status(once)
        #expect(noRepeat.meetings == 3 && noRepeat.repeatedPeople == 0 && noRepeat.positives == 0 && !noRepeat.isCalibrated)
        let ready = try status(two + [try person("Carol", meetings: [m[2]]) { _ in [voice(2, 0), voice(2, 1)] }])
        #expect(ready.meetings == 3 && ready.repeatedPeople == 1 && ready.positives == 2 && ready.negatives >= 4)
        let calibration = try #require(ready.calibration)
        #expect(calibration.minimumSimilarity == VoiceProfileCalibrator.minimumThreshold)
        #expect(calibration.minimumMargin == VoiceProfileCalibrator.margin)
        #expect(calibration.matcherVersion == VoiceProfileMatcher.version && calibration.valid)
        #expect(ready.positivesAccepted == 2)
        // Deterministic: the same confirmations give the same calibration.
        #expect(try status(two + [try person("Carol", meetings: [m[2]]) { _ in [voice(2, 0), voice(2, 1)] }]).calibration?.minimumSimilarity == calibration.minimumSimilarity)
    }

    @Test func thresholdSitsAboveEverySimilarOtherPerson() throws {
        let m = (0..<3).map { _ in UUID() }
        // Bob's voice is close to Alex's (cosine ~0.8).
        let near: (Int) -> [Float] = { k in clusterVector(0, second: 1, coefficient: 0.6 + Float(k) * 0.01) }
        let profiles = [try person("Alex", meetings: [m[0], m[1]]) { r in [voice(0, r * 2, tilt: 0.1), voice(0, r * 2 + 1, tilt: 0.1)] },
                        try person("Bob", meetings: [m[2]]) { _ in [near(0), near(1)] },
                        try person("Carol", meetings: [m[2]]) { _ in [voice(2, 0), voice(2, 1)] }]
        let result = try status(profiles)
        let calibration = try #require(result.calibration)
        #expect(calibration.minimumSimilarity > 0.78)
        #expect(calibration.minimumSimilarity < 1)
        // Incompatible models are not counted at all.
        let other = ModelSnapshot(role: .embedding, repository: "other/voices", revision: "2",
            directory: try RelativePath("other/revision"), preprocessingVersion: "1")
        let (segmentation, _) = try clusteringModels()
        #expect(VoiceProfileCalibrator.status(profiles, segmentation: segmentation, embedding: other).meetings == 0)
    }

    @Test func recognitionCalibratedFromConfirmationsNamesALaterMeeting() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let profiles = VoiceProfileStore(home: root.url), models = try clusteringModels()
        func recognizer(_ f: EnrollmentFixture, vector: [Float]) async -> VoiceProfileRecognition {
            let model = RecognitionInference(); await model.setVector(vector)
            return VoiceProfileRecognition(store: f.store, profiles: profiles, inference: model,
                calibrateFromConfirmations: true, speakerModels: (models.0, models.1), recognitionEnabled: { true })
        }
        // Nothing confirmed yet: no audio decoded, no registry created.
        let first = try await enrollmentFixture(root.url)
        let model = RecognitionInference()
        let idle = VoiceProfileRecognition(store: first.store, profiles: profiles, inference: model,
            calibrateFromConfirmations: true, speakerModels: (models.0, models.1), recognitionEnabled: { true })
        #expect(try await idle.recognize(meetingID: first.meeting.id).decisions.map(\.disposition) == [.uncalibrated])
        #expect(await model.activities == 0 && !FileManager.default.fileExists(atPath: profiles.databaseURL.path))
        let alex = try await remember(first, profiles: profiles, vector: clusterVector(0), name: "Alex")
        let second = try await enrollmentFixture(root.url)
        let more = RecognitionInference(); await more.setVector(clusterVector(0))
        _ = try await VoiceProfileEnrollment(store: second.store, profiles: profiles, inference: more)
            .enroll(second.confirm("Alex").confirmation, choice: .existing(profileID: alex.id, revisionID: alex.revisionID))
        let third = try await enrollmentFixture(root.url)
        _ = try await remember(third, profiles: profiles, vector: clusterVector(1), name: "Bob")
        let status = try await profiles.recognitionStatus(segmentation: models.0, embedding: models.1)
        #expect(!status.isCalibrated && status.meetings == 3 && status.negatives < VoiceProfileCalibrator.requiredNegatives)
        let fourth = try await enrollmentFixture(root.url)
        _ = try await remember(fourth, profiles: profiles, vector: clusterVector(2), name: "Carol")
        let ready = try await profiles.recognitionStatus(segmentation: models.0, embedding: models.1)
        #expect(ready.isCalibrated && ready.meetings == 4 && ready.repeatedPeople == 1)
        let later = try await enrollmentFixture(root.url)
        let report = try await recognizer(later, vector: clusterVector(0)).recognize(meetingID: later.meeting.id)
        #expect(report.assignments.map(\.name) == ["Alex"])
        if case .automatic(_, _, _, _, let version) = report.assignments[0].origin {
            #expect(version == ready.calibration?.version)
        } else { Issue.record("Expected an automatic assignment") }
        // A stranger stays unknown.
        let stranger = try await enrollmentFixture(root.url)
        let unknown = try await recognizer(stranger, vector: clusterVector(9)).recognize(meetingID: stranger.meeting.id)
        #expect(unknown.assignments.isEmpty && unknown.decisions.map(\.disposition) == [.belowThreshold])
        for f in [first, second, third, fourth, later, stranger] { try await f.store.close() }
    }

    @MainActor @Test func settingsShowLearningProgressWithoutCreatingTheRegistry() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let suite = "VoiceCalibrationTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VoiceProfileStore(home: root.url), presentation = SavedSpeakersPresentation(store: store, defaults: defaults)
        await presentation.refresh()
        #expect(presentation.status?.meetings == 0 && presentation.status?.isCalibrated == false)
        #expect(presentation.statusText.hasPrefix("Learning from your names: 0 of 3 meetings."))
        #expect(!FileManager.default.fileExists(atPath: store.databaseURL.path))
    }

    @Test func correctingANameMovesThatSpeechToTheNewVoice() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let f = try await enrollmentFixture(root.url), profiles = VoiceProfileStore(home: root.url)
        let dima = try await remember(f, profiles: profiles, vector: clusterVector(0), name: "Dima")
        // The user corrects the same voice to another person.
        let nikolai = try await remember(f, profiles: profiles, vector: clusterVector(0), name: "Nikolai")
        let registry = try await profiles.recognitionProfiles()
        let old = try #require(registry.first { $0.profile.id == dima.id })
        let new = try #require(registry.first { $0.profile.id == nikolai.id })
        #expect(old.history.isEmpty && old.bank().isEmpty)
        #expect(new.history.count == 1 && new.bank().count == new.revision.samples.count)
        // The superseded revision itself is kept (immutable history), only unused.
        #expect(try await profiles.revision(dima.revisionID) != nil)
        let evidence = VoiceProfileEvidence(segmentation: new.revision.segmentation, embedding: new.revision.embedding,
            samples: new.revision.samples)
        let result = try VoiceProfileMatcher.evaluate(evidence, profiles: registry, calibration: recognitionTestCalibration())
        #expect(result.disposition == .matched && result.winner?.profile.id == nikolai.id)
        try await f.store.close()
    }
}
