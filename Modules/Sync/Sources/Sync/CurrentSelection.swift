import Foundation

/// Which surface the user last picked something in.
///
/// The two selections are genuinely independent — the one-pane-selected invariant is between LEFT
/// and RIGHT only, so a pane and the Differences table can hold selections at the same time. That
/// makes "the current file" ambiguous by construction, and this is the tie-break: whichever surface
/// the user touched last is the one they mean.
public enum SelectionSurface: String, Sendable, Equatable {
    /// Either Compare pane, or the Tidy rail. Not split into left/right: the one-pane-selected
    /// invariant already guarantees at most one of them holds anything, so the side is recoverable
    /// from the selections themselves and storing it here would be a second source of truth.
    case pane
    /// The bottom workspace's Differences table.
    case differences
}

/// The one place that answers "which file does the app mean right now?".
///
/// It exists because the answer used to be given three times, by hand, in three different shapes:
/// the panes' Quick Look handler, the Tidy rail's near-identical copy of it, and
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
    /// `singleSource` drops the right pane entirely. On the Tidy rail the right pane is hidden, and
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
}
