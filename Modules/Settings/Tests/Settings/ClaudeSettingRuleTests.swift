import Testing
import Foundation
import Sync
@testable import Settings

/// Pins which changes Claude may make itself: look-and-feel either way; its own reach only lower,
/// and never to a limit at or below what is already spent.
@MainActor
@Suite struct ClaudeSettingRuleTests {

    private func scratch(_ test: String = #function) -> (String, UserDefaults) {
        let name = "ClaudeSettingRuleTests.\(test).\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    private func refusal(_ id: String, _ from: SettingValue?, _ to: SettingValue, _ defaults: UserDefaults) throws -> String? {
        ClaudeSettingRule.refusal(try #require(SettingsCatalog.entry(id)), from: from, to: to, defaults: defaults)
    }

    @Test func lookAndFeelChangesEitherWay() throws {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        #expect(try refusal("appearance.theme", .string("system"), .string("dark"), defaults) == nil)
        #expect(try refusal("readability.textSize", .int(110), .int(100), defaults) == nil)
        #expect(try refusal("readability.textSize", .int(100), .int(110), defaults) == nil)
    }

    @Test func onlyTheirClickChangesASuggestedSetting() throws {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        #expect(try refusal("sync.confirmTransfer", .bool(true), .bool(false), defaults) != nil)
        #expect(try refusal("intelligence.askClaudeModel", .string(AskClaudeModels.opus.id),
                            .string(AskClaudeModels.haiku.id), defaults) != nil)
    }

    @Test func reachGoesOnlyDown() throws {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        #expect(try refusal("intelligence.cloudRefine", .bool(true), .bool(false), defaults) == nil)
        #expect(try refusal("intelligence.cloudRefine", .bool(false), .bool(true), defaults) != nil)
        #expect(try refusal("intelligence.monthlyLimit", .double(25), .double(10), defaults) == nil)
        #expect(try refusal("intelligence.monthlyLimit", .double(25), .double(50), defaults) != nil)
        // 0 is No limit, the highest there is: from it any limit lowers, and to it never does.
        #expect(try refusal("intelligence.monthlyLimit", .double(25), .double(0), defaults) != nil)
        #expect(try refusal("intelligence.monthlyCap", .double(0), .double(5), defaults) == nil)
        // A value it can't read now can't be judged a lowering.
        #expect(try refusal("intelligence.monthlyLimit", nil, .double(10), defaults) != nil)
    }

    @Test func aLimitNeverGoesToWhatsAlreadySpent() throws {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        AskClaudeSpend.record(10, in: defaults)
        FilingSpendStore.record(
            FilingSpendEntry(timestamp: Date(), model: "claude-haiku-4-5", fileCount: 5, placedCount: 4,
                             inputTokens: 1000, outputTokens: 0, cacheReadTokens: 0,
                             cacheCreationTokens: 0, estimatedCostUSD: 6),
            defaults: defaults)
        #expect(try refusal("intelligence.monthlyLimit", .double(25), .double(10), defaults)?.contains("already spent") == true)
        #expect(try refusal("intelligence.monthlyLimit", .double(25), .double(5), defaults) != nil)
        #expect(try refusal("intelligence.monthlyCap", .double(10), .double(5), defaults)?.contains("already spent") == true)
        #expect(try refusal("intelligence.totalCap", .double(10), .double(5), defaults)?.contains("already spent") == true)
        #expect(try refusal("intelligence.totalCap", .double(25), .double(10), defaults) == nil)
    }
}
