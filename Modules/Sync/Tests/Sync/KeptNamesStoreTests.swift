import Testing
import Foundation
import Combine
@testable import Sync

/// The durable "I meant that name" state the row badge needs. The badge shows whenever the file is
/// on screen, so without a record of the choice a name the user meant would carry a mark they can
/// never answer. Organize's dismissal can't serve: it lasts only as long as the scan results.
@Suite struct KeptNamesStoreTests {

    private func scratch(_ name: String) -> ScratchDefaults {
        ScratchDefaults("KeptNames-\(name)")
    }

    @MainActor
    @Test func aKeptNameSurvivesTheStoreBeingRebuilt() {
        let defaults = scratch("persist")

        let store = KeptNamesStore(userDefaults: defaults)
        #expect(store.isKept("Q3: final.pdf") == false)
        store.keep("Q3: final.pdf")
        #expect(store.isKept("Q3: final.pdf"))

        // A fresh store over the same defaults is the relaunch: the decision must outlive the
        // session that made it.
        let reopened = KeptNamesStore(userDefaults: defaults)
        #expect(reopened.isKept("Q3: final.pdf"))
        #expect(reopened.isKept("something else.pdf") == false)
    }

    @MainActor
    @Test func withdrawingAKeepIsAlsoDurable() {
        let defaults = scratch("withdraw")

        let store = KeptNamesStore(userDefaults: defaults)
        store.keep("report ")
        store.keep("memo:draft")
        store.stopKeeping("report ")

        let reopened = KeptNamesStore(userDefaults: defaults)
        #expect(reopened.isKept("report ") == false)
        #expect(reopened.isKept("memo:draft"))
    }

    @MainActor
    @Test func theLastKeepWithdrawnLeavesNothingBehind() {
        let defaults = scratch("empty")

        let store = KeptNamesStore(userDefaults: defaults)
        store.keep("only one")
        store.stopKeeping("only one")
        // Removed rather than written as an empty array, which reads back the same but leaves a
        // dead entry in the defaults plist.
        #expect(defaults.object(forKey: KeptNamesStore.defaultsKey) == nil)
        #expect(KeptNamesStore(userDefaults: defaults).names.isEmpty)
    }

    /// Settings' "Clear All": durable like every other withdrawal, and it removes the defaults key
    /// rather than leaving an empty array, as `theLastKeepWithdrawnLeavesNothingBehind` checks for
    /// the one-at-a-time path.
    @MainActor
    @Test func clearingEveryKeepIsDurableAndLeavesNothingBehind() {
        let defaults = scratch("clearall")

        let store = KeptNamesStore(userDefaults: defaults)
        for name in ["report ", "Q3: final.pdf", "memo\u{200B}.txt"] { store.keep(name) }

        store.stopKeepingAll()

        #expect(store.names.isEmpty)
        #expect(defaults.object(forKey: KeptNamesStore.defaultsKey) == nil)
        #expect(KeptNamesStore(userDefaults: defaults).names.isEmpty)
    }

    /// Clearing an already-empty set publishes nothing. `names` is `@Published` and
    /// `FileSyncManager` reconciles `riskyNames` on every publish, so an unconditional `removeAll()`
    /// would re-filter every finding for a press that changed nothing.
    @MainActor
    @Test func clearingWhenNothingIsKeptPublishesNothing() async {
        let defaults = scratch("clearall-empty")

        let store = KeptNamesStore(userDefaults: defaults)
        var publishes = 0
        let token = store.objectWillChange.sink { _ in publishes += 1 }
        defer { token.cancel() }

        store.stopKeepingAll()
        await Task.yield()

        #expect(publishes == 0)
    }

