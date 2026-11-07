import Foundation
import Security
import Testing
import Events
import Sync
@testable import Settings

/// The buttons a card presses ask in Settings' words, run Settings' own code, and say what they
/// did.
@MainActor
@Suite struct SettingsActionsTests {

    private func scratch(_ test: String = #function) -> (String, UserDefaults) {
        let name = "SettingsActionsTests.\(test).\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    private func lookup(_ defaults: UserDefaults, _ settings: SettingsManager?) -> SettingsLookup {
        SettingsLookup(defaults: defaults, settings: settings, keyIsSaved: { false }, hiddenCount: { 0 },
                       isHidden: { _ in false }, loginItemIsOn: { false })
    }

    /// Each one is a button in the catalog, and exactly those that ask twice ask.
    @Test func everyActionIsACatalogButtonAndOnlyAsksTwiceAsks() throws {
        let actions = SettingsActions(settings: nil, sync: nil, lookup: nil)
        for id in SettingsActions.ids {
            let entry = try #require(SettingsCatalog.entry(id), "\(id) isn't in the catalog")
            guard case .button = entry.control else { Issue.record("\(id) isn't a button"); continue }
            #expect((actions.prompt(id, target: nil) != nil) == (entry.tier == .asksTwice), "\(id)")
        }
    }

    @Test func theQuestionsAreSettingsOwnWords() {
        let actions = SettingsActions(settings: nil, sync: nil, lookup: nil)
        #expect(actions.prompt("advanced.logClear", target: nil)?.messageText == "Clear the Activity Log?")
        #expect(actions.prompt("advanced.logClear", target: nil)?.informativeText == Logger.clearPrompt.informativeText)
        #expect(actions.prompt("intelligence.apiKeyRemove", target: nil)?.messageText == CloudKeyRow.removePrompt.messageText)
        #expect(actions.prompt("intelligence.costClear", target: nil)?.informativeText == FilingSpendStore.clearPrompt.informativeText)
        #expect(actions.prompt("advanced.resetSetup", target: nil)?.messageText == AdvancedSettingsTab.resetSetupPrompt.messageText)
        #expect(actions.prompt("advanced.resetAll", target: nil)?.informativeText.hasPrefix(AdvancedSettingsTab.resetAllExplanation) == true)
        #expect(actions.prompt("sources.removeFolder", target: nil) == .removeFolderSource(named: "this source"))
    }

    /// Reset All keeps the limits, but names what else it would raise from the values now.
    @Test func resetAllNamesWhatItWouldRaise() {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        defaults.set(AskClaudeModels.haiku.id, forKey: AskClaudeModels.defaultsKey)
        let actions = SettingsActions(settings: nil, sync: nil, lookup: lookup(defaults, nil))
        #expect(actions.resetAllRaises().contains { $0.hasPrefix("Model back to Sonnet") })
        defaults.set(10.0, forKey: AskClaudeSpend.limitDefaultsKey)
        #expect(!actions.resetAllRaises().contains { $0.hasPrefix("Monthly limit") }, "a kept limit was named")
        let question = actions.prompt("advanced.resetAll", target: nil)?.informativeText ?? ""
        #expect(question.contains("This also raises what Claude may do: Model back to Sonnet"))
        defaults.set(false, forKey: FileSyncManager.readContentsDefaultsKey)
        #expect(actions.resetAllRaises().contains("Read file contents on this Mac back to On"))
    }

    @Test func aPressRunsSettingsOwnCode() async throws {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        let sync = FileSyncManager()
        sync.keptNamesStore = KeptNamesStore(userDefaults: defaults)
        sync.keptNamesStore?.keep("Report .pdf")
        var resets = 0
        var actions = SettingsActions(settings: nil, sync: sync, lookup: lookup(defaults, nil))
        actions.resetAll = { resets += 1 }
        #expect(await actions.run("organize.keptNamesClearAll", target: nil) == .done("Cleared 1 allowed name."))
        #expect(sync.keptNamesStore?.names.isEmpty == true)
        #expect(await actions.run("advanced.resetAll", target: nil) != .refused("That button is in Settings."))
        #expect(resets == 1)
        #expect(await actions.run("sources.removeFolder", target: "icloud") == .refused("That can’t be done here right now."))
        #expect(await actions.run("people.lookForNames", target: nil) == .refused("That button is in Settings."))
    }

    /// Clear All asked about one pair of sources clears nothing once another pair is open.
    @Test func clearAllRefusesOnceThePairHasChanged() async throws {
        let (name, defaults) = scratch(); defer { wipeDefaultsSuite(name) }
        let sync = FileSyncManager()
        let store = IgnoredItemsStore(userDefaults: defaults)
        sync.ignoredItemsStore = store
        store.activate(pairKey: IgnoredItemsStore.pairKey("icloud", "dropbox"))
        store.add(["Taxes"])
        let actions = SettingsActions(settings: nil, sync: sync, lookup: lookup(defaults, nil))
        let asked = actions.scope("sync.ignoredItemsClearAll")
        store.activate(pairKey: IgnoredItemsStore.pairKey("icloud", "local"))
        store.add(["Work"])
        #expect(await actions.run("sync.ignoredItemsClearAll", target: nil, scope: asked)
                == .refused("The comparison changed since you were asked, so nothing was cleared."))
        #expect(store.rootRelativePaths == ["Work"])
    }

    @Test func aRefusedKeyRemovalSaysTheKeyIsStillThere() async {
        final class Locked: KeychainStore, @unchecked Sendable {
            func delete(_ query: [String: Any]) -> OSStatus { errSecInteractionNotAllowed }
            func add(_ attributes: [String: Any]) -> OSStatus { errSecInteractionNotAllowed }
            func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) { (errSecSuccess, nil) }
            func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { errSecInteractionNotAllowed }
        }
        var actions = SettingsActions(settings: nil, sync: nil, lookup: nil)
        actions.keychain = Locked()
        guard case .refused(let why) = await actions.run("intelligence.apiKeyRemove", target: nil) else {
            Issue.record("a refused removal said it was done"); return
        }
        #expect(why.contains("It is still stored"))
    }
}
