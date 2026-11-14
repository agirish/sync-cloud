import Testing
import Foundation
import Events
import EventsTestSupport
@testable import Sync

/// Pins the durable ignore store: per-pair persistence round-trips, order-independent pair
/// keys, and the idempotent activate that protects unsaved edits from provider-id churn.
@Suite struct IgnoredItemsStoreTests {

    @Test func testPairKeyIsOrderIndependent() {
        #expect(IgnoredItemsStore.pairKey("iCloud", "Dropbox") == IgnoredItemsStore.pairKey("Dropbox", "iCloud"))
        #expect(IgnoredItemsStore.pairKey("a", "b") != IgnoredItemsStore.pairKey("a", "c"))
    }

    @MainActor
    @Test func testAddRemovePersistAcrossInstances() {
        let defaults = ScratchDefaults("IgnoredItemsStoreTests")
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
        let defaults = ScratchDefaults("IgnoredItemsStoreTests")

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
        let defaults = ScratchDefaults("IgnoredItemsStoreTests")
        let key = IgnoredItemsStore.pairKey("a", "b")

        let store = IgnoredItemsStore(userDefaults: defaults)
        store.activate(pairKey: key)
        store.add(["kept"])
        // Re-activating the active key (launch churn, pane swap) must not reload from disk
        // over the in-memory set.
        store.activate(pairKey: key)
        #expect(store.rootRelativePaths == ["kept"])
    }

    /// An `add()` before any `activate()` updates the published set, so the UI shows the ignore,
    /// but `save()` has no active key and drops the write: the ignore is gone after a relaunch.
    /// Nothing else can report that, so the warning log line is the only signal.
    @MainActor
    @Test func testAddBeforeActivateIsSessionOnlyAndSaysSo() async {
        let log = LogCapture()
        let defaults = ScratchDefaults("IgnoredItemsStoreTests")

        let store = IgnoredItemsStore(userDefaults: defaults)   // deliberately NOT activated
        store.add(["Docs/orphan.txt"])

        // The UI-visible state claims the ignore took…
        #expect(store.rootRelativePaths == ["Docs/orphan.txt"])
        // …but nothing was written under any pair key.
        #expect(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("ignoredItems_v1_") } == false)
        #expect(await log.holds(.error, containing: "no provider pair is active yet"),
                "the dropped save was not logged")
    }

    @MainActor
    @Test func testRemoveAllClearsThePersistedKey() {
        let defaults = ScratchDefaults("IgnoredItemsStoreTests")
        let key = IgnoredItemsStore.pairKey("a", "b")

        let store = IgnoredItemsStore(userDefaults: defaults)
        store.activate(pairKey: key)
        store.add(["x", "y"])
        store.removeAll()
        #expect(store.rootRelativePaths.isEmpty)
        #expect(defaults.stringArray(forKey: key) == nil)
    }
}
