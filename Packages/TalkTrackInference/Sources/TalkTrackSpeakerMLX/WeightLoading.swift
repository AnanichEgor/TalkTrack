// Adapted from soniqo/speech-swift, revision 1e6e0e527be00e9c0ac79ebb255ea54cd6e9dd80.
// Apache-2.0; see ThirdParty/SpeechSwift-LICENSE and source provenance.
// TalkTrack modifications: Removed multi-backend support imports; use local missing-weights error.
import Foundation
import TalkTrackServices
import MLX
import MLXNN

/// Weight loading for the PyanNet segmentation model.
///
/// Loads from safetensors files produced by `scripts/convert_pyannote.py`.
/// The conversion script pre-computes sinc filters and transposes Conv1d weights,
/// so loading is a straightforward parameter tree update.
enum SegmentationWeightLoader {

    /// Load weights from a directory containing model.safetensors.
    nonisolated(nonsending) static func loadWeights(
        model: SegmentationModel,
        from localDirectory: ModelLocalDirectory
    ) async throws {
        let directory = try await localDirectory.validatedURL()
        let weightsURL = directory.appendingPathComponent("model.safetensors")

        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw SpeakerModelError.missingWeights(directory)
        }

        let weights = try MLX.loadArrays(url: weightsURL)

        // The conversion script produces keys matching our module structure directly.
        // Use ModuleParameters.unflattened to build the nested parameter tree.
        let parameters = ModuleParameters.unflattened(weights)

        // Apply to model
        try model.update(parameters: parameters, verify: .all)

        // Evaluate all parameters to ensure they're materialized
        MLX.eval(model.parameters())
    }
}
