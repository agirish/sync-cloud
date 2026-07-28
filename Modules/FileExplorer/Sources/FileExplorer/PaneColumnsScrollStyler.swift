import AppKit
import SwiftUI

/// Stops the column stack rubber-banding past its own edges.
///
/// AppKit gives every scroll view elastic overscroll, and on the horizontal stack that reads as a
/// defect rather than a flourish: pushing left at the first column drags the whole stack right and
/// exposes a column-wide band of empty pane where the first column should be. A screenshot caught
/// exactly that — five columns open, the leftmost slot blank and everything shifted over — and the
/// bounce is also part of why walking back through three or four columns feels unsteady rather
/// than smooth.
///
/// Finder's column view does not bounce horizontally either, so this is the native behaviour for
/// the thing being imitated, not a preference.
///
/// Placed as a zero-size `.background` INSIDE the horizontal `ScrollView`, so `enclosingScrollView`
/// resolves to that scroll view directly. It must not be attached inside a column: each column is a
/// `List`, i.e. its own vertical `NSScrollView`, and the walk would find that one instead and leave
/// the horizontal stack untouched while appearing to work. `documentView` is checked for exactly
/// that reason — a column's scroll view hosts an `NSTableView`, the stack's does not.
///
/// Vertical elasticity is deliberately left alone: it belongs to the columns' own lists, which
/// scroll vertically and should bounce like every other list in the app.
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
            if scroller.horizontalScrollElasticity != .none {
                scroller.horizontalScrollElasticity = .none
            }
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
