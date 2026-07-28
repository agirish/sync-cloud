import AppKit
import Events
import SwiftUI

/// Bounds how far the column stack can rubber-band past its own edges, and makes it spring back.
///
/// AppKit's overscroll is open-ended: push left at the first column and the whole stack drags
/// right, exposing a column-wide band of empty pane where the first column should be.
///
/// Switching elasticity off entirely (`63bb6cf`) fixed the hole and went too far — the stack then
/// stops dead at each edge. Capping the travel (`60fd18f`) restored the give but left it *stuck*
/// out there, which is worse than either: the whole point of a rubber band is that it returns.
///
/// The cap and the return are the same mechanism, which is why that version failed. Slack granted
/// unconditionally makes an overscrolled position permanently **legal**, so nothing ever pulls the
/// stack home — `constrainBoundsRect` is not merely a limit, it is the restoring force. The slack
/// therefore exists only while a gesture is in flight; the moment it ends, the hard clamp comes
/// back and the stack animates to it.
///
/// `NSClipView.constrainBoundsRect(_:)` is AppKit's supported hook for this and the only one:
/// `NSScrollElasticity` has no bounded case, so neither the limit nor the spring can be expressed
/// through the scroll view's own API.
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
        private var observers: [NSObjectProtocol] = []
        /// Bounds the search the way `PaneListSelectionStyler` does: `layout()` runs on every pass,
        /// and a hierarchy this can never resolve (the steady state if a future macOS reshapes
        /// SwiftUI's ScrollView) would otherwise re-walk the ancestry forever, on both panes.
        private var budget = StylerView.searchesPerChange
        private static let searchesPerChange = 4

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Torn down here rather than in `deinit`: a nonisolated `deinit` cannot touch
            // non-Sendable stored state, and leaving the window is the moment the observation
            // stops being about anything anyway.
            guard window != nil else { return releaseObservers() }
            rearm()
        }

        private func releaseObservers() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
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
            // Elasticity stays ON; the clip view is what bounds it and springs it back.
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
            observeLiveScroll(of: scroller, clipView: bounded)
        }

        /// The gesture's start and end are what gate the slack, so the clip view has to hear about
        /// them. `NSScrollView` posts both; nothing else tells a clip view whether the user's
        /// gesture is still in flight.
        private func observeLiveScroll(of scroller: NSScrollView, clipView: BoundedElasticClipView) {
            releaseObservers()
            observers = [
                NotificationCenter.default.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scroller, queue: .main
                ) { [weak clipView] _ in clipView?.beginLiveScroll() },
                NotificationCenter.default.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: scroller, queue: .main
                ) { [weak clipView] _ in clipView?.endLiveScroll() }
            ]
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

/// A clip view that gives a little during a scroll and springs back the moment it ends.
final class BoundedElasticClipView: NSClipView {

    /// How far past the content the stack may travel, in points.
    ///
    /// Well under `PaneViewMode.minimumColumnWidth` (140) on purpose: the gap a bounce opens must
    /// never be wide enough to read as a missing column, which is exactly how the unbounded version
    /// was reported.
    static let maximumOverscroll: CGFloat = 44

    /// True only while the user's gesture is in flight. The slack is gated on this, and that gate
    /// IS the spring — see the note on `PaneColumnsScrollStyler`.
    private(set) var isLiveScrolling = false

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        let settled = super.constrainBoundsRect(proposedBounds)
        guard isLiveScrolling, let documentView else { return settled }
        var rect = settled
        let slack = Self.maximumOverscroll
        // `super` has already clamped to the content; the proposed origin is what carries the
        // overscroll, so the limits are measured against it rather than against the clamped rect.
        rect.origin.x = min(max(proposedBounds.origin.x, -slack),
                            max(0, documentView.frame.width - rect.width) + slack)
        rect.origin.y = min(max(proposedBounds.origin.y, -slack),
                            max(0, documentView.frame.height - rect.height) + slack)
        return rect
    }

    func beginLiveScroll() { isLiveScrolling = true }

    /// Ends the gesture and returns the stack to legal bounds.
    ///
    /// Clearing the flag alone would let AppKit's *next* constrain pull it in, but nothing
    /// guarantees another one happens while the stack sits still — which is exactly how it got
    /// stuck out of bounds. The animation makes the return unconditional.
    func endLiveScroll() {
        isLiveScrolling = false
        let home = super.constrainBoundsRect(bounds)
        guard home.origin != bounds.origin else { return }
        let overshoot = max(abs(home.origin.x - bounds.origin.x),
                            abs(home.origin.y - bounds.origin.y))
        if overshoot > Self.maximumOverscroll + 1 {
            // The cap is meant to make this impossible. If it is ever logged, the blank band on
            // screen is NOT overscroll and has another cause entirely — worth knowing, because a
            // screenshot showed a gap roughly a full column wide, far beyond this cap.
            Logger.shared.debug(
                "[columns] stack ended a scroll \(Int(overshoot))pt out of bounds, past the "
                + "\(Int(Self.maximumOverscroll))pt cap")
        }
        // `setBoundsOrigin` directly rather than through `animator()`: with
        // `allowsImplicitAnimation` the move still animates, but the MODEL value lands at once.
        // Through the animator the model trails the animation, so the stack reads as still
        // overscrolled to anything that asks — including the test that pins this.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            setBoundsOrigin(home.origin)
        }
        enclosingScrollView?.reflectScrolledClipView(self)
    }
}
