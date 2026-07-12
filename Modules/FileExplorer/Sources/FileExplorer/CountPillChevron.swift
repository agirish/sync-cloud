import Foundation

/// The disclosure affordance on the header's "N Differences" count pill. The per-side item
/// totals expand inline to the RIGHT of the pill and collapse back to the LEFT, so the
/// chevron mirrors that motion: right when clicking will expand, left when clicking will
/// collapse. One place owns the mapping so the view and its pin test can't drift.
public enum CountPillChevron {
    /// SF Symbol for the pill's trailing chevron given the current expansion state.
    public static func symbol(expanded: Bool) -> String {
        expanded ? "chevron.left" : "chevron.right"
    }
}
