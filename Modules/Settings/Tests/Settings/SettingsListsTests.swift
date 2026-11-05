import Foundation
import Testing
import Sync
@testable import Settings

/// A card edits a list one item at a time, through the owners Settings uses, and never names what
/// is hidden from Claude.
@MainActor
@Suite struct SettingsListsTests {

    @MainActor private struct Rig {
        let name: String
        let defaults: UserDefaults
        let settings: SettingsManager
        let sync: FileSyncManager
        var lists: SettingsLists { SettingsLists(settings: settings, sync: sync, defaults: defaults) }

        init(_ test: String) {
            name = "SettingsListsTests.\(test).\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: name)!
            settings = SettingsManager(userDefaults: defaults)
            sync = FileSyncManager()
            sync.ignoredItemsStore = IgnoredItemsStore(userDefaults: defaults)
            sync.keptNamesStore = KeptNamesStore(userDefaults: defaults)
        }
    }

    @Test func aPatternGoesInAsSettingsAddsIt() {
        let rig = Rig(#function); defer { wipeDefaultsSuite(rig.name) }
        let lists = rig.lists
        #expect(lists.add("sync.ignorePatterns", "  ~$*  ") == .done)
        #expect(rig.settings.ignorePatterns.contains("~$*"))
        #expect(lists.add("sync.ignorePatterns", "~$*") == .refused("~$* is already in the list."))
        #expect(lists.add("sync.ignorePatterns", "   ") != .done)
        #expect(lists.contains("sync.ignorePatterns", scoped: "~$*") == true)
        #expect(lists.set("sync.ignorePatterns", scoped: "~$*", present: false) == .done)
        #expect(lists.contains("sync.ignorePatterns", scoped: "~$*") == false)
        #expect(lists.remove("sync.ignorePatterns", "~$*") == .refused("That’s no longer in the list."))
    }

    @Test func keptNamesAndHiddenFoldersGoThroughTheirOwners() {
        let rig = Rig(#function); defer { wipeDefaultsSuite(rig.name) }
        let lists = rig.lists
        #expect(lists.add("organize.keptNames", "Report .pdf") == .done)
        #expect(rig.sync.keptNamesStore?.isKept("Report .pdf") == true)
        #expect(lists.remove("organize.keptNames", "Report .pdf") == .done)
        #expect(rig.sync.keptNamesStore?.isKept("Report .pdf") == false)

        #expect(lists.add("intelligence.hidden", "/Users/me/Documents/Medical") == .done)
        #expect(AskClaudePrivacy.hiddenFolders(in: rig.defaults) == ["/Users/me/Documents/Medical"])
        #expect(lists.remove("intelligence.hidden", "/Users/me/Documents/Medical") == .done)
        #expect(AskClaudePrivacy.hiddenFolders(in: rig.defaults).isEmpty)
    }

    /// An ignored item belongs to the pair it was edited under: under another, it can't be told
    /// whether it is in, so its Undo or Revert can't ignore a path in the wrong comparison.
    @Test func anIgnoredItemKeepsToItsPairOfSources() throws {
        let rig = Rig(#function); defer { wipeDefaultsSuite(rig.name) }
        let store = try #require(rig.sync.ignoredItemsStore)
        store.activate(pairKey: IgnoredItemsStore.pairKey("icloud", "dropbox"))
        let lists = rig.lists
        let scoped = lists.scoped("sync.ignoredItems", "Taxes/2023")
        #expect(lists.set("sync.ignoredItems", scoped: scoped, present: true) == .done)
        #expect(store.rootRelativePaths == ["Taxes/2023"])

        store.activate(pairKey: IgnoredItemsStore.pairKey("icloud", "local"))
        #expect(lists.contains("sync.ignoredItems", scoped: scoped) == nil)
        #expect(lists.set("sync.ignoredItems", scoped: scoped, present: false) != .done)

        store.activate(pairKey: IgnoredItemsStore.pairKey("icloud", "dropbox"))
        #expect(lists.contains("sync.ignoredItems", scoped: scoped) == true)
        #expect(SettingsLists.shown("sync.ignoredItems", scoped) == "Taxes/2023")
    }

    /// An item already there is refused, so nothing records an edit that changed nothing, and Undo
    /// of such a "hide" can't unhide a folder that was hidden all along.
    @Test func addingWhatIsAlreadyThereIsRefused() {
        let rig = Rig(#function); defer { wipeDefaultsSuite(rig.name) }
        let lists = rig.lists
        #expect(lists.add("intelligence.hidden", "/Users/me/Taxes") == .done)
        #expect(lists.add("intelligence.hidden", "/Users/me/Taxes/") == .refused("That folder is already hidden from Claude."))
        #expect(lists.add("organize.keptNames", "a") == .done)
        #expect(lists.add("organize.keptNames", "a") == .refused("That’s already in the list."))
    }

    @Test func anEditInWordsNeverNamesWhatIsHidden() {
        #expect(SettingsLists.edit("sync.ignorePatterns", "~$*", present: true, isHidden: { _ in false }) == "added ~$*")
        #expect(SettingsLists.edit("sync.ignoredItems", "Medical/scan.pdf", present: false, isHidden: { $0.hasPrefix("Medical") })
                == "removed an item hidden from Claude")
        #expect(SettingsLists.edit("intelligence.hidden", "/Users/me/Documents/Medical", present: true, isHidden: { _ in false })
                == "hid a folder")
        #expect(SettingsLists.raises("intelligence.hidden", present: false))
        #expect(!SettingsLists.raises("intelligence.hidden", present: true))
        #expect(!SettingsLists.raises("sync.ignorePatterns", present: false))
        #expect(SettingsLists.takesClaudesPick("sync.ignorePatterns") && !SettingsLists.takesClaudesPick("organize.keptNames"))
    }
}
