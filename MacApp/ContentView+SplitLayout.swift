import SwiftUI
import Dashboard
import Design
import FileExplorer
import Sync

/// The custom pane split layout: the horizontal two-pane split, the vertical panes-over-bottom
/// split, and their invisible drag-to-resize handles. An extension, not separate Views, because the
/// splits read ContentView's fraction state and pane builders directly; the members they touch are
/// internal rather than private so this file can live outside ContentView.swift.
extension ContentView {

    /// Name of the coordinate space spanning the pane row, so the divider drag can read the
    /// cursor's absolute x position independent of the divider's own (moving) frame.
    static let paneRowSpace = "panesRow"
    static let verticalStackSpace = "verticalStack"

    /// Two file panes side by side with a draggable divider. Not `HSplitView`: its NSSplitView
    /// divider ignores the top safe area and draws up through the `.hiddenTitleBar` toolbar band,
    /// while this HStack stays inside the safe area, so the divider starts at the pane headers. A
    /// hit-testable handle updates `paneSplitFraction` to keep drag-to-resize.
    @ViewBuilder
    var panesSplit: some View {
        panesRow
    }

    /// One-way sync's setup, opened on the folders Compare's two panes show.
    func openOneWaySyncSetup() {
        oneWaySync.openSetup(panes: [shownFolder(isLeft: true), shownFolder(isLeft: false)])
    }

    /// The folder a pane shows: its source's root and where the pane is below it; in Columns, the
    /// deepest open column, as the pane's own crumbs say.
    func shownFolder(isLeft: Bool) -> String {
        let pane = paneContext(isLeft: isLeft)
        let root = (settings.rootPath(for: pane.providerId) as NSString).expandingTildeInPath
        let relative = syncManager.paneLocation(isLeft: isLeft, drawsColumns: pane.viewMode == .columns)
        return relative.isEmpty ? root : (root as NSString).appendingPathComponent(relative)
    }

    /// Opens Activity on Events: the toolbar chip's and the strip's door.
    func openActivityOnEvents() {
        ActivityCenter.shared.tab = .events
        ActivityCenter.shared.markSeen()
        openWindow(id: ActivityCenter.windowID)
    }

