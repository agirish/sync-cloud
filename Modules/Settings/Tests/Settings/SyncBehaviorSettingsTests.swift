import Testing
import Foundation
@testable import Settings
import Sync

/// Coverage for the Sync/Advanced-tab settings added with the expanded Settings surface:
/// persistence round-trips for date tolerance, scan-time verification, remembered ignores,
/// and ignore patterns; pattern add/remove normalization; the delete-confirmation default;
/// and the full reset.
@Suite struct SyncBehaviorSettingsTests {

    @MainActor
    private func makeManager(_ test: TestDefaults) -> SettingsManager {
        SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) })
    }

    @MainActor
    @Test func testDefaultsMatchHistoricalBehavior() {
        let test = TestDefaults()
        let settings = makeManager(test)
        #expect(settings.dateToleranceSeconds == 1)
        #expect(settings.autoVerifySameSizeDuringScan == false)
        #expect(settings.rememberIgnoredItems == true)
        #expect(settings.ignorePatterns.isEmpty)
        #expect(settings.conflictPolicy == .ask)
        #expect(settings.defaultSortOption == .name)
    }

    @MainActor
    @Test func testNewSettingsPersistAcrossInstances() {
        let test = TestDefaults()

        let a = makeManager(test)
        a.dateToleranceSeconds = 5
        a.autoVerifySameSizeDuringScan = true
        a.rememberIgnoredItems = false
        a.ignorePatterns = ["*.tmp", ".DS_Store"]
        a.conflictPolicy = .keepBoth
        a.defaultSortOption = .dateModified

        let b = makeManager(test)
        #expect(b.dateToleranceSeconds == 5)
        #expect(b.autoVerifySameSizeDuringScan == true)
        #expect(b.rememberIgnoredItems == false)
        #expect(b.ignorePatterns == ["*.tmp", ".DS_Store"])
        #expect(b.conflictPolicy == .keepBoth)
        #expect(b.defaultSortOption == .dateModified)
    }

    @Test func testShouldRestoreLastFocusDefaultsToTrue() {
        let test = TestDefaults()
        #expect(GeneralSettings.shouldRestoreLastFocus(test.defaults))
        test.defaults.set(false, forKey: GeneralSettings.restoreLastFocusKey)
        #expect(!GeneralSettings.shouldRestoreLastFocus(test.defaults))
    }

    @MainActor
    @Test func testAddIgnorePatternNormalizesAndDeduplicates() {
        let test = TestDefaults()
        let settings = makeManager(test)

        #expect(settings.addIgnorePattern("  *.tmp \n"))
        #expect(settings.ignorePatterns == ["*.tmp"])
        // Duplicate and whitespace-only input are refused.
        #expect(!settings.addIgnorePattern("*.tmp"))
        #expect(!settings.addIgnorePattern("   "))
        #expect(settings.ignorePatterns == ["*.tmp"])

        settings.removeIgnorePattern("*.tmp")
        #expect(settings.ignorePatterns.isEmpty)
    }

    @Test func testShouldConfirmBeforeDeleteDefaultsToTrue() {
        let test = TestDefaults()
        #expect(GeneralSettings.shouldConfirmBeforeDelete(test.defaults))
        test.defaults.set(false, forKey: GeneralSettings.confirmBeforeDeleteKey)
        #expect(!GeneralSettings.shouldConfirmBeforeDelete(test.defaults))
        test.defaults.set(true, forKey: GeneralSettings.confirmBeforeDeleteKey)
        #expect(GeneralSettings.shouldConfirmBeforeDelete(test.defaults))
    }

    @Test func testShouldConfirmBeforeTransferDefaultsToTrue() {
        // Default-true semantics like the delete flag: an unset key must confirm, not skip.
        let test = TestDefaults()
        #expect(GeneralSettings.shouldConfirmBeforeTransfer(test.defaults))
        test.defaults.set(false, forKey: GeneralSettings.confirmBeforeTransferKey)
        #expect(!GeneralSettings.shouldConfirmBeforeTransfer(test.defaults))
        test.defaults.set(true, forKey: GeneralSettings.confirmBeforeTransferKey)
        #expect(GeneralSettings.shouldConfirmBeforeTransfer(test.defaults))
    }

    @MainActor
    @Test func testResetAllSettingsClearsTheDomainAndRepublishesDefaults() {
        let test = TestDefaults()
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            overridesDomainName: test.suiteName,
            cloudStorageLister: { .read([]) }
        )

        settings.setPath("/tmp/custom-root", for: "iCloud")
        settings.dateToleranceSeconds = 60
        settings.ignorePatterns = ["*.tmp"]
        settings.conflictPolicy = .replace
        settings.defaultSortOption = .size
        test.defaults.set(false, forKey: GeneralSettings.confirmBeforeDeleteKey)

        settings.resetAllSettings()

        #expect(settings.dateToleranceSeconds == 1)
        #expect(settings.autoVerifySameSizeDuringScan == false)
        #expect(settings.rememberIgnoredItems == true)
        #expect(settings.ignorePatterns.isEmpty)
        #expect(settings.conflictPolicy == .ask)
        #expect(settings.defaultSortOption == .name)
        #expect(settings.disabledProviderIds.isEmpty)
        // Foreign keys in the same domain (the @AppStorage-backed toggles) are wiped too.
        #expect(GeneralSettings.shouldConfirmBeforeDelete(test.defaults))
        #expect(test.defaults.string(forKey: "root_override_iCloud") == nil)
    }

    /// The reset keeps what `SettingsResetKeeps` names — the Never show Claude list, the spending
    /// limits, the spend records, Automations and saved signatures — and takes the rest of what Claude was set to, which used to
    /// go with the whole domain: every folder he had hidden was shown to Claude again.
    @MainActor
    @Test func testResetAllSettingsKeepsTheHiddenListLimitsAndSpend() {
        let test = TestDefaults()
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            overridesDomainName: test.suiteName,
            cloudStorageLister: { .read([]) }
        )
        let defaults = test.defaults
        AskClaudePrivacy.hide("/Users/u/Documents/Medical", in: defaults)
        defaults.set(true, forKey: AskClaudePrivacy.readsFilesKey)
        defaults.set(5.0, forKey: AskClaudeSpend.limitDefaultsKey)
        AskClaudeSpend.record(3.10, in: defaults)
        defaults.set(2.0, forKey: FileSyncManager.monthlyBudgetCapKey)
        defaults.set(1.0, forKey: FileSyncManager.totalBudgetCapKey)
        FilingSpendStore.record(
            FilingSpendEntry(timestamp: Date(), model: "claude-haiku-4-5", fileCount: 5, placedCount: 4,
                             inputTokens: 1000, outputTokens: 0, cacheReadTokens: 0,
                             cacheCreationTokens: 0, estimatedCostUSD: 0.75),
            defaults: defaults)
        defaults.set(Data("[]".utf8), forKey: FileSyncManager.automationRulesDefaultsKey)
        defaults.set(Data("[]".utf8), forKey: FileSyncManager.rulesDefaultsKey)
        defaults.set(true, forKey: FileSyncManager.filingRulesMigratedKey)
        defaults.set(Data("[]".utf8), forKey: "editorPDFSavedSignatures")
        defaults.set("cursive", forKey: "editorPDFSignatureFace")
        defaults.set("claude-opus-4-1", forKey: "askClaudeModel")
        defaults.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        defaults.set(RootsMigration.currentStamp, forKey: RootsMigration.stampKey)
        defaults.set(["iCloud"], forKey: RootsMigration.handledProviderIdsKey)
        defaults.set(RootsMigration.iCloudRootMoveStamp, forKey: RootsMigration.iCloudRootMoveStampKey)
        settings.dateToleranceSeconds = 60
        settings.setSourceOrder(["Dropbox", "iCloud"])
        let kept = Set((defaults.persistentDomain(forName: test.suiteName) ?? [:]).keys)
            .filter(SettingsResetKeeps.keeps)
        // The hidden list, three limits, this month's Ask Claude spend, Refine's history, totals, last,
        // both rule stores and their flag, the signatures, and the three roots marks.
        #expect(kept.count == 15, "\(kept.sorted())")

        // Key by key, so the hidden list is there at every change the reset makes — a reader on
        // another thread never sees it gone. Removing the domain and writing it back would not be.
        let hiddenMissing = CallCounter()
        let changes = CallCounter()
        let watcher = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { _ in
            changes.increment()
            if AskClaudePrivacy.hiddenFolders(in: defaults).isEmpty { hiddenMissing.increment() }
        }
        defer { NotificationCenter.default.removeObserver(watcher) }

        let privacyPosts = CallCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: AskClaudePrivacy.didChange, object: defaults, queue: nil) { _ in privacyPosts.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }

        settings.resetAllSettings()

        let left = Set((defaults.persistentDomain(forName: test.suiteName) ?? [:]).keys)
        // The manager writes its own settings back at their defaults, so the domain is not only these.
        #expect(kept.isSubset(of: left), "\(kept.subtracting(left).sorted())")
        #expect(AskClaudePrivacy.hiddenFolders(in: defaults) == ["/Users/u/Documents/Medical"])
        #expect(AskClaudeSpend.limit(in: defaults) == 5)
        #expect(AskClaudeSpend.spent(in: defaults) == 3.10)
        #expect(FileSyncManager.totalBudgetCap(in: defaults) == 1)
        #expect(defaults.double(forKey: FileSyncManager.monthlyBudgetCapKey) == 2)
        #expect(FilingSpendStore.totals(defaults: defaults).costUSD == 0.75)
        #expect(!AskClaudePrivacy.readsFiles(in: defaults))
        #expect(defaults.data(forKey: FileSyncManager.automationRulesDefaultsKey) != nil)
        #expect(defaults.bool(forKey: FileSyncManager.filingRulesMigratedKey))
        #expect(defaults.data(forKey: "editorPDFSavedSignatures") != nil)
        #expect(defaults.string(forKey: "editorPDFSignatureFace") == nil)
        #expect(defaults.string(forKey: "askClaudeModel") == nil)
        #expect(defaults.object(forKey: FileSyncManager.usesCloudDefaultsKey) == nil)
        #expect(settings.dateToleranceSeconds == 1)
        #expect(settings.sourceOrder.isEmpty)
        #expect(defaults.object(forKey: "sourceOrder") == nil)
        #expect(changes.count > 1)
        #expect(hiddenMissing.count == 0)
        // The read switch changed, so whatever caches what Claude may see is told — by this reset:
        // the other tests' resets, running beside this one, post for their own stores.
        #expect(privacyPosts.count == 1)
    }

    /// The confirmation says what stays, not only what goes.
    @Test func testTheResetConfirmationNamesWhatItKeeps() throws {
        let parts = AdvancedSettingsTab.resetAllExplanation.components(separatedBy: "Kept:")
        try #require(parts.count == 2)
        // "Rules", the name Organize shows; "Automations" is a retired workspace name.
        for phrase in ["Rules", "saved signatures", "folders you hid from Claude", "spending limits",
                       "what it has cost", "API key", "files on disk"] {
            #expect(parts[1].contains(phrase), "\(phrase)")
            #expect(!parts[0].contains(phrase), "\(phrase) is also named as removed")
        }
        #expect(parts[0].contains("Folders you added as sources"))
        // Setup offers itself again only where no folder profile exists, so the alert does not
        // promise it will.
        #expect(parts[0].contains("forgets that setup has run"))
        #expect(!AdvancedSettingsTab.resetAllExplanation.contains("offer itself"))
    }
}
