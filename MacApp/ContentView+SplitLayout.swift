import SwiftUI
import Dashboard
import Design
import Sync

/// The custom pane split layout, extracted from ContentView.swift for size: the horizontal
/// two-pane split, the vertical panes-over-bottom-workspace split, and their invisible
/// drag-to-resize handles. An extension (not separate Views) because the splits read
/// ContentView's fraction state and pane builders directly; the members they touch are
/// internal rather than private so this file can live outside ContentView.swift.
extension ContentView {

    /// Name of the coordinate space spanning the pane row, so the divider drag can read the
    /// cursor's absolute x position independent of the divider's own (moving) frame.
    static let paneRowSpace = "panesRow"
    static let verticalStackSpace = "verticalStack"

    /// Two file panes side by side with a draggable divider between them. This replaces
    /// `HSplitView`: its NSSplitView-backed divider ignored the top safe area and drew up
    /// through the `.hiddenTitleBar` toolbar band, whereas this SwiftUI HStack lays out
    /// entirely within the safe area, so the divider starts at the pane headers. Drag-to-resize
    /// is preserved via a hit-testable divider handle that updates `paneSplitFraction`.
    @ViewBuilder
    var panesSplit: some View {
        GeometryReader { geo in
            // Named on `PaneLogic` so the sidebar's width clamp reasons about the SAME number —
            // two copies of a layout minimum is how a clamp comes to disagree with what it clamps.
            let minPane = PaneLogic.minComparePaneWidth
            let totalWidth = geo.size.width
            // Clamp so neither pane goes below minPane (degrades gracefully in a too-narrow window).
            let minFraction = PaneLogic.horizontalMinFraction(totalWidth: totalWidth, minPane: minPane)
            // While dragging, the live @State value drives the layout; otherwise the persisted one.
            let fraction = PaneLogic.clampedFraction(paneDragFraction ?? paneSplitFraction,
                                                     lower: minFraction, upper: 1 - minFraction)
            let leftWidth = totalWidth * fraction
            HStack(spacing: 0) {
                paneColumn(isLeft: true)
                    .frame(width: leftWidth)
                paneColumn(isLeft: false)
                    .frame(width: totalWidth - leftWidth)
            }
            .frame(width: totalWidth, height: geo.size.height)
            // Panes sit flush (no divider element) so they read as one continuous surface with no
            // seam. An invisible, hit-testable handle straddles the boundary to preserve resize.
            .overlay(alignment: .leading) {
                paneResizeHandle(totalWidth: totalWidth, minFraction: minFraction)
                    .offset(x: leftWidth - 6)
            }
            // The seam's own controls — ⇄ swap and 🔗 link-both — in one capsule straddling the
            // boundary. Pinned to the top so they don't eat the drag-to-resize area below.
            .overlay(alignment: .topLeading) {
                SeamPaneControls(hue: glassHue, onSwap: swapPanesAction)
                    .offset(x: leftWidth - 13, y: 8)
            }
            .coordinateSpace(.named(Self.paneRowSpace))
        }
        // The Space → Quick Look handler is NOT here any more. It hangs off each pane's file list
        // instead — see `paneQuickLook()` in `ContentView+PaneSearch.swift` for why the whole column
        // was the wrong subtree.
    }

    /// Invisible 12pt-wide drag handle centered on the pane boundary (the shared `ResizeHandle`).
    /// The drag reads the cursor's absolute x within the pane row (a fixed coordinate space) via
    /// `PaneLogic`'s clamp math and persists `paneSplitFraction` only on release.
    @ViewBuilder
    private func paneResizeHandle(totalWidth: CGFloat, minFraction: Double) -> some View {
        ResizeHandle(
            axis: .horizontal,
            coordinateSpace: .named(Self.paneRowSpace),
            onDrag: { value in
                guard totalWidth > 0 else { return }
                let f = PaneLogic.horizontalDragFraction(locationX: value.location.x, totalWidth: totalWidth)
                paneDragFraction = PaneLogic.clampedFraction(f, lower: minFraction, upper: 1 - minFraction)
            },
            onCommit: {
                if let f = paneDragFraction { paneSplitFraction = f }
                paneDragFraction = nil
            }
        )
    }

    /// The panes stacked over the bottom workspace, with a draggable — but invisible — horizontal
    /// divider between them. Replaces `VSplitView` so the divider line can be hidden (VSplitView's
    /// divider isn't customizable) while keeping resize. Because the split ratio is driven by
    /// `bottomPaneFraction`, it never resets when the Differences/Details tab changes.
    static let railRowSpace = "railRow"

