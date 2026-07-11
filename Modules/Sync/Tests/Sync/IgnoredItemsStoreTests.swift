import Testing
import Foundation
@testable import Sync

/// Pins the durable ignore store: per-pair persistence round-trips, order-independent pair
/// keys, and the idempotent activate that protects unsaved edits from provider-id churn.
@Suite struct IgnoredItemsStoreTests {

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "IgnoredItemsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    @Test func testPairKeyIsOrderIndependent() {
        #expect(IgnoredItemsStore.pairKey("iCloud", "Dropbox") == IgnoredItemsStore.pairKey("Dropbox", "iCloud"))
        #expect(IgnoredItemsStore.pairKey("a", "b") != IgnoredItemsStore.pairKey("a", "c"))
    }

    @MainActor
    @Test func testAddRemovePersistAcrossInstances() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = IgnoredItemsStore.pairKey("iCloud", "Dropbox")

        let store = IgnoredItemsStore(userDefaults: defaults)
        store.activate(pairKey: key)
        store.add(["Docs/a.txt", "node_modules"])
        store.remove(["Docs/a.txt"])

        let reloaded = IgnoredItemsStore(userDefaults: defaults)
        reloaded.activate(pairKey: key)
        #expect(reloaded.rootRelativePaths == ["node_modules"])
    }

    @MainActor
    @Test func testStoresAreScopedPerProviderPair() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = IgnoredItemsStore(userDefaults: defaults)
        store.activate(pairKey: IgnoredItemsStore.pairKey("iCloud", "Dropbox"))
        store.add(["only-for-this-pair"])

        store.activate(pairKey: IgnoredItemsStore.pairKey("iCloud", "GoogleDrive-x"))
        #expect(store.rootRelativePaths.isEmpty)

        store.activate(pairKey: IgnoredItemsStore.pairKey("Dropbox", "iCloud"))
        #expect(store.rootRelativePaths == ["only-for-this-pair"])
    }

    @MainActor
    @Test func testActivateSameKeyIsANoOp() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = IgnoredItemsStore.pairKey("a", "b")

        let store = IgnoredItemsStore(userDefaults: defaults)
        store.activate(pairKey: key)
        store.add(["kept"])
        // Re-activating the active key (launch churn, pane swap) must not reload from disk
        // over the in-memory set.
        store.activate(pairKey: key)
        #expect(store.rootRelativePaths == ["kept"])
    }

    @MainActor
    @Test func testRemoveAllClearsThePersistedKey() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = IgnoredItemsStore.pairKey("a", "b")

        let store = IgnoredItemsStore(userDefaults: defaults)
        store.activate(pairKey: key)
        store.add(["x", "y"])
        store.removeAll()
        #expect(store.rootRelativePaths.isEmpty)
        #expect(defaults.stringArray(forKey: key) == nil)
    }
}
