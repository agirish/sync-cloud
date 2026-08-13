import Foundation

/// Which surface the user last picked something in.
///
/// The two selections are genuinely independent — the one-pane-selected invariant is between LEFT
/// and RIGHT only, so a pane and the Differences table can hold selections at the same time. That
/// makes "the current file" ambiguous by construction, and this is the tie-break: whichever surface
/// the user touched last is the one they mean.
public enum SelectionSurface: Sendable, Equatable {
    /// Either Compare pane, or the single-source rail. Not split into left/right: the one-pane-selected
    /// invariant already guarantees at most one of them holds anything, so the side is recoverable
    /// from the selections themselves and storing it here would be a second source of truth.
    case pane
    /// The bottom workspace's Differences table.
    case differences
}

/// The one place that answers "which file does the app mean right now?".
///
/// It exists because the answer used to be given three times, by hand, in three different shapes:
/// the panes' Quick Look handler, the single-source rail's near-identical copy of it, and
/// `DetailsSidebar.activePath` — whose comment claimed it matched `PaneLogic.primarySelectionPath`
/// but re-implemented it instead. Space and the Info inspector could therefore disagree about which
/// file was current, and did: the inspector showed the pane selection while Space previewed the
/// Differences row, which is the confusion this type was extracted to end.
///
/// Pure and in `Sync` rather than in `MacApp` so all three consumers — `MacApp`, `FileExplorer`'s
/// `DifferencesView` and `Dashboard`'s `DetailsSidebar` — can reach the same implementation.
public enum CurrentSelection {

    /// The pane selection's primary path: alphabetically first, left pane winning over right.
    ///
    /// `min()` rather than `first`: `Set.first` is arbitrary per hash seed, so a multi-item
    /// selection would otherwise resolve to a different file on every launch. It is the
    /// allocation-free equivalent of `sorted().first` (both take the least element by `<`).
    ///
    /// `singleSource` drops the right pane entirely. On the single-source rail the right pane is hidden, and
    /// its lingering selection must not leak into what the rail previews or what the inspector
    /// shows — both surfaces used to spell that rule out separately.
    public static func primaryPanePath(
        left: Set<String>,
        right: Set<String>,
        singleSource: Bool = false
    ) -> String? {
        if let leftPath = left.min() { return leftPath }
        return singleSource ? nil : right.min()
    }

    /// The path Space should Quick Look, given what each surface holds and which was touched last.
    ///
    /// The last-touched surface wins; an empty one falls through to the other rather than
    /// previewing nothing, so clearing the Differences selection leaves Space still working on the
    /// pane instead of going dead. `nil` — nothing selected anywhere — is the only case that
    /// previews nothing, and every caller must return `.ignored` for it so the key stays available
    /// to whatever else might want it.
    public static func quickLookPath(
        lastInteracted: SelectionSurface?,
        panePath: String?,
        differencesPath: String?
    ) -> String? {
        switch lastInteracted {
        case .differences:
            return differencesPath ?? panePath
        case .pane, nil:
            return panePath ?? differencesPath
        }
    }

    /// What an ALREADY-OPEN Quick Look panel should do when the pane selection moves under it.
    ///
    /// Finder's behaviour, and the reason it is worth copying: the panel is a view of "the current
    /// file", not a snapshot of the file that happened to be current when you pressed Space. Left
    /// alone, the panel sat there naming a file the user had long since navigated away from —
    /// through a re-root, a search walk, an entire change of workspace — while looking exactly like
    /// a live preview of whatever is selected now.
    ///
    /// **`.close` on an empty selection is deliberate and is the case worth stating.** Deselecting
    /// leaves nothing for a preview to be *of*, and the alternatives are both worse: keeping the
    /// last file up is the stale panel again in its purest form, and blanking the panel's contents
    /// leaves an empty window the user has to dismiss by hand. Finder closes it.
    ///
    /// A table rather than three lines at the call site, because the call site is an `onChange` in
    /// a SwiftUI body — unreachable from a test — and two of the five rows are `.stay` for entirely
    /// different reasons that a reader will otherwise collapse into one.
    public static func previewFollow(
        showing: String?,
        followsPane: Bool,
        panePath: String?
    ) -> PreviewFollow {
        // Nothing open. Opening a preview because a selection moved would be the *original* bug
        // reported — a preview nobody asked for — so this arm must never do anything else.
        guard let showing else { return .stay }
        // Open, but not the pane's to move: a Differences row or the Info inspector put it there,
        // and a pane selection is not a statement about either.
        guard followsPane else { return .stay }
        guard let panePath else { return .close }
        return panePath == showing ? .stay : .retarget(panePath)
    }
}

/// What ``CurrentSelection/previewFollow(showing:followsPane:panePath:)`` decided.
public enum PreviewFollow: Equatable, Sendable {
    /// Point the open panel at this path instead.
    case retarget(String)
    /// Close the panel: there is no current file for it to be showing.
    case close
    /// Leave it exactly as it is — including "there is nothing open", which is most of the time.
    case stay
}
