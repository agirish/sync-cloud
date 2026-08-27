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
        let host = NSHostingView(rootView: AnyView(
            view.frame(width: width, height: LiquidGlass.headerHeight)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: LiquidGlass.headerHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        var found: [CGRect] = []
        func walk(_ v: NSView) {
            if v is NSPopUpButton {
                let frame = v.convert(v.bounds, to: host)
                // The trail is the lower of the header's two rows.
                if frame.midY > LiquidGlass.headerHeight / 2 { found.append(frame) }
            }
            v.subviews.forEach(walk)
        }
        walk(host)
        return found.sorted { $0.minX < $1.minX }
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
    /// it was undiscoverable: with a 15pt mark carrying no chevron, no border and no hover state,
    /// nothing on screen said the mark was a control, and the adjacent quick-jump chevron got the
    /// clicks instead. One chip, one menu was the answer, so the menu's own frame has to cover the
    /// name as well as the mark.
    @Test func theWholeChipIsTheTarget() throws {
        let menus = trailMenus(Self.header("iCloud Drive"), width: 560)
        let chip = try #require(menus.first)
        // Comfortably wider than the 15pt mark plus its padding — it has the name inside it.
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
}
