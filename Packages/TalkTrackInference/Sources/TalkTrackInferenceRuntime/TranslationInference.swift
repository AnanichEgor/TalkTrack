import TalkTrackDomain
import TalkTrackServices
import TalkTrackTextMLX

extension InferenceRuntime: TranslationTextInference {
    public func translationTokenCount(_ model: ModelSnapshot, settings: ProcessingSettings,
                                      system: String, prompt: String) async throws -> Int {
        guard model.role == .translation else { throw TranslationError.invalidRequest }
        return try await formattedTextTokens(model, settings: settings, system: system, prompt: prompt)
    }
    public func translationText(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String,
                                outputTokens: Int) async throws -> TranslationTextResponse {
        guard model.role == .translation else { throw TranslationError.invalidRequest }
        do {
            let value = try await generate(model, settings: settings, system: system, prompt: prompt, maxTokens: outputTokens)
            return TranslationTextResponse(text: value.text, contextPlan: value.contextPlan, generatedTokens: value.generatedTokens)
        } catch TextAdapterError.incompleteOutput { throw TranslationError.outputLimit }
    }
}
