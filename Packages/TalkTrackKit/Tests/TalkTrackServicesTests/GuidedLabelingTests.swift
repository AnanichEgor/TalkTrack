import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// Five streaming clusters, one per window (never heard together): A, and B at
/// cosine 0.6 to it; C, and D at 0.35 to it; E unrelated.
private func fiveClusters() throws -> (SystemSpeakerClustering, [UUID]) {
    let (segmentation, embedding) = try clusteringModels(), recordingID = UUID(), day = try clusterDay()
    var state = try SystemSpeakerClustering(meetingID: UUID(), segmentation: segmentation, embedding: embedding)
    let vectors = [clusterVector(0), clusterVector(0, second: 1, coefficient: 0.8), clusterVector(2),
                   clusterVector(2, second: 3, coefficient: sqrt(1 - 0.35 * 0.35)), clusterVector(4)]
    var ids: [UUID] = []
    for (window, vector) in vectors.enumerated() {
        let range = try clusterRange(Double(window * 2), Double(window * 2 + 2))
        ids.append(try #require(state.process(recordingID: recordingID, day: day, context: range, owned: range, observations: [
            SpeakerClusteringObservation(slot: 1, activity: [range], cleanSpeech: [range], embedding: SpeakerWindowEmbedding(values: vector, model: embedding))
        ]).first).speakerID)
    }
    return (state, ids)
}

private func pair(_ similarity: Double, same: Bool) -> NamedVoicePair {
    NamedVoicePair(recordingID: UUID(), similarity: similarity, apart: false, samePerson: same)
}

@Suite struct GuidedLabelingTests {
    @Test func namesLinkAndSeparateVoicesInConsolidation() throws {
        let (state, ids) = try fiveClusters()
        let (a, b, c, d, e) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        // Standard: A and B (0.6) merge; C and D (0.35) do not.
        let standard = state.consolidation()
        #expect(standard[b] == a && standard[d] == d)
        // Different names never share a voice, however similar.
        #expect(state.consolidation(links: [a: "alex", b: "maria"])[b] == b)
        // One name is one voice, however different.
        #expect(state.consolidation(links: [c: "yuri", d: "yuri"])[d] == c)
        #expect(state.consolidation(links: [c: "yuri", e: "yuri"])[e] == c)
        // A learned threshold merges C and D without names, never E.
        let learned = state.consolidation(learned: 0.33)
        #expect(learned[d] == c && learned[e] == e)
        // Heard in one window: only a learned threshold merges them, never different names.
        let apart: [UUID: Set<UUID>] = [a: [b], b: [a]]
        #expect(state.consolidation(apart: apart)[b] == b)
        #expect(state.consolidation(apart: apart, learned: 0.5)[b] == a)
        #expect(state.consolidation(apart: apart, links: [a: "alex", b: "maria"], learned: 0.5)[b] == b)
    }

