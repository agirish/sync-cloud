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

    /// The three control shapes the badge is actually adopted on, so the assertions cover a filled
    /// button, an outline button and a bare glyph rather than one lucky case.
    @MainActor
    private static func subjects() -> [(name: String, view: AnyView)] {
        [
            ("primary", AnyView(Button("Copy 560 to Dropbox") {}
                .buttonStyle(.actionBar(.primary, tint: tint, onTint: .white)))),
            ("outline", AnyView(Button("Review 12") {}
                .buttonStyle(.actionBar(.outline, tint: tint, onTint: .white)))),
            ("glyph", AnyView(Button { } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.hoverAffordance(.glyph, tint: tint)))),
        ]
    }

    private func hosted(_ view: some View, revealed: Bool) -> NSHostingView<AnyView> {
        NSHostingView(rootView: AnyView(view.environment(\.shortcutRevealActive, revealed)))
    }

    private func render(_ view: some View, revealed: Bool,
                        background: Color = Color(nsColor: .windowBackgroundColor)) -> NSBitmapImageRep? {
        let subject = view
            .environment(\.shortcutRevealActive, revealed)
            .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .leading)
            // Load-bearing, not scene-setting. Without it the canvas backs onto the borderless
            // window's own (black) buffer, and the standard keycap — a dark `.quaternary` chip —
            // composites to a ZERO pixel delta against it. The first version of this file measured
            // exactly that and reported "the keycap did not paint" for every subject that wasn't
            // sitting on an accent fill.
            .background(background)
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
            let off = hosted(subject.view.shortcutKeycap("⇧⌘→"),
                             revealed: false).fittingSize
            let on = hosted(subject.view.shortcutKeycap("⇧⌘→"),
                            revealed: true).fittingSize
            #expect(off == on, "\(subject.name) resized when the reveal came up: \(off) → \(on)")
        }
    }

    /// ...and the modifier costs the control nothing even to adopt: an unbadged control and a
    /// badged one at rest measure the same, so wiring a keycap onto a bar cannot reflow it.
    @Test func adoptingTheBadgeDoesNotChangeARestingControl() {
        for subject in Self.subjects() {
            let bare = hosted(subject.view, revealed: false).fittingSize
            let badged = hosted(subject.view.shortcutKeycap("⇧⌘→"),
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
            let badged = subject.view.shortcutKeycap("⌘F")
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
                  let badged = render(subject.view.shortcutKeycap("⌘F"),
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
                .shortcutKeycap("⌘F")
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
    /// on `shortcutKeycap(_:)`. This pins the shape that ordering assumes — a
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

    // MARK: The key is opaque, and the control steps back

    /// A colour sampled at the control's centre — which is where the key sits.
    private func centrePixel(_ rep: NSBitmapImageRep, controlWidth: CGFloat) -> NSColor? {
        let scale = CGFloat(rep.pixelsWide) / Self.canvas.width
        return rep.colorAt(x: Int(controlWidth / 2 * scale), y: Int(Self.canvas.height / 2 * scale))
    }

    /// The key is **opaque**: nothing behind it shows through.
    ///
    /// This is the whole reason the badge stopped being a translucent chip anchored to the trailing
    /// edge. Rendered over a white ground and a black one, the key's own pixels must be identical —
    /// if any of the ground bleeds through, the key is legible on one background and not the other,
    /// which is exactly the state the first design shipped in.
    @Test func theKeyIsOpaqueWhateverIsBehindIt() {
        for subject in Self.subjects() {
            let badged = subject.view.shortcutKeycap("⌘F")
            let controlWidth = hosted(subject.view, revealed: false).fittingSize.width
            guard let onWhite = render(badged, revealed: true, background: .white),
                  let onBlack = render(badged, revealed: true, background: .black),
                  let a = centrePixel(onWhite, controlWidth: controlWidth),
                  let b = centrePixel(onBlack, controlWidth: controlWidth) else {
                Issue.record("\(subject.name): no bitmap rep")
                continue
            }
            let delta = max(abs(a.redComponent - b.redComponent),
                            max(abs(a.greenComponent - b.greenComponent),
                                abs(a.blueComponent - b.blueComponent)))
            #expect(delta < 0.02,
                    "\(subject.name): the ground shows through the key (delta \(delta))")
        }
    }

    /// ...and the control behind it steps back, rather than staying at full strength under a key
    /// that only covers part of it.
    ///
    /// Sampled at the control's LEADING edge, well clear of the centred key, so this measures the
    /// fade and not the badge. Without it the label reads straight through beside the key — which
    /// is what "Copy 1 to Dropbo[⌘→]" looked like, and why it read as a rendering fault.
    /// Mean luminance over a rectangle of the canvas, in points.
    private func meanLuminance(_ rep: NSBitmapImageRep, _ rect: CGRect) -> CGFloat {
        let scale = CGFloat(rep.pixelsWide) / Self.canvas.width
        var total: CGFloat = 0, n = 0
        for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
                guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale)) else { continue }
                total += luminance(c); n += 1
            }
        }
        return n == 0 ? 0 : total / CGFloat(n)
    }

    @Test func theControlFadesBehindTheKey() {
        let button = Button("Copy 560 to Dropbox") {}
            .buttonStyle(.actionBar(.primary, tint: Self.tint, onTint: .white))
        let size = hosted(button, revealed: false).fittingSize
        guard let atRest = render(button.shortcutKeycap("⌘→"), revealed: false),
              let revealed = render(button.shortcutKeycap("⌘→"), revealed: true) else {
            Issue.record("no bitmap rep"); return
        }
        // The control's leading third: inside the fill, clear of the centred key. A mean rather
        // than a probe pixel — a single sample lands on a letter as easily as on the fill, and the
        // first version of this test did exactly that and reported "did not fade" twice.
        let top = (Self.canvas.height - size.height) / 2
        let region = CGRect(x: 4, y: top + 2, width: size.width / 3, height: size.height - 4)

        let before = meanLuminance(atRest, region)
        let after = meanLuminance(revealed, region)
        // Vacuity guard: a deep accent fill is dark. Measured 0.10 at rest and 0.71 revealed on the
        // recording machine — the thresholds sit far inside both.
        #expect(before < 0.35, "the region is not the fill (mean \(before)) — this test is vacuous")
        #expect(after > before + 0.25, "the control did not fade: \(before) → \(after)")
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

    // MARK: Contrast

    private func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            Issue.record("\(color) has no sRGB representation")
            return 0
        }
        return AccentLabel.relativeLuminance(red: rgb.redComponent,
                                             green: rgb.greenComponent,
                                             blue: rgb.blueComponent)
    }

    /// The key's legibility is a property of the key, in both appearances.
    ///
    /// It used to be a property of whatever the key sat on: a translucent chip whose contrast had
    /// to be argued hue by hue, and separately again for `.borderedProminent`, whose fill this code
    /// does not choose. An opaque key ends that whole class of question — `labelColor` on
    /// `controlBackgroundColor` is an AppKit-paired combination, and this measures it rather than
    /// trusting the pairing.
    @Test func theKeyClearsBodyTextContrastInBothAppearances() {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            var label = NSColor.labelColor, ground = NSColor.controlBackgroundColor
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
                ground = NSColor.controlBackgroundColor.usingColorSpace(.sRGB) ?? .white
            }
            let lighter = max(luminance(label), luminance(ground))
            let darker = min(luminance(label), luminance(ground))
            let ratio = (lighter + 0.05) / (darker + 0.05)
            #expect(ratio >= 4.5, "\(name): the key's glyph reads at only \(ratio):1")
        }
    }

    /// ...and the key actually USES those colours.
    ///
    /// The measurement above is of `NSColor` pairings and never touches `ShortcutKeycap` — a
    /// regression to `.secondary`, which is the exact bug this design replaced (a hierarchical
    /// style resolves against the enclosing foreground, so it rendered a WHITE glyph on the light
    /// key the moment it was dropped on the primary transfer button), would leave it green. This
    /// one reads the rendered key: its own fill against its own darkest glyph pixel.
    @Test func theRenderedKeyIsLegibleAgainstItsOwnFill() {
        let key = ShortcutKeycap("W")
        let size = hosted(key, revealed: true).fittingSize
        guard let rep = render(key, revealed: true) else {
            Issue.record("no bitmap rep"); return
        }
        let scale = CGFloat(rep.pixelsWide) / Self.canvas.width
        let top = (Self.canvas.height - size.height) / 2

        // Just inside the leading border, clear of the glyph: the key's own fill.
        guard let fill = rep.colorAt(x: Int(2 * scale), y: Int((top + size.height / 2) * scale)) else {
            Issue.record("no fill pixel"); return
        }
        // The darkest pixel inside the key is the glyph (or its anti-aliased core).
        var glyph = CGFloat(1)
        for y in stride(from: top + 2, to: top + size.height - 2, by: 0.5) {
            for x in stride(from: CGFloat(2), to: size.width - 2, by: 0.5) {
                guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale)) else { continue }
                glyph = min(glyph, luminance(c))
            }
        }
        let lighter = max(luminance(fill), glyph), darker = min(luminance(fill), glyph)
        let ratio = (lighter + 0.05) / (darker + 0.05)
        #expect(ratio >= 4.5, "the rendered key's glyph reads at only \(ratio):1 on its own fill")
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
