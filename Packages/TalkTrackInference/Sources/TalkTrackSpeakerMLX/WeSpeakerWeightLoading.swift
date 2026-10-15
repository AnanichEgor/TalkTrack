// Adapted from soniqo/speech-swift, revision 1e6e0e527be00e9c0ac79ebb255ea54cd6e9dd80.
// Apache-2.0; see ThirdParty/SpeechSwift-LICENSE and source provenance.
// TalkTrack modifications: Removed multi-backend support imports; use local missing-weights error.
import Foundation
import TalkTrackServices
import MLX
import MLXNN

/// Weight loading for the WeSpeaker ResNet34-LM speaker embedding model.
///
/// Loads from safetensors files produced by `scripts/convert_wespeaker.py`.
/// The conversion script fuses BatchNorm into Conv2d and transposes weights,
/// so loading is a straightforward parameter tree update.
enum WeSpeakerWeightLoader {

    /// Load weights from a directory containing model.safetensors.
    nonisolated(nonsending) static func loadWeights(
        model: WeSpeakerNetwork,
        from localDirectory: ModelLocalDirectory
    ) async throws {
        let directory = try await localDirectory.validatedURL()
        let weightsURL = directory.appendingPathComponent("model.safetensors")

        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw SpeakerModelError.missingWeights(directory)
        }

        let weights = try MLX.loadArrays(url: weightsURL)

        let parameters = ModuleParameters.unflattened(weights)

        try model.update(parameters: parameters, verify: .all)

        MLX.eval(model.parameters())
    }
}
