@testable import SyncCloud
import Dashboard
import Design
import Testing
import Foundation

/// That Compare's sidebar says which pane it acts on, the condition for Compare having a sidebar
/// at all: a wrong guess calls `focusOn`, which resets that pane's column stack, and navigation
/// has no undo.
///
/// The side is `PaneLogic.focusedPaneIsLeft`, the same answer the action bar, the lens scans and
/// the pane-scoped chords get, set by clicking the pane and shown by its accent border.
///
/// Scanned against the app's source because `ContentView` is a `View` with `@State` and can't be
/// instantiated here.
@Suite struct CompareSidebarTargetTests {

    static func source() throws -> String { sourceCodeOnly(try macAppFile("ContentView+FolderSidebar.swift")) }

    /// One member's body, read whitespace-insensitively.
    static func body(_ declaration: String) throws -> CodeText {
        CodeText(try declarationBody(of: declaration, in: source()))
    }

    /// Only in Compare. One pane leaves nothing to disambiguate, and a caption reading "opens in
    /// the pane" is noise on a 180pt column.
    @Test func theCaptionIsCompareOnly() throws {
        #expect(try Self.body("var folderSidebarTarget: SidebarTarget? {")
                    .contains("guard selectedWorkspace == .compare else { return nil }"),
                "the target caption is no longer gated to Compare — the other three workspaces would carry a caption that disambiguates nothing")
    }

    /// The side is the focused pane, and that is the one rule.
    ///
    /// Two tempting alternatives are refused by name: reading the selection (with nothing selected
    /// that is always the left pane, so the right is unreachable), and a stored toggle of the
    /// sidebar's own (a control that can disagree with everything else on screen).
    @Test func theSideIsTheFocusedPane() throws {
        let isLeft = try Self.body("var folderSidebarTargetIsLeft: Bool {")
        #expect(isLeft.contains("return focusedPane == .left"),
                "the sidebar target no longer follows the focused pane")
        #expect(!(try Self.source()).contains("compareSidebarTargetsRight"),
                "the sidebar has its own stored side again — a second setter for a value that now governs the action bar and the lens scans too")
        #expect(!isLeft.contains("lensTargetIsRight"),
                "the target follows the selection again — with nothing selected that is always the left pane, and the right one is unreachable")
    }

    /// A focused side left over from Compare must not leak into a one-pane workspace:
    /// `focusedPaneSide` isn't cleared on the way out, so a lingering `.right` would aim Browse at
    /// a pane it doesn't have.
    @Test func theFocusedSideIsIgnoredWhereThereIsOnlyOnePane() throws {
        #expect(try Self.body("var folderSidebarTargetIsLeft: Bool {")
                    .contains("guard selectedWorkspace == .compare else { return true }"),
                "the focused Compare side is consulted outside Compare")
    }

    /// A context-menu side reaches every branch of a source row, including the awkward one.
    ///
    /// `openFolderSidebarSource` has three `.state` branches. If
    /// `openFolderSidebarShortcutInsideItsOwner` (a shortcut whose folder lives inside another
    /// source) read `folderSidebarTargetIsLeft` itself, "Open in Right Pane" on that kind of row
    /// would silently open on the target side, in the one branch nobody thinks to try.
    @Test func theExplicitSideReachesEveryBranch() throws {
        let code = try Self.source()
        #expect(code.contains("func openFolderSidebarRow(_ row: FolderSidebarRow, inNewTab: Bool, side: Bool? = nil)"))
        #expect(code.contains("func openFolderSidebarSource(_ source: SidebarSourceRow, inNewTab: Bool, side: Bool? = nil)"))
        #expect(code.contains("inNewTab: inNewTab, isLeft: isLeft)"),
                "the inside-its-owner branch does not receive the resolved side — it re-reads the target")
        // Every open, enumerated from the source so a new branch is covered the day it appears: none
        // resolves the side itself.
        let opens = code.matches(of: /func (openFolderSidebar\w*)\(/).map { "func \($0.output.1)(" }
        #expect(opens.count >= 3, "the source-row opens were not found — this check is aimed at nothing")
        for open in opens {
            #expect(!(try Self.body(open)).contains("let isLeft = folderSidebarTargetIsLeft"),
                    "\(open) resolves the side itself again")
        }
    }

    /// The menu is wired to open, and doesn't change the target: picking a side for one folder is
    /// not a statement about the next one.
    @Test func theMenuOpensWithoutRepointingTheSidebar() throws {
        let code = try Self.source()
        #expect(code.contains("onOpenRowOnSide: { row, isLeft in"))
        #expect(code.contains("onOpenSourceOnSide: { source, isLeft in"))
        for wiring in ["onOpenRowOnSide", "onOpenSourceOnSide"] {
            let start = try #require(code.range(of: "\(wiring): {"))
            let body = String(code[start.upperBound...].prefix(200))
            #expect(!body.contains("noteFocusedPane"),
                    "\(wiring) also moves the focused pane — picking a side for one folder is not a statement about the next, and this one now moves the action bar too")
        }
    }

    /// The caption must actually be handed to the column. Without this the value could be
    /// computed, correct and never rendered, and every test above would still pass.
    @Test func theTargetReachesTheColumn() throws {
        #expect(try Self.source().contains("target: folderSidebarTarget"),
                "the column is not given the target, so Compare draws no caption at all")
    }

    /// The side is named, not inferred from the provider: two panes on one provider is ordinary,
    /// and then the name identifies nothing. The labels and glyphs live on `SidebarTarget`, pinned
    /// by `SidebarTargetTests`; this checks the app doesn't spell its own.
    @Test func theAppDoesNotSpellItsOwnSideLabels() throws {
        let code = try Self.source()
        for spelled in ["\"Left pane\"", "\"Right pane\"", "rectangle.lefthalf.filled"] {
            #expect(!code.contains(spelled),
                    "the app spells \(spelled) itself instead of going through SidebarTarget — two spellings of one label is how they drift")
        }
    }
}

