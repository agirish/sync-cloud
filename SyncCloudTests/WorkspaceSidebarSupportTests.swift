@testable import SyncCloud
import Dashboard
import Design
import Testing
import Foundation

/// Which workspaces get a folder sidebar, and how wide it may be when it has to share a row.
///
/// The mapping lives on `Workspace` because three surfaces ask it (the View menu item, the toolbar
/// button and the column), and `FolderSidebarModel.appliesTo` keeps them agreeing. This is the
/// half `Dashboard` cannot pin, since it cannot see `Workspace`.
@Suite struct WorkspaceSidebarSupportTests {

    /// Every case is decided explicitly. A `default:` would silently opt a future workspace in or
    /// out, and which is worse depends on the workspace; with every case supported, a `default:`
    /// looks harmless and would enrol whatever comes next.
    @Test func everyWorkspaceIsAccountedFor() {
        let supported = Workspace.allCases.filter(\.supportsFolderSidebar)
        #expect(supported.count == Workspace.allCases.count,
                "\(supported.count) of \(Workspace.allCases.count) workspaces support the sidebar — decide about the rest")
        #expect(Workspace.allCases.count == 4, "a workspace was added; decide whether it takes a sidebar")
    }
}

/// The lens workspaces share one row three ways, and the sidebar is what gives way.
///
/// Browse hands the sidebar the window minus one pane, so the stored width always fits. Organize
/// puts it beside a rail (min 220) and a lens panel (min 340), leaving 194pt after the gutter and
/// seam at a 760pt window: the 180 default fits and the 280 maximum does not.
///
/// The fixtures say 760, below the 804pt window floor, on purpose: keep them where the clamp bites,
/// since a fixture moved up until the clamp stops biting tests nothing.
@Suite struct LensSidebarWidthTests {

    private let gutter = LiquidGlass.cardGutter
    private var minSidebar: CGFloat { FolderSidebarView.minWidth }

    private func width(stored: CGFloat, total: CGFloat) -> CGFloat {
        PaneLogic.lensSidebarWidth(stored: stored, totalWidth: total,
                                   minSidebar: minSidebar, gutter: gutter)
    }

    /// The common case, which must not surprise: a normal window gives the user exactly the width
    /// they chose.
    @Test func aRoomyWindowHonoursTheStoredWidth() {
        #expect(width(stored: 180, total: 1600) == 180)
        #expect(width(stored: FolderSidebarView.maxWidth, total: 1600) == FolderSidebarView.maxWidth)
    }

    /// The default fits at the window floor, which is what lets the lens workspaces have a sidebar
    /// at all.
    @Test func theDefaultFitsAtTheWindowFloor() {
        #expect(width(stored: FolderSidebarView.defaultWidth, total: 760)
                == FolderSidebarView.defaultWidth)
    }

    /// At the floor the maximum cannot fit, and the sidebar is what shrinks, never the rail or the
    /// panel, whose minimums keep them usable.
    @Test func theMaximumIsClampedAtTheWindowFloor() {
        let clamped = width(stored: FolderSidebarView.maxWidth, total: 760)
        #expect(clamped < FolderSidebarView.maxWidth)
        #expect(clamped == 760 - PaneLogic.minRailWidth - PaneLogic.minLensWorkspaceWidth - PaneLogic.sidebarOverhead(gutter: gutter))
        #expect(clamped == 194)
    }

    /// What is left over never dips below the two minimums: the property the clamp exists for,
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

    /// It clamps, it never collapses, matching the resize divider's own rule. 150 fits at the 760pt
    /// floor with 44pt to spare, so the column's own minimum is reachable but never crossed.
    @Test func itNeverShrinksBelowTheColumnsOwnMinimum() {
        #expect(width(stored: minSidebar, total: 760) == minSidebar)
        // The window cannot go below its floor, but the function must still not return something
        // unusable if called with such a width.
        #expect(width(stored: 200, total: 600) == minSidebar)
    }
}

