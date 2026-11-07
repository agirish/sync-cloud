@testable import SyncCloud
import Dashboard
import Design
import SwiftUI
import Testing
import Foundation

/// The sidebar is a card, framed exactly as the Info inspector is. A flat column beside a floating
/// card over glass would read as a missing frame, not Finder's idiom drawn smaller. These pin "framed
/// the same way", not just "framed": two panels flanking one pane, each picking its own radius,
/// hairline and gutter, agree only until someone edits one, the drift `bottomSectionCard` exists to
/// stop. Scanned from the app's source, as in `SidebarPlaceRowTests`, because `ContentView` can't be
/// instantiated here and a re-implementation could agree with itself while disagreeing with the app.
@Suite struct FolderSidebarCardTests {

    static func source(_ relative: String) throws -> String { sourceCodeOnly(try repoFile(relative)) }

    static func sidebarSource() throws -> String { try source("MacApp/ContentView+FolderSidebar.swift") }
    static func hostSource() throws -> String { try source("MacApp/ContentView.swift") }
    static func layoutSource() throws -> String { try source("MacApp/ContentView+SplitLayout.swift") }

    /// The same call, argument for argument, so a change of surface style, glass level, hue or tint
    /// reaches both panels or neither. Comparing the call text catches the half-edit: a hue passed to
    /// one and not the other shows only under a non-default setting.
    @Test func theSidebarAndTheInspectorUseTheSameCall() throws {
        let sidebar = try #require(Self.cardCall(in: try Self.sidebarSource()),
                                   "no bottomSectionCard call found in the sidebar")
        let inspector = try #require(Self.cardCall(in: try Self.hostSource()),
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

    /// The gutter draws the separation, so the seam draws nothing. With cards on both sides a rule
    /// down the middle is a third edge between two already there, which is why the inspector's edge
    /// isn't a `Divider` either.
    @Test func theSeamIsAClearStripRatherThanADivider() throws {
        let code = try Self.layoutSource()
        let handle = try declarationBody(of: "func folderSidebarResizeHandle(", in: code)
        #expect(!handle.contains("Divider()"),
                "the sidebar seam draws a rule again, inside the card gutter")
        // Matched on the named constant, `PaneLogic.sidebarSeamWidth`, which the lens and Compare
        // rows also reserve. Matching a literal would fail for the naming and pass for a `Divider`
        // spelled differently.
        #expect(handle.contains("Color.clear.frame(width: PaneLogic.sidebarSeamWidth)"),
                "the seam is no longer the clear strip the inspector's edge uses")
    }

    /// The shared `ResizeHandle`, not a hand-rolled gesture. An `NSCursor.push()`/`pop()` pair in
    /// `onHover` leaks a pushed cursor if the column hides mid-hover (⌃⌘S is one keystroke away), and
    /// a hand-picked pointer drifts from the `.columnResize` every other seam shows.
    @Test func theSeamUsesTheSharedResizeHandle() throws {
        let handle = try declarationBody(of: "func folderSidebarResizeHandle(", in: try Self.layoutSource())
        #expect(handle.contains("ResizeHandle("),
                "the sidebar seam hand-rolls its resize gesture again")
        #expect(!handle.contains("NSCursor"),
                "the seam pushes an NSCursor again — a push with no matching pop when the column hides")
        #expect(handle.contains("coordinateSpace: .global"),
                "the drag reads a moving coordinate space, which is the stutter ResizeHandle documents")
    }

    /// The drag clamps to the column's own bounds and never closes it.
    @Test func theDragStillClampsToTheColumnsBounds() throws {
        let handle = try declarationBody(of: "func folderSidebarResizeHandle(", in: try Self.layoutSource())
        #expect(handle.contains("FolderSidebarView.minWidth"))
        #expect(handle.contains("FolderSidebarView.maxWidth"))
        #expect(handle.contains("folderSidebarDragOrigin"),
                "the drag reads the live width rather than the width it started from, so the column runs away from the pointer")
    }

    // MARK: - Geometry

    /// In Cards the card supplies its own half-gutter, so the column occupies `width + cardGutter`,
    /// one full gutter to the pane card beside it, which insets itself by the other half: the seam is
    /// a gap, not a butt joint. In Unified the column occupies exactly its width, flush against the
    /// pane at a hairline. `LiquidGlass.gutter(style)` is what the sidebar's slot reserves.
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
