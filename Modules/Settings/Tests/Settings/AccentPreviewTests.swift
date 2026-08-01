import AppKit
import Design
import SwiftUI
import Testing
@testable import Settings

/// Pins what the Appearance tab's accent preview is FOR: showing the accent pairing the app
/// actually ships.
///
/// The trap this suite exists to catch is a specific one, and it is attractive rather than
/// obvious. `LiquidGlassHue` offers two accents — the raw `accentColor` and the deepened
/// `accentFillColor` — and the raw one renders a brighter, livelier capsule. It is also the one
/// that strands a white label at 2.68:1 on Green and 2.20:1 on Amber, which is why every filled
/// surface in the app takes the deepened value (see `AccentFill`). A preview built by eye, or a
/// later refactor "simplifying" `accentFillColor` to `accentColor`, would show users a pairing the
/// app cannot render — worse than showing them nothing.
///
/// So the fill is measured in PAINTED PIXELS rather than by reading the property back. Asserting
/// `strip.someColor == hue.accentFillColor` would only prove the view holds the value; it would
/// not notice a `.opacity()`, a `.disabled()` dimming or a second fill drawn on top, and all three
/// change what the user is actually shown. `AccentFill.deepened` is also a DYNAMIC colour, so two
/// calls are not `==` to begin with.
@MainActor
@Suite(.serialized) struct AccentPreviewTests {

    /// Every hue but `.none`. `.none` resolves `Color.accentColor` — the machine's System Settings
    /// accent — so its exact value is not a property of this code. It gets its own case below,
    /// asserting the guarantees that hold for ANY input instead.
    private static let fixedHues = LiquidGlassHue.allCases.filter { $0 != .none }

    /// The hues `AccentFill` actually deepens. On the other five the raw and deepened accents are
    /// the same colour by construction (already dark enough to carry white), so "the preview did
    /// not use the raw accent" is unfalsifiable there — naming them keeps the suite honest about
    /// which cases can really tell the two apart.
    private static let deepenedHues: [LiquidGlassHue] = [.cyan, .teal, .green, .amber, .coral, .rose]

    // MARK: Rendering

    /// Renders the strip at its own fitting size and returns the bitmap plus that size in points.
    private func renderStrip(_ hue: LiquidGlassHue,
                             _ appearance: NSAppearance.Name) -> (NSBitmapImageRep, CGSize) {
        let view = AccentPreviewStrip(hue: hue)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        let host = NSHostingView(rootView: AnyView(view))
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.colorSpace = .sRGB
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        return (rep, size)
    }

    /// The pixel at a point, in points rather than backing pixels.
    ///
    /// The re-tag is load-bearing and cost an hour: the window renders into an sRGB backing store,
    /// so the rep's samples ARE sRGB — but `colorAt` hands them back labelled
    /// `NSCalibratedRGBColorSpace`, and calling `usingColorSpace(.sRGB)` on that CONVERTS
    /// already-correct values, lightening every one of them (deepened Blue read back as 0.221 /
    /// 0.534 / 0.916 instead of 0.175 / 0.445 / 0.895 — close enough to the raw accent to look
    /// like a real defect in the view). Re-tagging keeps the samples and fixes only the label.
    private func paint(_ rep: NSBitmapImageRep, _ point: CGPoint, in size: CGSize) -> NSColor? {
        let sx = CGFloat(rep.pixelsWide) / size.width
        let sy = CGFloat(rep.pixelsHigh) / size.height
        guard let px = rep.colorAt(x: Int(point.x * sx), y: Int(point.y * sy)) else { return nil }
        return NSColor(srgbRed: px.redComponent, green: px.greenComponent,
                       blue: px.blueComponent, alpha: px.alphaComponent)
    }

    /// The transfer button's fill, sampled 5pt inside its leading edge at the vertical centre —
    /// inside the capsule (whose leftmost point at mid-height is the strip's 10pt padding) and
    /// well clear of the label, which starts 12pt further in.
    private func buttonFill(_ hue: LiquidGlassHue, _ appearance: NSAppearance.Name) -> NSColor? {
        let (rep, size) = renderStrip(hue, appearance)
        return paint(rep, CGPoint(x: 15, y: size.height / 2), in: size)
    }

    /// The count pill's fill, sampled 5pt inside its TRAILING edge — the pill is the strip's last
    /// element, so its capsule ends at the strip's 10pt trailing padding, and its own 10pt padding
    /// keeps the label out of the sample.
    private func pillFill(_ hue: LiquidGlassHue, _ appearance: NSAppearance.Name) -> NSColor? {
        let (rep, size) = renderStrip(hue, appearance)
        return paint(rep, CGPoint(x: size.width - 15, y: size.height / 2), in: size)
    }

    // MARK: Color math