    @ViewBuilder
    var verticalSplit: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            switch contentLayout {
            case .compareSplit:
                // ONE structure for both the expanded and collapsed states — the same `panesSplit`,
                // divider, and `bottomPaneView` children in the same positions — so collapsing keeps
                // their identity instead of tearing down and rebuilding the two ~40k-row Lists (which
                // was the collapse's lag). Only the frame heights and the divider's presence change:
                //   • expanded  — panes fill the space above a fraction-sized bottom pane, drag divider.
                //   • collapsed — panes fill everything above the bottom pane, which hugs its header
                //                 strip (height nil = intrinsic), and the divider goes to zero height.
                let collapsed = bottomPaneIsCollapsed
                let minTop: CGFloat = 220
                let minBottom: CGFloat = 150
                let dividerHeight: CGFloat = collapsed ? 0 : 1
                let panesHeight = PaneLogic.verticalPanesHeight(totalHeight: totalHeight, dividerHeight: dividerHeight)
                // fraction = the bottom pane's share; clamp so neither section drops below its min.
                let minFraction = PaneLogic.verticalMinFraction(panesHeight: panesHeight, minBottom: minBottom)
                let maxFraction = PaneLogic.verticalMaxFraction(panesHeight: panesHeight, minTop: minTop, minFraction: minFraction)
                let fraction = PaneLogic.clampedFraction(verticalDragFraction ?? bottomPaneFraction,
                                                         lower: minFraction, upper: maxFraction)
                let bottomHeight = panesHeight * fraction
                // **Leading and OUTSIDE the vertical stack**, exactly as in `browseLayout` and for
                // the same reason: the remembered folders belong to the panes' sources, not to the
                // Differences table stacked under them, so the column spans the whole height rather
                // than shrinking when the bottom pane grows.
                //
                // `sidebarSlot` is subtracted into its own name and never into `geo.size.width` —
                // shadowing that is what put the sidebar outside the window in the lens layout
                // (see `PaneLogic.LensRow`). The row keeps its true width; only the stack beside
                // the column is narrowed.
                let sidebarWidth = folderSidebarIsShowing
                    ? PaneLogic.compareSidebarWidth(stored: browseSidebarWidth,
                                                    totalWidth: geo.size.width,
                                                    minSidebar: FolderSidebarView.minWidth,
                                                    gutter: LiquidGlass.cardGutter)
                    : 0
                // The seam strip is in this slot too — see `PaneLogic.LensRow.sidebarSlot` for the
                // 1pt overflow that leaving it out costs.
                let sidebarSlot = folderSidebarIsShowing
                    ? sidebarWidth + PaneLogic.sidebarOverhead(gutter: LiquidGlass.cardGutter) : 0
                HStack(spacing: 0) {
                    if folderSidebarIsShowing {
                        folderSidebar(width: sidebarWidth)
                        folderSidebarResizeHandle(displayedWidth: sidebarWidth)
                    }
                    VStack(spacing: 0) {
                        panesSplit
                            .panesRegionFrame(surfaceStyle, level: glassLevel)
                            .frame(maxHeight: .infinity)
                        verticalResizeDivider(panesHeight: panesHeight, minFraction: minFraction, maxFraction: maxFraction)
                            .frame(height: dividerHeight)
                            .opacity(collapsed ? 0 : 1)
                            .allowsHitTesting(!collapsed)
                        bottomPaneView
                            // nil height when collapsed → the bottom pane hugs its header strip; a fixed
                            // fraction height when expanded. Same modifier either way, so identity holds.
                            .frame(height: collapsed ? nil : bottomHeight)
                    }
                    .frame(width: geo.size.width - sidebarSlot)
                    .coordinateSpace(.named(Self.verticalStackSpace))
                }
                .frame(width: geo.size.width, height: totalHeight)
            case .singleExpanded, .singleCollapsed:
                // Single-source: the source rail docked left of a full-height workspace,
                // laid out horizontally — collapsed to a spine, or expanded to a resizable pane.
                singleSourceLayout(collapsed: contentLayout == .singleCollapsed, geo: geo)
            case .browseFull:
                browseLayout(geo: geo)
            case .editorExpanded, .editorCollapsed:
                editorLayout(collapsed: contentLayout == .editorCollapsed, geo: geo)
            }
        }
    }

    /// The single-source horizontal layout: a collapsed spine or an expanded, resizable source pane
    /// on the left, and the workspace filling the rest.
    @ViewBuilder
    func singleSourceLayout(collapsed: Bool, geo: GeometryProxy) -> some View {
        let totalWidth = geo.size.width
        if collapsed {
            HStack(spacing: 0) {
                railSpine
                // Collapsed, the workspace has everything but the spine — and the spine is what
                // the overflow would land on. Same reason as the split branch below.
                bottomPaneView
                    .frame(maxWidth: .infinity)
                    .clipped()
            }
            .frame(width: totalWidth, height: geo.size.height)
        } else {
            // **The sidebar comes off the top, and the rest divides as it always did.**
            //
            // Taking its width out of `totalWidth` before the fractions are computed is what keeps
            // the rail and the lens panel honest: they go on being measured against the room they
            // actually have, so their minimums mean the same thing whether or not a sidebar is up,
            // and `railFraction` keeps describing the split between those two rather than silently
            // becoming a three-way share.
            //
            // The width itself is clamped, not the stored one — see `PaneLogic.lensSidebarWidth`.
            // Browse can afford whatever the user stored; here three things divide one row, and at
            // the 760 window floor the rail and panel claim 560 of it.
            let sidebarWidth = folderSidebarIsShowing
                ? PaneLogic.lensSidebarWidth(stored: browseSidebarWidth, totalWidth: totalWidth,
                                             minSidebar: FolderSidebarView.minWidth,
                                             gutter: LiquidGlass.cardGutter)
                : 0
            // **`splitWidth`, never a shadowed `totalWidth`.** The fractions and the two minimums
            // are measured against the room the rail and the workspace actually divide, while the
            // ROW is still the full width — and conflating those two is not a hypothetical: the
            // first version of this shadowed `totalWidth`, the reduced value reached the row's own
            // `.frame(width:)`, and the sidebar rendered outside the window. See `PaneLogic.LensRow`.
            let splitWidth = totalWidth - (folderSidebarIsShowing
                ? sidebarWidth + PaneLogic.sidebarOverhead(gutter: LiquidGlass.cardGutter) : 0)
            let minRail = PaneLogic.minRailWidth
            let minWorkspace = PaneLogic.minLensWorkspaceWidth
            let lower = minRail / max(splitWidth, 1)
            let upper = 1 - minWorkspace / max(splitWidth, 1)
            // In a very narrow window the two minimums can't both be honored; pin to the rail min.
            let fraction = (lower <= upper)
                ? PaneLogic.clampedFraction(railDragFraction ?? railFraction, lower: lower, upper: upper)
                : lower
            let row = PaneLogic.lensRow(totalWidth: totalWidth, sidebarWidth: sidebarWidth,
                                        showsSidebar: folderSidebarIsShowing,
                                        gutter: LiquidGlass.cardGutter, fraction: fraction)
            HStack(spacing: 0) {
                // Leading, exactly as in `browseLayout` — the remembered folders belong to the
                // pane's source, and here that pane is the rail. Organize's scope and Storage's
                // root both already follow it (`lensScanRootExpanded` reads the targeted pane's
                // current directory), so a click here moves the lens with the pane and needs no
                // workspace-specific wiring at all.
                if folderSidebarIsShowing {
                    folderSidebar(width: sidebarWidth)
                    folderSidebarResizeHandle(displayedWidth: sidebarWidth)
                }
                // Space → Quick Look rides inside `paneColumn`, on the file list — not out here on
                // the whole column. See `paneQuickLook()`.
                paneColumn(isLeft: true)
                    .panesRegionFrame(surfaceStyle, level: glassLevel)
                    .frame(width: row.railWidth)
                // **The workspace may not paint on the pane beside it.** A `LensHeaderCard` whose
                // row 2 holds `.fixedSize()` prose and a control does not shrink to the width it is
                // offered — its own `.frame(maxWidth: .infinity)` reports the LARGER of the proposal
                // and what its children insist on — and SwiftUI centres an oversized child, so the
                // excess spills past BOTH edges. The workspace is drawn after the source pane, so
                // the left half of that excess landed on the file list: at the 340pt floor with
                // Duplicates selected the card measures ~600pt, and rail items, a "410 groups" pill
                // and half of "1.7 MB reclaimable" were painted over a pane they have nothing to do
                // with, while "Apply 410 recommended" ran off the other side.
                //
                // The clip belongs HERE and nowhere inside the card: this is the only place that
                // knows a definite width. A `.clipped()` on the card clips to the card's own
                // resolved 600pt and is a no-op — measured, 6,678 pixels of ink outside the column
                // either way (`LensHeaderCardOverrunTests`).
                bottomPaneView
                    .frame(width: row.workspaceWidth)
                    .clipped()
            }
            .frame(width: totalWidth, height: geo.size.height)
            .overlay(alignment: .leading) {
                // Offset from the ROW's leading edge, which is not the rail's once a sidebar sits
                // in front of it — see `LensRow.railHandleOffset`.
                railResizeHandle(splitWidth: row.splitWidth, sidebarSlot: row.sidebarSlot,
                                 lower: lower, upper: upper)
                    .offset(x: row.railHandleOffset)
            }
            .coordinateSpace(.named(Self.railRowSpace))
        }
    }

    /// Browse: the source pane with the whole window, and nothing else in it.
    ///
    /// This is `singleSourceLayout(collapsed: false, …)` with the workspace half, the divider and
    /// the fraction arithmetic taken out — there is no second region for a fraction to divide.
    /// What it deliberately keeps is everything that makes that column a pane rather than a list:
    /// the same `paneColumn(isLeft: true)` and the same region frame — and, inside that column,
    /// the same Space → Quick Look handler every other pane gets (`paneQuickLook()`).
    ///
    /// **Except while a person gather is up.** Browse's pane search offers "everything that is
    /// theirs" like every other pane does, so Browse has to be able to *show* the answer — with
    /// nothing else in the window, an accept here started the sweep and changed no pixel, and the
    /// only exit (switching workspace) threw the answer away. The gather takes a resizable bottom
    /// slot of the same shape Compare's is, and shares its remembered fraction
    /// (`mainBottomPaneFraction`) — so dragging it here does move Compare's divider, which is one
    /// remembered "bottom share" rather than two. **Not** the lens workspaces: those lay out
    /// horizontally (`singleSourceLayout`, sized by `railFraction`) and give the gather the whole
    /// workspace column. No collapse rung either: this slot is temporary and the ✕ and Esc already
    /// give the window back, where Compare's bottom pane is permanent furniture.
    /// **One structure whether or not a gather is up**, for the reason `.compareSplit` gives a few
    /// lines above: the column is a ~40k-node selection walk feeding a `List`, and putting it in
    /// two branches of an `if` gives it two identities — so accepting a person offer would tear
    /// the file column down and rebuild it, losing its scroll position and its expanded folders,
    /// and clearing the gather would do it again. Only the divider's height and the third child's
    /// presence change; the column stays the first child of the same `VStack` throughout.
    @ViewBuilder
    func browseLayout(geo: GeometryProxy) -> some View {
        let hasGather = personScope != nil
        let minTop: CGFloat = 220
        let minBottom: CGFloat = 150
        let dividerHeight: CGFloat = hasGather ? 1 : 0
        let panesHeight = PaneLogic.verticalPanesHeight(totalHeight: geo.size.height,
                                                        dividerHeight: dividerHeight)
        let minFraction = PaneLogic.verticalMinFraction(panesHeight: panesHeight, minBottom: minBottom)
        let maxFraction = PaneLogic.verticalMaxFraction(panesHeight: panesHeight, minTop: minTop,
                                                        minFraction: minFraction)
        let fraction = PaneLogic.clampedFraction(verticalDragFraction ?? bottomPaneFraction,
                                                 lower: minFraction, upper: maxFraction)
        HStack(spacing: 0) {
            // **Leading, and outside the vertical stack.** The remembered folders belong to the
            // pane's *source*, not to whatever is stacked under the pane — a gather is a temporary
            // answer to a search, and a sidebar that shrank when one opened would read as part of
            // it. This also keeps `browseLayout`'s "one structure whether or not a gather is up"
            // rule intact: the sidebar's presence changes nothing about the VStack beside it.
            //
            // False from 2026-08-20 until v4.4, while the column was held: the branch and its
            // divider were written, reviewed and unreachable. Live since #13 landed.
            if folderSidebarIsShowing {
                folderSidebar(width: browseSidebarWidth)
                folderSidebarResizeHandle(displayedWidth: browseSidebarWidth)
            }
            VStack(spacing: 0) {
                paneColumn(isLeft: true)
                    .panesRegionFrame(surfaceStyle, level: glassLevel)
                    .frame(maxHeight: .infinity)
                verticalResizeDivider(panesHeight: panesHeight, minFraction: minFraction,
                                      maxFraction: maxFraction)
                    .frame(height: dividerHeight)
                    .opacity(hasGather ? 1 : 0)
                    .allowsHitTesting(hasGather)
                if let scope = personScope {
                    personGatherSection(scope)
                        .frame(height: panesHeight * fraction)
                }
            }
            .coordinateSpace(.named(Self.verticalStackSpace))
        }
        .frame(width: geo.size.width, height: geo.size.height)
    }

    /// **The sidebar's drag handle**, and the seam between it and the pane.
    ///
    /// The column was fixed at 180 through v4.3 on the reasoning that "the pane beside it is the
    /// resizable one". With eleven sources listed and several needing an account to tell them apart,
    /// 180 leaves about 136pt for a name plus its account, so the width becomes the user's own
    /// answer to how much name they want to pay for.
    ///
    /// **A clear 1pt strip, not a `Divider`** — the same construction as the Info inspector's edge,
    /// for the same reason: both sides of this seam are cards now, so the gutter between them draws
    /// the separation and a rule down the middle of it would be a third edge between two that are
    /// already there. Only the hit target remains, straddling the gap.
    ///
    /// **It clamps, it never closes.** Dragged past either end the width stops; it does not collapse
    /// the column, because a panel that closes itself when you resize it is the behaviour people
    /// file bugs about, and ⌃⌘S is right there. The stored value is clamped on read as well as on
    /// write — see `browseSidebarWidth`.
    /// - Parameter displayedWidth: the width the column is currently DRAWN at, which the drag
    ///   measures from. Not `browseSidebarWidth`: in a lens workspace at a narrow window the stored
    ///   value can exceed what fits, and starting the drag from the stored number would make the
    ///   column jump to it the moment the pointer moved.
    @ViewBuilder
    func folderSidebarResizeHandle(displayedWidth: CGFloat) -> some View {
        Color.clear.frame(width: PaneLogic.sidebarSeamWidth)
            .overlay {
                // `ResizeHandle`, not a hand-rolled gesture: this was the one seam in the window
                // that wrote its own, and it paid for it twice — an `NSCursor.push()`/`pop()` pair
                // in `onHover` that leaks a pushed cursor if the column is hidden mid-hover (⌃⌘S
                // is one keystroke away), and a pointer that read as a resize while the shared
                // component's `.columnResize` is what every other seam shows.
                ResizeHandle(
                    axis: .horizontal,
                    thickness: 10,
                    minimumDistance: 1,
                    coordinateSpace: .global,
                    onDrag: { value in
                        // From the width at the START of this drag, not from the live value: adding
                        // each frame's translation to an already-updated width compounds it, and the
                        // column runs away from the pointer.
                        let base = folderSidebarDragOrigin ?? displayedWidth
                        if folderSidebarDragOrigin == nil { folderSidebarDragOrigin = base }
                        browseSidebarWidthRaw = Double(min(max(base + value.translation.width,
                                                               FolderSidebarView.minWidth),
                                                           FolderSidebarView.maxWidth))
                    },
                    onCommit: { folderSidebarDragOrigin = nil }
                )
            }
    }

    /// The collapsed source rail: a thin, clickable spine that expands the pane when clicked (the
    /// same action the toolbar's pane toggle performs). Icon-only by design — the provider name
    /// lives once in the workspace's source bar while collapsed, so the spine doesn't repeat it.
    @ViewBuilder
    var railSpine: some View {
        let provider = settings.availableProviders.first(where: { $0.id == leftProviderId })
        let name = provider?.displayName ?? "Source"
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { togglePanesForCurrentTab() }
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .scaledFont(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Image(systemName: "cloud")
                    .scaledFont(.system(size: 14, weight: .semibold))
                    .foregroundStyle(glassHue.accentColor)
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .frame(width: 34)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.row, tint: glassHue.accentColor, shape: .roundedRect(8)))
        // A slim card, not a docked `.bar` strip: the bar fill stayed opaque at Clear and sat
        // flush against the root padding while every neighbor floated — the spine joins the gap
        // model instead (5pt to the window edge and to the workspace card beside it).
        .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        .help("Show the \(name) pane to browse or re-scope")
        .accessibilityLabel("Show the \(name) source pane")
    }

    /// Invisible drag handle on the rail/workspace boundary — mirrors `paneResizeHandle` but writes
    /// the rail fraction and reads the rail-row coordinate space.
    @ViewBuilder
    /// - Parameters:
    ///   - splitWidth: the room the rail and the workspace divide — what `railFraction` is a
    ///     fraction OF. Not the row: a sidebar is not part of this split.
    ///   - sidebarSlot: how far the split's leading edge sits from the row's. The drag reads
    ///     `railRowSpace`, which is anchored to the ROW, so the pointer's x has to be rebased or
    ///     every drag lands one sidebar-width to the right of where the cursor is.
    // Internal rather than private: the Editor's layout lives in `ContentView+Editor` and divides
    // the same rail row against the same fraction.
    func railResizeHandle(splitWidth: CGFloat, sidebarSlot: CGFloat,
                                  lower: Double, upper: Double) -> some View {
        ResizeHandle(
            axis: .horizontal,
            coordinateSpace: .named(Self.railRowSpace),
            onDrag: { value in
                guard splitWidth > 0, lower <= upper else { return }
                let f = PaneLogic.horizontalDragFraction(locationX: value.location.x - sidebarSlot,
                                                         totalWidth: splitWidth)
                railDragFraction = PaneLogic.clampedFraction(f, lower: lower, upper: upper)
            },
            onCommit: {
                if let f = railDragFraction { railFraction = f }
                railDragFraction = nil
            }
        )
    }

    /// The invisible, draggable horizontal divider between the panes and the bottom workspace.
    /// Like the vertical one, it tracks the cursor's absolute y in a fixed coordinate space and
    /// persists only on release.
    @ViewBuilder
    private func verticalResizeDivider(panesHeight: CGFloat, minFraction: Double, maxFraction: Double) -> some View {
        Rectangle()
            .fill(Color.clear)
            .overlay {
                ResizeHandle(
                    axis: .vertical,
                    coordinateSpace: .named(Self.verticalStackSpace),
                    onDrag: { value in
                        guard panesHeight > 0 else { return }
                        let f = PaneLogic.verticalDragFraction(locationY: value.location.y, panesHeight: panesHeight)
                        verticalDragFraction = PaneLogic.clampedFraction(f, lower: minFraction, upper: maxFraction)
                    },
                    onCommit: {
                        if let f = verticalDragFraction { bottomPaneFraction = f }
                        verticalDragFraction = nil
                    }
                )
            }
    }
}

