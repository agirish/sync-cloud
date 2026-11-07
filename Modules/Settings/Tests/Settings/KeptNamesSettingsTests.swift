import AppKit
import Foundation
import SwiftUI
import Testing
import Sync
@testable import Settings

/// The kept-names list in Settings ▸ Organize: the inventory of "I meant that name" decisions.
///
/// A kept name draws no badge, so this list is the only place to see what has been kept. A name
/// removed here must stop being kept, durably, or the list lies about what it does.
///
/// Asserted against `remove(_:)` and `clearAll(confirm:)`, the methods the row button and Clear
/// All call, over a real `KeptNamesStore` on an injected suite. Only driving the rendered control
/// could show that the buttons call these methods.
@Suite struct KeptNamesSettingsTests {

    private func scratch(_ name: String) -> ScratchDefaults {
        ScratchDefaults("KeptNamesSettings-\(name)")
    }

    /// Removing one row withdraws that keep and only that one, and the removal survives a relaunch.
    @MainActor
    @Test func removingARowWithdrawsThatKeepFromThePersistedSet() {
        let defaults = scratch("remove")

        let store = KeptNamesStore(userDefaults: defaults)
        store.keep("report ")
        store.keep("Q3: final.pdf")

        KeptNamesList(store: store).remove("report ")

        #expect(store.isKept("report ") == false)
        #expect(store.isKept("Q3: final.pdf"), "removing one row must not disturb the others")

        // A fresh store over the same defaults is the relaunch. A removal that cleared only memory
        // would leave the name kept on next launch, its badge silenced and its rename not offered.
        let reopened = KeptNamesStore(userDefaults: defaults)
        #expect(reopened.isKept("report ") == false)
        #expect(reopened.isKept("Q3: final.pdf"))
    }

    /// Clear All empties the set, durably.
    @MainActor
    @Test func clearAllWithdrawsEveryKeep() {
        let defaults = scratch("clear")

        let store = KeptNamesStore(userDefaults: defaults)
        for name in ["a ", "b:", "c\u{200B}d"] { store.keep(name) }
        #expect(store.names.count == 3)

        KeptNamesList(store: store).clearAll(confirm: { true })

        #expect(store.names.isEmpty)
        #expect(KeptNamesStore(userDefaults: defaults).names.isEmpty)
    }

    /// The list shows the store's names in a stable order, so rows don't shuffle under the cursor
    /// mid-removal.
    @MainActor
    @Test func theListPresentsEveryKeptNameInAStableOrder() {
        let defaults = scratch("order")

        let store = KeptNamesStore(userDefaults: defaults)
        for name in ["zulu ", "alpha ", "mike:"] { store.keep(name) }

        #expect(store.sortedNames == ["alpha ", "mike:", "zulu "])
    }

    // MARK: The section as laid out

    /// Lays the tab out for real, with names in the store, so a broken `body` can't pass on the
    /// method tests above. A populated tab must be taller than an empty one, the cheapest proof
    /// the rows are drawn.
    @MainActor
    @Test func theSectionLaysOutItsRowsWhenNamesAreKept() {
        let defaults = scratch("layout")

        let store = KeptNamesStore(userDefaults: defaults)
        let manager = FileSyncManager()
        manager.keptNamesStore = store

        let empty = laidOutHeight(ProvidersSettingsTab(page: .nameChecks, syncManager: manager).environmentObject(SettingsManager(autoDiscover: false, userDefaults: defaults, cloudStorageLister: { .read([]) })))
        #expect(empty > 0, "the tab did not lay out at all")

        for name in ["report ", "Q3: final.pdf", "memo\u{200B}.txt"] { store.keep(name) }
        let populated = laidOutHeight(ProvidersSettingsTab(page: .nameChecks, syncManager: manager).environmentObject(SettingsManager(autoDiscover: false, userDefaults: defaults, cloudStorageLister: { .read([]) })))

        #expect(populated > empty,
                "three kept rows and a Clear All added \(populated - empty)pt — the rows are not being rendered")
    }

    /// Text scale pinned, as in `SettingsLayoutTests`: `scaledFont` reads it from the environment,
    /// so unpinned it measures this machine's text size.
    @MainActor
    private func laidOutHeight(_ view: some View,
                               width: CGFloat = SettingsSheetMetrics.contentWidth(textScale: 1)) -> CGFloat {
        let host = NSHostingView(rootView: view.environment(\.appFontScale, 1).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // MARK: Findability

    /// Users type the menu items' words ("Always Allow This Name"), the list's old name ("kept
    /// names"), or the problem ("risky name", "trailing space"), not the section title.
    @Test func allowedNamesIsFindableByTheWordsItsControlUses() {
        for query in ["kept names", "allowed names", "always allow", "allow name", "stop allowing",
                      "risky name", "badge", "trailing space"] {
            let results = filterSettings(SettingsSearchIndex.all, query: query)
            #expect(results.contains { $0.title == "Allowed names" && $0.place == SettingsPlace(.nameChecks) },
                    "'\(query)' should surface the Allowed names control")
        }
    }

    /// It belongs beside the rule that raises a risky-name badge (TE332), not on Compare beside
    /// Ignored items, whose shape it shares: an allowed name clears its badge in every pane.
    @Test func allowedNamesLiveBesideTheNameRule() {
        let entry = SettingsSearchIndex.all.first { $0.title == "Allowed names" }
        let rule = SettingsSearchIndex.all.first { $0.title == "Check folder names against" }
        #expect(entry?.place == SettingsPlace(.nameChecks), "Allowed names points at \(entry?.place.name ?? "nothing")")
        #expect(entry?.place == rule?.place)
    }
}
