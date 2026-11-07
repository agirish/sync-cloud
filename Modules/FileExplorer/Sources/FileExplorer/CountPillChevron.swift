import Foundation

/// The chevron on the header's "N Differences" count pill. The per-side totals expand to the
/// right of the pill and collapse to the left, so the chevron points the way a click will move
/// them. Before a scan the pill does nothing, so it has no chevron. One place owns the mapping so
/// the view and its pin test can't drift.
public enum CountPillChevron {
    /// The SF Symbol for the pill's trailing chevron, or nil before a scan.
    public static func symbol(hasScanned: Bool, expanded: Bool) -> String? {
        guard hasScanned else { return nil }
        return expanded ? "chevron.left" : "chevron.right"
    }
}
