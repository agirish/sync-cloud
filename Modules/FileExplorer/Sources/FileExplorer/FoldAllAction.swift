import Foundation

/// The differences header's master disclosure: one button that folds or unfolds every folder
/// section at once. The filter menu and ⌥-click on a triangle do the same, but neither is visible.
/// Kept pure so the rule can be asserted without laying out a view; being one button, it must
/// decide what a click does when only some folders are collapsed.
///
/// Public because `FoldAllShortcut` carries the resolved case to the app target, where the ⇧⌘F
/// menu item titles itself from it. The rules stay internal, so the app can't compute a second
/// answer.
public enum FoldAllAction: Equatable {
    case collapse
    case expand

    /// What a click will do, given how many sections on screen are collapsed: any expanded section
    /// means collapse, and only a fully collapsed table offers expand. Mixed usually means one
    /// folder opened to look inside, so the way out is closing it. A majority rule would flip under
    /// a still pointer as a bulk sync empties sections mid-copy.
    ///
    /// Count `collapsedOnScreen` against the sections drawn, never the collapsed-folder set, which
    /// can hold folders the filter has hidden and would report "all collapsed" over expanded rows.
    static func next(collapsedOnScreen: Int, sectionCount: Int) -> FoldAllAction {
        // No sections is not "all collapsed": there is nothing to expand. Unreachable while
        // `isOffered` gates the control; answered so the function is total.
        guard sectionCount > 0 else { return .collapse }
        return collapsedOnScreen >= sectionCount ? .expand : .collapse
    }

    /// Whether the header offers the control. Absent when the table has no sections ("Group by
    /// folder" off, or `isWorthGrouping` declined), so it can't disagree with the table's shape.
    /// Folded away from `.glyphFilter` on, where the filter is a bare funnel too: two anonymous
    /// glyphs side by side is worse than one, and the filter menu still has Expand/Collapse All.
    static func isOffered(sectionCount: Int, compaction: HeaderCompaction) -> Bool {
        sectionCount > 0 && compaction < .glyphFilter
    }

    /// SF Symbol for the button. Not a chevron: the section triangles and the pane's show/hide
    /// toggle already use chevrons, and a third would differ only by position.
    var systemImage: String {
        switch self {
        case .collapse: return "rectangle.compress.vertical"
        case .expand: return "rectangle.expand.vertical"
        }
    }

    /// Names the action, not the state, like the count pill's chevron. Used for the tooltip and the
    /// accessible name, since a tooltip is not announced.
    var title: String {
        switch self {
        case .collapse: return "Collapse all folders"
        case .expand: return "Expand all folders"
        }
    }
}
