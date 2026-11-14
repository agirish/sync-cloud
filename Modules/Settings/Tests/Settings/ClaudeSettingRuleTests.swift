import Testing
import Foundation
import Sync
@testable import Settings

/// Pins which changes Claude may make itself: look-and-feel either way; its own reach only lower,
/// and never to a limit at or below what is already spent.
@MainActor
@Suite struct ClaudeSettingRuleTests {

    private func scratch(_ test: String = #function) -> ScratchDefaults {
        ScratchDefaults("ClaudeSettingRuleTests.\(test)")
    }

    private func refusal(_ id: String, _ from: SettingValue?, _ to: SettingValue, _ defaults: UserDefaults) throws -> String? {
        ClaudeSettingRule.refusal(try #require(SettingsCatalog.entry(id)), from: from, to: to, defaults: defaults)
    }

    @Test func lookAndFeelChangesEitherWay() throws {
        let defaults = scratch()
        #expect(try refusal("appearance.theme", .string("system"), .string("dark"), defaults) == nil)
        #expect(try refusal("readability.textSize", .int(110), .int(100), defaults) == nil)
        #expect(try refusal("readability.textSize", .int(100), .int(110), defaults) == nil)
    }

    @Test func onlyTheirClickChangesASuggestedSetting() throws {
        let defaults = scratch()
        #expect(try refusal("sync.confirmTransfer", .bool(true), .bool(false), defaults) != nil)
        #expect(try refusal("intelligence.askClaudeModel", .string(AskClaudeModels.opus.id),
                            .string(AskClaudeModels.haiku.id), defaults) != nil)
    }

    @Test func reachGoesOnlyDown() throws {
        let defaults = scratch()
        #expect(try refusal("intelligence.monthlyLimit", .double(25), .double(10), defaults) == nil)
        #expect(try refusal("intelligence.monthlyLimit", .double(25), .double(50), defaults) != nil)
        // 0 is No limit, the highest there is: from it any limit lowers, and to it never does.
        #expect(try refusal("intelligence.monthlyLimit", .double(25), .double(0), defaults) != nil)
        // A value it can't read now can't be judged a lowering.
        #expect(try refusal("intelligence.monthlyLimit", nil, .double(10), defaults) != nil)
    }

    @Test func aLimitNeverGoesToWhatsAlreadySpent() throws {
        let defaults = scratch()
        // The chat's and Organize's spend are one total, so the limit can't go to what both have spent.
        AskClaudeSpend.record(4, in: defaults)
        AskClaudeSpend.recordOrganize(6, in: defaults)
        #expect(try refusal("intelligence.monthlyLimit", .double(25), .double(10), defaults)?.contains("already spent") == true)
        #expect(try refusal("intelligence.monthlyLimit", .double(25), .double(5), defaults) != nil)
        #expect(try refusal("intelligence.monthlyLimit", .double(50), .double(25), defaults) == nil)
    }
}
