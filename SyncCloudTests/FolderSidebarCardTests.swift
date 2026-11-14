@testable import SyncCloud
import Dashboard
import Design
import SwiftUI
import Testing
import Foundation

/// The sidebar is a card framed exactly as the Info inspector is: a flat column beside a floating
/// card would read as a missing frame. Two panels each picking their own radius, hairline and
/// gutter agree only until someone edits one, the drift `bottomSectionCard` exists to stop.
/// Scanned from source, as in `SidebarPlaceRowTests`, because `ContentView` can't be instantiated.
@Suite struct FolderSidebarCardTests {
    /// The same call, argument for argument, so a style, glass, hue or tint change reaches both panels
    /// or neither. A hue passed to one only shows under a non-default setting.
    @Test func theSidebarAndTheInspectorUseTheSameCall() throws {
        let sidebar = try #require(Self.cardCall(in: try macAppCode("ContentView+FolderSidebar.swift")),
                                   "no bottomSectionCard call found in the sidebar")
        let inspector = try #require(Self.cardCall(in: try macAppCode("ContentView.swift")),
                                     "no bottomSectionCard call found in the Info inspector")
        #expect(sidebar == inspector,
                "the two panels flanking the pane are framed differently — sidebar: \(sidebar), inspector: \(inspector)")
    }

    /// The call's arguments, whitespace-collapsed: `bottomSectionCard(a, b: c, …)`.
    static func cardCall(in code: String) -> String? {
        guard let start = code.range(of: ".bottomSectionCard(") else { return nil }
        guard let end = code[start.upperBound...].firstIndex(of: ")") else { return nil }
        return code[start.lowerBound...end]
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - The seam

    /// The gutter draws the separation, so the seam draws nothing: with cards on both sides a rule
    /// down the middle is a third edge. The inspector's edge isn't a `Divider` either.
    @Test func theSeamIsAClearStripRatherThanADivider() throws {
        let code = try macAppCode("ContentView+SplitLayout.swift")
        let handle = try declarationBody(of: "func folderSidebarResizeHandle(", in: code)
        #expect(!handle.contains("Divider()"),
                "the sidebar seam draws a rule again, inside the card gutter")
        // Matched on `PaneLogic.sidebarSeamWidth`, which the lens and Compare rows also reserve; a
        // literal would fail for the naming and pass for a `Divider` spelled differently.
        #expect(handle.contains("Color.clear.frame(width: PaneLogic.sidebarSeamWidth)"),
                "the seam is no longer the clear strip the inspector's edge uses")
    }

    /// The shared `ResizeHandle`, not a hand-rolled gesture: a `NSCursor.push()`/`pop()` pair in
    /// `onHover` leaks a pushed cursor if the column hides mid-hover (⌃⌘S), and a hand-picked pointer
    /// drifts from the `.columnResize` every other seam shows.
    @Test func theSeamUsesTheSharedResizeHandle() throws {
        let handle = try declarationBody(of: "func folderSidebarResizeHandle(", in: try macAppCode("ContentView+SplitLayout.swift"))
        #expect(handle.contains("ResizeHandle("),
                "the sidebar seam hand-rolls its resize gesture again")
        #expect(!handle.contains("NSCursor"),
                "the seam pushes an NSCursor again — a push with no matching pop when the column hides")
        #expect(handle.contains("coordinateSpace: .global"),
                "the drag reads a moving coordinate space, which is the stutter ResizeHandle documents")
    }

    /// The drag clamps to the column's own bounds and never closes it.
    @Test func theDragStillClampsToTheColumnsBounds() throws {
        let handle = try declarationBody(of: "func folderSidebarResizeHandle(", in: try macAppCode("ContentView+SplitLayout.swift"))
        #expect(handle.contains("FolderSidebarView.minWidth"))
        #expect(handle.contains("FolderSidebarView.maxWidth"))
        #expect(handle.contains("folderSidebarDragOrigin"),
                "the drag reads the live width rather than the width it started from, so the column runs away from the pointer")
    }

    // MARK: - Geometry

    /// In Cards the column occupies `width + cardGutter`, one full gutter to the pane card, which
    /// insets itself by the other half: a gap, not a butt joint. In Unified it is exactly its width,
    /// flush at a hairline. `LiquidGlass.gutter(style)` is what the sidebar's slot reserves.
    @Test @MainActor func theCardAddsExactlyOneGutter() {
        let bare = Color.clear.frame(width: FolderSidebarView.defaultWidth, height: 200)
        for style in SurfaceStyle.allCases {
            let carded = bare.bottomSectionCard(style, level: .frosted, hue: .blue, tint: 0)
            let size = NSHostingView(rootView: AnyView(carded)).fittingSize
            #expect(size.width == FolderSidebarView.defaultWidth + LiquidGlass.gutter(style),
                    "\(style): the sidebar's gutter is \(size.width - FolderSidebarView.defaultWidth), not \(LiquidGlass.gutter(style))")
        }
    }
}
