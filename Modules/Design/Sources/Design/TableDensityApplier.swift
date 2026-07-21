import AppKit
import SwiftUI

/// Reaches the `NSTableView` beneath a SwiftUI `Table` and pins its row height — the only
/// row-density lever the Table actually honors (see `listDensity(_:)`). A nil `rowHeight`
/// restores the metrics observed when compact first took hold. For `rowHeight` that snapshot
/// may already include SwiftUI's own env-plumbing write (the Table sets `rowHeight` from the
/// environment even while `usesAutomaticRowHeights` is on) — harmless, because the restore
/// also re-enables `usesAutomaticRowHeights`, and AppKit ignores `rowHeight` entirely while
/// that's on. Live-toggling compact → comfortable in Settings therefore returns the exact
/// pre-compact look on the SAME table instance.
///
/// `listDensity(_:)` keeps this applier structurally stable across density changes (no
/// `@ViewBuilder` branch), so the same `TableDensityApplierView` — and its captured
/// originals — survives a toggle. That's what makes the restore path live at all: a
/// structural branch would recreate the applier and drop the capture.
struct TableDensityApplier: NSViewRepresentable {
    let rowHeight: CGFloat?

    func makeNSView(context: Context) -> TableDensityApplierView { TableDensityApplierView() }

    func updateNSView(_ view: TableDensityApplierView, context: Context) {
        view.desiredRowHeight = rowHeight
        view.applySoon()
    }
}

/// The AppKit worker behind `TableDensityApplier`. Internal (not private) so unit tests can
/// drive `apply(to:)` against a bare `NSTableView` without mounting a SwiftUI hierarchy.
final class TableDensityApplierView: NSView {
    /// The row height to pin, or nil to restore the table's captured originals.
    var desiredRowHeight: CGFloat?

    /// The table's own metrics, captured the first time compact overrides them; restored
    /// (and cleared) when the density returns to comfortable. `private(set)` so tests can
    /// assert capture/reset without being able to corrupt it.
    private(set) var original: (rowHeight: CGFloat, spacing: NSSize, automaticHeights: Bool)?

    /// The table `original` was captured from. When `apply(to:)` is handed a *different*
    /// table (SwiftUI recreated the Table, or a test points us elsewhere), the stale capture
    /// must never be written onto the new instance — it is reset instead. Known limitation:
    /// the previous table, if still alive, stays pinned; the multi-column discriminator plus
    /// the window-scoped cache make that unreachable in the app.
    private weak var appliedTable: NSTableView?

    /// Weak cache of the resolved table so steady-state layout passes skip the subtree walk.
    /// Reused only while it still lives in this view's window; re-found otherwise.
    private weak var cachedTable: NSTableView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySoon()
    }

    // Re-assert on every layout pass: SwiftUI re-tiles the table on data changes and can
    // recreate it on tab switches. apply() is guarded, so steady state is a no-op.
    override func layout() {
        super.layout()
        apply()
    }

    func applySoon() {
        // The Table's NSScrollView may not exist yet while SwiftUI is still mounting
        // this background view — retry after the current runloop turn.
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    private func apply() {
        // Nothing to pin and nothing to restore (comfortable since launch): pay nothing —
        // not even the view-tree walk.
        guard desiredRowHeight != nil || original != nil else { return }
        guard let tableView = resolveTableView() else { return }
        apply(to: tableView)
    }

    /// Pins or restores `tableView` per `desiredRowHeight`. Internal seam so tests can drive
    /// the contract against a bare table.
    func apply(to tableView: NSTableView) {
        // Discriminator: this modifier is only ever attached to multi-column `Table`s. A
        // single-column NSTableView found nearby is a SwiftUI `List` (the file panes) that
        // happens to share the ancestor subtree — it must never be touched.
        guard tableView.tableColumns.count > 1 else { return }

        if appliedTable !== tableView {
            // New table identity: a capture from a previous table is stale — drop it so it
            // can't be "restored" onto this one.
            original = nil
            appliedTable = tableView
        }

        if let desired = desiredRowHeight {
            if original == nil {
                original = (tableView.rowHeight, tableView.intercellSpacing,
                            tableView.usesAutomaticRowHeights)
            }
            // usesAutomaticRowHeights is the piece that actually matters: SwiftUI's Table
            // measures every cell and ignores `rowHeight` while it's on (verified live —
            // rowHeight already read 20 while the rows still rendered at ~25pt). The spacing
            // check keeps the guard complete: a SwiftUI re-tile can reset intercellSpacing
            // alone, and that too must be re-pinned.
            if tableView.usesAutomaticRowHeights || tableView.rowHeight != desired
                || tableView.intercellSpacing.height != 0 {
                tableView.usesAutomaticRowHeights = false
                tableView.rowHeight = desired
                tableView.intercellSpacing = NSSize(width: tableView.intercellSpacing.width, height: 0)
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<tableView.numberOfRows))
            }
        } else if let original {
            tableView.usesAutomaticRowHeights = original.automaticHeights
            tableView.rowHeight = original.rowHeight
            tableView.intercellSpacing = original.spacing
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<tableView.numberOfRows))
            self.original = nil
        }
    }

    /// Resolves the target table: the weak cache while it's still in our window, a fresh
    /// subtree find otherwise. A detached applier (no window) resolves to nothing at all —
    /// besides being pointless to pin a table nobody can see, the cache's
    /// `cached.window === window` identity check would vacuously pass when BOTH are nil
    /// (a detached applier next to a detached table), reusing a capture that belongs to a
    /// hierarchy this view is no longer part of.
    func resolveTableView() -> NSTableView? {
        guard window != nil else { return nil }
        if let cached = cachedTable, cached.window === window { return cached }
        cachedTable = findTableView()
        return cachedTable
    }

    /// This view sits as a background sibling of the Table's hosting view — walk a few
    /// levels up, scanning each subtree, to find the table. Only multi-column tables
    /// qualify (see `apply(to:)`), so a nearby single-column `List` can never be cached.
    ///
    /// Ambiguity is REFUSED, never guessed at: if a level's subtree holds more than one
    /// multi-column table, this pass is skipped (nil). An animated branch swap can briefly
    /// host both the outgoing and incoming `Table` in the same subtree, and picking one by
    /// traversal order risks capturing the dying table's already-pinned values as the
    /// "originals" — poisoning the restore for the table that survives. Once the transient
    /// coexistence ends, a later layout pass finds exactly one table and proceeds.
    private func findTableView() -> NSTableView? {
        var root: NSView? = superview
        for _ in 0..<5 {
            guard let candidate = root else { return nil }
            let found = Self.multiColumnTableViews(in: candidate)
            if found.count == 1 { return found[0] }
            if found.count > 1 { return nil }
            root = candidate.superview
        }
        return nil
    }

    private static func multiColumnTableViews(in view: NSView) -> [NSTableView] {
        var result: [NSTableView] = []
        collectMultiColumnTableViews(in: view, into: &result)
        return result
    }

    private static func collectMultiColumnTableViews(in view: NSView, into result: inout [NSTableView]) {
        if let table = view as? NSTableView, table.tableColumns.count > 1 { result.append(table) }
        for sub in view.subviews {
            collectMultiColumnTableViews(in: sub, into: &result)
        }
    }
}
