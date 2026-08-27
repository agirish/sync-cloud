import Testing
import Foundation
@testable import Settings
import Sync

/// Pins that provider path/name overrides are read from the app's own defaults domain only.
/// `dictionaryRepresentation()` merges the whole search list (NSGlobalDomain included), so a
/// stray key elsewhere in the list that happens to start with `path_override_` /
/// `name_override_` must not be honored when the owning domain's name is passed in.
@Suite struct OverrideDomainScopingTests {

    @MainActor
    @Test func testSearchListOnlyOverrideKeysAreNotHonored() async throws {
        let test = TestDefaults()
        defer { test.wipe() }

        // A real override, persisted to the suite's own domain.
        test.defaults.set("/real/override", forKey: "root_override_OneDrive-Work")
        // Keys visible only via the merged search list — a second suite added with
        // addSuite(named:) stands in for NSGlobalDomain: its keys appear in this instance's
        // dictionaryRepresentation() but not in the suite's own persistentDomain. (Per-instance,
        // unlike register(defaults:), whose registration domain is process-global and would
        // leak into the other, parallel-running Settings tests.)
        let globalStandIn = TestDefaults()
        defer { globalStandIn.wipe() }
        globalStandIn.defaults.set("/global/evil", forKey: "root_override_Dropbox")
        globalStandIn.defaults.set("Evil Name", forKey: "name_override_Dropbox")
        test.defaults.addSuite(named: globalStandIn.suiteName)

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            overridesDomainName: test.suiteName,
            cloudStorageLister: { .read([
                URL(fileURLWithPath: "/CloudStorage/OneDrive-Work"),
                URL(fileURLWithPath: "/CloudStorage/Dropbox"),
            ]) },
            pathValidator: { _ in true }
        )
        await settings.discoverProviders()

        let byId = Dictionary(uniqueKeysWithValues: settings.availableProviders.map { ($0.id, $0) })
        // The domain-persisted override applies…
        #expect(byId["OneDrive-Work"]?.rootPath == "/real/override")
        // …the search-list-only keys do not (Dropbox keeps its discovered default path).
        #expect(byId["Dropbox"]?.rootPath == "/CloudStorage/Dropbox")
        #expect(byId["Dropbox"]?.displayName == "Dropbox")

        // **And the two "is this customized?" predicates agree with what actually applied.** They
        // read the same keys for a different purpose — whether the row shows a Reset, and what the
        // reset logs — and they used to read them through `userDefaults.string(forKey:)`, i.e. the
        // merged search list. So the stray key above answered TRUE here while `mapProviders`
        // correctly ignored it: Dropbox's row offered to reset a root it did not have, and taking
        // the offer logged a reset of a key that was never this install's. Two readers of one key
        // with two scoping rules, which is the exact defect the scoped read exists to prevent.
        #expect(settings.hasRootOverride(for: "OneDrive-Work"))
        #expect(!settings.hasRootOverride(for: "Dropbox"))
    }

    /// The same scoping, for the landing folder — whose key is the one where `""` is a real stored
    /// value, so "is there a key" is the only question that can be asked about it.
    @MainActor
    @Test func testSearchListOnlyOpenAtKeysDoNotLookLikeAChoice() async throws {
        let test = TestDefaults()
        defer { test.wipe() }
        test.defaults.set("Work", forKey: "openAt_override_OneDrive-Work")

        let globalStandIn = TestDefaults()
        defer { globalStandIn.wipe() }
        globalStandIn.defaults.set("Evil", forKey: "openAt_override_Dropbox")
        test.defaults.addSuite(named: globalStandIn.suiteName)

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            overridesDomainName: test.suiteName,
            cloudStorageLister: { .read([
                URL(fileURLWithPath: "/CloudStorage/OneDrive-Work"),
                URL(fileURLWithPath: "/CloudStorage/Dropbox"),
            ]) },
            pathValidator: { _ in true }
        )
        await settings.discoverProviders()

        let byId = Dictionary(uniqueKeysWithValues: settings.availableProviders.map { ($0.id, $0) })
        #expect(byId["OneDrive-Work"]?.openAt == "Work")
        #expect(byId["Dropbox"]?.openAt == "Documents", "a search-list key repointed a source's landing folder")
        #expect(settings.hasOpenAtOverride(for: "OneDrive-Work"))
        #expect(!settings.hasOpenAtOverride(for: "Dropbox"),
                "Dropbox's row claims a landing folder the user chose, from a key this install does not own")
    }

    /// Fresh-install hole: a suite nothing was ever persisted to has NO persistent domain
    /// (`persistentDomain(forName:)` returns nil). That must read as "no overrides" — not fall
    /// back to the merged search list, which would honor a stray NSGlobalDomain key precisely
    /// when the app owns no keys of its own.
    @MainActor
    @Test func testEmptyOwnDomainMeansNoOverridesNotSearchListFallback() async throws {
        // Nothing is ever written to the suite's own domain in this test.
        let test = TestDefaults()
        defer { test.wipe() }

        let globalStandIn = TestDefaults()
        defer { globalStandIn.wipe() }
        globalStandIn.defaults.set("/global/evil", forKey: "root_override_Dropbox")
        globalStandIn.defaults.set("Evil Name", forKey: "name_override_Dropbox")
        test.defaults.addSuite(named: globalStandIn.suiteName)

        // Precondition of the hole being tested: the suite really has no persistent domain yet.
        #expect(test.defaults.persistentDomain(forName: test.suiteName) == nil)

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            overridesDomainName: test.suiteName,
            cloudStorageLister: { .read([URL(fileURLWithPath: "/CloudStorage/Dropbox")]) },
            pathValidator: { _ in true }
        )
        await settings.discoverProviders()

        let dropbox = settings.availableProviders.first { $0.id == "Dropbox" }
        #expect(dropbox?.rootPath == "/CloudStorage/Dropbox")
        #expect(dropbox?.displayName == "Dropbox")
    }

    /// Without a domain name (bare injected suite), the merged-list fallback keeps overrides
    /// working — the pre-existing injectability contract for callers that can't name a domain.
    @MainActor
    @Test func testNilDomainNameFallsBackToMergedList() async throws {
        let test = TestDefaults()
        defer { test.wipe() }
        test.defaults.set("/suite/override", forKey: "root_override_Dropbox")

        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([URL(fileURLWithPath: "/CloudStorage/Dropbox")]) },
            pathValidator: { _ in true }
        )
        await settings.discoverProviders()

        #expect(settings.availableProviders.first { $0.id == "Dropbox" }?.rootPath == "/suite/override")
    }
}
