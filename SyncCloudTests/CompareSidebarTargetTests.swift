@testable import SyncCloud
import Dashboard
import Design
import Testing
import Foundation

/// **That Compare's sidebar says which pane it acts on**, which is the condition on Compare having
/// a sidebar at all.
///
/// Compare was excluded until 2026-08-24 for a reason that was never about machinery: a rule
/// answering "which pane" has always existed. What was missing is that the answer was invisible in
/// the case that matters. A wrong guess calls `focusOn`, which resets that pane's column stack, and
/// navigation has no undo.
///
/// **The rule has been three things in three days, and the last change removed a rule rather than
/// adding one.** It read `PaneLogic.activePane` (the pane holding a SELECTION), which was
/// unusable: with nothing selected the answer is always the left pane, so aiming the right one at a
/// folder meant selecting a file in it first, which nothing tells you and a background click
/// undoes. Two capsules in the sidebar header replaced that. Both are gone now — the side is
/// `PaneLogic.focusedPaneIsLeft`, the same answer the action bar, the lens scans and the
/// pane-scoped chords get, set by clicking the pane and shown by that pane's accent border.
///
/// Scanned against the app's own source for `SidebarPlaceRowTests`' reason: `ContentView` is a
/// `View` with `@State` and cannot be instantiated here.
@Suite struct CompareSidebarTargetTests {

    static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read ContentView+FolderSidebar.swift — this scan would be vacuous")
        try #require(raw.count > 3000, "the file is implausibly short — the scan is vacuous")
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    @Test func theScanCanSeeAKnownSymbol() throws {
        #expect(try Self.source().contains("var folderSidebarTarget"))
    }

    /// **Only in Compare.** One pane leaves nothing to disambiguate, and a caption reading "opens
    /// in the pane" is noise on a 180pt column.
    @Test func theCaptionIsCompareOnly() throws {
        let code = try Self.source()
        #expect(code.contains("guard selectedWorkspace == .compare else { return nil }"),
                "the target caption is no longer gated to Compare — the other three workspaces would carry a caption that disambiguates nothing")
    }

    /// **The side is the focused pane, and it is the ONE rule.**
    ///
    /// Two predecessors are named here rather than described, because each was reported from the
    /// running build and each would look reasonable to someone re-reading this member cold: a read
    /// of the selection (unreachable right pane), and a stored toggle of the sidebar's own (a
    /// control that could disagree with everything else on screen).
    @Test func theSideIsTheFocusedPane() throws {
        let code = try Self.source()
        #expect(code.contains("return focusedPane == .left"),
                "the sidebar target no longer follows the focused pane")
        #expect(!code.contains("compareSidebarTargetsRight"),
                "the sidebar has its own stored side again — a second setter for a value that now governs the action bar and the lens scans too")
        #expect(!code.contains("var folderSidebarTargetIsLeft: Bool { !lensTargetIsRight }"),
                "the target follows the selection again — with nothing selected that is always the left pane, and the right one is unreachable")
    }

    /// Outside Compare the question does not arise, and a focused side left over from Compare must
    /// not leak into a workspace with one pane — `focusedPaneSide` is not cleared on the way out,
    /// so a lingering `.right` would otherwise aim Browse at a pane it does not have.
    @Test func theFocusedSideIsIgnoredWhereThereIsOnlyOnePane() throws {
        #expect(try Self.source().contains("guard selectedWorkspace == .compare else { return true }"),
                "the focused Compare side is consulted outside Compare")
    }

    /// **A context-menu side reaches every branch of a source row, including the awkward one.**
    ///
    /// `openFolderSidebarSource` has three `.state` branches, and one of them —
    /// `openFolderSidebarShortcutInsideItsOwner`, for a shortcut whose folder lives inside another
    /// source — read `folderSidebarTargetIsLeft` itself. So "Open in Right Pane" on that kind of
    /// row silently opened it on the target side instead. One of three branches behaving
    /// differently from the other two is precisely what nobody thinks to try.
    @Test func theExplicitSideReachesEveryBranch() throws {
        let code = try Self.source()
        #expect(code.contains("func openFolderSidebarRow(_ row: FolderSidebarRow, inNewTab: Bool, side: Bool? = nil)"))
        #expect(code.contains("func openFolderSidebarSource(_ source: SidebarSourceRow, inNewTab: Bool, side: Bool? = nil)"))
        #expect(code.contains("inNewTab: inNewTab, isLeft: isLeft)"),
                "the inside-its-owner branch does not receive the resolved side — it re-reads the target")
        #expect(!code.contains("""
                                                 inNewTab: Bool) {
        let isLeft = folderSidebarTargetIsLeft
"""), "a source-row branch resolves the side itself again")
    }

    /// The menu is wired to open, and does NOT change the target: picking a side for one folder is
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

    /// **The sidebar cannot set the side any more, and that absence is the assertion.**
    ///
    /// A one-direction check ("the target reads the focused pane") stays green with a second setter
    /// sitting beside it writing that same state — which is exactly the shape the capsules had. So
    /// the setter's own plumbing is named and required to be gone.
    @Test func theSidebarHasNoWayToSetTheSideItself() throws {
        let code = try Self.source()
        for retired in ["pickFolderSidebarSide", "onPickSide", "compareSidebarTargetsRight"] {
            #expect(!code.contains(retired),
                    "\(retired) is back — the sidebar can set the focused pane from its own header again")
        }
    }

    /// The caption must actually be handed to the column. Without this the value is computed,
    /// correct, and never rendered — and every test above would still pass.
    @Test func theTargetReachesTheColumn() throws {
        #expect(try Self.source().contains("target: folderSidebarTarget"),
                "the column is not given the target, so Compare draws no caption at all")
    }

    /// **The side is named, not inferred from the provider** — two panes on one provider is ordinary
    /// here, and then the name identifies nothing. The labels and glyphs live on `SidebarTarget`
    /// now, where `SidebarTargetTests` pins them; what belongs here is that the app does not spell
    /// its own.
    @Test func theAppDoesNotSpellItsOwnSideLabels() throws {
        let code = try Self.source()
        for spelled in ["\"Left pane\"", "\"Right pane\"", "rectangle.lefthalf.filled"] {
            #expect(!code.contains(spelled),
                    "the app spells \(spelled) itself instead of going through SidebarTarget — two spellings of one label is how they drift")
        }
    }
}

/// **Compare's row divides three ways too, and by the same arithmetic that went wrong once.**
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

    /// **Compare has MORE slack than the lens workspaces, not less** — two 250pt panes claim 500 of
    /// the 760 floor against the rail-plus-panel's 560. Worth pinning because the intuition runs
    /// the other way: two panes sounds hungrier than one pane and a panel.
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

    /// The split's own minimum and the clamp's must be the same number, or the clamp reserves room
    /// the split does not want (or, worse, less than it needs).
    @Test func theClampAndTheSplitAgreeOnAPanesMinimum() {
        #expect(PaneLogic.minComparePaneWidth == 250)
    }
}
