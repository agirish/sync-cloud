import Testing
import Foundation
@testable import Settings
import Sync

/// Coverage for the Sync and Advanced tab settings: persistence round-trips for date tolerance,
/// scan-time verification, remembered ignores and ignore patterns; pattern add/remove
/// normalization; the delete-confirmation default; and the full reset.
@Suite struct SyncBehaviorSettingsTests {

    @MainActor
    @Test func testDefaultsMatchHistoricalBehavior() {
        let test = TestDefaults()
        let settings = test.manager()
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

        let a = test.manager()
        a.dateToleranceSeconds = 5
        a.autoVerifySameSizeDuringScan = true
        a.rememberIgnoredItems = false
        a.ignorePatterns = ["*.tmp", ".DS_Store"]
        a.conflictPolicy = .keepBoth
        a.defaultSortOption = .dateModified

        let b = test.manager()
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
        let settings = test.manager()

        #expect(settings.addIgnorePattern("  *.tmp \n"))
        #expect(settings.ignorePatterns == ["*.tmp"])
        // Duplicate and whitespace-only input are refused.
        #expect(!settings.addIgnorePattern("*.tmp"))
        #expect(!settings.addIgnorePattern("   "))
        #expect(settings.ignorePatterns == ["*.tmp"])

        settings.removeIgnorePattern("*.tmp")
        #expect(settings.ignorePatterns.isEmpty)
    }

    /// The two confirm flags, each read through its own reader.
    enum ConfirmFlag: String, CaseIterable {
        case delete, transfer
        var key: String {
            self == .delete ? GeneralSettings.confirmBeforeDeleteKey : GeneralSettings.confirmBeforeTransferKey
        }
        func read(_ defaults: UserDefaults) -> Bool {
            self == .delete ? GeneralSettings.shouldConfirmBeforeDelete(defaults)
                : GeneralSettings.shouldConfirmBeforeTransfer(defaults)
        }
    }

    /// Default-true semantics: an unset key must confirm, not skip.
    @Test(arguments: ConfirmFlag.allCases) func testShouldConfirmDefaultsToTrue(_ flag: ConfirmFlag) {
        let test = TestDefaults()
        #expect(flag.read(test.defaults))
        test.defaults.set(false, forKey: flag.key)
        #expect(!flag.read(test.defaults))
        test.defaults.set(true, forKey: flag.key)
        #expect(flag.read(test.defaults))
    }

