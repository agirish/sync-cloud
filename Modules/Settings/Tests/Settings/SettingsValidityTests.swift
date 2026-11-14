import Testing
import Foundation
@testable import Settings
import Sync

private let root = URL(fileURLWithPath: "/Users/test/Library/CloudStorage")
private func folder(_ name: String) -> URL { root.appendingPathComponent(name) }
/// The Dropbox source's root, the account folder, which is what validity is asked about.
/// `.../Dropbox/Documents` is only where panes open inside it.
private let dropboxDocs = "/Users/test/Library/CloudStorage/Dropbox"

@MainActor
private func makeSettings(_ test: TestDefaults, validPaths: Mutable<Set<String>>) -> SettingsManager {
    test.manager(lister: { .read([folder("Dropbox")]) }, validator: { validPaths.value.contains($0) })
}

// MARK: - pathValidity: what the badge shows and when it is re-checked

@Suite struct SettingsPathValidityTests {

    /// The provider's folder is deleted externally between discoveries, so "Refresh providers"
    /// changes neither the card's identity nor its path string; the badge must still flip to
    /// invalid.
    @MainActor
    @Test func testFolderDeletedExternallyFlipsInvalidOnRefreshDespiteUnchangedPath() async {
        let test = TestDefaults()
        let validPaths = Mutable<Set<String>>([dropboxDocs])
        let settings = makeSettings(test, validPaths: validPaths)

        await settings.discoverProviders()
        let pathBefore = settings.rootPath(for: "Dropbox")
        #expect(settings.isPathValid(for: "Dropbox") == true)

        validPaths.value.remove(dropboxDocs) // folder vanishes on disk; path string is untouched
        await settings.discoverProviders() // the user's "Refresh providers" gesture
        #expect(settings.rootPath(for: "Dropbox") == pathBefore)
        #expect(settings.isPathValid(for: "Dropbox") == false)
    }

    /// The reverse: a missing folder is created externally, and refresh picks it up.
    @MainActor
    @Test func testFolderCreatedExternallyFlipsValidOnRefresh() async {
        let test = TestDefaults()
        let validPaths = Mutable<Set<String>>([])
        let settings = makeSettings(test, validPaths: validPaths)

        await settings.discoverProviders()
        #expect(settings.isPathValid(for: "Dropbox") == false)

        validPaths.value.insert(dropboxDocs)
        await settings.discoverProviders()
        #expect(settings.isPathValid(for: "Dropbox") == true)
    }

    /// Overriding a path revalidates against the new target, and resetting revalidates
    /// against the restored default — the badge never keeps the old path's verdict.
    @MainActor
    @Test func testPathOverrideAndResetRevalidateAgainstTheActivePath() async {
        let test = TestDefaults()
        let external = "/Volumes/External/Dropbox"
        let validPaths = Mutable<Set<String>>([external]) // default Documents folder does not exist
        let settings = makeSettings(test, validPaths: validPaths)

        await settings.discoverProviders()
        #expect(settings.isPathValid(for: "Dropbox") == false)

        settings.setPath(external, for: "Dropbox")
        await settings.discoverProviders()
        #expect(settings.rootPath(for: "Dropbox") == external)
        #expect(settings.isPathValid(for: "Dropbox") == true)

        settings.resetPath(for: "Dropbox")
        await settings.discoverProviders()
        #expect(settings.rootPath(for: "Dropbox") == dropboxDocs)
        #expect(settings.isPathValid(for: "Dropbox") == false)
    }

    /// A valid, unchanged path must stay valid across refreshes — no false flips.
    @MainActor
    @Test func testValidUnchangedPathStaysValidAcrossRefreshes() async {
        let test = TestDefaults()
        let settings = makeSettings(test, validPaths: Mutable<Set<String>>([dropboxDocs]))

        await settings.discoverProviders()
        #expect(settings.isPathValid(for: "Dropbox") == true)

        await settings.discoverProviders()
        await settings.discoverProviders()
        #expect(settings.isPathValid(for: "Dropbox") == true)
    }

    /// The badge is meaningful before the first discovery completes: init validates the default
    /// iCloud provider it seeds `availableProviders` with.
    @MainActor
    @Test func testInitialProvidersAreValidatedBeforeFirstDiscovery() {
        let test = TestDefaults()
        let iCloudDefaultPath = SettingsManager.iCloudDefaultPath
        let settings = test.manager(validator: { $0 == iCloudDefaultPath })

        #expect(settings.isPathValid(for: "iCloud") == true)
        #expect(settings.isPathValid(for: "NonExistent") == false)
    }
}
