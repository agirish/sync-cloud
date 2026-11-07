import AppKit
import Design
import SwiftUI

/// Makes the empty area of a pane's list a deselect target: clicking below the last row clears the
/// selection, the way it does in Finder and in every other list on this OS.
///
/// A gesture recognizer, not a SwiftUI tap: the empty area belongs to AppKit, a `.background`
/// behind the list never gets those clicks (the scroll view is opaque to hit-testing), and a
/// `TapGesture` on the list would compete with the rows and cause dead clicks. A recognizer can
/// decline an event before it engages, leaving AppKit's mouse handling untouched. That declining
/// is this file's whole safety argument, so `acceptsClick(modifiers:pointInTable:table:)` is
/// separate and pinned by its own tests.
///
/// On the table, not its clip view: SwiftUI's table fills its viewport exactly, so the empty area
/// is table, and the click hit-tests to the recognizer's own view with no assumption about how far
/// AppKit walks an ancestor chain. A row click hit-tests to an `NSTableRowView` inside the table,
/// and if it does reach this recognizer, `acceptsClick` declines it.
///
/// Placed as a zero-size `.background` sibling of the list, like `PaneListSelectionStyler`, whose
/// ancestor walk it reuses.
struct PaneBackgroundDeselect: NSViewRepresentable {
    /// Runs on a plain click in the list's empty area. Re-supplied on every SwiftUI update, since it
    /// closes over the column depth the click should truncate to.
    let onDeselect: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView(onDeselect: onDeselect) }

    /// A SwiftUI update can mean a rebuilt table, so re-arm the search as well as refreshing the
    /// closure.
    func updateNSView(_ view: CatcherView, context: Context) {
        view.onDeselect = onDeselect
        view.rearm()
    }

    /// Whether a click on the list is one this should act on.
    ///
    /// Two refusals:
    ///
    ///   - ⌘ and ⇧ are the list's own extend and range-select; acting on them would collapse a
    ///     multi-selection whenever the pointer missed a row by a pixel.
    ///   - A point that resolves to a row is a row click, and this must be invisible to it.
    ///
    /// Split from the delegate so tests can drive it over a synthetic table with a plain point,
    /// rather than fabricating `NSEvent`s against a window a test process can't make key.
    static func acceptsClick(
        modifiers: NSEvent.ModifierFlags,
        pointInTable: CGPoint,
        table: NSTableView
    ) -> Bool {
        guard PaneViewMode.clickNavigates(modifiers: modifiers) else { return false }
        return table.row(at: pointInTable) == -1
    }

    /// The bounded search and its re-arm ladder are `FrameAnchoredResolveView`'s; this adds the
    /// recognizer install. **Keep the search budget refilled**: a spent one silently stops the
    /// install, and unlike a styler's highlight, a missing recognizer has no visible symptom.
    final class CatcherView: FrameAnchoredResolveView, NSGestureRecognizerDelegate {
        var onDeselect: () -> Void

        /// The table the recognizer currently sits on, so a rebuilt list moves it rather than
        /// accumulating one recognizer per rebuild.
        ///
        /// The gate below reads this, not `cachedTable`: it is by construction the view a click on
        /// this recognizer hit-tested to. A resolve that comes up empty (budget spent, or nothing
        /// matched mid-rebuild) sets `cachedTable = nil` while this recognizer stays live, and a
        /// gate reading the cache would silently decline every click until a later re-resolve.
        private weak var installedOn: NSTableView?
        private var recognizer: NSClickGestureRecognizer?

        init(onDeselect: @escaping () -> Void) {
            self.onDeselect = onDeselect
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Uninstalls on the way out of the window, not in `deinit`, which is nonisolated and
        /// can't touch non-Sendable state. **A recognizer left behind is a crash risk**: its target
        /// is unowned, so a click on an orphan calls into a deallocated view. The cached table is
        /// forgotten too, not trusted again across a window exit.
        override func windowDidExit() {
            uninstall()
            forgetResolvedTable()
        }

        /// Differs from the base's re-arm on purpose: the budget is always refilled, but the
        /// deferred retry is only for the mount, when the scroll view may not exist yet. Once
        /// armed, `layout()` re-checks every pass, so a block per update would be needless
        /// per-render main-queue work, with one of these per column.
        override func rearm() {
            refillSearchBudget()
            guard installedOn == nil else { return }
            DispatchQueue.main.async { [weak self] in self?.resolvePass() }
        }

        override func resolvePass() {
            guard let table = resolveTableView() else { return }
            guard installedOn !== table else { return }
            uninstall()
            let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
            click.delegate = self
            table.addGestureRecognizer(click)
            recognizer = click
            installedOn = table
            // The one place every pane table (Tree, and each column) is already resolved, so the
            // keyboard claim rides on it rather than searching on its own. Not a click behaviour:
            // see `PaneListKeyFocus` for why it is a monitor.
            PaneListKeyFocus.register(table)
        }

        private func uninstall() {
            if let recognizer, let installedOn { installedOn.removeGestureRecognizer(recognizer) }
            recognizer = nil
            installedOn = nil
        }

        @objc private func handleClick(_ sender: NSClickGestureRecognizer) {
            onDeselect()
        }

        /// The gate. Returning false means the recognizer never engages and the click reaches the
        /// table untouched.
        ///
        /// Reads `installedOn`, not `cachedTable`: the recognizer is on that table, so it is the
        /// view this click hit-tested to and the only one whose coordinate space the point is in.
        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            guard let table = installedOn else { return false }
            let point = table.convert(event.locationInWindow, from: nil)
            return PaneBackgroundDeselect.acceptsClick(
                modifiers: event.modifierFlags, pointInTable: point, table: table)
        }

    }
}
