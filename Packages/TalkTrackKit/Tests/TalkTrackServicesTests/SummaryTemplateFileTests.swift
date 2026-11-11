import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

@Suite struct SummaryTemplateFileTests {
    static let retro = """
        ---
        name: Sprint Retro
        purpose: What went well, what did not, and what to change
        rules:
          - Group feedback by team when the team is named.
        per_person: Updates by Person
        ---

        ## What Went Well
        Successes and things the team wants to keep doing, one bullet each.

        ## What Did Not Go Well
        Problems, delays and frustrations raised, with who raised them when known.

        ## Updates by Person
        One bullet group per speaker label with what they finished this sprint.

        ## Decisions

        ## Action Items
        """

    private func check(_ text: String, names: [String] = [], language: OutputLanguage = .english) -> SummaryTemplateCheck {
        SummaryTemplateValidator.validate(text, existingNames: names, language: language)
    }

    private func errors(_ text: String) -> [SummaryTemplateDiagnostic] { check(text).errors }

    // MARK: 1.1 Parsing

    @Test func validFileBuildsCustomTemplateOverTheCurrentCore() throws {
        let result = check(Self.retro)
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics.map(\.text))")
        let file = try #require(result.file)
        #expect(file.name == "Sprint Retro" && file.purpose.hasPrefix("What went well"))
        #expect(file.sections.map(\.heading) == ["What Went Well", "What Did Not Go Well", "Updates by Person", "Decisions", "Action Items"])
        #expect(file.sections.map(\.line) == [9, 12, 15, 18, 20])
        let template = file.template()
        #expect(template.type == .custom && template.version == SummaryTemplates.currentVersion)
        #expect(template.icon == "person.crop.circle" && template.title == "Sprint Retro")
        // Headings are used as written in both output languages.
        #expect(template.sections.allSatisfy { $0.english == $0.russian })
        // Bare shared headings take the built-in guidance of the current version.
        let auto = try #require(SummaryTemplates.template(.auto))
        #expect(template.sections[3].guidance == auto.sections.first { $0.english == "Decisions" }?.guidance)
        #expect(template.sections[4].guidance == auto.sections.first { $0.english == "Action Items" }?.guidance)
        #expect(template.perPersonSection?.english == "Updates by Person")
        #expect(template.rules == ["Group feedback by team when the team is named.", SummaryTemplateFile.perPersonRule("Updates by Person")])
        // The prompt keeps the fixed core and uses the custom sections.
        let system = SummaryPrompt.system(template, language: .russian)
        #expect(system.contains("## What Went Well\nSuccesses and things"))
        // From version 5 the fixed words are named in English; TalkTrack localizes the response.
        #expect(system.contains("\"Owner:\"") && system.contains("\"None noted.\"") && system.contains("Write the whole summary in Russian"))
        #expect(!system.contains("Ответственный") && !system.contains("Не отмечено"))
        #expect(system.contains("For this type of meeting:\n- Group feedback by team"))
    }

    @Test func russianSharedHeadingsAndQuotedValues() throws {
        let file = try #require(check("""
            ---
            name: "Планёрка"
            rules: []
            ---
            ## Кратко
            Два-три предложения о том, чем закончилась встреча.
            ## Решения
            ## открытые вопросы
            """, language: .russian).file)
        #expect(file.name == "Планёрка" && file.rules.isEmpty)
        let template = file.template()
        #expect(template.sections[1].guidance == SummaryTemplates.sharedGuidance(heading: "Decisions"))
        #expect(template.sections[2].english == "открытые вопросы")
        #expect(template.sections[2].guidance == SummaryTemplates.sharedGuidance(heading: "Open Questions"))
        #expect(template.perPersonSection == nil)
    }

    @Test func surroundingCodeFenceIsIgnoredAndLinesStayTheUsers() throws {
        let fenced = "Here is your template:\n\n```markdown\n" + Self.retro + "\n```\n"
        // Commentary before the fence is text before the header.
        #expect(errors(fenced).first?.line == 1)
        let result = check("```markdown\n" + Self.retro + "\n```\n")
        #expect(result.errors.isEmpty)
        #expect(result.file?.sections.first?.line == 10)
        #expect(check("~~~\n" + Self.retro + "\n~~~").errors.isEmpty)
    }

    @Test func multiLineExplanationsAndWindowsLineEndings() throws {
        let text = "---\r\nname: Client Call\r\n---\r\n## Requests\r\nWhat the client asked for.\r\nKeep their wording.\r\n\r\n## Action Items\r\n"
        let file = try #require(check(text).file)
        #expect(file.sections[0].explanation == "What the client asked for.\nKeep their wording.")
    }

    typealias Case = (text: String, line: Int?, message: String)
    static let body = "## A\nSome text here please."

    static let parseCases: [Case] = [
        ("", nil, "empty"),
        ("name: X\n---\n## A\nSome text here please.", 1, "must start with the header"),
        ("Sure! Here it is:\n---\nname: X\n---\n## A\nSome text here please.", 1, "must start with the header"),
        ("---\nname: X\n## A\nSome text here please.", 1, "not closed"),
        ("---\npurpose: Y\n---\n## A\nSome text here please.", 1, "no \"name\""),
        ("---\nname:\n---\n## A\nSome text here please.", 2, "\"name\" is empty"),
        ("---\nnmae: X\n---\n## A\nSome text here please.", 2, "Did you mean \"name\""),
        ("---\nname: X\nper_persn: A\n---\n## A\nSome text here please.", 3, "Did you mean \"per_person\""),
        ("---\nname: X\nicon: sparkles\n---\n## A\nSome text here please.", 3, "Unknown header field \"icon\""),
        ("---\nname: X\nname: Y\n---\n## A\nSome text here please.", 3, "more than once"),
        ("---\nname: X\nthis is not a field\n---\n## A\nSome text here please.", 3, "key: value"),
        ("---\nname: X\n  - stray\n---\n## A\nSome text here please.", 3, "must follow \"rules:\""),
        ("---\nname: X\nrules: be nice\n---\n## A\nSome text here please.", 3, "its own line"),
        ("---\nname: X\n---\n", nil, "no sections"),
        ("---\nname: X\n---\nIntro text\n## A\nSome text here please.", 4, "Text before the first section"),
        ("---\nname: X\n---\n# A\nSome text here please.", 4, "two #"),
        ("---\nname: X\n---\n## A\nSome text\n### Sub\nmore", 6, "starts with \"#\""),
    ]

    @Test(arguments: parseCases)
    func parseErrors(text: String, line: Int?, message: String) {
        let found = errors(text)
        #expect(found.contains { $0.line == line && $0.message.contains(message) }, "\(found.map(\.text))")
        #expect(check(text).file == nil)
    }

    // MARK: 1.2 Validation

    static let longHeading: String = "---\nname: X\n---\n## " + String(repeating: "H", count: 61) + "\nSome text here please."
    static let longName: String = "---\nname: " + String(repeating: "N", count: 61) + "\n---\n" + body
    static let longExplanation: String = "---\nname: X\n---\n## A\n" + String(repeating: "word ", count: 130)
    static let longRule: String = "---\nname: X\nrules:\n  - " + String(repeating: "r", count: 401) + "\n---\n" + body

    static let validationCases: [Case] = [
        ("---\nname: X\n---\n## A\nFirst explanation is long enough.\n## a\nSecond explanation also long.", 6, "repeats line 4"),
        ("---\nname: X\n---\n## Summary\n## B\nSome text here please.", 4, "has no explanation"),
        ("---\nname: X\n---\n##\nSome text here please.", 4, "empty"),
        ("---\nname: X\n---\n## **Bold**\nSome text here please.", 4, "plain text"),
        ("---\nname: X\n---\n## 1. First\nSome text here please.", 4, "list mark or number"),
        ("---\nname: X\n---\n## - First\nSome text here please.", 4, "list mark or number"),
        (longHeading, 4, "longer than 60"),
        (longName, 2, "longer than 60"),
        ("---\nname: X\nper_person: People\n---\n## A\nSome text here please.", 3, "not one of the section headings"),
        (longExplanation, 4, "longer than 600"),
        (longRule, 4, "longer than 400"),
    ]

    @Test(arguments: validationCases)
    func validationErrors(text: String, line: Int?, message: String) {
        let found = errors(text)
        #expect(found.contains { $0.line == line && $0.message.contains(message) }, "\(found.map(\.text))")
        #expect(check(text).file == nil)
    }

    @Test func tooManySectionsIsAnErrorAndMoreThanEightAWarning() {
        func sections(_ count: Int) -> String {
            "---\nname: X\n---\n" + (1...count).map { "## Section \($0)\nWhat goes in part \($0) of the meeting, \(String(repeating: "x", count: $0))." }.joined(separator: "\n")
        }
        #expect(errors(sections(13)).contains { $0.message.contains("More than 12 sections") && $0.line == 28 })
        let nine = check(sections(9))
        #expect(nine.canImport)
        #expect(nine.warnings.contains { $0.message.contains("More than 8 sections") && $0.line == 20 })
        #expect(check(sections(8)).warnings.isEmpty)
    }

    @Test func templateTooLargeSaysByHowMuch() {
        let explanation = String(repeating: "Describe the discussion in detail. ", count: 16)
        let text = "---\nname: Huge\n---\n" + (1...8).map { "## Part \($0)\n\(explanation)" }.joined(separator: "\n")
        let error = errors(text).first { $0.message.contains("too large") }
        #expect(error?.line == nil)
        #expect(error?.message.contains("over the limit of \(SummaryTemplateValidator.tokenBudget)") == true)
    }

    @Test func warningsNeverBlock() throws {
        let text = """
            ---
            name: Noisy
            rules:
              - Do not invent anything and write the summary in English.
              - Cite the times of every point.
            ---
            ## Overview
            Short.
            ## Metrics
            Put the numbers in a table with numbered rows.
            ## Time
            Calculate how long each topic took.
            ## People
            Guess the real names of Voice1 and Voice2 from context.
            ## Обсуждение
            Что обсуждали на встрече, коротко по каждой теме.
            ## Discussion
            Что обсуждали на встрече, коротко по каждой теме!
            """
        let result = check(text)
        #expect(result.errors.isEmpty, "\(result.errors.map(\.text))")
        #expect(result.canImport && result.file != nil)
        let warnings = result.warnings.map(\.text)
        #expect(warnings.contains { $0.hasPrefix("Line 7:") && $0.contains("very short") })
        #expect(warnings.contains { $0.hasPrefix("Line 9:") && $0.contains("tables, JSON") })
        #expect(warnings.contains { $0.hasPrefix("Line 11:") && $0.contains("compute times") })
        #expect(warnings.contains { $0.hasPrefix("Line 13:") && $0.contains("identify speakers") })
        #expect(warnings.contains { $0.hasPrefix("Line 4:") && $0.contains("repeats what TalkTrack always") })
        #expect(warnings.contains { $0.hasPrefix("Line 5:") && $0.contains("repeats what TalkTrack always") })
        #expect(warnings.contains { $0.contains("not in English") })
        #expect(warnings.contains { $0.hasPrefix("Line 17:") && $0.contains("nearly the same") })
        // In Russian the Latin headings are the mismatch.
        #expect(check(text, language: .russian).warnings.contains { $0.text.contains("not in Russian") })
    }

    /// The 4K room of a template at the budget was measured with the real
    /// tokenizers (`template-budget`, docs/summaries.md); here the boundary.
    @Test func budgetBoundaryIsExact() throws {
        func text(_ padding: Int) -> String {
            "---\nname: Edge\n---\n" + (1...10).map { "## Area \($0)\nWhat participants said about this part of the work, with names and numbers as stated. " + String(repeating: "More detail. ", count: 8) }.joined(separator: "\n")
                + "\n## Notes\n" + String(repeating: "a", count: padding)
        }
        var padding = 0
        while SummaryTemplateValidator.estimatedTokens(try #require(SummaryTemplateFile.parse(text(padding)).file).template())
                < SummaryTemplateValidator.tokenBudget { padding += 1 }
        let at = check(text(padding))
        #expect(SummaryTemplateValidator.estimatedTokens(try #require(at.file).template()) == SummaryTemplateValidator.tokenBudget)
        #expect(at.errors.isEmpty)
        let over = check(text(padding + 3))
        #expect(over.file == nil && over.errors.contains { $0.message.contains("too large") })
    }

    @Test func russianFixtureFitsTheBudget() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Fixtures/SummaryTemplates/russian-retro.md").standardizedFileURL
        let result = check(try String(contentsOf: url, encoding: .utf8), language: .russian)
        #expect(result.errors.isEmpty && result.warnings.isEmpty, "\(result.diagnostics.map(\.text))")
        #expect(result.file?.template().perPersonSection?.english == "Обновления по участникам")
    }

    @Test func sameNameIsReplacementNotError() {
        let result = check(Self.retro, names: ["Weekly", "sprint retro"])
        #expect(result.canImport && result.errors.isEmpty)
        #expect(result.replaces == "sprint retro")
        #expect(check(Self.retro, names: ["Weekly"]).replaces == nil)
    }

    // MARK: 1.5 Bundled guide and example

    @Test func bundledExampleImportsCleanlyAndGuideIsEnglish() throws {
        let example = try #require(SummaryTemplateGuide.exampleText)
        let result = check(example, language: .english)
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics.map(\.text))")
        let file = try #require(result.file)
        #expect(file.name == "General Meeting")
        #expect(file.sections.map(\.heading) == ["Summary", "Key Topics", "Decisions", "Action Items", "Open Questions"])
        let guide = try #require(SummaryTemplateGuide.guideText)
        #expect(guide.hasPrefix("# How to write a TalkTrack summary template"))
        #expect(guide.contains("## For AI assistants") && guide.contains("Example Template.md"))
        #expect(!guide.contains(/\p{Script=Cyrillic}/))
        #expect(!example.contains(/\p{Script=Cyrillic}/))
        // The guide's own sample file imports too.
        let sample = try #require(guide.firstMatch(of: /```markdown\n(---\n[\s\S]*?)```/)?.output.1)
        #expect(check(String(sample)).errors.isEmpty)
    }

    // MARK: 1.4 Export

    @Test func everyBuiltInTypeExportsAndReimportsWithTheSamePrompt() throws {
        for language in OutputLanguage.allCases {
            for builtIn in SummaryTemplates.current {
                let text = SummaryTemplateFile.render(builtIn, language: language)
                let result = check(text, language: language)
                #expect(result.errors.isEmpty, "\(builtIn.type) \(language): \(result.errors.map(\.text))")
                let custom = try #require(result.file).template()
                #expect(custom.title == builtIn.title && custom.purpose == builtIn.purpose)
                #expect(custom.perPersonSection?.title(language) == builtIn.perPersonSection?.title(language))
                for fromParts in [false, true] {
                    // A built-in prompt names English headings; the exported file
                    // carries the summary language's headings, used verbatim.
                    var expected = SummaryPrompt.system(builtIn, language: language, fromParts: fromParts)
                    for section in builtIn.sections where language != .english {
                        expected = expected.replacingOccurrences(of: "## \(section.english)\n", with: "## \(section.title(language))\n")
                    }
                    #expect(SummaryPrompt.system(custom, language: language, fromParts: fromParts) == expected, "\(builtIn.type) \(language)")
                }
            }
        }
    }

    @Test func customTemplateExportsBackToAnEquivalentFile() throws {
        let template = try #require(check(Self.retro).file).template()
        let exported = SummaryTemplateFile.render(template, language: .english)
        #expect(exported.contains("per_person: Updates by Person"))
        #expect(!exported.contains("said nothing about their work"))
        let again = try #require(check(exported).file).template()
        #expect(SummaryPrompt.system(again, language: .english) == SummaryPrompt.system(template, language: .english))
    }

    @Test func reportsHeaderAndSectionErrorsTogether() {
        let check = SummaryTemplateValidator.validate("---\nname: Broken\nperpson: Updates\n---\n\n## Summary\n\n## Summary\nTwo sentences.\n")
        #expect(!check.canImport)
        #expect(check.errors.compactMap(\.line) == check.errors.compactMap(\.line).sorted())
        #expect(check.errors.contains { $0.line == 3 && $0.message.contains("perpson") })
        #expect(check.errors.contains { $0.line == 8 })
    }

}
