import Foundation
import Testing
import Settings
@testable import SyncCloud

/// TE290 step 6: what a change does beyond its value, as a card badges it — one table, judged from
/// the old value to the new, for a click, a suggestion and an Undo alike.
@MainActor
@Suite struct AskClaudeSettingBadgeTests {

    @Test(arguments: [
        // Raising Claude's spending or access.
        ("intelligence.askClaudeModel", "claude-haiku-5-5", "claude-sonnet-5-5", ["↑ Raises"]),
        ("intelligence.readsFiles", "false", "true", ["↑ Raises"]),
        ("intelligence.monthlyLimit", "25.0", "0.0", ["↑ Raises"]),
        // Lowering it: the change Claude may make itself.
        ("intelligence.readsFiles", "true", "false", ["↓ Tightens"]),
        ("intelligence.monthlyLimit", "0.0", "25.0", ["↓ Tightens"]),
        // Removing a safeguard.
        ("sync.whenFileExists", "skip", "replace", ["⚠ Less safe"]),
        ("sync.confirmTransfer", "true", "false", ["⚠ Less safe"]),
        ("sync.confirmTransfer", "false", "true", []),
        // What else happens.
        ("sync.dateTolerance", "1.0", "2.0", ["Rescans"]),
        ("general.showHiddenByDefault", "false", "true", ["↑ Raises", "Next launch"]),
        // Look-and-feel: nothing to badge.
        ("appearance.theme", "system", "dark", []),
    ])
    func aChangeIsBadgedForWhatItDoes(id: String, from: String, to: String, badges: [String]) throws {
        let entry = try #require(SettingsCatalog.entry(id))
        let old = try #require(SettingsCatalog.value(from, for: entry), "\(from) isn't a value of \(id)")
        let new = try #require(SettingsCatalog.value(to, for: entry), "\(to) isn't a value of \(id)")
        #expect(AskClaudeSettingBadge.badges(entry, from: old, to: new).map(\.rawValue) == badges)
        #expect(AskClaudeSettingBadge.badges(entry, from: new, to: new).isEmpty)
    }
}
