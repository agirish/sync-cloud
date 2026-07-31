import AppKit
import SwiftUI

/// Disables the pane `List`'s built-in row-selection highlight so the accent-tinted selection drawn
/// by each row's `.listRowBackground` is the ONLY highlight. SwiftUI backs the sidebar list with an
/// `NSTableView` whose selection is painted from `NSColor.selectedContentBackgroundColor` — a flat
/// gray under a Graphite macOS accent, and unmoved by SwiftUI's `.tint`. Reaching the table and
/// setting `selectionHighlightStyle = .none` removes that gray; the SwiftUI selection binding (and
/// therefore the row background keyed on it) is unaffected, so selection behaviour is unchanged.
///
/// Placed as a `.background` sibling of the list, it finds that list's table through
/// `PaneListResolver` and re-asserts on every layout pass, since SwiftUI re-tiles and can recreate
/// the table on data changes or tab switches.
///
/// It reached only the first column of a Columns pane until the resolver was frame-anchored: every
/// column drilled into kept the OS highlight. See `PaneListResolver` for the mechanism and the
/// measurement.
struct PaneListSelectionStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> StylerView { StylerView() }
    /// A SwiftUI update can mean a rebuilt table, so re-arm the search as well as re-asserting.
    func updateNSView(_ view: StylerView, context: Context) { view.rearmSearch() }

    final class StylerView: NSView {
        private weak var cachedTable: NSTableView?

        /// Searches left before giving up until something changes. The walk below scans up to six
        /// ancestor subtrees, and `layout()` runs it on every pass — so an unresolvable hierarchy
        /// (the steady state if a future macOS reshapes SwiftUI's List) would otherwise burn a full
        /// six-ancestor scan per layout, on both panes, forever. The budget bounds that.
        ///
        /// **What re-arms it is the whole correctness story.** It used to re-arm on a SwiftUI
        /// update — i.e. on `updateNSView` — and that quietly meant "constantly", because the host
        /// re-rendered the pane on every one of its ~56 published properties. The styler was being
        /// spammed, and the spam was doing the work: any table SwiftUI recreated got re-styled
        /// within milliseconds because the budget had just been refilled again.
        ///
        /// Then `FileTreeView` became `Equatable` (`cbc1eca`) and the pane stopped re-rendering on
        /// unrelated state — correctly — and this went with it. Once the budget hit zero, nothing
        /// refilled it, the styler gave up **permanently**, and the OS selection highlight came back
        /// underneath the pane's own accent wash: a bright blue row where the table had key focus,
        /// a gray one where it did not, and the app's teal only on the lists that happened to
        /// resolve before the budget ran out. Three different-looking selections in one window.
        ///
        /// So it re-arms on the two things that genuinely mean "the list under me may have changed":
        /// the anchor moving, and a table we had ceasing to be ours. Neither depends on how often
        /// SwiftUI updates us, which is the property that was missing. `passesSinceExhausted` then
        /// covers what no change signal can see — a table swapped in place beneath a perfectly still
        /// anchor — at a thirtieth of the cost of scanning every pass.
        private var searchBudget = StylerView.searchesPerChange
        private static let searchesPerChange = 6
        /// The anchor's window rect at the last search. A moved or resized anchor sits over a
        /// different list than it did — see `PaneListResolver`, where the frame IS the identity.
        private var lastSearchedTarget: CGRect = .null
        /// Layout passes since the burst budget ran dry with nothing found.
        ///
        /// The budget bounds a BURST; this bounds the STEADY STATE. Together they mean an
        /// unresolvable hierarchy costs one ancestor scan per thirty layout passes instead of one
        /// per pass, while a list that only appears later — or is swapped in place while this
        /// anchor sits perfectly still, which no change signal can see — is still picked up within
        /// a few frames. "Gave up permanently" is the defect all of this exists to prevent, so it
        /// must not be reachable by any path.
        private var passesSinceExhausted = 0
        private static let retryEveryNPasses = 30

        /// Test seam: how many ancestor scans have actually run. The re-arm rules are only
        /// meaningful if the STEADY state stays rare, and a suite with no way to count scans could
        /// not tell "recovers" from "scans on every single pass", which is the cost the budget
        /// exists to prevent.
        private(set) var searchesPerformed = 0


        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            rearmSearch()
        }

        override func layout() {
            super.layout()
            apply()
        }

        /// The table's scroll view may not exist yet while SwiftUI is still mounting this background
        /// view — retry after the current runloop turn, with a fresh search budget.
        func rearmSearch() {
            searchBudget = Self.searchesPerChange
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let table = resolveTableView() else { return }
            if table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }
        }

        /// Re-validates a cached table against this view's current frame instead of trusting it for
        /// the lifetime of the window. A drill rebuilds the column stack wholesale, so a table that
        /// was this list's a moment ago can belong to a different column now — see
        /// `PaneListResolver` for why the frame is the identifier.
        /// Internal, not private: this is the test seam. The re-arm rules above are the whole
        /// correctness story and a suite that could not drive them would be asserting nothing.
        func resolveTableView() -> NSTableView? {
            guard window != nil else { return nil }
            let target = convert(bounds, to: nil)
            // Not laid out yet. Spending budget here would burn the search on a frame SwiftUI has
            // not assigned, and the retry would find none left.
            guard !target.isEmpty else { return nil }
            if let cached = cachedTable, cached.window === window,
               PaneListResolver.matches(cached, target: target) { return cached }
            // Reaching here means either we never had a table, or the one we had is gone or is no
            // longer the list under this anchor. The latter two are hierarchy changes and earn a
            // fresh budget; so does the anchor having moved. Sitting still with nothing to find
            // earns nothing, which is what keeps the bound meaningful. See `searchBudget`.
            let anchorMoved = !target.equalTo(lastSearchedTarget)
            let lostItsTable = cachedTable != nil
            lastSearchedTarget = target
            // Cleared before the checks below, so `lostItsTable` reads true exactly once per
            // invalidation rather than on every later pass — otherwise a table that vanished for
            // good would refill the budget forever and reinstate the per-layout scan.
            cachedTable = nil
            if anchorMoved || lostItsTable {
                searchBudget = Self.searchesPerChange
                passesSinceExhausted = 0
            } else if searchBudget == 0 {
                passesSinceExhausted += 1
                if passesSinceExhausted >= Self.retryEveryNPasses {
                    passesSinceExhausted = 0
                    searchBudget = 1
                }
            }
            guard searchBudget > 0 else { return nil }
            searchBudget -= 1
            searchesPerformed += 1
            cachedTable = PaneListResolver.table(matching: self)
            return cachedTable
        }
    }
}

/// How strongly a pane paints its selected rows, by whether that pane is the active one.
///
/// This is the replacement for the emphasized/unemphasized selection AppKit used to draw: the panes
/// disable the system highlight (`PaneListSelectionStyler`) to get the app accent instead of OS
/// gray, and the window pins `controlActiveState` to `.active` to stop the glass graying out when it
/// isn't key. Both are deliberate, but together they removed every cue for which pane the action bar
/// acts on. Named constants rather than literals at the call site so the two stay a *pair* — the gap
/// between them is the whole signal, and `PaneSelectionWashTests` pins that it stays legible.
public enum PaneSelectionWash {
    /// The pane holding the action bar: the selection reads at full strength.
    public static let active: Double = 0.22
    /// The other pane: still clearly a selection, visibly subordinate to the active one.
    public static let inactive: Double = 0.10

    public static func opacity(isActivePane: Bool) -> Double {
        isActivePane ? active : inactive
    }
}
