import Foundation

/// Which surface the user last picked something in. A pane and the Differences table can hold
/// selections at once (only left and right exclude each other), so "the current file" needs a
/// tie-break: the surface the user touched last.
public enum SelectionSurface: Sendable, Equatable {
    /// Either Compare pane, or the single-source rail. Not split into left and right: at most one
    /// pane holds a selection, so storing the side would be a second source of truth.
    case pane
    /// The bottom workspace's Differences table.
    case differences
}

/// The one place that answers "which file does the app mean right now?", so Space and the Info
/// inspector can't disagree about the current file. Pure and in `Sync` so `MacApp`,
/// `FileExplorer`'s `DifferencesView` and `Dashboard`'s `DetailsSidebar` share it.
public enum CurrentSelection {

    /// The pane selection's primary path: alphabetically first, left pane winning over right.
    ///
    /// `min()`, not `first`: `Set.first` varies with the hash seed, so a multi-item selection would
    /// resolve to a different file each launch. `singleSource` ignores the right pane, which is
    /// hidden on the single-source rail, so its leftover selection can't leak into the preview.
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
    /// The last-touched surface wins; an empty one falls through to the other, so clearing the
    /// Differences selection doesn't leave Space dead. `nil` means nothing is selected anywhere, and
    /// every caller must return `.ignored` for it so the key stays available to others.
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

    /// What an already-open Quick Look panel should do when the pane selection moves under it. As in
    /// Finder, the panel shows the current file, not the one current when Space was pressed, so it
    /// never looks like a live preview of a file the user has left.
    ///
    /// An empty selection closes it, as Finder does: keeping the last file up is a stale panel, and
    /// blanking it leaves an empty window to dismiss by hand. A function rather than lines in the
    /// `onChange` that calls it, so tests can reach it; two `.stay` arms have different reasons.
    public static func previewFollow(
        showing: String?,
        followsPane: Bool,
        panePath: String?
    ) -> PreviewFollow {
        // Nothing open. A selection move must never open a preview nobody asked for.
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
