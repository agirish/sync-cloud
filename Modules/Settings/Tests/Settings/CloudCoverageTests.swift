import Testing
import Foundation
@testable import Settings
import Sync

/// `SettingsManager.cloudCoverage` — the **call site** of the rule that a disabled provider still
/// counts as coverage.
///
/// `FileLocationTests` proves `FileLocation.coverage` honours the rule when it is handed the full
/// provider list. That says nothing about which list this property actually hands it, and the call
/// site is where the rule is easiest to lose: `enabledProviders` sits right next to
/// `availableProviders`, reads like the obviously-correct one, and swapping them compiles, passes
/// every existing test, and silently reports every file in a switched-off provider as having only
/// one copy. A helper proved correct against a list nobody passes it proves nothing.
@MainActor
@Suite struct CloudCoverageTests {

    private struct Defaults {
        let name = "CloudCoverage-\(UUID().uuidString)"
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        func wipe() { UserDefaults.standard.removePersistentDomain(forName: name) }
    }

    private func settings(_ defaults: UserDefaults) async -> SettingsManager {
        // Built inside the closure: a `@MainActor` static cannot be captured by a Sendable one.
        let manager = SettingsManager(
            autoDiscover: false,
            userDefaults: defaults,
            cloudStorageLister: {
                [URL(fileURLWithPath: "/Users/test/Library/CloudStorage/Dropbox")]
            })
        await manager.discoverProviders()
        return manager
    }

    /// The discovered providers are covered, and their paths are the ones the classifier sees.
    @Test func discoveredProvidersAreCovered() async {
        let test = Defaults(); defer { test.wipe() }
        let manager = await settings(test.defaults)
        let coverage = manager.cloudCoverage
        #expect(coverage.roots.map(\.providerId).sorted() == ["Dropbox", "iCloud"])
        #expect(FileLocation.outsideEveryCloudFolder(
            path: "/Users/test/Library/CloudStorage/Dropbox/Documents/a.txt",
            in: coverage) == false)
    }

    /// **The rule.** Switching a provider off in Settings does not move its folder off the disk, so
    /// a file inside it still has a second copy. Mutation seam: change `cloudCoverage` to read
    /// `enabledProviders` and this fails.
    @Test func aDisabledProvidersFolderIsStillCoverage() async {
        let test = Defaults(); defer { test.wipe() }
        let manager = await settings(test.defaults)
        let file = "/Users/test/Library/CloudStorage/Dropbox/Documents/a.txt"
        #expect(FileLocation.outsideEveryCloudFolder(path: file, in: manager.cloudCoverage) == false)

        manager.setEnabled(false, for: "Dropbox")
        #expect(manager.enabledProviders.map(\.id).contains("Dropbox") == false,
                "the fixture did not actually disable anything")
        #expect(FileLocation.outsideEveryCloudFolder(path: file, in: manager.cloudCoverage) == false,
                "a switched-off provider stopped counting as coverage — every file inside it now reports as having only one copy")
    }

    /// A folder source the user added is never coverage, through this property as through the
    /// classifier — it is the thing being asked about, not a cloud.
    @Test func aFolderSourceIsNotCoverageHereEither() async {
        let test = Defaults(); defer { test.wipe() }
        let manager = await settings(test.defaults)
        _ = manager.addFolderSource(path: "/Users/test/Projects")
        // `addFolderSource` records it; `availableProviders` is rebuilt by a discovery pass.
        await manager.discoverProviders()
        #expect(manager.availableProviders.contains { $0.isLocalFolder },
                "the fixture did not actually add a folder source — the assertions below would hold trivially")
        #expect(manager.cloudCoverage.roots.contains { $0.providerId.contains("Projects") } == false)
        #expect(FileLocation.outsideEveryCloudFolder(path: "/Users/test/Projects/notes.md",
                                                     in: manager.cloudCoverage))
    }
}
