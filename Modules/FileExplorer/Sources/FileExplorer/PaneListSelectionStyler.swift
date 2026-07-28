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
        /// (the steady state if a future macOS reshapes SwiftUI's List) used to burn a full
        /// six-ancestor scan per layout, on both panes, forever. The budget bounds that; it re-arms
        /// on a window change or a SwiftUI update, which is when a new table could actually appear.
        private var searchBudget = StylerView.searchesPerChange
        private static let searchesPerChange = 6

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
        private func resolveTableView() -> NSTableView? {
            guard window != nil else { return nil }
            let target = convert(bounds, to: nil)
            // Not laid out yet. Spending budget here would burn the search on a frame SwiftUI has
            // not assigned, and the retry would find none left.
            guard !target.isEmpty else { return nil }
            if let cached = cachedTable, cached.window === window,
               PaneListResolver.matches(cached, target: target) { return cached }
            guard searchBudget > 0 else { return nil }
            searchBudget -= 1
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