    @MainActor
    @Test func testResetAllSettingsClearsTheDomainAndRepublishesDefaults() {
        let test = TestDefaults()
        let settings = test.manager(domain: test.suiteName)

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

    /// The reset keeps what `SettingsResetKeeps` names (the Never show Claude list, spending
    /// limits, spend records, rules and saved signatures) and resets the rest, including what
    /// Claude was set to. Losing the hidden list would show every hidden folder to Claude again.
    @MainActor
    @Test func testResetAllSettingsKeepsTheHiddenListLimitsAndSpend() {
        let test = TestDefaults()
        let settings = test.manager(domain: test.suiteName)
        let defaults = test.defaults
        AskClaudePrivacy.hide("/Users/u/Documents/Medical", in: defaults)
        AskClaudePrivacy.shareWithoutAsking("/Users/u/Documents/Recipes", in: defaults)
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
        defaults.set(Data("[]".utf8), forKey: FileSyncManager.rejectionsDefaultsKey)
        defaults.set(["a"], forKey: "folderJumpPinnedByRoot")
        defaults.set(Data("{}".utf8), forKey: "folderJumpRecentsByRoot")
        defaults.set(RootsMigration.currentStamp, forKey: RootsMigration.stampKey)
        defaults.set(["iCloud"], forKey: RootsMigration.handledProviderIdsKey)
        defaults.set(RootsMigration.iCloudRootMoveStamp, forKey: RootsMigration.iCloudRootMoveStampKey)
        settings.dateToleranceSeconds = 60
        settings.setSourceOrder(["Dropbox", "iCloud"])
        let kept = Set((defaults.persistentDomain(forName: test.suiteName) ?? [:]).keys)
            .filter(SettingsResetKeeps.keeps)
        // The hidden list, three limits, this month's Ask Claude spend, Refine's history, totals, last,
        // both rule stores and their flag, the signatures, the rejections, the pins, and the three
        // roots marks.
        #expect(kept.count == 17, "\(kept.sorted())")

        // Key by key, so the hidden list is there at every change the reset makes and a reader on
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
        #expect(AskClaudePrivacy.sharedFolders(in: defaults).isEmpty)
        #expect(defaults.data(forKey: FileSyncManager.automationRulesDefaultsKey) != nil)
        #expect(defaults.bool(forKey: FileSyncManager.filingRulesMigratedKey))
        #expect(defaults.data(forKey: "editorPDFSavedSignatures") != nil)
        #expect(defaults.string(forKey: "editorPDFSignatureFace") == nil)
        #expect(defaults.object(forKey: "folderJumpRecentsByRoot") == nil)
        #expect(defaults.string(forKey: "askClaudeModel") == nil)
        #expect(defaults.object(forKey: FileSyncManager.usesCloudDefaultsKey) == nil)
        #expect(settings.dateToleranceSeconds == 1)
        #expect(settings.sourceOrder.isEmpty)
        #expect(defaults.object(forKey: "sourceOrder") == nil)
        #expect(changes.count > 1)
        #expect(hiddenMissing.count == 0)
        // The read switch changed, so whatever caches what Claude may see is told, once: other
        // tests' resets running beside this one post for their own stores.
        #expect(privacyPosts.count == 1)
    }

    /// Given a store but no domain name, the reset clears that store's own keys. Fails if it lists
    /// the app's domain instead, leaving a key only the store holds.
    @MainActor
    @Test func testResetAllSettingsWithNoDomainNameClearsTheStoreItWasGiven() {
        let test = TestDefaults()
        let settings = test.manager()
        let defaults = test.defaults
        AskClaudePrivacy.hide("/Users/u/Documents/Medical", in: defaults)
        defaults.set("cursive", forKey: "resetAllTest.onlyInThisStore")

        settings.resetAllSettings()

        #expect(defaults.object(forKey: "resetAllTest.onlyInThisStore") == nil)
        #expect(AskClaudePrivacy.hiddenFolders(in: defaults) == ["/Users/u/Documents/Medical"])
    }

    /// The confirmation says what stays, not only what goes.
    @Test func testTheResetConfirmationNamesWhatItKeeps() throws {
        let parts = AdvancedSettingsTab.resetAllExplanation.components(separatedBy: "Kept:")
        try #require(parts.count == 2)
        // "Rules", the name Organize shows; "Automations" is a retired workspace name.
        for phrase in ["Rules", "saved signatures", "Favorites and pins", "folders you hid from Claude", "spending limits",
                       "what it has cost", "API key", "your files"] {
            #expect(parts[1].contains(phrase), "\(phrase)")
            #expect(!parts[0].contains(phrase), "\(phrase) is also named as removed")
        }
        #expect(parts[0].contains("Folders you added as sources"))
        // Setup offers itself again only where no folder profile exists, so the alert does not
        // promise it will.
        #expect(parts[0].contains("forgets that setup has run"))
        #expect(!AdvancedSettingsTab.resetAllExplanation.contains("offer itself"))
        // The full reset deletes setup's draft, a file in Application Support, so "files on disk"
        // would overclaim; the person's own files are what is untouched.
        #expect(!AdvancedSettingsTab.resetAllExplanation.contains("files on disk"))
        // Neither is in the defaults domain: One-Way Sync is saved in Application Support, and
        // macOS holds Launch at login. "Settings return to their defaults" must not take them in.
        for phrase in ["One-Way Sync", "Launch at login"] {
            #expect(parts[1].contains(phrase), "\(phrase)")
            #expect(!parts[0].contains(phrase), "\(phrase) is also named as reset")
        }
    }

    /// Settings' own Reset All names what it would raise for Claude, as the card's question does.
    @MainActor
    @Test func settingsResetAllNamesWhatItWouldRaise() throws {
        let question = AdvancedSettingsTab.resetAllQuestion(raising: ["Model back to Sonnet"])
        #expect(question == AdvancedSettingsTab.resetAllExplanation + "\n\nThis also raises what Claude may do: Model back to Sonnet.")
        #expect(AdvancedSettingsTab.resetAllQuestion(raising: []) == AdvancedSettingsTab.resetAllExplanation)
        let text = SettingsAsksBeforeRemovingTests.withoutComments(try settingsSource("SettingsView.swift"))
        #expect(text.contains("alert.informativeText = Self.resetAllQuestion(raising: resetAllRaises())"),
                "Settings' Reset All alert doesn't name what it raises")
        #expect(text.contains(".resetAllRaises()\n"), "Settings never hands Advanced what Reset All raises")
    }
}
