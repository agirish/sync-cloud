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

/// One shipping call site that draws a non-default face, and a string it really renders.
///
/// A struct rather than a tuple because `@Test(arguments:)` only destructures pairs, and because
/// `digits` has to travel with the font: `ScaledFont` does not expose whether `monospacedDigit()`
/// was applied, and that is what decides which face a regression would fall back to.
struct FaceCallSite: Sendable, CustomStringConvertible {
    let site: String
    /// The font the call site builds, verbatim.
    let font: ScaledFont
    /// Whether that font asks for monospaced digits.
    let digits: Bool
    /// A string the site really renders — the strings below all come off `FilingSpendFormat` or
    /// out of a pane row.
    let text: String

    var description: String { "\(site) — \"\(text)\"" }

    /// The face `nsFont` returned before the design and the digit flag were composed: the digits
    /// font if one was asked for, the plain system font otherwise, with the design dropped either
    /// way. Rebuilt from the two things `ScaledFont` does publish, so this is the real fallback
    /// rather than a restatement of it.
    func faceWithTheDesignDropped(scale: CGFloat) -> NSFont {
        let size = font.pointSize(scale: scale)
        return digits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: font.symbolWeight)
            : NSFont.systemFont(ofSize: size, weight: font.symbolWeight)
    }
}

/// Every `.rounded` call site SyncCloud ships, and nothing else — grep `design: .rounded` under
/// `Modules/*/Sources` and these are the three hits.
///
/// The two spend panes are byte-identical `stat(_:_:)` helpers in different modules, and both
/// render all three strings; they take different ones here so a fixture that stopped
/// discriminating shows up in one case rather than in neither. "18.4k tok" is deliberately NOT
/// among them — measured, it is 72.745pt in the plain digits face against 72.210pt in the rounded
/// one, and at scale 1.15 the two round to the same 82.5pt. It would have passed in the wrong face.
let roundedCallSites = [
    FaceCallSite(site: "PaneRowFonts.name", font: .system(.body, design: .rounded),
                 digits: false, text: "Birth Certificate"),
    FaceCallSite(site: "SettingsView.stat (filing spend)",
                 font: .system(size: 16, weight: .semibold, design: .rounded).monospacedDigit(),
                 digits: true, text: "~$1.24"),
    FaceCallSite(site: "FilingSpendHistoryView.stat",
                 font: .system(size: 16, weight: .semibold, design: .rounded).monospacedDigit(),
                 digits: true, text: "1234"),
]

