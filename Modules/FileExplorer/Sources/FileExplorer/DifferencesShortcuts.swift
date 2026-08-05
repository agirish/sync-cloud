import SwiftUI

// MARK: - Differences shortcuts

// The differences header's shortcut-reachable actions, published to the App scope so its menu
// items (⇧⌘R Review, ⇧⌘V Verify, ⌥⌘F fold) can reach them. The keys live here rather than in the
// app target because `DifferencesView` is the publisher: the availability rules (a live session,
// an empty target set, a sync in flight) are its state, and publishing from the view keeps the
// menu's enabled-ness and the button's visibility answering to the same facts.
//
// Closures rather than a binding: every one of these fires a method that already exists on the
// view; none of them is state a menu could own. `nil` means "not available right now", which the
// menu items render as disabled — the same contract `beginPaneSearch` established.

/// What ⌥⌘F would do right now — collapse or expand — plus the closure that does it.
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

private struct StartDifferencesReviewKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct VerifyDifferencesKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct FoldAllDifferencesKey: FocusedValueKey {
    typealias Value = FoldAllShortcut
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
}
