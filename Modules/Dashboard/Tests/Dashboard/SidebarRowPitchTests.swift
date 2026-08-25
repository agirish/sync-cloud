import AppKit
import SwiftUI
import Testing
@testable import Dashboard
import Design

/// **The column's vertical rhythm, measured rather than asserted.**
///
/// `rowHeight` is a floor, and what a reader actually sees is the PITCH — the floor plus the 2pt
/// between rows. Those are two numbers in two places, so the one that matters is not written down
/// anywhere and drifts silently when either moves.
///
/// It has already drifted once. The floor was 26 on reasoning that read well and was wrong: Finder
/// draws 24pt rows at its small sidebar icon size and 28 at medium, so 26 "sits between them" —
/// except the sidebar being compared against was on neither of those sizes. Measured against a
/// side-by-side screenshot on 2026-08-24, calibrated on a reference visible in both windows (the
/// traffic lights, 12pt, at ~14px), Finder's pitch is ~32pt and this column's was 28.
@MainActor @Suite struct SidebarRowPitchTests {

    /// Renders the column with `favorites` rows in it and returns its laid-out height.
    private func height(favorites: Int) -> CGFloat {
        let rows = FolderSidebarModel.rows(
            sources: [.init(root: "/i", name: "iCloud",
                            favorites: (0..<favorites).map { "F\($0)" }, isAvailable: true)],
            recents: [])
        let view = FolderSidebarView(folderRows: rows, locationRows: [], shortcutRows: [],
                                     currentRoot: "/i", currentRelativePath: "", currentSourceId: "",
                                     width: FolderSidebarView.defaultWidth, collapsed: [],
                                     accent: LiquidGlassHue.blue.accentColor,
                                     onOpen: { _, _ in }, onToggleFavorite: { _ in },
                                     onOpenSource: { _, _ in }, onToggleSection: { _ in })
            .frame(width: FolderSidebarView.defaultWidth)
        return NSHostingView(rootView: AnyView(view)).fittingSize.height
    }

    /// **A differential, not a single measurement.** The column's padding, its section header and
    /// its scroll chrome are all in the total and none of them are per-row, so only the difference
    /// between two row counts isolates what one row costs.
    @Test func aRowOccupiesThirtyTwoPoints() {
        let pitch = (height(favorites: 8) - height(favorites: 3)) / 5
        #expect(pitch == 32,
                "a sidebar row occupies \(pitch)pt, not 32 — the column's rhythm has drifted from Finder's")
    }

    /// The pitch is the floor plus the gap, and this pins that it is genuinely the floor doing the
    /// work — a row is not being padded to that height by something else, which would make
    /// `rowHeight` a number that no longer describes anything.
    @Test func thePitchIsTheFloorPlusTheGapBetweenRows() {
        let pitch = (height(favorites: 8) - height(favorites: 3)) / 5
        #expect(pitch == FolderSidebarView.rowHeight + 2,
                "the pitch (\(pitch)) is not rowHeight (\(FolderSidebarView.rowHeight)) plus the 2pt row gap — something else is setting the row's height")
    }

    /// A one-line row must not be taller than the floor. If a label's own line height ever exceeded
    /// it the floor would stop being the thing that decides, and raising it would change nothing —
    /// which is the failure mode that makes a metric constant quietly decorative.
    @Test func theFloorIsWhatDecidesAOneLineRowsHeight() {
        #expect(FolderSidebarView.rowHeight > ScaledFont.system(size: 13).pointSize(scale: 1) * 1.6,
                "a 13pt label's line box is within reach of the row floor — the floor may no longer be what sets the height")
    }
}
