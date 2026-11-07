import AppKit
import Events

/// Gives a pane's list the keyboard when a click lands in it.
///
/// SwiftUI doesn't, on macOS 27: a click on a `List` row selects it but leaves the window as first
/// responder, so every key after it (arrows, ⇧↑, ⌫ for `.onDeleteCommand`, type-select) reaches
/// the window and is dropped. A stock `List(selection:)` in a bare app does the same, so the pane
/// has to claim the keyboard.
///
/// Scoped to registered tables, the pane lists: other surfaces decide focus themselves (the review
/// card sends focus back from its table), and an app-wide rule would fight them. A list opts in
/// through `register(_:)`, which `PaneBackgroundDeselect` calls since it already resolves every
/// pane table (Tree, and each column of Columns).
///
/// Two parts, both needed. One local monitor reads clicks and never consumes them. It sees no
/// clicks on the differences `Table` unless a gesture recognizer is on it, which is all
/// `ClickNormalizer` is for. The monitor stays the only claimant: a recognizer that claimed for
/// itself would race it and pick the wrong list.
@MainActor
enum PaneListKeyFocus {

    /// What the monitor asks for, named so a test can check it: a test calling `noteClick` directly
    /// would pass with either button dropped from the mask.
    static let watchedEvents: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseDown]

    /// The pane lists. Weak, so a column that closes leaves nothing behind to unregister.
    private static let registered = NSHashTable<NSTableView>.weakObjects()
    private static var monitor: Any?

    /// Opts `table` in, and installs the monitor the first time anything does.
    ///
    /// Left on the up, right on the down. A rubber-band drag should claim once, when it ends. A
    /// right-click has no usable up: the menu opens on the down and its tracking loop owns the up.
    /// The claim is deferred either way, which puts it after the menu.
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
    /// Right-clicks come here too, so a menu opened on a row leaves the keys on that row's list, as
    /// in every Mac list. Not on the differences list: `ClickNormalizer` watches the primary button
    /// only, so a right-click there reaches no monitor.
    ///
    /// Two turns late, deliberately. The click's own handling queues work for the next turn (the
    /// other pane's selection clear, the Columns navigation), since writing into the window
    /// mid-commit drops the click. One hop would land ahead of that work; two land behind it.
    /// `schedule` is injected so a test can run the claim without a run loop.
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
        // Believe a hit-test only inside that list's visible rows: a pane's table answers for
        // points outside its viewport, so a click on the differences list's top rows would focus
        // the pane.
        let hitTable = target(forHit: hit).flatMap { table in
            visibleRect(of: table).contains(event.locationInWindow) ? table : nil
        }
        guard let table = hitTable
                ?? target(covering: event.locationInWindow, in: window) else { return }
        schedule { claim(table, in: window) }
    }

    /// Where a list's rows are actually visible, in window coordinates.
    ///
    /// The scroll view's viewport, not the table's frame, which is as tall as its rows and would
    /// claim clicks on whatever sits beyond a long list. A table with no scroll view is its own
    /// viewport; `.zero` would make it unclaimable, since both routes test containment.
    static func visibleRect(of table: NSTableView) -> NSRect {
        guard let clip = table.enclosingScrollView?.contentView else {
            return table.convert(table.bounds, to: nil)
        }
        return clip.convert(clip.bounds, to: nil)
    }

    /// The registered list whose visible rows cover `pointInWindow`, or nil.
    ///
    /// The fallback when hit-testing finds no list: a click on the differences `Table` hit-tests to
    /// the window's root hosting view, with no `NSTableView` in the chain. Frame containment answers
    /// without the view tree, as `PaneListResolver` does. Smallest area wins, so a list inside
    /// another surface beats the surface around it.
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
    /// The caret rule isn't repeated here: `noteClick` asks `landedInAnEditableField` before either
    /// route, so a hit inside a field never reaches this.
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
    /// It computes nothing. The differences `Table` handles clicks where a local `NSEvent` monitor
    /// never sees them; with a recognizer on it, they reach the stream and `noteClick` runs. It never
    /// recognizes (`false`, always), so the click still belongs to the table: only its presence
    /// matters.
    ///
    /// **Don't** give it a claim of its own: it would race the monitor and claim this table for
    /// clicks on a pane. One claimant: `noteClick`.
    ///
    /// The recognizer retains this object, so both live exactly as long as their table. A
    /// recognizer's delegate is weak and its target unowned, so a released normalizer would leave a
    /// recognizer nothing refuses, sending its action to freed memory (the hazard
    /// `PaneBackgroundDeselect` notes for its own). Owning it elsewhere fails too: per-instance
    /// installs stack a recognizer per SwiftUI rebuild, and a shared one gets uninstalled by the
    /// first owner to leave the window.
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
            // The retain that closes the orphan hazard: `delegate` and `target` are both
            // non-owning.
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
    /// "Inside it" covers a field editor that took the caret in a row during the click: it is a
    /// descendant of the table and keeps focus. `table.window === window` because two turns is long
    /// enough for a column to close under a click that navigated.
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
        // Ungated, like `[click]` and `[deselect]`: one line per click that moves focus, which
        // every later keystroke depends on. `MouseDownProbe`'s `[fr]` line logs only while the
        // scroll trace is armed.
        if moved { Logger.shared.debug("[focus] the keyboard moved to a list that was clicked") }
        return moved
    }
}
