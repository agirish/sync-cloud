@testable import SyncCloud
import Dashboard
import Design
import Testing
import Foundation

/// **Which workspaces get a folder sidebar, and how wide it may be when it has to share a row.**
///
/// The mapping lives on `Workspace` because three surfaces ask it — the View menu item, the toolbar
/// button and the column — and `FolderSidebarModel.appliesTo` exists so they cannot disagree. This
/// is the half `Dashboard` cannot pin: that module cannot see `Workspace` at all.
@Suite struct WorkspaceSidebarSupportTests {

    /// **Every workspace with a single source pane the sidebar can re-root.** Organize's scope and
    /// Storage's root both already follow that pane (`lensScanRootExpanded` reads the targeted
    /// pane's current directory), so the sidebar moves the lens with no workspace-specific wiring.
    ///
    /// Storage used to be named here as a workspace of its own. It is a lens inside Organize now,
    /// so it is covered by Organize's line — and the claim is unchanged for the user, because the
    /// pane it follows is the same one.
    @Test func everySingleSourceWorkspaceSupportsIt() {
        #expect(Workspace.browse.supportsFolderSidebar)
        #expect(Workspace.filing.supportsFolderSidebar, "Organize")
    }

    /// **Compare too, since it can now say which pane it acts on.**
    ///
    /// It was held back not for want of machinery — `PaneLogic.lensTargetsRightPane` always
    /// answered "which pane" — but because that answer was invisible, and a click that re-roots the
    /// wrong pane resets its column stack with no undo. `SidebarTarget` is what changed, so this
    /// test and `TheCompareTargetIsVisible` are two halves of one claim: turning Compare on is only
    /// defensible while the caption exists.
    @Test func compareIsSupportedNowThatItNamesItsTarget() {
        #expect(Workspace.compare.supportsFolderSidebar)
    }

    /// Every case is decided explicitly. A `default:` here would silently opt a future workspace in
    /// or out, and which of those is worse depends on the workspace — so neither is a safe default.
    ///
    /// The list being "all of them" is exactly when this test starts earning its keep: a `default:`
    /// now looks harmless and would silently enrol whatever comes next.
    @Test func everyWorkspaceIsAccountedFor() {
        let supported = Workspace.allCases.filter(\.supportsFolderSidebar)
        #expect(supported.count == Workspace.allCases.count,
                "\(supported.count) of \(Workspace.allCases.count) workspaces support the sidebar — decide about the rest")
        #expect(Workspace.allCases.count == 4, "a workspace was added; decide whether it takes a sidebar")
    }
}

/// **The lens workspaces share one row three ways, and the sidebar is what gives way.**
///
/// Browse hands the sidebar the window minus one pane, so the stored width always fits. Organize
/// puts it beside a rail (min 220) and a lens panel (min 340) — 560 of the window — leaving 200pt
/// at the app's 760pt floor, which the 180 default fits and the 280 maximum does not.
///
/// **The fixtures below say 760, and they have never moved.** That is the floor again today; it was
/// the floor when this suite was written; and in between the Editor workspace raised it to 810 for
/// a fifth bar label while these stayed put. Re-pointing every fixture at a raised floor is the
/// obvious move and the wrong one — a clamp only earns its test at a width where it actually bites,
/// and moving a fixture up until it stops biting is how a suite goes green by no longer asking
/// anything. That the floor came back down to them is a coincidence, not a vindication: the reason
/// to stay was the clamp, not the number. (The Settings sheet's own floor test records the same
/// lesson from the other side: `sheetClampsToTheSpaceTheHostHas` had to KEEP a narrower fixture
/// while 810 gave the width axis two points of slack.) So these read as "at and below the narrowest
/// window the app allows", and the arithmetic in the prose is the arithmetic of the fixture.
@Suite struct LensSidebarWidthTests {

    private let gutter = LiquidGlass.cardGutter
    private var minSidebar: CGFloat { FolderSidebarView.minWidth }

    private func width(stored: CGFloat, total: CGFloat) -> CGFloat {
        PaneLogic.lensSidebarWidth(stored: stored, totalWidth: total,
                                   minSidebar: minSidebar, gutter: gutter)
    }

