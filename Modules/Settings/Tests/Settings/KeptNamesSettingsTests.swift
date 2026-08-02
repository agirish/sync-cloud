import AppKit
import Foundation
import SwiftUI
import Testing
import Sync
@testable import Settings

/// The kept-names list in Settings ▸ Organize: the inventory of "I meant that name" decisions.
///
/// Keeping and un-keeping were both already reachable from a pane row's context menu, so no keep
/// was ever a one-way door — but a kept name draws no badge, so nothing on screen led anywhere and
/// the only way to answer "what have I kept?" was to walk your files. This list is that answer, and
/// what it has to get right is the reverse trip: a name removed here must actually stop being kept,
/// durably, or the list is a display that lies about what it does.
///
/// Asserted against `remove(_:)` and `clearAll()` — the two methods the row button and Clear All
/// call — over a real `KeptNamesStore` on an injected defaults suite. That is the wiring from the
/// view to the persisted set; what it does not reach is whether the buttons are connected to these
/// methods, which nothing short of driving the rendered control could show.
@Suite struct KeptNamesSettingsTests {

    private func scratch(_ name: String) -> (UserDefaults, String) {
        let suite = "KeptNamesSettings-\(name)-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    /// Removing one row withdraws that keep and only that keep — and it survives the relaunch,
    /// which is the whole point of the store being durable in the first place.
    @MainActor
    @Test func removingARowWithdrawsThatKeepFromThePersistedSet() {
        let (defaults, suite) = scratch("remove")
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = KeptNamesStore(userDefaults: defaults)
        store.keep("report ")
        store.keep("Q3: final.pdf")

        KeptNamesList(store: store).remove("report ")

        #expect(store.isKept("report ") == false)
        #expect(store.isKept("Q3: final.pdf"), "removing one row must not disturb the others")

        // A fresh store over the same defaults IS the relaunch. A removal that only cleared the
        // in-memory set would leave the name flagged-as-kept again on next launch, with the badge
        // still silenced and Organize still refusing to offer the rename.
        let reopened = KeptNamesStore(userDefaults: defaults)
        #expect(reopened.isKept("report ") == false)
        #expect(reopened.isKept("Q3: final.pdf"))
    }

    /// Clear All empties the set, durably.
    @MainActor
    @Test func clearAllWithdrawsEveryKeep() {
        let (defaults, suite) = scratch("clear")
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = KeptNamesStore(userDefaults: defaults)
        for name in ["a ", "b:", "c\u{200B}d"] { store.keep(name) }
        #expect(store.names.count == 3)

        KeptNamesList(store: store).clearAll()

        #expect(store.names.isEmpty)
        #expect(KeptNamesStore(userDefaults: defaults).names.isEmpty)
    }

    /// The list renders the names the store holds, in the store's stable order — so two runs of
    /// the same set do not shuffle the rows under the user's cursor mid-removal.
    @MainActor
    @Test func theListPresentsEveryKeptNameInAStableOrder() {
        let (defaults, suite) = scratch("order")
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = KeptNamesStore(userDefaults: defaults)
        for name in ["zulu ", "alpha ", "mike:"] { store.keep(name) }

        #expect(store.sortedNames == ["alpha ", "mike:", "zulu "])
    }

    // MARK: The section as laid out

    /// Every assertion above calls a method; none of them build the view. This one lays the tab
    /// out for real, with names in the store, so the rows and the Clear All are actually
    /// constructed — a broken `body` would otherwise ship green.
    ///
    /// A populated tab must also be TALLER than an empty one. Height rather than a constant: the
    /// section renders through `KeptNamesList`, and asserting "the list is longer when it has rows"
    /// is the cheapest statement that the rows reached the screen at all rather than being built
    /// and dropped.
    @MainActor
    @Test func theSectionLaysOutItsRowsWhenNamesAreKept() {
        let (defaults, suite) = scratch("layout")
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = KeptNamesStore(userDefaults: defaults)
        let manager = FileSyncManager()
        manager.keptNamesStore = store

        let empty = laidOutHeight(FilingSettingsTab(syncManager: manager))
        #expect(empty > 0, "the tab did not lay out at all")

        for name in ["report ", "Q3: final.pdf", "memo\u{200B}.txt"] { store.keep(name) }
        let populated = laidOutHeight(FilingSettingsTab(syncManager: manager))

        #expect(populated > empty,
                "three kept rows and a Clear All added \(populated - empty)pt — the rows are not being rendered")
    }

    /// Text scale pinned, as `SettingsLayoutTests` does: `scaledFont` reads it from the environment,
    /// so an unpinned measurement reports whatever text size the machine running the test has set.
    @MainActor
    private func laidOutHeight(_ view: some View,
                               width: CGFloat = SettingsSheetMetrics.contentWidth(textScale: 1)) -> CGFloat {
        let host = NSHostingView(rootView: view.environment(\.appFontScale, 1).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // MARK: Findability

    /// The control is at the bottom of the longest tab in Settings, so search is how it is
    /// realistically reached — and almost none of the words a user would type appear in its label.
    /// The section is titled "Kept names", but the decision is made through menu items worded
    /// "Always Allow This Name" / "Stop Allowing This Name", and what sent the user looking is the
    /// problem ("risky name", "trailing space") rather than the state they put it in.
    @Test func keptNamesIsFindableByTheWordsItsControlUses() {
        for query in ["kept names", "always allow", "allow name", "stop allowing",
                      "risky name", "badge", "trailing space"] {
            let results = filterSettings(SettingsSearchIndex.all, query: query)
            #expect(results.contains { $0.title == "Kept names" && $0.tab == .filing },
                    "'\(query)' should surface the Kept names control")
        }
    }

    /// It belongs on Organize, with the rename finding whose rows it suppresses — not on Sync
    /// beside Ignored items. Both are durable sets with a per-row removal, which is why the list
    /// follows that section's shape, but a keep answers Organize's risky-name chip, and landing on
    /// the wrong tab of two that look alike is worse than landing on none.
    @Test func keptNamesLivesOnOrganizeRatherThanBesideIgnoredItems() {
        let entry = SettingsSearchIndex.all.first { $0.title == "Kept names" }
        #expect(entry?.tab == .filing, "Kept names points at \(entry?.tab.displayName ?? "nothing")")
    }
}
