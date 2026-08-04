import AppKit
import SwiftUI
import Testing
@testable import Design

/// The badge's two promises: it costs the control it decorates nothing, and it actually paints.
///
/// Both are measured on a laid-out, rendered control rather than reasoned about. Size comes from
/// `NSHostingView.fittingSize` (the laid-out result, not the constant that fed it), and presence
/// from counting pixels that changed — a view can report a perfectly correct size and draw
/// nothing at all, which is exactly the failure this net is for.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct ShortcutKeycapTests {

    private static let canvas = CGSize(width: 240, height: 44)
    private static let tint = Color(red: 0, green: 0.44, blue: 0.91)

    /// The three control shapes the badge is actually adopted on, so the size assertions cover a
    /// filled button, an outline button and a bare glyph rather than one lucky case. Each carries
    /// the alignment its real call sites use — a labelled button badges at its trailing edge, an
    /// icon-only one badges over the glyph, because a keycap is nearly as wide as the whole
    /// control there and anything overhanging would foul the neighbouring nav buttons.
    @MainActor
    private static func subjects() -> [(name: String, view: AnyView, alignment: Alignment)] {
        [
            ("primary", AnyView(Button("Copy 560 to Dropbox") {}
                .buttonStyle(.actionBar(.primary, tint: tint, onTint: .white))), .trailing),
            ("outline", AnyView(Button("Review 12") {}
                .buttonStyle(.actionBar(.outline, tint: tint, onTint: .white))), .trailing),
            ("glyph", AnyView(Button { } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.hoverAffordance(.glyph, tint: tint))), .center),
        ]
    }

    private func hosted(_ view: some View, revealed: Bool) -> NSHostingView<AnyView> {
        NSHostingView(rootView: AnyView(view.environment(\.shortcutRevealActive, revealed)))
    }

    private func render(_ view: some View, revealed: Bool) -> NSBitmapImageRep? {
        let subject = view
            .environment(\.shortcutRevealActive, revealed)
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .leading)
            // Load-bearing, not scene-setting. Without it the canvas backs onto the borderless
            // window's own (black) buffer, and the standard keycap — a dark `.quaternary` chip —
            // composites to a ZERO pixel delta against it. The first version of this file measured
            // exactly that and reported "the keycap did not paint" for every subject that wasn't
            // sitting on an accent fill.
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)

        let host = NSHostingView(rootView: AnyView(subject))
        host.frame = CGRect(origin: .zero, size: Self.canvas)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Pixels differing by more than a hair between two renders of the same canvas. Every pixel,
    /// not a grid: a keycap is a small object and the point of this count is to notice it.
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

    // MARK: Zero layout shift

    /// The headline invariant: a badged control is the same size whether the reveal is on or off,
    /// so nothing moves or resizes under a settled pointer.
    ///
    /// `fittingSize` and not the metrics: an `.overlay` is *documented* not to affect its host's
    /// size, and this asserts that the modifier really is an overlay rather than, say, an `HStack`
    /// someone swapped in because it looked tidier.
    @Test func aBadgedControlIsTheSameSizeInBothStates() {
        for subject in Self.subjects() {
            let off = hosted(subject.view.shortcutKeycap("⇧⌘→", alignment: subject.alignment),
                             revealed: false).fittingSize
            let on = hosted(subject.view.shortcutKeycap("⇧⌘→", alignment: subject.alignment),
                            revealed: true).fittingSize
            #expect(off == on, "\(subject.name) resized when the reveal came up: \(off) → \(on)")
        }
    }

    /// ...and the modifier costs the control nothing even to adopt: an unbadged control and a
    /// badged one at rest measure the same, so wiring a keycap onto a bar cannot reflow it.
    @Test func adoptingTheBadgeDoesNotChangeARestingControl() {
        for subject in Self.subjects() {
            let bare = hosted(subject.view, revealed: false).fittingSize
            let badged = hosted(subject.view.shortcutKeycap("⇧⌘→", alignment: subject.alignment),
                                revealed: false).fittingSize
            #expect(bare == badged, "\(subject.name) grew just from adopting a keycap: \(bare) → \(badged)")
        }
    }

    /// A long shortcut must not be the exception. `⇧⌘→` is the widest string any adopter passes.
    @Test func aWideKeycapStillCostsTheControlNothing() {
        let view = Button("Review 12") {}.buttonStyle(.actionBar(.outline, tint: Self.tint, onTint: .white))
        let narrow = hosted(view.shortcutKeycap("⏎"), revealed: true).fittingSize
        let wide = hosted(view.shortcutKeycap("⇧⌘→"), revealed: true).fittingSize
        #expect(narrow == wide, "the keycap's own width reached the control: \(narrow) vs \(wide)")
    }

    // MARK: Presence — the badge actually paints

    /// Renders both states and counts the pixels that moved. Correct size proves room; only
    /// pixels prove paint, and this is deliberately NOT asserted through the accessibility tree —
    /// under `swift test` there is no assistive client, so every caption assertion passes
    /// vacuously whether or not anything was drawn.
    @Test func theKeycapPaintsWhenTheRevealIsActive() {
        for subject in Self.subjects() {
            let badged = subject.view.shortcutKeycap("⌘F", alignment: subject.alignment)
            guard let off = render(badged, revealed: false),
                  let on = render(badged, revealed: true) else {
                Issue.record("\(subject.name): no bitmap rep")
                continue
            }
            let changed = pixelsDiffering(off, on)
            // A keycap at this font is roughly 22×14 points; at 2x backing that is ~1200 pixels,
            // and its fill alone covers most of them. 200 is a floor far below a real badge and
            // far above the handful of pixels an anti-aliasing difference could account for.
            #expect(changed > 200,
                    "\(subject.name): the reveal changed only \(changed) pixels — the keycap did not paint")
        }
    }

    /// The other half of the same question: at rest the modifier must paint *nothing*, so a
    /// control that has adopted a keycap looks exactly like one that hasn't.
    @Test func theKeycapPaintsNothingAtRest() {
        for subject in Self.subjects() {
            guard let bare = render(subject.view, revealed: false),
                  let badged = render(subject.view.shortcutKeycap("⌘F", alignment: subject.alignment),
                                      revealed: false) else {
                Issue.record("\(subject.name): no bitmap rep")
                continue
            }
            let changed = pixelsDiffering(bare, badged)
            #expect(changed == 0, "\(subject.name): \(changed) pixels differ at rest")
        }
    }

    // MARK: On-accent contrast

    private func luminance(_ color: NSColor) -> CGFloat {
        AccentLabel.relativeLuminance(red: color.redComponent,
                                      green: color.greenComponent,
                                      blue: color.blueComponent)
    }

    /// `over` composited onto `base` at `alpha`, in sRGB components — which is what the renderer
    /// does with a `Color.black.opacity(_:)` fill over a solid button.
    ///
    /// Both sides are re-tagged into sRGB first: `NSColor.black` is a Generic Gray colour and
    /// *raises* on `redComponent` rather than answering, which is the one way this arithmetic can
    /// fail loudly instead of quietly.
    private func composite(_ over: NSColor, alpha: CGFloat, on base: NSColor) -> NSColor {
        guard let over = over.usingColorSpace(.sRGB), let base = base.usingColorSpace(.sRGB) else {
            Issue.record("no sRGB representation to composite")
            return .white
        }
        return NSColor(srgbRed: over.redComponent * alpha + base.redComponent * (1 - alpha),
                       green: over.greenComponent * alpha + base.greenComponent * (1 - alpha),
                       blue: over.blueComponent * alpha + base.blueComponent * (1 - alpha),
                       alpha: 1)
    }

    private func srgb(_ color: Color) -> NSColor {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            Issue.record("\(color) has no sRGB representation")
            return .white
        }
        return converted
    }

    /// The keycap's white glyph on an accent-filled button must clear the same body-text bar the
    /// button's own label clears — on every hue, including any added later.
    ///
    /// This is the assertion the "obvious" design fails. A translucent *white* key, which is what
    /// the drawing instinct reaches for, lightens its own backing off the deepened fill and drops
    /// the glyph under the floor; scrimming down can only help. Measured over all twelve hues
    /// rather than eyeballed on Blue.
    @Test func theOnAccentKeycapClearsBodyTextContrastOnEveryHue() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let fill = srgb(hue.accentFillColor)
            let backing = composite(.black, alpha: ShortcutKeycapMetrics.onAccentScrim, on: fill)
            let ratio = 1.05 / (luminance(backing) + 0.05)
            #expect(ratio >= AccentFill.whiteLabelContrast,
                    "white keycap glyph on \(hue) is only \(ratio):1")
        }
    }

    /// ...and it is never *worse* than the label beside it, which is the actual promise: the
    /// keycap borrows the button's own guarantee rather than establishing a weaker one.
    ///
    /// Fails if the scrim is ever flipped to a lightening one — the single most likely edit to
    /// this file, and the reason the direction is spelled out in `onAccentScrim`'s doc.
    @Test func theOnAccentScrimNeverLightensTheBacking() {
        for hue in LiquidGlassHue.allCases where hue != .none {
            let fill = srgb(hue.accentFillColor)
            let backing = composite(.black, alpha: ShortcutKeycapMetrics.onAccentScrim, on: fill)
            #expect(luminance(backing) <= luminance(fill),
                    "\(hue): the keycap backing is lighter than the fill it sits on")
        }
    }

    // MARK: Speech

    /// The glyphs are right to show and useless to hear. VoiceOver gets words.
    @Test func shortcutGlyphsAreSpokenAsWords() {
        #expect(ShortcutKeycapSpeech.spoken("⌘F") == "Command F")
        #expect(ShortcutKeycapSpeech.spoken("⇧⌘→") == "Shift Command Right Arrow")
        #expect(ShortcutKeycapSpeech.spoken("esc") == "Escape")
        #expect(ShortcutKeycapSpeech.spoken("␣") == "Space")
        #expect(ShortcutKeycapSpeech.spoken("⌘,") == "Command ,")
    }
}
