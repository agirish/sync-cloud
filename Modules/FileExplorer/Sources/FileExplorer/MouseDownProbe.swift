import AppKit
import Events
import SwiftUI

/// One log line per left-click, naming the view the click actually lands on.
///
/// Every other click probe reports from inside a handler (`[tap]`, `[sel]`, `[click]`), so all of
/// them are silent about a click no handler runs for. This sits ahead of them on the app's event
/// stream, so a click that dies in hit-testing still leaves a record: which window, which view, and
/// whether that view resolves to a table row. A decoration that swallows clicks (the reason
/// `DifferencesTableSelectionStyler.SelectionWashView.hitTest` returns `nil`) shows up as a click
/// whose hit view is that decoration and whose row is `-1`.
///
/// Read-only: the monitor returns the event unchanged, so the probe can't become a suspect itself.
/// A probe that consumed or delayed clicks would look exactly like the bug it is looking for.
///
/// Gated on `PaneScrollTrace.isEnabled` like the other click stamps: the log is trimmed at ~5 MB,
/// and an always-on probe would spend that budget on clicks instead of sync runs and errors.
@MainActor
public enum MouseDownProbe {
    private static var monitor: Any?

    /// Drag events seen since the last mouse-down. A down/up pair with drags between is a drag to
    /// AppKit, not a click, and a hand that moves a pixel while pressing produces exactly that.
    private static var dragsSinceDown = 0

    /// Installs the monitor. No-op unless the trace is armed, and idempotent because SwiftUI can
    /// re-run `App.init`; a second monitor would double every line.
    public static func arm() {
        guard PaneScrollTrace.isEnabled, monitor == nil else { return }
        // Both halves of the click, plus drags. `NSTableView` commits some selections on the
        // down but defers others to the up, to tell a click from a drag (a ⌘-click on a selected
        // row, say), and `TapGesture` needs the up too. A lost up is invisible on the down and
        // looks like a table that declines to select.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown]
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
        // Keys, and the responder they reached. A key delivered to the wrong responder runs no
        // handler, so it is as invisible as a dead click; this names who got it.
        if event.type == .keyDown {
            let window = event.window ?? NSApp.keyWindow
            Logger.shared.debug(
                "[key] w\(window?.windowNumber ?? -1) \(describe(event.modifierFlags))"
                + "\(named(event.keyCode)) → firstResponder \(responder(window))")
            return
        }
        guard let window = event.window else {
            // A click with no window never reached a view; nowhere else would show it.
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
            // Counted, not described: drags between a down and its up make AppKit treat the
            // sequence as a drag, which would explain a table declining to select. One line per
            // drag would drown the log, so only the tally on the up is kept.
            dragsSinceDown += 1
        case .leftMouseUp:
            Logger.shared.debug(
                "[hit] UP   w\(window.windowNumber) \(mods)click\(event.clickCount) "
                + "after \(dragsSinceDown) drag(s) | \(where_) | fr \(responder(window))")
            dragsSinceDown = 0
            // Asked again a beat later, because this monitor runs ahead of the click: the `fr`
            // above is the focus the click inherited, not the focus it produced.
            checkFocusAfterTheClick(in: window, landedInTable: isInTable(hit))
        default:
            dragsSinceDown = 0
            Logger.shared.debug(
                "[hit] DOWN w\(window.windowNumber) \(mods)click\(event.clickCount) → \(ancestry(of: hit)) | \(where_) | fr \(responder(window))")
        }
    }

    /// Who holds the keyboard a beat after a click: the line that says whether
    /// `PaneListKeyFocus` did its job. A row click should read as that list's table. 300ms is well
    /// past the claim's two-turn deferral, so a line still naming the window is a claim that didn't
    /// happen.
    private static func checkFocusAfterTheClick(in window: NSWindow, landedInTable: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                _ = Logger.shared.debug(
                    "[fr] 300ms after a click \(landedInTable ? "in a table" : "outside any table"): "
                    + "\(responder(window))")
            }
        }
    }

    /// The key, named only where naming it is diagnostic; everything else is "a key". The trace may
    /// be left on through ordinary typing, and printing every key code would make
    /// `~/sync-cloud.log` a record of what was typed. The navigation keys are the ones a focus
    /// investigation needs, and none carries content.
    private static func named(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 36, 76: return "return"
        case 48: return "tab"
        case 49: return "space"
        case 51: return "delete"
        case 53: return "esc"
        case 116, 121: return "page up/down"
        case 115, 119: return "home/end"
        default: return "a key"
        }
    }

    /// Whether `view` sits in a table — the same walk `row(for:event:)` makes, without the report.
    private static func isInTable(_ view: NSView?) -> Bool {
        var current = view
        while let step = current {
            if step is NSTableView { return true }
            current = step.superview
        }
        return false
    }

    /// Who holds keyboard focus, and whether that responder sits inside one of the pane's tables.
    /// A `List` whose table isn't first responder gets no arrow keys, which no other line here can
    /// tell apart from a table that got them and declined.
    private static func responder(_ window: NSWindow?) -> String {
        guard let window else { return "NO WINDOW" }
        guard let responder = window.firstResponder else { return "NOBODY" }
        if responder === window { return "the WINDOW itself — no view holds focus" }
        var name = String(describing: type(of: responder))
        if let view = responder as? NSView {
            var current: NSView? = view
            while let step = current {
                if let table = step as? NSTableView {
                    name += step === view ? " (IS a table t\(shortID(table)))"
                                          : " (inside table t\(shortID(table)))"
                    break
                }
                current = step.superview
            }
        }
        return name
    }

    /// The same short table identity the `[hit]` lines print, so the two can be read together.
    private static func shortID(_ table: NSTableView) -> String {
        String(UInt(bitPattern: ObjectIdentifier(table).hashValue) % 10000)
    }

    /// The hit view and up to three ancestors, innermost first. Three is enough to tell "an
    /// `NSTableRowView` two hops up" from "a decoration with no row above it" without turning one
    /// click into a paragraph.
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
                // What the table believes at the instant of the click. `NSTableView` computes a
                // ⌘-click as "selection toggled at this row" and hands SwiftUI the result; if that
                // equals what the binding already holds, the setter never runs and the click is
                // silent, like an event that never arrived. The table's identity matters because a
                // Columns pane has one table per column, each writing the pane's selection.
                let selected = table.selectedRowIndexes
                let shown = selected.prefix(12).map(String.init).joined(separator: ",")
                let more = selected.count > 12 ? "…+\(selected.count - 12)" : ""
                let alreadyOn = index != -1 && selected.contains(index)
                return "t\(shortID(table)) "
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
