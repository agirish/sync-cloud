import SwiftUI
import AppKit

/// Reports that a click landed anywhere in a pane, without taking the click.
///
/// `focusedPaneSide` is what every pane-scoped surface reads (⌘F, ⌘[, ⌘], ⇧⌘N, the file action
/// bar, the lens scans, the folder sidebar), so any click in a pane must move it: empty space under
/// the last row, the header's breadcrumb or refresh button, the column background, a right-click.
/// Listing those one at a time goes stale with every new control, so this asks once, at the one
/// place that sees every click whatever AppKit view is beneath it.
///
/// `hitTest` runs while an event is routed, and a view that answers `nil` is passed over, so this
/// reports the click and then declines it, every time. It is never a responder, never in the key
/// loop, and can't swallow a press on a button it covers.
///
/// **Don't** use `.allowsHitTesting(false)` for that guarantee: it removes the view from hit
/// testing altogether, so it would stop being asked.
struct PaneClickReporter: NSViewRepresentable {
    let onClick: () -> Void

    /// Which events count as working in a pane. `hitTest` is asked for far more than presses (hover
    /// tracking and layout ask too), and a focus move on hover would re-aim ⌘W and Delete at
    /// whatever pane the pointer crossed last. Right-click counts: the context menu's items act on
    /// that pane.
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

        /// The event in flight, behind a seam. `NSApp.currentEvent` is nil in a test process, so a
        /// test calling `hitTest` directly would take the guard's early exit and never reach the
        /// line that declines the click; `itNeverTakesTheClick` sets this to exercise it.
        var currentEventType: () -> NSEvent.EventType? = { NSApp.currentEvent?.type }

        /// How the report leaves the click's own routing. `hitTest` runs before the clicked control
        /// sees its mouseDown, and the report is a `@Published` write the clicked List is bound to.
        /// Publishing there can flush inside the table's mouse-down tracking loop and reload the
        /// List mid-commit, dropping the click, so it takes two clicks to select.
        /// `paneSelectionBinding` orders its own focus write after the selection commit for this
        /// reason; the reporter, firing earliest, defers.
        ///
        /// `.default` runloop mode, not `DispatchQueue.main.async`: the main queue drains in the
        /// common modes, which include event tracking, so an async hop can still land inside that
        /// loop. Nothing reads the focus synchronously in the same click (the context menu is keyed
        /// to the row's pane, and the selection path writes focus after its commit), so a turn
        /// later changes only the order.
        var deliver: (@escaping () -> Void) -> Void = { block in
            RunLoop.main.perform(inModes: [.default], block: block)
        }

        /// Always returns nil (see the type's doc), with one exit so declining the click is a
        /// property of the member, not of one branch.
        ///
        /// The point arrives in the superview's coordinates, so it is converted before the `bounds`
        /// test; read as local, the report would fire for clicks outside the pane whenever the view
        /// isn't at its superview's origin, as Compare's right pane never is.
        override func hitTest(_ point: NSPoint) -> NSView? {
            if PaneClickReporter.shouldReport(currentEventType()),
               let superview,
               bounds.contains(convert(point, from: superview)),
               let onClick {
                deliver(onClick)
            }
            return nil
        }
    }
}