    @Test func aVoiceBelongsToAPersonOnlyByMostOfItsSpeech() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(SpeakerLinks.owner(of: [a, b], links: [a: "yuri"], speech: [a: 1, b: 5]) == nil)
        #expect(SpeakerLinks.owner(of: [a, b], links: [a: "yuri"], speech: [a: 5, b: 1]) == "yuri")
        // Someone else's named speech above a fifth leaves it unowned.
        #expect(SpeakerLinks.owner(of: [a, b, c], links: [a: "yuri", c: "dima"], speech: [a: 6, b: 1, c: 3]) == nil)
        #expect(SpeakerLinks.owner(of: [a, b, c], links: [a: "yuri", c: "dima"], speech: [a: 8, b: 1, c: 1]) == "yuri")
    }

    @Test func coverageCountsOnlyTranscribedSpeechOfOnePerson() throws {
        let recording = UUID()
        let named = [NamedSpeech(name: " Юра ", recordingID: recording, intervals: [try clusterRange(0, 6)]),
                     NamedSpeech(name: "Дима", recordingID: recording, intervals: [try clusterRange(6, 8)])]
        #expect(named[0].person == "юра" && named[0].name == "Юра")
        #expect(SpeakerLinks.person(of: [try clusterRange(1, 5)], recordingID: recording, named: named) == "юра")
        #expect(SpeakerLinks.person(of: [try clusterRange(4, 8)], recordingID: recording, named: named) == nil)
        #expect(SpeakerLinks.person(of: [try clusterRange(1, 5)], recordingID: UUID(), named: named) == nil)
    }

    @Test func mergeCalibrationSitsAboveTheMostSimilarDifferentPair() {
        let negatives = (0..<26).map { pair(0.03 + Double($0) * 0.01, same: false) } + [pair(0.293, same: false)]
        let all = negatives + [pair(0.473, same: true), pair(0.378, same: true)]
        let active = SpeakerMergeCalibration(pairs: all)
        #expect(active.isActive && abs(active.threshold! - 0.343) < 1e-9)
        #expect(active.positives == 2 && active.negatives == 27 && active.mergeable == 2)
        #expect(active.version == SpeakerMergeCalibration.version && active.hash.count == 64)
        // Gates: two same-person pairs, ten different pairs, one pair above the threshold.
        #expect(!SpeakerMergeCalibration(pairs: negatives + [pair(0.473, same: true)]).isActive)
        #expect(!SpeakerMergeCalibration(pairs: Array(negatives.prefix(9)) + [pair(0.47, same: true), pair(0.38, same: true)]).isActive)
        #expect(!SpeakerMergeCalibration(pairs: negatives + [pair(0.33, same: true), pair(0.32, same: true)]).isActive)
        // Never below the floor.
        let low = SpeakerMergeCalibration(pairs: (0..<12).map { _ in pair(0.1, same: false) } + [pair(0.5, same: true), pair(0.4, same: true)])
        #expect(low.threshold == SpeakerMergeCalibration.floor)
        // The hash does not depend on the order the pairs were read in.
        #expect(SpeakerMergeCalibration(pairs: all.reversed()).hash == active.hash)
    }

    /// Two voices named one person become one voice on Apply Names, with the
    /// same words; a fragment named for someone else splits them again;
    /// clearing names leaves only unknown voices.
    @Test func applyNamesMergesSplitsAndClearsWithoutTranscribingAgain() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, seconds: 6)
        let text = "Alex will not pay 42 rubles tomorrow and Maria will check 17 items today"
        try await fixture.store.saveFinalCheckpoint(try resegment(try await stageFinal(fixture, text: text), split: true), stage: .validating)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        let meetingID = fixture.recording.meetingID
        #expect(first.speakers.count == 2)
        #expect(try await fixture.store.namesApplicableRecordings(meetingID: meetingID) == [fixture.recording.id])
        for speaker in first.speakers { try await fixture.store.confirmSpeakerName(meetingID: meetingID, speakerID: speaker.id, name: "Alex") }
        let words = try #require(try await fixture.store.transcriptRevision(first.id)).segments.map(\.originalText)

        let merged = try #require(try await fixture.store.applyNames(meetingID: meetingID).first)
        let lowest = first.speakers.min { $0.number < $1.number }!
        #expect(merged.speakers.map(\.id) == [lowest.id] && merged.assignments.map(\.name) == ["Alex"])
        let mergedRevision = try #require(try await fixture.store.transcriptRevision(merged.id))
        #expect(mergedRevision.segments.map(\.originalText).joined(separator: " ") == words.joined(separator: " "))
        #expect(try await fixture.store.jobs(meetingID: meetingID).filter { $0.snapshot.kind == .finalTranscription }.allSatisfy { $0.stage == .completed })

        // Name Maria's part as a fragment: it shows at once, then gets its own voice.
        let maria = try #require(mergedRevision.segments.last { $0.track == .system })
        let named = try await fixture.store.nameFragment(meetingID: meetingID, recordingID: fixture.recording.id, segmentIDs: [maria.id], name: "Maria")
        #expect(named.anchors.count == 1)
        #expect(named.items.contains { if case .speech(let block) = $0 { block.speakerLabel == "Maria" && block.isNamedFragment } else { false } })
        let split = try #require(try await fixture.store.applyNames(meetingID: meetingID).first)
        #expect(Set(split.assignments.compactMap(\.name)) == ["Alex", "Maria"])
        #expect(split.assignments.first { $0.name == "Maria" }?.origin == .linked)
        #expect(split.assignments.first { $0.name == "Alex" }?.origin == .manual)
        let splitRevision = try #require(try await fixture.store.transcriptRevision(split.id))
        let mariaVoice = try #require(split.assignments.first { $0.name == "Maria" }).daySpeakerID
        #expect(splitRevision.segments.contains { $0.originalText == maria.originalText && $0.speaker == .system(daySpeakerID: mariaVoice) })
        // Linked names are not the user's statements.
        #expect(try await fixture.store.namedSpeech(meetingID: meetingID).map(\.person).sorted() == ["alex", "maria"])

        _ = try await fixture.store.clearSpeakerNames(meetingID: meetingID)
        #expect(try await fixture.store.fragmentAnchors(meetingID: meetingID).isEmpty)
        let cleared = try #require(try await fixture.store.applyNames(meetingID: meetingID).first)
        #expect(cleared.assignments.isEmpty && cleared.speakers.count == 2)
        try await fixture.store.close()
    }

    @Test func fragmentNamesReplaceRemoveRefuseMicrophoneAndReopen() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, seconds: 6)
        _ = try await stageFinal(fixture)
        let published = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        let meetingID = fixture.recording.meetingID
        let revision = try #require(try await fixture.store.transcriptRevision(published.id))
        let system = try #require(revision.segments.first { $0.track == .system })
        let microphone = try #require(revision.segments.first { $0.track == .microphone })
        await #expect(throws: SpeakerRenameError.microphone) {
            try await fixture.store.nameFragment(meetingID: meetingID, recordingID: fixture.recording.id, segmentIDs: [microphone.id], name: "Me")
        }
        await #expect(throws: SpeakerRenameError.invalidName) {
            try await fixture.store.nameFragment(meetingID: meetingID, recordingID: fixture.recording.id, segmentIDs: [system.id], name: " ")
        }
        _ = try await fixture.store.nameFragment(meetingID: meetingID, recordingID: fixture.recording.id, segmentIDs: [system.id], name: "Yuri")
        let renamed = try await fixture.store.nameFragment(meetingID: meetingID, recordingID: fixture.recording.id, segmentIDs: [system.id], name: "Dima")
        #expect(renamed.anchors.map(\.name) == ["Dima"])
        try await fixture.store.close()
        let reopened = try await SessionStore.open(fixture.library)
        #expect(try await reopened.fragmentAnchors(meetingID: meetingID).map(\.name) == ["Dima"])
        let removed = try await reopened.removeFragmentName(meetingID: meetingID, recordingID: fixture.recording.id, segmentIDs: [system.id])
        #expect(removed.anchors.isEmpty)
        #expect(!removed.items.contains { if case .speech(let block) = $0 { block.isNamedFragment } else { false } })
        await #expect(throws: SpeakerRenameError.changed) {
            try await reopened.removeFragmentName(meetingID: meetingID, recordingID: fixture.recording.id, segmentIDs: [system.id])
        }
        try await reopened.close()
    }

    @Test func libraryPairsComeFromStandardVoicesNotThePublishedOnes() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, seconds: 6)
        let text = "Alex will not pay 42 rubles tomorrow and Maria will check 17 items today"
        try await fixture.store.saveFinalCheckpoint(try resegment(try await stageFinal(fixture, text: text), split: true), stage: .validating)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        let meetingID = fixture.recording.meetingID
        for speaker in first.speakers { try await fixture.store.confirmSpeakerName(meetingID: meetingID, speakerID: speaker.id, name: "Alex") }
        let before = try await fixture.store.namedVoicePairs()
        #expect(before.count == 1 && before[0].samePerson && before[0].apart)
        // Merging the two voices must not erase the pair that taught it.
        _ = try await fixture.store.applyNames(meetingID: meetingID)
        #expect(try await fixture.store.namedVoicePairs() == before)
        #expect(try await !fixture.store.mergeCalibration().isActive)
        try await fixture.store.close()
    }

    @Test @MainActor func transcriptNamesFragmentsAndAppliesNames() async throws {
        let folder = try TemporaryFolder(); defer { folder.remove() }
        let fixture = try await finalFixture(folder, seconds: 6)
        let text = "Alex will not pay 42 rubles tomorrow and Maria will check 17 items today"
        try await fixture.store.saveFinalCheckpoint(try resegment(try await stageFinal(fixture, text: text), split: true), stage: .validating)
        let first = try await fixture.store.publishFinalTranscript(jobID: fixture.job.id)
        let p = MeetingTranscriptPresentation(store: fixture.store, meetingID: fixture.recording.meetingID)
        await p.refresh()
        #expect(!p.hasSpeakerNames && !p.canApplyNames && p.applicableRecordings == [fixture.recording.id])
        let revision = try #require(try await fixture.store.transcriptRevision(first.id))
        let segments = revision.segments.filter { $0.track == .system }
        await p.beginNameFragment(recordingID: fixture.recording.id, segmentIDs: segments.map(\.id))
        #expect(p.fragmentSegmentIDs == segments.map(\.id) && p.draftName.isEmpty)
        p.draftName = "Alex"; p.rememberVoice = false
        await p.saveRename()
        #expect(p.renameTarget == nil && p.fragmentSegmentIDs == nil && p.snapshot?.anchors.count == segments.count)
        #expect(p.hasSpeakerNames && p.canApplyNames)
        // Reopening the sheet on a named fragment shows its name.
        await p.beginNameFragment(recordingID: fixture.recording.id, segmentIDs: [segments[0].id])
        #expect(p.draftName == "Alex"); p.cancelRename()
        await p.applyNames()
        #expect(p.noticeMessage?.hasPrefix("Names applied") == true)
        let voices = Set(p.snapshot!.revisions.flatMap(\.segments).compactMap { segment -> UUID? in
            if case .system(let id) = segment.speaker { id } else { nil } })
        #expect(voices.count == 1 && p.snapshot!.assignments.map(\.origin) == [.linked])
        await p.removeFragmentName(recordingID: fixture.recording.id, segmentIDs: [segments[0].id])
        #expect(p.snapshot?.anchors.count == segments.count - 1)
        try await fixture.store.close()
    }

    @Test @MainActor func settingsExplainMergeLearning() async throws {
        let root = try TemporaryFolder(); defer { root.remove() }
        let defaults = try #require(UserDefaults(suiteName: "TalkTrack.MergeText.\(UUID())"))
        let p = SavedSpeakersPresentation(store: VoiceProfileStore(home: root.url), defaults: defaults)
        await p.refresh()
        #expect(p.mergeText == nil)
        let learning = SpeakerMergeCalibration(pairs: [pair(0.4, same: true)] + (0..<3).map { _ in pair(0.1, same: false) })
        p.mergeCalibration = { learning }
        await p.refresh()
        #expect(p.mergeText?.hasPrefix("Learning: 1 of 2 people named on two voices, 3 of 10 pairs") == true)
        let active = SpeakerMergeCalibration(pairs: [pair(0.47, same: true), pair(0.38, same: true)] + (0..<10).map { _ in pair(0.293, same: false) })
        p.mergeCalibration = { active }
        await p.refresh()
        #expect(p.mergeText?.hasPrefix("Active. Learned from 12 pairs of voices you named: voices at least 0.34 alike") == true)
    }

    /// User request, 2026-10-14: correcting one reply's name must not rename
    /// the voice's other replies, and the correction teaches recognition.
    @Test @MainActor func correctingOneReplyRenamesOnlyItAndTeachesSavedVoices() async throws {
        let home = try TemporaryFolder(), other = try TemporaryFolder(), root = try TemporaryFolder()
        defer { home.remove(); other.remove(); root.remove() }
        let profiles = VoiceProfileStore(home: home.url)
        // Yuri already has a saved voice from another library.
        let earlier = try await enrollmentFixture(other.url)
        let yuri = try await VoiceProfileEnrollment(store: earlier.store, profiles: profiles, inference: EnrollmentInference())
            .enroll(try await earlier.confirm("Yuri").confirmation, choice: .newProfile)
        try await earlier.store.close()

        let f = try await enrollmentFixture(root.url, seconds: 36, pieces: 12)
        let service = VoiceProfileEnrollment(store: f.store, profiles: profiles, inference: EnrollmentInference())
        let p = MeetingTranscriptPresentation(store: f.store, meetingID: f.meeting.id, enrollment: service)
        await p.refresh()
        let ids = f.revision.segments.map(\.id)
        // Selecting a name always starts with this reply; the whole voice is an explicit choice.
        await p.beginNaming(recordingID: f.recording.id, segmentIDs: [ids[0]])
        #expect(p.scope == .reply && p.fragmentSegmentIDs == [ids[0]])
        p.scope = .voice
        #expect(p.fragmentSegmentIDs == nil)
        p.draftName = "Dima"; await p.saveRename()
        let dima = try #require(try await profiles.profiles().first { $0.name == "Dima" })
        // Correct a later reply that lies inside one of Dima's saved samples.
        let before = try #require(try await profiles.recognitionProfiles().first { $0.profile.id == dima.id }).bank()
        let index = try #require((1..<12).last { i in
            let reply = f.revision.segments[i].interval
            return before.contains { $0.interval.start <= reply.start && reply.end <= $0.interval.end }
        })
        let corrected = f.revision.segments[index].interval
        // Selecting a named voice corrects only that reply, prefilled with its name.
        await p.beginNaming(recordingID: f.recording.id, segmentIDs: [ids[index]])
        #expect(p.scope == .reply && p.fragmentSegmentIDs == [ids[index]] && p.draftName == "Dima")
        p.draftName = "Yuri"
        #expect(p.effectiveProfileID == yuri.id)
        await p.saveRename()
        #expect(p.noticeMessage?.hasPrefix("Name saved for this reply. Voice remembered locally as Yuri") == true)
        let labels = p.snapshot!.items.compactMap { item -> String? in if case .speech(let block) = item { block.speakerLabel } else { nil } }
        #expect(labels.first == "Dima" && labels.contains("Yuri") && labels.filter { $0 == "Yuri" }.count == 1)
        #expect(p.snapshot!.assignments.map(\.name) == ["Dima"])
        // A three-second correction joined Yuri's adequate voice.
        let updated = try #require(try await profiles.profiles().first { $0.id == yuri.id })
        let added = try #require(try await profiles.revision(updated.revisionID))
        #expect(added.previousRevisionID == yuri.revisionID && added.samples.reduce(0) { $0 + $1.interval.duration.seconds } < 10)
        let corrections = try await f.store.voiceCorrections()
        let registry = try await profiles.recognitionProfiles(corrections: corrections)
        #expect(try #require(registry.first { $0.profile.id == yuri.id }).isAdequate)
        // The sample holding the corrected speech left Dima's bank; the rest stayed.
        let after = try #require(registry.first { $0.profile.id == dima.id }).bank()
        func holds(_ sample: VoiceProfileSample) -> Bool { sample.interval.start <= corrected.start && corrected.end <= sample.interval.end }
        #expect(before.contains(where: holds) && !after.contains(where: holds) && after.count == before.count - before.filter(holds).count)
        #expect(try await profiles.savedVoices(segmentation: added.segmentation, embedding: added.embedding).allSatisfy { !$0.needsNewSpeech })
        try await f.store.close()
    }

    /// Unit vectors at a given cosine to axis `base` (towards axis `towards`).
    private func near(_ base: Int, _ cosine: Float, towards: Int) -> [Float] {
        clusterVector(base, second: towards, coefficient: sqrt(1 - cosine * cosine))
    }

    @Test func replyRecognitionMeasuresLeavingOneReplyOutAndNamesOnlyClearMatches() {
        let recording = UUID()
        func cluster(_ person: String, _ vector: [Float]) -> NamedCluster {
            NamedCluster(person: person, recordingID: recording, id: UUID(), vectors: [vector], neighbours: [])
        }
        // Yuri's replies are alike (0.9 to axis 0); Dima's (axis 2) are unrelated.
        let named = [cluster("yuri", near(0, 0.95, towards: 10)), cluster("yuri", near(0, 0.95, towards: 11)),
                     cluster("yuri", near(0, 0.95, towards: 12)),
                     cluster("dima", near(2, 0.95, towards: 13)), cluster("dima", near(2, 0.95, towards: 14)),
                     cluster("dima", near(2, 0.95, towards: 15))]
        let recognition = ReplyRecognition(named: named, names: ["yuri": "Юра", "dima": "Дима"])
        let m = recognition.measurement
        #expect(m.people == 2 && m.positives == 6 && m.negatives == 6 && m.accepted == 6)
        #expect(m.threshold == ReplyRecognition.floor && m.isActive)
        #expect(recognition.person(for: [near(0, 0.9, towards: 20)]) == "yuri")
        #expect(recognition.person(for: [near(2, 0.9, towards: 20)]) == "dima")
        // Too far from anyone, or between two people: stays unnamed.
        #expect(recognition.person(for: [clusterVector(30)]) == nil)
        var between = [Float](repeating: 0, count: 256); between[0] = 0.7; between[2] = 0.7; between[20] = sqrt(1 - 0.98)
        #expect(recognition.person(for: [between]) == nil)
        // One reply per person gives nothing to hold out.
        #expect(!ReplyRecognition(named: [named[0], named[3]], names: [:]).measurement.isActive)
    }

    @Test func voicesHeardTogetherStandInOnlyUntilSomeoneElseIsNamed() {
        let recording = UUID()
        let yuri = (10..<13).map { NamedCluster(person: "yuri", recordingID: recording, id: UUID(), vectors: [near(0, 0.95, towards: $0)], neighbours: []) }
        // Alone, Yuri has no negatives: nothing is named.
        #expect(!ReplyRecognition(named: yuri, names: [:]).measurement.isActive)
        // Heard-together voices give them; a stranger as close as 0.8 raises the threshold.
        let strangers = (20..<25).map { [near(0, 0.8, towards: $0)] }
        let alone = ReplyRecognition(named: yuri, names: [:], strangers: ["yuri": strangers])
        #expect(alone.measurement.negatives == 5 && alone.measurement.isActive)
        #expect(abs(alone.measurement.threshold! - (0.8 * 0.95 + ReplyRecognition.headroom)) < 1e-4)
        #expect(alone.person(for: [near(0, 0.98, towards: 30)]) == "yuri")
        // With someone else named, they are ignored and the threshold falls to the floor.
        let dima = (13..<16).map { NamedCluster(person: "dima", recordingID: recording, id: UUID(), vectors: [near(2, 0.95, towards: $0)], neighbours: []) }
        let both = ReplyRecognition(named: yuri + dima, names: [:], strangers: ["yuri": strangers])
        #expect(both.measurement.negatives == 6 && both.measurement.threshold == ReplyRecognition.floor)
    }
}

