import Foundation

/// The differences header's master disclosure — the one control that folds or unfolds every folder
/// section at once.
///
/// Collapse-all and expand-all already existed as items in the filter menu, and as ⌥-click on any
/// section triangle. Neither is visible: the menu is labelled "Filter the list", and the ⌥ gesture
/// is unadvertised. This type is the rule for the button that says so out loud, kept pure so the
/// rule can be asserted without laying out a view.
///
/// Being ONE button rather than a pair means it has to answer a question the two menu items never
/// face: what does a click do when SOME folders are collapsed?
///
/// Public because `FoldAllShortcut` carries the resolved case across to the app target, where
/// the ⌥⌘F menu item titles itself from it. The resolution rules stay internal — the app is
/// handed an answer, never the machinery to compute a second one.
public enum FoldAllAction: Equatable {
    case collapse
    case expand

    /// What a click will do, given how many of the sections **on screen** are collapsed.
    ///
    /// The rule is *any expanded section → collapse*, and only an entirely collapsed table offers
    /// expand. Two reasons, and the second is the load-bearing one:
    ///
    /// - Mixed is what you get after collapsing everything and opening one folder to look inside,
    ///   so the way back out is closing it again.
    /// - A toggle that flipped on a majority would change what it does without the user touching
    ///   it. A bulk sync consumes rows as it runs, so sections empty out and disappear mid-copy —
    ///   the button under a settled pointer must not quietly become its own opposite.
    ///
    /// `collapsedOnScreen` is counted against the sections the table is actually drawing, never
    /// against the collapsed-folder set directly: that set can hold names for folders the active
    /// filter has since hidden, which would report "everything is collapsed" for a table showing
    /// expanded rows.
    static func next(collapsedOnScreen: Int, sectionCount: Int) -> FoldAllAction {
        // No sections is not "all collapsed" — there is nothing to expand. Unreachable while
        // `isOffered` gates the control, and answered here anyway so the type is total.
        guard sectionCount > 0 else { return .collapse }
        return collapsedOnScreen >= sectionCount ? .expand : .collapse
    }

    /// Whether the header offers the control at all.
    ///
    /// Absent when the table is not sectioned — `sections` is empty both when "Group by folder" is
    /// off and when `isWorthGrouping` declined it, so one question covers both and the control
    /// cannot disagree with the shape the table is drawing.
    ///
    /// Folded away from `.glyphFilter` down, which is the rung where the filter itself drops to a
    /// bare funnel: two anonymous glyphs side by side is a worse trade than one, and the filter
    /// menu still carries Expand All / Collapse All at every width.
    static func isOffered(sectionCount: Int, compaction: HeaderCompaction) -> Bool {
        sectionCount > 0 && compaction < .glyphFilter
    }

    /// SF Symbol for the button.
    ///
    /// Deliberately not a chevron. The section triangles are `chevron.right`/`chevron.down` and the
    /// pane's show/hide toggle is `chevron.up`/`chevron.down`, so this row already has two controls
    /// that "collapse something" — a third drawn from the same vocabulary would be tellable apart
    /// only by position.
    var systemImage: String {
        switch self {
        case .collapse: return "rectangle.compress.vertical"
        case .expand: return "rectangle.expand.vertical"
        }
    }

    /// Names the action, not the state — the same "points the way the next click sends it"
    /// convention the count pill's chevron follows.
    ///
    /// Used for the tooltip *and* the accessible name. A tooltip is not announced, and the section
    /// headers already learned that lesson the expensive way when `accessibilityElement(children:
    /// .ignore)` swallowed their disclosure button whole.
    var title: String {
        switch self {
        case .collapse: return "Collapse all folders"
        case .expand: return "Expand all folders"
        }
    }
}
