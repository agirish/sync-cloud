import AppKit
import SwiftUI
import Testing
import Design
@testable import FileExplorer

/// **A link in Markdown Preview reads as text, in the window's hue (FE2).**
///
/// Both Previews drew links in the RAW accent: 3.7:1 on white at Blue, 2.7:1 at Green and Coral,
/// 2.2:1 at Amber, against the 4.5:1 body text needs. They now take `ChromeInk.bodyText` — deepened
/// in light, lifted in dark — read-only through `MarkdownBlockView.linkInk`, editable through
/// `PreviewEditorView.linkInk`.
///
/// **The ground.** Preview draws no background of its own (`PreviewEditorView` turns
/// `drawsBackground` off; `MarkdownPreview` paints none), so its ground is the pane's. The ground
/// that can be resolved off screen is the pane at Solid and Tint 0 — `controlBackgroundColor`, white
/// in light and 0.118 in dark — and the app's sheets either side of it (0.96 light, 0.13 dark), the
/// grounds `SemanticInkContrastTests` holds the same ink to. Glass panes and a raised Tint put the
/// hue's own wash under the text, which nothing off screen can render (`.glassEffect` draws
/// nothing there), so those are not measured here.
@MainActor
@Suite struct MarkdownLinkInkTests {

    static let textFloor: CGFloat = 4.5

    /// Light grounds, then dark: the Solid pane resolved from AppKit, and the sheets.
    static func grounds(dark: Bool) -> [(String, NSColor)] {
        let pane = resolved(Color(nsColor: .controlBackgroundColor), dark: dark)
        return dark
            ? [("the dark pane", pane), ("the dark sheet", NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1))]
            : [("the light pane", pane), ("the light sheet", NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1))]
    }

    /// `color` as drawn in one appearance, in sRGB components.
    static func resolved(_ color: Color, dark: Bool) -> NSColor {
        var out = NSColor.white
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB) ?? .white
        }
        return out
    }

    static func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        func lum(_ c: NSColor) -> CGFloat {
            AccentLabel.relativeLuminance(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
        }
        let (x, y) = (lum(a) + 0.05, lum(b) + 0.05)
        return max(x, y) / min(x, y)
    }

    static func same(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) < 0.002 && abs(a.greenComponent - b.greenComponent) < 0.002
            && abs(a.blueComponent - b.blueComponent) < 0.002
    }

    /// **The fixture reproduces the defect**: the raw accent misses the floor on the light pane for
    /// the hues the review measured, so the test below cannot pass with the raw accent drawn.
    @Test func theRawAccentMissesTheFloor() throws {
        let pane = try #require(Self.grounds(dark: false).first?.1)
        for hue in [LiquidGlassHue.green, .coral, .amber, .blue] {
            let raw = Self.ratio(Self.resolved(hue.accentColor, dark: false), pane)
            #expect(raw < Self.textFloor, "raw \(hue.displayName) is \(raw):1 on the light pane — the defect is gone")
        }
    }

    /// **Every hue, both appearances, both Previews, at 4.5:1 or better** — and the two Previews
    /// draw one colour, so turning Edit in Preview on or off does not change a link.
    @Test func everyHueReadsAsTextInBothPreviewsAndBothAppearances() {
        for hue in LiquidGlassHue.allCases {
            for dark in [false, true] {
                let readOnly = Self.resolved(MarkdownBlockView.linkInk(dark ? .dark : .light, accent: hue.accentColor),
                                             dark: dark)
                let editable = Self.resolved(Color(nsColor: PreviewEditorView.linkInk(hue.accentColor)), dark: dark)
                let side = dark ? "dark" : "light"
                #expect(Self.same(readOnly, editable),
                        "\(hue.displayName) \(side): read-only draws \(readOnly), editable \(editable)")
                for (name, ground) in Self.grounds(dark: dark) {
                    let r = Self.ratio(readOnly, ground)
                    #expect(r >= Self.textFloor, "\(hue.displayName) link on \(name) is \(r):1")
                }
            }
        }
    }

    /// The editable ink picks its shade where it is DRAWN: one `NSColor`, deepened in light and
    /// lifted in dark — not whichever appearance was current when the page was built.
    @Test func theEditableInkFollowsTheAppearanceItIsDrawnIn() {
        let hue = LiquidGlassHue.indigo.accentColor
        let ink = Color(nsColor: PreviewEditorView.linkInk(hue))
        let light = Self.resolved(ink, dark: false), dark = Self.resolved(ink, dark: true)
        // Indigo is deepened a touch for light and lifted for dark, so the two shades differ.
        #expect(!Self.same(light, dark), "one shade in both appearances: \(light)")
        #expect(Self.same(light, Self.resolved(ChromeInk.bodyText(.light, hue), dark: false)),
                "the light shade is \(light)")
        #expect(Self.same(dark, Self.resolved(ChromeInk.bodyText(.dark, hue), dark: true)),
                "the dark shade is \(dark)")
    }

    /// **The call site: a link run is painted in that ink**, not the accent it was handed.
    @Test func aLinkRunIsPaintedInTheReadableShade() throws {
        let run = MarkdownRun(text: "the plan", link: "https://example.com/plan")
        for dark in [false, true] {
            let piece = MarkdownBlockView.attributed(run, accent: LiquidGlassHue.coral.accentColor,
                                                     scheme: dark ? .dark : .light, fontScale: 1)
            let color = try #require(piece.runs.first?.foregroundColor, "the link run has no colour")
            let drawn = Self.resolved(color, dark: dark)
            let expected = Self.resolved(ChromeInk.bodyText(dark ? .dark : .light, LiquidGlassHue.coral.accentColor),
                                         dark: dark)
            #expect(Self.same(drawn, expected), "the link is \(drawn), not the readable coral \(expected)")
        }
        // Light is where coral has to move, so a link left in the raw accent fails here.
        let light = MarkdownBlockView.attributed(run, accent: LiquidGlassHue.coral.accentColor,
                                                 scheme: .light, fontScale: 1)
        let drawn = Self.resolved(try #require(light.runs.first?.foregroundColor), dark: false)
        #expect(!Self.same(drawn, Self.resolved(LiquidGlassHue.coral.accentColor, dark: false)),
                "the link is still the raw accent")
    }
}
