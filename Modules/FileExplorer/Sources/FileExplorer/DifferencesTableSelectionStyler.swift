import AppKit
import SwiftUI

/// Replaces the differences `Table`'s native selection highlight with the panes' accent wash, so
/// one window shows one selection language. AppKit paints the native one in the system accent
/// (flat gray under Graphite), and a `Table` has no per-row background hook, so this turns the
/// highlight off (as `PaneListSelectionStyler` does for the panes) and gives each selected
/// `NSTableRowView` a wash subview shaped like the panes' rounded capsule.
///
/// A `.background` sibling of the Table, it finds the table through `PaneListResolver` in its
/// multi-column mode, with the frame anchoring and bounded search inherited from
/// `FrameAnchoredResolveView`, where the re-arm rules are documented.
///
/// Three signals repaint the washes, each covering a hole in the others:
/// - `NSTableView.selectionDidChangeNotification` (user clicks and SwiftUI's programmatic writes),
///   plus `selectionIsChangingNotification`, the live stream a drag-extend posts before mouse-up.
/// - the clip view's bounds changing: scrolling recycles row views, and a reused one must gain or
///   lose the wash with no selection change.
/// - this view's own `layout()`: mount, resize, and SwiftUI re-tiling, which also re-asserts
///   `selectionHighlightStyle` on a table SwiftUI may have rebuilt.
struct DifferencesTableSelectionStyler: NSViewRepresentable {
    /// The wash: the app accent at `PaneSelectionWash.active`, as an `NSColor` the row views
    /// resolve at draw time. An accent or appearance change also pushes a fresh color through
    /// `updateNSView`.
    let washColor: NSColor

    func makeNSView(context: Context) -> StylerView { StylerView() }
    /// A SwiftUI update can mean a rebuilt table or a changed accent, so push the color and
    /// re-arm the search as well as re-asserting.
    func updateNSView(_ view: StylerView, context: Context) {
        view.washColor = washColor
        view.rearm()
    }

    final class StylerView: FrameAnchoredResolveView {
        /// The differences table is the window's one multi-column table, which the pane
        /// resolver's single-column filter skips; this flag is the inverse.
        override class var resolvesMultiColumnTable: Bool { true }

        var washColor: NSColor = .clear {
            // Equality-guarded: `updateNSView` assigns on every SwiftUI update, which during a
            // bulk sync is once per file, and each repaint enumerates the visible rows.
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

        /// The repaint observers attach on both resolution paths, a cached hit and a fresh
        /// resolve, because a table can resolve before SwiftUI wraps it in its scroll view, and
        /// `observe` re-registers once the clip exists.
        override func tableIsCurrent(_ table: NSTableView) {
            observe(table)
            // And the keyboard: a click on a difference doesn't move first responder by itself,
            // so ⇧↓ would extend the last-clicked pane's selection. Registered here, the one place
            // that resolves this table, as `PaneBackgroundDeselect` is for the panes. The review
            // queue has no styler; `reviewFocusNudge` hands focus back to its card instead.
            PaneListKeyFocus.register(table)
            // And a recognizer, so this table's clicks reach something that can claim the keyboard
            // (see `PaneListKeyFocus.ClickNormalizer`). It belongs to the table, so a rebuilt
            // styler adopts the one already there; the guard only saves work on each layout pass.
            if normalizedTable !== table {
                normalizedTable = table
                PaneListKeyFocus.ClickNormalizer.install(on: table)
            }
        }

        /// Attaches the repaint observers to a newly resolved table and its clip view, dropping
        /// any previous table's. Safe to repeat: it re-registers only when something is missing.
        ///
        /// The clip view is its own condition, not folded into "observers exist": a table can
        /// resolve before its scroll view exists, and treating that as fully observed would skip
        /// the clip observer for good, leaving recycled rows with a missing or stale wash.
        private func observe(_ table: NSTableView) {
            let clip = table.enclosingScrollView?.contentView
            guard observedTable !== table || observers.isEmpty || observedClip !== clip else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            observedTable = table
            observedClip = clip
            let center = NotificationCenter.default
            // Both selection notifications: `DidChange` lands at mouse-up, but a drag-extend
            // posts `IsChanging` throughout, the only live feedback once the native highlight is
            // off.
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
        /// The table this view has already normalized — see `tableIsCurrent(_:)`.
        private weak var normalizedTable: NSTableView?
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

/// The rounded accent capsule drawn behind a selected differences row. Its geometry matches the
/// pane rows' `RoundedRectangle(cornerRadius: Radius.chip).padding(.horizontal, 6)
/// .padding(.vertical, 1)`, so the two read as the same selection.
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

    /// Hit-testing falls through to the row: the wash is decoration, and swallowing clicks would
    /// make selected rows dead to further clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: Self.horizontalInset, dy: Self.verticalInset)
        guard !rect.isEmpty else { return }
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }
}