    @ViewBuilder
    private var panesRow: some View {
        GeometryReader { geo in
            // Named on `PaneLogic` so the sidebar's width clamp uses the same number; two copies of a
            // layout minimum is how a clamp comes to disagree with what it clamps.
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
            // The seam's own controls, ⇄ swap and 🔗 link-both, in one capsule straddling the
            // boundary. Pinned to the top so they don't eat the drag-to-resize area below.
            .overlay(alignment: .topLeading) {
                SeamPaneControls(hue: glassHue, onSwap: swapPanesAction)
                    .offset(x: leftWidth - 13, y: 8)
            }
            .coordinateSpace(.named(Self.paneRowSpace))
        }
        // **No Space → Quick Look handler here.** It hangs off each pane's file list; see
        // `paneQuickLook()` in `ContentView+PaneSearch.swift` for why the whole column is the wrong
        // subtree.
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

    /// The panes stacked over the bottom workspace, with an invisible, draggable horizontal divider.
    /// Not `VSplitView`, whose divider line can't be hidden. The ratio is `bottomPaneFraction`, so it
    /// never resets when the Differences/Details tab changes.
    static let railRowSpace = "railRow"

    @ViewBuilder
    var verticalSplit: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            switch contentLayout {
            case .compareSplit:
                // One structure for expanded and collapsed: the same `panesSplit`, divider and
                // `bottomPaneView` in the same positions, so collapsing keeps their identity instead
                // of tearing down and rebuilding two ~40k-row Lists. Only the frame heights and the
                // divider's presence change:
                //   • expanded  — panes fill the space above a fraction-sized bottom pane, drag divider.
                //   • collapsed — panes fill everything above the bottom pane, which hugs its header
                //                 strip (height nil = intrinsic), and the divider goes to zero height.
                let collapsed = bottomPaneIsCollapsed
                let minTop: CGFloat = 220
                let minBottom: CGFloat = 150
                // Folded, Cards needs no strip (the cards' gutter is the boundary), but Unified keeps
                // it: it is the hairline between the panes and the folded toolbar.
                let dividerHeight: CGFloat = collapsed && surfaceStyle == .cards ? 0 : 1
                let panesHeight = PaneLogic.verticalPanesHeight(totalHeight: totalHeight, dividerHeight: dividerHeight)
                // fraction = the bottom pane's share; clamp so neither section drops below its min.
                let minFraction = PaneLogic.verticalMinFraction(panesHeight: panesHeight, minBottom: minBottom)
                let maxFraction = PaneLogic.verticalMaxFraction(panesHeight: panesHeight, minTop: minTop, minFraction: minFraction)
                let fraction = PaneLogic.clampedFraction(verticalDragFraction ?? bottomPaneFraction,
                                                         lower: minFraction, upper: maxFraction)
                let bottomHeight = panesHeight * fraction
                // Leading and outside the vertical stack, as in `browseLayout`: the remembered
                // folders belong to the panes' sources, not to the Differences table under them, so
                // the column spans the whole height.
                //
                // **Subtract `sidebarSlot` into its own name, never into `geo.size.width`:** shadowing
                // that width puts the sidebar outside the window (see `PaneLogic.LensRow`). The row
                // keeps its true width; only the stack beside the column is narrowed.
                let sidebarWidth = folderSidebarIsShowing
                    ? PaneLogic.compareSidebarWidth(stored: browseSidebarWidth,
                                                    totalWidth: geo.size.width,
                                                    minSidebar: FolderSidebarView.minWidth,
                                                    gutter: LiquidGlass.gutter(surfaceStyle))
                    : 0
                // The seam strip is in this slot too; see `PaneLogic.LensRow.sidebarSlot` for the 1pt
                // overflow that leaving it out costs.
                let sidebarSlot = folderSidebarIsShowing
                    ? sidebarWidth + PaneLogic.sidebarOverhead(gutter: LiquidGlass.gutter(surfaceStyle)) : 0
                HStack(spacing: 0) {
                    if folderSidebarIsShowing {
                        folderSidebar(width: sidebarWidth)
                        folderSidebarResizeHandle(displayedWidth: sidebarWidth)
                    }
                    VStack(spacing: 0) {
                        panesSplit
                            .panesRegionFrame(surfaceStyle, level: glassLevel)
                            .frame(maxHeight: .infinity)
                        verticalResizeDivider(panesHeight: panesHeight, minFraction: minFraction,
                                              maxFraction: maxFraction, isActive: !collapsed)
                            .frame(height: dividerHeight)
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
                // Single-source: the source rail docked left of a full-height workspace, collapsed to
                // a spine or expanded to a resizable pane.
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
        // The sidebar comes off the top, and the rest divides as before. Taking its width out of
        // `totalWidth` first keeps the rail and lens panel measured against the room they really
        // have, so their minimums mean the same with or without a sidebar, and `railFraction` stays
        // a two-way split.
        //
        // The displayed width is clamped, not the stored one (`PaneLogic.lensSidebarWidth`). Browse
        // can afford whatever the user stored; here three things divide one row, and at the 760
        // window floor the rail and panel claim 560 of it.
        let sidebarWidth = folderSidebarIsShowing
            ? PaneLogic.lensSidebarWidth(stored: browseSidebarWidth, totalWidth: totalWidth,
                                         minSidebar: FolderSidebarView.minWidth,
                                         gutter: LiquidGlass.gutter(surfaceStyle), railCollapsed: collapsed)
            : 0
        // **`splitWidth`, never a shadowed `totalWidth`.** The fractions and minimums are measured
        // against the room the rail and workspace divide, while the row is still the full width. A
        // reduced `totalWidth` reaching the row's `.frame(width:)` would render the sidebar outside
        // the window. See `PaneLogic.LensRow`.
        let splitWidth = totalWidth - (folderSidebarIsShowing
            ? sidebarWidth + PaneLogic.sidebarOverhead(gutter: LiquidGlass.gutter(surfaceStyle)) : 0)
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
                                    gutter: LiquidGlass.gutter(surfaceStyle), fraction: fraction)
        // One row whether the rail is open or a spine. Only the leading slot changes, and the
        // workspace, with the same modifiers either way, keeps its identity across a collapse;
        // two arms of an `if` would rebuild the lens and reopen its lists at the top.
        CollapsibleRailRow {
            if collapsed {
                // Only while the pinned column holds the folder pane folded and the sidebar was
                // asked back: a collapse takes the sidebar with it otherwise.
                if folderSidebarIsShowing {
                    folderSidebar(width: sidebarWidth)
                    folderSidebarResizeHandle(displayedWidth: sidebarWidth)
                }
                railSpine
            } else {
                // Leading, as in `browseLayout`: the remembered folders belong to the pane's source,
                // and here that pane is the rail. Organize's scope and Storage's root already follow
                // it (`lensScanRootExpanded` reads the targeted pane's directory), so a click here
                // moves the lens with the pane and needs no workspace-specific wiring.
                if folderSidebarIsShowing {
                    folderSidebar(width: sidebarWidth)
                    folderSidebarResizeHandle(displayedWidth: sidebarWidth)
                }
                // Space → Quick Look rides inside `paneColumn`, on the file list, not out here on the
                // whole column. See `paneQuickLook()`.
                paneColumn(isLeft: true)
                    .panesRegionFrame(surfaceStyle, level: glassLevel)
                    .frame(width: row.railWidth)
                    .unifiedSeam(surfaceStyle, edge: .trailing)
            }
        } workspace: {
            // **The workspace may not paint on the pane beside it.** A `LensHeaderCard` whose row 2
            // holds `.fixedSize()` prose and a control doesn't shrink to its offered width: its
            // `.frame(maxWidth: .infinity)` reports the larger of the proposal and what its children
            // insist on, and SwiftUI centres an oversized child, so the excess spills past both
            // edges. Drawn after the source pane, the left half would land on the file list (at the
            // 340pt floor with Duplicates selected the card measures ~600pt).
            //
            // The clip belongs here, the only place that knows a definite width. A `.clipped()` on
            // the card clips to the card's own resolved width and does nothing
            // (`LensHeaderCardOverrunTests`). Collapsed, the workspace has everything but the spine,
            // which is what the overflow would land on, so the width is the rest of the row: one
            // flexible frame, exactly `row.workspaceWidth` open and `maxWidth: .infinity` collapsed,
            // so the frame is one modifier in both states.
            bottomPaneView
                .frame(minWidth: collapsed ? nil : row.workspaceWidth,
                       maxWidth: collapsed ? .infinity : row.workspaceWidth)
                .clipped()
                // Info, from the folded pane's spine, over the lens's leading edge.
                .overlay(alignment: .leading) { organizeSpineInfoDrawer }
                // The lens's result message, when the reader is working here.
                .modifier(workspaceResultMessageHost)
                // With the strip's own curve, so the lens header moves down beside the pane's
                // toolbar card as the strip slides in, as Edit's document column does. Keyed on the
                // strip alone, for the reason `editorLayout` gives.
                .designAnimation(.easeOut(duration: 0.18), value: sourcePaneStripIgnoringFold)
        }
        .frame(width: totalWidth, height: geo.size.height)
        .overlay(alignment: .leading) {
            // Offset from the row's leading edge, which is not the rail's once a sidebar sits in
            // front of it. See `LensRow.railHandleOffset`.
            if !collapsed {
                railResizeHandle(splitWidth: row.splitWidth, sidebarSlot: row.sidebarSlot,
                                 lower: lower, upper: upper)
                    .offset(x: row.railHandleOffset)
            }
        }
        .coordinateSpace(.named(Self.railRowSpace))
    }

    /// Browse: the source pane with the whole window, and nothing else in it.
    ///
    /// `singleSourceLayout(collapsed: false, …)` without the workspace half, the divider and the
    /// fraction arithmetic. It keeps what makes the column a pane rather than a list: the same
    /// `paneColumn(isLeft: true)`, the same region frame and, inside that column, the same Space →
    /// Quick Look handler every pane gets (`paneQuickLook()`).
    ///
    /// Except while a person gather is up. Browse's pane search offers "everything that is theirs"
    /// like every pane, so Browse has to show the answer. The gather takes a resizable bottom slot
    /// shaped like Compare's and shares its remembered fraction (`mainBottomPaneFraction`), so
    /// dragging it here moves Compare's divider too: one "bottom share", not two. Not the lens
    /// workspaces, which lay out horizontally and give the gather the whole workspace column. No
    /// collapse rung: the slot is temporary, and ✕ and Esc give the window back.
    ///
    /// **One structure whether or not a gather is up**, as in `.compareSplit` above: the column is a
    /// ~40k-node selection walk feeding a `List`, and two branches of an `if` would give it two
    /// identities, so opening or clearing a gather would rebuild the file column and lose its scroll
    /// position and expanded folders. Only the divider's height and the third child's presence
    /// change; the column stays the first child of the same `VStack` throughout.
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
            // Leading, and outside the vertical stack. The remembered folders belong to the pane's
            // source, not to whatever is stacked under the pane; a sidebar that shrank when a gather
            // opened would read as part of it. This also keeps the "one structure" rule: the
            // sidebar's presence changes nothing about the VStack beside it.
            if folderSidebarIsShowing {
                folderSidebar(width: browseSidebarWidth)
                folderSidebarResizeHandle(displayedWidth: browseSidebarWidth)
            }
            VStack(spacing: 0) {
                // The pane and its status bar are one region. The bar is a foot on the column, not a
                // sibling: in `.unified` it is inside the pane's area, so a gather opening below
                // draws its hairline under the bar, not between the bar and its list. In `.cards`
                // the modifier does nothing and each child insets itself.
                //
                // Under the pane, above the gather: the bar describes the pane's tree, and a gather
                // must not push it underneath a list of somebody's documents.
                //
                // **Outside `paneColumn`.** That function builds Browse's pane, both Compare panes
                // and the Organize/Storage rail, so a bar inside it would appear on four surfaces,
                // and Browse is the only one that should have it. See `PaneStatusBar`.
                //
                // The wrapper is unconditional, so flipping the switch doesn't move `paneColumn` in
                // the view tree (the same "one structure" rule). No animation on the switch either:
                // a 15pt row sliding under a 40,000-row list would relayout the list for a caption.
                VStack(spacing: 0) {
                    paneColumn(isLeft: true)
                        .frame(maxHeight: .infinity)
                    if statusBarVisible {
                        browseStatusBar
                    }
                }
                .panesRegionFrame(surfaceStyle, level: glassLevel)
                .frame(maxHeight: .infinity)
                verticalResizeDivider(panesHeight: panesHeight, minFraction: minFraction,
                                      maxFraction: maxFraction, isActive: hasGather)
                    .frame(height: dividerHeight)
                if let scope = personScope {
                    personGatherSection(scope)
                        .frame(height: panesHeight * fraction)
                }
            }
            .coordinateSpace(.named(Self.verticalStackSpace))
        }
        .frame(width: geo.size.width, height: geo.size.height)
    }

