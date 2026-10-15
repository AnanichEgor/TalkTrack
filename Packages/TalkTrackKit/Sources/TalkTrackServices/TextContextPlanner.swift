import Foundation
import TalkTrackDomain

public struct TextContextPlan: Codable, Equatable, Sendable {
    public let selection: ContextLimit
    public let role: ModelRole
    public let inputTokens: Int
    public let outputTokens: Int
    public let contextTokens: Int
}

public enum TextContextPlanningError: Error, LocalizedError, Equatable {
    case invalidRequest
    case outputNeedsPartition(estimated: Int, maximum: Int)
    case requiresPartition(input: Int, output: Int, limit: Int)
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "The text request has an invalid context or output budget."
        case .outputNeedsPartition(let estimated, let maximum):
            "The estimated response needs \(estimated) tokens, exceeding the \(maximum)-token generation limit. Process the source in complete parts."
        case .requiresPartition(let input, let output, let limit):
            "The full request needs \(input) input tokens plus \(output) output tokens, exceeding the \(limit)-token context. Split the source into complete parts; no content has been removed."
        }
    }
}

public enum TextContextPlanner {
    /// Input must already include the tokenizer's actual chat template, system
    /// prompt, source data and special tokens. This planner never clips content.
    public static func resolve(selection: ContextLimit, role: ModelRole, inputTokens: Int,
                               outputTokens: Int? = nil) throws -> TextContextPlan {
        guard inputTokens > 0, [.summary, .translation, .spelling].contains(role),
              // An explicit reserve may exceed estimated output caps (up to 32K) for
              // thinking runs, whose reasoning counts against it.
              outputTokens == nil || (1...32768).contains(outputTokens!) else {
            throw TextContextPlanningError.invalidRequest
        }
        let reserve: Int
        if let outputTokens { reserve = outputTokens }
        else if role == .summary {
            let suggested = min(8192, max(1024, inputTokens))
            reserve = selection == .automatic ? suggested : min(suggested, selection.rawValue / 2)
        } else {
            // Conservative initial planning, not a claim about a fixed language
            // token ratio. Capped/incomplete generations still fail validation.
            let multiplier = role == .translation ? 4 : 10
            let divisor = role == .translation ? 1 : 4
            let (scaled, overflow) = inputTokens.multipliedReportingOverflow(by: multiplier)
            guard !overflow else { throw TextContextPlanningError.invalidRequest }
            let estimated = max(role == .translation ? 1024 : 512, scaled / divisor)
            guard estimated <= 16384 else { throw TextContextPlanningError.outputNeedsPartition(estimated: estimated, maximum: 16384) }
            reserve = estimated
        }
        let (required, overflow) = inputTokens.addingReportingOverflow(reserve)
        let ceiling = selection == .automatic ? ContextLimit.maximumSelectable.rawValue : selection.rawValue
        guard !overflow, required <= ceiling else {
            throw TextContextPlanningError.requiresPartition(input: inputTokens, output: reserve, limit: ceiling)
        }
        let resolved = selection == .automatic
            ? ContextLimit.manualOptions.first(where: { $0.rawValue >= required })! : selection
        return TextContextPlan(selection: selection, role: role, inputTokens: inputTokens,
            outputTokens: reserve, contextTokens: resolved.rawValue)
    }
}