/// The controls that belong to the seam itself: ⇄ swap on top, 🔗 link-both underneath, in one
/// capsule straddling the boundary between the panes.
///
/// Link used to be a chain at the trailing end of *each* pane's breadcrumb — two buttons writing
/// one `@AppStorage` key, which is one button more than a single setting needs. Folding it in
/// beside swap also puts it where its meaning already lives: what it joins is the gap it sits in.
///
/// Both halves are square, so the capsule's ends are true semicircles — which is what lets the
/// linked fill below be an exact bottom half, and lets each half wear the same circular hover
/// wash the lone swap chip used to have.
struct SeamPaneControls: View {
    let hue: LiquidGlassHue
    let onSwap: () -> Void

    /// The one link preference in the app; `PaneLinkPreference` names its other readers.
    @AppStorage(PaneLinkPreference.defaultsKey) private var linkBothPanes = false

    /// Read because the pill is hue-washed now, which makes every engaged colour in it depend on
    /// which side of the surface it has to shift against. See `engagedWash` and `glyphInk`.
    @Environment(\.colorScheme) private var colorScheme

    /// Shared with the two glyph views, which size themselves to one half.
    fileprivate static let half: CGFloat = 26

    /// How much of the hue the resting capsule carries over its material — frosted, not solid, so
    /// the material still reads through it.
    ///
    /// 0.14 rather than something bolder because the button style's own wash stacks on top of it,
    /// and stacking puts the seam on the nav pills' ladder instead of beside it: 0.14 rest →
    /// 0.14 + 0.14·0.86 = **0.26** hovered → 0.14 + 0.24·0.86 = **0.35** pressed, against
    /// `PaneNavChrome`'s 0.22 and 0.34. A heavier rest would put an idle seam at the weight the
    /// pills next to it use for *hovered*.
    fileprivate static let restWash: Double = 0.14