    /// Browse's status bar, composed from the left pane, the only pane Browse has.
    ///
    /// The selection is resolved here, not carried down from `paneColumn`: that function resolves
    /// its own (`ownNodes`) in a different call, and threading it out would give Browse a path
    /// through the shared pane builder the other three surfaces don't take. The lookup uses
    /// `FileSyncManager`'s path→node index, so it is O(selection).
    ///
    /// The cloud clause reads the badge memo, never the filesystem: a selected row has been drawn,
    /// so `CloudOnlyBadgeCache` already holds its answer (the same read File ▸ Download makes), and
    /// this path runs every render.
    @ViewBuilder
    var browseStatusBar: some View {
        BrowseStatusBar(
            itemCount: syncManager.leftItemCount,
            tree: syncManager.leftPaneTree,
            selection: PaneStatusFacts.Selection.make(nodes: paneSelectionNodes(isLeft: true),
                                                      isCloudOnly: CloudOnlyBadgeCache.cached),
            readAt: syncManager.leftTreeReadAt,
            changedOnDisk: syncManager.leftChangedOnDisk,
            typeFilter: typeFilterStatus(isLeft: true),
            onClearTypeFilter: { syncManager.leftTypeFilter = nil })
            .contentSurface(hue: glassHue, tint: surfaceTint)
            .paneCardIfNeeded(surfaceStyle, level: glassLevel, accentBorder: paneCardAccent(isLeft: true))
    }

