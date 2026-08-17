import Testing
import Foundation
@testable import Settings
import Sync

/// Mutable set of paths the injected validator reports as valid — simulates provider
/// folders appearing and disappearing on disk between discovery passes.
private final class ValidPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String>

    init(_ paths: Set<String>) {
        self.paths = paths
    }

    func insert(_ path: String) {
        lock.lock()
        paths.insert(path)
        lock.unlock()
    }

    func remove(_ path: String) {
        lock.lock()
        paths.remove(path)
        lock.unlock()
    }

    func contains(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains(path)
    }
}

private let root = URL(fileURLWithPath: "/Users/test/Library/CloudStorage")
private func folder(_ name: String) -> URL { root.appendingPathComponent(name) }
private let dropboxDocs = "/Users/test/Library/CloudStorage/Dropbox/Documents"

@MainActor
private func makeSettings(_ test: TestDefaults, validPaths: ValidPaths) -> SettingsManager {
    SettingsManager(
        autoDiscover: false,
        userDefaults: test.defaults,
        cloudStorageLister: { .read([folder("Dropbox")]) },
        pathValidator: { validPaths.contains($0) })
}

// MARK: - pathValidity: what the badge shows and when it is re-checked

@Suite struct SettingsPathValidityTests {

    /// The stale-badge regression pin (19763de) at the validity level: the provider's folder is
    /// deleted externally between discoveries, so "Refresh providers" changes neither the card's
    /// identity nor its path string — the badge must still flip to invalid.
    @MainActor
    @Test func testFolderDeletedExternallyFlipsInvalidOnRefreshDespiteUnchangedPath() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let validPaths = ValidPaths([dropboxDocs])
        let settings = makeSettings(test, validPaths: validPaths)

        await settings.discoverProviders()
        let pathBefore = settings.path(for: "Dropbox")
        #expect(settings.isPathValid(for: "Dropbox") == true)

        validPaths.remove(dropboxDocs) // folder vanishes on disk; path string is untouched
        await settings.discoverProviders() // the user's "Refresh providers" gesture
        #expect(settings.path(for: "Dropbox") == pathBefore)
        #expect(settings.isPathValid(for: "Dropbox") == false)
    }

    /// The reverse: a missing folder is created externally, and refresh picks it up.
    @MainActor
    @Test func testFolderCreatedExternallyFlipsValidOnRefresh() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let validPaths = ValidPaths([])
        let settings = makeSettings(test, validPaths: validPaths)

        await settings.discoverProviders()
        #expect(settings.isPathValid(for: "Dropbox") == false)

        validPaths.insert(dropboxDocs)
        await settings.discoverProviders()
        #expect(settings.isPathValid(for: "Dropbox") == true)
    }

    /// Overriding a path revalidates against the new target, and resetting revalidates
    /// against the restored default — the badge never keeps the old path's verdict.
    @MainActor
    @Test func testPathOverrideAndResetRevalidateAgainstTheActivePath() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let external = "/Volumes/External/Dropbox"
        let validPaths = ValidPaths([external]) // default Documents folder does not exist
        let settings = makeSettings(test, validPaths: validPaths)

        await settings.discoverProviders()
        #expect(settings.isPathValid(for: "Dropbox") == false)

        settings.setPath(external, for: "Dropbox")
        await settings.discoverProviders()
        #expect(settings.path(for: "Dropbox") == external)
        #expect(settings.isPathValid(for: "Dropbox") == true)

        settings.resetPath(for: "Dropbox")
        await settings.discoverProviders()
        #expect(settings.path(for: "Dropbox") == dropboxDocs)
        #expect(settings.isPathValid(for: "Dropbox") == false)
    }

    /// A valid, unchanged path must stay valid across refreshes — no false flips.
    @MainActor
    @Test func testValidUnchangedPathStaysValidAcrossRefreshes() async {
        let test = TestDefaults()
        defer { test.wipe() }
        let settings = makeSettings(test, validPaths: ValidPaths([dropboxDocs]))

        await settings.discoverProviders()
        #expect(settings.isPathValid(for: "Dropbox") == true)

        await settings.discoverProviders()
        await settings.discoverProviders()
        #expect(settings.isPathValid(for: "Dropbox") == true)
    }

    /// The badge is meaningful before the first discovery completes: init validates the
    /// default iCloud provider it seeds `availableProviders` with (the launch-time state
    /// the card previously computed in `onAppear`).
    @MainActor
    @Test func testInitialProvidersAreValidatedBeforeFirstDiscovery() {
        let test = TestDefaults()
        defer { test.wipe() }
        let iCloudDefaultPath = SettingsManager.iCloudDefaultPath
        let settings = SettingsManager(
            autoDiscover: false,
            userDefaults: test.defaults,
            cloudStorageLister: { .read([]) },
            pathValidator: { $0 == iCloudDefaultPath })

        #expect(settings.isPathValid(for: "iCloud") == true)
        #expect(settings.isPathValid(for: "NonExistent") == false)
    }
}
