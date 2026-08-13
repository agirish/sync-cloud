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
/// THIS table) with the same frame anchoring and the same bounded search-budget discipline as the
/// pane styler — both now inherited from `FrameAnchoredResolveView`, where the re-arm rules (the
/// correctness story) are documented once.
///
/// What repaints the washes is three signals, each covering a hole in the others:
/// - `NSTableView.selectionDidChangeNotification` — selection moved (posted for both user clicks
///   and the programmatic writes SwiftUI makes when its selection binding changes) — plus
///   `selectionIsChangingNotification`, the live stream a drag-extend posts before mouse-up.
/// - the clip view's bounds changing — scrolling recycles row views, and a reused row view
///   scrolled in under a selected index must gain the wash (and one under an unselected index
///   must lose a stale one) without any selection having changed.
/// - this view's own `layout()` — mount, resize, and SwiftUI re-tiling, which also re-asserts
///   `selectionHighlightStyle` on a table SwiftUI may have rebuilt.
struct DifferencesTableSelectionStyler: NSViewRepresentable {
    /// The wash: the app accent at `PaneSelectionWash.active`. An `NSColor` so the row views can
    /// resolve it at draw time. (Correctness doesn't hinge on the color staying dynamic: an
    /// accent or appearance change re-evaluates the view's body and pushes a fresh color through
    /// `updateNSView`, and an appearance switch redisplays the window anyway.)
    let washColor: NSColor

    func makeNSView(context: Context) -> StylerView { StylerView() }
    /// A SwiftUI update can mean a rebuilt table or a changed accent, so push the color and
    /// re-arm the search as well as re-asserting.
    func updateNSView(_ view: StylerView, context: Context) {
        view.washColor = washColor
        view.rearm()
    }

    final class StylerView: FrameAnchoredResolveView {
        /// The differences table is the window's one multi-column table — the pane resolver's
        /// single-column filter exists precisely to skip it, and this flag is the inverse.
        override class var resolvesMultiColumnTable: Bool { true }

        var washColor: NSColor = .clear {
            // Equality-guarded: `updateNSView` assigns on every SwiftUI update, and the
            // differences view re-renders per published file during a bulk sync — an
            // unconditional repaint here would enumerate the visible rows twice per file.
            didSet { if washColor != oldValue { paintWashes() } }
        }

        private var observers: [NSObjectProtocol] = []

        override func windowDidExit() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            observedTable = nil
            observedClip = nil
        }

        override func resolvePass() {
            guard let table = resolveTableView() else { return }
            if table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }
            paintWashes()
        }

        /// The repaint observers attach on BOTH resolution paths — a cached hit and a fresh
        /// resolve — because a table can resolve before SwiftUI has wrapped it in its scroll
        /// view, and `observe` is what re-registers once the clip exists.
        override func tableIsCurrent(_ table: NSTableView) { observe(table) }

        /// Attaches the repaint observers to a newly resolved table (and its clip view),
        /// dropping any previous table's. Safe to call with the same table repeatedly — it
        /// re-registers only when something is actually missing.
        ///
        /// The clip view is tracked as its own condition, not folded into "observers exist":
        /// a table can resolve before SwiftUI has wrapped it in its scroll view, and a guard
        /// that read one registered observer as "fully observed" would then skip the clip
        /// observer for the table's whole lifetime — scroll-driven row-view reuse would repaint
        /// nothing, leaving reused rows washless (or stale-washed) until the next selection
        /// change or unrelated re-render.
        private func observe(_ table: NSTableView) {
            let clip = table.enclosingScrollView?.contentView
            guard observedTable !== table || observers.isEmpty || observedClip !== clip else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            observedTable = table
            observedClip = clip
            let center = NotificationCenter.default
            // Both selection notifications: `DidChange` lands at mouse-up, but a drag-extend
            // posts `IsChanging` throughout — with the native highlight off, that stream is the
            // only live feedback a rubber-band selection has.
            for name in [NSTableView.selectionDidChangeNotification,
                         NSTableView.selectionIsChangingNotification] {
                observers.append(center.addObserver(forName: name, object: table, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.paintWashes() }
                })
            }
            if let clip {
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
        private weak var observedClip: NSClipView?

        private func paintWashes() {
            guard let table = cachedTable else { return }
            let wash = washColor
            table.enumerateAvailableRowViews { rowView, _ in
                SelectionWashView.update(on: rowView, color: rowView.isSelected ? wash : nil)
            }
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