/// The three widths a lens row divides into, and the invariant that keeps them honest. If the
/// row's own `.frame(width:)` were narrower than its parts, SwiftUI would centre the overflow and
/// draw the sidebar outside the window, with nothing reporting it. The invariant is arithmetic
/// rather than pixels, which makes it assertable.
@Suite struct LensRowGeometryTests {

    private let gutter = LiquidGlass.cardGutter

    private func row(total: CGFloat, sidebar: CGFloat, shows: Bool, fraction: Double) -> PaneLogic.LensRow {
        PaneLogic.lensRow(totalWidth: total, sidebarWidth: sidebar, showsSidebar: shows,
                          gutter: gutter, fraction: fraction)
    }

    /// Everything in the row must add up to the row; anything else is content overflowing a
    /// frame, which SwiftUI centres rather than reports.
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

    /// The seam strip is part of the slot, or every lens and Compare row overflows by 1pt. The
    /// invariant above cannot see that: it adds up only the parts it lists, and the strip would not
    /// be one of them.
    @Test func theSlotIncludesTheSeamAndNotJustTheGutter() {
        let r = row(total: 1200, sidebar: 180, shows: true, fraction: 0.5)
        #expect(r.sidebarSlot == 180 + gutter + PaneLogic.sidebarSeamWidth,
                "the slot is \(r.sidebarSlot) — a shown sidebar costs its width, the gutter AND the seam strip")
        #expect(PaneLogic.sidebarSeamWidth == 1)
    }

    /// With no sidebar the row is exactly the plain split. Compare and a hidden sidebar both take
    /// this path, so a regression here shows only as the rail moving.
    @Test func hidingTheSidebarRestoresTheOriginalSplit() {
        let r = row(total: 1200, sidebar: 180, shows: false, fraction: 0.4)
        #expect(r.sidebarSlot == 0)
        #expect(r.splitWidth == 1200)
        #expect(r.railWidth == 480)
        #expect(r.workspaceWidth == 720)
        #expect(r.railHandleOffset == 474)
    }

    /// `railFraction` keeps meaning the same thing: a fraction of what the rail and the workspace
    /// divide, not of the row, or toggling the sidebar would silently re-split the other two.
    ///
    /// The expected values are explicit `CGFloat`s: bare literals would be Int arithmetic, which
    /// truncates an odd split.
    @Test func theFractionAppliesToTheSplitAndNotTheWholeRow() {
        let shown = row(total: 1200, sidebar: 180, shows: true, fraction: 0.5)
        // 180 + 5 gutter + 1 seam.
        let expectedSplit: CGFloat = 1200 - 186
        #expect(shown.splitWidth == expectedSplit)
        #expect(shown.railWidth == expectedSplit / 2)
        #expect(shown.railWidth == 507, "half of \(expectedSplit) is not \(shown.railWidth)")
        #expect(shown.railWidth + shown.workspaceWidth == shown.splitWidth)
    }

    /// The rail's drag handle moves with the seam it marks. Its overlay is aligned to the row, so a
    /// sidebar in front of the rail displaces the seam; an offset measured from the rail alone
    /// would leave the handle over the sidebar.
    @Test func theRailHandleFollowsTheSeamPastTheSidebar() {
        let shown = row(total: 1200, sidebar: 180, shows: true, fraction: 0.5)
        let hidden = row(total: 1200, sidebar: 180, shows: false, fraction: 0.5)
        #expect(shown.railHandleOffset == shown.sidebarSlot + shown.railWidth - 6)
        #expect(shown.railHandleOffset > hidden.railHandleOffset - 6,
                "the handle did not move when a sidebar was put in front of the rail")
        // And it lands on the seam, not merely somewhere to the right of it.
        #expect(abs(shown.railHandleOffset + 6 - (shown.sidebarSlot + shown.railWidth)) < 0.001)
    }
}
