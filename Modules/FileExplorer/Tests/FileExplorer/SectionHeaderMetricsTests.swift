import AppKit
import Design
import SwiftUI
import Testing
@testable import FileExplorer

/// The grouped table's section header is a click target before it is a label, and its height is
/// the whole of that. Measured with `NSHostingView.fittingSize` — the LAID-OUT result — rather than
/// by restating the padding constant, which would pass even if the padding stopped applying.
@MainActor
@Suite(.serialized) struct SectionHeaderMetricsTests {

    private func laidOutHeight(_ view: some View, width: CGFloat = 420) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func header(collapsed: Bool = false, selected: Bool = false) -> DifferenceSectionHeader {
        DifferenceSectionHeader(folder: "Immigration", count: 13,
                                accent: LiquidGlassHue.green.accentColor,
                                isFullySelected: selected,
                                isCollapsed: collapsed,
                                directionSummary: collapsed ? "10 → Dropbox · 3 → iCloud" : "")
    }

    /// The bug this exists to stop: the header's tappable region used to be the height of its text
    /// (~16pt) while the table drew a taller section row, so the band above the words looked like
    /// header and did nothing. 28pt is the floor for something you hit without aiming — comfortably
    /// under a Table row and comfortably over a line of 12pt text.
    @Test func sectionHeaderIsAComfortableClickTarget() {
        #expect(laidOutHeight(header()) >= 28)
    }

    /// Every state has to be equally hittable. A collapsed header gains a direction summary and a
    /// selected one gains a wash; neither may change the height, or the row would jump under the
    /// pointer as you click it.
    @Test func everyStateHasTheSameHeight() {
        let expanded = laidOutHeight(header())
        #expect(laidOutHeight(header(collapsed: true)) == expanded)
        #expect(laidOutHeight(header(selected: true)) == expanded)
        #expect(laidOutHeight(header(collapsed: true, selected: true)) == expanded)
    }

    /// A long folder name truncates rather than wrapping. A wrapped name would grow the header and
    /// break the even rhythm the collapsed summary depends on.
    @Test func aLongFolderNameDoesNotGrowTheHeader() {
        let long = DifferenceSectionHeader(folder: "Quarterly Board Reporting And Archive 2024-2026",
                                           count: 1284, accent: LiquidGlassHue.green.accentColor)
        #expect(laidOutHeight(long, width: 240) == laidOutHeight(header()))
    }
}
