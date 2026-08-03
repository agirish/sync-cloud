import AppKit
import Design
import Events
import SwiftUI
import Sync

/// The Columns presentation of one pane: Finder-style Miller columns over the pane's loaded tree.
///
/// Resting state is the whole trick. With an empty `browsePath` this renders exactly one column
/// spanning the pane, listing the same rows the tree view lists — which is why Columns can be the
/// default without rearranging anyone's pane on first launch. Columns appear only once a folder is
/// clicked.
///
/// Navigation here is deliberately *not* re-rooting. Drilling writes `browsePath` and nothing else:
/// no reload, no rescan, no change to the pane's comparison scope, so every difference badge stays
/// valid as you walk. `FileActionHandler.focusFolder` remains the separate, deliberate way to
/// narrow the comparison.
struct PaneColumnsView: View {
    let tree: PaneTree
    let otherTree: PaneTree
    /// Path → children for this pane's published tree, built once per publish (see
    /// `PaneChildrenIndex`). A column resolves its rows with a dictionary lookup; asking
    /// `PaneRow.children` per column per render is the recursive walk that froze the main thread.
    let childrenIndex: PaneChildrenIndex
    /// Absolute path of the pane's tree root — the folder the first column lists.
    let treeRoot: String
    @Binding var browsePath: PaneBrowsePath
    /// Applies a new column stack for this pane. Routed through the host rather than written
    /// straight to the binding because the seam link makes this a two-pane decision, and only the
    /// host can see the other pane's tree to mirror into it.
    let onNavigate: (PaneBrowsePath) -> Void
    @Binding var selection: Set<String>
    let otherSelection: Set<String>
    let isLeft: Bool
    let delegate: FileActionDelegate
    let diffIndex: DiffStatusIndex
    let otherPaneName: String
    let isSingleSource: Bool
    let density: ListDensity
    let isActivePane: Bool
    /// Shared placement scratch space; column rows report their bottoms into it exactly as tree
    /// rows do, so the action bar keeps flipping edges. `nil` on surfaces with no action bar.
    let placement: PaneBarPlacement?
    let onBarEdgeFlip: (() -> Void)?
    /// Presents a Quick Look preview; owned by the hosting `FileTreeView`.
    let onQuickLook: (URL) -> Void
    /// A plain click on empty space, carrying the depth of the column it landed in — `nil` when it
    /// landed past the last column, where there is nothing to truncate to. Routed to the host for
    /// the same reason `onNavigate` is: clearing the selection is a two-pane decision (the pane
    /// holding it may not be this one) and only the host can see both sides.
    let onBackgroundDeselect: (Int?) -> Void
    /// The download request this pane is watching. Owned — and polled — by the hosting
    /// `FileTreeView`, which holds the pane's single (pane-scoped) subscription; read here by the
    /// row whose file it names (`FileRowView.awaitingDownloadID`) and by the preview column showing
    /// that file (`ColumnPreviewColumn.awaitingDownloadPath`).
    var awaitingDownload: CloudDownloadRequest?
    /// The pane's resolved row fonts — see `PaneRowFonts`.
    var fonts: PaneRowFonts = .unscaled

    /// One width shared by both panes, so the two sides stay symmetric while you read them against
    /// each other. Clamped on every write — see `PaneViewMode.clampColumnWidth`.
    @AppStorage(PaneViewMode.columnWidthDefaultsKey) private var storedColumnWidth: Double =
        Double(PaneViewMode.defaultColumnWidth)
    /// Whether a selected file gets a preview column, as it does in Finder's column view. Toggled
    /// from the pane header's pill and from a column's empty-area context menu — the same place
    /// Finder keeps its view options. One shared preference, not a per-pane one.
    @AppStorage(PaneViewMode.previewColumnDefaultsKey) private var previewEnabled: Bool =
        PaneViewMode.previewColumnDefault
    /// The preview pane's width, dragged from the divider on its leading edge.
    @AppStorage(PaneViewMode.previewColumnWidthDefaultsKey) private var storedPreviewWidth: Double =
        Double(PaneViewMode.defaultPreviewColumnWidth)
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    /// Live width while a divider is being dragged, so the drag doesn't write defaults per frame.
    @State private var dragWidth: CGFloat?
    /// The column width the current divider drag started from. `DragGesture.translation` is
    /// cumulative, so the anchor must not move while the drag runs.
    @State private var dragAnchorWidth: CGFloat?
    /// The same two for the preview's divider, kept apart from the columns' pair: one set of scratch
    /// state shared by two dividers that resize different things is a drag on one silently
    /// continuing from the other's anchor.
    @State private var dragPreviewWidth: CGFloat?
    @State private var dragPreviewAnchor: CGFloat?

    /// How long after a reveal the second attempt is made. Past the 0.18s scroll animation, so a
    /// first attempt that DID land has finished moving and the retry is a no-op — see
    /// `revealDeepestColumn`.
    static let revealRetryDelay: TimeInterval = 0.25

    /// How many times a reveal held off by a wheel gesture in its OWN pane re-checks the hold
    /// before giving up, spaced `WheelGestureTracker.staleness` apart — nominally five seconds of
    /// a gesture that keeps delivering.
    ///
    /// **Counted, not clocked**, and that is the point. Each check schedules the next, so a
    /// starved main thread stretches the budget rather than burning it — a wall-clock deadline
    /// would expire unused on exactly the loaded machine where the reveal is slowest to land.
    ///
    /// A budget exists at all only as a stop for a lock that never releases. That is not
    /// hypothetical here: a latched axis lock has shipped twice (the phase-less wheel mouse, whose
    /// events clear nothing), and an unbounded re-check would answer that bug with a chain of
    /// timers running for the life of the pane. Under a lock that behaves, the wait ends when the
    /// gesture does, and this number is never reached.
    static let revealHoldChecks = 50

    /// This pane's handle on its own mounted overscroll watchdog — see `PaneColumnHoldGate`.
    @State private var holdGate = PaneColumnHoldGate()

    /// The animation `revealDeepestColumn` scrolls with. Defaults to the shipped ease, so every
    /// window that does not opt out scrolls exactly as it always did — see
    /// `paneColumnRevealAnimation`.
    @Environment(\.paneColumnRevealAnimation) private var revealAnimation

