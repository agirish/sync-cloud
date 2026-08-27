import AppKit
import SwiftUI
import Testing
@testable import Dashboard
import Design
import Sync

/// That the pane header's rung actually **behaves** the way `ScanRungMode` says.
///
/// `ScanRungModeTests` holds the rule; nothing there says `PaneHeader` consults it. That gap has
/// bitten this change set twice already — a rule extracted for testability, tested, and then not
/// wired up, with every test still green. This closes it from the other end: it renders the real
/// header and asserts the pixels differ exactly where the mode says they should, so a revert to
/// inline ternaries that *behaves* the same still passes and one that behaves differently cannot.
///
/// Pixels, not the accessibility tree: there is no accessibility tree without an assistive client,
/// so label assertions here would pass vacuously.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct ScanRungCallSiteTests {

    private static let box = CGSize(width: 560, height: 120)

    /// The real `PaneHeader`, with the bar's arrangement injected so the render does not depend on
    /// whatever the host machine's standard domain happens to hold.
    private static func header(isRefreshing: Bool, canCancel: Bool) -> some View {
        let defaults = ScratchDefaults("ScanRungCallSiteTests")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        defaults.set(PaneBarIconSize.regular.rawValue, forKey: PaneBar.iconSizeKey)
        return PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    rootPath: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: isRefreshing,
            onCancelScan: canCancel ? {} : nil,
            showHiddenFiles: .constant(false),
            viewMode: .constant(.columns), onNewFolder: {})
            .defaultAppStorage(defaults)
    }

    private func bitmap(_ view: some View) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: AnyView(
            view.frame(width: Self.box.width, height: Self.box.height).background(Color.white)
        ))
        host.frame = CGRect(origin: .zero, size: Self.box)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func pixelsDiffering(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        var differing = 0
        for y in 0..<min(lhs.pixelsHigh, rhs.pixelsHigh) {
            for x in 0..<min(lhs.pixelsWide, rhs.pixelsWide) {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(a.redComponent - b.redComponent),
                                max(abs(a.greenComponent - b.greenComponent),
                                    abs(a.blueComponent - b.blueComponent)))
                if delta > 0.02 { differing += 1 }
            }
        }
        return differing
    }

    /// Mid-scan, a header that was given a cancel handler must RENDER differently from one that was
    /// not — `.stop`'s glyph against `.busy`'s. This is the assertion that fails if the rung stops
    /// consulting the mode.
    @Test func aHeaderGivenACancelHandlerDrawsADifferentRungMidScan() throws {
        let busy = try #require(bitmap(Self.header(isRefreshing: true, canCancel: false)))
        let stop = try #require(bitmap(Self.header(isRefreshing: true, canCancel: true)))
        #expect(pixelsDiffering(busy, stop) > 20,
                "the rung rendered identically with and without a cancel handler — PaneHeader is not reading ScanRungMode")
    }

    /// ...and the control: **idle**, the handler must change nothing at all. A header that differed
    /// here would be drawing Stop over a pane with no scan running, and it would also make the test
    /// above pass for the wrong reason — any difference anywhere would satisfy it.
    @Test func theCancelHandlerChangesNothingWhileIdle() throws {
        let without = try #require(bitmap(Self.header(isRefreshing: false, canCancel: false)))
        let with = try #require(bitmap(Self.header(isRefreshing: false, canCancel: true)))
        #expect(pixelsDiffering(without, with) == 0,
                "an idle rung changed appearance just because a cancel handler was supplied")
    }

    /// The regression guard for every caller outside the app, from the rendered side: mid-scan and
    /// with no cancel handler, the rung still goes **disabled** — the behaviour every non-app
    /// caller has always had — while the one with a handler stays live and only swaps its glyph.
    ///
    /// Measured as a comparison rather than an absolute because the numbers are the point:
    /// disabling dims the whole pill (2,264 px against the idle render here), where a glyph swap on
    /// a live control touches only the glyph (356 px). That is a **6× gap in the direction that
    /// says which one is disabled**, and the first cut of this test asserted it backwards — the
    /// fixture is what corrected it. It fails if `.busy` stops being disabled, or if `.stop`
    /// starts being.
    @Test func onlyTheRungWithNoCancelHandlerGoesDisabledMidScan() throws {
        let idle = try #require(bitmap(Self.header(isRefreshing: false, canCancel: false)))
        let busy = try #require(bitmap(Self.header(isRefreshing: true, canCancel: false)))
        let stop = try #require(bitmap(Self.header(isRefreshing: true, canCancel: true)))
        #expect(pixelsDiffering(idle, busy) > pixelsDiffering(idle, stop) * 2,
                "the no-cancel rung no longer dims the way a disabled control does")
    }
}
