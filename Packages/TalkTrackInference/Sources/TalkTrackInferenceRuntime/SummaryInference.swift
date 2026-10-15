import Foundation
import TalkTrackDomain
import TalkTrackServices
import TalkTrackTextMLX

extension InferenceRuntime: SummaryTextInference {
    public func tokenCounts(_ model: ModelSnapshot, settings: ProcessingSettings, texts: [String]) async throws -> [Int] {
        guard model.role == .summary else { throw SummaryGenerationError.invalidRequest }
        return try await textTokenCounts(model, settings: settings, texts: texts)
    }

    public func formattedTokenCount(_ model: ModelSnapshot, settings: ProcessingSettings,
                                    system: String, prompt: String) async throws -> Int {
        guard model.role == .summary else { throw SummaryGenerationError.invalidRequest }
        return try await formattedTextTokens(model, settings: settings, system: system, prompt: prompt)
    }

    public func summaryText(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String,
                            outputTokens: Int?, attempt: Int) async throws -> SummaryTextResponse {
        guard model.role == .summary else { throw SummaryGenerationError.invalidRequest }
        do {
            // Each attempt is reproducible; a retry after an invalid format samples anew.
            var sampling = TextSampling.summary(repository: model.repository); sampling.seed += UInt64(max(0, attempt))
            let result = try await generate(model, settings: settings, system: system, prompt: prompt,
                                            maxTokens: outputTokens, sampling: sampling)
            return SummaryTextResponse(text: result.text, contextPlan: result.contextPlan, generatedTokens: result.generatedTokens)
        } catch TextAdapterError.incompleteOutput { throw SummaryGenerationError.outputLimit }
        catch TextAdapterError.inputBudget { throw SummaryGenerationError.budget }
        catch is TextContextPlanningError { throw SummaryGenerationError.budget }
    }
}