    /// The common case, and the one that must not be surprising: a normal window gives the user
    /// exactly the width they chose.
    @Test func aRoomyWindowHonoursTheStoredWidth() {
        #expect(width(stored: 180, total: 1600) == 180)
        #expect(width(stored: FolderSidebarView.maxWidth, total: 1600) == FolderSidebarView.maxWidth)
    }

    /// **The default fits at the window floor**, which is the whole reason the lens workspaces can
    /// have a sidebar at all rather than being excluded as they were until now.
    @Test func theDefaultFitsAtTheWindowFloor() {
        #expect(width(stored: FolderSidebarView.defaultWidth, total: 760)
                == FolderSidebarView.defaultWidth)
    }

    /// At the floor the maximum cannot fit, and the sidebar is what shrinks — never the rail or
    /// the panel, whose minimums are what make them usable at all.
    @Test func theMaximumIsClampedAtTheWindowFloor() {
        let clamped = width(stored: FolderSidebarView.maxWidth, total: 760)
        #expect(clamped < FolderSidebarView.maxWidth)
        #expect(clamped == 760 - PaneLogic.minRailWidth - PaneLogic.minLensWorkspaceWidth - PaneLogic.sidebarOverhead(gutter: gutter))
        #expect(clamped == 194)
    }

    /// **What is left over never dips below the two minimums** — the property the clamp exists for,
    /// asserted directly rather than inferred from the numbers above.
    @Test func theRailAndPanelKeepTheirMinimumsAtEveryWidth() {
        for total in stride(from: CGFloat(760), through: 2000, by: 40) {
            for stored in [minSidebar, FolderSidebarView.defaultWidth, FolderSidebarView.maxWidth] {
                let w = width(stored: stored, total: total)
                let rest = total - w - PaneLogic.sidebarOverhead(gutter: gutter)
                #expect(rest >= PaneLogic.minRailWidth + PaneLogic.minLensWorkspaceWidth,
                        "at \(total)pt with a stored \(stored)pt sidebar, the rail and panel are left \(rest)pt")
            }
        }
    }

    /// **It clamps, it never collapses** — matching the resize divider's own rule. 150 fits at the
    /// 760pt fixture with 44pt to spare, and the fixture is the app's real floor again, so the
    /// column's own minimum is reachable but never crossed.
    @Test func itNeverShrinksBelowTheColumnsOwnMinimum() {
        #expect(width(stored: minSidebar, total: 760) == minSidebar)
        // Below the window floor the window cannot go, but the function must still not return
        // something unusable if it ever were called with one.
        #expect(width(stored: 200, total: 600) == minSidebar)
    }
}

/// **The three widths a lens row divides into, and the invariant that keeps them honest.**
///
/// These exist because the first version of `singleSourceLayout` got it wrong in a way nothing
/// could see. The sidebar's width was subtracted into a *shadowed* `totalWidth`, and that reduced
/// value then reached the row's own `.frame(width:)` — so the row was framed narrower than the
/// three things inside it, SwiftUI centred the overflow, and the sidebar drew **outside the
/// window**. Every test passed. The gate was right, the clamp was right, the arithmetic that put
/// them together was not, and no test looked at it because it lived inline in a `View`.
///
/// The invariant is arithmetic rather than pixels, which is what makes it assertable at all.
@Suite struct LensRowGeometryTests {

    private let gutter = LiquidGlass.cardGutter

    private func row(total: CGFloat, sidebar: CGFloat, shows: Bool, fraction: Double) -> PaneLogic.LensRow {
        PaneLogic.lensRow(totalWidth: total, sidebarWidth: sidebar, showsSidebar: shows,
                          gutter: gutter, fraction: fraction)
    }

