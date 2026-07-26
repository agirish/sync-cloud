import SwiftUI
import Dashboard
import Design

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
            let minPane: CGFloat = 250
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
        // Quick Look on plain Space, scoped to the pane trees — NOT a window-level
        // `.keyboardShortcut(.space)`: a key equivalent is consulted before the first responder
        // and a match consumes the event outright (a no-op action still swallows it), which ate
        // spaces typed in the Differences search field and Settings-overlay fields. onKeyPress
        // only fires while key focus is inside this subtree (the pane Lists; rename/new-folder
        // prompts are separate NSAlert panels), so text fields elsewhere get Space normally.
        .onKeyPress(.space) {
            guard let targetPath = PaneLogic.primarySelectionPath(
                leftSelection: syncManager.selectedLeftPaths,
                rightSelection: syncManager.selectedRightPaths
            ) else { return .ignored }
            quickLookURL = URL(fileURLWithPath: targetPath)
            return .handled
        }
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
                .frame(width: geo.size.width, height: totalHeight)
                .coordinateSpace(.named(Self.verticalStackSpace))
            case .singleExpanded, .singleCollapsed:
                // Single-source (Tidy): the source rail docked left of a full-height workspace,
                // laid out horizontally — collapsed to a spine, or expanded to a resizable pane.
                singleSourceLayout(collapsed: contentLayout == .singleCollapsed, geo: geo)
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
                bottomPaneView
                    .frame(maxWidth: .infinity)
            }
            .frame(width: totalWidth, height: geo.size.height)
        } else {
            let minRail: CGFloat = 220
            let minWorkspace: CGFloat = 340
            let lower = minRail / max(totalWidth, 1)
            let upper = 1 - minWorkspace / max(totalWidth, 1)
            // In a very narrow window the two minimums can't both be honored; pin to the rail min.
            let fraction = (lower <= upper)
                ? PaneLogic.clampedFraction(railDragFraction ?? railFraction, lower: lower, upper: upper)
                : lower
            let railWidth = totalWidth * fraction
            HStack(spacing: 0) {
                paneColumn(isLeft: true)
                    .panesRegionFrame(surfaceStyle, level: glassLevel)
                    .frame(width: railWidth)
                    // The same Space → Quick Look the comparison panes get (ShortcutsReference
                    // promises it "in the panes", and the rail IS a pane) — scoped to the rail
                    // column so the workspace's own Space handlers are untouched. The right
                    // selection is explicitly empty: the hidden Compare pane's leftover
                    // selection must not hijack the preview.
                    .onKeyPress(.space) {
                        guard let targetPath = PaneLogic.primarySelectionPath(
                            leftSelection: syncManager.selectedLeftPaths,
                            rightSelection: []
                        ) else { return .ignored }
                        quickLookURL = URL(fileURLWithPath: targetPath)
                        return .handled
                    }
                bottomPaneView
                    .frame(width: totalWidth - railWidth)
            }
            .frame(width: totalWidth, height: geo.size.height)
            .overlay(alignment: .leading) {
                railResizeHandle(totalWidth: totalWidth, lower: lower, upper: upper)
                    .offset(x: railWidth - 6)
            }
            .coordinateSpace(.named(Self.railRowSpace))
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
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Image(systemName: "cloud")
                    .font(.system(size: 14, weight: .semibold))
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
    private func railResizeHandle(totalWidth: CGFloat, lower: Double, upper: Double) -> some View {
        ResizeHandle(
            axis: .horizontal,
            coordinateSpace: .named(Self.railRowSpace),
            onDrag: { value in
                guard totalWidth > 0, lower <= upper else { return }
                let f = PaneLogic.horizontalDragFraction(locationX: value.location.x, totalWidth: totalWidth)
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

    /// Shared with `SwapPanesGlyph`, which sizes itself to one half.
    fileprivate static let half: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onSwap) {
                SwapPanesGlyph(accent: hue.accentColor)
            }
            // `.glyph`, not `.circular`: the capsule is what floats now, and a half that lifted
            // on hover would peel out of chrome that stayed put. Same wash and ring numbers,
            // minus the lift — and the shape override keeps the wash round inside the pill.
            .buttonStyle(.hoverAffordance(.glyph, tint: hue.accentColor, shape: .circle))
            .help("Swap the left and right panes")

            Rectangle()
                .fill(hue.accentColor.opacity(0.28))
                .frame(width: Self.half, height: 0.5)

            Button {
                linkBothPanes.toggle()
            } label: {
                // A chain, not ⇄ — the ⇄ arrows are reserved for swap-panes (UX 1.2). There is no
                // `link.slash` in SF Symbols, so off/on is carried by the fill, not a second glyph.
                Image(systemName: PaneGlyph.linkBothPanes)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(linkBothPanes ? hue.onAccentLabelColor : hue.accentColor)
                    .frame(width: Self.half, height: Self.half)
            }
            // The hover wash has to show against whatever is under it, and that changes with the
            // state: the accent over material when unlinked, white over the deepened accent fill
            // when linked — an accent wash on an accent fill carries no colour at all.
            .buttonStyle(.hoverAffordance(
                .glyph,
                tint: linkBothPanes ? hue.onAccentLabelColor : hue.accentColor,
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
        // Material base plus a subtle accent wash over it, so the seam controls read in the app
        // hue instead of a neutral gray chip. Behind the linked fill, which is the later layer.
        .background(Capsule().fill(.regularMaterial)
            .overlay(Capsule().fill(hue.accentColor.opacity(0.14))))
        .overlay(Capsule().strokeBorder(hue.accentColor.opacity(0.35), lineWidth: 0.75))
    }
}

/// The ⇄ half of `SeamPaneControls`.
///
/// Its own `View` type because it reads the enclosing hover-affordance button's phase, which
/// needs an `@Environment`. The chrome it used to draw for itself now belongs to the capsule.
struct SwapPanesGlyph: View {
    let accent: Color

    @Environment(\.hoverAffordancePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Pressing turns the glyph over — the same thing the click is about to do to the panes, so
    /// the feedback names the outcome instead of just acknowledging the click. Dropped under
    /// Reduce Motion, where the style's wash still carries the press.
    private var flipped: Bool { phase == .pressed && !reduceMotion }

    var body: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(accent)
            .rotationEffect(.degrees(flipped ? 180 : 0))
            .animation(.easeInOut(duration: 0.16), value: flipped)
            .frame(width: SeamPaneControls.half, height: SeamPaneControls.half)
    }
}
