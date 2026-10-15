import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

/// One token per word; chat formatting adds a fixed eight. Responses list the
/// cited lines of their input, so coverage can be traced to the final text.
actor WordTokenInference: SummaryTextInference {
    enum Behavior { case normal, capAbove(lines: Int), repeatAbove(lines: Int), capFinalAbove(parts: Int) }
    var behavior: Behavior
    /// Words of a topic line each part adds; merges keep only the first topic.
    var padding = 0
    private(set) var calls: [(system: String, prompt: String, plan: TextContextPlan)] = []
    init(_ behavior: Behavior = .normal, padding: Int = 0) { self.behavior = behavior; self.padding = padding }

    nonisolated static func words(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    func tokenCounts(_ model: ModelSnapshot, settings: ProcessingSettings, texts: [String]) async throws -> [Int] {
        texts.map(Self.words)
    }
    func formattedTokenCount(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String) async throws -> Int {
        Self.words(system) + Self.words(prompt) + 8
    }
    func summaryText(_ model: ModelSnapshot, settings: ProcessingSettings, system: String, prompt: String,
                     outputTokens: Int?, attempt: Int) async throws -> SummaryTextResponse {
        let input = Self.words(system) + Self.words(prompt) + 8
        let plan: TextContextPlan
        do { plan = try TextContextPlanner.resolve(selection: settings.contextLimit, role: .summary, inputTokens: input, outputTokens: outputTokens) }
        catch { throw SummaryGenerationError.budget }
        calls.append((system, prompt, plan))
        let part = system.hasPrefix("You take notes")
        let lines = prompt.split(separator: "\n").filter { $0.hasPrefix("[") || $0.hasPrefix("- ") }
        if part {
            switch behavior {
            case .capAbove(let limit) where lines.count > limit: throw SummaryGenerationError.outputLimit
            case .repeatAbove(let limit) where lines.count > limit:
                return SummaryTextResponse(text: Array(repeating: "- the same point again", count: 3).joined(separator: "\n"),
                                           contextPlan: plan, generatedTokens: 15)
            default: break
            }
        }
        if case .capFinalAbove(let limit) = behavior, system.hasPrefix("You write a meeting summary"),
           prompt.components(separatedBy: "<part_notes").count - 1 > limit {
            throw SummaryGenerationError.outputLimit
        }
        // Cited lines collapse into one word, "[t1],[t2],…", so responses stay
        // short while every time can be traced to the final summary.
        var cited: [String] = [], other: [String] = []
        for line in lines {
            if line.hasPrefix("- covered ") { cited.append(String(line.dropFirst(10))) }
            else if line.hasPrefix("- topic ") { if !other.contains(where: { $0.hasPrefix("- topic ") }) { other.append(String(line)) } }
            else if line.hasPrefix("- ") { if !other.contains(String(line)) { other.append(String(line)) } }
            else if let end = line.firstIndex(of: "]") { cited.append(String(line[...end])) }
        }
        if prompt.contains("<notes>") { other.append("- notes part \(calls.count) (notes)") }
        if part, padding > 0 { other.append("- topic \(calls.count) " + Array(repeating: "filler", count: padding).joined(separator: " ")) }
        var output = [system.hasPrefix("You write a meeting summary") ? "## Summary" : "## Topics"] + other
        if !cited.isEmpty { output.append("- covered " + cited.joined(separator: ",")) }
        let text = output.joined(separator: "\n")
        guard Self.words(text) < plan.outputTokens else { throw SummaryGenerationError.outputLimit }
        return SummaryTextResponse(text: text, contextPlan: plan, generatedTokens: Self.words(text))
    }
}

struct ChunkingMeeting {
    let meeting: Meeting
    let items: [TranscriptDisplayItem]
    /// Blocks alternate between two voices 10 s apart; days add a separator.
    init(blocks: [String], days: Int = 1) throws {
        meeting = Meeting(draft: try MeetingDraft(title: "Long planning call", description: "Quarterly plan"))
        var recordings: [Recording] = [], segments: [TranscriptSegment] = [], speakers: [DaySpeaker] = []
        let perDay = (blocks.count + days - 1) / days
        for day in 0..<days {
            let start = Date(timeIntervalSince1970: 1_790_000_000 + Double(day) * (86_400 * 3 + 3600))
            let recording = try Recording(meetingID: meeting.id, startedAt: start, timeZoneIdentifier: "UTC")
            let dayID = recording.days[0].id
            let voices = [DaySpeaker(meetingID: meeting.id, dayID: dayID, number: 1),
                          DaySpeaker(meetingID: meeting.id, dayID: dayID, number: 2)]
            recordings.append(recording); speakers += voices
            for (index, text) in blocks.dropFirst(day * perDay).prefix(perDay).enumerated() {
                let offset = Double(index * 10)
                segments.append(TranscriptSegment(recordingID: recording.id, dayID: dayID, track: .system,
                    interval: try MediaInterval(start: MediaTime(seconds: offset), end: MediaTime(seconds: offset + 4)),
                    wallClockStart: start.addingTimeInterval(offset),
                    speaker: .system(daySpeakerID: voices[index % 2].id), originalText: text))
            }
        }
        items = try TranscriptFormatter.format(meetingID: meeting.id, recordings: recordings, segments: segments, speakers: speakers)
    }
    var timestamps: [String] { items.compactMap { if case .speech(let b) = $0 { b.timestamp } else { nil } } }
}

@Suite struct SummaryChunkingTests {
    static let model = ModelSnapshot(role: .summary, repository: "test/text", revision: "1",
                                     directory: try! RelativePath("test/text"), preprocessingVersion: "1")
    /// Chunking mechanics are exercised through version 1 (whole meeting with
    /// notes), which saved jobs still use; version 2 differs only in its source.
    static func settings(_ limit: ContextLimit, type: SummaryType = .auto) -> ProcessingSettings {
        ProcessingSettings(summaryLanguage: .english, contextLimit: limit, summaryType: type, templateVersion: "1")
    }
    static func notes(_ words: Int) -> String { Array(repeating: "w", count: words).joined(separator: " ") }

    /// Every request fits its context; every part covers consecutive units once;
    /// every cited line reaches the final summary.
    func checkCoverage(_ draft: SummaryDraft, _ fake: WordTokenInference, _ meeting: ChunkingMeeting,
                       notesWords: Int, ceiling: Int) async {
        let calls = await fake.calls
        for call in calls {
            #expect(call.plan.inputTokens + call.plan.outputTokens <= call.plan.contextTokens)
            #expect(call.plan.contextTokens <= ceiling)
        }
        let parts = draft.requests.filter { $0.stage == .part }.map(\.sources)
        #expect(MeetingSummarizer.covers(parts, count: draft.units.count))
        // Each round's merges and pass-throughs consume the previous level once.
        #expect(draft.requests.last?.stage == .final)
        let partPrompts = calls.filter { $0.system.hasPrefix("You take notes") }.map(\.prompt)
        let notesInParts = partPrompts.map { prompt -> Int in
            guard let start = prompt.range(of: "<notes>\n"), let end = prompt.range(of: "\n</notes>") else { return 0 }
            return WordTokenInference.words(String(prompt[start.upperBound..<end.lowerBound]))
        }.reduce(0, +)
        #expect(notesInParts == notesWords)
        // Every block reaches the final text once, in order (pieces of one block share its time).
        let covered = draft.text.split(separator: "\n").first { $0.hasPrefix("- covered ") }
            .map { $0.dropFirst(10).split(separator: ",").map { String($0.dropFirst().dropLast()) } } ?? []
        #expect(covered.enumerated().filter { $0.offset == 0 || covered[$0.offset - 1] != $0.element }.map(\.element) == meeting.timestamps)
        #expect(SummaryCheck.unknownCitations(draft.text, transcript: meeting.items).isEmpty)
    }

    @Test func directRequestUpToEachBoundaryAndCompletePartsOneTokenBeyond() async throws {
        let meeting = try ChunkingMeeting(blocks: (0..<6).map { "Point \($0) about the plan." })
        let template = try #require(SummaryTemplates.template(.auto, version: "1"))
        for limit in [ContextLimit.automatic] + ContextLimit.manualOptions {
            let settings = Self.settings(limit)
            let ceiling = limit == .automatic ? ContextLimit.maximumSelectable.rawValue : limit.rawValue
            func fits(_ words: Int) -> Bool {
                let input = WordTokenInference.words(SummaryPrompt.system(template, language: .english))
                    + WordTokenInference.words(SummaryPrompt.user(meeting: meeting.meeting, notes: Self.notes(words), transcript: meeting.items)) + 8
                return (try? TextContextPlanner.resolve(selection: limit, role: .summary, inputTokens: input)) != nil
            }
            var (low, high) = (0, ceiling)
            while low < high { let mid = (low + high + 1) / 2; if fits(mid) { low = mid } else { high = mid - 1 } }
            let largest = low
            #expect(fits(largest) && !fits(largest + 1))

            let direct = WordTokenInference()
            let one = try await MeetingSummarizer(model: Self.model, settings: settings, inference: direct)
                .summarize(meeting: meeting.meeting, notes: Self.notes(largest), transcript: meeting.items)
            #expect(one.requests.map(\.stage) == [.direct], "\(limit)")
            let plan = one.requests[0].contextPlan
            #expect(plan.contextTokens == ceiling && plan.inputTokens + plan.outputTokens <= ceiling, "\(limit)")
            #expect(plan.contextTokens - plan.inputTokens - plan.outputTokens < 4, "\(limit) is not at its boundary")

            let chunked = WordTokenInference()
            let many = try await MeetingSummarizer(model: Self.model, settings: settings, inference: chunked)
                .summarize(meeting: meeting.meeting, notes: Self.notes(largest + 1), transcript: meeting.items)
            #expect(many.requests.first?.stage == .part, "\(limit)")
            await checkCoverage(many, chunked, meeting, notesWords: largest + 1, ceiling: ceiling)
        }
    }

    @Test func oversizedBlockIsSplitKeepingItsTimeAndSpeaker() async throws {
        let long = (0..<9000).map { "word\($0)" }.joined(separator: " ")
        let meeting = try ChunkingMeeting(blocks: ["Opening remark.", long, "Closing remark."])
        let fake = WordTokenInference()
        let draft = try await MeetingSummarizer(model: Self.model, settings: Self.settings(.tokens4K), inference: fake)
            .summarize(meeting: meeting.meeting, notes: nil, transcript: meeting.items)
        let pieces = draft.units.filter { $0.pieces > 1 }
        #expect(pieces.count >= 3 && pieces.map(\.piece) == Array(0..<pieces.count))
        let header = "[\(meeting.timestamps[1])]: Voice2 - "
        #expect(pieces.allSatisfy { $0.text.hasPrefix(header) && $0.date != nil })
        #expect(pieces.map { String($0.text.dropFirst(header.count)) }.joined(separator: " ") == long)
        await checkCoverage(draft, fake, meeting, notesWords: 0, ceiling: 4096)
    }

    @Test func partNotesMergeInRoundsUntilTheFinalSummaryFits() async throws {
        let meeting = try ChunkingMeeting(blocks: (0..<900).map { "Item \($0): " + Array(repeating: "detail", count: 25).joined(separator: " ") },
                                          days: 3)
        let fake = WordTokenInference(padding: 300)
        let draft = try await MeetingSummarizer(model: Self.model, settings: Self.settings(.tokens4K), inference: fake)
            .summarize(meeting: meeting.meeting, notes: "Ask legal about the text\nBudget is 18,000 EUR", transcript: meeting.items)
        #expect(draft.requests.contains { $0.stage == .merge })
        #expect(Set(draft.requests.map(\.level)).count >= 2)
        // Each part repeats the date line its first block needs.
        let parts = await fake.calls.filter { $0.system.hasPrefix("You take notes") }
        #expect(parts.allSatisfy { !$0.prompt.contains("<transcript>") || $0.prompt.contains("<transcript>\n------------ [") })
        await checkCoverage(draft, fake, meeting, notesWords: 9, ceiling: 4096)
        #expect(draft.text.contains("(notes)"))
    }

    @Test func cappedOrRepeatingPartsAreRetriedSmallerOrFail() async throws {
        let meeting = try ChunkingMeeting(blocks: (0..<400).map { "Item \($0): " + Array(repeating: "detail", count: 25).joined(separator: " ") })
        for behavior in [WordTokenInference.Behavior.capAbove(lines: 20), .repeatAbove(lines: 20)] {
            let fake = WordTokenInference(behavior)
            let draft = try await MeetingSummarizer(model: Self.model, settings: Self.settings(.tokens8K), inference: fake)
                .summarize(meeting: meeting.meeting, notes: nil, transcript: meeting.items)
            await checkCoverage(draft, fake, meeting, notesWords: 0, ceiling: 8192)
            #expect(draft.requests.filter { $0.stage == .part }.allSatisfy { $0.sources.count <= 20 })
        }
        // A single unit that still fails is reported, not dropped.
        for (behavior, error) in [(WordTokenInference.Behavior.capAbove(lines: 0), SummaryGenerationError.outputLimit),
                                  (.repeatAbove(lines: 0), .repetition)] {
            await #expect(throws: error) {
                try await MeetingSummarizer(model: Self.model, settings: Self.settings(.tokens8K), inference: WordTokenInference(behavior))
                    .summarize(meeting: meeting.meeting, notes: nil, transcript: meeting.items)
            }
        }
    }

    @Test func aCappedFinalSummaryIsRetriedAfterAMergeRound() async throws {
        let meeting = try ChunkingMeeting(blocks: (0..<300).map { "Item \($0): " + Array(repeating: "detail", count: 25).joined(separator: " ") })
        let fake = WordTokenInference(.capFinalAbove(parts: 1))
        let draft = try await MeetingSummarizer(model: Self.model, settings: Self.settings(.tokens4K), inference: fake)
            .summarize(meeting: meeting.meeting, notes: nil, transcript: meeting.items)
        #expect(draft.requests.map(\.stage).suffix(2) == [.merge, .final])
        #expect(draft.requests.last?.sources == 0..<1)
        await checkCoverage(draft, fake, meeting, notesWords: 0, ceiling: 4096)
        // The final request gets twice the planner's reserve, or the rest of the context.
        let plan = try #require(draft.requests.last?.contextPlan)
        let planned = try TextContextPlanner.resolve(selection: .tokens4K, role: .summary, inputTokens: plan.inputTokens).outputTokens
        #expect(plan.outputTokens == min(2 * planned, 4096 - plan.inputTokens) && plan.outputTokens > planned)
        // With one set of notes left there is nothing more to condense.
        await #expect(throws: SummaryGenerationError.outputLimit) {
            try await MeetingSummarizer(model: Self.model, settings: Self.settings(.tokens4K), inference: WordTokenInference(.capFinalAbove(parts: 0)))
                .summarize(meeting: meeting.meeting, notes: nil, transcript: meeting.items)
        }
    }

    @Test func invalidRequestsAndRepetitionDetection() async throws {
        let meeting = try ChunkingMeeting(blocks: ["Hello."])
        await #expect(throws: SummaryGenerationError.emptySource) {
            try await MeetingSummarizer(model: Self.model, settings: Self.settings(.tokens4K), inference: WordTokenInference())
                .summarize(meeting: meeting.meeting, notes: " \n", transcript: [])
        }
        var old = Self.settings(.tokens4K); old.templateVersion = "0"
        await #expect(throws: SummaryGenerationError.invalidRequest) {
            try await MeetingSummarizer(model: Self.model, settings: old, inference: WordTokenInference())
                .summarize(meeting: meeting.meeting, notes: nil, transcript: meeting.items)
        }
        var title = meeting.meeting; title.title = Self.notes(4000)
        await #expect(throws: SummaryGenerationError.tooLarge) {
            try await MeetingSummarizer(model: Self.model, settings: Self.settings(.tokens4K), inference: WordTokenInference())
                .summarize(meeting: title, notes: Self.notes(5000), transcript: meeting.items)
        }
        #expect(SummaryCheck.isRepetitive("- a point that repeats\n- a point that repeats\n- a point that repeats"))
        #expect(SummaryCheck.isRepetitive("Summary: and then and then and then and then"))
        #expect(!SummaryCheck.isRepetitive("## Topics\n- None noted.\n## Decisions\n- None noted.\n## Open Questions\n- None noted."))
        // A standup lists the same short fields for every person (real Daily, 2026-10-13).
        let people = ["Dima", "Maxim", "Yura", "Tomas"].map { "- **\($0)**:\n  - Done: Greeted the team.\n  - Next: None noted.\n  - Blockers: None explicitly stated." }
        #expect(!SummaryCheck.isRepetitive("## Updates by Person\n" + people.joined(separator: "\n")))
        let sentence = "- Waiting for Scott's response regarding the user access and versionation issue in scope."
        #expect(SummaryCheck.isRepetitive([sentence, "- other", sentence, "- more", sentence].joined(separator: "\n")))
        #expect(!MeetingSummarizer.covers([0..<2, 3..<4], count: 4) && !MeetingSummarizer.covers([0..<2, 1..<4], count: 4))
        #expect(MeetingSummarizer.covers([0..<2, 2..<4], count: 4))
    }
}