/// Compare's row divides three ways too: the sidebar's clamp leaves both panes their minimum.
@Suite struct CompareSidebarWidthTests {

    private let gutter = LiquidGlass.cardGutter

    private func width(stored: CGFloat, total: CGFloat) -> CGFloat {
        PaneLogic.compareSidebarWidth(stored: stored, totalWidth: total,
                                      minSidebar: FolderSidebarView.minWidth, gutter: gutter)
    }

    @Test func aRoomyWindowHonoursTheStoredWidth() {
        #expect(width(stored: 180, total: 1600) == 180)
        #expect(width(stored: FolderSidebarView.maxWidth, total: 1600) == FolderSidebarView.maxWidth)
    }

    /// Compare has more slack than the lens workspaces, not less: two 250pt panes claim 500 of the
    /// row against the rail-plus-panel's 560. Pinned because intuition says two panes are hungrier.
    ///
    /// Measured at 760, the app's floor, where the clamp bites. A clamp earns its test only at a
    /// width where it bites: at 810 this one wouldn't (810 − 500 − 6 = 304, over the 280 maximum),
    /// so don't move the fixture just to follow the floor.
    @Test func compareIsRoomierAtTheFloorThanTheLensWorkspaces() {
        let compare = width(stored: FolderSidebarView.maxWidth, total: 760)
        let lens = PaneLogic.lensSidebarWidth(stored: FolderSidebarView.maxWidth, totalWidth: 760,
                                              minSidebar: FolderSidebarView.minWidth, gutter: gutter)
        #expect(compare > lens, "Compare clamped harder than the lens workspaces (\(compare) vs \(lens))")
        #expect(compare == 760 - PaneLogic.minComparePaneWidth * 2 - PaneLogic.sidebarOverhead(gutter: gutter))
        #expect(compare == 254)
    }

    /// Neither pane may be pushed under its own minimum at any width the window can be.
    @Test func neitherPaneEverDropsBelowItsMinimum() {
        for total in stride(from: CGFloat(760), through: 2400, by: 40) {
            for stored in [FolderSidebarView.minWidth, FolderSidebarView.defaultWidth, FolderSidebarView.maxWidth] {
                let rest = total - width(stored: stored, total: total) - PaneLogic.sidebarOverhead(gutter: gutter)
                #expect(rest >= PaneLogic.minComparePaneWidth * 2,
                        "at \(total)pt with a stored \(stored)pt sidebar the two panes are left \(rest)pt")
            }
        }
    }
}
