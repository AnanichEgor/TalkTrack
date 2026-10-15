import Foundation
import TalkTrackDomain
import TalkTrackServices

extension InferenceRuntime: SystemSpeakerInference {
    public func speakerActivity(_ model: ModelSnapshot, samples: [Float]) async throws -> [SpeakerWindowActivity] {
        guard model.role == .segmentation else { throw SpeakerClusteringError.incompatibleModel }
        return try await segment(model, samples: samples).map {
            SpeakerWindowActivity(slot: $0.slot, relative: try MediaInterval(start: MediaTime(seconds: $0.start), end: MediaTime(seconds: $0.end)))
        }
    }
    public func speakerEmbedding(_ model: ModelSnapshot, samples: [Float]) async throws -> SpeakerWindowEmbedding {
        guard model.role == .embedding else { throw SpeakerClusteringError.incompatibleModel }
        let value = try await embed(model, samples: samples)
        return SpeakerWindowEmbedding(values: value.values, model: value.model)
    }
}
