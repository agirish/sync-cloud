import AppKit
import SwiftUI
import Testing
@testable import Dashboard
import Design
import Sync

/// That the pane header's rung behaves the way `ScanRungMode` says. `ScanRungModeTests` holds the
/// rule but can't see whether `PaneHeader` consults it, so this renders the real header and asserts
/// the pixels differ where the mode says they should. Pixels, because there is no accessibility
/// tree without an assistive client.
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
        ProbeRig(AnyView(view.frame(width: Self.box.width, height: Self.box.height).background(Color.white)),
                 size: Self.box).capture()
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

    /// Mid-scan, a header given a cancel handler must render differently from one without:
    /// `.stop`'s glyph against `.busy`'s. Fails if the rung stops consulting the mode.
    @Test func aHeaderGivenACancelHandlerDrawsADifferentRungMidScan() throws {
        let busy = try #require(bitmap(Self.header(isRefreshing: true, canCancel: false)))
        let stop = try #require(bitmap(Self.header(isRefreshing: true, canCancel: true)))
        #expect(pixelsDiffering(busy, stop) > 20,
                "the rung rendered identically with and without a cancel handler — PaneHeader is not reading ScanRungMode")
    }

    /// ...and the control: idle, the handler must change nothing. A difference here would mean Stop
    /// over a pane with no scan running, and would let the test above pass for the wrong reason.
    @Test func theCancelHandlerChangesNothingWhileIdle() throws {
        let without = try #require(bitmap(Self.header(isRefreshing: false, canCancel: false)))
        let with = try #require(bitmap(Self.header(isRefreshing: false, canCancel: true)))
        #expect(pixelsDiffering(without, with) == 0,
                "an idle rung changed appearance just because a cancel handler was supplied")
    }

    /// Guards callers outside the app, from the rendered side: mid-scan with no cancel handler the
    /// rung goes disabled, while one with a handler stays live and only swaps its glyph. A
    /// comparison, not an absolute: disabling dims the whole pill, a glyph swap only the glyph.
    /// Fails if `.busy` stops being disabled or `.stop` starts being.
    @Test func onlyTheRungWithNoCancelHandlerGoesDisabledMidScan() throws {
        let idle = try #require(bitmap(Self.header(isRefreshing: false, canCancel: false)))
        let busy = try #require(bitmap(Self.header(isRefreshing: true, canCancel: false)))
        let stop = try #require(bitmap(Self.header(isRefreshing: true, canCancel: true)))
        #expect(pixelsDiffering(idle, busy) > pixelsDiffering(idle, stop) * 2,
                "the no-cancel rung no longer dims the way a disabled control does")
    }
}
