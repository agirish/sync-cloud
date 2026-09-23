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
        guard let table = target(forHit: hit) else { return }
        schedule { claim(table, in: window) }
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
