import Foundation
import Testing
import TalkTrackDomain
@testable import TalkTrackServices

@Suite struct TextContextPlannerTests {
    @Test func autoSelectsSmallestExactFitAndNextSize() throws {
        #expect(ContextLimit.manualOptions.map(\.rawValue) == [4096, 8192, 16384, 32768, 65536])
        #expect(ContextLimit.maximumSelectable == .standard)
        for (index, limit) in ContextLimit.manualOptions.enumerated() {
            let exact = try TextContextPlanner.resolve(selection: .automatic, role: .summary,
                inputTokens: limit.rawValue - 128, outputTokens: 128)
            #expect(exact.contextTokens == limit.rawValue)
            #expect(try TextContextPlanner.resolve(selection: limit, role: .summary,
                inputTokens: limit.rawValue - 128, outputTokens: 128).contextTokens == limit.rawValue)
            #expect(throws: TextContextPlanningError.self) {
                try TextContextPlanner.resolve(selection: limit, role: .summary,
                    inputTokens: limit.rawValue - 127, outputTokens: 128)
            }
            if index < ContextLimit.manualOptions.count - 1 {
                let next = try TextContextPlanner.resolve(selection: .automatic, role: .summary,
                    inputTokens: limit.rawValue - 127, outputTokens: 128)
                #expect(next.contextTokens == ContextLimit.manualOptions[index + 1].rawValue)
            } else {
                #expect(throws: TextContextPlanningError.self) {
                    try TextContextPlanner.resolve(selection: .automatic, role: .summary,
                        inputTokens: limit.rawValue - 127, outputTokens: 128)
                }
            }
        }
    }

    @Test func taskTypeChangesReserveAndManualLimitsNeverExpand() throws {
        let summary = try TextContextPlanner.resolve(selection: .automatic, role: .summary, inputTokens: 1800)
        let translation = try TextContextPlanner.resolve(selection: .automatic, role: .translation, inputTokens: 1800)
        let correction = try TextContextPlanner.resolve(selection: .automatic, role: .spelling, inputTokens: 1800)
        #expect(summary.contextTokens == 4096 && summary.outputTokens == 1800)
        #expect(translation.contextTokens == 16384 && translation.outputTokens == 7200)
        #expect(correction.contextTokens == 8192 && correction.outputTokens == 4500)
        #expect(throws: TextContextPlanningError.self) {
            try TextContextPlanner.resolve(selection: .tokens4K, role: .translation, inputTokens: 1800)
        }
        #expect(throws: TextContextPlanningError.self) {
            try TextContextPlanner.resolve(selection: .automatic, role: .translation, inputTokens: 5000)
        }
        #expect(try TextContextPlanner.resolve(selection: .tokens4K, role: .summary, inputTokens: 2048).outputTokens == 2048)
        #expect(throws: TextContextPlanningError.self) {
            try TextContextPlanner.resolve(selection: .tokens4K, role: .summary, inputTokens: 3000)
        }
    }

    @Test func overflowAndInvalidReservesAreRejected() {
        for input in [0, Int.max] {
            #expect(throws: TextContextPlanningError.self) {
                try TextContextPlanner.resolve(selection: .automatic, role: .summary, inputTokens: input)
            }
        }
        for reserve in [0, 32769] {
            #expect(throws: TextContextPlanningError.self) {
                try TextContextPlanner.resolve(selection: .automatic, role: .summary, inputTokens: 10, outputTokens: reserve)
            }
        }
    }

    @Test func preferencesPersistWhileLegacyAndRunningJobsKeepTheirBudget() throws {
        let suite = "TalkTrack.ContextTest.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ProcessingPreferences.context(in: defaults) == .small)
        #expect(ProcessingPreferences.snapshot(from: defaults).contextLimit == .small)
        #expect(ProcessingSettings().contextLimit == .small)
        for selection in ContextLimit.allCases {
            defaults.set(selection.rawValue, forKey: ProcessingPreferences.contextKey)
            let reopened = try #require(UserDefaults(suiteName: suite))
            #expect(ProcessingPreferences.context(in: reopened) == selection)
        }
        defaults.set(0, forKey: ProcessingPreferences.contextKey)
        let running = ProcessingPreferences.snapshot(from: defaults)
        defaults.set(4096, forKey: ProcessingPreferences.contextKey)
        #expect(running.contextLimit == .automatic)
        #expect(ProcessingPreferences.snapshot(from: defaults).contextLimit == .tokens4K)
        for raw in [129024, 131072] {
            let legacy = try JSONDecoder().decode(ContextLimit.self, from: Data(String(raw).utf8))
            #expect(!ContextLimit.allCases.contains(legacy))
            #expect(try TextContextPlanner.resolve(selection: legacy, role: .summary, inputTokens: 100).contextTokens == raw)
            #expect(String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self) == String(raw))
            let oldSnapshot = ProcessingSettings(contextLimit: legacy)
            #expect(try DomainCodec.decode(ProcessingSettings.self, from: DomainCodec.encode(oldSnapshot)) == oldSnapshot)
            defaults.set(raw, forKey: ProcessingPreferences.contextKey)
            #expect(ProcessingPreferences.context(in: defaults) == .standard)
            #expect(defaults.integer(forKey: ProcessingPreferences.contextKey) == 65536)
            #expect(ProcessingPreferences.snapshot(from: defaults).contextLimit == .standard)
            #expect(oldSnapshot.contextLimit.rawValue == raw)
        }
    }
}
