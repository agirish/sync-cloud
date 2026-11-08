import Foundation
import Testing
@testable import Sync

/// What Reset All Settings keeps (`SettingsResetKeeps`): the Never show Claude list, the spending
/// limit, every spend record, Rules, saved signatures and migration marks. The spend stores are
/// read off the keys they really write, so a new spend key the list does not name goes red here.
@Suite struct SettingsResetKeepsTests {

    /// A throwaway suite and its name; it wipes itself when the test lets go of it.
    private func suite() -> (ScratchDefaults, String) {
        let defaults = ScratchDefaults("SettingsResetKeeps")
        return (defaults, defaults.scratchSuiteName)
    }

    private func storedKeys(_ name: String, _ defaults: UserDefaults) -> Set<String> {
        Set((defaults.persistentDomain(forName: name) ?? [:]).keys)
    }

    /// Refine's retired record is only ever read now, so the test writes its payloads the way the old
    /// store did: the keys it used, JSON-encoded.
    private func writeOldRecord(_ defaults: UserDefaults) throws {
        let entry = FilingSpendEntry(timestamp: Date(timeIntervalSince1970: 1_790_000_000), model: "claude-haiku-4-5",
                                     fileCount: 5, placedCount: 4, inputTokens: 1000, outputTokens: 0,
                                     cacheReadTokens: 0, cacheCreationTokens: 0, estimatedCostUSD: 0.02)
        defaults.set(try JSONEncoder().encode([entry]), forKey: FilingSpendStore.historyKey)
        defaults.set(try JSONEncoder().encode(FilingSpendTotals(costUSD: 0.02, tokens: 1000, scans: 1)),
                     forKey: FilingSpendStore.totalsKey)
        defaults.set(try JSONEncoder().encode(entry), forKey: FilingSpendStore.lastKey)
    }

    @Test func everyKeyTheSpendRecordsWriteIsKept() throws {
        let (defaults, name) = suite()
        AskClaudeSpend.record(0.40, in: defaults, now: Date(timeIntervalSince1970: 1_790_000_000))
        AskClaudeSpend.record(0.10, in: defaults, now: Date(timeIntervalSince1970: 1_800_000_000))
        AskClaudeSpend.recordOrganize(0.05, in: defaults, now: Date(timeIntervalSince1970: 1_800_000_000))
        try writeOldRecord(defaults)

        let keys = storedKeys(name, defaults)
        // Two months of Ask Claude, Organize's share of one, and Refine's old history, totals and last scan.
        #expect(keys.count == 6, "\(keys.sorted())")
        for key in keys { #expect(SettingsResetKeeps.keeps(key), "\(key) would be reset") }
    }

    /// The copies an unreadable record is set aside under are the only copy of what was spent.
    @Test func theCopiesOfAnUnreadableRecordAreKept() {
        let (defaults, name) = suite()
        let corrupt = Data("{ \"costUSD\": 4.87, \"tok".utf8)
        defaults.set(corrupt, forKey: FilingSpendStore.totalsKey)
        defaults.set(corrupt, forKey: FilingSpendStore.historyKey)
        // Reading sets the copies aside. Both are read, not asked through `isUnreadable`, which stops
        // at the first unreadable one.
        if case .unreadable = FilingSpendStore.totalsRead(defaults: defaults) {} else { Issue.record("totals not unreadable") }
        if case .unreadable = FilingSpendStore.entriesRead(defaults: defaults) {} else { Issue.record("history not unreadable") }

        let keys = storedKeys(name, defaults)
        #expect(keys.contains(FilingSpendStore.totalsKey + ".unreadable"))
        #expect(keys.contains(FilingSpendStore.historyKey + ".unreadable"))
        for key in keys { #expect(SettingsResetKeeps.keeps(key), "\(key) would be reset") }
    }

    /// The one-time carry-over's stamp and its notice survive a reset: run again, the carry-over would
    /// find nothing and say nothing, and a notice not yet read would be lost.
    @Test func theRefineMigrationsStampAndNoticeAreKept() {
        #expect(SettingsResetKeeps.keeps(RefineSpendMigration.doneKey))
        #expect(SettingsResetKeeps.keeps(RefineSpendMigration.noticeKey))
    }

    @Test func theHiddenListIsKeptAndTheSharedListIsNot() {
        let (defaults, name) = suite()
        AskClaudePrivacy.hide("/Users/u/Documents/Medical", in: defaults)
        AskClaudePrivacy.shareWithoutAsking("/Users/u/Documents/Recipes", in: defaults)

        #expect(storedKeys(name, defaults) == [AskClaudePrivacy.hiddenFoldersKey, AskClaudePrivacy.sharedFoldersKey])
        #expect(SettingsResetKeeps.keeps(AskClaudePrivacy.hiddenFoldersKey))
        // Its default, none, is the stricter one.
        #expect(!SettingsResetKeeps.keeps(AskClaudePrivacy.sharedFoldersKey))
    }

    /// What he made by hand, through the stores that write it.
    @MainActor
    @Test func theChoicesHeMadeByHandAreKept() {
        let (defaults, name) = suite()
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
        for key in ["rootsModelStamp",
                    "rootsModelHandledProviderIds", "paneBarArrangementMigration",
                    "infoPreviewMigrationDone"] {
            #expect(SettingsResetKeeps.keeps(key), "\(key)")
        }
    }

    @Test func theSpendingLimitIsKept() {
        #expect(SettingsResetKeeps.keeps("askClaudeMonthlyLimitUSD"))
    }

    /// Automations, the rejections, and the copies an unreadable rule list is set aside under —
    /// read off the keys the rule store really writes.
    @MainActor
    @Test func everyKeyTheRuleStoresWriteIsKept() {
        let (defaults, name) = suite()
        let corrupt = Data("[{\"id\": \"x".utf8)
        for key in [FileSyncManager.automationRulesDefaultsKey,
                    FileSyncManager.rejectionsDefaultsKey, FileSyncManager.wordRejectionsDefaultsKey] {
            defaults.set(corrupt, forKey: key)
            _ = FileSyncManager.decodePersistedStore([AutomationRule].self, from: defaults, key: key,
                                                     describing: "rules")
        }

        let keys = storedKeys(name, defaults)
        // Three stores and their set-aside copies.
        #expect(keys.count == 6, "\(keys.sorted())")
        for key in keys { #expect(SettingsResetKeeps.keeps(key), "\(key) would be reset") }
    }

    /// Settings and records that are not money, privacy or his own rules and signatures go with the reset.
    @Test func everythingElseIsReset() {
        // Real keys of the domain, and the month prefix without its dot: only `askClaudeSpend.<month>`
        // may ride the prefix.
        for key in ["askClaudeModel", "askClaudeSharedFolders", "askClaudePanelWidth", "askClaudeAnswers",
                    "askClaudePanelPlacement", "askClaudePanelPinned", "askClaudePinnedWidth",
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
