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
    func updateNSView(_ view: StylerView, context: Context) { view.applySoon() }

    final class StylerView: NSView {
        private weak var cachedTable: NSTableView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applySoon()
        }

        override func layout() {
            super.layout()
            apply()
        }

        /// The table's scroll view may not exist yet while SwiftUI is still mounting this background
        /// view — retry after the current runloop turn.
        func applySoon() {
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
            cachedTable = findTableView()
            return cachedTable
        }

        /// Walk up a few levels, scanning each subtree for the pane's single-column table. Ambiguity
        /// (two tables in one subtree — e.g. both panes momentarily under one ancestor) is refused,
        /// not guessed; a lower level, closer to this view's own list, resolves to exactly one.
        private func findTableView() -> NSTableView? {
            var root: NSView? = superview
            for _ in 0..<6 {
                guard let candidate = root else { return nil }
                let tables = Self.singleColumnTables(in: candidate)
                if tables.count == 1 { return tables[0] }
                if tables.count > 1 { return nil }
                root = candidate.superview
            }
            return nil
        }

        private static func singleColumnTables(in view: NSView) -> [NSTableView] {
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
