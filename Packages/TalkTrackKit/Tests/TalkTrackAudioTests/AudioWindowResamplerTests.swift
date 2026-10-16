import Foundation
import Testing
@testable import TalkTrackAudio

@Suite struct AudioWindowResamplerTests {
    @Test(arguments: [1, 2, 3, 17, 8191, 8192, 8193, 47_999, 48_000, 48_001, 1_440_000])
    func nativeConversionRetainsFractionalTailsAndSeparatesModelPadding(count: Int) throws {
        let output = try AudioWindowResampler.convert48K([Float](repeating: 0.1, count: count))
        #expect(output.validFrameCount == (count + 2) / 3)
        #expect(output.sourceFrameCount == count)
        #expect(output.samples.count == max(1600, output.validFrameCount))
        #expect(output.samples.allSatisfy { $0.isFinite })
        #expect(output.samples.dropFirst(output.validFrameCount).allSatisfy { $0 == 0 })
        #expect(output.samples.count <= 480_000)
    }

    @Test func nativeFilterPreservesSpeechBandTimingAndRejectsAliasing() throws {
        let count = 48_000
        let low = (0..<count).map { Float(0.2 * sin(2 * .pi * 1000 * Double($0) / 48_000)) }
        let high = (0..<count).map { Float(0.2 * sin(2 * .pi * 19_000 * Double($0) / 48_000)) }
        let output = try AudioWindowResampler.convert48K(low, minimumOutputFrames: 0)
        let rejected = try AudioWindowResampler.convert48K(high, minimumOutputFrames: 0)
        var bestLag = 0, bestError = Double.infinity
        for lag in -2...2 {
            var sum = 0.0
            for i in 512..<15_488 {
                let expected = 0.2 * sin(2 * .pi * 1000 * Double(i + lag) / 16_000)
                let difference = Double(output.samples[i]) - expected
                sum += difference * difference
            }
            let error = sqrt(sum / 14_976)
            if error < bestError { bestError = error; bestLag = lag }
        }
        #expect(abs(bestLag) <= 1)
        #expect(bestError < 0.002)
        let aliasRMS = sqrt(rejected.samples[512..<15_488].reduce(0.0) { $0 + Double($1) * Double($1) } / 14_976)
        #expect(aliasRMS < 0.0025) // >35 dB rejection against a 0.2-amplitude sine.
        var impulse = [Float](repeating: 0, count: count)
        impulse[6000] = 0.5
        let pulse = try AudioWindowResampler.convert48K(impulse, minimumOutputFrames: 0)
        let peak = try #require(pulse.samples.indices.max { abs(pulse.samples[$0]) < abs(pulse.samples[$1]) })
        #expect(abs(peak - 2000) <= 1)
    }

    /// Loud decoded audio slightly above full scale stays within the models' ±1.
    @Test func overshootIsLimitedToFullScale() throws {
        let loud = (0..<48_000).map { index -> Float in index % 96 < 48 ? 1.2 : -1.2 }
        let converted = try AudioWindowResampler.convert48K(loud)
        #expect(converted.samples.allSatisfy { abs($0) <= 1 })
        #expect(converted.samples.contains(1) && converted.samples.contains(-1))
    }

    @Test func invalidInputIsRejectedWithoutUnboundedAllocation() throws {
        for samples: [Float] in [[], [.nan], [.infinity]] {
            #expect(throws: AudioResamplingError.invalidPCM) { try AudioWindowResampler.convert48K(samples) }
        }
        #expect(throws: AudioResamplingError.invalidPCM) {
            try AudioWindowResampler.convert48K([Float](repeating: 0, count: 1_440_001))
        }
        #expect(throws: AudioResamplingError.invalidPCM) { try AudioWindowResampler.convert48K([0], minimumOutputFrames: 16_001) }
    }

    @Test func cancelledWorkerDoesNotEnterConversion() async {
        let work = Task {
            while !Task.isCancelled { await Task.yield() }
            return try AudioWindowResampler.convert48K([Float](repeating: 0, count: 48_000))
        }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
    }
}
