import AppKit
import Design
import SwiftUI
import Testing
@testable import Settings

/// Guards that the Appearance tab's accent preview shows the pairing the app actually ships.
///
/// `LiquidGlassHue` has two accents: the raw `accentColor` looks livelier but strands a white
/// label below AA on Green and Amber, so every filled surface takes the deepened `accentFillColor`
/// (see `AccentFill`). A preview using the raw one would show a pairing the app can't render.
///
/// The fill is measured in painted pixels, not read back, so an `.opacity()`, a dimming or a fill
/// drawn on top is caught too. `AccentFill.deepened` is dynamic, so two calls aren't `==` anyway.
@MainActor
@Suite(.serialized, .machinePinned(.pixelSampling)) struct AccentPreviewTests {

    /// Every hue but `.none`, which resolves the machine's system accent, so its value isn't this
    /// code's. Its own case below checks what holds for any input.
    private static let fixedHues = LiquidGlassHue.allCases.filter { $0 != .none }

    /// The hues `AccentFill` actually deepens. On the others raw and deepened are the same colour,
    /// so only these can tell the two apart.
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
    /// **Re-tag, never convert.** The backing store is sRGB, but `colorAt` labels its samples
    /// calibrated RGB; `usingColorSpace(.sRGB)` would convert already-correct values and lighten
    /// them, enough to pass for the raw accent. Re-tagging keeps the samples and fixes the label.
    private func paint(_ rep: NSBitmapImageRep, _ point: CGPoint, in size: CGSize) -> NSColor? {
        let sx = CGFloat(rep.pixelsWide) / size.width
        let sy = CGFloat(rep.pixelsHigh) / size.height
        guard let px = rep.colorAt(x: Int(point.x * sx), y: Int(point.y * sy)) else { return nil }
        return NSColor(srgbRed: px.redComponent, green: px.greenComponent,
                       blue: px.blueComponent, alpha: px.alphaComponent)
    }

    /// The transfer button's fill, sampled 5pt inside its leading edge at mid-height: inside the
    /// capsule (which starts at the strip's 10pt padding) and clear of the label.
    private func buttonFill(_ hue: LiquidGlassHue, _ appearance: NSAppearance.Name) -> NSColor? {
        let (rep, size) = renderStrip(hue, appearance)
        return paint(rep, CGPoint(x: 15, y: size.height / 2), in: size)
    }

    /// The count pill's fill, sampled 5pt inside its trailing edge: the pill is last, ending at
    /// the strip's 10pt padding, and its own padding keeps the label out of the sample.
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

    /// Resolves a SwiftUI `Color` in a pinned appearance: `accentFillColor` is dynamic, so unasked
    /// it answers for whatever appearance is current.
    private func resolve(_ color: Color, _ appearance: NSAppearance.Name) -> NSColor {
        var out: NSColor?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB)
        }
        return out ?? NSColor(color)
    }

    /// Largest sRGB component difference between two colours, for "same paint" checks. Both sides
    /// are converted first because `NSColor.white` is gray-space, and asking it for `redComponent`
    /// throws. For the already-sRGB samples the conversion is a no-op.
    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return .infinity }
        return max(abs(x.redComponent - y.redComponent),
                   max(abs(x.greenComponent - y.greenComponent), abs(x.blueComponent - y.blueComponent)))
    }

    // MARK: The pairing

    /// The button and the pill both paint `accentFillColor`, the deepened accent. The 0.02
    /// tolerance absorbs 8-bit quantisation. Looped, not `@Test(arguments:)`, because
    /// `LiquidGlassHue` isn't `Sendable`; each expectation names its hue.
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

    /// …and not the raw accent, on the hues where the two differ; elsewhere an equality check
    /// passes either way.
    ///
    /// The count pill is the assertion that matters: `ActionBarButtonStyle` deepens its own
    /// `.primary` tint, so the button stays right even when fed `accentColor`, while
    /// `SemanticCapsuleStyle.onAccent` paints what it is handed. Feeding the strip `accentColor`
    /// must fail on the pill.
    @MainActor
    @Test func previewRejectsTheRawAccent() async throws {
        for hue in Self.deepenedHues {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let raw = resolve(hue.accentColor, appearance)
                let deepened = resolve(hue.accentFillColor, appearance)
                // The premise: on these hues the two are different paints, so the checks below can
                // fail. If `AccentFill` stops deepening one, this says so.
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

    /// What the deepening exists for, measured on painted pixels: the white label clears WCAG AA
    /// on both chips, every hue, both appearances.
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

    /// `onAccentLabelColor` is white for every hue: the other half of the pairing, which a change
    /// could move without touching a fill.
    @Test func theOnAccentLabelIsWhiteForEveryHue() {
        for hue in LiquidGlassHue.allCases {
            let label = NSColor(hue.onAccentLabelColor).usingColorSpace(.sRGB)!
            #expect(distance(label, .white) < 0.01, "\(hue.displayName) pairs with \(label), not white.")
        }
    }

    // MARK: The "None" hue

    /// `.none` defers to the system accent, so the strip must still paint a real button. The
    /// colour is the machine's, so this pins what holds for any input: opaque, distinct from the
    /// ground, and carrying white at AA.
    @MainActor
    @Test func noneStillPaintsALegibleButton() async throws {
        let white = NSColor.white.usingColorSpace(.sRGB)!
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let (rep, size) = renderStrip(.none, appearance)

            // First, the button is there: every hue lays the strip out the same, so `.none`'s must
            // measure like a fixed hue's. Without this, dropping the button lets the pill slide
            // under the sample point and every pixel check still passes.
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

    /// The caption names the value, then what it does, like the neighbouring sections. `.none`
    /// gets its own sentence: the generic one under a visibly coloured button reads as a bug.
    @Test func theCaptionNamesTheChoiceAndItsUses() {
        #expect(AccentColorSection.caption(for: .cyan)
                == "Cyan. Used for filled controls, selection, and the seam chrome.")
        #expect(AccentColorSection.caption(for: .graphite).hasPrefix("Graphite. "))

        let none = AccentColorSection.caption(for: .none)
        #expect(none.hasPrefix("None. "))
        // "macOS accent", not "macOS accent color": the caption has a one-line budget (see
        // `caption(for:)`) and must be free to drop a word this test doesn't care about.
        #expect(none.contains("macOS accent"),
                "None's caption must explain why a coloured button is still showing: \(none)")
        // Under `.none` selection follows the system accent: the pane wash paints
        // `glassHue.accentColor`, which is `Color.accentColor` there
        // (`FileTreeView.rowSelectionBackground`). Only the glass tint goes away.
        #expect(none.contains("selection"),
                "None's caption must say selection follows the macOS accent too: \(none)")
        #expect(!none.lowercased().contains("no wash") && !none.contains("get no"),
                "None's caption is claiming the panes lose their selection wash again: \(none)")
    }

    /// The spoken label takes the caption's `.none` branch too: "None accent on a filled button"
    /// contradicts itself, and a VoiceOver user can't see the strip to make sense of it.
    @Test func thePreviewLabelSpeaksTheSystemAccentForNone() {
        let none = AccentPreviewStrip.accessibilityLabel(for: .none)

        #expect(none != "Preview: None accent on a filled button and a count pill.",
                "the `.none` label is back to the self-contradicting generic form")
        #expect(!none.contains("None"), "spoken label still names 'None' as if it were a colour: \(none)")
        #expect(none.contains("macOS accent"),
                "the `.none` label must attribute the sample's colour to the system accent: \(none)")

        // The fixed hues keep the generic form, hue named.
        #expect(AccentPreviewStrip.accessibilityLabel(for: .cyan)
                == "Preview: Cyan accent on a filled button and a count pill.")
    }

    // The accent section's image snapshot is in `SettingsSnapshotTests`, marked
    // `.machinePinned(.referenceImages)` so CI excludes it.
    //
    // The pixel checks above read a live renderer, so another renderer can fail them for machine
    // reasons. They are `.machinePinned(.pixelSampling)` and still run on CI, which is sound only
    // while the runner is the recording machine; they are coarse enough to survive small
    // renderer differences, where a drifted PNG fails at once.
}
