import Foundation
import Testing
@testable import Sync

/// Removing an automation rule persists. A deletion that doesn't reach the store leaves a zombie
/// rule that keeps filing the user's files on every run with nothing in the UI to explain it. Each test
/// uses a fresh manager over the same defaults (a relaunch), because a removal that mutates before
/// loading persists the unloaded empty array and deletes every rule.
@MainActor
@Suite struct AutomationRuleRemovalTests {

    private func rule(_ name: String, template: String = "Docs") -> AutomationRule {
        AutomationRule(name: name, conditions: [.kindIs(.pdf)], destinationTemplate: template)
    }

    /// A manager over `defaults` that has NOT loaded rules yet — the state a fresh launch is in.
    private func makeManager(_ defaults: UserDefaults) -> FileSyncManager {
        let m = FileSyncManager()
        m.filingRuleDefaults = defaults
        return m
    }

    @Test func removingARulePersistsTheDeletionAcrossRelaunch() throws {
        let defaults = ScratchDefaults("AutomationRemove")
        let keep = rule("Keep"), drop = rule("Drop")
        let writer = makeManager(defaults)
        writer.upsertAutomationRule(keep)
        writer.upsertAutomationRule(drop)

        // A fresh manager removes, so it must load before mutating; skipping the load persists
        // the empty array, and this sees [] rather than [keep].
        let remover = makeManager(defaults)
        remover.removeAutomationRule(id: drop.id)
        #expect(remover.automationRules.map(\.id) == [keep.id])

        // And the deletion is durable: the next launch does not resurrect the rule.
        let reader = makeManager(defaults)
        reader.ensureAutomationRulesLoaded()
        #expect(reader.automationRules.map(\.id) == [keep.id])
    }

    @Test func removingAnUnknownIdLeavesTheStoreUntouched() throws {
        let defaults = ScratchDefaults("AutomationRemoveUnknown")
        let a = rule("A"), b = rule("B")
        let writer = makeManager(defaults)
        writer.upsertAutomationRule(a)
        writer.upsertAutomationRule(b)

        let remover = makeManager(defaults)
        remover.removeAutomationRule(id: UUID())

        let reader = makeManager(defaults)
        reader.ensureAutomationRulesLoaded()
        #expect(reader.automationRules.map(\.id) == [a.id, b.id])
    }

    @Test func removingTheLastRuleDoesNotResurrectIt() throws {
        let defaults = ScratchDefaults("AutomationRemoveLast")
        let only = rule("Only")
        let writer = makeManager(defaults)
        writer.upsertAutomationRule(only)

        let remover = makeManager(defaults)
        remover.removeAutomationRule(id: only.id)
        #expect(remover.automationRules.isEmpty)

        // The empty set is a saved state (an encoded []), not a removed key, so a fresh launch
        // reads "no rules" rather than "nothing saved yet" to back-fill.
        let reader = makeManager(defaults)
        reader.ensureAutomationRulesLoaded()
        #expect(reader.automationRules.isEmpty)
        #expect(defaults.data(forKey: FileSyncManager.automationRulesDefaultsKey) != nil)
    }
}
