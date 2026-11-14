import Testing
import Foundation
@testable import Settings

/// The seed offers the cloud accounts the last discovery found, so a restored pane can find its
/// source before discovery has run. `SettingsManager.init` seeds `availableProviders`
/// synchronously; without the record, a pane restored onto Google Drive, Dropbox or OneDrive would
/// skip its launch refresh on every launch. iCloud is always seeded, so it can't show the problem.
@Suite struct CloudAccountSeedTests {

    private let key = "lastKnownAccountFolders"

    @MainActor
    @Test func aRestoredPaneFindsItsCloudAccountBeforeDiscoveryRuns() async {
        let test = TestDefaults()
        // A previous session's discovery, as it would have left the record.
        test.defaults.set(["/CloudStorage/GoogleDrive-someone@example.com",
                           "/CloudStorage/Dropbox"], forKey: key)

        // No discovery has run — the lister would answer, but nothing has called it.
        let settings = test.manager(validator: { _ in true })

        let seeded = settings.availableProviders.map(\.id)
        #expect(seeded.contains("GoogleDrive-someone@example.com"),
                "the seed offered no Google Drive account, so a pane restored onto one skips its launch refresh: \(seeded)")
        #expect(seeded.contains("Dropbox"), "the seed offered no Dropbox: \(seeded)")
        #expect(seeded.contains("iCloud"), "the always-present entry went missing")
    }

    @MainActor
    @Test func withNoRecordTheSeedIsUnchanged() {
        let test = TestDefaults()
        // A first launch after install: nothing recorded, so nothing invented.
        let settings = test.manager(validator: { _ in true })

        let seeded = settings.availableProviders.map(\.id)
        #expect(seeded.contains("iCloud"), "iCloud is always available and must still be seeded")
        #expect(!seeded.contains(where: { $0.hasPrefix("GoogleDrive-") || $0 == "Dropbox" }),
                "the seed invented a cloud account nothing had ever discovered: \(seeded)")
    }

    /// Discovery writes the record the seed reads, on every readable pass, not only when the set
    /// changes: what must survive the quit is what was last seen.
    @MainActor
    @Test func aReadableDiscoveryRecordsWhatItSaw() async {
        let test = TestDefaults()
        let settings = test.manager(
            lister: { .read([URL(fileURLWithPath: "/CloudStorage/Dropbox")]) },
            validator: { _ in true })

        await settings.discoverProviders()
        #expect(test.defaults.stringArray(forKey: key) == ["/CloudStorage/Dropbox"],
                "discovery did not record the accounts it found, so the next launch seeds nothing")

        // A second, identical pass must still leave the record intact.
        await settings.discoverProviders()
        #expect(test.defaults.stringArray(forKey: key) == ["/CloudStorage/Dropbox"])
    }

    /// An unreadable root must not erase the record, nor shrink the published list: it is no
    /// evidence the accounts are gone. The record being persisted is what lets the fallback work on
    /// the first pass after launch.
    @MainActor
    @Test func anUnreadableRootLeavesTheRecordAlone() async {
        let test = TestDefaults()
        test.defaults.set(["/CloudStorage/Dropbox"], forKey: key)

        let settings = test.manager(lister: { .unreadableRoot }, validator: { _ in true })

        await settings.discoverProviders()
        #expect(test.defaults.stringArray(forKey: key) == ["/CloudStorage/Dropbox"],
                "an unreadable root erased the record of accounts it never looked at")
        #expect(settings.availableProviders.map(\.id).contains("Dropbox"),
                "and the account itself went missing from the published list")
    }
}