    /// Ink for a seam half that is **not** carrying the linked fill: neutral at rest, and on a LIGHT
    /// appearance the deepened accent once the pointer is on it.
    ///
    /// Deepened rather than `accentColor` because the pill it sits on is now the accent too. On the
    /// light composite a raw-accent glyph runs 1.58:1 (Cyan) to 3.53:1 (Indigo) — nine of the eleven
    /// hues under the 3:1 floor, i.e. hovering would make the glyph *harder* to read than at rest.
    /// `accentFillColor` is bounded below by construction and clears 3:1 on every hue (3.21:1 worst,
    /// on Purple). Rest measures 8.4–8.9:1.
    ///
    /// **Dark drops the tint entirely, and that is not symmetry for its own sake.** Deepening means
    /// darkening, so on a dark pill it moves the ink *toward* the surface: rendered and sampled over
    /// three plausible dark grounds, a deepened Cyan glyph measures 1.58–2.60:1 where the raw accent
    /// gets 3.08–5.07:1 and plain `.primary` more still. Applying the light-appearance answer to both
    /// was the defect this call originally shipped with. `ChromeInk` already owns exactly this rule —
    /// on a washed surface the fill is the only honest carrier of hover — so route through it rather
    /// than restating it, and let `engagedWash` carry the hover in dark.
    fileprivate static func glyphInk(_ scheme: ColorScheme,
                                     deepened: Color,
                                     phase: HoverAffordancePhase) -> Color {
        ChromeInk.label(scheme, light: phase.isEngaged ? deepened : .primary.opacity(0.75))
    }

