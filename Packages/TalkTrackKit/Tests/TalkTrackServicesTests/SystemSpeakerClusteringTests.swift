import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

func clusteringModels() throws -> (ModelSnapshot, ModelSnapshot) {
    let directory = try RelativePath("test/revision")
    return (ModelSnapshot(role: .segmentation, repository: "test/segments", revision: "1", directory: directory, preprocessingVersion: "1"),
            ModelSnapshot(role: .embedding, repository: "test/voices", revision: "1", directory: directory, preprocessingVersion: "1"))
}
func clusterRange(_ start: Double, _ end: Double) throws -> MediaInterval {
    try MediaInterval(start: MediaTime(seconds: start), end: MediaTime(seconds: end))
}
func clusterDay(_ date: String = "2026-10-08T10:00:00Z", zone: String = "UTC") throws -> RecordingDay {
    try RecordingDay(capturedAt: ISO8601DateFormatter().date(from: date)!, timeZoneIdentifier: zone)
}
func clusterVector(_ index: Int, second: Int? = nil, coefficient: Float = 0) -> [Float] {
    var values = [Float](repeating: 0, count: 256)
    values[index] = sqrt(1 - coefficient * coefficient)
    if let second { values[second] = coefficient }
    return values
}
func clusterObservation(_ slot: Int, _ start: Double, _ end: Double, voice: Int?, model: ModelSnapshot) throws -> SpeakerClusteringObservation {
    let active = try clusterRange(start, end)
    return SpeakerClusteringObservation(slot: slot, activity: [active], cleanSpeech: voice == nil ? [] : [active],
        embedding: voice.map { SpeakerWindowEmbedding(values: clusterVector($0), model: model) })
}

