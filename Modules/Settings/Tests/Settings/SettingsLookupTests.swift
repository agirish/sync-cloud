import Testing
import Foundation
import Design
import Sync
@testable import Settings

/// Pins what Ask Claude's settings tool answers: matching by the words someone would use, values
/// read from their owners, and the privacy lines it never crosses.
@MainActor
@Suite struct SettingsLookupTests {

    /// A lookup over a scratch suite and a manager on it, with the key, hidden list and login item
    /// as given.
    private func lookup(_ suite: String, keySaved: Bool = false, hidden: Int = 0,
                        loginOn: Bool = false) -> (SettingsLookup, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        let manager = SettingsManager(userDefaults: defaults)
        let lookup = SettingsLookup(defaults: defaults, settings: manager,
                                    keyIsSaved: { keySaved }, hiddenCount: { hidden },
                                    isHidden: { _ in false }, loginItemIsOn: { loginOn })
        return (lookup, defaults)
    }

    private func suiteName(_ test: String = #function) -> String { "SettingsLookupTests.\(test).\(UUID().uuidString)" }

    /// A card and its Undo get a hidden folder's real value; only the words for Claude leave it
    /// out. Given the placeholder, an Undo would write it back as a folder.
    @Test func aHiddenFolderIsRealForTheCardAndHiddenForClaude() async throws {
        let name = suiteName()
        let defaults = UserDefaults(suiteName: name)!
        defer { wipeDefaultsSuite(name) }
        let settings = SettingsManager(autoDiscover: false, userDefaults: defaults, overridesDomainName: name,
                                       cloudStorageLister: { .read([]) }, pathValidator: { _ in true })
        settings.availableProviders = [
            CloudProvider(id: "Acct", displayName: "Dropbox", imageName: "cloud", rootPath: "/Volumes/x/Dropbox", openAt: "Medical", type: .dropBox),
        ]
        let lookup = SettingsLookup(defaults: defaults, settings: settings, keyIsSaved: { false }, hiddenCount: { 1 },
                                    isHidden: { $0.hasSuffix("/Medical") }, loginItemIsOn: { false })
        let openAt = try #require(SettingsCatalog.entry("sources.openAt"))
        #expect(lookup.currentValue(openAt, target: "Acct") == .string("Medical"))
        let words = await lookup.get(["sources.openAt"])
        #expect(words.contains("(hidden from Claude)"))
        #expect(!words.contains("Medical"))
    }

    @Test func findMatchesTheWordsPeopleUse() async {
        let name = suiteName(); defer { wipeDefaultsSuite(name) }
        let (lookup, _) = lookup(name)

        let darkMode = await lookup.find("dark mode")
        #expect(darkMode.components(separatedBy: "\n").first?.hasPrefix("appearance.theme ·") == true)

        let limit = await lookup.find("monthly limit")
        #expect(limit.contains("intelligence.monthlyLimit · Monthly limit (Ask Claude ▸ Key & Spending): $25"))

        #expect(await lookup.find("").hasPrefix("Give words"))
        #expect(await lookup.find("xylophone").hasPrefix("No setting matches"))
    }

    @Test func findReturnsAtMostEight() async {
        let name = suiteName(); defer { wipeDefaultsSuite(name) }
        let (lookup, _) = lookup(name)
        // Single vowels match nearly every entry, so only the cap limits the result.
        let lines = await lookup.find("a e i o u").components(separatedBy: "\n")
        #expect(lines.count <= SettingsLookup.findLimit)
    }

    @Test func getReadsTheStoredValueAndSaysWhatItDoes() async {
        let name = suiteName(); defer { wipeDefaultsSuite(name) }
        let (lookup, defaults) = lookup(name)
        defaults.set(AppearanceMode.dark.rawValue, forKey: LiquidGlass.appearanceModeKey)

        let theme = await lookup.get(["appearance.theme"])
        #expect(theme.contains("value: Dark"))
        #expect(theme.contains("default: System · changed: yes"))
        #expect(theme.contains("choices: System · Light · Dark"))
        #expect(theme.contains("who changes it: you may change it when they ask"))

        let tolerance = await lookup.get(["sync.dateTolerance"])
        #expect(tolerance.contains("value: 1 second"))
        #expect(tolerance.contains("changed: no"))
        #expect(tolerance.contains("help: Counts two modification dates"))
        #expect(tolerance.contains("effects: both panes rescan"))

        #expect(await lookup.get(["no.such"]).contains("no such setting"))
    }

    @Test func theKeyIsOnlySavedOrNot() async {
        let name = suiteName(); defer { wipeDefaultsSuite(name) }
        let saved = await lookup(name, keySaved: true).0.get(["intelligence.apiKey"])
        #expect(saved.contains("value: a key is saved"))
        let none = await lookup(name, keySaved: false).0.get(["intelligence.apiKey"])
        #expect(none.contains("value: no key saved"))
    }

    @Test func hiddenFromClaudeIsOnlyACount() async {
        let name = suiteName(); defer { wipeDefaultsSuite(name) }
        let (lookup, defaults) = lookup(name, hidden: 3)
        defaults.set(["/Users/someone/Medical"], forKey: AskClaudePrivacy.hiddenFoldersKey)

        let hidden = await lookup.get(["intelligence.hidden"])
        #expect(hidden.contains("value: 3 items hidden"))
        #expect(!hidden.contains("Medical"))
        let changed = await lookup.changed()
        #expect(changed.contains("Hidden from Claude (Ask Claude ▸ Privacy): 3 items"))
        #expect(!changed.contains("Medical"))
    }

    @Test func changedListsOnlyWhatDiffers() async {
        let name = suiteName(); defer { wipeDefaultsSuite(name) }
        let (fresh, _) = lookup(name)
        #expect(await fresh.changed() == "Every setting is at its default.")

        let other = suiteName("changedListsOnlyWhatDiffers.b"); defer { wipeDefaultsSuite(other) }
        let (lookup, defaults) = lookup(other, loginOn: true)
        defaults.set(false, forKey: GeneralSettings.confirmBeforeTransferKey)
        defaults.set(50.0, forKey: AskClaudeSpend.limitDefaultsKey)
        let lines = await lookup.changed().components(separatedBy: "\n")
        #expect(lines.contains("Confirm before copying or moving (General): Off — default On"))
        #expect(lines.contains("Monthly limit (Ask Claude ▸ Key & Spending): $50 — default $25"))
        #expect(lines.contains("Launch SyncCloud at login (General): On — default Off"))
        #expect(lines.count == 3)
    }

    @Test func aSettingTurnedOffByAnotherSaysSo() async {
        let name = suiteName(); defer { wipeDefaultsSuite(name) }
        let (lookup, defaults) = lookup(name)
        defaults.set(false, forKey: FileSyncManager.usesAIDefaultsKey)

        let model = await lookup.get(["intelligence.cloudModel"])
        #expect(model.contains("disabled: until Suggest folders with Apple Intelligence is on"))
    }

    @Test func tintSaysItIsDisabledWhileAccentColorIsNone() async {
        let name = suiteName(); defer { wipeDefaultsSuite(name) }
        let (lookup, defaults) = lookup(name)
        defaults.set(LiquidGlassHue.none.rawValue, forKey: LiquidGlass.hueKey)
        #expect(await lookup.get(["appearance.tint"]).contains("disabled: while Accent color is None"))
    }
}
