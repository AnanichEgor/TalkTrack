import Foundation
import TalkTrackDomain
import TalkTrackServices
import TalkTrackTextMLX

extension InferenceRuntime: FinalTranscriptionInference {
    public func unavailableFinalModels(_ models: [ModelSnapshot]) async throws -> [ModelRole] {
        var missing: [ModelRole] = []
        let catalog = try ModelCatalog.bundled()
        for model in models {
            _ = try catalog.model(for: model)
            if try await !isInstalled(model) { missing.append(model.role) }
        }
        return missing
    }

    public func finalText(_ model: ModelSnapshot, samples: [Float], language: MeetingLanguage) async throws -> FinalASRText {
        guard model.role == .finalASR else { throw FinalTranscriptionError.invalidJob }
        // Only exact digital silence skips ASR; quiet speech is never classified
        // as a source gap or removed by a volume threshold.
        guard (1600...160_000).contains(samples.count), samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
            throw FinalTranscriptionError.invalidJob
        }
        if samples.allSatisfy({ $0 == 0 }) { return FinalASRText(text: "", language: language) }
        let result = try await transcribe(model, samples: samples, language: language == .auto ? nil : language == .english ? "English" : "Russian",
            maxTokens: 1024, allowEmpty: true)
        let detected: MeetingLanguage = language != .auto ? language :
            result.language?.lowercased() == "russian" ? .russian :
            result.language?.lowercased() == "english" ? .english : .auto
        // `.auto` reports an undetected or unsupported language; the pipeline
        // transcribes the window again in the track's established language.
        return FinalASRText(text: result.text, language: detected)
    }

    public func finalAlignment(_ model: ModelSnapshot, samples: [Float], text: String,
                               language: MeetingLanguage) async throws -> [FinalAlignmentItem] {
        guard model.role == .alignment, language != .auto else { throw FinalTranscriptionError.invalidJob }
        return try await align(model, samples: samples, text: text, language: language == .russian ? "Russian" : "English").map {
            FinalAlignmentItem(text: $0.text, relative: try MediaInterval(start: MediaTime(seconds: $0.startTime), end: MediaTime(seconds: $0.endTime)))
        }
    }

    public func correctIndexed(_ model: ModelSnapshot, settings: ProcessingSettings,
                               blocks: [IndexedCorrection]) async throws -> FinalCorrectionResponse {
        guard model.role == .spelling else { throw FinalTranscriptionError.invalidJob }
        do {
            let result = try await generate(model, settings: settings, system: IndexedSpellingCorrection.systemPrompt,
                prompt: IndexedSpellingCorrection.prompt(blocks))
            return FinalCorrectionResponse(text: result.text, contextPlan: result.contextPlan, generatedTokens: result.generatedTokens)
        } catch TextAdapterError.inputBudget { throw FinalTranscriptionError.correctionBudget }
        catch TextContextPlanningError.requiresPartition { throw FinalTranscriptionError.correctionBudget }
        catch TextContextPlanningError.outputNeedsPartition { throw FinalTranscriptionError.correctionBudget }
    }
}