    /// The modifiers a click here is read as carrying, or `nil` — the shipped default — to ask the
    /// keyboard. See `paneClickModifiers`.
    @Environment(\.paneClickModifiers) private var pinnedClickModifiers

    /// What every navigation guard in this view tests. `nil` is the shipped value and this is then
    /// literally `NSEvent.modifierFlags`, which is what all three call sites read before the pin
    /// existed.
    private var clickModifiers: NSEvent.ModifierFlags { pinnedClickModifiers ?? NSEvent.modifierFlags }

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var columnWidth: CGFloat {
        PaneViewMode.clampColumnWidth(dragWidth ?? CGFloat(storedColumnWidth))
    }
    private var preferredPreviewWidth: CGFloat {
        PaneViewMode.clampPreviewColumnWidth(dragPreviewWidth ?? CGFloat(storedPreviewWidth))
    }
    /// The directories each open column lists, root first.
    private var directories: [String] { browsePath.columnDirectories(treeRoot: treeRoot) }

    /// The file the preview column would show, or `nil` — see `ColumnPreview.item`.
    ///
    /// Every Columns surface, comparison panes included. This was the rail's alone at first, on the
    /// reasoning that a comparison pane is half a window wide and its whole job is to be read against
    /// the pane beside it, so spending a third of it on a preview would take that room from the
    /// columns doing the comparing. That is a real cost, but it is the reader's to weigh — and they
    /// weigh it with the toggle, which is the same one the rail uses. The width rule already refuses
    /// the trade where it would be ruinous: `showsPreviewColumn` gives a preview no room at all
    /// unless a full column still fits beside it.
    private var previewItem: ColumnPreviewItem? {
        guard previewEnabled, let deepest = directories.last else { return nil }
        return ColumnPreview.item(selection: selection,
                                  deepestRows: childrenIndex.children(atPath: deepest) ?? [])
    }

    var body: some View {
        // The measured width feeds the layout directly. It used to be mirrored into @State and read
        // back from there, which meant the first render of any pane decided push-vs-stack from a
        // width of 0 — a wide pane opened as one column and corrected itself a frame later.
        GeometryReader { geo in
            columnStack(paneWidth: geo.size.width)
        }
    }

    /// The pane: the scrolling column stack, and — when a file is selected — the preview pinned to
    /// the trailing edge beside it.
    ///
    /// The preview sits OUTSIDE the scroll view, which is the whole design. Inside it, the preview
    /// and the columns had to share one width: enlarging it either ran off the right edge (it was the
    /// last item, so it grew into the scroll overflow) or, when its width came from the columns'
    /// slack, forced every column narrow enough that the stack stopped scrolling — the columns became
    /// unreadable *and* the preview still couldn't exceed the leftovers. Pinned, the two are
    /// independent: the preview takes width from the SCROLL VIEW, so the columns keep theirs and keep
    /// scrolling.
    @ViewBuilder
    private func columnStack(paneWidth: CGFloat) -> some View {
        let previewTarget = previewItem
        let showsPreview = PaneViewMode.showsPreviewColumn(
            paneWidth: paneWidth, columnWidth: columnWidth,
            isEnabled: previewEnabled, hasPreviewTarget: previewTarget != nil)
        let previewWidth = showsPreview
            ? PaneViewMode.previewPaneWidth(paneWidth: paneWidth, columnWidth: columnWidth,
                                            preferred: preferredPreviewWidth)
            : 0
        // What the columns get. Every layout rule below reads THIS, not the pane: the stack's own
        // geometry is unchanged by the preview's existence, it simply has less room.
        let stackWidth = paneWidth - previewWidth

        HStack(spacing: 0) {
            scrollingColumns(stackWidth: stackWidth, paneWidth: paneWidth,
                             showsPreview: showsPreview)
                .frame(width: stackWidth)
            if showsPreview, let previewTarget {
                // The pane's action bar is an overlay across the WHOLE pane, so on a comparison pane
                // it lands on top of this column — and it is not an edge case: the preview needs
                // exactly one selected file, which is precisely when the bar is up. Measured in a
                // 940pt pane, the bar spans x 10…930 of the pane while the preview holds x 438…940,
                // covering 492 of its 502 points across the bottom band, which is where the identity
                // rows are. Nor can it be dismissed to read them: the bar's ✕ clears the selection,
                // and that takes the preview with it.
                //
                // `placement` is the signal because its contract is already "nil on surfaces with no
                // action bar", which is why the Tidy rail (where this column shipped first) never had
                // the problem.
                //
                // Deliberately NOT also `isActivePane`, though that would be the more precise reading
                // of "a bar will actually be drawn here": the bar shows on the active side only, so an
                // inactive pane holding a single-file selection reserves a band nothing occupies. The
                // cost of precision is a jump — clicking into that pane would raise the bar and lift
                // the identity rows a whole band in the same instant. A little dead space on the pane
                // you are not reading beats geometry that moves under the one you just clicked, which
                // is the same resting-state rule `showsPreviewColumn` follows when it refuses to let
                // a file click start the stack scrolling.
                ColumnPreviewColumn(
                    item: previewTarget,
                    actionBarClearance: placement == nil ? 0 : ColumnPreviewColumn.actionBarClearance,
                    paneToken: PaneToken(isLeft: isLeft, isSingleSource: isSingleSource),
                    awaitingDownloadPath: awaitingDownload?.path)
                    .frame(width: previewWidth)
                    // On the preview's LEADING edge, and it resizes the preview. This is the drag
                    // that could not work while the preview lived in the scroll view: pinned to the
                    // trailing edge, growing it moves this seam left, under the cursor, exactly as a
                    // divider should behave.
                    .overlay(alignment: .leading) { previewDivider(rendered: previewWidth) }
            }
        }
    }

