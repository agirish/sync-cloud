import Foundation
import Testing
@testable import Sync

/// The removal half of the automation-rule lifecycle.
///
/// `upsertAutomationRule` has an end-to-end persistence test (`PersistedStoreWriteTests`); the
/// removal half had none, and it is the only half that can leave a ZOMBIE: a deletion that does
/// not reach the store keeps filing the user's files on every subsequent run, silently, with the
/// rule no longer visible anywhere in the UI to explain why. Every test here drives a FRESH
/// manager over the same defaults — the relaunch shape — because the dangerous mutation is not
/// "forgot to persist" alone: a removal that mutates before loading persists the unloaded empty
/// array, deleting every rule to delete one.
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

        // A fresh manager (the relaunch) removes. The method must load the persisted rules
        // before mutating — a removal that skipped the load would persist the unloaded empty
        // array, which this first assertion sees as [] rather than [keep].
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

        // The empty set is a real saved state (the key holds an encoded []), not a removed key —
        // and a fresh launch reads it as "no rules", not as "nothing saved yet" to be back-filled
        // from anywhere else. The rule stays gone.
        let reader = makeManager(defaults)
        reader.ensureAutomationRulesLoaded()
        #expect(reader.automationRules.isEmpty)
        #expect(defaults.data(forKey: FileSyncManager.automationRulesDefaultsKey) != nil)
    }
}
