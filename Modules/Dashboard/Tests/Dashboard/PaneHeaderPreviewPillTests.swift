import AppKit
import SwiftUI
import Testing
import Sync
import Design
@testable import Dashboard

/// **The preview pill paints the state it is given, and takes it from its binding.**
///
/// Two things this has to cover, and the second is why it is new. The pill wears the accent while
/// the preview shows and nothing while it doesn't — that claim is about painted pixels, and every
/// geometry and control-count test in `PaneHeaderHeightTests` is blind to it. And the value it wears
/// now arrives as a `Binding` from the host, because Browse's preview preference is not Compare's
/// (`PaneViewMode.previewColumnKey(isBrowse:)`); a header that went back to reading the shared key
/// from `@AppStorage` would answer for every surface at once, which is the whole bug.
///
/// **`DashboardSnapshotTests.paneHeaderWideWithPreviewOff` does not cover either half, and its doc
/// comment claiming otherwise was wrong.** Measured, by rendering the pill from a stale
/// `@AppStorage` while the binding said off: both reference images still matched. The pill is about
/// 0.9% of a 660×92 header and `assertViewSnapshot` allows 1% of pixels to differ, so the control
/// this feature turns on lives *under* that harness's tolerance. (It is also
/// `.machinePinned(.referenceImages)`, so it never runs on CI at all.) Counting the pixels that
/// DIFFER between the two states has neither problem.
@MainActor
@Suite(.serialized) struct PaneHeaderPreviewPillTests {

    /// The pill measures 26×22pt at this control size, so a state change that repaints its fill and
    /// its glyph moves several hundred pixels. The floor is set well under what the accent fill
    /// alone covers and well over anti-aliasing jitter, which `testTheSameStateRendersIdentically`
    /// measures as exactly zero.
    static let floor = 200

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func testThePillPaintsItsStateInBothAppearances(appearance: NSAppearance.Name) throws {
        // **The fixture's premise, stated rather than assumed.** This renders the default arrangement
        // at a width that seats it, so the pill is on the bar; move `.preview` out of the default and
        // it is drawn in the ⋯ menu instead, which no render of the bar contains. The measurement
        // below would then report "moved 0" and blame the pill for not painting — the right number
        // attached to the wrong cause. This says which it is.
        #expect(PaneBarArrangement.default.items.contains(.preview),
                "the default pane bar no longer carries the preview pill — this fixture renders the bar, so re-point it at whatever draws the toggle now")

        let on = try Self.rendered(previewEnabled: true, appearance: appearance)
        let off = try Self.rendered(previewEnabled: false, appearance: appearance)

        // The harness first: two blank renders differ in nothing, and would fail this test for a
        // reason that has nothing to do with the pill.
        #expect(try Self.inkCount(on) > 1_000, "the ON render is nearly empty — the header did not draw")
        #expect(try Self.inkCount(off) > 1_000, "the OFF render is nearly empty — the header did not draw")

        let moved = try Self.differingPixels(on, off)
        #expect(moved >= Self.floor, """
                turning the preview off moved \(moved) pixel(s) in \(appearance.rawValue) — the pill \
                is not painting the state it was handed. A header reading the preference from \
                `@AppStorage` instead of its binding fails exactly here, and answers for Browse and \
                Compare with one value.
                """)
    }

    /// The control on the measurement: the same state twice must move NOTHING. Without it, a floor
    /// of 200 could be met by render-to-render noise, and the test above would pass against a pill
    /// frozen in one fill.
    @Test func testTheSameStateRendersIdentically() throws {
        let a = try Self.rendered(previewEnabled: true, appearance: .aqua)
        let b = try Self.rendered(previewEnabled: true, appearance: .aqua)
        #expect(try Self.differingPixels(a, b) == 0,
                "two renders of the same state differ — this fixture is noisy, and the floor above measures the noise rather than the pill")
    }

    // MARK: - Measurement

    /// Pixels whose colour differs at all between two renders of the same size.
    static func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) throws -> Int {
        try #require(a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh,
                     "the two renders are different sizes — nothing below compares like for like")
        var count = 0
        for x in 0..<a.pixelsWide {
            for y in 0..<a.pixelsHigh {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(p.redComponent - q.redComponent) > 0.01
                    || abs(p.greenComponent - q.greenComponent) > 0.01
                    || abs(p.blueComponent - q.blueComponent) > 0.01 { count += 1 }
            }
        }
        return count
    }

    /// Pixels that are not the window-background ground, as a proof the header rendered at all.
    static func inkCount(_ rep: NSBitmapImageRep) throws -> Int {
        let ground = try #require(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let p = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(p.redComponent - ground.redComponent) > 0.02
                    || abs(p.greenComponent - ground.greenComponent) > 0.02
                    || abs(p.blueComponent - ground.blueComponent) > 0.02 { count += 1 }
            }
        }
        return count
    }

    /// The header at a width wide enough to carry the pill on the bar rather than in the ⋯ menu,
    /// in Columns mode — the only mode that offers the toggle at all.
    static func rendered(previewEnabled: Bool, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        // Its own suite, so nothing is inherited from the process or from another test. The preview
        // setting is deliberately NOT in here: the point of the fixture is that it travels as a
        // binding, and a value written to defaults would prove nothing about the pill.
        let defaults = ScratchDefaults("PaneHeaderPreviewPillTests-render")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        let size = CGSize(width: 700, height: LiquidGlass.headerHeight)
        let header = PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    path: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, showHiddenFiles: .constant(false),
            viewMode: .constant(.columns), previewEnabled: .constant(previewEnabled))
        let host = NSHostingView(rootView: AnyView(
            header
                .defaultAppStorage(defaults)
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
        ))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}
