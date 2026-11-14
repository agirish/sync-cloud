import AppKit
import SwiftUI
import Testing
@testable import Design

/// The badge's two promises: it costs the control it decorates nothing, and it actually paints.
///
/// Both are measured on a laid-out, rendered control. Size comes from `NSHostingView.fittingSize`,
/// and presence from counting changed pixels, since a view can report a correct size and draw
/// nothing at all.
@MainActor
@Suite(.serialized) struct ShortcutKeycapTests {

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
            // Load-bearing: without it the canvas backs onto the borderless window's black buffer,
            // and a dark keycap composites to a zero pixel delta against it, so every subject off
            // an accent fill would report "the keycap did not paint".
            .background(background)
            .environment(\.colorScheme, .light)
        return offscreenBitmap(AnyView(subject), size: Self.canvas)
    }

    // MARK: Zero layout shift

    /// A badged control is the same size whether the reveal is on or off, so nothing moves under a
    /// settled pointer. Measured by `fittingSize`, so it fails if the overlay becomes, say, an
    /// `HStack`.
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
        let narrow = hosted(view.shortcutKeycap("↩"), revealed: true).fittingSize
        let wide = hosted(view.shortcutKeycap("⇧⌘→"), revealed: true).fittingSize
        #expect(narrow == wide, "the keycap's own width reached the control: \(narrow) vs \(wide)")
    }

    // MARK: Presence — the badge actually paints

    /// Renders both states and counts the pixels that moved: only pixels prove paint. Not asserted
    /// through the accessibility tree, which under `swift test` has no assistive client, so caption
    /// assertions would pass whether or not anything was drawn.
    @Test(.machinePinned(.pixelSampling)) func theKeycapPaintsWhenTheRevealIsActive() {
        for subject in Self.subjects() {
            let badged = subject.view.shortcutKeycap("⌘F")
            guard let off = render(badged, revealed: false),
                  let on = render(badged, revealed: true) else {
                Issue.record("\(subject.name): no bitmap rep")
                continue
            }
            let changed = Pixel.differing(off, on)
            // A keycap here is roughly 22×14 points, ~1200 pixels at 2x. 200 sits far below a real
            // badge and far above what an anti-aliasing difference could account for.
            #expect(changed > 200,
                    "\(subject.name): the reveal changed only \(changed) pixels — the keycap did not paint")
        }
    }

    /// The other half of the same question: at rest the modifier must paint *nothing*, so a
    /// control that has adopted a keycap looks exactly like one that hasn't.
    @Test(.machinePinned(.pixelSampling)) func theKeycapPaintsNothingAtRest() {
        for subject in Self.subjects() {
            guard let bare = render(subject.view, revealed: false),
                  let badged = render(subject.view.shortcutKeycap("⌘F"),
                                      revealed: false) else {
                Issue.record("\(subject.name): no bitmap rep")
                continue
            }
            let changed = Pixel.differing(bare, badged)
            #expect(changed == 0, "\(subject.name): \(changed) pixels differ at rest")
        }
    }

    // MARK: Disabled controls

    /// A disabled control's shortcut does not fire, so it must not advertise one. Needs both that
    /// the modifier reads `isEnabled` and that it is applied above `.disabled(…)`, so there is an
    /// `isEnabled` to read.
    @Test(.machinePinned(.pixelSampling)) func aDisabledControlWearsNoBadge() {
        for subject in Self.subjects() {
            let badged = subject.view
                .shortcutKeycap("⌘F")
                .disabled(true)
            guard let off = render(badged, revealed: false),
                  let on = render(badged, revealed: true) else {
                Issue.record("\(subject.name): no bitmap rep")
                continue
            }
            #expect(Pixel.differing(off, on) == 0,
                    "\(subject.name): a disabled control painted a keycap during the reveal")
        }
    }

    /// ...and applied below `.disabled(…)` the modifier can't see the state, which is why the
    /// ordering is documented on `shortcutKeycap(_:)`. This pins that assumption: a control
    /// disabled outside the badge still reads as enabled, so the badge shows.
    @Test(.machinePinned(.pixelSampling)) func theDisabledGuardDependsOnTheDocumentedOrdering() {
        let wrongOrder = Button("Review 12") {}
            .buttonStyle(.actionBar(.outline, tint: Self.tint, onTint: .white))
            .disabled(true)
            .shortcutKeycap("⌘F")
        guard let off = render(wrongOrder, revealed: false),
              let on = render(wrongOrder, revealed: true) else {
            Issue.record("no bitmap rep"); return
        }
        #expect(Pixel.differing(off, on) > 200,
                "the ordering rule is no longer load-bearing: if the modifier now sees through `.disabled` from outside, drop the ordering note from the doc comment")
    }

    /// A `nil` symbol paints nothing, reveal or no reveal (the scan rung once it has become Stop).
    /// `theKeycapPaintsWhenTheRevealIsActive` is the positive control, so "nothing changed" can't
    /// pass on a harness that renders nothing.
    @Test(.machinePinned(.pixelSampling)) func aControlWithNoChordWearsNoBadge() {
        for subject in Self.subjects() {
            let unbadged = subject.view.shortcutKeycap(nil)
            guard let off = render(unbadged, revealed: false),
                  let on = render(unbadged, revealed: true) else {
                Issue.record("\(subject.name): no bitmap rep")
                continue
            }
            #expect(Pixel.differing(off, on) == 0,
                    "\(subject.name): a control with no chord painted a keycap during the reveal")
        }
    }

    // MARK: The key is opaque, and the control steps back

    /// A colour sampled at the control's centre, where the key sits.
    private func centrePixel(_ rep: NSBitmapImageRep, controlWidth: CGFloat) -> NSColor? {
        let scale = CGFloat(rep.pixelsWide) / Self.canvas.width
        return rep.colorAt(x: Int(controlWidth / 2 * scale), y: Int(Self.canvas.height / 2 * scale))
    }

    /// The key is opaque: nothing behind it shows through. Rendered over white and over black, its
    /// pixels must be identical; if the ground bled through, the key would be legible on one
    /// background and not the other.
    @Test(.machinePinned(.pixelSampling)) func theKeyIsOpaqueWhateverIsBehindIt() {
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

    /// ...and the control behind it steps back; at full strength its label reads straight through
    /// beside the key like a rendering fault. Sampled at the leading edge, clear of the centred
    /// key, so this measures the fade and not the badge.
    @Test(.machinePinned(.pixelSampling)) func theControlFadesBehindTheKey() {
        let button = Button("Copy 560 to Dropbox") {}
            .buttonStyle(.actionBar(.primary, tint: Self.tint, onTint: .white))
        let size = hosted(button, revealed: false).fittingSize
        guard let atRest = render(button.shortcutKeycap("⌘→"), revealed: false),
              let revealed = render(button.shortcutKeycap("⌘→"), revealed: true) else {
            Issue.record("no bitmap rep"); return
        }
        // The control's leading third: inside the fill, clear of the centred key. A mean, because
        // a single sample can land on a letter as easily as on the fill.
        let top = (Self.canvas.height - size.height) / 2
        let region = CGRect(x: 4, y: top + 2, width: size.width / 3, height: size.height - 4)

        let before = meanLuminance(atRest, region)
        let after = meanLuminance(revealed, region)
        // Vacuity guard: a deep accent fill is dark. Measured about 0.10 at rest and 0.71 revealed;
        // the thresholds sit far inside both.
        #expect(before < 0.35, "the region is not the fill (mean \(before)) — this test is vacuous")
        #expect(after > before + 0.25, "the control did not fade: \(before) → \(after)")
    }

    // MARK: Modifier ordering

    /// Applying `.disabled(…)` outside the style, as badged call sites must, doesn't change the
    /// control. Checked on the render: `ActionBarButtonStyle` reads `isEnabled` itself and dims by
    /// `ActionBarMetrics.disabledOpacity`.
    @Test(.machinePinned(.pixelSampling), arguments: ActionBarWeight.allCases)
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
        // Vacuity guard: two blank canvases would satisfy the comparison below too. `.actionBar`
        // dims a disabled control rather than hiding it, so something must be there to compare.
        #expect(Pixel.differing(a, blank) > 200,
                "\(weight): the disabled control painted nothing — the comparison below is vacuous")
        #expect(Pixel.differing(a, b) == 0,
                "\(weight): the reorder changed \(Pixel.differing(a, b)) pixels of the disabled control")
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

    /// The key's legibility is a property of the key, in both appearances, not of whatever it sits
    /// on. `labelColor` on `controlBackgroundColor` is an AppKit pairing; this measures it rather
    /// than trusting it.
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

    /// ...and the rendered key uses those colours: its fill against its darkest glyph pixel. A
    /// switch to `.secondary` would pass the test above, yet resolves against the enclosing
    /// foreground and draws a white glyph on the light key over the primary transfer button.
    @Test(.machinePinned(.pixelSampling)) func theRenderedKeyIsLegibleAgainstItsOwnFill() {
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
        // Punctuation keys are named: a bare "." or "," reads as sentence punctuation, so
        // "Command ." announces as just "Command", a chord that doesn't exist.
        #expect(ShortcutKeycapSpeech.spoken("⌘,") == "Command Comma")
        #expect(ShortcutKeycapSpeech.spoken("⇧⌘.") == "Shift Command Period")
        #expect(ShortcutKeycapSpeech.spoken("⌘[") == "Command Left Bracket")
        #expect(ShortcutKeycapSpeech.spoken("⌘]") == "Command Right Bracket")
        #expect(ShortcutKeycapSpeech.spoken("⌘⌫") == "Command Delete")
        #expect(ShortcutKeycapSpeech.spoken("⌥⌘F") == "Option Command F")
        // ↩ is how every Return keycap is drawn, so it must be spoken, not read as a raw glyph.
        #expect(ShortcutKeycapSpeech.spoken("↩") == "Return")
        #expect(ShortcutKeycapSpeech.spoken("⇧↩") == "Shift Return")
    }
}
