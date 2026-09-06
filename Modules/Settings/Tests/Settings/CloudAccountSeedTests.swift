import Testing
import Foundation
@testable import Settings

/// **The seed offers the cloud accounts the last discovery found, so a restored pane can find its
/// source before discovery has run.**
///
/// `SettingsManager.init` seeds `availableProviders` synchronously so the app can start before the
/// first off-main discovery publishes. It seeded `cloudStorageFolders: []` — iCloud and the
/// persisted folder sources, and no cloud account at all — so a pane restored onto Google Drive,
/// Dropbox or OneDrive named a provider `enabledProviders` did not contain, and its launch refresh
/// was skipped with a warning on EVERY launch.
///
/// That was not a race discovery sometimes won: the empty list is in the constructor, so the miss
/// was guaranteed for anyone whose pane is pinned to a cloud account. iCloud never tripped it
/// because iCloud is a constant the seed always adds.
@Suite struct CloudAccountSeedTests {

    private let key = "lastKnownAccountFolders"

    @MainActor
    @Test func aRestoredPaneFindsItsCloudAccountBeforeDiscoveryRuns() async {
        let test = TestDefaults(); defer { test.wipe() }
        // A previous session's discovery, as it would have left the record.
        test.defaults.set(["/CloudStorage/GoogleDrive-someone@example.com",
                           "/CloudStorage/Dropbox"], forKey: key)

        // No discovery has run — the lister would answer, but nothing has called it.
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([]) },
            pathValidator: { _ in true })

        let seeded = settings.availableProviders.map(\.id)
        #expect(seeded.contains("GoogleDrive-someone@example.com"),
                "the seed offered no Google Drive account, so a pane restored onto one skips its launch refresh: \(seeded)")
        #expect(seeded.contains("Dropbox"), "the seed offered no Dropbox: \(seeded)")
        #expect(seeded.contains("iCloud"), "the always-present entry went missing")
    }

    @MainActor
    @Test func withNoRecordTheSeedIsUnchanged() {
        let test = TestDefaults(); defer { test.wipe() }
        // A first launch after install: nothing recorded, so nothing invented.
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([]) },
            pathValidator: { _ in true })

        let seeded = settings.availableProviders.map(\.id)
        #expect(seeded.contains("iCloud"), "iCloud is always available and must still be seeded")
        #expect(!seeded.contains(where: { $0.hasPrefix("GoogleDrive-") || $0 == "Dropbox" }),
                "the seed invented a cloud account nothing had ever discovered: \(seeded)")
    }

    /// The record is what makes the seed possible, so discovery has to write it — and write it on
    /// every readable pass, not only when the set changes: what has to survive the quit is "what
    /// did we last actually see", which a change-guard would skip for an unchanged pass.
    @MainActor
    @Test func aReadableDiscoveryRecordsWhatItSaw() async {
        let test = TestDefaults(); defer { test.wipe() }
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([URL(fileURLWithPath: "/CloudStorage/Dropbox")]) },
            pathValidator: { _ in true })

        await settings.discoverProviders()
        #expect(test.defaults.stringArray(forKey: key) == ["/CloudStorage/Dropbox"],
                "discovery did not record the accounts it found, so the next launch seeds nothing")

        // A second, identical pass must still leave the record intact.
        await settings.discoverProviders()
        #expect(test.defaults.stringArray(forKey: key) == ["/CloudStorage/Dropbox"])
    }

    /// **An unreadable root must not erase the record**, for the same reason it must not shrink the
    /// published list: it is not evidence the accounts are gone. Before this was persisted the
    /// fallback could not work on the first pass after launch at all, because the in-memory value
    /// started empty every time.
    @MainActor
    @Test func anUnreadableRootLeavesTheRecordAlone() async {
        let test = TestDefaults(); defer { test.wipe() }
        test.defaults.set(["/CloudStorage/Dropbox"], forKey: key)

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .unreadableRoot },
            pathValidator: { _ in true })

        await settings.discoverProviders()
        #expect(test.defaults.stringArray(forKey: key) == ["/CloudStorage/Dropbox"],
                "an unreadable root erased the record of accounts it never looked at")
        #expect(settings.availableProviders.map(\.id).contains("Dropbox"),
                "and the account itself went missing from the published list")
    }
}