    private func luminance(_ c: NSColor) -> CGFloat {
        guard let s = c.usingColorSpace(.sRGB) else { return 0 }
        return AccentLabel.relativeLuminance(red: s.redComponent, green: s.greenComponent, blue: s.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        let (hi, lo) = x > y ? (x, y) : (y, x)
        return Double((hi + 0.05) / (lo + 0.05))
    }

    /// Resolves a SwiftUI `Color` the way the render does, in a pinned appearance — `accentFillColor`
    /// is dynamic, so it must be asked in an appearance or it answers for whatever is current.
    private func resolve(_ color: Color, _ appearance: NSAppearance.Name) -> NSColor {
        var out: NSColor?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB)
        }
        return out ?? NSColor(color)
    }

    /// Distance between two colours in sRGB components, for "is this the same paint" checks.
    ///
    /// Both sides are converted first, and that is not belt-and-braces: `NSColor.white` is a
    /// GRAY-space colour, and asking a gray colour for `redComponent` does not return 1 — it
    /// throws. The samples arriving here are already sRGB-tagged, so for those the conversion is
    /// the no-op it looks like.
    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return .infinity }
        return max(abs(x.redComponent - y.redComponent),
                   max(abs(x.greenComponent - y.greenComponent), abs(x.blueComponent - y.blueComponent)))
    }

    // MARK: The pairing

    /// The button and the pill both paint `accentFillColor` — the DEEPENED accent.
    ///
    /// Tolerance is 0.02 per component: the fill is composited over the strip's ground and through
    /// a `compositingGroup`, so the painted value is the fill itself rather than a blend, but 8-bit
    /// quantisation still moves the last digit.
    /// Looped rather than `@Test(arguments:)` because `LiquidGlassHue` is not `Sendable` and so
    /// cannot cross into a parameterized case. Every expectation names its hue, so a failure still
    /// says which one broke.
    @MainActor
    @Test func previewPaintsTheDeepenedAccent() async throws {
        for hue in Self.fixedHues {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let expected = resolve(hue.accentFillColor, appearance)
                let button = try #require(buttonFill(hue, appearance))
                let pill = try #require(pillFill(hue, appearance))

                #expect(distance(button, expected) < 0.02,
                        "\(hue.displayName) button painted \(button) in \(appearance.rawValue), not the deepened \(expected).")
                #expect(distance(pill, expected) < 0.02,
                        "\(hue.displayName) count pill painted \(pill) in \(appearance.rawValue), not the deepened \(expected).")
            }
        }
    }

    /// …and specifically NOT the raw accent, on the six hues where the two actually differ.
    ///
    /// Separate from the case above because it is the one that can catch the swap: on Blue or
    /// Indigo the raw and deepened accents are the same colour, so an equality check there passes
    /// either way. This is where the guard has teeth.
    ///
    /// **The count pill is the assertion that matters, and the button alone would be a fake.**
    /// Mutation-testing this suite turned up exactly that: feeding the strip `accentColor`
    /// everywhere still leaves the BUTTON correct, because `ActionBarButtonStyle` deepens its own
    /// tint for `.primary` (`fill = AccentFill.deepened(tint)`) and repairs the mistake on the way
    /// to the screen. `SemanticCapsuleStyle.onAccent` has no such repair — it paints the fill it is
    /// handed — so the pill is the one surface where the raw accent actually reaches the user, and
    /// a version of this test that sampled only the button passed the mutation it exists to catch.
    @MainActor
    @Test func previewRejectsTheRawAccent() async throws {
        for hue in Self.deepenedHues {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let raw = resolve(hue.accentColor, appearance)
                let deepened = resolve(hue.accentFillColor, appearance)
                // The premise: on these hues the two really are different paints, so the assertions
                // below are falsifiable. If AccentFill ever stops deepening one, this says so.
                #expect(distance(raw, deepened) > 0.02,
                        "\(hue.displayName): raw and deepened accents are the same colour — this case proves nothing.")

                let pill = try #require(pillFill(hue, appearance))
                #expect(distance(pill, raw) > 0.02,
                        "\(hue.displayName) count pill painted the RAW accent \(raw) — white on it is illegible.")

                let button = try #require(buttonFill(hue, appearance))
                #expect(distance(button, raw) > 0.02,
                        "\(hue.displayName) button painted the RAW accent \(raw).")
            }
        }
    }

    /// The promise the whole deepening exists to keep, measured on the pixels the preview actually
    /// shows rather than on the palette: the white label clears WCAG AA on both chips, every hue,
    /// both appearances.
    @MainActor
    @Test func whiteLabelClearsAAOnWhatIsPainted() async throws {
        for hue in Self.fixedHues {
            let white = NSColor(hue.onAccentLabelColor).usingColorSpace(.sRGB)!
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let button = try #require(buttonFill(hue, appearance))
                let pill = try #require(pillFill(hue, appearance))

                #expect(contrast(white, button) >= 4.5,
                        "\(hue.displayName) button: white label at \(contrast(white, button)):1.")
                #expect(contrast(white, pill) >= 4.5,
                        "\(hue.displayName) count pill: white label at \(contrast(white, pill)):1.")
            }
        }
    }

    /// `onAccentLabelColor` is white for every hue — the other half of the pairing, and the half a
    /// refactor could quietly change without moving a single fill.
    @Test func theOnAccentLabelIsWhiteForEveryHue() {
        for hue in LiquidGlassHue.allCases {
            let label = NSColor(hue.onAccentLabelColor).usingColorSpace(.sRGB)!
            #expect(distance(label, .white) < 0.01, "\(hue.displayName) pairs with \(label), not white.")
        }
    }

    // MARK: The "None" hue

    /// `.none` is the case most likely to look broken, so it is asserted rather than assumed: it
    /// defers to the system accent, so the strip must still paint a real, opaque, legible button —
    /// not an invisible one, and not a transparent hole showing the ground through it.
    ///
    /// The exact colour is the machine's business, so what is pinned are the guarantees that hold
    /// for any input: fully opaque, distinct from the ground behind it, and carrying white at AA.
    @MainActor
    @Test func noneStillPaintsALegibleButton() async throws {
        let white = NSColor.white.usingColorSpace(.sRGB)!
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let (rep, size) = renderStrip(.none, appearance)

            // FIRST: the button is actually there. Every hue lays the strip out identically — the
            // two chips carry the same text regardless — so `.none`'s strip must measure the same
            // as a fixed hue's. Without this the pixel checks below are hollow: drop the button
            // for `.none` and the pill simply slides into the leading position, where it answers
            // the sample point with an accent capsule of its own and every assertion still passes.
            // Mutation-testing caught precisely that.
            let (_, reference) = renderStrip(.blue, appearance)
            #expect(abs(size.width - reference.width) < 0.5 && abs(size.height - reference.height) < 0.5,
                    "None laid out at \(size) against \(reference) for a fixed hue — a chip is missing.")

            let button = try #require(paint(rep, CGPoint(x: 15, y: size.height / 2), in: size))
            // The strip's ground, sampled in its top-left corner inside the border.
            let ground = try #require(paint(rep, CGPoint(x: 3, y: 3), in: size))

            #expect(button.alphaComponent > 0.99, "None painted a translucent button (\(button)).")
            #expect(distance(button, ground) > 0.05,
                    "None's button is indistinguishable from the ground behind it.")
            #expect(contrast(white, button) >= 4.5,
                    "None: white label at \(contrast(white, button)):1 on the system accent.")
        }
    }

    // MARK: Caption

    /// The caption follows the neighbouring sections' idiom — name the value, then say what it
    /// does — and `.none` gets a sentence of its own rather than the generic one, because "None.
    /// Used for filled controls…" under a visibly coloured button would read as a bug.
    @Test func theCaptionNamesTheChoiceAndItsUses() {
        #expect(AccentColorSection.caption(for: .cyan)
                == "Cyan. Used for filled controls, selection, and the seam chrome.")
        #expect(AccentColorSection.caption(for: .graphite).hasPrefix("Graphite. "))

        let none = AccentColorSection.caption(for: .none)
        #expect(none.hasPrefix("None. "))
        #expect(none.contains("macOS accent color"),
                "None's caption must explain why a coloured button is still showing: \(none)")
    }

    // MARK: Snapshot

    /// The section as it ships: twelve swatches, the preview strip, and the caption — at the real
    /// content width, in both appearances.
    ///
    /// Four hues, chosen so the reference shows the on-accent pairing across the deepening range:
    /// Amber and Cyan are the two lightest accents (the ones `AccentFill` moves furthest, and the
    /// ones where a raw-accent regression would be unmistakable), Indigo and Graphite are dark
    /// enough to come back untouched. `.none` is deliberately absent — it resolves the machine's
    /// system accent, which would make this reference non-portable.
    ///
    /// What this reference does and does not protect, measured rather than assumed (the caveat
    /// `countPillFreshnessStates` records for the same reason): swapping the deepened fill for the
    /// raw accent DOES fail it — the colour change is far past the 0.99/0.98 tolerance. Changing
    /// the strip's internal spacing by 4pt does NOT: one small capsule shifting inside a 583×700
    /// frame is a smaller share of the pixels than the tolerance absorbs. Geometry here is pinned
    /// by `SettingsLayoutTests`' laid-out height and by the size check in
    /// `noneStillPaintsALegibleButton`, not by this image.
    @MainActor
    @Test func accentSectionSnapshot() {
        assertViewSnapshot(
            of: AccentSectionSpecimen(),
            // 700 clears four sections at their measured 163pt pitch plus the page's own padding.
            // Sized deliberately, not generously: the frame is fixed, so a section growing past it
            // would be silently cropped out of the reference rather than failing it.
            size: CGSize(width: SettingsSheetMetrics.contentWidth(textScale: 1), height: 700),
            named: "accent-section")
    }

    private struct AccentSectionSpecimen: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                ForEach([LiquidGlassHue.amber, .cyan, .indigo, .graphite]) { hue in
                    AccentColorSection(selectedHue: hue, onSelect: { _ in })
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
    }
}
