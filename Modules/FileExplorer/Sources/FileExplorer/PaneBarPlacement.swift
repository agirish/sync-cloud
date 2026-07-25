import CoreGraphics

/// Shared, reference-type scratch space for deciding whether a pane's floating action bar docks at
/// the top or bottom of its list. Held by the host (one per pane) and handed to `FileTreeView`,
/// which fills `rowBottoms`/`viewportHeight` from live geometry. Because it's a class, those
/// per-frame writes invalidate no view, so scrolling never re-renders the List. The host reads
/// `resolveAtTop(selection:)` straight from its own `body`, so the bar's edge is known synchronously
/// the instant the selection changes — no post-layout round-trip, no show-then-flip.
public final class PaneBarPlacement {
    public init() {}

    /// Height of the list viewport; the coverage test measures down from this edge.
    var viewportHeight: CGFloat = 0
    /// The viewport's top edge in GLOBAL (window) coordinates. Row positions are captured in global
    /// space too, and the resolve subtracts this to get viewport-relative positions. Global on both
    /// sides on purpose: a named coordinate space cannot be resolved from inside a List row (each
    /// row is hosted in its own AppKit view, outside the space's SwiftUI subtree), so `.named`
    /// silently fell back to global there — inflating every row by the list's offset from the
    /// window top and flipping the bar a quarter-viewport early.
    var viewportGlobalMinY: CGFloat = 0
    /// Every visible row's bottom edge in GLOBAL coordinates, keyed by node id. Tracks all rows
    /// (not just the selected one) so a freshly-clicked row's position is already known at click
    /// time. Interpreted against `viewportGlobalMinY`.
    var rowBottoms: [String: CGFloat] = [:]
    /// The measured footprint of the bottom-docked bar — its padded overlay height, written by the
    /// host from the bar's real geometry. This is the coverage zone: the bar only hides a row whose
    /// bottom edge falls inside it, so the flip triggers exactly when covering would happen, not at
    /// a guessed flat band (the old 72pt band flipped a click several points before any overlap —
    /// the "premature flip on the way down"). Holds a bar-at-rest estimate until first measured.
    /// Public: the HOST measures the bar (it renders it) and writes the value here.
    public var coverage: CGFloat = 64
    /// The last committed edge — the hysteresis anchor. Written ONLY inside `resolveAtTop`, so
    /// every caller reasons from the same anchor. (The old shape had the host resolving WITHOUT
    /// committing while two other paths committed, so consecutive renders could disagree with the
    /// anchor and the bar flip-flopped.)
    private(set) var atTop = false

    /// Extra clearance (beyond leaving the coverage zone) a selected row must gain before the bar
    /// drops back to the bottom — about one comfortable row. The old 28pt dead-zone was thinner
    /// than a row step, so arrowing near the boundary bounced the bar.
    private static let exitHysteresis: CGFloat = 44

    /// Resolves — and commits — which edge the bar belongs on for the given selection: top exactly
    /// when a bottom-docked bar would cover the lowest selected visible row. A short or unscrolled
    /// list keeps the bar at the bottom because its rows hug the top of the viewport; a selection
    /// with no visible row does too (there is nothing on screen to cover). Entering the top edge
    /// happens the moment covering would occur; returning to the bottom additionally requires
    /// `exitHysteresis` of clearance, so a row parked at the boundary can't chatter the bar.
    /// Idempotent for unchanged geometry + selection, so the host may call it on every render.
    @discardableResult
    public func resolveAtTop(selection: Set<String>) -> Bool {
        var lowestGlobal = -CGFloat.greatestFiniteMagnitude
        for id in selection {
            if let maxY = rowBottoms[id] { lowestGlobal = max(lowestGlobal, maxY) }
        }
        guard lowestGlobal > -.greatestFiniteMagnitude, viewportHeight > 0 else {
            atTop = false
            return false
        }
        // Both sides global; the difference is the row's position within the viewport.
        let lowest = lowestGlobal - viewportGlobalMinY
        let coveredFrom = viewportHeight - coverage
        atTop = atTop ? lowest > coveredFrom - Self.exitHysteresis : lowest > coveredFrom
        return atTop
    }
}
