import AppKit
import SwiftUI

/// How tightly the long lists (the Differences table, Tidy group cards, Filing suggestions)
/// pack their rows (backlog H7). Comfortable is the app's unchanged default look; Compact is
/// the power user's opt-in for scanning 1,000+ rows. Stored in UserDefaults via
/// `ListDensity.defaultsKey`, mirroring the other appearance options in `LiquidGlass`.
public enum ListDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable
    case compact

    /// UserDefaults key for the selected density (raw value of `ListDensity`). Read via
    /// `@AppStorage` by the Settings Appearance tab and every list view that honors it —
    /// one shared constant so the setting has a single source of truth.
    public static let defaultsKey = "listDensity"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }

    /// The concrete row measurements for this density. Comfortable's values ARE the app's
    /// pre-H7 constants — comfortable must render pixel-identical to the look before the
    /// setting existed (pinned by `ListDensityTests`).
    public var metrics: ListDensityMetrics {
        switch self {
        case .comfortable:
            return ListDensityMetrics(
                cardHeaderVerticalPadding: 12,
                cardRowVerticalPadding: 11,
                cardListSpacing: 10,
                cardListPadding: 12,
                tableMinRowHeight: nil,
                showsSecondaryDetail: true,
                flatRowVerticalPadding: 6,
                treeIconSize: 17,
                logListSpacing: 6
            )
        case .compact:
            return ListDensityMetrics(
                cardHeaderVerticalPadding: 7,
                cardRowVerticalPadding: 6,
                cardListSpacing: 6,
                cardListPadding: 8,
                tableMinRowHeight: 20,
                showsSecondaryDetail: false,
                flatRowVerticalPadding: 2,
                treeIconSize: 14,
                logListSpacing: 2
            )
        }
    }
}

/// Pure row measurements per density — a small testable type so the numbers live in one
/// place instead of scattered across view literals.
public struct ListDensityMetrics: Equatable, Sendable {
    /// Vertical padding of a card's always-visible header row (Tidy group header).
    public let cardHeaderVerticalPadding: CGFloat
    /// Vertical padding of a row inside an expanded card (a duplicate copy row).
    public let cardRowVerticalPadding: CGFloat
    /// Spacing between cards in a card list (Tidy groups, Filing suggestions).
    public let cardListSpacing: CGFloat
    /// Outer padding around a card list.
    public let cardListPadding: CGFloat
    /// Minimum row height override for `Table`s; nil leaves the system default untouched
    /// (comfortable must not alter the current table look).
    public let tableMinRowHeight: CGFloat?
    /// Whether rows show their secondary size/date detail line; compact hides it.
    public let showsSecondaryDetail: Bool
    /// Vertical padding of a flat list row (file rows, log rows, history rows).
    public let flatRowVerticalPadding: CGFloat
    /// Side of a file row's square icon frame.
    public let treeIconSize: CGFloat
    /// `LazyVStack` spacing in the log-style windows (Activity Log, Sync History).
    public let logListSpacing: CGFloat
}

public extension View {
    /// Applies a density to a `Table`/`List` subtree. Comfortable restores the default look;
    /// compact tightens the rows.
    ///
    /// A SwiftUI `Table` ignores every environment lever on macOS — `defaultMinListRowHeight`,
    /// `controlSize`, and even the ambient font never reach its NSTableView or its hosted
    /// cells (verified empirically against the Compare differences table; the original H7
    /// row-minimum approach rendered pixel-identical rows). So compact reaches beneath the
    /// Table and pins the AppKit `rowHeight` directly via `TableDensityApplier`; the
    /// environment minimum is still set for any plain `List` under the same modifier. Cell
    /// fonts don't inherit either — table cells opt in per-view (see `DifferenceNameCell`).
    @ViewBuilder
    func listDensity(_ density: ListDensity) -> some View {
        if let minRowHeight = density.metrics.tableMinRowHeight {
            self.environment(\.defaultMinListRowHeight, minRowHeight)
                .background(TableDensityApplier(rowHeight: minRowHeight))
        } else {
            self.background(TableDensityApplier(rowHeight: nil))
        }
    }
}

/// Reaches the `NSTableView` beneath a SwiftUI `Table` and pins its row height — the only
/// row-density lever the Table actually honors (see `listDensity(_:)`). A nil `rowHeight`
/// restores the table's own original metrics, so live-toggling compact → comfortable in
/// Settings returns the exact pre-compact look.
private struct TableDensityApplier: NSViewRepresentable {
    let rowHeight: CGFloat?

    func makeNSView(context: Context) -> ApplierView { ApplierView() }

    func updateNSView(_ view: ApplierView, context: Context) {
        view.desiredRowHeight = rowHeight
        view.applySoon()
    }

    final class ApplierView: NSView {
        var desiredRowHeight: CGFloat?
        /// The table's own metrics, captured the first time compact overrides them; restored
        /// when the density returns to comfortable.
        private var original: (rowHeight: CGFloat, spacing: NSSize, automaticHeights: Bool)?

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
            guard let tableView = findTableView() else { return }
            if let desired = desiredRowHeight {
                if original == nil {
                    original = (tableView.rowHeight, tableView.intercellSpacing,
                                tableView.usesAutomaticRowHeights)
                }
                // usesAutomaticRowHeights is the piece that actually matters: SwiftUI's Table
                // measures every cell and ignores `rowHeight` while it's on (verified live —
                // rowHeight already read 20 while the rows still rendered at ~25pt).
                if tableView.usesAutomaticRowHeights || tableView.rowHeight != desired {
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

        /// This view sits as a background sibling of the Table's hosting view — walk a few
        /// levels up, scanning each subtree, to find the table.
        private func findTableView() -> NSTableView? {
            var root: NSView? = superview
            for _ in 0..<5 {
                guard let candidate = root else { return nil }
                if let found = Self.firstTableView(in: candidate) { return found }
                root = candidate.superview
            }
            return nil
        }

        private static func firstTableView(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for sub in view.subviews {
                if let found = firstTableView(in: sub) { return found }
            }
            return nil
        }
    }
}