    /// **The one that fails on the shadowed version.** Everything in the row must add up to the
    /// row; anything else is content overflowing a frame, which SwiftUI centres rather than
    /// reports.
    @Test func theWidthsAlwaysSumToTheRow() {
        for total in stride(from: CGFloat(760), through: 2400, by: 55) {
            for shows in [true, false] {
                for fraction in [0.25, 0.4, 0.6, 0.75] {
                    let r = row(total: total, sidebar: 180, shows: shows, fraction: fraction)
                    let sum = r.sidebarSlot + r.railWidth + r.workspaceWidth
                    #expect(abs(sum - total) < 0.001,
                            "at \(total)pt (sidebar: \(shows), fraction \(fraction)) the parts sum to \(sum) — the row is framed to a width its contents do not fit")
                }
            }
        }
    }

    /// With no sidebar the row must be byte-for-byte what it was before any of this — Compare and
    /// a hidden sidebar both take this path, so a regression here is invisible until someone
    /// notices the rail moved.
    /// **The seam strip is part of the slot**, and leaving it out cost a 1pt overflow in every
    /// lens and Compare row until this test existed.
    ///
    /// The invariant above could not see it: `sidebarSlot + rail + workspace` summed to the row
    /// exactly, while the ROW also contained a 1pt clear strip nobody had counted. An invariant is
    /// only as complete as the list of things it adds up.
    @Test func theSlotIncludesTheSeamAndNotJustTheGutter() {
        let r = row(total: 1200, sidebar: 180, shows: true, fraction: 0.5)
        #expect(r.sidebarSlot == 180 + gutter + PaneLogic.sidebarSeamWidth,
                "the slot is \(r.sidebarSlot) — a shown sidebar costs its width, the gutter AND the seam strip")
        #expect(PaneLogic.sidebarSeamWidth == 1)
    }

    /// The clamp reserves what the layout actually spends, so the two cannot disagree at the floor.
    /// 760 again, for the reason in the suite note — the narrowest width worth asking about.
    @Test func theClampReservesTheSeamToo() {
        let clamped = PaneLogic.lensSidebarWidth(stored: FolderSidebarView.maxWidth, totalWidth: 760,
                                                 minSidebar: FolderSidebarView.minWidth, gutter: gutter)
        let rest = 760 - clamped - PaneLogic.sidebarOverhead(gutter: gutter)
        #expect(rest >= PaneLogic.minRailWidth + PaneLogic.minLensWorkspaceWidth,
                "at the window floor the rail and panel are left \(rest)pt — the clamp reserved less than the row spends")
    }

    @Test func hidingTheSidebarRestoresTheOriginalSplit() {
        let r = row(total: 1200, sidebar: 180, shows: false, fraction: 0.4)
        #expect(r.sidebarSlot == 0)
        #expect(r.sidebarWidth == 0, "a hidden sidebar still reports a width")
        #expect(r.splitWidth == 1200)
        #expect(r.railWidth == 480)
        #expect(r.workspaceWidth == 720)
        #expect(r.railHandleOffset == 474)
    }

    /// **`railFraction` keeps meaning the same thing.** It is a fraction of what the rail and the
    /// workspace divide, not of the row — otherwise toggling the sidebar would silently re-split
    /// the other two.
    ///
    /// The expected values are written as explicit `CGFloat`s. Spelled as bare literals,
    /// `(1200 - 185) / 2` is Int arithmetic and evaluates to 507 rather than 507.5 — which failed
    /// this test against correct code, and would have passed it against code that truncated.
    @Test func theFractionAppliesToTheSplitAndNotTheWholeRow() {
        let shown = row(total: 1200, sidebar: 180, shows: true, fraction: 0.5)
        // 180 + 5 gutter + 1 seam.
        let expectedSplit: CGFloat = 1200 - 186
        #expect(shown.splitWidth == expectedSplit)
        #expect(shown.railWidth == expectedSplit / 2)
        #expect(shown.railWidth == 507, "half of \(expectedSplit) is not \(shown.railWidth)")
        #expect(shown.railWidth + shown.workspaceWidth == shown.splitWidth)
    }

    /// **The rail's drag handle moves with the seam it marks.** The overlay carrying it is aligned
    /// to the ROW, so a sidebar in front of the rail displaces the seam — an offset measured from
    /// the rail alone would leave the handle sitting over the sidebar.
    @Test func theRailHandleFollowsTheSeamPastTheSidebar() {
        let shown = row(total: 1200, sidebar: 180, shows: true, fraction: 0.5)
        let hidden = row(total: 1200, sidebar: 180, shows: false, fraction: 0.5)
        #expect(shown.railHandleOffset == shown.sidebarSlot + shown.railWidth - 6)
        #expect(shown.railHandleOffset > hidden.railHandleOffset - 6,
                "the handle did not move when a sidebar was put in front of the rail")
        // And it lands ON the seam, not merely somewhere to the right of it.
        #expect(abs(shown.railHandleOffset + 6 - (shown.sidebarSlot + shown.railWidth)) < 0.001)
    }
}