    /// The accent depth that actually registers *against the pill*, which flips with the appearance
    /// for the same reason `glyphInk` does: `accentFillColor` is darker than the light pill (good)
    /// and barely distinguishable from the dark one (bad). Sampled hover step on the dark grounds:
    /// 1.30–1.35× raw against 1.13–1.16× deepened; on light, 1.15–1.17× deepened against 1.07× raw.
    ///
    /// Not `linked`'s wash — that one stays `onAccentLabelColor` in both appearances, because it
    /// lands on the solid fill rather than on this frost.
    private var engagedWash: Color {
        colorScheme == .dark ? hue.accentColor : hue.accentFillColor
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSwap) {
                SwapPanesGlyph(deepened: hue.accentFillColor)
            }
            // `.glyph`, not `.circular`: the capsule is what floats now, and a half that lifted
            // on hover would peel out of chrome that stayed put. Same wash and ring numbers,
            // minus the lift — and the shape override keeps the wash round inside the pill.
            //
            // Washes in `engagedWash`, not the raw hue: the pill underneath is already the raw
            // accent, so on light there is nothing for a raw wash to shift against.
            .buttonStyle(.hoverAffordance(.glyph, tint: engagedWash, shape: .circle))
            // The tab lists move with the panes — see `FileSyncManager.swapPanes`. Said here
            // because it is the one consequence of ⇄ that is invisible until you look up and find
            // the other pane's tabs where yours were.
            .help("Swap the left and right panes, tabs and all")