/// The raw, unrounded width of `text` in `font` — what the gap floors below are stated against,
/// because SwiftUI's ceiling to the next half point can swallow a real difference of up to 0.5pt.
func rawWidth(_ text: String, _ font: NSFont) -> CGFloat {
    NSAttributedString(string: text, attributes: [.font: font]).size().width
}

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

    // MARK: - The cache

    /// The caches are keyed by `NSFont`, and that only works if two separately-built `ScaledFont`s
    /// resolving to the same face produce fonts that are `==` and hash alike.
    ///
    /// Worth its own case because the failure is silent and is a PERFORMANCE failure, not a wrong
    /// answer: identity-keyed fonts would miss on every lookup, refill the cache until it hit its
    /// limit, flush, and repeat — turning a ~25µs-per-symbol measurement back into a per-layout-pass
    /// cost, which is the entire thing the computed ladder exists to remove.
    @Test func equalScaledFontsResolveToCacheableAppKitFonts() {
        for (a, b) in [(ScaledFont.system(size: 13), ScaledFont.system(size: 13)),
                       (.caption, .caption),
                       (.system(size: 12, weight: .semibold).monospacedDigit(),
                        .system(size: 12, weight: .semibold).monospacedDigit())] {
            for scale in appFontScales {
                let x = a.nsFont(scale: scale), y = b.nsFont(scale: scale)
                #expect(x == y, "\(x) != \(y) — the measurement caches would never hit")
                #expect(x.hashValue == y.hashValue, "equal fonts hash differently — same problem")
            }
        }
        // Fonts that should NOT collide, or a cached width would be served for the wrong face.
        #expect(ScaledFont.system(size: 13).nsFont(scale: 1)
                != ScaledFont.system(size: 13, weight: .bold).nsFont(scale: 1))
        #expect(ScaledFont.system(size: 12, weight: .semibold).nsFont(scale: 1)
                != ScaledFont.system(size: 12, weight: .semibold).monospacedDigit().nsFont(scale: 1))
        #expect(ScaledFont.system(size: 13).nsFont(scale: 1)
                != ScaledFont.system(size: 13).nsFont(scale: 1.3))
        // `.rounded` fell through to `systemFont` until 2026-08-17, so a rounded font resolved to
        // the default face and measured as it — silently, in the one file whose whole claim is that
        // its numbers agree with the drawn text. `PaneRowFonts.name` is rounded, so the first
        // ladder to measure a column row name would have been wrong; nothing measures one today,
        // which is why this never showed up as a layout bug. It showed up as a wrong number in a
        // release-notes draft instead.
        #expect(ScaledFont.system(.body, design: .rounded).nsFont(scale: 1)
                != ScaledFont.system(.body).nsFont(scale: 1),
                "a rounded font resolved to the default face — measurements would be off it")
    }

    /// The width half of the same defect, stated as a number so it cannot pass by the two fonts
    /// merely being unequal objects. "Birth Certificate" is the string the column-row work
    /// measured: 95.729pt in SF Pro against 92.917pt in SF Rounded, and the SF Pro figure is the
    /// one that reached a notes draft as the width of a row that draws the rounded face.
    @Test func aRoundedFontMeasuresNarrowerThanTheDefaultFace() {
        let rounded = ScaledFont.system(.body, design: .rounded).nsFont(scale: 1)
        let plain = ScaledFont.system(.body).nsFont(scale: 1)
        #expect(rounded.pointSize == plain.pointSize, "premise: same size, so only the face differs")

        func width(_ font: NSFont) -> CGFloat {
            NSAttributedString(string: "Birth Certificate", attributes: [.font: font]).size().width
        }
        let roundedWidth = width(rounded), plainWidth = width(plain)
        #expect(roundedWidth < plainWidth,
                "SF Rounded is the narrower face here: \(roundedWidth) vs \(plainWidth)")
        // A floor on the gap, so a fallback that quietly returns the default face fails rather than
        // passing on measurement noise. Measured 2.81pt; 1pt is comfortably below it and well above
        // any rounding the text system does.
        #expect(plainWidth - roundedWidth > 1,
                "the two faces measured within 1pt — the rounded design is probably not applied")
    }

    /// Every shipping rounded call site, measured against the view SwiftUI lays out for it.
    ///
    /// The case above covers `PaneRowFonts.name`, which is the one rounded site that does *not*
    /// ask for monospaced digits — and that is exactly why the fix it pins was incomplete.
    /// `Font.monospacedDigit()` preserves the design, so the two filing-spend totals, which are
    /// rounded *and* monospaced-digit, went out through `nsFont`'s digits path above the design
    /// switch and came back in the default face: "1234" at 16pt semibold measured 40.745pt where
    /// the drawn text is 42.042pt. Parameterised over the sites rather than over one font, so
    /// adding a fourth rounded call site is what makes this suite notice it.
    @Test(arguments: roundedCallSites)
    func everyRoundedCallSiteMeasuresTheFaceItDraws(site: FaceCallSite) {
        for scale in appFontScales {
            // The premise, asserted rather than assumed: a fixture whose string measures the same
            // in both faces would pass with the design dropped. One of the three candidate strings
            // does exactly that at one scale (see `roundedCallSites`), so this is not theoretical.
            let gap = abs(rawWidth(site.text, site.font.nsFont(scale: scale))
                          - rawWidth(site.text, site.faceWithTheDesignDropped(scale: scale)))
            #expect(gap > 1,
                    "\(site) at scale \(scale): the face drawn and the face with the design dropped measure within \(gap)pt — this fixture cannot fail")

            let computed = LabelMetrics.width(of: site.text, font: site.font, scale: scale)
            let drawn = hostedWidth(Text(site.text).font(site.font.resolved(scale: scale)))
            #expect(computed == drawn,
                    "\(site) at scale \(scale): computed \(computed)pt, drawn \(drawn)pt")
        }
    }

    /// The headline numbers, and the guarantee they could have cost.
    ///
    /// A rounded font that also wants monospaced digits needs *both*, and the obvious repairs each
    /// drop one: returning the digits font drops the face (40.745pt), and returning the rounded
    /// font drops the equal-width digits (38.487pt, and "1" is 7.873pt against "0" at 10.609pt —
    /// the 2pt-per-digit error `monospacedDigitSystemFont` exists to prevent). Composing them
    /// carries the descriptor's number-spacing feature across, which is the fact this pins.
    @Test func aRoundedDigitsFontKeepsBothTheFaceAndTheEqualWidthDigits() {
        let font = ScaledFont.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit()
        let measured = font.nsFont(scale: 1)
        #expect(measured.pointSize == 16, "premise: unscaled, so only the face is in question")

        // The face. 42.042 against the 40.745 the digits font alone reports.
        let digitsOnly = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        #expect(abs(rawWidth("1234", measured) - 42.042) < 0.05,
                "\"1234\" measured \(rawWidth("1234", measured))pt, expected the rounded face's 42.042")
        #expect(abs(rawWidth("1234", digitsOnly) - 40.745) < 0.05,
                "the pre-fix answer moved: \(rawWidth("1234", digitsOnly))pt, expected 40.745")
        #expect(rawWidth("1234", measured) - rawWidth("1234", digitsOnly) > 1,
                "the two measured within 1pt — the rounded design is probably not applied")

        // The digits. Stated as widths of real strings rather than as a trait lookup, because a
        // trait can be present on a descriptor the text system then ignores.
        #expect(rawWidth("1", measured) == rawWidth("0", measured),
                "\"1\" is \(rawWidth("1", measured))pt and \"0\" is \(rawWidth("0", measured))pt — the monospaced-digit feature was lost applying the design")
        #expect(rawWidth("1111", measured) == rawWidth("1234", measured))
        let roundedOnly = ScaledFont.system(size: 16, weight: .semibold, design: .rounded)
            .nsFont(scale: 1)
        #expect(rawWidth("1", measured) - rawWidth("1", roundedOnly) > 2,
                "the digits are no wider than the proportional face's — nothing was gained")

        // And both halves agree with the drawn text.
        for scale in appFontScales {
            #expect(LabelMetrics.width(of: "1234", font: font, scale: scale)
                    == hostedWidth(Text("1234").font(font.resolved(scale: scale))))
        }
    }

    /// `.monospaced` is the other half of the same interaction, and it goes the other way: the
    /// monospaced face is fixed-pitch throughout, so it answers a `monospacedDigit()` request on
    /// its own and must win outright. Returning the digits font instead gives the *proportional*
    /// face with equal-width digits — the wrong glyph for every letter, 72.745pt for "18.4k tok"
    /// at 16pt semibold where the monospaced face lays out 89.016pt.
    ///
    /// No shipping call site combines the two today; this pins the answer before one does, which
    /// is the whole lesson of the miss above it.
    @Test func theMonospacedFaceAnswersADigitRequestOnItsOwn() {
        let font = ScaledFont.system(size: 16, weight: .semibold).monospaced().monospacedDigit()
        let measured = font.nsFont(scale: 1)
        let digitsOnly = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        #expect(rawWidth("18.4k tok", measured) - rawWidth("18.4k tok", digitsOnly) > 1,
                "the proportional digits face measured within 1pt of the monospaced one (\(rawWidth("18.4k tok", measured)) vs \(rawWidth("18.4k tok", digitsOnly)))")
        // The digit guarantee still holds — it is the point of the face, not a thing it gave up.
        #expect(rawWidth("1", measured) == rawWidth("0", measured))
        #expect(rawWidth("W", measured) == rawWidth("1", measured),
                "the monospaced face is fixed-pitch across letters too")

        // And asking for them must not mint a *second* font for the same face. `LabelMetrics`
        // keys both caches on `NSFont`, so two objects that measure identically but compare
        // unequal are two entries, and one of them misses on every lookup. Measured: routing
        // `.monospaced` through the descriptor transform instead of `NSFont.monospacedSystemFont`
        // gives exactly that — a font that lays out the same and is `!=` both the canonical one
        // (at every weight but `.regular`) and its own no-digits sibling.
        #expect(measured == ScaledFont.system(size: 16, weight: .semibold).monospaced().nsFont(scale: 1),
                "the digit request built a different font object for the same face")
        #expect(measured == NSFont.monospacedSystemFont(ofSize: 16, weight: .semibold),
                "not the canonical monospaced font — a caller that built one would miss the cache")

        for scale in appFontScales {
            #expect(LabelMetrics.width(of: "18.4k tok", font: font, scale: scale)
                    == hostedWidth(Text("18.4k tok").font(font.resolved(scale: scale))))
        }
    }

    /// `.serif` was the third design falling through to the default face, and unlike `.rounded` it
    /// was never drawn — nothing in SyncCloud asks for it. It is handled anyway, because "latent"
    /// is what `.rounded` was until a number off it reached a release-notes draft, and because an
    /// explicit `default:` that silently swallows a design is the shape of both misses.
    ///
    /// Pinned as a width so it is a claim about the face rather than about the branch existing:
    /// "Birth Certificate" is 98.872pt in New York against 95.729pt in SF Pro at 13pt.
    @Test func aSerifFontMeasuresTheSerifFace() {
        for (font, plain, text) in [
            (ScaledFont.system(.body, design: .serif), ScaledFont.system(.body), "Birth Certificate"),
            (.system(size: 16, weight: .semibold, design: .serif).monospacedDigit(),
             .system(size: 16, weight: .semibold).monospacedDigit(), "1234"),
        ] {
            for scale in appFontScales {
                let serifWidth = rawWidth(text, font.nsFont(scale: scale))
                let plainWidth = rawWidth(text, plain.nsFont(scale: scale))
                #expect(abs(serifWidth - plainWidth) > 1,
                        "\"\(text)\" at scale \(scale): serif \(serifWidth)pt vs default \(plainWidth)pt — the serif design is probably not applied")
                #expect(LabelMetrics.width(of: text, font: font, scale: scale)
                        == hostedWidth(Text(text).font(font.resolved(scale: scale))),
                        "\"\(text)\" at scale \(scale) does not match the drawn run")
            }
        }
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
