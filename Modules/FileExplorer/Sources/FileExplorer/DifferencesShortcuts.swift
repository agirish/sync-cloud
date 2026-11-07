import SwiftUI
import Sync

// MARK: - Differences shortcuts

// The differences header's shortcut-reachable actions, published to the App scope for its menu
// items (⇧⌘R Review, ⇧⌘V Verify, ⇧⌘F fold). The keys live here because `DifferencesView`
// publishes them: the availability rules are its state, so the menu's enabled state and the
// button's visibility answer to the same facts.
//
// Closures, not bindings: each fires a method on the view, and none is state a menu could own.
// `nil` means "not available now", which the menu items draw disabled, as with `beginPaneSearch`.

/// What ⇧⌘F would do right now (collapse or expand), plus the closure that does it. A pair, so the
/// menu item's title and its effect come from one `FoldAllAction` resolution, as the header's own
/// toggle does.
public struct FoldAllShortcut {
    public let action: FoldAllAction
    public let run: () -> Void

    public init(action: FoldAllAction, run: @escaping () -> Void) {
        self.action = action
        self.run = run
    }
}

/// The four directional transfers (⌘← / ⌘→ copy, ⇧ makes it a move) as one value, as with
/// `cycleTab`: they are available together, and four focused values could disagree about the
/// selection they all act on.
///
/// **`run` must resolve its rows when it fires, never when it is published.** A focused value
/// isn't re-armed while a menu is open (see `DeleteSelectionCommand`), so captured rows could
/// carry a stale `action` from a bulk sync underneath straight to `syncFile`/`syncAll`. So
/// `keyboardCopy` takes no rows and reads `displayRows.sorted` itself at fire time.
public struct TransferShortcut {
    /// Runs one of the four. The direction and the move flag are the item's, not the value's.
    public let run: (FileDifference.SyncAction, Bool) -> Void
    /// What the items say instead of "Left"/"Right": the provider names, so the menu reads
    /// "Copy to Dropbox" like every other transfer surface.
    public let leftName: String
    public let rightName: String

    public init(leftName: String, rightName: String,
                run: @escaping (FileDifference.SyncAction, Bool) -> Void) {
        self.leftName = leftName
        self.rightName = rightName
        self.run = run
    }
}

/// The availability rules behind the four published values, pure so tests can hold them (a
/// `.focusedSceneValue` can't be read without a scene). Each parameter has a state that flips the
/// answer, so tests can catch the view passing it wrong.
enum DifferencesShortcutRules {
    /// ⇧⌘R: no session already running, something to review, no sync blocking actions, and no
    /// destination pick in flight. Collapse doesn't gate it: starting a review expands the pane
    /// by `isCollapsedToHeaderStrip`'s own override.
    static func reviewAvailable(sessionActive: Bool, targetCount: Int,
                                blocked: Bool, suspended: Bool) -> Bool {
        !sessionActive && targetCount > 0 && !blocked && !suspended
    }

    /// ⇧⌘V: Review's rule over the verifiable subset, plus a collapse gate, because a verify run's
    /// progress strip draws inside the pane and would be hidden under a header strip.
    static func verifyAvailable(sessionActive: Bool, verifiableCount: Int,
                                blocked: Bool, collapsed: Bool, suspended: Bool) -> Bool {
        !sessionActive && verifiableCount > 0 && !blocked && !collapsed && !suspended
    }

    /// ⇧⌘F: the table must be on screen (no session owning the pane, not collapsed to the header
    /// strip) and sectioned, the same conditions as the header's toggle.
    static func foldAvailable(sessionActive: Bool, collapsed: Bool,
                              sectionCount: Int, suspended: Bool) -> Bool {
        !sessionActive && !collapsed && sectionCount > 0 && !suspended
    }