            // Stays NEUTRAL while everything around it goes to the hue: this hairline has to read
            // against the frosted wash above it *and* against the solid `accentFillColor` below it
            // when linked, and an accent line on an accent fill is not a line at all.
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: Self.half, height: 0.5)

            Button {
                linkBothPanes.toggle()
            } label: {
                LinkPanesGlyph(deepened: hue.accentFillColor,
                               onAccent: hue.onAccentLabelColor,
                               isLinked: linkBothPanes)
            }
            // The hover wash has to show against whatever is under it, and that changes with the
            // state: `engagedWash` over the frosted pill when unlinked, white over the solid accent
            // fill when linked — an accent wash on an accent fill carries no colour at all.
            .buttonStyle(.hoverAffordance(
                .glyph,
                tint: linkBothPanes ? hue.onAccentLabelColor : engagedWash,
                shape: .circle
            ))
            .help(linkBothPanes
                ? "Linked: clicking a folder moves both panes. Click to unlink."
                : "Link panes: clicking a folder will move both. Tip: hold ⌥ to do it once.")
            .accessibilityLabel("Link both panes")
            .accessibilityValue(linkBothPanes ? "On" : "Off")
            .accessibilityAddTraits(linkBothPanes ? .isSelected : [])
        }
        // The linked fill goes in the BACKGROUND rather than inside the button's label so the
        // style's own hover wash still lands on top of it instead of underneath.
        .background(alignment: .bottom) {
            if linkBothPanes {
                UnevenRoundedRectangle(bottomLeadingRadius: Self.half / 2,
                                       bottomTrailingRadius: Self.half / 2,
                                       style: .continuous)
                    .fill(hue.accentFillColor)
                    .frame(height: Self.half)
            }
        }
        // Material base plus a frosted ACCENT wash. The neutral 0.075 this replaces put the pill at
        // `PaneNavChrome`'s resting weight, which was the right call for a control sitting *in* the
        // nav row — but this one floats over pane content, on a window whose background is already
        // the hue, and a grey chip on a hue-washed pane reads as an unstyled blob rather than as a
        // quiet one. Behind the linked fill, which is the later layer.
        .background(Capsule().fill(.regularMaterial)
            .overlay(Capsule().fill(hue.accentColor.opacity(Self.restWash))))
        // The capsule floats over pane content rather than over chrome, so unlike the nav pills it
        // needs an edge of its own to sit against a light file list — now in the hue as well, so
        // the pill reads as one accent object instead of a tinted fill in a grey ring.
        .overlay(Capsule().strokeBorder(hue.accentColor.opacity(0.35), lineWidth: 0.75))
    }
}

