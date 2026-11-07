import Testing
import Foundation
@testable import Settings

/// SettingsManager persistence: setPath's empty-string clear. Asserted directly against
/// UserDefaults (setPath writes synchronously before its background rediscovery Task), in an
/// injected suite, so nothing touches .standard or races other tests.
@Suite struct SettingsPersistenceTests {

    @MainActor
    @Test func testSetPathEmptyClearsTheOverride() {
        let test = TestDefaults()
        // The root override. `path_override_` is the legacy Location key, which this build reads
        // once at migration and never writes; the maintenance lines still read it as theirs.
        let key = "root_override_Dropbox"

        let settings = SettingsManager(autoDiscover: false, userDefaults: test.defaults, cloudStorageLister: { .read([]) })

        settings.setPath("/tmp/custom-root", for: "Dropbox")
        #expect(test.defaults.string(forKey: key) == "/tmp/custom-root")

        // Empty string must clear the override (removeObject), not persist "".
        settings.setPath("", for: "Dropbox")
        #expect(test.defaults.string(forKey: key) == nil)
    }

    // The ignoreGoogleDriveNewerDateOnly relaunch is covered by
    // SettingsDiscoveryTests.testIgnoreGoogleDriveFlagRoundTripsThroughInjectedDefaults.
}

/// The stored-tab resolution. The launch read is in `MacApp/ContentView.swift`, outside every SPM
/// package, so ContentView calls `SettingsPlace.resolvingStored` rather than spelling the fallback
/// itself, and the fallback is tested here.
@Suite struct StoredTabResolutionTests {

    /// Every case survives a round trip. Without this, `resolvingStored` could return Appearance
    /// unconditionally and the fallback test below would still pass.
    @Test func everyTabRoundTripsThroughItsStoredValue() {
        for tab in SettingsView.SettingsTab.allCases {
            #expect(SettingsPlace.resolvingStored(tab.rawValue) == SettingsPlace(tab),
                    "\(tab.rawValue) does not survive a round trip through its own raw value")
        }
    }

    /// The tabs TE332 folded into others leave their raw values in `settingsSelectedTab` on every
    /// Mac that last showed them. Each opens the page that took it in, not the fallback.
    @Test func aFoldedTabOpensItsNewHome() {
        #expect(SettingsPlace.resolvingStored("readability") == SettingsPlace(.textAndSpacing))
        #expect(SettingsPlace.resolvingStored("people") == SettingsPlace(.people))
        #expect(SettingsPlace.resolvingStored("duplicates") == SettingsPlace(.duplicates))
        // Renamed, not folded: the raw values stayed, so they resolve as tabs.
        #expect(SettingsPlace.resolvingStored("sync") == SettingsPlace(.sync))
        #expect(SettingsPlace.resolvingStored("intelligence") == SettingsPlace(.intelligence))
    }

    /// Nothing stored, nothing readable, and a value no build ever wrote all land on the same tab.
    /// The third matters most: a retired tab leaves its raw value in `settingsSelectedTab` on
    /// every Mac that used it, and the app reads it on launch, a path nobody runs before shipping.
    @Test func theStoredTabFallsBackWhenUnrecognised() {
        let appearance = SettingsPlace(.appearance)
        #expect(SettingsPlace.resolvingStored(nil) == appearance)
        #expect(SettingsPlace.resolvingStored("") == appearance)
        #expect(SettingsPlace.resolvingStored("a-tab-that-was-retired") == appearance)
        // A page's raw value is not a tab's: `settingsSelectedTab` never held one.
        #expect(SettingsPlace.resolvingStored("ignored") == appearance)
        // Case matters: raw values are exact, and a near miss must not resolve.
        #expect(SettingsPlace.resolvingStored("General") == appearance,
                "resolution is case-insensitive, so a near-miss silently lands on a real tab")
        #expect(SettingsPlace.resolvingStored("Readability") == appearance)
    }
}

/// The page each paged tab opens on — see `SettingsSubTabMemory`.
@Suite struct SubTabMemoryTests {

    @Test func aTabOpensOnItsFirstPageUntilAnotherIsShown() {
        #expect(SettingsSubTabMemory.page(for: .sync, in: "") == .differences)
        #expect(SettingsSubTabMemory.page(for: .general, in: "") == nil)
        let stored = SettingsSubTabMemory.remembering(.ignored, in: "")
        #expect(SettingsSubTabMemory.page(for: .sync, in: stored) == .ignored)
        // One tab's page leaves the others alone.
        let both = SettingsSubTabMemory.remembering(.pdf, in: stored)
        #expect(SettingsSubTabMemory.page(for: .sync, in: both) == .ignored)
        #expect(SettingsSubTabMemory.page(for: .edit, in: both) == .pdf)
        #expect(SettingsSubTabMemory.page(for: .filing, in: both) == .toFile)
    }

    /// The value outlives builds and `defaults write` can set it, so a pair this build can't read,
    /// or one naming another tab's page, is skipped rather than trapped on or obeyed.
    @Test func anUnreadablePairIsSkipped() {
        let stored = "sync=pdf;edit=nonsense;garbage;providers=localFolders;=;intelligence="
        #expect(SettingsSubTabMemory.page(for: .sync, in: stored) == .differences)
        #expect(SettingsSubTabMemory.page(for: .edit, in: stored) == .text)
        #expect(SettingsSubTabMemory.page(for: .providers, in: stored) == .localFolders)
    }

    @Test func rememberWritesThePlacesPageAndNothingForATab() {
        let suite = "SubTabMemoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        SettingsSubTabMemory.remember(SettingsPlace(.general), in: defaults)
        #expect(defaults.string(forKey: SettingsSubTabMemory.defaultsKey) == nil)
        SettingsSubTabMemory.remember(SettingsPlace(.oneWaySync), in: defaults)
        SettingsSubTabMemory.remember(SettingsPlace(.nameChecks), in: defaults)
        let stored = defaults.string(forKey: SettingsSubTabMemory.defaultsKey) ?? ""
        #expect(SettingsSubTabMemory.page(for: .sync, in: stored) == .oneWaySync)
        #expect(SettingsSubTabMemory.page(for: .providers, in: stored) == .nameChecks)
    }

    /// Every page belongs to the tab that lists it, and every paged tab has at least two pages.
    @Test func everyPageIsOnItsTabsStrip() {
        for page in SettingsSubTab.allCases {
            #expect(page.tab.subTabs.contains(page))
        }
        for tab in SettingsView.SettingsTab.allCases where !tab.subTabs.isEmpty {
            #expect(tab.subTabs.count >= 2, "\(tab.displayName) has a strip of one")
        }
    }
}