    /// The Miller-column stack itself, scrolling horizontally within `stackWidth`.
    ///
    /// - Parameter showsPreview: whether the preview is taking room from this stack right now. Not
    ///   used for layout — `stackWidth` already carries that — but as a scroll trigger (its rising
    ///   edge) and as the gate on the preview-width driver; see the drivers below.
    @ViewBuilder
    private func scrollingColumns(stackWidth: CGFloat, paneWidth: CGFloat,
                                  showsPreview: Bool) -> some View {
        // Below two minimum columns there is no room for a second one, so the pane shows a single
        // column that replaces its contents as you drill and `‹` walks back out.
        //
        // Resolved from the PANE, not from `stackWidth`: the preview must not flip the pane into a
        // different navigation mode. Selecting a file would otherwise turn a two-column stack into a
        // pushing one, and `‹` would start meaning something else than it did a click ago.
        let usesPush = PaneViewMode.usesPushNavigation(paneWidth: paneWidth)
        // Push mode shows only the deepest column; the rest of the stack is still in `browsePath`,
        // which is what lets `‹` walk back out and `›` walk back in.
        let visible = usesPush ? Array(directories.suffix(1)) : directories
        // A single column spans whatever area it has — the whole pane at rest, and the pane minus
        // the preview once one is showing. This is the resting state that makes Columns safe to
        // default to, and what push mode renders at every depth.
        //
        // It deliberately does NOT step back to `columnWidth` when a preview appears. That left a
        // narrow column with a band of dead space beside it AND no divider to fix it with: dividers
        // hang off a column's trailing edge and are only drawn *between* columns, so a lone column
        // had none, and the seam at the preview belongs to the preview. A column that fills its area
        // needs no resizing, which is the same reason the resting single column never had a divider
        // either.
        let spansStack = visible.count == 1

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: !spansStack) {
                HStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element) { offset, directory in
                        let depth = usesPush ? browsePath.depth : offset
                        column(directory: directory, depth: depth,
                               previewSupported: previewSupportable(paneWidth: paneWidth))
                            .frame(width: spansStack ? stackWidth : columnWidth)
                            .id(directory)
                            .overlay(alignment: .trailing) {
                                if !spansStack && offset < visible.count - 1 {
                                    divider
                                }
                            }
                    }
                    trailingDeselectFiller(paneWidth: stackWidth, columnCount: visible.count,
                                           isSingleColumn: spansStack)
                }
                // Inside the ScrollView, so the ancestor walk resolves the STACK's scroll view
                // rather than a column's own list. See `PaneColumnsOverscrollReturn`.
                .background(PaneColumnsOverscrollReturn(holdGate: holdGate))
            }
            .scrollDisabled(spansStack)
            // Keep the deepest column in view as you drill, like Finder.
            .onChange(of: browsePath) { _, _ in
                revealDeepestColumn(proxy)
            }
            // The second driver: the preview ARRIVING — the rising edge only.
            //
            // The preview is pinned OUTSIDE the scroll view, so it does not scroll into or out of
            // the content — it takes points off the stack's VIEWPORT while AppKit keeps the clip's
            // origin exactly where it was. Whatever occupied the points it now covers is simply
            // hidden, and that is the deepest column: the one holding the very file the preview
            // was raised to describe.
            //
            // Nothing else corrected this, and each near-miss is worth stating so it isn't
            // re-attempted:
            //
            // - The `browsePath` driver above cannot. Clicking a file in the deepest column
            //   truncates the stack to that column's own depth, which is a no-op, so `browsePath`
            //   compares equal and the driver never fires. (Not *always* equal: `truncate` also
            //   clears the forward stack, so the same click after a `‹` does move the value and
            //   did scroll correctly — which is why this read as intermittent.)
            // - `PaneColumnsOverscrollReturn` cannot. Narrowing the clip GROWS the legal scroll
            //   range, so the stale origin stays legal and `legalOrigin` finds nothing to clamp.
            //
            // The FALLING edge is deliberately NOT driven — the first application of THE RULE the
            // three geometry drivers below all follow:
            //
            //   **Reveal only on the edge that can newly OCCLUDE the deepest column** — the
            //   stack's content growing, or its viewport shrinking. The opposite edge can only
            //   ever un-hide content, so there is nothing for a reveal to correct there, and
            //   firing anyway force-scrolls a stack the user may have deliberately scrolled back.
            //
            // Closing the preview grows the viewport, so a manually scrolled-back origin is
            // usually still legal, and the right behavior is to stay exactly where the user put
            // it — this handler used to reveal unconditionally, which yanked the whole stack to
            // the deepest column on every preview close and clobbered that scroll-back.
            //
            // The one case a close does break is an origin the grown viewport pushed out of
            // range, i.e. the stack was resting at its far end. That is corrected by the clip
            // itself: `NSClipView` re-constrains its bounds when its frame grows, so the stack
            // lands on the nearest legal origin immediately. This comment used to hand the case
            // to `PaneColumnsOverscrollReturn`'s clamp and describe a 0.14s-quiescence bounce;
            // that is not what happens here — measured by deleting `legalOrigin`'s clamp, after
            // which `ColumnPreviewRevealTests`' close test still passes. The watchdog is the
            // backstop for the clip that does NOT self-correct (a phase-less gesture's leftovers),
            // and `PaneColumnsOverscrollReturnCycleTests` pins it against exactly this shape.
            //
            // Reported as "Tidy works, Compare doesn't". That was pure geometry, not two code
            // paths — a full-width rail has room to spare after the preview takes its 420pt, so a
            // shallow stack stays wholly visible; half a window does not. Measured at the same
            // three-column stack: a 690pt pane narrows to 270 with the deepest column at 420…630
            // (entirely hidden), a 1400pt rail narrows to 980 and keeps it. Both are pinned in
            // `ColumnPreviewRevealTests` so the rail cannot regress the day someone drills deeper.
            .onChange(of: showsPreview) { _, isShowing in
                guard isShowing else { return }
                revealDeepestColumn(proxy)
            }
            // And once the preview's own divider settles. Growing the preview walks the seam left
            // across the deepest column, re-hiding exactly what the driver above reveals.
            //
            // Keyed on the STORED width, which is what makes this the drag's end rather than its
            // every frame: a live drag renders from `dragPreviewWidth` and writes the preference
            // only in `onEnded`. Scrolling per frame would put a programmatic scroll inside a live
            // gesture — the shape that recursed `enforceHold` to depth 1839 and killed a shipped
            // build — and would be pointless besides, since mid-drag the seam is under the user's
            // own cursor and they can see exactly where it is.
            //
            // Gated on THIS pane's `showsPreview`, because the stored width is one process-wide
            // key shared by up to three `PaneColumnsView` instances (both comparison panes and
            // the Tidy rail): ending a drag in one pane fired this handler in every pane, and a
            // pane whose preview is hidden had its viewport untouched by that drag — revealing
            // there force-scrolled a stack the user may have deliberately scrolled back.
            //
            // And gated on the GROWING edge, per THE RULE above: a drag that NARROWS the preview
            // hands the stack's viewport points back, which can only un-hide the deepest column,
            // so there is nothing to correct and a reveal there is the same unasked-for scroll
            // the falling edge of `showsPreview` was making.
            .onChange(of: storedPreviewWidth) { previous, current in
                guard showsPreview, current > previous else { return }
                revealDeepestColumn(proxy)
            }
            // And once the COLUMN divider settles, for the same reason: widening the columns
            // grows every column in the stack, pushing the deepest column's trailing edge right
            // — past the preview's seam when one is open, past the pane's own edge when not —
            // while the clip's origin stays where it was. Same stored-width keying as the
            // preview divider above (drag end, never per frame), and the same defect class:
            // before this driver existed, nothing corrected the occlusion (`legalOrigin` finds
            // nothing to clamp — the origin is still legal, the content just grew past it).
            //
            // Deliberately NOT gated on `showsPreview`, unlike the driver above. The column
            // width is also one shared key, but it changes the CONTENT geometry of every pane's
            // stack — a preview-less pane's deepest column is pushed past the pane edge by the
            // same drag — so every pane has a real occlusion to correct, and firing everywhere
            // is legitimate.
            //
            // Gated on the GROWING edge, per THE RULE above. NARROWING the columns shrinks every
            // stack's content, which can only reduce occlusion: measured, four 300pt columns in a
            // 690pt pane are 1200pt of content, and a drag down to 260 leaves 1040 — nothing that
            // was visible is hidden by it. Firing anyway yanked a pane the user had scrolled back
            // to x=0 forward to x=350, from a drag made in the OTHER pane, which is precisely the
            // asymmetry the `showsPreview` driver above was fixed for.
            //
            // What is deliberately NOT here is an occlusion pre-check ("skip when the deepest
            // column is already fully visible"). The edge guard is the cheap, observable half of
            // that idea; the rest would need the laid-out column frames, which this handler
            // cannot see. The honest residual trade-off it leaves: a pane whose user scrolled
            // back (deepest column occluded by choice) is still brought to its deepest column
            // when any pane's column divider commits WIDER — the same trade the preview
            // divider's driver makes, and pinned as a test so it stays a decision rather than a
            // surprise.
            .onChange(of: storedColumnWidth) { previous, current in
                guard current > previous else { return }
                revealDeepestColumn(proxy)
            }
        }
    }

    /// Brings the deepest column back to the trailing edge of whatever room the stack has — the
    /// seam the preview sits against, or the pane's own edge when there is none.
    ///
    /// Deferred, which every caller needs for the same reason in a different guise: `onChange`
    /// fires while SwiftUI is still applying the update, so the geometry the scroll resolves
    /// against is the OLD one. A drill would target a column the stack has not laid out yet and
    /// land short, leaving the fresh column half off the edge; a preview would resolve `.trailing`
    /// against the viewport width it is in the middle of taking 420pt away from.
    ///
    /// **Issued TWICE, and that is not belt-and-braces.** A too-early scroll does not land short
    /// here — it is silently dropped and never retried. Measured: with the deferral removed
    /// entirely, `.trailing` resolves against the full 690pt viewport, which a 630pt stack already
    /// fits, so SwiftUI concludes no scrolling is required and the stack sits at origin 0 forever.
    /// One runloop turn is *usually* enough to avoid that, but it is a race, not a guarantee: the
    /// same build produced that exact stuck-at-0 result in 4 of 14 full-suite runs and passed the
    /// other 10. A second attempt after the layout has certainly settled costs nothing when the
    /// first one worked — `scrollTo` on a stack already at its trailing edge moves nothing — and is
    /// the difference between "usually reveals the column" and "reveals it".
    ///
    /// **Each attempt resolves its own target**, from `browsePath` as it reads when that attempt
    /// runs — never from the stack the reveal was scheduled against. Resolving once at fire time
    /// let the 0.25s retry speak for a stack that no longer existed: drill a→b at t=0 (attempts at
    /// t=0 and t=0.25), drill b→c at t=0.10 (t=0.10 and t=0.35), and the t=0.25 retry scrolled to
    /// b's trailing edge. That is not a harmless no-op — b is still a real, non-last column, so
    /// the stack visibly jerked BACKWARDS a column's width until t=0.35 put it right. Four drivers
    /// now schedule these, so more paths reach that overlap, not fewer. Reading the binding from
    /// the deferred block is the same live read `DeferredColumnNavigation`'s staleness check makes
    /// one screen below, for the same reason: the block carries no memory of what happened after
    /// it was queued, so it must ask.
    ///
    /// The window it opens is the price: a deliberate scroll made within `revealRetryDelay` of
    /// opening a preview gets overridden. That is a quarter-second after the click that raised the
    /// preview, aimed at the column the user just clicked in, so the correction lands where they
    /// were already looking.
    ///
    /// `anchor: .trailing` always yields a WHOLE column rather than a sliver: `showsPreviewColumn`
    /// refuses a preview unless a full column fits beside it, and `previewPaneWidth` caps the
    /// preview at the pane minus one column, so the stack's viewport is never narrower than
    /// `columnWidth`.
    ///
    /// The animation is taken from the environment rather than written here so a host that cannot
    /// run one can say so — see `paneColumnRevealAnimation`. Read once, before the closure, so both
    /// attempts scroll with the value this update carried — the opposite of the TARGET, which each
    /// attempt re-resolves for the reason given above.
    ///
    /// **An attempt made while this pane's own stack is HELD is deferred, not spent.** The axis
    /// lock's `enforceHold` reverts any horizontal movement of a stack whose pane has a
    /// vertical-dominant wheel gesture in flight, and it cannot tell that gesture's leaked
    /// sideways deltas — the drift it exists to erase — from this reveal's programmatic scroll.
    /// A momentum tail routinely outlasts `revealRetryDelay`: flick vertically in a column, then
    /// drill (by keyboard, or by a click that does not kill the coast), and BOTH attempts land
    /// inside the hold and are reverted. The lock then decays and nothing else fires —
    /// `browsePath` has already moved, the preview and both widths are untouched, and the reverted
    /// origin is perfectly legal so the quiescence return has nothing to clamp. The freshly opened
    /// deepest column stayed hidden behind the pane's edge for good.
    ///
    /// Asking the hold first is what makes the reveal WAIT the gesture out instead of losing to
    /// it, and it leaves the hold itself exactly as it was: while the gesture delivers, the stack
    /// still holds still (that is the sideways-wiggle fix), and `enforceHold` keeps its one-revert-
    /// per-runloop-turn bound — the deferral means there is simply nothing for it to revert. The
    /// question is the SCOPED one, per pane, so a flick in the other pane defers nothing here.
    ///
    /// The alternative — letting the revert record what it defeated and replaying it on release —
    /// was rejected: the watchdog sees only a bounds change, so replaying would restore the
    /// gesture's own leaked drift as readily as a reveal, which is the jitter bug.
    private func revealDeepestColumn(_ proxy: ScrollViewProxy) {
        let animation = revealAnimation
        let gate = holdGate
        func attempt(checksLeft: Int) {
            guard !MainActor.assumeIsolated({ gate.isStackHeld }) else {
                guard checksLeft > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + WheelGestureTracker.staleness) {
                    attempt(checksLeft: checksLeft - 1)
                }
                return
            }
            guard let deepest = browsePath.columnDirectories(treeRoot: treeRoot).last else { return }
            withAnimation(animation) { proxy.scrollTo(deepest, anchor: .trailing) }
        }
        DispatchQueue.main.async { attempt(checksLeft: Self.revealHoldChecks) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealRetryDelay) {
            attempt(checksLeft: Self.revealHoldChecks)
        }
    }

    /// Whether this pane is wide enough to hold a preview column at all — the gate on *offering* the
    /// setting. Distinct from `showsPreviewColumn`, which also asks whether a file is selected and
    /// whether the setting is on: a menu item that vanished whenever the preview it toggles was not
    /// currently on screen would be unreachable exactly when you wanted to switch it back on.
    private func previewSupportable(paneWidth: CGFloat) -> Bool {
        PaneViewMode.showsPreviewColumn(paneWidth: paneWidth, columnWidth: columnWidth,
                                        isEnabled: true, hasPreviewTarget: true)
    }

    /// The dead space to the right of the last column, made a deselect target so that clicking
    /// there behaves like clicking below a column's last row.
    ///
    /// Finder never shows this area — it fills the pane with empty columns — so there is no Finder
    /// answer to borrow for what it should do. It clears the selection and truncates nothing:
    /// there is no column here, so there is no depth to truncate to, and closing the stack from a
    /// click *past* it would be a navigation the user did not ask for.
    ///
    /// Width is zero whenever the stack overflows, so this cannot pad the scroll content — see
    /// `PaneViewMode.trailingFillerWidth`.
    @ViewBuilder
    private func trailingDeselectFiller(paneWidth: CGFloat, columnCount: Int,
                                        isSingleColumn: Bool) -> some View {
        let width = PaneViewMode.trailingFillerWidth(
            paneWidth: paneWidth, columnWidth: columnWidth,
            columnCount: columnCount, isSingleColumn: isSingleColumn)
        if width > 0 {
            Color.clear
                .frame(width: width)
                .contentShape(Rectangle())
                // Plain clicks only, matching the row path and the list catcher: ⌘ and ⇧ belong to
                // the lists' own extend and range-select.
                .onTapGesture {
                    guard PaneViewMode.clickNavigates(modifiers: clickModifiers) else { return }
                    Logger.shared.debug("[deselect] \(isLeft ? "left" : "right") past last column")
                    onBackgroundDeselect(nil)
                }
        }
    }

    /// One column: the rows of `directory`, or a placeholder when it has none.
    ///
    /// A `List` per column rather than a `LazyVStack`, so `onDeleteCommand`, the selection binding
    /// and `PaneListSelectionStyler` keep working instead of being reimplemented three times over.
    @ViewBuilder
    private func column(directory: String, depth: Int, previewSupported: Bool) -> some View {
        let rows = childrenIndex.children(atPath: directory) ?? []
        List(selection: columnSelection(for: rows, depth: depth)) {
            ForEach(rows) { row in
                columnRow(row, depth: depth)
            }
        }
        .listStyle(.sidebar)
        .tint(glassHue.accentColor)
        .background(PaneListSelectionStyler())
        // Clicking below this column's last row deselects and closes the columns to its right,
        // like Finder. The depth is this column's own, so a click in column 0 of three closes two.
        .background(PaneBackgroundDeselect {
            Logger.shared.debug("[deselect] \(isLeft ? "left" : "right") col\(depth) empty area")
            onBackgroundDeselect(depth)
        })
        // Instrumentation for the open "first column moves up and down" report — see
        // `PaneColumnJitterProbe`.
        .background(PaneColumnJitterProbe(depth: depth, isLeft: isLeft))
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, density.metrics.treeIconSize + 6)
        .onDeleteCommand {
            let selected = tree.selectedNodes(at: selection)
            if !selected.isEmpty { delegate.handleDelete(selected) }
        }
        .overlay {
            if rows.isEmpty {
                Text("Empty")
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            SharedFileMenuItems.refresh(delegate: delegate)
            Divider()
            SharedFileMenuItems.newFolder(at: directory, delegate: delegate)
            SharedFileMenuItems.pasteHere(clipboardHasItems: delegate.clipboardHasItems) {
                delegate.handlePasteToPath(directory)
            }
            Divider()
            SharedFileMenuItems.getInfo(for: directory, delegate: delegate)
            // The pane's view options live where Finder keeps its own — the empty-area menu of the
            // very columns they restack. Deliberately NOT in `FileContextMenu`: that menu is built
            // per row, so anything in it exists once per visible file.
            if previewSupported {
                Divider()
                Toggle(isOn: $previewEnabled) {
                    Label("Show Preview", systemImage: "sidebar.right")
                }
            }
        }
    }

    @ViewBuilder
    private func columnRow(_ row: PaneRow, depth: Int) -> some View {
        let node = row.node
        // The folder you drilled *through* stays marked even though the selection has moved on to a
        // deeper column — without it a three-column stack shows no trace of how you got there.
        let isOnPath = depth < browsePath.depth && browsePath.components[depth] == node.name

        ColumnRowView(
            row: row,
            isIgnored: FileTreeView.rowIsIgnored(node, currentPath: treeRoot, delegate: delegate, isSingleSource: isSingleSource),
            diffStatus: diffIndex.status(forNodeId: node.id),
            containedDiffCount: node.isDirectory ? diffIndex.containedDiffCount(forNodeId: node.id) : 0,
            density: density,
            showsChevron: node.isDirectory,
            fonts: fonts,
            riskyReason: delegate.riskyNameReason(forName: row.info.name, isDirectory: row.info.isDirectory),
            awaitingDownloadID: awaitingDownload?.idIfWatching(node.id)
        )
        .tag(node.id)
        // Single click opens a folder's column, per the decision — the one real change to the
        // pane's click contract, and what makes "columns appear when you click" work. A file click
        // closes any deeper columns without opening one of its own.
        //
        // `simultaneousGesture` rather than `onTapGesture`: the tap must not CONSUME the click, so
        // that ⌘- and ⇧-click still reach the List and extend or range-select there. That much is
        // unchanged from `dba5cd3`.
        //
        // What changed is that this handler commits a PLAIN click's selection itself again. Leaving
        // it entirely to the List looked right — it is what the tree presentation does — but it does
        // not survive this gesture: one instrumented session logged **42 column taps and only 8
        // selections**, i.e. this closure ran (the column navigated) while the row never highlighted
        // and the action bar never appeared. That is the dead click, and it is why `[click]` lines
        // were so much rarer than `[columns]` lines in the log.
        //
        // Only a plain click is taken. ⌘ and ⇧ return at the guard below without touching
        // `selection`, so the multi-select `dba5cd3` restored is untouched: the flattening it fixed
        // came from assigning on EVERY tap, modifiers included.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            // ⌘ and ⇧ clicks are the List's business — extend and range-select, no navigation.
            guard PaneViewMode.clickNavigates(modifiers: clickModifiers) else { return }
            if PaneScrollTrace.isEnabled {
                Logger.shared.debug("[tap] \(isLeft ? "left" : "right") col\(depth) \(node.isDirectory ? "dir" : "file") \(node.name)")
            }
            // Before navigating: a drill restructures the column stack, and the selection should be
            // committed against the stack the user clicked in, not the one they are about to get.
            if selection != [node.id] { selection = [node.id] }
            onNavigate(navigation(for: row, depth: depth))
            // No click-cost stamp here any more, and that is deliberate.
            //
            // There have been two, and both measured the user's finger. `[click]` stamps from the
            // selection commit on mouse-DOWN, inside `NSTableView`'s tracking loop, so it spans the
            // hold — `dfa74e4` caught that. `[render]` replaced it by stamping here, in the tap
            // gesture's `onEnded`, and reading back on the next main-queue turn, claiming "this
            // stamp starts after the button is already up, so whatever it measures is work". It
            // does not: across twenty clicks the two agreed to within 0.2ms. This closure runs
            // INSIDE the same tracking loop, so the block it enqueues cannot run until that loop
            // exits — when the button comes up. Moving the stamp changed nothing, because the flaw
            // was never where the stamp was; it was hanging the clock off an input event at all.
            //
            // `MainThreadHitchMonitor` times the run loop instead, which cannot be inflated by a
            // held button because a held button with nothing happening IS the run loop asleep.
        })
        .contextMenu {
            FileContextMenu(
                row: row, selection: selection, tree: tree, otherTree: otherTree,
                otherSelection: otherSelection, isLeft: isLeft, currentPath: treeRoot,
                delegate: delegate, otherPaneName: otherPaneName, isSingleSource: isSingleSource,
                onQuickLook: onQuickLook
            )
        }
        .background(rowPositionProbe(for: node))
        .listRowBackground(rowBackground(for: node, isOnPath: isOnPath))
    }

    /// Selection is confined to one column (decision 5, matching Finder and the pane's flat
    /// `Set<String>`): each column reads the shared selection filtered to its own rows and writes
    /// it wholesale, so selecting here clears every other column by construction.
    private func columnSelection(for rows: [PaneRow], depth: Int) -> Binding<Set<String>> {
        // The membership set used to be built HERE — `Set(rows.map(\.id))` — which meant hashing
        // every row of every open column on every render of the pane, purely to answer an
        // intersection that is empty most of the time. Same answer, computed in the getter and
        // short-circuited when there is nothing to intersect: the common case (no selection, which
        // is every frame of a scroll) now costs nothing at all, and the populated case allocates
        // only the handful of ids that actually match instead of one entry per row.
        Binding(
            get: {
                guard !selection.isEmpty else { return [] }
                return Set(rows.lazy.map(\.id).filter(selection.contains))
            },
            set: { newValue in
                // Logged including the EMPTY writes, which are the interesting ones: an empty write
                // is silent everywhere else (it enforces nothing and takes no token in
                // `applySelectionWrite`), so a selection that lands and is then cleared would look
                // exactly like one that never landed at all. Gated with the rest of the dead-click
                // instrumentation — `[click]` remains as the ungated record that a selection landed.
                if PaneScrollTrace.isEnabled {
                    Logger.shared.debug("[sel] \(isLeft ? "left" : "right") list wrote \(newValue.count) item(s)")
                }
                selection = newValue
                // The List committed this one, which means the tap gesture did NOT — the two never
                // both drive a single click, and the log showed `[sel]` lines with no `[tap]`
                // beside them. Those are the clicks that select a folder and leave its column
                // shut: `TapGesture` fails outright if the pointer drifts even slightly, while
                // `NSTableView` selects on mouse-down regardless.
                //
                // The row used to be `.draggable` too, and that was long blamed for the drift —
                // but cross-pane drag was removed once it turned out never to have started here
                // at all (that competition is exactly what killed it), and the drift remains.
                // `TapGesture`'s own strictness is the whole cause, so BOTH sources still commit.
                //
                // So navigation cannot hang off the gesture alone. Whichever source commits the
                // selection navigates for it, and they agree by construction because both call
                // `navigation(for:depth:)`. A tap that DOES fire drills synchronously and this one
                // then computes the same path, which `setBrowsePath` discards as unchanged.
                guard PaneViewMode.clickNavigates(modifiers: clickModifiers),
                      newValue.count == 1,
                      let id = newValue.first,
                      let row = rows.first(where: { $0.id == id })
                else { return }
                // Both the target and the stack it was computed against are captured NOW. Deferred
                // a runloop turn: `browsePath` restructures the column stack, and writing it from
                // inside the List's own selection commit is the mid-commit sibling write that drops
                // clicks outright (`aa9d407`).
                let stackAtWrite = browsePath
                let path = navigation(for: row, depth: depth)
                DispatchQueue.main.async {
                    guard DeferredColumnNavigation.isStillValid(
                        current: browsePath, computedAgainst: stackAtWrite, target: path)
                    else {
                        Logger.shared.debug("[columns] dropped a stale deferred navigation to \(path.relativePath.isEmpty ? "root" : path.relativePath)")
                        return
                    }
                    onNavigate(path)
                }
            }
        )
    }

    /// Where a click on `row` in the column at `depth` should leave the stack: a folder opens its
    /// own column, a file closes any deeper ones without opening one.
    ///
    /// Shared by the tap gesture and the List's selection commit so the two can never disagree
    /// about what a click means.
    private func navigation(for row: PaneRow, depth: Int) -> PaneBrowsePath {
        var path = browsePath
        if row.node.isDirectory {
            path.drill(into: row.node.name, atDepth: depth)
        } else {
            path.truncate(toDepth: depth)
        }
        return path
    }

    @ViewBuilder
    private func rowBackground(for node: FileNode, isOnPath: Bool) -> some View {
        if selection.contains(node.id) {
            wash(opacity: PaneSelectionWash.opacity(isActivePane: isActivePane))
        } else if isOnPath {
            // Quieter than a selection: this row is the trail, not the target.
            wash(opacity: PaneSelectionWash.opacity(isActivePane: false) * 0.6)
        } else {
            Color.clear
        }
    }

    private func wash(opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(glassHue.accentColor.opacity(opacity))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
    }

    /// Column rows report their bottom edges exactly as tree rows do, so `PaneBarPlacement` keeps
    /// resolving the action bar's edge. The math is purely vertical, so a horizontal stack of
    /// columns needs no change to it — only these probes.
    @ViewBuilder
    private func rowPositionProbe(for node: FileNode) -> some View {
        if placement != nil {
            GeometryReader { proxy in
                Color.clear.preference(key: PaneRowBottomsKey.self,
                                       value: [node.id: proxy.frame(in: .global).maxY])
            }
        }
    }

    /// The draggable seam between two columns. Writes defaults only when the drag ends, so a drag
    /// doesn't churn UserDefaults every frame.
    private var divider: some View {
        dividerChrome {
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    // Capture the starting width once; `translation` is cumulative, so
                    // folding it into the live width compounds every frame.
                    let anchor = dragAnchorWidth ?? columnWidth
                    if dragAnchorWidth == nil { dragAnchorWidth = anchor }
                    dragWidth = PaneViewMode.draggedColumnWidth(anchor: anchor,
                                                                translation: value.translation.width)
                }
                .onEnded { _ in
                    if let dragWidth { storedColumnWidth = Double(dragWidth) }
                    dragWidth = nil
                    dragAnchorWidth = nil
                }
        }
    }

    /// The seam between the scrolling columns and the pinned preview, which resizes the PREVIEW.
    ///
    /// - Parameter rendered: the preview's current laid-out width, which is what the drag starts
    ///   from — the stored preference can differ from it when the `room` cap binds, and anchoring on
    ///   the stored one would jump the seam by the difference on the drag's first pixel.
    private func previewDivider(rendered: CGFloat) -> some View {
        dividerChrome {
            DragGesture(coordinateSpace: .global)
                .onChanged { value in
                    let anchor = dragPreviewAnchor ?? rendered
                    if dragPreviewAnchor == nil { dragPreviewAnchor = anchor }
                    dragPreviewWidth = PaneViewMode.draggedPreviewColumnWidth(
                        anchor: anchor, translation: value.translation.width)
                }
                .onEnded { _ in
                    if let dragPreviewWidth { storedPreviewWidth = Double(dragPreviewWidth) }
                    dragPreviewWidth = nil
                    dragPreviewAnchor = nil
                }
        }
    }

    /// One hairline and the 9pt strip that makes it grabbable. Shared by both dividers so they
    /// cannot drift apart visually; only the gesture differs.
    private func dividerChrome<G: Gesture>(gesture: () -> G) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
                    .gesture(gesture())
            }
    }
}

