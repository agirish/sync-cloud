import AppKit
import SwiftUI

/// Disables the pane `List`'s built-in row-selection highlight so the accent-tinted selection drawn
/// by each row's `.listRowBackground` is the ONLY highlight. SwiftUI backs the sidebar list with an
/// `NSTableView` whose selection is painted from `NSColor.selectedContentBackgroundColor` — a flat
/// gray under a Graphite macOS accent, and unmoved by SwiftUI's `.tint`. Reaching the table and
/// setting `selectionHighlightStyle = .none` removes that gray; the SwiftUI selection binding (and
/// therefore the row background keyed on it) is unaffected, so selection behaviour is unchanged.
///
/// Placed as a zero-size `.background` sibling of the list, it walks up to the nearest single-column
/// `NSTableView` (a multi-column one would be a `Table`, not our pane list) and re-asserts on every
/// layout pass, since SwiftUI re-tiles and can recreate the table on data changes or tab switches.
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

        private func resolveTableView() -> NSTableView? {
            guard window != nil else { return nil }
            if let cached = cachedTable, cached.window === window { return cached }
            guard searchBudget > 0 else { return nil }
            searchBudget -= 1
            cachedTable = Self.findTableView(from: superview)
            return cachedTable
        }

        /// Walk up a few levels, scanning each subtree for the pane's single-column table. Ambiguity
        /// (two tables in one subtree — e.g. both panes momentarily under one ancestor) is refused,
        /// not guessed; a lower level, closer to this view's own list, resolves to exactly one.
        /// Static and internal so `PaneListSelectionStylerTests` can drive it over a synthetic
        /// hierarchy — the refusal rule is the part worth pinning, since getting it wrong would
        /// silently style the OTHER pane's table.
        static func findTableView(from start: NSView?) -> NSTableView? {
            var root: NSView? = start
            for _ in 0..<6 {
                guard let candidate = root else { return nil }
                let tables = singleColumnTables(in: candidate)
                if tables.count == 1 { return tables[0] }
                if tables.count > 1 { return nil }
                root = candidate.superview
            }
            return nil
        }

        static func singleColumnTables(in view: NSView) -> [NSTableView] {
            var result: [NSTableView] = []
            func walk(_ v: NSView) {
                if let table = v as? NSTableView, table.tableColumns.count <= 1 { result.append(table) }
                for sub in v.subviews { walk(sub) }
            }
            walk(view)
            return result
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
