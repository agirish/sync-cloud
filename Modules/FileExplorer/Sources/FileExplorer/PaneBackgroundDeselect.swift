import AppKit
import Design
import SwiftUI

/// Makes the empty area of a pane's list a deselect target: clicking below the last row clears the
/// selection, the way it does in Finder and in every other list on this OS.
///
/// The panes had no deselect gesture at all. Escape and the action bar's ✕ were both added to work
/// around that, and neither helps the user who simply clicks off a file expecting it to let go.
///
/// **Why a gesture recognizer and not a SwiftUI tap.** The empty area belongs to AppKit. A
/// `.background` behind the list never receives those clicks — the list's scroll view is opaque to
/// hit-testing — and a `TapGesture` on the list would have to compete with the rows, which is the
/// exact competition that produced the dead clicks (`743d8bd`, `8b85cf4`). A recognizer can decline
/// an event *before* it engages, and a declined event leaves AppKit's own mouse handling completely
/// untouched. That declining is the whole safety argument of this file, which is why
/// `acceptsClick(modifiers:pointInTable:table:)` is separated out and pinned by its own tests.
///
/// **Why the table and not its clip view.** The first draft put the recognizer on the enclosing
/// `NSClipView`, reasoning that a table shorter than its viewport would not receive the clicks
/// below it. Mounting the pane and measuring says otherwise: SwiftUI's table fills its viewport
/// exactly (520pt of table in a 520pt clip view, with three rows in it), so the empty area *is*
/// table. Putting the recognizer there means the click's hit-test view is the recognizer's own
/// view, with no assumption about how far AppKit walks an ancestor chain — and the ancestor
/// question is precisely the kind of thing this file cannot afford to be wrong about, since a
/// recognizer that never fires would be invisible until the user reported it.
///
/// It leaves row clicks doubly protected. A row click hit-tests to an `NSTableRowView` *inside* the
/// table, so it may not consult this recognizer at all; if it does, `acceptsClick` declines it.
///
/// Placed as a zero-size `.background` sibling of the list, exactly like `PaneListSelectionStyler`,
/// whose ancestor walk it reuses wholesale.
struct PaneBackgroundDeselect: NSViewRepresentable {
    /// Runs on a plain click in the list's empty area. Re-supplied on every SwiftUI update, since it
    /// closes over the column depth the click should truncate to.
    let onDeselect: () -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView(onDeselect: onDeselect) }

    /// A SwiftUI update can mean a rebuilt table, so re-arm the search as well as refreshing the
    /// closure.
    func updateNSView(_ view: CatcherView, context: Context) {
        view.onDeselect = onDeselect
        view.rearmSearch()
    }

    /// Whether a click on the list is one this should act on.
    ///
    /// Two refusals, and both matter:
    ///
    ///   - ⌘ and ⇧ are the list's own extend and range-select. Acting on them would collapse a
    ///     multi-selection the moment the pointer missed a row by a pixel — the same flattening
    ///     `dba5cd3` fixed on the row path.
    ///   - A point that resolves to a row is a row click, and this must be invisible to it.
    ///
    /// Split from the delegate so tests can drive it over a synthetic table with a plain point,
    /// rather than fabricating `NSEvent`s against a window a test process cannot make key.
    static func acceptsClick(
        modifiers: NSEvent.ModifierFlags,
        pointInTable: CGPoint,
        table: NSTableView
    ) -> Bool {
        guard PaneViewMode.clickNavigates(modifiers: modifiers) else { return false }
        return table.row(at: pointInTable) == -1
    }

    final class CatcherView: NSView, NSGestureRecognizerDelegate {
        var onDeselect: () -> Void

        private weak var cachedTable: NSTableView?
        /// The table the recognizer currently sits on, so a rebuilt list moves it rather than
        /// accumulating one recognizer per rebuild.
        ///
        /// Typed as the table rather than a bare view because the gate below reads it: it is by
        /// construction the view a click on this recognizer hit-tested to, which `cachedTable` is
        /// not. A resolve that comes up empty — the budget ran out, or the frame matched nothing
        /// mid-rebuild — assigns `cachedTable = nil` while leaving this recognizer installed and
        /// live, and a gate reading `cachedTable` then declined every click until some later pass
        /// happened to re-resolve. Silently, since a recognizer that never fires looks exactly like
        /// a feature nobody built.
        private weak var installedOn: NSTableView?
        private var recognizer: NSClickGestureRecognizer?

        /// Same budget as `PaneListSelectionStyler`: the walk scans up to six ancestor subtrees and
        /// `layout()` runs it every pass, so an unresolvable hierarchy would otherwise burn a full
        /// scan per layout forever.
        private var searchBudget = CatcherView.searchesPerChange
        private static let searchesPerChange = 6

        init(onDeselect: @escaping () -> Void) {
            self.onDeselect = onDeselect
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Uninstalls on the way out of the window, not in `deinit`: a nonisolated `deinit` cannot
        /// touch non-Sendable stored state, and this follows the same rule the column stack's
        /// observers do. Leaving a recognizer behind would be worse than untidy — its target is
        /// unowned, so a click on an orphaned one would call into a deallocated view.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                uninstall()
                cachedTable = nil
            } else {
                rearmSearch()
            }
        }

        override func layout() {
            super.layout()
            apply()
        }

        /// Re-arms after a SwiftUI update, which can mean a rebuilt table.
        ///
        /// The deferred retry is only for the mount, when the list's scroll view may not exist yet.
        /// Once armed, `layout()` re-checks on every pass anyway, so scheduling a block per update
        /// would be per-render main-queue work on a pane whose click cost has been measured more
        /// than once — and there is one of these per column.
        func rearmSearch() {
            searchBudget = Self.searchesPerChange
            guard installedOn == nil else { return }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let table = resolveTableView() else { return }
            guard installedOn !== table else { return }
            uninstall()
            let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
            click.delegate = self
            table.addGestureRecognizer(click)
            recognizer = click
            installedOn = table
        }

        private func uninstall() {
            if let recognizer, let installedOn { installedOn.removeGestureRecognizer(recognizer) }
            recognizer = nil
            installedOn = nil
        }

        @objc private func handleClick(_ sender: NSClickGestureRecognizer) {
            onDeselect()
        }

        /// The gate. Returning false here means the recognizer never engages and the click reaches
        /// the table exactly as it does today.
        ///
        /// Reads `installedOn`, not `cachedTable`: the recognizer is ON that table, so it is the
        /// view this click hit-tested to and the only one whose coordinate space the point below is
        /// meaningful in. See the note on the property for what reading the cache instead cost.
        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            guard let table = installedOn else { return false }
            let point = table.convert(event.locationInWindow, from: nil)
            return PaneBackgroundDeselect.acceptsClick(
                modifiers: event.modifierFlags, pointInTable: point, table: table)
        }

        /// Same rule as `PaneListSelectionStyler`: the frame identifies the list, and a cached
        /// answer is re-validated against it because a drill rebuilds the stack underneath.
        private func resolveTableView() -> NSTableView? {
            guard window != nil else { return nil }
            let target = convert(bounds, to: nil)
            guard !target.isEmpty else { return nil }
            if let cached = cachedTable, cached.window === window,
               PaneListResolver.matches(cached, target: target) { return cached }
            guard searchBudget > 0 else { return nil }
            searchBudget -= 1
            cachedTable = PaneListResolver.table(matching: self)
            return cachedTable
        }
    }
}
