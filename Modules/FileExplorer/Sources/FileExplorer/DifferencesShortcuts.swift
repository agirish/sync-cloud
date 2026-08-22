import SwiftUI
import Sync

// MARK: - Differences shortcuts

// The differences header's shortcut-reachable actions, published to the App scope so its menu
// items (⇧⌘R Review, ⇧⌘V Verify, ⇧⌘F fold) can reach them. The keys live here rather than in the
// app target because `DifferencesView` is the publisher: the availability rules (a live session,
// an empty target set, a sync in flight) are its state, and publishing from the view keeps the
// menu's enabled-ness and the button's visibility answering to the same facts.
//
// Closures rather than a binding: every one of these fires a method that already exists on the
// view; none of them is state a menu could own. `nil` means "not available right now", which the
// menu items render as disabled — the same contract `beginPaneSearch` established.

/// What ⇧⌘F would do right now — collapse or expand — plus the closure that does it.
///
/// Carried as a pair so the menu item's title and its effect come from the same `FoldAllAction`
/// resolution, the rule the header's own toggle follows ("the tooltip and the announced name can
/// never describe different clicks").
public struct FoldAllShortcut {
    public let action: FoldAllAction
    public let run: () -> Void

    public init(action: FoldAllAction, run: @escaping () -> Void) {
        self.action = action
        self.run = run
    }
}

/// The four directional transfers — ⌘← / ⌘→ copy, ⇧ makes it a move — as one value.
///
/// **One value for four items, not four**, on `cycleTab`'s argument: they are available together
/// and unavailable together, so four focused values would be four chances for two of them to
/// disagree about a selection they all act on.
///
/// **`run` must resolve its rows when it FIRES, not when it is published**, and the first cut did
/// not: it closed over the `sorted` array `body` had just computed, so the closure held that exact
/// snapshot for as long as the focused value lived. A focused value is not re-armed while a menu is
/// open — the rule `DeleteSelectionCommand` and the clipboard both record — so a bulk sync running
/// underneath an open Compare menu left ⌘→ holding `FileDifference` values whose `action` had since
/// changed, and `runCopyOrMove` hands those values straight to `syncFile`/`syncAll`. Stale values
/// reaching a real file operation is the whole hazard.
///
/// It is unrepresentable now rather than merely fixed: `keyboardCopy` takes no rows at all and reads
/// `displayRows.sorted` itself, alongside the `selection` and `isSyncActionBlocked` it was already
/// reading at fire time. The captured parameter was the odd one out in its own body.
public struct TransferShortcut {
    /// Runs one of the four. The direction and the move flag are the item's, not the value's.
    public let run: (FileDifference.SyncAction, Bool) -> Void
    /// What the items say instead of "Left"/"Right" — the provider names, so the menu reads
    /// "Copy to Dropbox" like every other transfer surface in the app rather than naming a side
    /// the user has to translate.
    public let leftName: String
    public let rightName: String

    public init(leftName: String, rightName: String,
                run: @escaping (FileDifference.SyncAction, Bool) -> Void) {
        self.leftName = leftName
        self.rightName = rightName
        self.run = run
    }
}

/// The availability rules behind the four published values, pure so they can be held by tests
/// (a `.focusedSceneValue` cannot be read without a scene). Each parameter exists because some
/// state of it must flip the answer; a parameter no test can flip is one the view stopped
/// passing correctly without anything failing.
enum DifferencesShortcutRules {
    /// ⇧⌘R: no session already running, something to review, no sync blocking actions, and no
    /// destination pick in flight. Collapse does NOT gate it — starting a review expands the
    /// pane by `isCollapsedToHeaderStrip`'s own override.
    static func reviewAvailable(sessionActive: Bool, targetCount: Int,
                                blocked: Bool, suspended: Bool) -> Bool {
        !sessionActive && targetCount > 0 && !blocked && !suspended
    }

