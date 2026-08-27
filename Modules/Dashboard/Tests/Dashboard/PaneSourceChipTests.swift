import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard

/// The breadcrumb's first crumb, which is the source picker — the surface that REPLACED the retired
/// provider capsule.
///
/// The capsule had its own coverage and that coverage was deleted with it, leaving the thing that
/// took over its job pinned only at the edges: `ProviderMenuTests` checks what is IN the menu and
/// `SyncCloudTests.MenuLabelMarkTests` checks that its brand mark does not blow up the row. Neither
/// asks the question this file does — whether the first crumb is a menu at all.
///
/// **A `Menu` in the `borderlessButton` style is an `NSPopUpButton` in the AppKit tree**, which is
/// what makes this answerable offscreen. A plain crumb is a SwiftUI `Button` with a custom style and
/// leaves no `NSControl` behind at all, so the two are told apart by presence rather than by
/// reading a label — and reading a label would be vacuous here in any case: an offscreen
/// `NSHostingView` has an empty accessibility tree unless an assistive client is attached.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct PaneSourceChipTests {

    /// Every `NSPopUpButton` on the header's SECOND row — the breadcrumb trail.
    ///
    /// Scoped to that row on purpose: the bar above it carries menus of its own (Sort, and the ⋯
    /// overflow), so an unscoped count would answer about those and move whenever the bar's
    /// arrangement changes. The trail also owns a second menu — the quick-jump chevron at its
    /// trailing end — which is exactly why the assertions below are about WHERE the leading one is
    /// rather than how many there are.
    private func trailMenus(_ view: some View, width: CGFloat) -> [CGRect] {
        trailPopUps(view, width: width).map(\.frame)
    }

    /// The same walk, keeping the button so its disclosure state can be read.
    ///
    /// **The frame alone cannot answer whether the chip says it opens something.** A `Menu`'s
    /// indicator is drawn by the `NSPopUpButtonCell`, and `.menuIndicator(.hidden)` sets that cell's
    /// `arrowPosition` to `.noArrow` — so the presence of the mark is a property of the cell, not a
    /// few points of width a layout assertion could catch. Every other route was measured and does
    /// not work: the label is drawn by AppKit, so a glyph put there in SwiftUI (`Text(Image(...))`,
    /// `Image(nsImage:)`) renders nothing at all and would leave a test asserting about a mark that
    /// was never on screen.
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

    /// **A pane with a source opens its trail with a menu; a pane without one does not.**
    ///
    /// This is the whole claim the capsule's retirement rests on. The capsule was the only control
    /// that said "this pane's source can be changed here", and the design that replaced it moved
    /// that job onto the first crumb — so a first crumb that renders as a plain crumb is a pane with
    /// no way to switch source at all, which is precisely the report that sent the first attempt
    /// back ("So the picker is gone?").
    ///
    /// Measured by position rather than by count, because the trail carries a second menu of its own
    /// at the trailing end (quick-jump). The source chip is the LEADING one and sits at the trail's
    /// own leading edge; with no source, the leading menu is that trailing chevron, far to the right.
    @Test func theFirstCrumbIsAMenuWhenThePaneHasASourceAndNotWhenItDoesNot() throws {
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

    /// The chip is one target, not a mark beside a name that happen to sit together.
    ///
    /// The first attempt split them — the mark opened the menu and the name went to the root — and
    /// it was undiscoverable: with a small mark carrying no chevron, no border and no hover state,
    /// nothing on screen said the mark was a control, and the adjacent quick-jump chevron got the
    /// clicks instead. One chip, one menu was the answer, so the menu's own frame has to cover the
    /// name as well as the mark.
    @Test func theWholeChipIsTheTarget() throws {
        let menus = trailMenus(Self.header("iCloud Drive"), width: 560)
        let chip = try #require(menus.first)
        // Comfortably wider than the 18pt mark plus its padding — it has the name inside it.
        #expect(chip.width > 40,
                "the source chip is \(chip.width)pt wide, which is the mark alone rather than the whole crumb")
        // **Measured against the trail's OTHER menu, not against a number.** The chevron at the
        // trailing end is an accepted click target that has been on this row since before the chip
        // existed, so "at least as tall as that" is a claim about this app rather than about a
        // guideline — and, unlike a literal, it does not silently become the wrong test when the
        // trail's font moves. It did once: this read `>= 16`, which was the chip's height at the
        // `.body` the source name was mistakenly set in, and it failed the moment the label was
        // brought back in step with the `.callout` the rest of the trail is drawn at.
        let quickJump = try #require(menus.last, "the trail drew no quick-jump menu to compare against")
        #expect(chip.height >= quickJump.height,
                "the chip is \(chip.height)pt tall against the quick-jump menu's \(quickJump.height)pt on the same row")
    }

    /// **The chip is not smaller than the ordinary controls above it.**
    ///
    /// It was: 17pt against a bar whose controls draw a fixed `33 × 20` pill, with the difference
    /// almost entirely `.padding(.vertical, 1)` — one point of air, so the capsule hugged the name
    /// instead of containing it. The pane's identity element being the smallest chrome on the pane
    /// is the thing this pins, and it is pinned against `PaneNavMetrics.pill` rather than a literal
    /// so it keeps meaning the same thing if the bar is ever resized.
    ///
    /// **The padding is added rather than measured, and that is a real limit of this test.** The
    /// wash and the hairline are drawn OUTSIDE the `Menu` (they have to be — a `.background` inside
    /// an AppKit-drawn label never paints), so the `NSPopUpButton`'s frame is the label alone. What
    /// is measured is the label, which is what the font choice moves; what is added is the chip's
    /// own constant. A change to either is caught, but only their sum is asserted.
    @Test func theChipIsAtLeastAsTallAsTheBarControlsAboveIt() throws {
        let chip = try #require(trailMenus(Self.header("iCloud Drive"), width: 560).first)
        let drawn = chip.height + 2 * SourceChip.vertical
        let barControl = PaneNavMetrics.pill(.regular).height
        #expect(drawn >= barControl,
                "the source chip draws \(drawn)pt tall against the bar's \(barControl)pt controls, so the pane's identity element is the smallest thing on the pane again")
    }

    /// **The chip says it opens something, and the quick-jump menu beside it still does not.**
    ///
    /// Both halves are the test. At a source root the trail is one crumb, so the row carries exactly
    /// one disclosure mark — and while the chip's was hidden, that one mark belonged to the
    /// quick-jump menu sitting a few points to its right, which is not the source picker. Asserting
    /// only "the chip has an arrow" would pass just as happily on a row where both had one, which is
    /// the confusion the chip's arrow was originally dropped to avoid.
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
