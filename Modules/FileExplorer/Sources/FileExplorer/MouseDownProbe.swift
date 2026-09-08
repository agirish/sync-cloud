import AppKit
import Events
import SwiftUI

/// One log line per left-click, naming the view the click actually lands on.
///
/// **The instrument the dead-click investigations have never had.** Every probe before this one
/// reports from *inside* a handler — `[tap]` from the row's gesture, `[sel]` from the List's
/// selection commit, `[click]` from `applySelectionWrite` — so all of them are silent about the
/// clicks that matter most: the ones no handler ever runs for. A session on 2026-09-08 logged
/// **two** interactions across a minute of clicking the user described as "lots of dead clicks",
/// with `press→settled` at 65ms and the main thread 22% busy. Nothing was slow; the clicks simply
/// were not arriving, and no existing line could say where they went.
///
/// This sits ahead of all of them, on the app's own event stream, so a click that dies in
/// hit-testing still leaves a record: which window, which view, and whether that view resolves to
/// a row of a table. A decoration that swallows clicks — the failure `6be489e1` fixed once for the
/// pane's spinner, and that `DifferencesTableSelectionStyler.SelectionWashView.hitTest` returns
/// `nil` to prevent — shows up here as a click whose hit-test view is that decoration and whose
/// row is `-1`, beside a working click on the same row that reports an `NSTableRowView`.
///
/// **Read-only, and deliberately so.** The monitor returns the event unchanged, so it cannot itself
/// become a suspect: a probe that consumed or delayed clicks would be indistinguishable from the
/// bug it was installed to find. That is the same discipline `PaneBackgroundDeselect` documents for
/// its recognizer, applied to an instrument rather than a feature.
///
/// Gated on `PaneScrollTrace.isEnabled` like the rest of the click stamps — one line per click is
/// cheap next to the travel trace, but the log is trimmed at ~5 MB and an always-on probe would
/// spend that budget on clicks instead of on sync runs and errors.
@MainActor
public enum MouseDownProbe {
    private static var monitor: Any?

    /// Drag events seen since the last mouse-down. A down/up pair with drags between it is a drag
    /// to AppKit, not a click — and a hand that moves a pixel while pressing produces exactly that.
    private static var dragsSinceDown = 0

    /// Installs the monitor. No-op unless the trace is armed, and idempotent because `App.init`
    /// can be re-run by SwiftUI — a second monitor would double every line and quietly halve the
    /// value of a count.
    public static func arm() {
        guard PaneScrollTrace.isEnabled, monitor == nil else { return }
        // **Both halves of the click, and dragged too.** Watching only the DOWN is what let this
        // investigation run six rounds without noticing the real asymmetry: `NSTableView` commits
        // some selections on mouse-down but defers others to mouse-UP so it can tell a click from
        // the start of a drag — a ⌘-click on an already-selected row is exactly such a case — and
        // `TapGesture` needs the up as well. A lost up is therefore invisible on the down, and
        // presents as a table that simply declines to select.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        ) { event in
            report(event)
            return event      // never consume: see the class doc
        }
        Logger.shared.debug(
            "[hit] mouse-down probe ARMED — one line per left-click naming the view it lands on "
            + "(docs/columns-layout-loop.md)")
    }

    /// The line itself. Everything it prints is read off the event and the view tree; it mutates
    /// nothing, so an armed session differs from an unarmed one only by the log.
    private static func report(_ event: NSEvent) {
        guard let window = event.window else {
            // A click with no window never reached a view at all — worth its own line, because it
            // is indistinguishable from "nothing happened" everywhere else.
            Logger.shared.debug("[hit] click with NO window — the event reached no view")
            return
        }
        guard let content = window.contentView else {
            Logger.shared.debug("[hit] window \(window.windowNumber) has no content view")
            return
        }
        let inContent = content.convert(event.locationInWindow, from: nil)
        let hit = content.hitTest(inContent)
        let mods = describe(event.modifierFlags)
        let where_ = row(for: hit, event: event)
        switch event.type {
        case .leftMouseDragged:
            // Counted, not described: a drag between a down and its up is what makes AppKit treat
            // the sequence as a drag rather than a click, and it is the one thing that would
            // explain a table declining to select without anything having consumed the up. One
            // line per drag would drown the file, so only the tally that follows the up is kept.
            dragsSinceDown += 1
        case .leftMouseUp:
            Logger.shared.debug(
                "[hit] UP   w\(window.windowNumber) \(mods)click\(event.clickCount) "
                + "after \(dragsSinceDown) drag(s) | \(where_)")
            dragsSinceDown = 0
        default:
            dragsSinceDown = 0
            Logger.shared.debug(
                "[hit] DOWN w\(window.windowNumber) \(mods)click\(event.clickCount) → \(ancestry(of: hit)) | \(where_)")
        }
    }

    /// The hit view and up to three ancestors, innermost first. Three because the interesting
    /// answer is usually "an `NSTableRowView` two hops up" versus "a decoration with no row above
    /// it at all", and both are visible at that depth without turning one click into a paragraph.
    private static func ancestry(of view: NSView?) -> String {
        guard var v = view else { return "NOTHING (hitTest returned nil)" }
        var names = [String(describing: type(of: v))]
        for _ in 0..<3 {
            guard let parent = v.superview else { break }
            names.append(String(describing: type(of: parent)))
            v = parent
        }
        return names.joined(separator: " ← ")
    }

    /// Whether the click resolves to a row of an enclosing table, which is what decides if the
    /// List can select from it. `-1` beside a real row index on the same list is the tell.
    private static func row(for view: NSView?, event: NSEvent) -> String {
        var v = view
        while let current = v {
            if let table = current as? NSTableView {
                let point = table.convert(event.locationInWindow, from: nil)
                let index = table.row(at: point)
                let place = index == -1 ? "NO row at that point" : "row \(index)"
                // **What the TABLE believes, at the instant of the click.** Everything else in this
                // investigation reports what happened *after* a handler ran, so all of it is blind
                // to a click the table answers by deciding nothing changed. `NSTableView` computes
                // a ⌘-click as "current selection toggled at this row" and hands SwiftUI the
                // result; if that result equals what the binding already holds, the setter is never
                // called and the click is silent — indistinguishable, in every other line, from an
                // event that never arrived.
                //
                // So print the table's own selection and its identity. The identity matters because
                // a Columns pane has one table PER COLUMN, each with its own binding writing the
                // pane's selection wholesale — and no line so far has ever said which of them a
                // click landed in.
                let selected = table.selectedRowIndexes
                let shown = selected.prefix(12).map(String.init).joined(separator: ",")
                let more = selected.count > 12 ? "…+\(selected.count - 12)" : ""
                let alreadyOn = index != -1 && selected.contains(index)
                return "t\(UInt(bitPattern: ObjectIdentifier(table).hashValue) % 10000) "
                    + "\(place) of \(table.numberOfRows) | table sel [\(shown)\(more)] "
                    + "(\(selected.count)) | clicked row \(alreadyOn ? "ALREADY selected" : "not selected")"
            }
            v = current.superview
        }
        return "no enclosing table"
    }

    private static func describe(_ flags: NSEvent.ModifierFlags) -> String {
        var parts = ""
        if flags.contains(.command) { parts += "⌘" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.control) { parts += "⌃" }
        return parts.isEmpty ? "" : parts + " "
    }
}
