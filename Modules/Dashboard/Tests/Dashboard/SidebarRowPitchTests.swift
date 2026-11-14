import AppKit
import SwiftUI
import Testing
@testable import Dashboard
import Design

/// The column's vertical rhythm, measured rather than asserted. `rowHeight` is a floor; what a
/// reader sees is the pitch, the floor plus the 2pt between rows, which is written down nowhere and
/// drifts when either moves. 32pt matches Finder's sidebar pitch.
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

    /// A differential: padding, section header and scroll chrome are in the total but not per row,
    /// so only the difference between two row counts isolates one row. Pitch equal to floor plus gap
    /// proves the floor sets the height, not something else padding the row.
    @Test func aRowOccupiesThirtyTwoPointsTheFloorPlusTheGap() {
        let pitch = (height(favorites: 8) - height(favorites: 3)) / 5
        #expect(pitch == 32,
                "a sidebar row occupies \(pitch)pt, not 32 — the column's rhythm has drifted from Finder's")
        #expect(pitch == FolderSidebarView.rowHeight + 2,
                "the pitch (\(pitch)) is not rowHeight (\(FolderSidebarView.rowHeight)) plus the 2pt row gap — something else is setting the row's height")
    }
}
