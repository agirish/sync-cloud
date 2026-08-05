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

    // MARK: Disabled controls

    /// A disabled control's shortcut does not fire, so it must not advertise one.
    ///
    /// The badge was doing exactly that on the transfer buttons and the destination picker's two
    /// gated buttons — a keycap on a greyed-out control, promising a chord that the key equivalent
    /// refuses. Two things had to be true to fix it and both are asserted here: the modifier reads
    /// `isEnabled`, and it is applied ABOVE `.disabled(…)` so there is an `isEnabled` to read.
    @Test func aDisabledControlWearsNoBadge() {
        for subject in Self.subjects() {
            let badged = subject.view
                .shortcutKeycap("⌘F", alignment: subject.alignment)
                .disabled(true)
            guard let off = render(badged, revealed: false),
                  let on = render(badged, revealed: true) else {
                Issue.record("\(subject.name): no bitmap rep")
                continue
            }
            #expect(pixelsDiffering(off, on) == 0,
                    "\(subject.name): a disabled control painted a keycap during the reveal")
        }
    }

    /// ...and the guard is the modifier's, not the call site's ordering alone: applied BELOW
    /// `.disabled(…)` the modifier cannot see the state, which is why the ordering is documented
    /// on `shortcutKeycap(_:surface:alignment:)`. This pins the shape that ordering assumes — a
    /// control disabled *outside* the badge still reads as enabled, so the badge shows.
    @Test func theDisabledGuardDependsOnTheDocumentedOrdering() {
        let wrongOrder = Button("Review 12") {}
            .buttonStyle(.actionBar(.outline, tint: Self.tint, onTint: .white))
            .disabled(true)
            .shortcutKeycap("⌘F")
        guard let off = render(wrongOrder, revealed: false),
              let on = render(wrongOrder, revealed: true) else {
            Issue.record("no bitmap rep"); return
        }
        #expect(pixelsDiffering(off, on) > 200,
                "the ordering rule is no longer load-bearing: if the modifier now sees through `.disabled` from outside, drop the ordering note from the doc comment")
    }

    // MARK: Placement

    /// The bounding box of every pixel that changed between two renders, in POINTS.
    private func changedBox(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> CGRect? {
        let scale = CGFloat(lhs.pixelsWide) / Self.canvas.width
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<min(lhs.pixelsHigh, rhs.pixelsHigh) {
            for x in 0..<min(lhs.pixelsWide, rhs.pixelsWide) {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else { continue }
                let delta = max(abs(a.redComponent - b.redComponent),
                                max(abs(a.greenComponent - b.greenComponent),
                                    abs(a.blueComponent - b.blueComponent)))
                if delta > 0.02 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        // `maxX`/`maxY` are INCLUSIVE pixel indices, so the box's far edge is one pixel past them.
        // Without the +1 every measurement here reads half a point short at 2x backing, which is
        // most of the 4pt quantity the inset tests are trying to see.
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX + 1 - minX) / scale,
                      height: CGFloat(maxY + 1 - minY) / scale)
    }

    /// A centred badge must actually land centred on its control.
    ///
    /// The trailing inset exists to hold a *trailing* badge off the control's edge. Applied
    /// unconditionally — which is how it shipped — it also pushes a CENTRED badge half the inset
    /// off-centre, and on a 28pt glyph button, which is what every icon-only adopter is, that is
    /// visible. Nothing caught it: the size tests are blind to placement and the paint tests only
    /// count pixels, so the fix went in with no coverage at all until this.
    @Test func aCentredBadgeIsCentredOnItsControl() {
        let glyph = Button { } label: { Image(systemName: "magnifyingglass") }
            .buttonStyle(.hoverAffordance(.glyph, tint: Self.tint))
        // Centred in the canvas, NOT at its leading edge — and that is load-bearing. A glyph button
        // measures 15pt and a `⌘F` keycap 17.5pt, so a centred badge is WIDER than the control it
        // sits on and overhangs it. Rendered against the leading edge it is clipped at x = 0, and
        // clipping swallows exactly the shift this test exists to detect: the first version of it
        // measured a clipped box and passed against the unconditional-inset mutation.
        let badged = glyph
            .shortcutKeycap("⌘F", alignment: .center)
            .frame(width: Self.canvas.width, height: Self.canvas.height)

        guard let off = render(badged, revealed: false),
              let on = render(badged, revealed: true),
              let box = changedBox(off, on) else {
            Issue.record("no bitmap rep, or the keycap painted nothing")
            return
        }
        let controlCentre = Self.canvas.width / 2
        #expect(box.minX > 0 && box.maxX < Self.canvas.width - 1,
                "the badge is clipped by the canvas (\(box)) — this test cannot see a shift")
        #expect(abs(box.midX - controlCentre) < 1.5,
                "the centred keycap sits at \(box.midX)pt on a control centred at \(controlCentre)pt")
    }

    /// ...and the other half of the same rule: a TRAILING badge really is held off the control's
    /// edge by the inset, rather than sitting flush against it.
    ///
    /// Added because a mutation that dropped the inset entirely survived the centring test above —
    /// that one can only see a badge move, not a badge failing to be offset in the first place.
    @Test func aTrailingBadgeIsInsetFromTheControlsEdge() {
        let button = Button("Copy 560 to Dropbox") {}
            .buttonStyle(.actionBar(.primary, tint: Self.tint, onTint: .white))
        let badged = button.shortcutKeycap("⌘→", surface: .accentFill)

        let controlWidth = hosted(button, revealed: false).fittingSize.width
        guard let off = render(badged, revealed: false),
              let on = render(badged, revealed: true),
              let box = changedBox(off, on) else {
            Issue.record("no bitmap rep, or the keycap painted nothing")
            return
        }
        // The control is laid out against the canvas's leading edge, so its trailing edge is at
        // `controlWidth`. One point of tolerance and no more — the quantity under test is 4pt, so
        // this still fails a dropped or doubled inset. The slack is for the keycap's 0.75pt border,
        // which is stroked INSIDE its shape and whose outermost column falls under the 0.02 colour
        // threshold this box is measured with.
        let expected = controlWidth - ShortcutKeycapMetrics.trailingInset
        #expect(abs(box.maxX - expected) < 1,
                "the trailing keycap ends at \(box.maxX)pt, but \(ShortcutKeycapMetrics.trailingInset)pt inside a control ending at \(controlWidth)pt would be \(expected)pt")
    }

    // MARK: Modifier ordering

    /// Moving `.disabled(…)` outside the badge — which three call sites needed so the modifier could
    /// read `isEnabled` — must not change what the control looks like.
    ///
    /// It is not obviously free: `ActionBarButtonStyle` reads `isEnabled` itself and dims the whole
    /// control by `ActionBarMetrics.disabledOpacity`, so the reorder moves the environment write
    /// from inside that style's scope to outside it. This is the behaviour-preservation check for
    /// that reorder, on the laid-out, rendered result rather than on reasoning about SwiftUI's
    /// environment propagation.
    @Test(arguments: ActionBarWeight.allCases)
    func disablingOutsideTheStyleLooksTheSameAsDisablingInside(weight: ActionBarWeight) {
        let style = ActionBarButtonStyle(weight: weight, tint: Self.tint, onTint: .white, isIconOnly: false)
        let inside = Button("New folder") {}.disabled(true).buttonStyle(style)
        let outside = Button("New folder") {}.buttonStyle(style).disabled(true)

        #expect(hosted(inside, revealed: false).fittingSize == hosted(outside, revealed: false).fittingSize,
                "\(weight): the reorder changed the control's size")
        guard let a = render(inside, revealed: false),
              let b = render(outside, revealed: false),
              let blank = render(Color.clear, revealed: false) else {
            Issue.record("\(weight): no bitmap rep"); return
        }
        // Vacuity guard: two identically BLANK canvases would satisfy the comparison below just as
        // well as two identically drawn controls. `.actionBar` dims a disabled control rather than
        // hiding it, so there has to be something there to compare.
        #expect(pixelsDiffering(a, blank) > 200,
                "\(weight): the disabled control painted nothing — the comparison below is vacuous")
        #expect(pixelsDiffering(a, b) == 0,
                "\(weight): the reorder changed \(pixelsDiffering(a, b)) pixels of the disabled control")
    }

    // MARK: On-accent contrast

    /// Re-tags into sRGB before reading components, rather than trusting the caller to.
    ///
    /// `NSColor.white` and `.black` are Generic Gray, and `redComponent` on those *raises* rather
    /// than answering — an uncaught `NSInvalidArgumentException` that takes the whole test process
    /// down, so it reads as a crash rather than as a failing assertion. That has now cost this file
    /// two debugging rounds; the conversion belongs here, once, and not at each call site.
    private func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            Issue.record("\(color) has no sRGB representation")
            return 0
        }
        return AccentLabel.relativeLuminance(red: rgb.redComponent,
                                             green: rgb.greenComponent,
                                             blue: rgb.blueComponent)
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

    /// ...and it is never *worse* than the label beside it, on **any** fill — which is the actual
    /// promise, and the more important one.
    ///
    /// The test above only covers `accentFillColor`, which is what `.actionBar(.primary)` deepens
    /// its tint to. Five adopters are `.borderedProminent` instead, whose bezel AppKit fills with
    /// the raw system accent — a colour this code neither chooses nor deepens, and which the user
    /// may have set to something as light as Yellow, where white text sits near 2:1 before the
    /// keycap is involved at all. So the guarantee that has to hold there is relative, not
    /// absolute: scrimming may not make it worse.
    ///
    /// Sampled over the light hues and the raw accents too, not just the deepened ones, so a fill
    /// the keycap was never designed against still cannot be degraded by it. Fails if the scrim is
    /// ever flipped to a lightening one — the single most likely edit to this file, and the reason
    /// the direction is spelled out in `onAccentScrim`'s doc.
    @Test func theOnAccentScrimNeverLightensAnyBacking() {
        var fills: [(String, NSColor)] = []
        for hue in LiquidGlassHue.allCases where hue != .none {
            fills.append(("\(hue) deepened", srgb(hue.accentFillColor)))
            fills.append(("\(hue) raw", srgb(hue.accentColor)))
        }
        // The two extremes a system accent can reach, which no `LiquidGlassHue` covers.
        fills.append(("white", .white))
        fills.append(("black", .black))

        for (name, fill) in fills {
            let backing = composite(.black, alpha: ShortcutKeycapMetrics.onAccentScrim, on: fill)
            let before = 1.05 / (luminance(fill) + 0.05)
            let after = 1.05 / (luminance(backing) + 0.05)
            #expect(luminance(backing) <= luminance(fill),
                    "\(name): the keycap backing is lighter than the fill it sits on")
            #expect(after >= before - 0.0001,
                    "\(name): the keycap glyph reads at \(after):1 where the button's own label reads at \(before):1")
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
