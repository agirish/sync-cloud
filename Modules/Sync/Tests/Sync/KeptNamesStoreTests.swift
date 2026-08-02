import Testing
import Foundation
@testable import Sync

/// The durable "I meant that name" state the row badge needs.
///
/// The badge is rendered every time a file is on screen, so without somewhere to record a deliberate
/// choice a name the user meant becomes a permanent mark they cannot answer. Organize's existing
/// dismissal cannot serve: it lasts only as long as the scan results do.
@Suite struct KeptNamesStoreTests {

    private func scratch(_ name: String) -> (UserDefaults, String) {
        let suite = "KeptNames-\(name)-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @MainActor
    @Test func aKeptNameSurvivesTheStoreBeingRebuilt() {
        let (defaults, suite) = scratch("persist")
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = KeptNamesStore(userDefaults: defaults)
        #expect(store.isKept("Q3: final.pdf") == false)
        store.keep("Q3: final.pdf")
        #expect(store.isKept("Q3: final.pdf"))

        // A fresh store over the same defaults IS the relaunch: the whole point of the type is that
        // the decision outlives the session that made it.
        let reopened = KeptNamesStore(userDefaults: defaults)
        #expect(reopened.isKept("Q3: final.pdf"))
        #expect(reopened.isKept("something else.pdf") == false)
    }

    @MainActor
    @Test func withdrawingAKeepIsAlsoDurable() {
        let (defaults, suite) = scratch("withdraw")
        defer { defaults.removePersistentDomain(forName: suite) }

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
        let (defaults, suite) = scratch("empty")
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = KeptNamesStore(userDefaults: defaults)
        store.keep("only one")
        store.stopKeeping("only one")
        // Removed rather than written as an empty array — an empty array read back is the same
        // empty set, but leaving the key behind means every provider pair the user ever kept a
        // name under accumulates a dead entry in the defaults plist.
        #expect(defaults.object(forKey: KeptNamesStore.defaultsKey) == nil)
        #expect(KeptNamesStore(userDefaults: defaults).names.isEmpty)
    }

    /// The keep is about the NAME, so the same name in a different folder is the same decision.
    /// This is the deliberate cost of name-keying: it is what stops a move or a copy from re-asking
    /// a question the user already answered.
    @MainActor
    @Test func keepingANameCoversEveryFileWithThatName() {
        let (defaults, suite) = scratch("byname")
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = KeptNamesStore(userDefaults: defaults)
        store.keep("scan 001 .pdf")
        // Same string, wherever it lives — the store never sees a path, which is precisely the
        // property that makes it survive the file moving.
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
        let suite = "KeptFilter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

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
        // The pre-store behaviour, preserved exactly for tests and the CLI, which attach no store.
        #expect(manager.reportable(found).count == 2)
    }

    /// Keeping a name AFTER a scan has published has to drop the row that is already on screen —
    /// otherwise the user keeps a name from a pane row and Organize goes on offering to rename it.
    @MainActor
    @Test func keepingANameDropsItFromAlreadyPublishedResults() async throws {
        let suite = "KeptLive-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = FileSyncManager()
        let store = KeptNamesStore(userDefaults: defaults)
        manager.keptNamesStore = store
        manager.riskyNames = [risky("keep me "), risky("fix me ")]

        store.keep("keep me ")
        // The subscription hop is a Combine sink on the main actor; yield once so it lands.
        await Task.yield()
        #expect(manager.riskyNames.map(\.currentName) == ["fix me "])
    }

    /// Attaching a store to a manager that has already scanned applies it at once, rather than
    /// waiting for the next change to the set. A window reopen recreates `ContentView` and
    /// re-attaches, which is exactly this order.
    @MainActor
    @Test func attachingAStoreFiltersWhatIsAlreadyPublished() {
        let suite = "KeptAttach-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = FileSyncManager()
        manager.riskyNames = [risky("kept "), risky("other ")]
        let store = KeptNamesStore(userDefaults: defaults)
        store.keep("kept ")
        manager.keptNamesStore = store

        #expect(manager.riskyNames.map(\.currentName) == ["other "])
    }
}
