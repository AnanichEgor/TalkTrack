@preconcurrency import AVFoundation
import Foundation

public enum AudioResamplingError: Error, Equatable, LocalizedError, Sendable {
    case invalidPCM, conversionFailed(String), unexpectedFrameCount
    public var errorDescription: String? {
        switch self {
        case .invalidPCM: "The audio window is invalid or exceeds thirty seconds."
        case .conversionFailed(let message): "Audio conversion failed: \(message)"
        case .unexpectedFrameCount: "Audio conversion returned an unexpected number of frames."
        }
    }
}

public struct ResampledAudioWindow: Sendable {
    public static let sampleRate: UInt32 = 16_000
    public let samples: [Float]
    /// Padding used to satisfy a model's minimum input length is not source
    /// audio. Consumers must map timestamps against sourceFrameCount as well.
    public let validFrameCount: Int
    public let sourceFrameCount: Int
}

/// Independent, bounded stored-audio windows, not a real-time streaming
/// converter. Run on the audio reader worker, never on a hardware callback.
public enum AudioWindowResampler {
    public static let maximumSourceFrames = 1_440_000
    public static func convert48K(_ samples: [Float], minimumOutputFrames: Int = 1600) throws -> ResampledAudioWindow {
        guard !samples.isEmpty, samples.count <= maximumSourceFrames,
              (0...16_000).contains(minimumOutputFrames), samples.allSatisfy(\.isFinite) else {
            throw AudioResamplingError.invalidPCM
        }
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let source = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
                  let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
                  let converter = AVAudioConverter(from: source, to: target) else {
                throw AudioResamplingError.conversionFailed("The native sample-rate converter is unavailable")
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            // SDK contract: .normal has no output latency, and synthesizes
            // unavailable trailing frames when the input signals endOfStream.
            converter.primeMethod = .normal
            let expected = (samples.count + 2) / 3
            let paddedInput = expected * 3
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(paddedInput)),
                  let inputChannel = input.floatChannelData?[0],
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else {
                throw AudioResamplingError.conversionFailed("Cannot allocate the bounded conversion buffers")
            }
            input.frameLength = AVAudioFrameCount(paddedInput)
            samples.withUnsafeBufferPointer { inputChannel.update(from: $0.baseAddress!, count: $0.count) }
            // Native SRC rounds fractional output lengths. At most two zero
            // source frames ensure the last partial 16 kHz frame is retained.
            if paddedInput > samples.count {
                inputChannel.advanced(by: samples.count).update(repeating: 0, count: paddedInput - samples.count)
            }
            var provided = false, result: [Float] = []
            result.reserveCapacity(max(expected, minimumOutputFrames))
            while true {
                try Task.checkCancellation()
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, state in
                    if provided { state.pointee = .endOfStream; return nil }
                    provided = true
                    state.pointee = .haveData
                    return input
                }
                guard status != .error, error == nil, let channel = output.floatChannelData?[0] else {
                    throw AudioResamplingError.conversionFailed(error?.localizedDescription ?? "The native converter rejected the window")
                }
                let count = Int(output.frameLength)
                guard count <= expected - result.count else { throw AudioResamplingError.unexpectedFrameCount }
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
                if status == .endOfStream { break }
                guard count > 0 else { throw AudioResamplingError.unexpectedFrameCount }
            }
            guard result.count == expected, result.allSatisfy(\.isFinite) else {
                throw AudioResamplingError.unexpectedFrameCount
            }
            if result.count < minimumOutputFrames {
                result.append(contentsOf: repeatElement(0, count: minimumOutputFrames - result.count))
            }
            return ResampledAudioWindow(samples: result, validFrameCount: expected, sourceFrameCount: samples.count)
        }
    }
}
