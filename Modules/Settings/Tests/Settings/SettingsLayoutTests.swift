import AppKit
import Design
import SwiftUI
import Testing
@testable import Settings

/// Pins the promise the sidebar layout was built to keep: the Appearance tab fits its opening
/// without scrolling, and the sheet never outgrows the window it is centered in.
///
/// The height is measured from the LAID-OUT view (`NSHostingView.fittingSize`), not computed
/// from the constants that feed it — the constants agreeing with each other proves nothing about
/// what SwiftUI actually lays out. The shipped grouped-Form version measured 884pt into a 436pt
/// opening, which is how a control ended up cut in half by the sheet's bottom edge.
///
/// Only Appearance is pinned. It is the tab that motivated the change and the tallest one that
/// can be made to fit, and it reads nothing but `@AppStorage` — so its height is a property of
/// the layout rather than of the machine's data. Providers grows with the Mac's provider list and
/// is *expected* to scroll; General and Tidy reach for SMAppService and the Keychain on appear,
/// which a `swift test` host can block on.
@Suite struct SettingsLayoutTests {

    /// The content column: the sheet minus the rail and the divider between them.
    private static var contentWidth: CGFloat {
        SettingsSheetMetrics.contentWidth(textScale: 1)
    }

    @MainActor
    private func laidOutHeight(_ view: some View, width: CGFloat) -> CGFloat {
        // The text scale is pinned rather than inherited: `scaledFont` reads it from the
        // environment, so an unpinned measurement would silently report whatever text size the
        // machine running the test happens to have set.
        let host = NSHostingView(rootView: view.environment(\.appFontScale, 1).frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @MainActor
    @Test func appearanceFitsItsOpeningWithoutScrolling() async throws {
        let height = laidOutHeight(AppearanceSettingsTab(), width: Self.contentWidth)
        let opening = SettingsSheetMetrics.contentOpening(textScale: 1)

        #expect(height <= opening,
                "Appearance lays out at \(height)pt in a \(opening)pt opening — it scrolls again.")
    }

    /// The early warning the flat "does it fit" check can't give: a caption gaining one line is
    /// ~15pt, so a tab sitting 5pt under its opening is one copy edit from scrolling. If this
    /// trips, either trim the tab or raise `SettingsSheetMetrics.baseSize.height` deliberately.
    @MainActor
    @Test func appearanceKeepsRoomForACopyEdit() async throws {
        let height = laidOutHeight(AppearanceSettingsTab(), width: Self.contentWidth)
        let margin = SettingsSheetMetrics.contentOpening(textScale: 1) - height

        #expect(margin >= 15, "Only \(margin)pt of slack left below the last control.")
    }

    // MARK: - Sizing

    @Test func sheetGrowsWithTheTextSetting() {
        // The sheet is sized in points and its contents in scaled type. If the sheet didn't grow
        // with the type, Larger would put the taller tabs straight back into scrolling.
        let base = SettingsSheetMetrics.resolvedSize(textScale: 1, available: nil)
        let larger = SettingsSheetMetrics.resolvedSize(textScale: 1.3, available: nil)

        #expect(base == SettingsSheetMetrics.baseSize)
        #expect(larger.width > base.width)
        #expect(larger.height > base.height)
    }

    @Test func sheetClampsToTheSpaceTheHostHas() {
        // The window's own minimum is 600pt wide — narrower than the sheet wants at any text
        // size — so an unclamped sheet would hang off the edge of a small window.
        let available = CGSize(width: 600, height: 500)
        let cramped = SettingsSheetMetrics.resolvedSize(textScale: 1, available: available)

        #expect(cramped.width == available.width - SettingsSheetMetrics.hostMargin)
        #expect(cramped.height == available.height - SettingsSheetMetrics.hostMargin)
    }

    @Test func sheetStopsShrinkingAtItsFloor() {
        // Below the floor the rail plus a usable content column stops being possible. The sheet
        // stops shrinking and its content scrolls instead — overflowing a tiny window is better
        // than a sheet too small to use.
        let tiny = SettingsSheetMetrics.resolvedSize(textScale: 1, available: CGSize(width: 200, height: 200))

        #expect(tiny == SettingsSheetMetrics.floorSize)
    }

    @Test func aRoomySpaceLeavesTheSheetAtItsIdealSize() {
        let roomy = SettingsSheetMetrics.resolvedSize(textScale: 1, available: CGSize(width: 1600, height: 1000))

        #expect(roomy == SettingsSheetMetrics.baseSize)
    }

    @Test func theContentOpeningAccountsForTheHeaderAndDivider() {
        #expect(SettingsSheetMetrics.contentOpening(textScale: 1)
                == SettingsSheetMetrics.baseSize.height - SettingsSheetMetrics.headerHeight - 1)
    }

    // MARK: - The rail

    @Test func everyTabHasARailSymbol() {
        // A tab added without a symbol would render an empty slot in the rail rather than fail
        // to build — SF Symbol names are strings.
        for tab in SettingsView.SettingsTab.allCases {
            #expect(NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil) != nil,
                    "\(tab.rawValue) has no SF Symbol named \(tab.symbolName)")
        }
    }
}
