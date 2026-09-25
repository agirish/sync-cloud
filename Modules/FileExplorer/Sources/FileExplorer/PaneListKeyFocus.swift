import AppKit

/// Gives a pane's list the keyboard when a click lands in it.
///
/// **SwiftUI does not, on macOS 27.** A click on a `List` row selects it, but the window keeps
/// itself as first responder, so every key after the click — ↑, ↓, ⇧↑ to extend the selection, ⌫
/// for `.onDeleteCommand`, type-select — is delivered to the window and dropped. Measured
/// 2026-09-16, first in the app (`[fr] 300ms after a row click: the WINDOW itself`, with the arrow
/// presses behind it arriving at the window) and then in a bare four-list app with nothing of
/// SyncCloud's in it: a stock `List(selection:)`, a sidebar-style one, one carrying the pane's
/// declining click recognizer and one with the system highlight turned off. **All four** left the
/// window as first responder after a click. So there is nothing in the pane to remove; the claim
/// has to be made.
///
/// **Scoped to registered tables — the pane lists — and nothing else.** Every SwiftUI list in the
/// app shares the platform behaviour, but several surfaces decide focus for themselves (the review
/// card sends focus back from its table on every click), so an app-wide rule would fight them. A
/// pane list opts in through `register(_:)`, which `PaneBackgroundDeselect` calls as it installs
/// its recognizer: that is the one sibling already resolving every pane table — Tree, and each
/// column of Columns — so registration costs no search of its own.
///
/// **A local monitor, not a recognizer.** The recognizer on the table is consulted for the clicks
/// it might act on; whether AppKit consults a table's recognizers for a click whose hit view is a
/// SwiftUI cell deep inside a row is exactly the kind of ancestry question
/// `PaneBackgroundDeselect` declines to bet on. The event stream sees every click, and returns it
/// untouched.
@MainActor
enum PaneListKeyFocus {

    /// The pane lists. Weak, so a column that closes leaves nothing behind to unregister.
    private static let registered = NSHashTable<NSTableView>.weakObjects()
    private static var monitor: Any?

