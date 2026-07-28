import AppKit
import SwiftUI

/// Bounds how far the column stack can rubber-band past its own edges.
///
/// AppKit's overscroll is open-ended: push left at the first column and the whole stack drags
/// right, exposing a column-wide band of empty pane where the first column should be. A screenshot
/// caught exactly that — five columns open, leftmost slot blank, everything shifted over.
///
/// Switching elasticity off entirely fixed the hole and went too far: the stack then stops dead at
/// each edge, which reads as a stutter of its own. What is wanted is a little give and no more, so
/// the bounce is *capped* rather than removed — `.allowed` elasticity over a clip view that refuses
/// to travel more than `maximumOverscroll` beyond the content.
///
/// `NSClipView.constrainBoundsRect(_:)` is AppKit's supported hook for this and the only one:
/// `NSScrollElasticity` has no bounded case, so the limit cannot be expressed through the scroll
/// view's own API.
///
/// Placed as a zero-size `.background` INSIDE the horizontal `ScrollView`, so `enclosingScrollView`
/// resolves to that scroll view directly. It must not be attached inside a column: each column is a
/// `List`, i.e. its own vertical `NSScrollView`, and the walk would find that one instead and leave
/// the horizontal stack untouched while appearing to work. `documentView` is checked for exactly
/// that reason — a column's scroll view hosts an `NSTableView`, the stack's does not.
///
/// The columns' own vertical bounce is untouched: it belongs to their lists, which should behave
/// like every other list in the app.
struct PaneColumnsScrollStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> StylerView { StylerView() }
    /// A SwiftUI update can rebuild the scroll view, so re-assert rather than trusting one pass.
    func updateNSView(_ view: StylerView, context: Context) { view.rearm() }

    final class StylerView: NSView {
        private weak var cached: NSScrollView?
        /// Bounds the search the way `PaneListSelectionStyler` does: `layout()` runs on every pass,
        /// and a hierarchy this can never resolve (the steady state if a future macOS reshapes
        /// SwiftUI's ScrollView) would otherwise re-walk the ancestry forever, on both panes.
        private var budget = StylerView.searchesPerChange
        private static let searchesPerChange = 4

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            rearm()
        }

        override func layout() {
            super.layout()
            apply()
        }

        func rearm() {
            budget = Self.searchesPerChange
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let scroller = resolveScrollView() else { return }
            // Elasticity stays ON; the clip view is what bounds it.
            if scroller.horizontalScrollElasticity != .allowed {
                scroller.horizontalScrollElasticity = .allowed
            }
            guard !(scroller.contentView is BoundedElasticClipView) else { return }
            let existing = scroller.contentView
            let bounded = BoundedElasticClipView()
            bounded.frame = existing.frame
            bounded.autoresizingMask = existing.autoresizingMask
            bounded.drawsBackground = existing.drawsBackground
            bounded.backgroundColor = existing.backgroundColor
            // Assigning `contentView` does NOT carry the document view across — it drops it, and
            // the stack comes back with no columns at all. Caught by the mounted test, which found
            // zero column lists after the swap. Re-attach it explicitly.
            let document = scroller.documentView
            scroller.contentView = bounded
            scroller.documentView = document
            scroller.reflectScrolledClipView(bounded)
        }

        private func resolveScrollView() -> NSScrollView? {
            guard window != nil else { return nil }
            if let cached, cached.window === window { return cached }
            guard budget > 0 else { return nil }
            budget -= 1
            cached = Self.findStackScrollView(from: self)
            return cached
        }

        /// The nearest enclosing scroll view that is NOT one of the columns' lists.
        ///
        /// Static and internal so the rule can be driven over a synthetic hierarchy: picking the
        /// wrong scroll view here would silently kill a column list's own bounce instead of the
        /// stack's, which looks identical from the outside and is exactly the mistake worth pinning.
        static func findStackScrollView(from start: NSView?) -> NSScrollView? {
            var view = start?.superview
            while let current = view {
                if let scroller = current as? NSScrollView, !hostsATable(scroller) { return scroller }
                view = current.superview
            }
            return nil
        }

        /// A column's scroll view hosts the column's `NSTableView`; the stack's hosts the row of
        /// columns. `documentView` is checked rather than searching the subtree, because the stack's
        /// document view CONTAINS tables and a subtree search would call it a column.
        private static func hostsATable(_ scroller: NSScrollView) -> Bool {
            scroller.documentView is NSTableView
        }
    }
}

/// A clip view whose overscroll is capped instead of open-ended.
///
/// `NSScrollElasticity` is all-or-nothing, so the cap has to be applied where AppKit asks what
/// bounds a scroll is allowed to reach. `super` clamps hard to the document's own extent; this
/// re-opens a fixed amount of travel past each edge and nothing beyond it, which is the difference
/// between a stack that gives a little and one that scrolls into an empty pane.
final class BoundedElasticClipView: NSClipView {

    /// How far past the content the stack may travel, in points.
    ///
    /// Well under `PaneViewMode.minimumColumnWidth` (140) on purpose: the gap a bounce opens must
    /// never be wide enough to read as a missing column, which is exactly how the unbounded version
    /// was reported.
    static let maximumOverscroll: CGFloat = 44

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let slack = Self.maximumOverscroll
        // `super` has already clamped to the content; the proposed origin is what carries the
        // overscroll, so the limits are measured against it rather than against the clamped rect.
        let lowerX = -slack
        let upperX = max(0, documentView.frame.width - rect.width) + slack
        rect.origin.x = min(max(proposedBounds.origin.x, lowerX), upperX)
        let lowerY = -slack
        let upperY = max(0, documentView.frame.height - rect.height) + slack
        rect.origin.y = min(max(proposedBounds.origin.y, lowerY), upperY)
        return rect
    }
}