/// The ⇄ half of `SeamPaneControls`.
///
/// Its own `View` type because it reads the enclosing hover-affordance button's phase, which
/// needs an `@Environment`. The chrome it used to draw for itself now belongs to the capsule.
struct SwapPanesGlyph: View {
    /// `LiquidGlassHue.accentFillColor`, not `accentColor` — see `SeamPaneControls.glyphInk`.
    let deepened: Color

    @Environment(\.hoverAffordancePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Pressing turns the glyph over — the same thing the click is about to do to the panes, so
    /// the feedback names the outcome instead of just acknowledging the click. Dropped under
    /// Reduce Motion, where the style's wash still carries the press.
    private var flipped: Bool { phase == .pressed && !reduceMotion }

    var body: some View {
        Image(systemName: "arrow.left.arrow.right")
            .scaledFont(.system(size: 11, weight: .bold))
            .foregroundStyle(SeamPaneControls.glyphInk(colorScheme, deepened: deepened, phase: phase))
            .rotationEffect(.degrees(flipped ? 180 : 0))
            // `designAnimation` rather than `animation` for one spelling across the app, but note
            // that **the gate here is `flipped`, not the modifier**: it already folds
            // `!reduceMotion` in, so under the setting the value never changes and there is nothing
            // to animate either way. Belt and braces, not the mechanism — don't read this line as
            // the thing that honours the setting, and don't remove the check in `flipped` because
            // this line looks like it covers it.
            .designAnimation(.easeInOut(duration: 0.16), value: flipped)
            .frame(width: SeamPaneControls.half, height: SeamPaneControls.half)
    }
}

/// The 🔗 half of `SeamPaneControls`.
///
/// A chain, not ⇄ — the ⇄ arrows are reserved for swap-panes (UX 1.2). There is no `link.slash` in
/// SF Symbols, so off/on is carried by the fill, not a second glyph.
///
/// Its own `View` type for the same reason `SwapPanesGlyph` is: the resting ink now depends on the
/// enclosing button's hover phase, and that only resolves inside the style's body. Written inline in
/// the parent it would read the *parent's* environment and never leave `.rest`.
struct LinkPanesGlyph: View {
    /// `LiquidGlassHue.accentFillColor`, not `accentColor` — see `SeamPaneControls.glyphInk`.
    let deepened: Color
    let onAccent: Color
    let isLinked: Bool

    @Environment(\.hoverAffordancePhase) private var phase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: PaneGlyph.linkBothPanes)
            .scaledFont(.system(size: 11, weight: .bold))
            // Linked keeps both of its colours — white on the deepened accent fill underneath. It
            // still reads as the "on" state now that the pill itself carries the hue, because what
            // separates them is opacity, not colour: a SOLID half against a 0.14 frost, with the
            // only white glyph in the control on it.
            .foregroundStyle(isLinked
                ? onAccent
                : SeamPaneControls.glyphInk(colorScheme, deepened: deepened, phase: phase))
            .frame(width: SeamPaneControls.half, height: SeamPaneControls.half)
    }
}
