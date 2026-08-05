import AppKit
import SwiftUI

/// Replaces the differences `Table`'s native selection highlight with the accent wash the panes
/// draw, so one window shows one selection language. The native highlight is painted by AppKit
/// from `NSColor.selectedContentBackgroundColor` — the SYSTEM accent, flat gray under Graphite —
/// while every pane row draws `accentColor.opacity(0.22)` through `.listRowBackground`. A `Table`
/// exposes no per-row background hook, so the wash has to be painted from the AppKit side: disable
/// the system highlight (as `PaneListSelectionStyler` does for the pane lists) and give each
/// selected `NSTableRowView` a wash subview whose geometry matches the panes' rounded capsule.
///
/// Placed as a `.background` sibling of the Table, it finds the table through `PaneListResolver`
/// (in its multi-column mode — the pane resolver's single-column filter exists precisely to skip
/// THIS table) with the same frame anchoring and the same bounded search-budget discipline; see
/// `PaneListSelectionStyler` for why the re-arm rules are the correctness story.
///
/// What repaints the washes is three signals, each covering a hole in the others:
/// - `NSTableView.selectionDidChangeNotification` — selection moved (posted for both user clicks
///   and the programmatic writes SwiftUI makes when its selection binding changes).
/// - the clip view's bounds changing — scrolling recycles row views, and a reused row view
///   scrolled in under a selected index must gain the wash (and one under an unselected index
///   must lose a stale one) without any selection having changed.
/// - this view's own `layout()` — mount, resize, and SwiftUI re-tiling, which also re-asserts
///   `selectionHighlightStyle` on a table SwiftUI may have rebuilt.
struct DifferencesTableSelectionStyler: NSViewRepresentable {
    /// The wash: the app accent at `PaneSelectionWash.active`. An `NSColor` rather than a `Color`
    /// so the row views can resolve it per appearance pass — the accent is a dynamic color and
    /// must stay one all the way to the layer.
    let washColor: NSColor

    func makeNSView(context: Context) -> StylerView { StylerView() }
    /// A SwiftUI update can mean a rebuilt table or a changed accent, so push the color and
    /// re-arm the search as well as re-asserting.
    func updateNSView(_ view: StylerView, context: Context) {
        view.washColor = washColor
        view.rearmSearch()
    }

    final class StylerView: NSView {
        var washColor: NSColor = .clear {
            didSet { paintWashes() }
        }

        private weak var cachedTable: NSTableView?
        private var observers: [NSObjectProtocol] = []

        /// Same bounded-burst discipline as `PaneListSelectionStyler` — see that type for why the
        /// budget re-arms on anchor movement and table loss rather than on SwiftUI update spam,
        /// and why the steady-state retry exists at all.
        private var searchBudget = StylerView.searchesPerChange
        private static let searchesPerChange = 6
        private var lastSearchedTarget: CGRect = .null
        private var passesSinceExhausted = 0
        private static let retryEveryNPasses = 30

        /// Test seam, mirroring `PaneListSelectionStyler.searchesPerformed`.
        private(set) var searchesPerformed = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Torn down here rather than in `deinit`: a nonisolated `deinit` cannot touch
            // non-Sendable stored state (same pattern as `PaneColumnsOverscrollReturn`).
            // Re-entering a window re-arms below.
            guard window != nil else {
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = []
                observedTable = nil
                return
            }
            rearmSearch()
        }

        override func layout() {
            super.layout()
            apply()
        }

        func rearmSearch() {
            searchBudget = Self.searchesPerChange
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let table = resolveTableView() else { return }
            if table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }
            paintWashes()
        }

        /// Attaches the repaint observers to a newly resolved table (and its clip view),
        /// dropping any previous table's. Safe to call with the same table repeatedly — it
        /// re-registers only when the table actually changed.
        private func observe(_ table: NSTableView) {
            guard observedTable !== table || observers.isEmpty else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            observedTable = table
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSTableView.selectionDidChangeNotification,
                object: table, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.paintWashes() }
            })
            if let clip = table.enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clip, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.paintWashes() }
                })
            }
        }
        private weak var observedTable: NSTableView?

        private func paintWashes() {
            guard let table = cachedTable else { return }
            let wash = washColor
            table.enumerateAvailableRowViews { rowView, _ in
                SelectionWashView.update(on: rowView, color: rowView.isSelected ? wash : nil)
            }
        }

        /// Same shape as `PaneListSelectionStyler.resolveTableView`, differing only in asking the
        /// resolver for a MULTI-column table. Internal, not private: the test seam.
        func resolveTableView() -> NSTableView? {
            guard window != nil else { return nil }
            let target = convert(bounds, to: nil)
            guard !target.isEmpty else { return nil }
            if let cached = cachedTable, cached.window === window,
               PaneListResolver.matches(cached, target: target) {
                observe(cached)
                return cached
            }
            let anchorMoved = !target.equalTo(lastSearchedTarget)
            let lostItsTable = cachedTable != nil
            lastSearchedTarget = target
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
            cachedTable = PaneListResolver.table(matching: self, multiColumn: true)
            if let table = cachedTable { observe(table) }
            return cachedTable
        }
    }
}

/// The rounded accent capsule drawn behind a selected differences row. Geometry matches the pane
/// rows' `RoundedRectangle(cornerRadius: 6).padding(.horizontal, 6).padding(.vertical, 1)`, so the
/// two surfaces read as the same selection.
final class SelectionWashView: NSView {
    static let horizontalInset: CGFloat = 6
    static let verticalInset: CGFloat = 1
    static let cornerRadius: CGFloat = 6

    var color: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    /// Ensures `rowView` carries exactly the wash it should: a colored capsule when `color` is
    /// given, none when nil. Reuses an existing wash view rather than churning subviews on every
    /// repaint, and inserts below the cell views so text always draws over it.
    static func update(on rowView: NSTableRowView, color: NSColor?) {
        let existing = rowView.subviews.compactMap { $0 as? SelectionWashView }.first
        guard let color else {
            existing?.removeFromSuperview()
            return
        }
        let wash: SelectionWashView
        if let existing {
            wash = existing
        } else {
            wash = SelectionWashView(frame: rowView.bounds)
            wash.autoresizingMask = [.width, .height]
            rowView.addSubview(wash, positioned: .below, relativeTo: rowView.subviews.first)
        }
        if wash.color != color { wash.color = color }
    }

    /// Hit-testing must fall through to the row: the wash is decoration, and swallowing clicks
    /// here would make selected rows dead to further clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: Self.horizontalInset, dy: Self.verticalInset)
        guard !rect.isEmpty else { return }
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }
}
