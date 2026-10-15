// Adapted from soniqo/speech-swift, revision 1e6e0e527be00e9c0ac79ebb255ea54cd6e9dd80.
// Apache-2.0; see ThirdParty/SpeechSwift-LICENSE and source provenance.
// TalkTrack modifications: Keep only segmentation configuration.
import Foundation

/// Model configuration for pyannote PyanNet segmentation.
public struct SegmentationConfig: Sendable {
    /// Audio sample rate in Hz
    public let sampleRate: Int

    /// SincNet filter counts per layer
    public let sincnetFilters: [Int]
    /// SincNet kernel sizes per layer
    public let sincnetKernelSizes: [Int]
    /// SincNet strides per layer
    public let sincnetStrides: [Int]
    /// SincNet max-pool kernel sizes per layer
    public let sincnetPoolSizes: [Int]

    /// LSTM hidden size (per direction; output is 2x for bidirectional)
    public let lstmHiddenSize: Int
    /// Number of LSTM layers
    public let lstmNumLayers: Int

    /// Linear layer hidden size
    public let linearHiddenSize: Int
    /// Number of linear layers (before classifier)
    public let linearNumLayers: Int

    /// Number of output classes (powerset)
    public let numClasses: Int

    /// Default configuration for pyannote/segmentation-3.0
    public static let `default` = SegmentationConfig(
        sampleRate: 16000,
        sincnetFilters: [80, 60, 60],
        sincnetKernelSizes: [251, 5, 5],
        sincnetStrides: [10, 1, 1],
        sincnetPoolSizes: [3, 3, 3],
        lstmHiddenSize: 128,
        lstmNumLayers: 4,
        linearHiddenSize: 128,
        linearNumLayers: 2,
        numClasses: 7
    )
}

