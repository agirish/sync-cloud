import AppKit
import SwiftUI
import Testing
@testable import Design

/// Every symbol the differences header draws. Outside the suite because `@Test(arguments:)`
/// evaluates its fixtures where the test is *registered*, which is not the main actor.
private let headerSymbols = [
    "checkmark.shield", "checklist", "ellipsis", "chevron.down", "chevron.up",
    "line.3.horizontal.decrease.circle", "xmark.circle.fill", "magnifyingglass",
    "arrow.right", "arrow.left", "exclamationmark.triangle",
    "rectangle.compress.vertical", "arrow.down.left.and.arrow.up.right",
]

/// Strings the header really renders: counts with and without separators, provider names of
/// several lengths, and the whole transfer-button sentence.
private let headerTexts = [
    "1", "17", "576", "1,284", "Differences", "Verify 12", "Review 1,284",
    "Copy 17 to Dropbox", "Move 1,284 to OneDrive — Personal", "iCloud Drive",
    "29m ago", "scanning…", "12 selected", "Everything", "Only on iCloud Drive",
]

/// The four app font scales. The ladder has to be right at every one of them.
private let appFontScales: [CGFloat] = FontSize.allCases.map(\.scale)

/// Checks every number `LabelMetrics` computes against the view SwiftUI actually draws.
///
/// This suite is the whole warrant for the differences header's computed ladder. The header no
/// longer discovers its rung by building six toolbars and measuring them; it adds up the widths this
/// type reports. That trade is only safe while "the width this reports" and "the width SwiftUI lays
/// out" are the same number, so nothing here compares a constant against another constant — every
/// expectation reads `NSHostingView.fittingSize` off a real hosted view.
///
/// **The hosting view needs a window.** Measured while calibrating this: a detached `NSHostingView`
/// reports 19.0pt for a `checklist` symbol that measures 17.5pt inside a window, and it is wrong in
/// both directions across the symbol set (`magnifyingglass` goes the other way). A suite that
/// skipped the window would fail against numbers that are correct.
/// `.machinePinned(.pixelSampling)`: every expectation reads a laid-out width out of a live
/// renderer, and two cases additionally pin the exact figures this Mac's font and symbol metrics
/// produce (17.5pt for `checklist`, 77.0pt for "Review 1234").
@MainActor
@Suite(.machinePinned(.pixelSampling)) struct LabelMetricsTests {

    private func hostedWidth<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 4000, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    // MARK: - Text

    @Test(arguments: headerTexts) func textWidthMatchesTheDrawnRun(text: String) {
        for scale in appFontScales {
            for font in [ScaledFont.system(size: 13), .system(size: 11), .caption] {
                let computed = LabelMetrics.width(of: text, font: font, scale: scale)
                let drawn = hostedWidth(Text(text).font(font.resolved(scale: scale)))
                #expect(computed == drawn,
                        "\"\(text)\" at scale \(scale): computed \(computed)pt, drawn \(drawn)pt")
            }
        }
    }

    /// The digits path is measured in the monospaced-digit face, which is a materially different
    /// width — "1" is 5.93pt proportional against 7.87pt monospaced.
    @Test(arguments: ["1", "17", "576", "1,284", "88,888"])
    func monospacedDigitWidthMatchesTheDrawnRun(text: String) {
        for scale in appFontScales {
            let font = ScaledFont.system(size: 12, weight: .semibold).monospacedDigit()
            let computed = LabelMetrics.width(of: text, font: font, scale: scale)
            let drawn = hostedWidth(Text(text).font(font.resolved(scale: scale)))
            #expect(computed == drawn,
                    "\"\(text)\" at scale \(scale): computed \(computed)pt, drawn \(drawn)pt")
        }
    }

    /// The rounding rule itself, stated as a fact about SwiftUI rather than inferred from the
    /// assertions above: a run is rounded UP to the next half point, not to the nearest one. Both
    /// rules agree on most strings, which is exactly why this needs its own case — "Review 1,284"
    /// is where they part company.
    @Test func textRoundsUpToTheNextHalfPointNotToTheNearest() {
        let font = ScaledFont.system(size: 13)
        let raw = NSAttributedString(string: "Review 1234",
                                     attributes: [.font: font.nsFont(scale: 1)]).size().width
        #expect(raw > 76.5 && raw < 77,
                "fixture no longer straddles a half point (\(raw)pt) — pick another string")
        #expect(LabelMetrics.width(of: "Review 1234", font: font, scale: 1) == 77)
        #expect((raw * 2).rounded() / 2 == 76.5, "nearest-half would give 76.5 — the wrong answer")
    }

    // MARK: - Symbols

    @Test(arguments: headerSymbols) func symbolWidthMatchesTheDrawnGlyph(name: String) {
        for scale in appFontScales {
            for font in [ScaledFont.system(size: 13),
                         .system(size: 12, weight: .semibold),
                         .system(size: 9, weight: .semibold),
                         .system(size: 11, weight: .bold)] {
                let computed = LabelMetrics.symbolWidth(name, font: font, scale: scale)
                let drawn = hostedWidth(Image(systemName: name).font(font.resolved(scale: scale)))
                let pt = font.nsFont(scale: scale).pointSize
                #expect(computed == drawn,
                        "\(name) in \(pt)pt at scale \(scale): computed \(computed)pt, drawn \(drawn)pt")
            }
        }
    }

    /// The measurement source, pinned as its own claim: an image's `size` is the *ceiling* of what
    /// SwiftUI lays out, and its `alignmentRect` is the thing itself. Written down because `size` is
    /// the obvious property to reach for and is right often enough to look correct.
    @Test func imageSizeIsNotTheLaidOutWidthButTheAlignmentRectIs() {
        let image = try! #require(NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
            .flatMap { $0.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) })
        let drawn = hostedWidth(Image(systemName: "checklist").font(.system(size: 13)))
        #expect(image.size.width == 18, "fixture stopped straddling — pick another symbol")
        #expect(drawn == 17.5)
        #expect(image.alignmentRect.width == drawn)
    }

    // MARK: - Composites

    @Test(arguments: [("Verify 12", "checkmark.shield"), ("Review 1,284", "checklist"),
                      ("Copy 17 to Dropbox", "arrow.right"), ("Exit Review", "xmark.circle.fill")])
    func labelWidthMatchesTheDrawnLabel(title: String, symbol: String) {
        for scale in appFontScales {
            let font = ScaledFont.system(size: 13)
            let computed = LabelMetrics.labelWidth(title, systemImage: symbol, font: font, scale: scale)
            let drawn = hostedWidth(Label(title, systemImage: symbol).font(font.resolved(scale: scale)))
            #expect(computed == drawn,
                    "\(title)/\(symbol) at scale \(scale): computed \(computed)pt, drawn \(drawn)pt")
        }
    }

    /// The 8pt gap is a gap, not an icon slot: it stays 8pt across icons 14pt and 17.5pt wide, which
    /// is what makes `labelWidth` a sum rather than a table.
    @Test func theLabelGapIsConstantAcrossIconWidths() {
        let font = ScaledFont.system(size: 13)
        for symbol in ["checkmark.shield", "checklist", "arrow.right"] {
            let label = hostedWidth(Label("Verify 12", systemImage: symbol).font(font.resolved(scale: 1)))
            let title = hostedWidth(Text("Verify 12").font(font.resolved(scale: 1)))
            let icon = hostedWidth(Image(systemName: symbol).font(font.resolved(scale: 1)))
            #expect(label - title - icon == LabelMetrics.labelIconSpacing,
                    "\(symbol) implies a \(label - title - icon)pt gap")
        }
    }

    /// `.actionBar`'s own footprint: `ActionBarMetrics.horizontalPadding` either side of the label,
    /// and a circle for the icon-only form.
    @Test func actionBarFootprintMatchesTheDrawnButton() {
        let font = ScaledFont.system(size: 13)
        let labelW = LabelMetrics.labelWidth("Verify 12", systemImage: "checkmark.shield",
                                             font: font, scale: 1)
        let drawn = hostedWidth(
            Button {} label: { Label("Verify 12", systemImage: "checkmark.shield") }
                .buttonStyle(.actionBar(.outline, tint: .blue, onTint: .white)))
        #expect(LabelMetrics.actionBarWidth(labelWidth: labelW) == drawn)

        let iconDrawn = hostedWidth(
            Button {} label: { Image(systemName: "ellipsis") }
                .buttonStyle(.actionBar(.outline, tint: .blue, onTint: .white, iconOnly: true)))
        #expect(LabelMetrics.actionBarIconOnlyWidth == iconDrawn)
    }

    // MARK: - The layout facts the ladder's arithmetic assumes

    /// An `HStack` charges no spacing for a child that resolves to nothing. The header's rows are
    /// full of `@ViewBuilder` `if`s — the verify button, the selection chip, the overflow — so a row
    /// that paid a 10pt gap per absent control would be 40pt wider than this arithmetic says.
    @Test func anAbsentChildCostsNoSpacing() {
        @ViewBuilder func maybe(_ show: Bool) -> some View {
            if show { Color.clear.frame(width: 50, height: 10) }
        }
        let two = hostedWidth(HStack(spacing: 10) {
            Color.clear.frame(width: 50, height: 10)
            Color.clear.frame(width: 50, height: 10)
        })
        let withGap = hostedWidth(HStack(spacing: 10) {
            Color.clear.frame(width: 50, height: 10)
            maybe(false)
            Color.clear.frame(width: 50, height: 10)
        })
        #expect(two == 110)
        #expect(withGap == two)
    }

    /// A `Spacer(minLength:)` contributes exactly its minimum to a row's ideal width, and takes a
    /// gap on each side. `ActionBarLadderTests` pins the consequence — that a row containing one
    /// still sheds; this pins the arithmetic the ladder does with it.
    @Test func aSpacerContributesItsMinimumToTheIdealWidth() {
        let measured = hostedWidth(HStack(spacing: 10) {
            Color.clear.frame(width: 50, height: 10)
            Spacer(minLength: 16)
            Color.clear.frame(width: 50, height: 10)
        })
        // Annotated, not inferred: an unannotated `50 + 10 + 16 + 10 + 50` types as `Int`, and the
        // heterogeneous comparison `#expect` then picks reports 136.0 != 136.
        let expected: CGFloat = 50 + 10 + 16 + 10 + 50
        #expect(measured == expected)
    }
}
