import SwiftUI
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

    /// Invisible 12pt-wide drag handle centered on the pane boundary. The drag reads the cursor's
    /// absolute x within the pane row (a fixed coordinate space) rather than accumulating
    /// translation on the moving handle — so it stays smooth — and persists `paneSplitFraction`
    /// only on release.
    @ViewBuilder
    private func paneResizeHandle(totalWidth: CGFloat, minFraction: Double) -> some View {
        Color.clear
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.paneRowSpace))
                    .onChanged { value in
                        guard totalWidth > 0 else { return }
                        let f = PaneLogic.horizontalDragFraction(locationX: value.location.x, totalWidth: totalWidth)
                        paneDragFraction = PaneLogic.clampedFraction(f, lower: minFraction, upper: 1 - minFraction)
                    }
                    .onEnded { _ in
                        if let f = paneDragFraction { paneSplitFraction = f }
                        paneDragFraction = nil
                    }
            )
    }

    /// The panes stacked over the bottom workspace, with a draggable — but invisible — horizontal
    /// divider between them. Replaces `VSplitView` so the divider line can be hidden (VSplitView's
    /// divider isn't customizable) while keeping resize. Because the split ratio is driven by
    /// `bottomPaneFraction`, it never resets when the Differences/Details tab changes.
    @ViewBuilder
    var verticalSplit: some View {
        GeometryReader { geo in
            let totalHeight = geo.size.height
            switch verticalLayout {
            case .workspaceOnly:
                // The top Left/Right panes are hidden for this tab (Tidy / Storage Lens): the
                // bottom workspace takes the whole content area. It always wins over a hidden
                // bottom pane, so this branch can never leave the window empty.
                bottomPaneView
                    .frame(width: geo.size.width, height: totalHeight)
            case .panesOnly:
                panesSplit
                    .panesRegionFrame(surfaceStyle)
            case .split:
                let minTop: CGFloat = 220
                let minBottom: CGFloat = 150
                let dividerHeight: CGFloat = 1
                let panesHeight = PaneLogic.verticalPanesHeight(totalHeight: totalHeight, dividerHeight: dividerHeight)
                // fraction = the bottom pane's share; clamp so neither section drops below its min.
                let minFraction = PaneLogic.verticalMinFraction(panesHeight: panesHeight, minBottom: minBottom)
                let maxFraction = PaneLogic.verticalMaxFraction(panesHeight: panesHeight, minTop: minTop, minFraction: minFraction)
                let fraction = PaneLogic.clampedFraction(verticalDragFraction ?? bottomPaneFraction,
                                                         lower: minFraction, upper: maxFraction)
                let bottomHeight = panesHeight * fraction
                VStack(spacing: 0) {
                    panesSplit
                        .panesRegionFrame(surfaceStyle)
                        .frame(height: panesHeight - bottomHeight)
                    verticalResizeDivider(panesHeight: panesHeight, minFraction: minFraction, maxFraction: maxFraction)
                        .frame(height: dividerHeight)
                    bottomPaneView
                        .frame(height: bottomHeight)
                }
                .frame(width: geo.size.width, height: totalHeight)
                .coordinateSpace(.named(Self.verticalStackSpace))
            }
        }
    }

    /// The invisible, draggable horizontal divider between the panes and the bottom workspace.
    /// Like the vertical one, it tracks the cursor's absolute y in a fixed coordinate space and
    /// persists only on release.
    @ViewBuilder
    private func verticalResizeDivider(panesHeight: CGFloat, minFraction: Double, maxFraction: Double) -> some View {
        Rectangle()
            .fill(Color.clear)
            .overlay {
                Color.clear
                    .frame(height: 12)
                    .contentShape(Rectangle())
                    .pointerStyle(.rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.verticalStackSpace))
                            .onChanged { value in
                                guard panesHeight > 0 else { return }
                                let f = PaneLogic.verticalDragFraction(locationY: value.location.y, panesHeight: panesHeight)
                                verticalDragFraction = PaneLogic.clampedFraction(f, lower: minFraction, upper: maxFraction)
                            }
                            .onEnded { _ in
                                if let f = verticalDragFraction { bottomPaneFraction = f }
                                verticalDragFraction = nil
                            }
                    )
            }
    }
}
