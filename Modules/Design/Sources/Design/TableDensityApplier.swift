import AppKit
import SwiftUI

/// Reaches the `NSTableView` beneath a SwiftUI `Table` and pins its row height, the only
/// row-density lever the Table honors (see `listDensity(_:)`). A nil `rowHeight` restores the
/// metrics captured when compact first took hold. That snapshot may already include SwiftUI's own
/// `rowHeight` write (the Table sets it from the environment even with `usesAutomaticRowHeights`
/// on), which is harmless: the restore re-enables `usesAutomaticRowHeights`, and AppKit ignores
/// `rowHeight` while it's on. So switching compact → comfortable in Settings returns the exact
/// original look on the same table.
///
/// `listDensity(_:)` keeps this applier structurally stable across density changes (no
/// `@ViewBuilder` branch), so the same `TableDensityApplierView` and its captured originals
/// survive a toggle; a branch would recreate the applier and drop the capture.
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

    /// The table `original` was captured from. Handed a different table (SwiftUI recreated the
    /// Table, or a test points elsewhere), the stale capture is reset, never written onto the new
    /// one. The previous table, if still alive, stays pinned; the multi-column discriminator and
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
            // `usesAutomaticRowHeights` is the piece that matters: SwiftUI's Table measures every
            // cell and ignores `rowHeight` while it's on. The spacing check keeps the guard
            // complete: a SwiftUI re-tile can reset intercellSpacing alone, and that must be
            // re-pinned too.
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

    /// Resolves the target table: the weak cache while it's still in our window, a fresh subtree
    /// find otherwise. A detached applier resolves to nothing: the cache's
    /// `cached.window === window` check would pass vacuously when both are nil and reuse a capture
    /// from a hierarchy this view has left.
    func resolveTableView() -> NSTableView? {
        guard window != nil else { return nil }
        if let cached = cachedTable, cached.window === window { return cached }
        cachedTable = findTableView()
        return cachedTable
    }

    /// This view sits as a background sibling of the Table's hosting view, so walk a few levels
    /// up, scanning each subtree. Only multi-column tables qualify (see `apply(to:)`), so a nearby
    /// single-column `List` is never cached.
    ///
    /// Ambiguity is refused, never guessed at: a level holding more than one multi-column table
    /// skips this pass (nil). An animated branch swap can briefly host the outgoing and incoming
    /// `Table` together, and capturing the dying table's pinned values as "originals" would poison
    /// the restore for the survivor. A later layout pass finds exactly one table and proceeds.
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