    /// The rows a directional transfer acts on: the selection, in this direction, and nothing
    /// else.
    ///
    /// **Never fall back to the whole filtered set**, as ``DifferenceActionTargets`` does for the
    /// header buttons: ⌘→ over a stale selection would transfer every differing file with nothing
    /// on screen saying so. Keep the two resolvers separate.
    ///
    /// A held row (`FileDifference.heldBack`) is left out of a selection of more than one, as the
    /// header leaves it out (`DifferenceActionTargets.transferItems`), since `syncFile` copies
    /// whatever it is given. Selected alone, it is copied the way its guess points (a link source
    /// is refused by `syncFile`); the row's right-click menu copies it either way
    /// (`DifferenceRowMenu.copyDirections`). "Alone" means one selected id, not one surviving row.
    ///
    /// - Parameter rows: the visible rows as of the moment the chord fires, never a snapshot
    ///   taken when the shortcut was published. See ``TransferShortcut``.
    static func transferItems(rows: [FileDifference],
                              selection: Set<FileDifference.ID>,
                              direction: FileDifference.SyncAction) -> [FileDifference] {
        guard !selection.isEmpty else { return [] }
        let pickedAlone = selection.count == 1
        return rows.filter {
            selection.contains($0.id) && $0.action == direction && (pickedAlone || $0.heldBack == nil)
        }
    }

    /// The held rows ``transferItems(rows:selection:direction:)`` leaves out of a selection of more
    /// than one, in that direction, handed to the run so its banner says how many were left out
    /// and why. Empty for a held row picked alone, which `transferItems` sends.
    static func heldItems(rows: [FileDifference],
                          selection: Set<FileDifference.ID>,
                          direction: FileDifference.SyncAction) -> [FileDifference] {
        guard selection.count > 1 else { return [] }
        return rows.filter { selection.contains($0.id) && $0.action == direction && $0.heldBack != nil }
    }

    /// The live rows for a set of ids, in the rows' own order: the direction-blind half of
    /// ``transferItems(rows:selection:direction:)``. A menu item holds ids and reads values only
    /// when it fires, because an NSMenu outlives the table state it was built from.
    ///
    /// Empty when nothing matches: a full rescan mints new `FileDifference.id`s, so the rows the
    /// user pointed at are no longer there.
    static func rows(_ rows: [FileDifference],
                     matching ids: Set<FileDifference.ID>) -> [FileDifference] {
        guard !ids.isEmpty else { return [] }
        return rows.filter { ids.contains($0.id) }
    }

    /// ⌘← / ⌘→ / ⇧⌘← / ⇧⌘→: rows selected in the differences table, and that table is the surface
    /// the selection belongs to.
    ///
    /// `surface` stands in for focus: a menu item's chord is window-level, so "does ⌘→ mean these
    /// rows?" is answered by `lastSelectionSurface`, as for Space and Quick Look, since both panes
    /// and the table can hold a selection at once. ⌘→ typed in a text field is left to the editor
    /// by `chordBelongsToTextEditor` at the menu item.
    ///
    /// A review session owns the keyboard while it runs (its card reads plain ⌫ and ↩), and a
    /// blocking sync means no transfer may start: the same two gates Review and Verify carry.
    static func transferAvailable(selectionCount: Int, surface: SelectionSurface?,
                                  sessionActive: Bool, blocked: Bool, suspended: Bool) -> Bool {
        selectionCount > 0 && surface == .differences && !sessionActive && !blocked && !suspended
    }
}

private struct StartDifferencesReviewKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct VerifyDifferencesKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct FoldAllDifferencesKey: FocusedValueKey {
    typealias Value = FoldAllShortcut
}

private struct TransferSelectionKey: FocusedValueKey {
    typealias Value = TransferShortcut
}

public extension FocusedValues {
    /// Starts a guided review over the current targets. `nil` while a review is already running,
    /// while a sync blocks actions, or when there is nothing to review.
    var startDifferencesReview: (() -> Void)? {
        get { self[StartDifferencesReviewKey.self] }
        set { self[StartDifferencesReviewKey.self] = newValue }
    }

    /// Checksums the verifiable (same-size, date-only) differences. `nil` when none qualify.
    var verifyDifferences: (() -> Void)? {
        get { self[VerifyDifferencesKey.self] }
        set { self[VerifyDifferencesKey.self] = newValue }
    }

    /// Collapses or expands every folder section, by the master disclosure's next-click rule.
    /// `nil` when the table is not sectioned or the list is not showing.
    var foldAllDifferences: FoldAllShortcut? {
        get { self[FoldAllDifferencesKey.self] }
        set { self[FoldAllDifferencesKey.self] = newValue }
    }

    /// Copy or move the differences selection across. `nil` when the table holds nothing, when the
    /// panes hold the selection instead, or while a review or a sync owns the keyboard.
    var transferSelection: TransferShortcut? {
        get { self[TransferSelectionKey.self] }
        set { self[TransferSelectionKey.self] = newValue }
    }
}
