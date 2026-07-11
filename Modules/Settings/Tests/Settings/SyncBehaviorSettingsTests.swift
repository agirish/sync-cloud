import Testing
import Foundation
@testable import Settings

/// Coverage for the Sync/Advanced-tab settings added with the expanded Settings surface:
/// persistence round-trips for date tolerance, scan-time verification, remembered ignores,
/// and ignore patterns; pattern add/remove normalization; the delete-confirmation default;
/// and the full reset.
@Suite struct SyncBehaviorSettingsTests {

    @MainActor
    private func makeManager(_ test: TestDefaults) -> SettingsManager {
        SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { [] })
    }

    @MainActor
    @Test func testDefaultsMatchHistoricalBehavior() {
        let test = TestDefaults()
        defer { test.wipe() }
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
        defer { test.wipe() }

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
        defer { test.wipe() }
        #expect(GeneralSettings.shouldRestoreLastFocus(test.defaults))
        test.defaults.set(false, forKey: GeneralSettings.restoreLastFocusKey)
        #expect(!GeneralSettings.shouldRestoreLastFocus(test.defaults))
    }

    @MainActor
    @Test func testAddIgnorePatternNormalizesAndDeduplicates() {
        let test = TestDefaults()
        defer { test.wipe() }
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
        defer { test.wipe() }
        #expect(GeneralSettings.shouldConfirmBeforeDelete(test.defaults))
        test.defaults.set(false, forKey: GeneralSettings.confirmBeforeDeleteKey)
        #expect(!GeneralSettings.shouldConfirmBeforeDelete(test.defaults))
        test.defaults.set(true, forKey: GeneralSettings.confirmBeforeDeleteKey)
        #expect(GeneralSettings.shouldConfirmBeforeDelete(test.defaults))
    }

    @Test func testShouldConfirmBeforeTransferDefaultsToTrue() {
        // Default-true semantics like the delete flag: an unset key must confirm, not skip.
        let test = TestDefaults()
        defer { test.wipe() }
        #expect(GeneralSettings.shouldConfirmBeforeTransfer(test.defaults))
        test.defaults.set(false, forKey: GeneralSettings.confirmBeforeTransferKey)
        #expect(!GeneralSettings.shouldConfirmBeforeTransfer(test.defaults))
        test.defaults.set(true, forKey: GeneralSettings.confirmBeforeTransferKey)
        #expect(GeneralSettings.shouldConfirmBeforeTransfer(test.defaults))
    }

    @MainActor
    @Test func testResetAllSettingsWipesTheDomainAndRepublishesDefaults() {
        let test = TestDefaults()
        defer { test.wipe() }
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            overridesDomainName: test.suiteName,
            cloudStorageLister: { [] }
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
        #expect(test.defaults.string(forKey: "path_override_iCloud") == nil)
    }
}
