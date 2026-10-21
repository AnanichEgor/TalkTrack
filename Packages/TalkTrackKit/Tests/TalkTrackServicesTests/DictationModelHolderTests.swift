import Foundation
import Testing
@testable import TalkTrackServices

private actor ModelEvents {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

@Suite struct DictationModelHolderTests {
    private func holder(_ events: ModelEvents) -> DictationModelHolder<String> {
        DictationModelHolder(load: { key in await events.add("load \(key)"); return key },
                             unload: { model in await events.add("unload \(model)") })
    }

    @Test func consecutiveDictationsLoadOnce() async throws {
        let events = ModelEvents(), models = holder(events)
        #expect(try await models.use("live-asr") { $0 } == "live-asr")
        #expect(try await models.use("live-asr") { $0 } == "live-asr")
        #expect(await events.values == ["load live-asr"])
        // Switching models replaces the loaded one.
        _ = try await models.use("final-asr") { $0 }
        #expect(await events.values == ["load live-asr", "unload live-asr", "load final-asr"])
    }

    @Test func idleUnloadOnlyWhenNothingHappenedSince() async throws {
        let events = ModelEvents(), models = holder(events)
        _ = try await models.use("live-asr") { $0 }
        let stale = await models.touch()
        _ = try await models.use("live-asr") { $0 }
        await models.unloadIfIdle(since: stale)
        #expect(await models.loadedKey == "live-asr")
        let current = await models.touch()
        await models.unloadIfIdle(since: current)
        #expect(await models.loadedKey == nil)
        #expect(await events.values == ["load live-asr", "unload live-asr"])
    }

    @Test func captureUnloadWaitsForNoUser() async throws {
        let events = ModelEvents(), models = holder(events)
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let dictation = Task { try await models.use("live-asr") { model -> String in
            enteredContinuation.yield()
            for await _ in release { break }
            return model
        } }
        for await _ in entered { break }
        // A meeting starting now cannot pull the model from under the dictation.
        await models.unloadAll()
        #expect(await models.loadedKey == "live-asr")
        releaseContinuation.yield()
        #expect(try await dictation.value == "live-asr")
        await models.unloadAll()
        #expect(await models.loadedKey == nil)
        #expect(await events.values == ["load live-asr", "unload live-asr"])
    }

    @Test func failedLoadLeavesNothingLoaded() async {
        let models = DictationModelHolder<String>(load: { _ in throw CocoaError(.fileNoSuchFile) }, unload: { _ in })
        await #expect(throws: CocoaError.self) { try await models.use("live-asr") { $0 } }
        #expect(await models.loadedKey == nil)
    }
}

@Suite struct DictationAudioTests {
    @Test func shortAudioIsOnePiece() {
        let samples = [Float](repeating: 0.1, count: 16_000 * 30)
        #expect(DictationAudio.pieces(samples).map(\.count) == [samples.count])
    }

    @Test func longAudioSplitsAtTheQuietestMoment() {
        var samples = [Float](repeating: 0.2, count: 16_000 * 150)
        // Quiet stretches at 55 s and 112 s.
        for second in [55, 112] { for index in (second * 16_000)..<(second * 16_000 + 3_200) { samples[index] = 0 } }
        let pieces = DictationAudio.pieces(samples)
        #expect(pieces.count == 3)
        #expect(pieces.reduce(0) { $0 + $1.count } == samples.count)
        #expect(abs(Double(pieces[0].count) / 16_000 - 55.05) < 0.1)
        #expect(pieces.allSatisfy { $0.count <= 60 * 16_000 })
    }
}
