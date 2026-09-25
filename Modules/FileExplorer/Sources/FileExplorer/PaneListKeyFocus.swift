import AppKit
import Events

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
/// **Two parts, and both are needed.** The claim itself reads the app's event stream: one local
/// monitor, which sees clicks on the pane lists and never consumes them. That stream does NOT see
/// clicks on the differences `Table` at all — measured 2026-09-25 — and a gesture recognizer on
/// that table is what puts them into it, which is all `ClickNormalizer` is for. The monitor stays
/// the only claimant either way: a recognizer that decided for itself which list a click belonged
/// to raced the monitor and claimed the wrong one.
@MainActor
enum PaneListKeyFocus {

    /// What the monitor asks for. Named so a test can hold it: the mask is otherwise unreadable once
    /// the monitor exists, and a test that only calls `noteClick` directly would pass with either
    /// button dropped from it.
    static let watchedEvents: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseDown]

    /// The pane lists. Weak, so a column that closes leaves nothing behind to unregister.
    private static let registered = NSHashTable<NSTableView>.weakObjects()
    private static var monitor: Any?

    /// Opts `table` in, and installs the monitor the first time anything does.
    ///
    /// **Left on the UP, right on the DOWN.** A left-drag that rubber-bands a selection should claim
    /// once, when it finishes; the up is that moment. A right-click has no usable up — the context
    /// menu opens on the down and runs a tracking loop that the matching up belongs to — so the down
    /// is the only one to read. The claim is deferred either way, which puts it after the menu.
    static func register(_ table: NSTableView) {
        registered.add(table)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: watchedEvents) { event in
            noteClick(event)
            return event      // never consumed: this only decides who holds the keyboard next
        }
    }

    static func isRegistered(_ table: NSTableView) -> Bool { registered.contains(table) }


    /// One click's worth: find the list it landed in and claim the keyboard for it.
    ///
    /// Right-clicks come here too, so a menu opened on a row leaves the keys on that row's list —
    /// which is what every other Mac list does. The differences list is the exception it cannot help:
    /// `ClickNormalizer` watches the primary button only, so a right-click there reaches no monitor
    /// and changes nothing, exactly as before.
    ///
    /// **Two turns late, deliberately.** The monitor runs ahead of the click's own handling, and
    /// that handling queues work of its own — the other pane's selection clear and the Columns
    /// navigation both go to the next turn, because writing into the window mid-commit drops the
    /// click (`aa9d407`). One hop would put this claim ahead of that queued work; two put it behind,
    /// so the click lands, settles, and only then does focus move. `schedule` is injected so a test
    /// can run the claim without a run loop.
    static func noteClick(
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

    /// Where a list's rows are actually visible, in window coordinates.
    ///
    /// **The scroll view's viewport, not the table's own frame.** A table is as tall as its rows, so
    /// its frame reaches far outside the viewport and a click on whatever sits beyond a long list
    /// would otherwise count as a click in it (measured 2026-09-25 — it is what let a pane answer
    /// for clicks on the list below it). A table with no scroll view around it is its own viewport;
    /// answering `.zero` there would make such a list permanently unclaimable, since both routes
    /// test containment.
    static func visibleRect(of table: NSTableView) -> NSRect {
        guard let clip = table.enclosingScrollView?.contentView else {
            return table.convert(table.bounds, to: nil)
        }
        return clip.convert(clip.bounds, to: nil)
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
    /// Frame containment answers it without the view tree, which is what `PaneListResolver` does for
    /// the stylers. Smallest area wins, so a list inside another surface is preferred to the surface
    /// around it.
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

    /// The registered list a click on `hit` landed in, or nil.
    ///
    /// **The caret rule is not repeated here.** It used to be, and two copies of one rule are two
    /// places to keep in step; `noteMouseUp` asks `landedInAnEditableField` before either route, so
    /// a hit inside a field never reaches this.
    static func target(forHit hit: NSView?) -> NSTableView? {
        var view = hit
        while let step = view {
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
    /// **It belongs to the table, and that is what makes it safe.** A recognizer's delegate is weak
    /// and its target unowned, so a normalizer released while its recognizer stayed on a live table
    /// would leave a recognizer nothing refuses — free to recognize clicks and to send its action to
    /// freed memory. That is the hazard `PaneBackgroundDeselect` documents for its own recognizer,
    /// and it is closed here by making the recognizer RETAIN this object: both then live exactly as
    /// long as the table they are on, and nothing has to remember to take them back.
    ///
    /// **Two attempts at that ownership were worse, and are recorded so they are not retried.**
    /// Holding the normalizer in the styler and installing per instance stacked a recognizer on the
    /// table for every SwiftUI rebuild. Making `install` idempotent fixed the stacking but let two
    /// stylers share one normalizer, and then the first of them to leave the window uninstalled the
    /// recognizer the other was still relying on — measured, as a mounted view carrying none.
    @MainActor
    final class ClickNormalizer: NSObject, NSGestureRecognizerDelegate {
        private static var associationKey: UInt8 = 0

        /// Installs one, or returns the one this table already has.
        @discardableResult
        static func install(on table: NSTableView) -> ClickNormalizer {
            if let existing = table.gestureRecognizers
                .compactMap({ $0.delegate as? ClickNormalizer }).first {
                return existing
            }
            let normalizer = ClickNormalizer()
            let recognizer = NSClickGestureRecognizer(target: normalizer, action: #selector(never))
            recognizer.delegate = normalizer
            table.addGestureRecognizer(recognizer)
            // The retain that closes the orphan hazard: `delegate` and `target` are both non-owning,
            // so without this the normalizer's only owner would be whoever called `install`.
            objc_setAssociatedObject(recognizer, &associationKey, normalizer,
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return normalizer
        }

        /// How many a table is carrying — for the test that no rebuild stacks them.
        static func count(on table: NSTableView) -> Int {
            table.gestureRecognizers.filter { $0.delegate is ClickNormalizer }.count
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
        let moved = window.makeFirstResponder(table)
        // Ungated, like `[click]` and `[deselect]`: one line per click that actually MOVES focus,
        // which is the decision every keystroke after it depends on. The `[fr]` line in
        // `MouseDownProbe` says the same thing but only while the scroll trace is armed, and the
        // reports this file exists for arrive with it off.
        if moved { Logger.shared.debug("[focus] the keyboard moved to a list that was clicked") }
        return moved
    }
}
