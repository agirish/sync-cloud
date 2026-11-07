import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard

/// The breadcrumb's first crumb, which is the pane's source picker.
///
/// `ProviderMenuTests` checks what is in the menu and `SyncCloudTests.MenuLabelMarkTests` that its
/// brand mark doesn't blow up the row; this file checks that the first crumb is a menu at all.
///
/// A `Menu` in the `borderlessButton` style is an `NSPopUpButton` in the AppKit tree, while a plain
/// crumb is a SwiftUI `Button` that leaves no `NSControl`, so the two are told apart by presence.
/// Reading a label wouldn't work: an offscreen `NSHostingView` has an empty accessibility tree
/// unless an assistive client is attached.
@MainActor
@Suite(.serialized) struct PaneSourceChipTests {

    /// Every `NSPopUpButton` on the header's second row, the breadcrumb trail. Scoped to that row
    /// because the bar above has menus of its own (Sort, ⋯) that move with its arrangement. The
    /// trail also has the quick-jump chevron at its trailing end, so the tests ask where the
    /// leading menu is, not how many there are.
    private func trailMenus(_ view: some View, width: CGFloat) -> [CGRect] {
        trailPopUps(view, width: width).map(\.frame)
    }

    /// The same walk, keeping the button so its disclosure state can be read. A `Menu`'s indicator
    /// is drawn by the `NSPopUpButtonCell`, and `.menuIndicator(.hidden)` sets its `arrowPosition`
    /// to `.noArrow`, so the mark is a property of the cell, not something a frame shows. A glyph
    /// added in SwiftUI (`Text(Image(...))`, `Image(nsImage:)`) renders nothing in an AppKit-drawn
    /// label, so it can't stand in.
    private func trailPopUps(_ view: some View, width: CGFloat) -> [(frame: CGRect, button: NSPopUpButton)] {
        let host = NSHostingView(rootView: AnyView(
            view.frame(width: width, height: LiquidGlass.headerHeight)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: LiquidGlass.headerHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var found: [(frame: CGRect, button: NSPopUpButton)] = []
        func walk(_ v: NSView) {
            if let button = v as? NSPopUpButton {
                let frame = v.convert(v.bounds, to: host)
                // The trail is the lower of the header's two rows.
                if frame.midY > LiquidGlass.headerHeight / 2 { found.append((frame, button)) }
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        return found.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func header(_ providerName: String?) -> PaneHeader {
        PaneHeader(
            title: "Left",
            provider: providerName.map {
                CloudProvider(id: "icloud", displayName: $0, imageName: "icloud-logo",
                              rootPath: "/Users/test/iCloud", type: .iCloud)
            },
            rootPath: "/Users/test/iCloud", relativePath: "Documents/Reports",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            viewMode: .constant(.columns), onNewFolder: {})
    }

    /// A pane with a source opens its trail with a menu; a pane without one does not. The first
    /// crumb is the only place to switch a pane's source, so a plain first crumb leaves no way to.
    ///
    /// Measured by position: the source chip sits at the trail's leading edge, and with no source
    /// the leading menu is the quick-jump chevron far to the right.
    @Test(.machinePinned(.pixelSampling)) func theFirstCrumbIsAMenuWhenThePaneHasASourceAndNotWhenItDoesNot() throws {
        let width: CGFloat = 560

        let withSource = trailMenus(Self.header("iCloud Drive"), width: width)
        let leading = try #require(withSource.first, "the trail drew no menu at all")
        #expect(leading.minX < 40,
                "the leading trail menu starts at \(leading.minX)pt — too far in to be the first crumb")

        let withoutSource = trailMenus(Self.header(nil), width: width)
        // Not "no menus": the quick-jump chevron is still there and still belongs there.
        #expect(withoutSource.first.map { $0.minX >= 40 } ?? true,
                "a pane with no source still opens its trail with a menu at \(withoutSource.first?.minX ?? -1)pt")
        #expect(withSource.count == withoutSource.count + 1,
                "the source chip is not the difference between the two trails (\(withSource.count) vs \(withoutSource.count) menus)")
    }

    /// The chip is one target: the menu's frame covers the name as well as the mark. A small mark
    /// alone, with no chevron, border or hover state, doesn't read as a control, and the clicks go
    /// to the quick-jump chevron beside it.
    @Test(.machinePinned(.pixelSampling)) func theWholeChipIsTheTarget() throws {
        let menus = trailMenus(Self.header("iCloud Drive"), width: 560)
        let chip = try #require(menus.first)
        // Comfortably wider than the 18pt mark plus its padding — it has the name inside it.
        #expect(chip.width > 40,
                "the source chip is \(chip.width)pt wide, which is the mark alone rather than the whole crumb")
        // Measured against the trail's other menu, not a literal: the quick-jump chevron is an
        // accepted click target on the same row, and unlike a number it moves with the trail's font.
        let quickJump = try #require(menus.last, "the trail drew no quick-jump menu to compare against")
        #expect(chip.height >= quickJump.height,
                "the chip is \(chip.height)pt tall against the quick-jump menu's \(quickJump.height)pt on the same row")
    }

    /// The chip, the pane's identity element, is no smaller than the bar's controls above it.
    /// Pinned against `PaneNavMetrics.pill`, not a literal, so it holds if the bar is resized.
    ///
    /// The padding is added, not measured: the wash and hairline are drawn outside the `Menu`,
    /// because a `.background` inside an AppKit-drawn label never paints, so the `NSPopUpButton`'s
    /// frame is the label alone. Only the sum of label and `SourceChip.vertical` is asserted.
    @Test(.machinePinned(.pixelSampling)) func theChipIsAtLeastAsTallAsTheBarControlsAboveIt() throws {
        let chip = try #require(trailMenus(Self.header("iCloud Drive"), width: 560).first)
        let drawn = chip.height + 2 * SourceChip.vertical
        let barControl = PaneNavMetrics.pill(.regular).height
        #expect(drawn >= barControl,
                "the source chip draws \(drawn)pt tall against the bar's \(barControl)pt controls, so the pane's identity element is the smallest thing on the pane again")
    }

    /// The chip draws a disclosure mark and the quick-jump menu beside it does not. At a source
    /// root the trail is one crumb, so a lone mark on the quick-jump menu would read as the source
    /// picker's, and marks on both would put two arrows onto unrelated menus side by side.
    @Test func theChipCarriesTheRowsDisclosureAndTheQuickJumpMenuDoesNot() throws {
        let popUps = trailPopUps(Self.header("iCloud Drive"), width: 560)
        let chip = try #require(popUps.first, "the trail drew no menu at all")
        let quickJump = try #require(popUps.last, "the trail drew no quick-jump menu")
        #expect(chip.button !== quickJump.button, "only one menu on the trail — nothing to compare")

        #expect((chip.button.cell as? NSPopUpButtonCell)?.arrowPosition != .noArrow,
                "the source chip draws no disclosure mark, so the only arrow on a root's trail is the quick-jump menu's and it reads as the source picker's")
        #expect((quickJump.button.cell as? NSPopUpButtonCell)?.arrowPosition == .noArrow,
                "the quick-jump menu grew a second system arrow next to the chip's, and two adjacent marks onto unrelated menus is what hiding the chip's was avoiding")
    }
}