    /// Opts `table` in, and installs the monitor the first time anything does.
    static func register(_ table: NSTableView) {
        registered.add(table)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            noteMouseUp(event)
            return event      // never consumed: this only decides who holds the keyboard next
        }
    }

    static func isRegistered(_ table: NSTableView) -> Bool { registered.contains(table) }


    /// One click's worth: find the pane list it landed in and claim the keyboard for it.
    ///
    /// **Two turns late, deliberately.** The monitor runs ahead of the click's own handling, and
    /// that handling queues work of its own — the other pane's selection clear and the Columns
    /// navigation both go to the next turn, because writing into the window mid-commit drops the
    /// click (`aa9d407`). One hop would put this claim ahead of that queued work; two put it behind,
    /// so the click lands, settles, and only then does focus move. `schedule` is injected so a test
    /// can run the claim without a run loop.
    static func noteMouseUp(
        _ event: NSEvent,
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { work in
            DispatchQueue.main.async { DispatchQueue.main.async { MainActor.assumeIsolated(work) } }
        }
    ) {
        guard let window = event.window, let content = window.contentView else { return }
        let hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
        // A caret took this click; neither route may take the keys off it.
        guard !landedInAnEditableField(hit) else { return }
        // **A hit-test answer is only believed where the click is actually inside that list.**
        // Measured 2026-09-25: a click on the differences list's top rows hit-tests to a PANE row —
        // the pane's table answers for points well outside its own viewport — so the hit route
        // "succeeded" and focused the pane while the reader was looking at the differences list.
        // That is what made the failure positional: lower rows missed the pane's reach and worked.
        let hitTable = target(forHit: hit).flatMap { table in
            visibleRect(of: table).contains(event.locationInWindow) ? table : nil
        }
        guard let table = hitTable
                ?? target(covering: event.locationInWindow, in: window) else { return }
        schedule { claim(table, in: window) }
    }

    /// The registered list whose visible rows cover `pointInWindow`, or nil.
    ///
    /// **The fallback for a list that hit-testing cannot see.** Measured 2026-09-25 in the app: a
    /// click that really does select a row of the differences `Table` reports its hit view as the
    /// window's ROOT hosting view, with no `NSTableView` anywhere in the chain — SwiftUI hosts that
    /// table somewhere `hitTest` does not descend from the content view. The pane lists resolve
    /// normally, so this is not a replacement for the hit-test route but the second question asked
    /// when the first comes back empty.
    ///
    /// Frame containment answers it without the view tree, which is exactly what `PaneListResolver`
    /// does for the stylers. The CLIP view's rect, not the table's: a table is as tall as its rows,
    /// so its own frame reaches far below the scroll view and a click under a short list would
    /// otherwise count. Smallest area wins, so a list inside another surface is preferred to the
    /// surface around it.
    /// Where a list's rows are actually visible, in window coordinates — its scroll view's viewport,
    /// not the table's own frame, which is as tall as its rows.
    static func visibleRect(of table: NSTableView) -> NSRect {
        guard let clip = table.enclosingScrollView?.contentView else { return .zero }
        return clip.convert(clip.bounds, to: nil)
    }

    static func target(covering pointInWindow: NSPoint, in window: NSWindow) -> NSTableView? {
        var best: (table: NSTableView, area: CGFloat)?
        for table in registered.allObjects where table.window === window {
            let visible = visibleRect(of: table)
            guard !visible.isEmpty, visible.contains(pointInWindow) else { continue }
            let area = visible.width * visible.height
            if best == nil || area < best!.area { best = (table, area) }
        }
        return best?.table
    }

    /// Whether the click put a caret in a field. Asked of the hit chain before either route, so a
    /// field the frame fallback knows nothing about still keeps its own click.
    static func landedInAnEditableField(_ hit: NSView?) -> Bool {
        var view = hit
        while let step = view {
            if step is NSText { return true }
            if let field = step as? NSTextField, field.isEditable { return true }
            if step is NSTableView { return false }
            view = step.superview
        }
        return false
    }

    /// The registered list a click on `hit` should focus, or nil.
    ///
    /// **An editable field inside the list keeps the click.** A caret the click put into a text
    /// field is where the keys belong; handing them to the table would end the edit the user just
    /// started. Checked on the way up, before the table is reached, so it holds for any field
    /// embedded in a row however deep.
    static func target(forHit hit: NSView?) -> NSTableView? {
        var view = hit
        while let step = view {
            if step is NSText { return nil }
            if let field = step as? NSTextField, field.isEditable { return nil }
            if let table = step as? NSTableView { return isRegistered(table) ? table : nil }
            view = step.superview
        }
        return nil
    }

    /// Puts a recognizer on a list so its clicks reach the app's event stream at all.
    ///
    /// **It computes nothing, and that is the whole of it.** The differences `Table` handles its
    /// clicks somewhere a local `NSEvent` monitor never sees: with no recognizer on it, clicking a
    /// difference produces no event anywhere in the app, so `noteMouseUp` never runs and the keys
    /// stay with whichever pane was clicked last. Attaching one changes that — measured 2026-09-25
    /// by adding it, removing it, and adding it back, with the same build failing and working in
    /// step. It never recognizes (`false`, always), so the click still belongs entirely to the
    /// table; it is the *presence* of a recognizer that matters, not anything it does.
    ///
    /// **Do not give this a claim of its own.** A version that decided for itself which list a
    /// click belonged to raced the monitor and claimed this table for clicks belonging to a pane,
    /// which read as the fix working intermittently. One claimant: `noteMouseUp`.
    @MainActor
    final class ClickNormalizer: NSObject, NSGestureRecognizerDelegate {
        @discardableResult
        static func install(on table: NSTableView) -> ClickNormalizer {
            let normalizer = ClickNormalizer()
            let recognizer = NSClickGestureRecognizer(target: normalizer, action: #selector(never))
            recognizer.delegate = normalizer
            table.addGestureRecognizer(recognizer)
            return normalizer
        }

        /// Never called: the recognizer is refused before it can recognize.
        @objc private func never(_ sender: Any?) {}

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                               shouldAttemptToRecognizeWith event: NSEvent) -> Bool { false }
    }

    /// Makes `table` first responder unless it — or something inside it — already is.
    ///
    /// The "inside it" half is the same protection as `target(forHit:)`, seen after the fact: a
    /// field editor that took the caret in a row during the click is a descendant of the table, and
    /// stays where it is. `table.window === window` because two turns is long enough for a column to
    /// close under a click that navigated.
    ///
    /// - Returns: whether focus was moved, for the test and the trace.
    @discardableResult
    static func claim(_ table: NSTableView, in window: NSWindow) -> Bool {
        guard table.window === window else { return false }
        if let current = window.firstResponder as? NSView,
           current === table || current.isDescendant(of: table) {
            return false
        }
        return window.makeFirstResponder(table)
    }
}
