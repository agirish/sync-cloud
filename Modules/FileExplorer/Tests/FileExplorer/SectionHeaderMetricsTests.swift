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
    /// header and did nothing.
    ///
    /// The floor has come down twice with the padding — 28pt at 7, 22pt at 4, and 18pt now at 2.
    /// Each was a deliberate loosening to match a deliberate design change rather than a way to
    /// turn a red test green, but three ratchets in, this assertion is nearly spent: the bug it
    /// guards lands the header at ~16pt and the floor is now 18. `SectionRowHeightTests` is the
    /// one with teeth, because it measures the 28pt the header reaches inside a real table
    /// instead of the 20pt it asks for on its own.
    ///
    /// **What it does NOT catch**, despite what this comment used to imply: the padding moving back
    /// OUTSIDE `contentShape`, which is the precise form the original bug took. `fittingSize` is
    /// identical either way, so this passes cleanly on that mutation — verified, not assumed. SwiftUI's
    /// content shape is not reachable from `NSHostingView.hitTest` either (it answers with the hosting
    /// view at every point, padding band included), so nothing here pins the ORDER of those two
    /// modifiers. Keep them adjacent in the view and read the comment there.
    @Test func sectionHeaderIsAComfortableClickTarget() {
        #expect(laidOutHeight(header()) >= 18)
    }

    /// The same guard expressed relative to the text rather than as an absolute floor, so it keeps
    /// its meaning when the app's Text Size setting scales the label: at a large text size a bare
    /// 16pt row grows past any fixed floor on its own, and the floor above would pass with the
    /// padding entirely gone.
    ///
    /// The expected gap is written as a literal on purpose. Reading `verticalPadding` here — which
    /// is what the first version of this test did — puts the constant on both sides of the
    /// comparison, so setting it to 0 asks only that the header be at least as tall as its own
    /// text, and the test cannot fail. Restating the number is the point: change the padding and
    /// this must be changed with it, deliberately. It is 4 now (2 above, 2 below).
    @Test func theHeaderClearsItsOwnTextByBothPaddings() {
        let bare = laidOutHeight(
            Text("Immigration").scaledFont(.system(size: 12, weight: .semibold)))
        #expect(laidOutHeight(header()) >= bare + 4)
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
