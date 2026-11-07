import CoreGraphics
import Foundation

/// Shared, reference-type scratch space for deciding whether a pane's floating action bar, and the
/// result message stacked beside it, docks at the top or bottom of its list. Held by the host (one
/// per pane) and handed to `FileTreeView`, which fills `rowBottoms`/`viewportHeight` from live
/// geometry. A class, so those per-frame writes invalidate no view and scrolling never re-renders
/// the List. The host reads `resolveAtTop(selection:)` from its own `body`, so the edge is known
/// the instant the selection changes, with no post-layout round-trip or show-then-flip.
public final class PaneBarPlacement {
    public init() {}

    /// Height of the list viewport; the coverage test measures down from this edge.
    var viewportHeight: CGFloat = 0
    /// The viewport's top edge in global (window) coordinates. Row positions are global too, and
    /// the resolve subtracts this. Global on both sides on purpose: a named coordinate space can't
    /// be resolved from inside a List row (each is hosted in its own AppKit view), so `.named`
    /// silently falls back to global there and every row would be off by the list's window offset.
    var viewportGlobalMinY: CGFloat = 0
    /// Every visible row's bottom edge in the window content view's top-down space (SwiftUI's
    /// `.global`), keyed by node id. All rows, not just the selected one, so a freshly clicked
    /// row's position is already known. Interpreted against `viewportGlobalMinY`.
    ///
    /// Two writers, one presentation at a time. The tree's rows report through `PaneRowBottomsKey`,
    /// measuring each row's content; each column's `ColumnListProbe` converts its table's row
    /// rects, which are cells, a few points lower. So the same row flips the bar a few points
    /// sooner in Columns; the cell is the row as its highlight draws it.
    var rowBottoms: [String: CGFloat] = [:]
    /// The measured footprint of the bottom-docked bar, its padded overlay height. This is the
    /// coverage zone: the bar only hides a row whose bottom edge falls inside it, so the flip
    /// triggers exactly when covering would happen, not at a guessed band. Holds a bar-at-rest
    /// estimate until measured. Public because the host renders the bar and writes this.
    public var coverage: CGFloat = 64
    /// The measured footprint of the result message, written by the host the same way. It docks in
    /// one stack with the bar, so the zone covered is the sum of the two and the pair flips as one.
    /// Holds a one-line estimate until measured, so the message's first frame lands at the right
    /// edge rather than showing at the bottom and then flipping.
    public var messageCoverage: CGFloat = 60
    /// Which of the two the overlay carries: set by the host's resolve, read by every re-resolve.
    private(set) var carriesBar = true
    private(set) var carriesMessage = false
    /// Where the row last acted on sat: the lowest visible row of the last guarded selection that
    /// had one, viewport-relative. The message's anchor once the selection is gone, since a delete
    /// prunes the selection before its message arrives, and the message would otherwise cover the
    /// deleted row's neighbours, where the next click is aimed. Refreshed by every resolve that can
    /// still see the selection, so a scroll before the act moves it too.
    private(set) var actedSlot: CGFloat?
    /// The last committed edge, the hysteresis anchor. Written only inside the resolve, so every
    /// caller reasons from the same anchor and consecutive renders can't make the bar flip-flop.
    private(set) var atTop = false

    /// The selection the bar is actually acting on: whatever the HOST last resolved against.
    ///
    /// **Geometry-driven re-resolves must reason from this, never their own selection.** The host's
    /// selection is empty for the inactive pane and, for one turn after a click, for the pane just
    /// clicked, while the pane's raw List selection is already populated. Two callers committing
    /// different answers would flip the edge back and forth from inside layout, and in Columns,
    /// where a click also opens a column and scrolls, the layout never settles: AppKit raises once
    /// a window needs more constraint passes than it has views, a hard crash. Hence this anchor,
    /// which `reresolveAtTop()` reads.
    private(set) var barSelection: Set<String> = []

    /// Extra clearance (beyond leaving the coverage zone) a selected row must gain before the bar
    /// drops back to the bottom, about one comfortable row. A dead zone thinner than a row step
    /// would bounce the bar when arrowing near the boundary.
    private static let exitHysteresis: CGFloat = 44

