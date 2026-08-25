import SwiftUI
import AppKit

/// **Reports that a click landed anywhere in a pane, without taking the click.**
///
/// `focusedPaneSide` is what every pane-scoped surface reads — ⌘F, ⌘[, ⌘], ⇧⌘N, ⇧⌘P, the file
/// action bar, the lens scans and the folder sidebar — and until now it moved on only three things:
/// ⌃⇥, a row selection, and the tab verbs. Everything else a person does inside a pane left it
/// pointing at the other one: clicking the empty space under the last row, the header card's
/// breadcrumb or its refresh button, the column background, a right-click for the context menu.
///
/// **Chasing those one at a time is the wrong shape and was tried first.** `noteWorkingIn` already
/// carries seven call sites added exactly that way, each from a bug report, and its own comment
/// enumerates the four gaps that had been found by then. An enumeration of the ways to click a pane
/// is stale the moment a control is added — so this asks the question once, at the only place that
/// sees every click regardless of which AppKit view is beneath it.
///
/// **How it sees them without stealing them.** `hitTest` is called on the view hierarchy while an
/// event is being routed, and a view that answers `nil` is passed over — the search continues to
/// whatever lies below. So this reports the click and then declines it, every time. It is never a
/// responder, never in the key loop, and cannot swallow a press on a button it happens to cover.
///
/// Do NOT reach for `.allowsHitTesting(false)` to make that guarantee: it removes the view from hit
/// testing altogether, which is also how it would stop being asked.
struct PaneClickReporter: NSViewRepresentable {
    let onClick: () -> Void

    /// **Which events count as working in a pane.** Pulled out because `hitTest` is called for far
    /// more than presses — hover tracking and layout ask too — and a focus move on hover would
    /// re-aim ⌘W and Delete at whatever pane the pointer crossed last.
    ///
    /// Right-click counts: opening a pane's context menu is working in that pane, and the menu's
    /// own items act on it.
    static func shouldReport(_ type: NSEvent.EventType?) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return true
        default: return false
        }
    }

    func makeNSView(context: Context) -> ClickReportingView {
        let view = ClickReportingView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: ClickReportingView, context: Context) { view.onClick = onClick }

    final class ClickReportingView: NSView {
        var onClick: (() -> Void)?

        /// **The event in flight, behind a seam.** `NSApp.currentEvent` is nil in a test process —
        /// nothing is being routed — so a test that calls `hitTest` directly takes the guard's
        /// early exit and never reaches the line that declines the click. The first version of
        /// `itNeverTakesTheClick` was written that way and passed with `return self` in place: it
        /// asserted the safety property over the one input that could not exercise it.
        var currentEventType: () -> NSEvent.EventType? = { NSApp.currentEvent?.type }

        /// Always returns nil — see the type's doc. One exit, so "declines the click" is a property
        /// of the member rather than of whichever branch a reader happens to check.
        ///
        /// The point arrives in the SUPERVIEW's coordinates, which is why it is converted before
        /// being tested against `bounds`; reading it as local makes the report fire for clicks
        /// outside the pane whenever the view is not at its superview's origin, and Compare's right
        /// pane never is.
        override func hitTest(_ point: NSPoint) -> NSView? {
            if PaneClickReporter.shouldReport(currentEventType()),
               let superview,
               bounds.contains(convert(point, from: superview)) {
                onClick?()
            }
            return nil
        }
    }
}
