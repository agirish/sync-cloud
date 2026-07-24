import CoreGraphics

/// Shared, reference-type scratch space for deciding whether a pane's floating action bar docks at
/// the top or bottom of its list. Held by the host (one per pane) and handed to `FileTreeView`,
/// which fills `rowBottoms`/`viewportHeight` from live geometry. Because it's a class, those
/// per-frame writes invalidate no view, so scrolling never re-renders the List. The host reads
/// `resolveAtTop(selection:)` straight from its own `body`, so the bar's edge is known synchronously
/// the instant the selection changes — no post-layout round-trip, no show-then-flip.
public final class PaneBarPlacement {
    public init() {}

    /// Height of the list viewport; the bottom-band test measures down from this edge.
    var viewportHeight: CGFloat = 0
    /// Every visible row's bottom edge in viewport space, keyed by node id. Tracks all rows (not
    /// just the selected one) so a freshly-clicked row's position is already known at click time.
    var rowBottoms: [String: CGFloat] = [:]
    /// The last resolved edge, kept for hysteresis so a row parked at the boundary can't chatter.
    var atTop = false

    /// How much of the list's bottom edge the action bar (plus a row of breathing room) covers.
    private static let band: CGFloat = 72
    /// Dead-zone (about one row) between the flip-to-top and flip-back-to-bottom thresholds.
    private static let hysteresis: CGFloat = 28

    /// Whether the bar should dock at the top for the given selection: true when the lowest selected
    /// visible row sits inside the bottom band a bottom-docked bar would cover. A short or unscrolled
    /// list keeps the bar at the bottom because its rows hug the top of the viewport. Pure w.r.t. the
    /// inputs except that it reads `atTop` for hysteresis — callers update `atTop` when they commit.
    public func resolveAtTop(selection: Set<String>) -> Bool {
        var lowest = -CGFloat.greatestFiniteMagnitude
        for id in selection {
            if let maxY = rowBottoms[id] { lowest = max(lowest, maxY) }
        }
        guard lowest > -.greatestFiniteMagnitude, viewportHeight > 0 else { return false }
        let enterTop = viewportHeight - Self.band
        return atTop ? lowest > enterTop - Self.hysteresis : lowest > enterTop
    }
}
