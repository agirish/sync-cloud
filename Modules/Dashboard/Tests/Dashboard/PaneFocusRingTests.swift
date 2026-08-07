import AppKit
import SwiftUI
import Testing
@testable import Dashboard
import Design
import Sync

/// The ring that says which pane the keyboard is in.
///
/// Two claims, and they pull against each other — which is why both are measured rather than
/// reasoned about. It has to **paint** (a focus cue that renders as nothing is the failure a green
/// geometry suite cannot see, and this feature shipped once already with no indicator at all), and
/// it has to cost **nothing**: `PaneHeaderHeightTests` pins the header against
/// `LiquidGlass.headerHeight`, and `LensHeaderCard` shares that line from the other side, so a ring
/// that took even a point would push the pinned rung out of its rail.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct PaneFocusRingTests {

    private static let box = CGSize(width: 420, height: 120)

    /// The hue is injected into the SAME store as the bar's arrangement, not layered on outside.
    /// `PaneHeader` reads both through `@AppStorage`, and the INNERMOST `defaultAppStorage` is the
    /// one it sees — a second one applied by the caller never reaches it. The first cut of the
    /// accent test did exactly that and measured a 0-pixel difference between two accents, which
    /// reads identically to "the ring ignores the hue".
    private static func header(isFocused: Bool, hue: LiquidGlassHue = .blue) -> some View {
        let defaults = ScratchDefaults("PaneFocusRingTests")
        defaults.set(PaneBarArrangement.default.encoded, forKey: PaneBar.arrangementKey)
        defaults.set(PaneBarIconSize.regular.rawValue, forKey: PaneBar.iconSizeKey)
        defaults.set(hue.rawValue, forKey: LiquidGlass.hueKey)
        return PaneHeader(
            title: "Left",
            provider: CloudProvider(id: "icloud", displayName: "iCloud Drive", imageName: "icloud-logo",
                                    path: "/Users/test/iCloud", type: .iCloud),
            rootPath: "/Users/test/iCloud", relativePath: "Documents",
            canGoBack: true, canGoForward: false, onBack: {}, onForward: {},
            onNavigate: { _ in }, onNavigateBoth: { _ in }, sortOption: .constant(.name),
            onRefresh: {}, isRefreshing: false, isFocused: isFocused,
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

    /// It paints. The threshold is a real ring's worth of pixels, not "something changed": a 2pt
    /// stroke around the provider capsule is hundreds of pixels, so a handful would mean an
    /// antialiasing artefact rather than a cue anyone can see.
    @Test func aFocusedPanePaintsARing() throws {
        let unfocused = try #require(bitmap(Self.header(isFocused: false)))
        let focused = try #require(bitmap(Self.header(isFocused: true)))
        #expect(pixelsDiffering(unfocused, focused) > 300,
                "the focused header painted no visible ring — a focus cue that renders as nothing is the whole failure mode here")
    }

    /// ...and it costs nothing. `fittingSize` is the laid-out result, so this catches a ring that
    /// was added as a border, a padding or a stroke *inside* a frame rather than as an overlay.
    @Test func theRingChangesNeitherHeightNorWidth() {
        let unfocused = NSHostingView(rootView: AnyView(Self.header(isFocused: false)))
        let focused = NSHostingView(rootView: AnyView(Self.header(isFocused: true)))
        #expect(focused.fittingSize.height == unfocused.fittingSize.height)
        #expect(focused.fittingSize.width == unfocused.fittingSize.width)
        #expect(unfocused.fittingSize.height > 1, "the fixture measured nothing")
    }

    /// The ring is drawn in the app's accent, which is user-selectable — so it has to track the
    /// hue rather than being a hard-coded blue. Two hues that are far apart must produce different
    /// renders; if they did not, the ring would be painting some fixed colour.
    /// What the ring itself is painted with, sampled **only where turning focus on changed
    /// pixels** — which is the ring and nothing else.
    ///
    /// Comparing whole focused renders across two accents does not work and the attempt is worth
    /// recording: the pane bar's controls are accent-tinted too (`paneNavChrome`), so two hues
    /// differ by ~1,246 pixels with no ring drawn at all. Any whole-render comparison passes on
    /// those and says nothing about the ring.
    private func ringColour(hue: LiquidGlassHue) -> (colour: NSColor, samples: Int)? {
        guard let rest = bitmap(Self.header(isFocused: false, hue: hue)),
              let focused = bitmap(Self.header(isFocused: true, hue: hue)) else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, n = 0
        for y in 0..<min(rest.pixelsHigh, focused.pixelsHigh) {
            for x in 0..<min(rest.pixelsWide, focused.pixelsWide) {
                guard let before = rest.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let after = focused.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let delta = max(abs(after.redComponent - before.redComponent),
                                max(abs(after.greenComponent - before.greenComponent),
                                    abs(after.blueComponent - before.blueComponent)))
                guard delta > 0.02 else { continue }
                r += after.redComponent; g += after.greenComponent; b += after.blueComponent; n += 1
            }
        }
        guard n > 0 else { return nil }
        return (NSColor(srgbRed: r / Double(n), green: g / Double(n), blue: b / Double(n), alpha: 1), n)
    }

    @Test func theRingTakesTheAppAccent() throws {
        let blue = try #require(ringColour(hue: .blue))
        let amber = try #require(ringColour(hue: .amber))
        // Both must actually be rings, not a stray pixel or two.
        #expect(blue.samples > 300 && amber.samples > 300,
                "one of the accents painted no ring at all — \(blue.samples) / \(amber.samples) pixels")
        // Blue and amber sit at opposite ends of the red channel; a hard-coded stroke would put
        // them at the same place.
        let redLift = amber.colour.redComponent - blue.colour.redComponent
        #expect(redLift > 0.15,
                "the ring is the same colour under two very different accents — it is not reading the hue (red lift \(redLift))")
    }
}
