import Testing
@testable import TalkTrackServices

@Suite struct TextMemoryAdmissionTests {
    static let gib: UInt64 = 1 << 30
    static let small: Int64 = 3_269_669_552, large: Int64 = 7_100_711_638

    static func memory(_ physical: UInt64, free: UInt64 = 0, footprint: UInt64 = 0, pressure: Int32 = 1) -> NativeMemorySnapshot {
        NativeMemorySnapshot(physicalBytes: physical, reclaimableBytes: free, footprintBytes: footprint, peakResidentBytes: footprint, pressure: pressure)
    }

    @Test func denseModelsUseTheirOwnKVShape() throws {
        let gib = Self.gib
        #expect(try TextMemoryAdmission.estimate(weightBytes: Self.large, contextTokens: 32768, profile: .qwen35Dense9B) == UInt64(Self.large) + 5*gib)
        #expect(try TextMemoryAdmission.estimate(weightBytes: Self.large, contextTokens: 65536, profile: .qwen35Dense9B) == UInt64(Self.large) + 6*gib)
        #expect(try TextMemoryAdmission.estimate(weightBytes: Self.small, contextTokens: 32768, profile: .qwen35Dense4B) == UInt64(Self.small) + 4*gib)
    }

    /// What is free right now does not matter: macOS compresses and swaps other
    /// apps to make room. Only the Mac's RAM and critical pressure refuse.
    @Test func admissionDependsOnRAMNotOnFreeMemory() throws {
        let gib = Self.gib
        try TextMemoryAdmission.admit(weightBytes: Self.large, contextTokens: 32768, alreadyLoaded: false,
                                      memory: Self.memory(64*gib, free: 1*gib), profile: .qwen35Dense9B)
        try TextMemoryAdmission.admit(weightBytes: Self.large, contextTokens: 65536, alreadyLoaded: false,
                                      memory: Self.memory(32*gib, pressure: 2), profile: .qwen35Dense9B)
        try TextMemoryAdmission.admit(weightBytes: Self.small, contextTokens: 32768, alreadyLoaded: false,
                                      memory: Self.memory(16*gib), profile: .qwen35Dense4B)
        // The 9B model may be tried on a 16 GB Mac, even at 64K (about 12.6 GiB of 14 usable).
        for context in [32768, 65536] {
            try TextMemoryAdmission.admit(weightBytes: Self.large, contextTokens: context, alreadyLoaded: false,
                                          memory: Self.memory(16*gib), profile: .qwen35Dense9B)
        }
        // Larger than RAM minus the reserve: the 9B model on 8 GB, 4B at 64K on 8 GB.
        for (weights, context, profile) in [(Self.small, 65536, TextMemoryProfile.qwen35Dense4B), (Self.large, 32768, .qwen35Dense9B)] {
            #expect(throws: TextMemoryAdmissionError.unsafe) {
                try TextMemoryAdmission.admit(weightBytes: weights, contextTokens: context, alreadyLoaded: false,
                                              memory: Self.memory(8*gib, free: 7*gib), profile: profile)
            }
        }
        #expect(throws: TextMemoryAdmissionError.pressure) {
            try TextMemoryAdmission.admit(weightBytes: Self.large, contextTokens: 32768, alreadyLoaded: true,
                                          memory: Self.memory(64*gib, free: 50*gib, pressure: 4), profile: .qwen35Dense9B)
        }
    }

    @Test func briefCriticalPressureWaitsAndOnlyLastingPressureOrRunawayFootprintStops() throws {
        let gib = Self.gib, watch = GenerationMemoryWatch(grace: .seconds(60)), start = ContinuousClock.now
        #expect(try !watch.check(Self.memory(16*gib, free: 0, footprint: 12*gib, pressure: 2), now: start))
        // Opening apps: critical for a few seconds, then macOS has made room.
        #expect(try watch.check(Self.memory(24*gib, footprint: 10*gib, pressure: 4), now: start))
        #expect(try watch.check(Self.memory(24*gib, footprint: 10*gib, pressure: 4), now: start + .seconds(59)))
        #expect(try !watch.check(Self.memory(24*gib, footprint: 10*gib, pressure: 2), now: start + .seconds(60)))
        // A new critical stretch starts its own grace period.
        #expect(try watch.check(Self.memory(24*gib, footprint: 10*gib, pressure: 4), now: start + .seconds(70)))
        #expect(throws: TextMemoryAdmissionError.pressure) {
            try watch.check(Self.memory(24*gib, footprint: 10*gib, pressure: 4), now: start + .seconds(130))
        }
        #expect(throws: TextMemoryAdmissionError.pressure) {
            try GenerationMemoryWatch().check(Self.memory(64*gib, free: 20*gib, footprint: 57*gib), now: start)
        }
        #expect(TextMemoryAdmissionError.unsafe.errorDescription?.contains("4B text model") == true)
    }

    @Test func admissionWaitsOutBriefCriticalPressureButNotAnUnsafeRequest() async throws {
        let gib = Self.gib, start = ContinuousClock.now
        final class Script: @unchecked Sendable {
            var samples: [NativeMemorySnapshot]; var sleeps = 0; var now: ContinuousClock.Instant
            init(_ samples: [NativeMemorySnapshot], now: ContinuousClock.Instant) { self.samples = samples; self.now = now }
            func sample() -> NativeMemorySnapshot { samples.count > 1 ? samples.removeFirst() : samples[0] }
        }
        let critical = Self.memory(24*gib, pressure: 4), normal = Self.memory(24*gib, pressure: 2)
        let brief = Script([critical, critical, normal], now: start)
        try await TextMemoryAdmission.admit(weightBytes: Self.large, contextTokens: 32768, alreadyLoaded: false,
            profile: .qwen35Dense9B, watch: GenerationMemoryWatch(), sample: brief.sample,
            now: { brief.now }, sleep: { brief.now += $0; brief.sleeps += 1 })
        #expect(brief.sleeps == 2)

        let lasting = Script([critical], now: start)
        await #expect(throws: TextMemoryAdmissionError.pressure) {
            try await TextMemoryAdmission.admit(weightBytes: Self.large, contextTokens: 32768, alreadyLoaded: false,
                profile: .qwen35Dense9B, watch: GenerationMemoryWatch(grace: .seconds(1)), sample: lasting.sample,
                now: { lasting.now }, sleep: { lasting.now += $0; lasting.sleeps += 1 })
        }
        #expect(lasting.sleeps == 4)

        let unsafe = Script([Self.memory(8*gib, pressure: 4)], now: start)
        await #expect(throws: TextMemoryAdmissionError.unsafe) {
            try await TextMemoryAdmission.admit(weightBytes: Self.large, contextTokens: 32768, alreadyLoaded: false,
                profile: .qwen35Dense9B, watch: GenerationMemoryWatch(), sample: unsafe.sample,
                now: { unsafe.now }, sleep: { unsafe.now += $0; unsafe.sleeps += 1 })
        }
        #expect(unsafe.sleeps == 0)
    }
}