    /// ⇧⌘V: the review shape over the verifiable subset — plus the collapse gate Review
    /// deliberately lacks. A verify run's progress strip renders inside the pane; started while
    /// the pane is a header strip, it is a background operation with its feedback hidden. (A
    /// review has no such problem: starting one re-opens the pane by
    /// `isCollapsedToHeaderStrip`'s own override, so `collapsed` would be a vacuous gate.)
    static func verifyAvailable(sessionActive: Bool, verifiableCount: Int,
                                blocked: Bool, collapsed: Bool, suspended: Bool) -> Bool {
        !sessionActive && verifiableCount > 0 && !blocked && !collapsed && !suspended
    }

    /// ⇧⌘F: the table must be on screen (no session owning the pane, not collapsed to the
    /// header strip) and sectioned — the same absences that withhold the header's toggle.
    static func foldAvailable(sessionActive: Bool, collapsed: Bool,
                              sectionCount: Int, suspended: Bool) -> Bool {
        !sessionActive && !collapsed && sectionCount > 0 && !suspended
    }

    /// The rows a directional transfer acts on: **the selection, in this direction, and nothing
    /// else.**
    ///
    /// **The absent fallback is the whole point of this being its own rule.**
    /// ``DifferenceActionTargets`` — the header buttons' resolver — deliberately falls back to the
    /// entire filtered set when a selection resolves to no visible row, so the buttons stay
    /// actionable after a rescan mints new ids. That is right for a button whose label counts what
    /// it will do, and catastrophic for a chord: ⌘→ pressed over a selection that has gone stale
    /// would transfer *every* differing file, with nothing on screen having said so.
    ///
    /// So the two resolvers stay two, and this one is named and tested rather than living as two
    /// lines inside a view method — because "unify these, they look the same" is exactly the edit
    /// that would introduce the fallback.
    ///
    /// - Parameter rows: the visible rows **as of the moment the chord fires**, never a snapshot
    ///   taken when the shortcut was published. See ``TransferShortcut``.
    static func transferItems(rows: [FileDifference],
                              selection: Set<FileDifference.ID>,
                              direction: FileDifference.SyncAction) -> [FileDifference] {
        guard !selection.isEmpty else { return [] }
        return rows.filter { selection.contains($0.id) && $0.action == direction }
    }

    /// The live rows for a set of ids, in the rows' own order.
    ///
    /// The direction-blind half of ``transferItems(rows:selection:direction:)``, for the menu
    /// actions that act on the whole selection rather than one direction of it. Both exist so a
    /// menu item can hold IDS and read values only when it fires: an NSMenu outlives the table
    /// state it was built from, and a row captured at build time may since have moved, been
    /// resolved, or gone.
    ///
    /// Empty for ids nothing matches, which is the honest answer for rows that are no longer on
    /// screen — a full rescan mints new `FileDifference.id`s, so an old id matching nothing means
    /// the row the user pointed at is genuinely not there any more.
    static func rows(_ rows: [FileDifference],
                     matching ids: Set<FileDifference.ID>) -> [FileDifference] {
        guard !ids.isEmpty else { return [] }
        return rows.filter { ids.contains($0.id) }
    }

    /// ⌘← / ⌘→ / ⇧⌘← / ⇧⌘→: rows selected in the differences table, and **that table is the
    /// surface the selection belongs to**.
    ///
    /// `surface` is the gate that replaces focus. Until now these chords were a
    /// `.onKeyPress` inside the Table, scoped there deliberately — a window-level key equivalent
    /// is consulted before the first responder and would have hijacked ⌘→ typed into the search
    /// field. As a menu item the chord is window-level by construction, so the question "does
    /// ⌘→ mean these rows?" needs an answer that is not "where is focus". The app already has
    /// one: `lastSelectionSurface`, which arbitrates exactly this for Space/Quick Look — both
    /// panes and the table can hold a selection at once, and this says which the user last meant.
    ///
    /// The text-field half of the original worry is handled where every other colliding chord
    /// handles it, by `chordBelongsToTextEditor` at the menu item.
    ///
    /// A review session owns the keyboard while it runs (its card reads plain ⌫ and ↩), and a
    /// blocking sync means no transfer may start — the same two gates Review and Verify carry.
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

    /// Collapses or expands every folder section — the master disclosure's own next-click rule.
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