    /// The sidebar's drag handle, and the seam between it and the pane. The width is the user's:
    /// with many sources, some told apart only by account, a fixed column leaves too little room
    /// for a name.
    ///
    /// A clear 1pt strip, not a `Divider`, like the Info inspector's edge: both sides of the seam
    /// are cards, so the gutter draws the separation and a rule would be a third edge. Only the hit
    /// target remains, straddling the gap.
    ///
    /// It clamps, never closes: dragged past either end the width stops rather than collapsing the
    /// column, and ⌃⌘S is right there. The stored value is clamped on read as well as on write
    /// (see `browseSidebarWidth`).
    /// - Parameter displayedWidth: the width the column is drawn at, which the drag measures from.
    ///   Not `browseSidebarWidth`: in a lens workspace at a narrow window the stored value can exceed
    ///   what fits, and starting from it would make the column jump the moment the pointer moved.
    @ViewBuilder
    func folderSidebarResizeHandle(displayedWidth: CGFloat) -> some View {
        Color.clear.frame(width: PaneLogic.sidebarSeamWidth)
            // Clear in Cards, where the two cards' insets draw the gap; the hairline itself in
            // Unified, where the sidebar and what follows it sit flush in one region.
            .unifiedSeam(surfaceStyle, edge: .leading)
            .overlay {
                // `ResizeHandle`, not a hand-rolled gesture: an `NSCursor.push()`/`pop()` pair in
                // `onHover` leaks a pushed cursor if the column is hidden mid-hover (⌃⌘S is one
                // keystroke away), and the shared `.columnResize` pointer is what every seam shows.
                ResizeHandle(
                    axis: .horizontal,
                    thickness: 10,
                    minimumDistance: 1,
                    coordinateSpace: .global,
                    onDrag: { value in
                        // From the width at the start of this drag, not the live value: adding each
                        // frame's translation to an already-updated width compounds it, and the column
                        // runs away from the pointer.
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

    /// The collapsed source rail: a thin, clickable spine that expands the pane (the toolbar's pane
    /// toggle does the same). Icon-only, because the workspace's source bar names the provider while
    /// collapsed.
    @ViewBuilder
    var railSpine: some View {
        let provider = settings.availableProviders.first(where: { $0.id == leftProviderId })
        let name = provider?.displayName ?? "Source"
        let rungs = Self.spineRungs(workspace: selectedWorkspace, pdfIsOpen: editorPDF.path != nil,
                                    pdfHasOutline: editorPDFHasOutline,
                                    markdownIsOpen: EditorWorkspaceView.markdownIsOpen(editorDocument))
        let railRungs = rungs.compactMap(\.railTab)
        let showsRailRungs = !railRungs.isEmpty
        // One card, one 34pt strip, for every workspace that draws a spine. The list's buttons are
        // only ever added inside it, so the card's geometry doesn't move for the others.
        VStack(spacing: 10) {
            if showsRailRungs {
                // Edit's pane button is one of the strip's columns: the cloud alone, lit while the
                // pane shows (the strip stays beside an open pane), and a second click folds it, as
                // the list buttons do. No chevron: it is a toggle, not a way out in one direction.
                let paneOpen = !editorPaneIsFolded
                let title = EditorRailFold.paneRungTitle(paneOpen: paneOpen, source: name)
                Button { runEditorPaneRung() } label: {
                    Self.stripGlyph("cloud", lit: paneOpen, accent: glassHue.accentColor)
                }
                .buttonStyle(.hoverAffordance(.row, tint: glassHue.accentColor, shape: .roundedRect(8)))
                .help(title)
                .accessibilityLabel(title)
                .accessibilityAddTraits(paneOpen ? [.isButton, .isSelected] : .isButton)
                .padding(.top, 6)
            } else {
                Button {
                    togglePanesForCurrentTab()
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "chevron.right")
                            .scaledFont(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Image(systemName: "cloud")
                            .scaledFont(.system(size: 14, weight: .semibold))
                            .foregroundStyle(glassHue.accentColor)
                        // The spacer is what makes the strip this button's target.
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 12)
                    .frame(width: PaneLogic.railSpineWidth)
                    // The whole strip is this button's target.
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                // Organize's Info, which has no pane to sit in while the pane is folded: a button
                // under the pane's, over the strip that is the pane's own target. The drawer it
                // opens comes out of the strip over the lens (`organizeSpineInfoDrawer`).
                .overlay(alignment: .top) {
                    if selectedWorkspace == .filing { spineInfoButton.padding(.top, 76) }
                }
                .buttonStyle(.hoverAffordance(.row, tint: glassHue.accentColor, shape: .roundedRect(8)))
                .help("Show the \(name) pane to browse or re-scope")
                .accessibilityLabel("Show the \(name) source pane")
            }
            // The Files list's place when it is not on screen: one button per tab, under a rule, in
            // the strip already there, so folding the list never adds a second strip. Gated on the
            // workspace: the list is Edit's, but every workspace with a collapsible pane draws this
            // spine, and a stray button in Organize would be the first thing anyone clicked. Showing
            // the list folds an open pane; the two are never on screen together.
            if showsRailRungs {
                Divider()
                    .frame(width: 16)
                ForEach(railRungs, id: \.self) { tab in
                    let drawn = editorRailIsDrawn
                    let lit = EditorRailFold.rungIsLit(tab, railDrawn: drawn, currentTab: editorRailShownTab)
                    let title = EditorRailFold.rungTitle(tab, railDrawn: drawn, currentTab: editorRailShownTab)
                    Button { runEditorRailRung(tab) } label: {
                        Self.stripGlyph(Self.railRungSymbol(tab), lit: lit, accent: glassHue.accentColor)
                    }
                    .buttonStyle(.hoverAffordance(.row, tint: glassHue.accentColor, shape: .roundedRect(8)))
                    .help(title)
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(lit ? [.isButton, .isSelected] : .isButton)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: PaneLogic.railSpineWidth)
        .frame(maxHeight: .infinity)
        // A slim card, not a docked `.bar` strip: the bar fill stays opaque at Clear and sits flush
        // against the root padding while every neighbour floats, so the spine joins the gap model
        // (5pt to the window edge and to the workspace card beside it). In Unified it is a strip of
        // the one region, with a hairline where the workspace starts.
        .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
        .unifiedSeam(surfaceStyle, edge: .trailing)
    }

    /// The spine's Info button: lit while Organize's Info is open, which is the drawer over the lens.
    /// While the pane is folded for Ask Claude's column there is no drawer, and it opens the pane.
    private var spineInfoButton: some View {
        let on = paneInfoShows(isLeft: true)
        let title = on ? "Hide Info" : "Show Info"
        return Button { setPaneInfo(isLeft: true, !on) } label: {
            Self.stripGlyph("info.circle", lit: on, accent: glassHue.accentColor)
        }
        .buttonStyle(.hoverAffordance(.row, tint: glassHue.accentColor, shape: .roundedRect(8)))
        .help(ShortcutHint.tooltip(title, AppChord.infoInspector.display))
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    /// One strip button's face, the pane's and the list's alike, so they read as one control: the
    /// glyph, and the accent wash behind it while its column shows.
    static func stripGlyph(_ symbol: String, lit: Bool, accent: Color) -> some View {
        Image(systemName: symbol)
            .scaledFont(.system(size: 14, weight: .semibold))
            .foregroundStyle(accent)
            .frame(width: PaneLogic.railSpineWidth - 6, height: 28)
            .background(RoundedRectangle(cornerRadius: Radius.control)
                .fill(lit ? accent.opacity(0.18) : .clear))
            .frame(width: PaneLogic.railSpineWidth, height: 30)
            .contentShape(Rectangle())
    }

    /// The strip button's glyph: the rail tab's own, so the button and the tab it opens match.
    static func railRungSymbol(_ tab: EditorRailTab) -> String {
        switch tab {
        case .files: return "doc.text"
        case .pages: return "square.grid.2x2"
        case .outline: return "list.bullet.indent"
        }
    }

    /// What the collapsed pane's spine offers, as a rule a test can hold.
    enum SpineRung: Equatable {
        /// The button that opens the source pane. Every spine has it: a chevron over the cloud, or in
        /// Edit the cloud alone, lit while the pane shows (the strip stays beside it there).
        case sourcePane
        /// Edit's Files list, folded or put away by Expand, or lit while it shows that tab.
        case textFiles
        /// The same list's Pages tab, only while a PDF is open, as the tab itself is.
        case pages
        /// The same list's Outline tab.
        case outline

        /// The rail tab this button opens, or `nil` for the pane's own button.
        var railTab: EditorRailTab? {
            switch self {
            case .sourcePane: return nil
            case .textFiles: return .files
            case .pages: return .pages
            case .outline: return .outline
            }
        }
    }

    /// The spine's rungs, top to bottom. Pure, so `EditorRailSpineTests` can pin that the list's
    /// buttons are Edit's alone. Edit draws them whether the list is showing or not (lit for the tab
    /// on screen), so the strip doesn't grow and shrink as the list opens and folds. One rung per
    /// rail tab: a PDF adds Pages and drops Outline when it has no contents, as a text file does
    /// unless it is Markdown. `EditorRailTab.shown` is the rule for all three, so the strip and the
    /// rail's tabs never disagree.
    static func spineRungs(workspace: Workspace, pdfIsOpen: Bool = false, pdfHasOutline: Bool = false,
                           markdownIsOpen: Bool = false) -> [SpineRung] {
        guard workspace == .editor else { return [.sourcePane] }
        return [.sourcePane] + EditorRailTab.shown(pdfIsOpen: pdfIsOpen, pdfHasOutline: pdfHasOutline,
                                                   markdownIsOpen: markdownIsOpen).map { tab -> SpineRung in
            switch tab {
            case .files: return .textFiles
            case .pages: return .pages
            case .outline: return .outline
            }
        }
    }

    /// Invisible drag handle on the rail/workspace boundary. Like `paneResizeHandle`, but writes the
    /// rail fraction and reads the rail-row coordinate space.
    @ViewBuilder
    /// - Parameters:
    ///   - splitWidth: the room the rail and the workspace divide, what `railFraction` is a
    ///     fraction of. Not the row: a sidebar is not part of this split.
    ///   - sidebarSlot: how far the split's leading edge sits from the row's. The drag reads
    ///     `railRowSpace`, anchored to the row, so the pointer's x has to be rebased or every drag
    ///     lands one sidebar-width right of the cursor.
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

    /// The invisible, draggable horizontal divider between the panes and the bottom workspace. Like
    /// the pane divider, it tracks the cursor's absolute y in a fixed coordinate space and persists
    /// only on release.
    @ViewBuilder
    ///
    /// `isActive: false` keeps the strip (and, in Unified, its hairline) but takes the drag away:
    /// Compare's folded Differences, where there is nothing left to resize.
    private func verticalResizeDivider(panesHeight: CGFloat, minFraction: Double, maxFraction: Double,
                                       isActive: Bool) -> some View {
        Rectangle()
            .fill(Color.clear)
            // Clear in Cards, where the cards' gutter is the boundary; the hairline in Unified.
            .unifiedSeam(surfaceStyle, edge: .top)
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
                .opacity(isActive ? 1 : 0)
                .allowsHitTesting(isActive)
            }
    }
}

/// A row whose leading slot changes and whose workspace keeps its identity.
///
/// Organize's rail and Edit's pane each collapse. Written as two arms of an `if collapsed`, the
/// workspace would be two identities, and every collapse would rebuild it: Edit would re-parse the
/// document into a new text view at the top, Organize's lists would reopen at the top. Here the
/// workspace is the row's second child whatever the first is, so only the leading slot rebuilds.
///
/// **The workspace must carry the same modifiers in both states:** a modifier added under a
/// condition wraps the view in a different type, which is an identity change again.
/// `CollapsibleRailRowTests` mounts it and checks the text view survives.
struct CollapsibleRailRow<Leading: View, Workspace: View>: View {
    let leading: Leading
    let workspace: Workspace

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder workspace: () -> Workspace) {
        self.leading = leading()
        self.workspace = workspace()
    }

    var body: some View {
        HStack(spacing: 0) {
            leading
            workspace
        }
    }
}

/// The controls that belong to the seam itself: ⇄ swap on top, 🔗 link-both underneath, in one
/// capsule straddling the boundary between the panes.
///
/// One link button for the one `@AppStorage` key, placed beside swap in the gap it joins.
///
/// Both halves are square, so the capsule's ends are true semicircles. That lets the linked fill
/// below be an exact bottom half, and each half wear the same circular hover wash.
struct SeamPaneControls: View {
    let hue: LiquidGlassHue
    let onSwap: () -> Void

    /// The one link preference in the app; `PaneLinkPreference` names its other readers.
    @AppStorage(PaneLinkPreference.defaultsKey) private var linkBothPanes = false

    /// Read because the pill is hue-washed, so every engaged colour in it depends on which side of
    /// the surface it shifts against. See `engagedWash` and `glyphInk`.
    @Environment(\.colorScheme) private var colorScheme

    /// Shared with the two glyph views, which size themselves to one half.
    fileprivate static let half: CGFloat = 26

    /// How much of the hue the resting capsule carries over its material: frosted, not solid, so the
    /// material still reads through.
    ///
    /// 0.14 because the button style's own wash stacks on top, which puts the seam on the nav pills'
    /// ladder: 0.14 rest → 0.14 + 0.14·0.86 = 0.26 hovered → 0.14 + 0.24·0.86 = 0.35 pressed, against
    /// `PaneNavChrome`'s 0.22 and 0.34. A heavier rest would put an idle seam at the pills' hovered
    /// weight.
    fileprivate static let restWash: Double = 0.14

    /// Ink for a seam half that is not carrying the linked fill: neutral at rest, and on a light
    /// appearance the deepened accent once the pointer is on it.
    ///
    /// Deepened rather than `accentColor` because the pill under it is the accent too: on the light
    /// composite a raw-accent glyph runs 1.58:1 (Cyan) to 3.53:1 (Indigo), mostly under the 3:1
    /// floor, so hovering would make it harder to read. `accentFillColor` clears 3:1 on every hue
    /// (3.21:1 worst, on Purple). Rest measures 8.4–8.9:1.
    ///
    /// Dark drops the tint entirely. Deepening darkens, so on a dark pill it moves the ink toward
    /// the surface: a deepened Cyan glyph measures 1.58–2.60:1 on dark grounds, against 3.08–5.07:1
    /// for the raw accent and more for `.primary`. `ChromeInk` owns this rule (on a washed surface
    /// the fill is the only honest carrier of hover), so this routes through it and lets
    /// `engagedWash` carry the hover in dark.
    fileprivate static func glyphInk(_ scheme: ColorScheme,
                                     deepened: Color,
                                     phase: HoverAffordancePhase) -> Color {
        ChromeInk.label(scheme, light: phase.isEngaged ? deepened : .primary.opacity(0.75))
    }

    /// The accent depth that registers against the pill, which flips with the appearance for the
    /// reason `glyphInk` gives: `accentFillColor` is darker than the light pill and barely differs
    /// from the dark one. Hover step on dark grounds: 1.30–1.35× raw against 1.13–1.16× deepened; on
    /// light, 1.15–1.17× deepened against 1.07× raw.
    ///
    /// Not `linked`'s wash, which stays `onAccentLabelColor` in both appearances because it lands on
    /// the solid fill rather than this frost.
    private var engagedWash: Color {
        colorScheme == .dark ? hue.accentColor : hue.accentFillColor
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSwap) {
                SwapPanesGlyph(deepened: hue.accentFillColor)
            }
            // `.glyph`, not `.circular`: the capsule is what floats, and a half that lifted on hover
            // would peel out of chrome that stays put. Same wash and ring numbers, minus the lift;
            // the shape override keeps the wash round inside the pill.
            //
            // Washes in `engagedWash`, not the raw hue: the pill underneath is already the raw
            // accent, so on light a raw wash would have nothing to shift against.
            .buttonStyle(.hoverAffordance(.glyph, tint: engagedWash, shape: .circle))
            // The tab lists move with the panes (`FileSyncManager.swapPanes`). Said here because it
            // is the one consequence of ⇄ you can't see until you find the other pane's tabs where
            // yours were.
            .help("Swap the left and right panes, tabs and all")
            // Named like its sibling below: `.help` is the accessibility help on macOS, so without
            // this VoiceOver reads the glyph's bare symbol.
            .accessibilityLabel("Swap panes")

            // Stays neutral while everything around it takes the hue: this hairline has to read
            // against the frosted wash above it and, when linked, the solid `accentFillColor` below
            // it, and an accent line on an accent fill is not a line at all.
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
            // The hover wash has to show against what is under it, which changes with the state:
            // `engagedWash` over the frosted pill when unlinked, white over the solid accent fill
            // when linked, where an accent wash would carry no colour.
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
        // The linked fill goes in the background rather than inside the button's label, so the
        // style's own hover wash lands on top of it instead of underneath.
        .background(alignment: .bottom) {
            if linkBothPanes {
                UnevenRoundedRectangle(bottomLeadingRadius: Self.half / 2,
                                       bottomTrailingRadius: Self.half / 2,
                                       style: .continuous)
                    .fill(hue.accentFillColor)
                    .frame(height: Self.half)
            }
        }
        // Material base plus a frosted accent wash. The pill floats over pane content on a window
        // whose background is already the hue, where a grey chip would read as an unstyled blob.
        // Behind the linked fill, which is the later layer.
        .background(Capsule().fill(.regularMaterial)
            .overlay(Capsule().fill(hue.accentColor.opacity(Self.restWash))))
        // The capsule floats over pane content, not chrome, so unlike the nav pills it needs an
        // edge of its own against a light file list, in the hue so the pill reads as one accent
        // object rather than a tinted fill in a grey ring.
        .overlay(Capsule().strokeBorder(hue.accentColor.opacity(0.35), lineWidth: 0.75))
    }
}

/// The ⇄ half of `SeamPaneControls`.
///
/// Its own `View` type because it reads the enclosing hover-affordance button's phase, which needs
/// an `@Environment`.
struct SwapPanesGlyph: View {
    /// `LiquidGlassHue.accentFillColor`, not `accentColor`; see `SeamPaneControls.glyphInk`.
    let deepened: Color

    @Environment(\.hoverAffordancePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Pressing turns the glyph over, which is what the click is about to do to the panes, so the
    /// feedback names the outcome. Dropped under Reduce Motion, where the style's wash still carries
    /// the press.
    private var flipped: Bool { phase == .pressed && !reduceMotion }

    var body: some View {
        Image(systemName: "arrow.left.arrow.right")
            .scaledFont(.system(size: 11, weight: .bold))
            .foregroundStyle(SeamPaneControls.glyphInk(colorScheme, deepened: deepened, phase: phase))
            .rotationEffect(.degrees(flipped ? 180 : 0))
            // `designAnimation` for one spelling across the app, but **the gate here is `flipped`,
            // not the modifier**: it already folds in `!reduceMotion`, so under the setting the value
            // never changes. Don't remove the check in `flipped` because this line looks like it
            // covers it.
            .designAnimation(.easeInOut(duration: 0.16), value: flipped)
            .frame(width: SeamPaneControls.half, height: SeamPaneControls.half)
    }
}

/// The 🔗 half of `SeamPaneControls`.
///
/// A chain, not ⇄, which is reserved for swap-panes. SF Symbols has no `link.slash`, so off and on
/// are carried by the fill, not a second glyph.
///
/// Its own `View` type for the reason `SwapPanesGlyph` is: the resting ink depends on the enclosing
/// button's hover phase, which only resolves inside the style's body. Inline in the parent it would
/// read the parent's environment and never leave `.rest`.
struct LinkPanesGlyph: View {
    /// `LiquidGlassHue.accentFillColor`, not `accentColor`; see `SeamPaneControls.glyphInk`.
    let deepened: Color
    let onAccent: Color
    let isLinked: Bool

    @Environment(\.hoverAffordancePhase) private var phase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: PaneGlyph.linkBothPanes)
            .scaledFont(.system(size: 11, weight: .bold))
            // Linked keeps both its colours: white on the deepened accent fill. It still reads as
            // "on" though the pill carries the hue, because what separates the states is opacity,
            // not colour: a solid half against a 0.14 frost, with the only white glyph in the
            // control on it.
            .foregroundStyle(isLinked
                ? onAccent
                : SeamPaneControls.glyphInk(colorScheme, deepened: deepened, phase: phase))
            .frame(width: SeamPaneControls.half, height: SeamPaneControls.half)
    }
}