/// Whether a column navigation queued a runloop turn ago still speaks for the stack.
///
/// The List's selection commit cannot navigate inline — writing `browsePath` from inside it is the
/// mid-commit sibling write that drops clicks outright (`aa9d407`) — so it hands the move to the
/// next runloop turn. That block then carries no memory of what happened in between, and "the main
/// queue always drains between two user events" is exactly the assumption `applySelectionWrite`
/// had to grow a sequencer token to stop relying on. Press `‹` (or let a mirrored drill, or a
/// republish prune, land first) before it runs and the stale block re-applies the click's
/// navigation on top of the newer move — the "Back doesn't work" shape.
///
/// Pure, because the rule reads obvious and has exactly one subtlety worth pinning: the tap
/// gesture's own SYNCHRONOUS drill must not look stale to this test. It leaves `browsePath` equal
/// to `target`, which is why `target` counts as current alongside the stack the block was computed
/// against — a check of `computedAgainst` alone would drop every navigation the tap already made,
/// i.e. all of them.
enum DeferredColumnNavigation {
    static func isStillValid(
        current: PaneBrowsePath,
        computedAgainst: PaneBrowsePath,
        target: PaneBrowsePath
    ) -> Bool {
        current == computedAgainst || current == target
    }
}

/// Preference carrying every visible row's bottom edge in GLOBAL space, keyed by node id.
///
/// Shared by the tree and columns presentations so both feed one `PaneBarPlacement`. Global, not a
/// named space: List rows are hosted in their own AppKit subtrees where a named space silently
/// degrades to global, which is what once flipped the action bar a quarter-viewport early.
struct PaneRowBottomsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { existing, _ in existing }
    }
}