    /// The keep is about the name, so the same name in another folder is the same decision. That
    /// is deliberate: it stops a move or copy from re-asking a question the user already answered.
    @MainActor
    @Test func keepingANameCoversEveryFileWithThatName() {
        let defaults = scratch("byname")

        let store = KeptNamesStore(userDefaults: defaults)
        store.keep("scan 001 .pdf")
        // The store never sees a path, which is what lets the keep survive the file moving.
        #expect(store.isKept("scan 001 .pdf"))
        #expect(store.isKept("scan 002 .pdf") == false)
    }
}

/// A kept name must not reach Organize's list, or "Fix all" would rename exactly what the user just
/// said they meant to keep.
@Suite struct KeptNamesFilterTests {

    private func risky(_ name: String) -> RiskyName {
        RiskyName(id: "/root/\(name)", relativePath: name, currentName: name,
                  sanitizedName: "fixed", reason: "because", isDirectory: false)
    }

    @MainActor
    @Test func reportableDropsKeptNamesAndOnlyThose() {
        let defaults = ScratchDefaults("KeptFilter")

        let manager = FileSyncManager()
        let store = KeptNamesStore(userDefaults: defaults)
        store.keep("kept ")
        manager.keptNamesStore = store

        let found = [risky("kept "), risky("not kept "), risky("also:not")]
        let reported = manager.reportable(found).map(\.currentName)
        #expect(reported == ["not kept ", "also:not"])
    }

    @MainActor
    @Test func withNoStoreEveryFindingIsReported() {
        let manager = FileSyncManager()
        let found = [risky("a "), risky("b:")]
        // Tests and the CLI attach no store, and must see every finding.
        #expect(manager.reportable(found).count == 2)
    }

    /// Keeping a name after a scan has published drops the row already on screen, or Organize
    /// would go on offering to rename a name the user kept from a pane row.
    @MainActor
    @Test func keepingANameDropsItFromAlreadyPublishedResults() async throws {
        let defaults = ScratchDefaults("KeptLive")

        let manager = FileSyncManager()
        let store = KeptNamesStore(userDefaults: defaults)
        manager.keptNamesStore = store
        manager.riskyNames = [risky("keep me "), risky("fix me ")]

        store.keep("keep me ")
        // The subscription hop is a Combine sink on the main actor; yield once so it lands.
        await Task.yield()
        #expect(manager.riskyNames.map(\.currentName) == ["fix me "])
    }

    /// A keep must announce itself on the manager, not only on the store. The store is a separate
    /// `ObservableObject` behind a plain `var`, so a view observing only the manager
    /// (`DifferencesView`, whose name cells hide the badge on a kept name) would keep showing it.
    /// Run with no risky names published: with results present, the sink's `removeAll` mutates a
    /// `@Published` array and announces anyway, so the test would pass without the explicit
    /// announcement.
    @MainActor
    @Test func keepingANameAnnouncesOnTheManagerEvenWithNothingToRemove() async throws {
        let defaults = ScratchDefaults("KeptAnnounce")

        let manager = FileSyncManager()
        let store = KeptNamesStore(userDefaults: defaults)
        manager.keptNamesStore = store
        manager.riskyNames = []

        var announcements = 0
        let token = manager.objectWillChange.sink { _ in announcements += 1 }
        defer { token.cancel() }

        store.keep("never scanned ")
        await Task.yield()
        #expect(announcements > 0,
                "nothing observing the manager would learn of the keep, so the Differences table's badge would go stale")
    }

    /// Attaching a store to a manager that has already scanned applies it at once, not at the next
    /// change to the set. The app attaches it before the first scan; this pins a late attach.
    @MainActor
    @Test func attachingAStoreFiltersWhatIsAlreadyPublished() {
        let defaults = ScratchDefaults("KeptAttach")

        let manager = FileSyncManager()
        manager.riskyNames = [risky("kept "), risky("other ")]
        let store = KeptNamesStore(userDefaults: defaults)
        store.keep("kept ")
        manager.keptNamesStore = store

        #expect(manager.riskyNames.map(\.currentName) == ["other "])
    }
}
