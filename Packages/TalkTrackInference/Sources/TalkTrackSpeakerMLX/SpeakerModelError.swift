import Foundation

enum SpeakerModelError: LocalizedError {
    case missingWeights(URL)

    var errorDescription: String? {
        switch self {
        case .missingWeights(let directory):
            "The speaker model is missing model.safetensors in \(directory.lastPathComponent). Reinstall the model."
        }
    }
}
