import Foundation
import Testing
@testable import Sync

/// What Reset All Settings keeps (`SettingsResetKeeps`): the Never show Claude list, the spending
/// limits, every spend record, Rules, saved signatures and migration marks. The spend stores are
/// read off the keys they really write, so a new spend key the list does not name goes red here.
@Suite struct SettingsResetKeepsTests {

    private func suite() -> (UserDefaults, String) {
        let name = "SettingsResetKeeps-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func storedKeys(_ name: String, _ defaults: UserDefaults) -> Set<String> {
        Set((defaults.persistentDomain(forName: name) ?? [:]).keys)
    }

    @Test func everyKeyTheSpendRecordsWriteIsKept() throws {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }
        AskClaudeSpend.record(0.40, in: defaults, now: Date(timeIntervalSince1970: 1_790_000_000))
        AskClaudeSpend.record(0.10, in: defaults, now: Date(timeIntervalSince1970: 1_800_000_000))
        FilingSpendStore.record(
            FilingSpendEntry(timestamp: Date(timeIntervalSince1970: 1_790_000_000), model: "claude-haiku-4-5",
                             fileCount: 5, placedCount: 4, inputTokens: 1000, outputTokens: 0,
                             cacheReadTokens: 0, cacheCreationTokens: 0, estimatedCostUSD: 0.02),
            defaults: defaults)

        let keys = storedKeys(name, defaults)
        // Two months of Ask Claude, and Refine's history, totals and last scan.
        #expect(keys.count == 5, "\(keys.sorted())")
        for key in keys { #expect(SettingsResetKeeps.keeps(key), "\(key) would be reset") }
    }

    /// The copies an unreadable record is set aside under are the only copy of what was spent.
    @Test func theCopiesOfAnUnreadableRecordAreKept() {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }
        let corrupt = Data("{ \"costUSD\": 4.87, \"tok".utf8)
        defaults.set(corrupt, forKey: FilingSpendStore.totalsKey)
        defaults.set(corrupt, forKey: FilingSpendStore.historyKey)
        FilingSpendStore.record(
            FilingSpendEntry(timestamp: Date(timeIntervalSince1970: 1_790_000_000), model: "claude-haiku-4-5",
                             fileCount: 1, placedCount: 1, inputTokens: 10, outputTokens: 0,
                             cacheReadTokens: 0, cacheCreationTokens: 0, estimatedCostUSD: 0.01),
            defaults: defaults)

        let keys = storedKeys(name, defaults)
        #expect(keys.contains(FilingSpendStore.totalsKey + ".unreadable"))
        #expect(keys.contains(FilingSpendStore.historyKey + ".unreadable"))
        for key in keys { #expect(SettingsResetKeeps.keeps(key), "\(key) would be reset") }
    }

    @Test func theHiddenListIsKeptAndTheReadSwitchIsNot() {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }
        AskClaudePrivacy.hide("/Users/u/Documents/Medical", in: defaults)
        defaults.set(true, forKey: AskClaudePrivacy.readsFilesKey)

        #expect(storedKeys(name, defaults) == [AskClaudePrivacy.hiddenFoldersKey, AskClaudePrivacy.readsFilesKey])
        #expect(SettingsResetKeeps.keeps(AskClaudePrivacy.hiddenFoldersKey))
        // Its default, off, is the stricter one.
        #expect(!SettingsResetKeeps.keeps(AskClaudePrivacy.readsFilesKey))
    }

    /// What he made by hand, through the stores that write it.
    @MainActor
    @Test func theChoicesHeMadeByHandAreKept() {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }
        KeptNamesStore(userDefaults: defaults).keep("CON.txt")
        defaults.set(["group-key"], forKey: FileSyncManager.ignoreDefaultsKey)
        defaults.set(Data("[]".utf8), forKey: PersonVetoLog.defaultsKey)
        let keys = storedKeys(name, defaults)
        #expect(keys.count == 3, "\(keys.sorted())")
        for key in keys { #expect(SettingsResetKeeps.keeps(key), "\(key) would be reset") }
    }

    /// The marks that say which shape stored data is in. Without them the next launch migrates what
    /// the app wrote after the reset a second time.
    @Test func theMigrationMarksAreKept() {
        for key in [FileSyncManager.filingRulesMigratedKey, OrganizeScopeDefaults.stampKey, "rootsModelStamp",
                    "rootsModelHandledProviderIds", "iCloudRootMoveStamp", "paneBarArrangementMigration",
                    "browseSidebarFavoritePlacesMigration", "paneColumnWidthFloorLifted"] {
            #expect(SettingsResetKeeps.keeps(key), "\(key)")
        }
    }

    @Test func theSpendingLimitsAreKept() {
        #expect(SettingsResetKeeps.keeps("askClaudeMonthlyLimitUSD"))
        #expect(SettingsResetKeeps.keeps("tidyFilingMonthlyBudgetUSD"))
        #expect(SettingsResetKeeps.keeps("tidyFilingTotalBudgetUSD"))
    }

    /// Automations, the legacy filing rules with their "migrated" flag, and the copies an
    /// unreadable rule list is set aside under — read off the keys the rule store really writes.
    @MainActor
    @Test func everyKeyTheRuleStoresWriteIsKept() {
        let (defaults, name) = suite()
        defer { wipeDefaultsSuite(name) }
        let corrupt = Data("[{\"id\": \"x".utf8)
        for key in [FileSyncManager.automationRulesDefaultsKey, FileSyncManager.rulesDefaultsKey,
                    FileSyncManager.rejectionsDefaultsKey, FileSyncManager.wordRejectionsDefaultsKey] {
            defaults.set(corrupt, forKey: key)
            _ = FileSyncManager.decodePersistedStore([AutomationRule].self, from: defaults, key: key,
                                                     describing: "rules")
        }
        defaults.set(true, forKey: FileSyncManager.filingRulesMigratedKey)

        let keys = storedKeys(name, defaults)
        // Four stores, their set-aside copies, and the flag.
        #expect(keys.count == 9, "\(keys.sorted())")
        for key in keys { #expect(SettingsResetKeeps.keeps(key), "\(key) would be reset") }
    }

    /// Settings and records that are not money, privacy or his own rules and signatures go with the reset.
    @Test func everythingElseIsReset() {
        // Real keys of the domain, and the month prefix without its dot: only `askClaudeSpend.<month>`
        // may ride the prefix.
        for key in ["askClaudeModel", "askClaudeReadsFiles", "askClaudePanelWidth", "askClaudeAnswers",
                    "tidyFilingUseCloud", "tidyFilingCloudModel", "tidyFilingReadContents",
                    "folderJumpRecentsByRoot", "folderJumpStaysByRoot", "editorRecentFiles",
                    "ignoredItems_v1_iCloud", "editorPDFSignatureFace", "editorPDFSignaturePen",
                    "editorPDFSignatureSmoothing", "folderSources", "sourceOrder", "appearanceMode",
                    "hasCompletedSetup", "hasSeenFirstRunWelcome", "setupPrimarySourceId", "browseTabs",
                    "organizeScopePath", "root_override_iCloud", "askClaudeSpend"] {
            #expect(!SettingsResetKeeps.keeps(key), "\(key) would be kept")
        }
    }
}
