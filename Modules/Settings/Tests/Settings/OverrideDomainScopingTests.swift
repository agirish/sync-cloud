import Testing
import Foundation
@testable import Settings
import Sync

/// Pins that provider root, landing-folder and name overrides are read from the app's own defaults
/// domain only. `dictionaryRepresentation()` merges the whole search list (NSGlobalDomain
/// included), so a stray `root_override_` or `name_override_` key elsewhere in it must not be
/// honored when the owning domain's name is passed in.
@Suite struct OverrideDomainScopingTests {

    @MainActor
    @Test func testSearchListOnlyOverrideKeysAreNotHonored() async throws {
        let test = TestDefaults()

        // A real override, persisted to the suite's own domain.
        test.defaults.set("/real/override", forKey: "root_override_OneDrive-Work")
        // A second suite added with addSuite(named:) stands in for NSGlobalDomain: its keys appear
        // in dictionaryRepresentation() but not in the suite's own persistentDomain. Not
        // register(defaults:), whose domain is process-global and would leak into parallel tests.
        let globalStandIn = TestDefaults()
        globalStandIn.defaults.set("/global/evil", forKey: "root_override_Dropbox")
        globalStandIn.defaults.set("Evil Name", forKey: "name_override_Dropbox")
        test.defaults.addSuite(named: globalStandIn.suiteName)

        let settings = test.manager(
            lister: { .read([
                URL(fileURLWithPath: "/CloudStorage/OneDrive-Work"),
                URL(fileURLWithPath: "/CloudStorage/Dropbox"),
            ]) },
            validator: { _ in true },
            domain: test.suiteName)
        await settings.discoverProviders()

        let byId = Dictionary(uniqueKeysWithValues: settings.availableProviders.map { ($0.id, $0) })
        // The domain-persisted override applies…
        #expect(byId["OneDrive-Work"]?.rootPath == "/real/override")
        // …the search-list-only keys do not (Dropbox keeps its discovered default path).
        #expect(byId["Dropbox"]?.rootPath == "/CloudStorage/Dropbox")
        #expect(byId["Dropbox"]?.displayName == "Dropbox")

        // The "is this customized?" predicates must agree with what applied. They decide whether
        // the row offers Reset; read through the merged list, the stray key would offer to reset a
        // root Dropbox doesn't have.
        #expect(settings.hasRootOverride(for: "OneDrive-Work"))
        #expect(!settings.hasRootOverride(for: "Dropbox"))
    }

    /// The same scoping for the landing folder, where `""` is a real stored value, so "is there a
    /// key" is the only question that can be asked.
    @MainActor
    @Test func testSearchListOnlyOpenAtKeysDoNotLookLikeAChoice() async throws {
        let test = TestDefaults()
        test.defaults.set("Work", forKey: "openAt_override_OneDrive-Work")

        let globalStandIn = TestDefaults()
        globalStandIn.defaults.set("Evil", forKey: "openAt_override_Dropbox")
        test.defaults.addSuite(named: globalStandIn.suiteName)

        let settings = test.manager(
            lister: { .read([
                URL(fileURLWithPath: "/CloudStorage/OneDrive-Work"),
                URL(fileURLWithPath: "/CloudStorage/Dropbox"),
            ]) },
            validator: { _ in true },
            domain: test.suiteName)
        await settings.discoverProviders()

        let byId = Dictionary(uniqueKeysWithValues: settings.availableProviders.map { ($0.id, $0) })
        #expect(byId["OneDrive-Work"]?.openAt == "Work")
        #expect(byId["Dropbox"]?.openAt == "Documents", "a search-list key repointed a source's landing folder")
        #expect(settings.hasOpenAtOverride(for: "OneDrive-Work"))
        #expect(!settings.hasOpenAtOverride(for: "Dropbox"),
                "Dropbox's row claims a landing folder the user chose, from a key this install does not own")
    }

    /// On a fresh install the suite has no persistent domain (`persistentDomain(forName:)` is nil).
    /// That must read as "no overrides", not fall back to the merged list, which would honor a
    /// stray NSGlobalDomain key exactly when the app owns no keys.
    @MainActor
    @Test func testEmptyOwnDomainMeansNoOverridesNotSearchListFallback() async throws {
        // Nothing is ever written to the suite's own domain in this test.
        let test = TestDefaults()

        let globalStandIn = TestDefaults()
        globalStandIn.defaults.set("/global/evil", forKey: "root_override_Dropbox")
        globalStandIn.defaults.set("Evil Name", forKey: "name_override_Dropbox")
        test.defaults.addSuite(named: globalStandIn.suiteName)

        // Precondition: the suite really has no persistent domain yet.
        #expect(test.defaults.persistentDomain(forName: test.suiteName) == nil)

        let settings = test.manager(
            lister: { .read([URL(fileURLWithPath: "/CloudStorage/Dropbox")]) },
            validator: { _ in true },
            domain: test.suiteName)
        await settings.discoverProviders()

        let dropbox = settings.availableProviders.first { $0.id == "Dropbox" }
        #expect(dropbox?.rootPath == "/CloudStorage/Dropbox")
        #expect(dropbox?.displayName == "Dropbox")
    }

    /// Without a domain name (a bare injected suite), overrides are read from the merged list, for
    /// callers that can't name a domain.
    @MainActor
    @Test func testNilDomainNameFallsBackToMergedList() async throws {
        let test = TestDefaults()
        test.defaults.set("/suite/override", forKey: "root_override_Dropbox")

        let settings = test.manager(
            lister: { .read([URL(fileURLWithPath: "/CloudStorage/Dropbox")]) },
            validator: { _ in true })
        await settings.discoverProviders()

        #expect(settings.availableProviders.first { $0.id == "Dropbox" }?.rootPath == "/suite/override")
    }
}
