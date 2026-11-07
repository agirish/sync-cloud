import AppKit
import Design
import SwiftUI
import Testing
@testable import FileExplorer

/// The grouped table's section header is a click target before it is a label, and its height is
/// what makes it one. Measured with `NSHostingView.fittingSize`, the laid-out result, not by
/// restating the padding constant, which would pass even if the padding stopped applying.
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

    /// The tappable region must be taller than the text's ~16pt, or the band above the words looks
    /// like header and does nothing: an 18pt floor, and the gap relative to the text, so it keeps
    /// its meaning when Text Size scales the label (at a large size a bare row grows past any fixed
    /// floor, which would pass with the padding gone). The gap is a literal, 4 (2 above, 2 below):
    /// reading `verticalPadding` would put the constant on both sides, so setting it to 0 could
    /// never fail. Change the padding, change this with it. `SectionRowHeightTests`, which measures
    /// the 28pt the header reaches in a real table, is the stronger guard.
    ///
    /// This does NOT catch padding moving outside `contentShape`: `fittingSize` is the same either
    /// way, and `NSHostingView.hitTest` can't see SwiftUI's content shape. Keep those two modifiers
    /// adjacent in the view and read the comment there.
    @Test func theHeaderClearsItsOwnTextByBothPaddings() {
        let bare = laidOutHeight(
            Text("Immigration").scaledFont(.system(size: 12, weight: .semibold)))
        let height = laidOutHeight(header())
        #expect(height >= 18)
        #expect(height >= bare + 4)
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
