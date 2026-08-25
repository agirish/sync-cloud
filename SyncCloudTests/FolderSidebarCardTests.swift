@testable import SyncCloud
import Dashboard
import Design
import SwiftUI
import Testing
import Foundation

/// **The sidebar is a card, framed exactly as the Info inspector is.**
///
/// Reported from the running app on 2026-08-24: the column arrived flush and undecorated, separated
/// from the pane by a plain `Divider`, while the panel on the other side of that pane was a floating
/// card. The shape was borrowed from Finder — but Finder's window is one opaque surface with a rule
/// down it, and this one is a floating card over glass, so a flat column beside a card is not the
/// same idiom drawn smaller. It is the absence of the idiom.
///
/// What these pin is not "it is decorated" but "it is decorated *the same way*". Two panels flanking
/// one pane, each free to pick its own corner radius, hairline and gutter, is a pair that agrees
/// only for as long as nobody edits either — which is the drift `bottomSectionCard` exists to stop.
///
/// Scanned against the app's own source for `SidebarPlaceRowTests`' reason: `ContentView` is a
/// `View` with `@State` and cannot be instantiated here, so the alternative is a re-implementation
/// that can agree with itself while disagreeing with the app.
@Suite struct FolderSidebarCardTests {

    static func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(relative)
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read \(relative) — this scan would be vacuous")
        try #require(raw.count > 3000, "\(relative) is implausibly short — the scan is vacuous")
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    static func sidebarSource() throws -> String { try source("MacApp/ContentView+FolderSidebar.swift") }
    static func hostSource() throws -> String { try source("MacApp/ContentView.swift") }
    static func layoutSource() throws -> String { try source("MacApp/ContentView+SplitLayout.swift") }

    /// The scan reads something: symbols that are definitely there must be found.
    @Test func theScansCanSeeKnownSymbols() throws {
        #expect(try Self.sidebarSource().contains("func folderSidebar(width:"))
        #expect(try Self.hostSource().contains("var infoInspector:"))
        #expect(try Self.layoutSource().contains("func folderSidebarResizeHandle(displayedWidth:"))
    }

    /// The one line that makes it a card at all.
    @Test func theSidebarIsFramedAsACard() throws {
        #expect(try Self.sidebarSource().contains(".bottomSectionCard("),
                "the sidebar is not framed as a card — it draws flush against the pane again")
    }

    /// **The same call, argument for argument.** Not "both are cards" — the same four arguments in
    /// the same order, so a change of surface style, glass level, hue or tint reaches both panels or
    /// neither. Comparing the extracted call text is what catches the half-edit: a hue passed to one
    /// and not the other renders as two panels that disagree only under a non-default setting,
    /// which is the last place anybody looks.
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

    /// **The gutter draws the separation, so the seam draws nothing.** With cards on both sides a
    /// visible rule down the middle is a third edge between two that are already there — which is
    /// why the inspector's edge has never been a `Divider` either.
    @Test func theSeamIsAClearStripRatherThanADivider() throws {
        let code = try Self.layoutSource()
        let handle = try #require(Self.declaration(of: "func folderSidebarResizeHandle(", in: code))
        #expect(!handle.contains("Divider()"),
                "the sidebar seam draws a rule again, inside the card gutter")
        // Matched on the named constant rather than the literal: the strip is
        // `PaneLogic.sidebarSeamWidth` now, because the lens and Compare rows have to reserve the
        // same point they spend. A literal here would fail for the naming and pass for a `Divider`
        // spelled differently, which is backwards.
        #expect(handle.contains("Color.clear.frame(width: PaneLogic.sidebarSeamWidth)"),
                "the seam is no longer the clear strip the inspector's edge uses")
    }

    /// **The shared `ResizeHandle`, not a hand-rolled gesture.** This seam was the only one in the
    /// window that wrote its own, and it paid for it twice: an `NSCursor.push()`/`pop()` pair in
    /// `onHover` leaks a pushed cursor if the column is hidden mid-hover — ⌃⌘S is one keystroke
    /// away — and its pointer was chosen separately from the `.columnResize` every other seam shows.
    @Test func theSeamUsesTheSharedResizeHandle() throws {
        let handle = try #require(Self.declaration(of: "func folderSidebarResizeHandle(",
                                                   in: try Self.layoutSource()))
        #expect(handle.contains("ResizeHandle("),
                "the sidebar seam hand-rolls its resize gesture again")
        #expect(!handle.contains("NSCursor"),
                "the seam pushes an NSCursor again — a push with no matching pop when the column hides")
        #expect(handle.contains("coordinateSpace: .global"),
                "the drag reads a moving coordinate space, which is the stutter ResizeHandle documents")
    }

    /// **The drag still clamps to the column's own bounds and never closes it.** The seam's
    /// construction changed; what it is allowed to do did not.
    @Test func theDragStillClampsToTheColumnsBounds() throws {
        let handle = try #require(Self.declaration(of: "func folderSidebarResizeHandle(",
                                                   in: try Self.layoutSource()))
        #expect(handle.contains("FolderSidebarView.minWidth"))
        #expect(handle.contains("FolderSidebarView.maxWidth"))
        #expect(handle.contains("folderSidebarDragOrigin"),
                "the drag reads the live width rather than the width it started from, so the column runs away from the pointer")
    }

    /// Text from the named declaration to the start of the next one — enough to assert about one
    /// member without the assertions matching a neighbour's body.
    static func declaration(of name: String, in code: String) -> String? {
        guard let start = code.range(of: name) else { return nil }
        let rest = code[start.upperBound...]
        guard let next = rest.range(of: "\n    var ") ?? rest.range(of: "\n    func ")
                ?? rest.range(of: "\n    private ") else { return String(rest) }
        return String(rest[..<next.lowerBound])
    }

    // MARK: - Geometry

    /// The card supplies its own half-gutter, so the column occupies `width + cardGutter` — one
    /// full gutter to the pane card beside it, which insets itself by the other half. This is the
    /// arithmetic that makes the seam a gap rather than a butt joint.
    @Test @MainActor func theCardAddsExactlyOneGutter() {
        let bare = Color.clear.frame(width: FolderSidebarView.defaultWidth, height: 200)
        let carded = bare.bottomSectionCard(.unified, level: .frosted, hue: .blue, tint: 0)
        let size = NSHostingView(rootView: AnyView(carded)).fittingSize
        #expect(size.width == FolderSidebarView.defaultWidth + LiquidGlass.cardGutter,
                "the sidebar card's gutter is \(size.width - FolderSidebarView.defaultWidth), not \(LiquidGlass.cardGutter)")
    }
}