    /// Resolves, and commits, which edge the bar belongs on for the given selection: top exactly
    /// when a bottom-docked bar would cover the lowest selected visible row. A short or unscrolled
    /// list keeps the bar at the bottom because its rows hug the top of the viewport; a selection
    /// with no visible row does too (there is nothing on screen to cover). Entering the top edge
    /// happens the moment covering would occur; returning to the bottom additionally requires
    /// `exitHysteresis` of clearance, so a row parked at the boundary can't chatter the bar.
    /// Idempotent for unchanged geometry + selection, so the host may call it on every render.
    ///
    /// This is the host's entry point, and defines the bar's selection of record. A pane
    /// re-resolving after a scroll or a new column calls `reresolveAtTop()` instead.
    @discardableResult
    public func resolveAtTop(selection: Set<String>) -> Bool {
        resolveAtTop(guarding: selection, bar: true, message: false)
    }

    /// The same resolve for the whole overlay stack: `selection` is the rows it must stay clear of,
    /// `bar` and `message` say what it carries. With no bar and no message the stack covers nothing
    /// and rests at the bottom, but the call still records where the selection sits, which is how
    /// a message raised after a delete knows the deleted row's slot. With a message and no
    /// selection left, that slot stands in for the selection.
    @discardableResult
    public func resolveAtTop(guarding selection: Set<String>, bar: Bool, message: Bool) -> Bool {
        barSelection = selection
        carriesBar = bar
        carriesMessage = message
        return reresolveAtTop()
    }

    /// Re-resolves after geometry moved, and answers whether that moved the committed edge: the
    /// question both presentations' geometry callbacks ask (the tree's row preference in
    /// `FileTreeView`, each column's `ColumnListProbe`). One method, so the two agree on what
    /// counts as a flip.
    func reresolveMovedEdge() -> Bool {
        let wasAtTop = atTop
        return reresolveAtTop() != wasAtTop
    }

    /// Re-resolves after rows moved and, on a genuine flip, tells the host on the next turn, never
    /// from inside the geometry callback that found it. Both presentations' callbacks take this
    /// path, and so does the host when the result message measures a new height. With no host to
    /// tell, nothing is resolved.
    @MainActor public func flipIfEdgeMoved(_ onFlip: (() -> Void)?) {
        guard let onFlip, reresolveMovedEdge() else { return }
        DispatchQueue.main.async { onFlip() }
    }

    /// Re-resolves the edge for the selection the host last committed, after geometry moved.
    ///
    /// The same maths as `resolveAtTop(selection:)`; only the source of the selection differs.
    @discardableResult
    func reresolveAtTop() -> Bool {
        let selection = barSelection
        let lowestVisible = Self.lowestVisibleBottom(of: selection, rowBottoms: rowBottoms,
                                                     viewportGlobalMinY: viewportGlobalMinY,
                                                     viewportHeight: viewportHeight)
        if let lowestVisible { actedSlot = lowestVisible }
        let zone = (carriesBar ? coverage : 0) + (carriesMessage ? messageCoverage : 0)
        // A pane shorter than the stack is covered whichever edge it takes, so stay at the
        // resting bottom; a negative `coveredFrom` would read every row as covered. An empty stack
        // covers nothing, so it stays at the bottom too.
        guard zone > 0, viewportHeight > zone else {
            atTop = false
            return false
        }
        // The deleted row's slot, when the act took the selection with it.
        let lowest = lowestVisible ?? (selection.isEmpty && carriesMessage ? actedSlot : nil)
        guard let lowest else {
            atTop = false
            return false
        }
        let coveredFrom = viewportHeight - zone
        atTop = atTop ? lowest > coveredFrom - Self.exitHysteresis : lowest > coveredFrom
        return atTop
    }

    /// The bottom of the lowest selected row on screen, viewport-relative; nil when none is.
    ///
    /// Only rows on screen can be covered. `rowBottoms` also holds rows laid out past the fold, and
    /// counting those would drag the bar to the top for a row nobody can see, covering the visible
    /// ones. So clamp to the viewport before taking the lowest.
    ///
    /// Vertically only, on purpose: a column scrolled out sideways keeps its rows here, since
    /// re-reporting every column on every frame of a sideways scroll is the cost `ColumnListProbe`
    /// avoids, and a column that dropped its rows would have none for the first click back.
    static func lowestVisibleBottom(of selection: Set<String>, rowBottoms: [String: CGFloat],
                                    viewportGlobalMinY: CGFloat, viewportHeight: CGFloat) -> CGFloat? {
        var lowest: CGFloat?
        for id in selection {
            guard let maxY = rowBottoms[id] else { continue }
            // Both sides global; the difference is the row's position within the viewport.
            let inViewport = maxY - viewportGlobalMinY
            guard inViewport <= viewportHeight else { continue }
            lowest = max(lowest ?? inViewport, inViewport)
        }
        return lowest
    }
}