/// A column row: the tree row plus a trailing chevron on folders.
///
/// Wraps `FileRowView` rather than reimplementing it, so the icon, name, cloud badge, difference
/// badge and contained-count pill can't drift between the two presentations — they are the same
/// view, and the chevron is the only thing Columns adds.
struct ColumnRowView: View {
    let row: PaneRow
    let isIgnored: Bool
    let diffStatus: FileDifference.DifferenceType?
    let containedDiffCount: Int
    let density: ListDensity
    let showsChevron: Bool
    /// The pane's resolved fonts — see `PaneRowFonts`.
    var fonts: PaneRowFonts = .unscaled
    /// See `FileRowView.riskyReason`. Resolved by the column, for the same reason the tree row
    /// resolves it: only the pane can reach the delegate.
    var riskyReason: String? = nil
    /// See `FileRowView.awaitingDownloadID`. Threaded through rather than observed here for the
    /// same reason: a per-row subscription for a per-session event.
    var awaitingDownloadID: UUID? = nil

    var body: some View {
        HStack(spacing: 6) {
            FileRowView(node: row.info, isIgnored: isIgnored, diffStatus: diffStatus,
                        containedDiffCount: containedDiffCount, density: density,
                        fonts: fonts, riskyReason: riskyReason, awaitingDownloadID: awaitingDownloadID)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(fonts.chevron)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Click modifiers

private struct PaneClickModifiersKey: EnvironmentKey {
    /// `nil` is "ask the keyboard", which is what the guards did unconditionally before this
    /// existed. Nothing that does not deliberately pin a value changes at all.
    static let defaultValue: NSEvent.ModifierFlags? = nil
}

extension EnvironmentValues {
    /// The modifiers `PaneColumnsView`'s navigation guards read, or `nil` to read the live keyboard.
    ///
    /// A click navigates only when it is plain — ⌘, ⇧ and ⌃ belong to the list's own extend,
    /// range-select and context menu (see `PaneViewMode.clickNavigates`). The guards answered that
    /// with `NSEvent.modifierFlags`, which is not a property of the click, the view, or even the
    /// process: it is **the global state of the machine's keyboard, sampled at the instant the
    /// selection commits.**
    ///
    /// For a real click that is right — the setter runs inside `NSTableView`'s mouse-down tracking
    /// loop, so the flags are the ones the user is holding as they click, and shipped behaviour is
    /// unchanged. For a test it is unwinnable. `ColumnDrillSourceTests` drives
    /// `selectRowIndexes` directly, with no event and no modifiers of its own, and then reads
    /// whatever key the person at the Mac happens to be holding. Hold ⇧ — which typing prose does
    /// roughly a tenth of the time — and the guard returns false, the deferred navigation is never
    /// queued, and the test burns its whole 20s deadline to report `browsePath == []`: the exact
    /// signature of the dropped-click defect it exists to catch.
    ///
    /// That is why it failed only in full-suite runs. A `--filter` run is over in seconds and the
    /// window for a keystroke to land inside it is tiny; a full suite holds the window open for
    /// minutes, on a Mac someone is working at. Load never came into it — the test spends its
    /// deadline because the navigation was never queued, not because it was queued late.
    ///
    /// Pinning `[]` makes the test's premise — *this is a plain click* — part of the test rather
    /// than of the room. Pin `.shift` and it fails on that signature deliberately, which is how the
    /// mechanism was confirmed.
    var paneClickModifiers: NSEvent.ModifierFlags? {
        get { self[PaneClickModifiersKey.self] }
        set { self[PaneClickModifiersKey.self] = newValue }
    }
}

// MARK: - Reveal animation

private struct PaneColumnRevealAnimationKey: EnvironmentKey {
    /// What `revealDeepestColumn` has always scrolled with. The default is the shipped behaviour,
    /// so nothing that does not deliberately opt out changes at all.
    static let defaultValue: Animation? = .easeOut(duration: 0.18)
}

extension EnvironmentValues {
    /// The animation `PaneColumnsView` scrolls its deepest-column reveal with, or `nil` to place
    /// the stack outright.
    ///
    /// This exists for hosts where CoreAnimation does not tick. A SwiftUI animation only advances
    /// while something is driving frames, and the app's window always is — it is on screen and
    /// key, so the reveal eases across in 0.18s exactly as designed. An OFFSCREEN, never-key
    /// `NSWindow` is not: when the machine throttles CoreAnimation, the animation never advances,
    /// the clip's `bounds.origin.x` sits at 0 forever, and the deepest column stays behind the
    /// preview. Two conditions do that throttling, both of them properties of the machine rather
    /// than of any code:
    ///
    /// - the display being asleep, which is the *normal* state of an unattended self-hosted CI
    ///   runner, and
    /// - Low Power Mode on battery.
    ///
    /// Measured on one commit, one clean build, with no source change between the columns:
    ///
    /// | | CoreAnimation ticking | throttled |
    /// |---|---|---|
    /// | `ColumnPreviewRevealTests` | 6/6 pass in 4.7s | **5/6 fail** |
    ///
    /// The failures are the reveal's own numbers — a 690pt pane narrows to 270 with the deepest
    /// column stranded at 420…630 — i.e. indistinguishable from the defect those tests were
    /// written to catch. Machine state, not code, decided the verdict, so any push made while
    /// nobody was at the machine read as red.
    ///
    /// **An ambient override cannot fix this, and that is why the injection point is here.** A
    /// host applying `.transaction { $0.animation = nil }` loses: an explicit `withAnimation` at
    /// the state change wins over the ambient transaction, which is the whole point of
    /// `withAnimation`. The animation has to be absent at the call itself, so the call has to be
    /// able to read that it should be.
    ///
    /// What a `nil` host gives up is only the easing. `scrollTo`'s DESTINATION — the thing every
    /// one of those tests measures — is resolved identically either way; unanimated, the stack is
    /// simply already there when the transaction commits. The reveal's real risks are all in that
    /// destination (which column, against which viewport width, after which layout pass), and a
    /// `nil` host still exercises every one of them, including the twice-issued attempt that
    /// exists because a too-early `scrollTo` is silently dropped.
    var paneColumnRevealAnimation: Animation? {
        get { self[PaneColumnRevealAnimationKey.self] }
        set { self[PaneColumnRevealAnimationKey.self] = newValue }
    }
}
