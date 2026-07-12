import Foundation

/// The disclosure affordance on the header's "N Differences" count pill. The per-side item
/// totals expand inline to the RIGHT of the pill and collapse back to the LEFT, so the
/// chevron mirrors that motion: right when clicking will expand, left when clicking will
/// collapse. Pre-scan the pill is a dead control, so no chevron is offered at all. One
/// place owns the mapping so the view and its pin test can't drift.
public enum CountPillChevron {
    /// SF Symbol for the pill's trailing chevron, or nil pre-scan (no invitation on a
    /// control that does nothing yet).
    public static func symbol(hasScanned: Bool, expanded: Bool) -> String? {
        guard hasScanned else { return nil }
        return expanded ? "chevron.left" : "chevron.right"
    }
}