@Suite struct SystemSpeakerClusteringTests {
    @Test func sixSpeakersAcrossWindowsAndSameDayRecordingsKeepIDsWhenSlotsReverse() throws {
        let (segmentation, embedding) = try clusteringModels(), meetingID = UUID(), recordingID = UUID(), day = try clusterDay()
        var state = try SystemSpeakerClustering(meetingID: meetingID, segmentation: segmentation, embedding: embedding)
        var ids: [UUID] = []
        for window in 0..<6 {
            let start = Double(window * 2), end = start + 2
            let result = try state.process(recordingID: recordingID, day: day, context: clusterRange(start, end), owned: clusterRange(start, end),
                observations: [clusterObservation(window % 3 + 1, start, end, voice: window, model: embedding)])
            ids.append(try #require(result.first).speakerID)
            #expect(result.first?.number == UInt(window + 1))
        }
        #expect(Set(ids).count == 6)
        let laterRecording = UUID(), laterDay = try clusterDay("2026-10-08T18:00:00Z")
        for (offset, voice) in [5, 0, 3, 2, 1, 4].enumerated() {
            let start = Double(offset * 2), end = start + 2
            let result = try state.process(recordingID: laterRecording, day: laterDay, context: clusterRange(start, end), owned: clusterRange(start, end),
                observations: [clusterObservation(3 - offset % 3, start, end, voice: voice, model: embedding)])
            #expect(result.first?.speakerID == ids[voice])
        }
        #expect(state.speakers.count == 6)
        #expect(state.speakers.allSatisfy { Set($0.recordingDayIDs) == Set([day.id, laterDay.id]) })
    }

    /// Real call audio puts one voice at cosine ~0.6-0.8 to itself, below the
    /// streaming threshold, so the streaming pass splits it; consolidation joins it.
    @Test func consolidationMergesOneVoiceSplitByStreamingAndKeepsOthersApart() throws {
        let (segmentation, embedding) = try clusteringModels(), recordingID = UUID(), day = try clusterDay()
        var state = try SystemSpeakerClustering(meetingID: UUID(), segmentation: segmentation, embedding: embedding)
        let vectors: [[Float]?] = [clusterVector(0), clusterVector(0, second: 1, coefficient: 0.8), clusterVector(2), nil,
                                   clusterVector(2, second: 3, coefficient: 0.6)]
        var ids: [UUID] = []
        for (window, vector) in vectors.enumerated() {
            let start = Double(window * 2), range = try clusterRange(start, start + 2)
            let observation = SpeakerClusteringObservation(slot: 1, activity: [range], cleanSpeech: vector == nil ? [] : [range],
                embedding: vector.map { SpeakerWindowEmbedding(values: $0, model: embedding) })
            // Adjacent windows do not overlap, so only voice similarity links them.
            ids.append(try #require(state.process(recordingID: recordingID, day: day, context: range, owned: range,
                                                  observations: [observation]).first).speakerID)
        }
        #expect(Set(ids).count == 5)
        let mapping = state.consolidation()
        #expect(mapping[ids[0]] == ids[0] && mapping[ids[1]] == ids[0])
        #expect(mapping[ids[2]] == ids[2] && mapping[ids[4]] == ids[2])
        #expect(mapping[ids[3]] == nil)
        // A stricter threshold keeps every voiced cluster apart.
        #expect(Set(state.consolidation(threshold: 0.9).values).count == 4)
        // Voices the segmentation separated in one window never merge, however similar.
        let apart = state.consolidation(apart: [ids[1]: [ids[0]], ids[0]: [ids[1]]])
        #expect(apart[ids[0]] != apart[ids[1]] && apart[ids[4]] == ids[2])
    }

    /// A short reply has no clean vector; it takes a nearby voice only when the
    /// segmentation never heard the two as different people in one window.
    @Test func shortReplyKeepsItsOwnVoiceNextToASeparatedSpeaker() throws {
        let (segmentation, embedding) = try clusteringModels(), recordingID = UUID(), day = try clusterDay()
        var state = try SystemSpeakerClustering(meetingID: UUID(), segmentation: segmentation, embedding: embedding)
        func speaker(_ start: Double, _ end: Double, vector: [Float]?) throws -> UUID {
            let range = try clusterRange(start, end)
            let observation = SpeakerClusteringObservation(slot: 1, activity: [range], cleanSpeech: vector == nil ? [] : [range],
                embedding: vector.map { SpeakerWindowEmbedding(values: $0, model: embedding) })
            return try #require(state.process(recordingID: recordingID, day: day, context: range, owned: range,
                                              observations: [observation]).first).speakerID
        }
        let asker = try speaker(0, 4, vector: clusterVector(0))
        let reply = try speaker(4, 5, vector: nil)
        let echo = try speaker(5, 6, vector: nil)
        func block(_ start: Double, _ end: Double, _ id: UUID) throws -> FinalTextBlock {
            let interval = try clusterRange(start, end)
            return FinalTextBlock(id: UUID(), recordingID: recordingID, day: day, track: .system,
                words: [FinalAlignedWord(text: "word", active: interval, wallClockStart: Date(timeIntervalSince1970: start))],
                interval: interval, speakerCandidates: [id], originalText: "word")
        }
        let blocks = try [block(0, 4, asker), block(4.2, 5, reply), block(5.2, 6, echo)]
        let merged = SpeakerConsolidation(clustering: state, blocks: blocks, apart: [asker: [reply], reply: [asker]])
        #expect(merged.blocks.map(\.speakerCandidates) == [[asker], [reply], [asker]])
        #expect(Set(merged.speakers.map(\.id)) == Set([asker, reply, echo]))
    }

    @Test func dayAndMeetingIsolationAndDSTKeepCapturedProvenance() throws {
        let (segmentation, embedding) = try clusteringModels(), meetingID = UUID()
        var state = try SystemSpeakerClustering(meetingID: meetingID, segmentation: segmentation, embedding: embedding)
        let day = try clusterDay("2026-10-25T00:30:00Z", zone: "Europe/London")
        let sameDate = try clusterDay("2026-10-25T02:30:00Z", zone: "Europe/London")
        #expect(day.utcOffsetSeconds != sameDate.utcOffsetSeconds)
        func first(_ day: RecordingDay, state: inout SystemSpeakerClustering) throws -> UUID {
            let values = try state.process(recordingID: UUID(), day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2),
                observations: [clusterObservation(1, 0, 2, voice: 0, model: embedding)])
            return try #require(values.first).speakerID
        }
        let original = try first(day, state: &state)
        #expect(try first(sameDate, state: &state) == original)
        let nextDay = try clusterDay("2026-10-26T02:30:00Z", zone: "Europe/London")
        let nextID = try first(nextDay, state: &state)
        #expect(nextID != original)
        #expect(state.speakers.last?.number == 1)
        var other = try SystemSpeakerClustering(meetingID: UUID(), segmentation: segmentation, embedding: embedding)
        #expect(try first(day, state: &other) != original)
    }

    @Test func simultaneousCandidatesWithIdenticalVectorsNeverCollapseAndMixedSpeechCannotTrain() throws {
        let (segmentation, embedding) = try clusteringModels(), day = try clusterDay()
        var state = try SystemSpeakerClustering(meetingID: UUID(), segmentation: segmentation, embedding: embedding)
        _ = try state.process(recordingID: UUID(), day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2),
            observations: [clusterObservation(1, 0, 2, voice: 0, model: embedding)])
        let recordingID = UUID()
        let activity = [try clusterRange(0, 2), try clusterRange(3, 5)]
        let first = SpeakerClusteringObservation(slot: 1, activity: activity, cleanSpeech: [try clusterRange(0, 2)],
            embedding: SpeakerWindowEmbedding(values: clusterVector(0), model: embedding))
        let second = SpeakerClusteringObservation(slot: 2, activity: [try clusterRange(3, 7)], cleanSpeech: [try clusterRange(5, 7)],
            embedding: SpeakerWindowEmbedding(values: clusterVector(0), model: embedding))
        let result = try state.process(recordingID: recordingID, day: day, context: clusterRange(0, 7), owned: clusterRange(0, 7), observations: [first, second])
        let firstID = try #require(result.first { $0.slot == 1 }).speakerID
        let secondID = try #require(result.first { $0.slot == 2 }).speakerID
        #expect(firstID != secondID)
        #expect(state.speakers.count == 3)
        #expect(result.filter { $0.active == (try? clusterRange(3, 5)) }.count == 1)
        let before = try state.checkpoint()
        #expect(throws: SpeakerClusteringError.invalidInput) {
            try state.process(recordingID: UUID(), day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2),
                observations: [clusterObservation(1, 0, 2, voice: 0, model: embedding), clusterObservation(2, 0, 2, voice: 1, model: embedding)])
        }
        #expect(try state.checkpoint() == before)
    }

    @Test func ambiguityAndInsufficientSpeechRemainNewUnknownsWithoutPoisoningOldVoices() throws {
        let (segmentation, embedding) = try clusteringModels(), day = try clusterDay(), meetingID = UUID()
        var state = try SystemSpeakerClustering(meetingID: meetingID, segmentation: segmentation, embedding: embedding)
        let first = SpeakerClusteringObservation(slot: 1, activity: [try clusterRange(0, 2), try clusterRange(4, 6)], cleanSpeech: [try clusterRange(0, 2)],
            embedding: SpeakerWindowEmbedding(values: clusterVector(0), model: embedding))
        let second = SpeakerClusteringObservation(slot: 2, activity: [try clusterRange(3, 8)], cleanSpeech: [try clusterRange(6, 8)],
            embedding: SpeakerWindowEmbedding(values: clusterVector(0, second: 1, coefficient: 0.6), model: embedding))
        let seeded = try state.process(recordingID: UUID(), day: day, context: clusterRange(0, 8), owned: clusterRange(0, 8), observations: [first, second])
        let firstID = try #require(seeded.first { $0.slot == 1 }).speakerID
        let secondID = try #require(seeded.first { $0.slot == 2 }).speakerID
        #expect(firstID != secondID)
        let recordingID = UUID()
        let uncertain = try state.process(recordingID: recordingID, day: day, context: clusterRange(0, 0.5), owned: clusterRange(0, 0.5),
            observations: [clusterObservation(1, 0, 0.5, voice: nil, model: embedding)])
        #expect(uncertain.first?.speakerID != firstID)
        #expect(state.retainedVectorCount == 2)
        // Similarity below the threshold also creates another unnamed voice.
        let different = try state.process(recordingID: UUID(), day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2),
            observations: [clusterObservation(1, 0, 2, voice: 1, model: embedding)])
        let middle = SpeakerClusteringObservation(slot: 1, activity: [try clusterRange(0, 2)], cleanSpeech: [try clusterRange(0, 2)],
            embedding: SpeakerWindowEmbedding(values: clusterVector(0, second: 1, coefficient: sqrt(0.1)), model: embedding))
        let ambiguous = try state.process(recordingID: UUID(), day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2), observations: [middle])
        #expect(ambiguous.first?.speakerID != firstID)
        #expect(ambiguous.first?.speakerID != secondID)
        #expect(ambiguous.first?.speakerID != different.first?.speakerID)
    }

    @Test func cleanTemporalOverlapCarriesAnIDAcrossSlotPermutationWithoutAnEmbedding() throws {
        let (segmentation, embedding) = try clusteringModels(), day = try clusterDay(), recordingID = UUID()
        var state = try SystemSpeakerClustering(meetingID: UUID(), segmentation: segmentation, embedding: embedding)
        let first = try state.process(recordingID: recordingID, day: day, context: clusterRange(0, 2), owned: clusterRange(0, 1.5),
            observations: [SpeakerClusteringObservation(slot: 1, activity: [try clusterRange(0, 2)])])
        let second = try state.process(recordingID: recordingID, day: day, context: clusterRange(1, 3), owned: clusterRange(1.5, 3),
            observations: [SpeakerClusteringObservation(slot: 3, activity: [try clusterRange(1, 3)])])
        #expect(first.first?.speakerID == second.first?.speakerID)
        #expect(first.first?.active.end == second.first?.active.start)
        #expect(state.speakers.count == 1)
        try state.gap(recordingID: recordingID, day: day, active: clusterRange(3, 4))
        let afterGap = try state.process(recordingID: recordingID, day: day, context: clusterRange(4, 4.5), owned: clusterRange(4, 4.5),
            observations: [clusterObservation(3, 4, 4.5, voice: nil, model: embedding)])
        #expect(afterGap.first?.speakerID != first.first?.speakerID)
    }

    @Test func checkpointRetainsIDsCompatibilityAndRejectsReplayAndInvalidEvidence() throws {
        let (segmentation, embedding) = try clusteringModels(), meetingID = UUID(), recordingID = UUID(), day = try clusterDay()
        var state = try SystemSpeakerClustering(meetingID: meetingID, segmentation: segmentation, embedding: embedding)
        let original = try state.process(recordingID: recordingID, day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2),
            observations: [clusterObservation(1, 0, 2, voice: 0, model: embedding)])
        let data = try state.checkpoint()
        var restored = try SystemSpeakerClustering(restoring: data, meetingID: meetingID, segmentation: segmentation, embedding: embedding)
        #expect(restored.speakers == state.speakers)
        #expect(throws: SpeakerClusteringError.outOfOrder) {
            try restored.process(recordingID: recordingID, day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2), observations: [])
        }
        let next = try restored.process(recordingID: recordingID, day: day, context: clusterRange(2, 4), owned: clusterRange(2, 4),
            observations: [clusterObservation(3, 2, 4, voice: 0, model: embedding)])
        #expect(next.first?.speakerID == original.first?.speakerID)
        #expect(throws: SpeakerClusteringError.invalidCheckpoint) {
            try SystemSpeakerClustering(restoring: data, meetingID: UUID(), segmentation: segmentation, embedding: embedding)
        }
        let incompatible = ModelSnapshot(role: .embedding, repository: embedding.repository, revision: "2", directory: embedding.directory, preprocessingVersion: "2")
        #expect(throws: SpeakerClusteringError.invalidCheckpoint) {
            try SystemSpeakerClustering(restoring: data, meetingID: meetingID, segmentation: segmentation, embedding: incompatible)
        }
        for vector in [[Float](repeating: 0, count: 256), [.nan], [Float](repeating: 1, count: 256)] {
            #expect(throws: SpeakerClusteringError.invalidInput) {
                try state.process(recordingID: UUID(), day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2),
                    observations: [SpeakerClusteringObservation(slot: 1, activity: [clusterRange(0, 2)], cleanSpeech: [clusterRange(0, 2)],
                        embedding: SpeakerWindowEmbedding(values: vector, model: embedding))])
            }
        }
        #expect(try state.checkpoint() == data)
    }

    @Test func twoHoursOfMetadataRetainOnlyEightVectorsAndOneWindowContext() throws {
        let (segmentation, embedding) = try clusteringModels(), day = try clusterDay(), recordingID = UUID()
        var state = try SystemSpeakerClustering(meetingID: UUID(), segmentation: segmentation, embedding: embedding)
        var firstID: UUID?
        for i in 0..<720 {
            let start = Double(i * 10)
            let result = try state.process(recordingID: recordingID, day: day, context: clusterRange(start, start + 10), owned: clusterRange(start, start + 10),
                observations: [clusterObservation(i % 3 + 1, start, start + 10, voice: 0, model: embedding)])
            if i == 0 { firstID = result.first?.speakerID }
            #expect(result.first?.speakerID == firstID)
        }
        #expect(state.retainedVectorCount == 8)
        #expect(state.speakers.count == 1)
        #expect(try state.checkpoint().count < 12_000)
    }

    @Test func boundedHistoryRetainsItsAnchorAndCannotDriftThroughSimilarIntermediateVoices() throws {
        let (segmentation, embedding) = try clusteringModels(), day = try clusterDay()
        var state = try SystemSpeakerClustering(meetingID: UUID(), segmentation: segmentation, embedding: embedding)
        func input(_ angle: Double) throws -> SpeakerClusteringObservation {
            SpeakerClusteringObservation(slot: 1, activity: [try clusterRange(0, 2)], cleanSpeech: [try clusterRange(0, 2)],
                embedding: SpeakerWindowEmbedding(values: clusterVector(0, second: 1, coefficient: Float(sin(angle * .pi / 180))), model: embedding))
        }
        let first = try state.process(recordingID: UUID(), day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2), observations: [input(0)])
        for _ in 0..<12 {
            let next = try state.process(recordingID: UUID(), day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2), observations: [input(20)])
            #expect(next.first?.speakerID == first.first?.speakerID)
        }
        #expect(state.retainedVectorCount == 8)
        let different = try state.process(recordingID: UUID(), day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2), observations: [input(40)])
        #expect(different.first?.speakerID != first.first?.speakerID)
        #expect(state.speakers.count == 2)
    }

    @Test func corruptedCheckpointRejectsImpossibleCoactivityDuplicateIDsAndInvalidVectors() throws {
        let (segmentation, embedding) = try clusteringModels(), meetingID = UUID(), day = try clusterDay()
        var state = try SystemSpeakerClustering(meetingID: meetingID, segmentation: segmentation, embedding: embedding)
        _ = try state.process(recordingID: UUID(), day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2), observations: [
            SpeakerClusteringObservation(slot: 1, activity: [clusterRange(0, 2)]),
            SpeakerClusteringObservation(slot: 2, activity: [clusterRange(0, 2)])])
        let json = try #require(JSONSerialization.jsonObject(with: state.checkpoint()) as? [String: Any])
        for corruption in 0..<4 {
            var candidate = json, value = try #require(json["value"] as? [String: Any])
            var days = try #require(value["days"] as? [[String: Any]])
            var clusters = try #require(days[0]["clusters"] as? [[String: Any]])
            if corruption == 0 {
                var context = try #require(value["context"] as? [String: Any])
                var slots = try #require(context["slots"] as? [[String: Any]])
                slots[1]["id"] = slots[0]["id"]
                context["slots"] = slots; value["context"] = context
            } else if corruption == 1 {
                clusters[1]["id"] = clusters[0]["id"]
            } else if corruption == 2 {
                clusters[0]["vectors"] = [[Float](repeating: 0, count: 256)]
            } else {
                var cursors = try #require(value["cursors"] as? [[String: Any]])
                cursors[0]["end"] = 0; value["cursors"] = cursors
            }
            days[0]["clusters"] = clusters; value["days"] = days; candidate["value"] = value
            let data = try JSONSerialization.data(withJSONObject: candidate)
            #expect(throws: SpeakerClusteringError.invalidCheckpoint) {
                try SystemSpeakerClustering(restoring: data, meetingID: meetingID, segmentation: segmentation, embedding: embedding)
            }
        }
    }

    /// A 16.7-minute call needed ~170 provisional clusters and failed at 128.
    @Test func checkpointFromSmallerLimitResumesUnderLargerOne() throws {
        let (segmentation, embedding) = try clusteringModels(), day = try clusterDay(), meeting = UUID(), recording = UUID()
        #expect(SpeakerClusteringPolicy.standard.maximumSpeakersPerDay >= 1024)
        let small = try SpeakerClusteringPolicy(maximumSpeakersPerDay: 1)
        var state = try SystemSpeakerClustering(meetingID: meeting, segmentation: segmentation, embedding: embedding, policy: small)
        _ = try state.process(recordingID: recording, day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2),
            observations: [clusterObservation(1, 0, 2, voice: 0, model: embedding)])
        let saved = try state.checkpoint()
        var resumed = try SystemSpeakerClustering(restoring: saved, meetingID: meeting, segmentation: segmentation,
            embedding: embedding, policy: .standard)
        let next = try resumed.process(recordingID: recording, day: day, context: clusterRange(2, 4), owned: clusterRange(2, 4),
            observations: [clusterObservation(1, 2, 4, voice: 1, model: embedding)])
        #expect(Set(next.map { $0.number }) == [2] && resumed.speakers.count == 2)
        // A smaller limit or other thresholds cannot reinterpret a checkpoint.
        #expect(throws: SpeakerClusteringError.invalidCheckpoint) {
            try SystemSpeakerClustering(restoring: try resumed.checkpoint(), meetingID: meeting, segmentation: segmentation,
                embedding: embedding, policy: small)
        }
        #expect(throws: SpeakerClusteringError.invalidCheckpoint) {
            try SystemSpeakerClustering(restoring: saved, meetingID: meeting, segmentation: segmentation,
                embedding: embedding, policy: try SpeakerClusteringPolicy(minimumSimilarity: 0.8))
        }
    }

    @Test func resourceLimitFailsAtomicallyAndCancelledProcessingDoesNotMutate() async throws {
        let (segmentation, embedding) = try clusteringModels(), day = try clusterDay()
        var state = try SystemSpeakerClustering(meetingID: UUID(), segmentation: segmentation, embedding: embedding,
            policy: SpeakerClusteringPolicy(maximumSpeakersPerDay: 1))
        _ = try state.process(recordingID: UUID(), day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2),
            observations: [clusterObservation(1, 0, 2, voice: 0, model: embedding)])
        let before = try state.checkpoint()
        #expect(throws: SpeakerClusteringError.speakerLimit) {
            try state.process(recordingID: UUID(), day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2),
                observations: [clusterObservation(1, 0, 2, voice: 1, model: embedding)])
        }
        #expect(try state.checkpoint() == before)
        let snapshot = state
        let work = Task {
            while !Task.isCancelled { await Task.yield() }
            var copy = snapshot
            return try copy.process(recordingID: UUID(), day: day, context: clusterRange(0, 2), owned: clusterRange(0, 2), observations: [])
        }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
    }
}
