import AppKit
import SwiftUI
import Testing
@testable import Design

/// Every symbol the differences header draws. Outside the suite because `@Test(arguments:)`
/// evaluates its fixtures where the test is registered, which is not the main actor.
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

/// Every scale the size slider can land on, not just the four named presets in `appFontScales`.
///
/// The height cases need the whole set: the line box steps with the point size, and the 10pt
/// pane-bar title lands on 9.5 and 10.5pt at 95% and 105%, sizes where `defaultLineHeight` is
/// short and neither a named preset. Derived from `selectablePercents`, so widening the slider
/// widens this.
private let everySelectableScale: [CGFloat] =
    FontSize.selectablePercents.map { FontSize(percent: $0).scale }

/// The faces whose line box is worth pinning: the pane bar's title font, then one of each kind the
/// app draws (a body size, a caption, a heavier face) and the two the `nsFont` design and digits
/// paths compose, since a face that fell back would silently report the wrong box.
private let lineHeightFonts: [ScaledFont] = [
    .system(size: 10, weight: .regular),
    .system(size: 13),
    .caption,
    .system(size: 12, weight: .semibold),
    .system(size: 11, weight: .bold),
    .system(.body, design: .rounded),
    .system(size: 16, weight: .semibold, design: .rounded).monospacedDigit(),
]

/// One shipping call site that draws a non-default face, and a string it really renders.
///
/// A struct rather than a tuple because `@Test(arguments:)` only destructures pairs, and `digits`
/// must travel with the font: `ScaledFont` doesn't expose whether `monospacedDigit()` was applied,
/// which decides the face a regression would fall back to.
struct FaceCallSite: Sendable, CustomStringConvertible {
    let site: String
    /// The font the call site builds, verbatim.
    let font: ScaledFont
    /// Whether that font asks for monospaced digits.
    let digits: Bool
    /// A string the site really renders, from `FilingSpendFormat` or a pane row.
    let text: String

    var description: String { "\(site) — \"\(text)\"" }

    /// The face `nsFont` would return with the design dropped: the digits font if one was asked
    /// for, the plain system font otherwise. Rebuilt from what `ScaledFont` publishes, so it is the
    /// real fallback, not a restatement of it.
    func faceWithTheDesignDropped(scale: CGFloat) -> NSFont {
        let size = font.pointSize(scale: scale)
        return digits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: font.symbolWeight)
            : NSFont.systemFont(ofSize: size, weight: font.symbolWeight)
    }
}

/// Every `.rounded` call site SyncCloud ships: the hits for `design: .rounded` under
/// `Modules/*/Sources`.
///
/// The two spend panes use identical `stat(_:_:)` helpers in different modules and render the
/// same strings; they take different ones here so a fixture that stops discriminating shows up in
/// one case. "18.4k tok" is left out: 72.745pt in the plain digits face against 72.210pt rounded,
/// and at scale 1.15 both round to 82.5pt, so it would pass in the wrong face.
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

/// The raw, unrounded width of `text` in `font`, which the gap floors below use because SwiftUI's
/// ceiling to the next half point can swallow a real difference of up to 0.5pt.
func rawWidth(_ text: String, _ font: NSFont) -> CGFloat {
    NSAttributedString(string: text, attributes: [.font: font]).size().width
}

/// Checks every number `LabelMetrics` computes against the view SwiftUI actually draws.
///
/// The differences header picks its rung by adding up the widths `LabelMetrics` reports, which is
/// only safe while those equal what SwiftUI lays out. So nothing here compares constants: every
/// expectation reads `NSHostingView.fittingSize` off a real hosted view.
///
/// The hosting view needs a window: detached, it reports 19.0pt for a `checklist` symbol that is
/// 17.5pt in a window, and errs both ways across the symbol set. Pinned to `.pixelSampling` per
/// test: every case that hosts a view reads a live renderer, and two pin this Mac's exact figures
/// (17.5pt for `checklist`, 77.0pt for "Review 1234").
@MainActor
@Suite struct LabelMetricsTests {

    private func hostedSize<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 4000, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func hostedWidth<V: View>(_ view: V) -> CGFloat { hostedSize(view).width }
    private func hostedHeight<V: View>(_ view: V) -> CGFloat { hostedSize(view).height }

    // MARK: - Text

    @Test(.machinePinned(.pixelSampling), arguments: headerTexts) func textWidthMatchesTheDrawnRun(text: String) {
        for scale in appFontScales {
            for font in [ScaledFont.system(size: 13), .system(size: 11), .caption] {
                let computed = LabelMetrics.width(of: text, font: font, scale: scale)
                let drawn = hostedWidth(Text(text).font(font.resolved(scale: scale)))
                #expect(computed == drawn,
                        "\"\(text)\" at scale \(scale): computed \(computed)pt, drawn \(drawn)pt")
            }
        }
    }

    /// The digits path is measured in the monospaced-digit face, a materially different width: "1"
    /// is 5.93pt proportional against 7.87pt monospaced.
    @Test(.machinePinned(.pixelSampling), arguments: ["1", "17", "576", "1,284", "88,888"])
    func monospacedDigitWidthMatchesTheDrawnRun(text: String) {
        for scale in appFontScales {
            let font = ScaledFont.system(size: 12, weight: .semibold).monospacedDigit()
            let computed = LabelMetrics.width(of: text, font: font, scale: scale)
            let drawn = hostedWidth(Text(text).font(font.resolved(scale: scale)))
            #expect(computed == drawn,
                    "\"\(text)\" at scale \(scale): computed \(computed)pt, drawn \(drawn)pt")
        }
    }

    /// The rounding rule itself, as a fact about SwiftUI: a run is rounded up to the next half
    /// point, not to the nearest. The two rules agree on most strings, so this needs a string where
    /// they part company.
    @Test(.machinePinned(.pixelSampling)) func textRoundsUpToTheNextHalfPointNotToTheNearest() {
        let font = ScaledFont.system(size: 13)
        let raw = NSAttributedString(string: "Review 1234",
                                     attributes: [.font: font.nsFont(scale: 1)]).size().width
        #expect(raw > 76.5 && raw < 77,
                "fixture no longer straddles a half point (\(raw)pt) — pick another string")
        #expect(LabelMetrics.width(of: "Review 1234", font: font, scale: 1) == 77)
        #expect((raw * 2).rounded() / 2 == 76.5, "nearest-half would give 76.5 — the wrong answer")
    }

    // MARK: - Symbols

    @Test(.machinePinned(.pixelSampling), arguments: headerSymbols) func symbolWidthMatchesTheDrawnGlyph(name: String) {
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

    /// The measurement source: an image's `size` is the ceiling of what SwiftUI lays out, and its
    /// `alignmentRect` is the thing itself. `size` is the obvious property and is right often enough
    /// to look correct.
    @Test(.machinePinned(.pixelSampling)) func imageSizeIsNotTheLaidOutWidthButTheAlignmentRectIs() {
        let image = try! #require(NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
            .flatMap { $0.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) })
        let drawn = hostedWidth(Image(systemName: "checklist").font(.system(size: 13)))
        #expect(image.size.width == 18, "fixture stopped straddling — pick another symbol")
        #expect(drawn == 17.5)
        #expect(image.alignmentRect.width == drawn)
    }

    // MARK: - Height

    /// `lineHeight` against a real hosted `Text`, at every scale the slider reaches, in the faces
    /// the app draws. The fixture varies the font, not the string, because a line box is the same
    /// height whatever is in it; `aLineBoxDoesNotDependOnWhatIsInIt` asserts that.
    @Test(.machinePinned(.pixelSampling), arguments: lineHeightFonts) func lineHeightMatchesTheDrawnLineBox(font: ScaledFont) {
        for scale in everySelectableScale {
            let computed = LabelMetrics.lineHeight(font: font, scale: scale)
            let drawn = hostedHeight(Text("Hg").font(font.resolved(scale: scale)))
            #expect(computed == drawn,
                    "\(font.pointSize(scale: scale))pt at scale \(scale): computed \(computed)pt, drawn \(drawn)pt")
        }
    }

    /// The height half of `imageSizeIsNotTheLaidOutWidthButTheAlignmentRectIs`: the obvious API is
    /// right often enough to look correct.
    ///
    /// `NSLayoutManager.defaultLineHeight(for:)` agrees with the drawn box at most sizes and is 1pt
    /// short at the rest, including 10pt and 11pt, the pane bar's title at 100% and 110%. Short means
    /// a row reserved off it is a box its own text hangs out of, with no loud symptom.
    ///
    /// Two checks per size: that the two APIs really part company here (a size where they agree
    /// can't fail), and that the one `LabelMetrics` calls matches the drawn view.
    @Test(.machinePinned(.pixelSampling)) func defaultLineHeightIsNotTheDrawnLineBoxButTheAttributedSizeIs() {
        let layoutManager = NSLayoutManager()
        for pointSize in [CGFloat(9.5), 10, 10.5, 11, 11.5] {
            let font = NSFont.systemFont(ofSize: pointSize)
            let drawn = hostedHeight(Text("Hg").font(.system(size: pointSize)))
            let stated = layoutManager.defaultLineHeight(for: font)
            #expect(stated == drawn - 1,
                    "\(pointSize)pt: defaultLineHeight is \(stated)pt against a drawn \(drawn)pt — the fixture no longer straddles, so this case cannot fail")
            #expect(NSAttributedString(string: "Hg", attributes: [.font: font]).size().height == drawn)
        }
        // And a size where the two agree: "sometimes short", not "always short", which is what
        // makes the wrong API look correct.
        #expect(layoutManager.defaultLineHeight(for: NSFont.systemFont(ofSize: 12))
                == hostedHeight(Text("Hg").font(.system(size: 12))))
    }

    /// A line box is a property of the font, not the run, which lets `lineHeight` take no string and
    /// cache one entry per font.
    ///
    /// **The empty string is the exception, and must never be the sample**: with no characters it
    /// carries no font run, so `size()` ignores the font and answers for a default face.
    ///
    /// Stated as "the empty string ignores the font", not "it differs from the box", because the
    /// default measures 14.0: 1pt out at 10pt and 13pt but exactly right at 11pt, where the obvious
    /// assertion would pass on a number that means nothing.
    @Test(.machinePinned(.pixelSampling)) func aLineBoxDoesNotDependOnWhatIsInIt() {
        let pointSizes: [CGFloat] = [10, 11, 13]
        func height(_ text: String, _ pointSize: CGFloat) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: pointSize)])
                .size().height
        }
        for pointSize in pointSizes {
            let box = height("Hg", pointSize)
            for text in ["Hg", "x", "Scan", "New Folder", "Ág", "日本語", "—"] {
                #expect(height(text, pointSize) == box,
                        "\"\(text)\" at \(pointSize)pt is \(height(text, pointSize))pt, not \(box)pt")
            }
        }
        // The boxes really move with the font; without this the claim below is vacuous.
        #expect(Set(pointSizes.map { height("Hg", $0) }).count == pointSizes.count,
                "the three sizes share a line box, so an empty string that ignored the font could not be told apart from one that did not")
        #expect(Set(pointSizes.map { height("", $0) }).count == 1,
                "the empty string now tracks the font — the guard `lineHeightSample` exists for is no longer pinned by anything")
        #expect(height("", 10) != height("Hg", 10),
                "and at 10pt it lands on the real box too, so nothing here discriminates any more")
    }

    // MARK: - Composites

    @Test(.machinePinned(.pixelSampling),
          arguments: [("Verify 12", "checkmark.shield"), ("Review 1,284", "checklist"),
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

    /// The 8pt gap is a gap, not an icon slot: it stays 8pt across icons 14pt and 17.5pt wide, so
    /// `labelWidth` is a sum rather than a table.
    @Test(.machinePinned(.pixelSampling)) func theLabelGapIsConstantAcrossIconWidths() {
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
    @Test(.machinePinned(.pixelSampling)) func actionBarFootprintMatchesTheDrawnButton() {
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
    /// The failure is silent and costs performance, not correctness: fonts that compared by
    /// identity would miss on every lookup, refill the cache to its limit, flush and repeat, putting
    /// a ~25µs-per-symbol measurement back on every layout pass.
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
        // A rounded font must not resolve to the default face, or it measures as that face with
        // no visible symptom. `PaneRowFonts.name` is rounded, so any ladder measuring a column row
        // name would come out wrong.
        #expect(ScaledFont.system(.body, design: .rounded).nsFont(scale: 1)
                != ScaledFont.system(.body).nsFont(scale: 1),
                "a rounded font resolved to the default face — measurements would be off it")
    }

    /// The width half of the same check, stated as a number so it can't pass by the two fonts
    /// merely being unequal objects. "Birth Certificate" is 95.729pt in SF Pro against 92.917pt in
    /// SF Rounded.
    @Test(.machinePinned(.pixelSampling)) func aRoundedFontMeasuresNarrowerThanTheDefaultFace() {
        let rounded = ScaledFont.system(.body, design: .rounded).nsFont(scale: 1)
        let plain = ScaledFont.system(.body).nsFont(scale: 1)
        #expect(rounded.pointSize == plain.pointSize, "premise: same size, so only the face differs")

        func width(_ font: NSFont) -> CGFloat {
            NSAttributedString(string: "Birth Certificate", attributes: [.font: font]).size().width
        }
        let roundedWidth = width(rounded), plainWidth = width(plain)
        #expect(roundedWidth < plainWidth,
                "SF Rounded is the narrower face here: \(roundedWidth) vs \(plainWidth)")
        // A floor on the gap, so a fallback to the default face fails instead of passing on noise.
        // Measured 2.81pt; 1pt is well below it and well above any rounding the text system does.
        #expect(plainWidth - roundedWidth > 1,
                "the two faces measured within 1pt — the rounded design is probably not applied")
    }

    /// Every shipping rounded call site, measured against the view SwiftUI lays out for it.
    ///
    /// The case above covers `PaneRowFonts.name`, the one rounded site without monospaced digits.
    /// `Font.monospacedDigit()` preserves the design, so the rounded, monospaced-digit filing-spend
    /// totals must too: if `nsFont`'s digits path dropped the design, "1234" at 16pt semibold would
    /// measure 40.745pt against a drawn 42.042pt. Parameterised over the sites, so a new rounded
    /// call site is added here.
    @Test(.machinePinned(.pixelSampling), arguments: roundedCallSites)
    func everyRoundedCallSiteMeasuresTheFaceItDraws(site: FaceCallSite) {
        for scale in appFontScales {
            // The premise, asserted: a string that measures the same in both faces would pass with
            // the design dropped, as "18.4k tok" does at one scale (see `roundedCallSites`).
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

    /// A rounded font that also wants monospaced digits needs both, and the obvious shortcuts each
    /// drop one: the digits font alone drops the face (40.745pt), and the rounded font alone drops
    /// the equal-width digits (38.487pt; "1" is 7.873pt against "0" at 10.609pt). Composing them
    /// carries the descriptor's number-spacing feature across, which is what this pins.
    @Test(.machinePinned(.pixelSampling)) func aRoundedDigitsFontKeepsBothTheFaceAndTheEqualWidthDigits() {
        let font = ScaledFont.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit()
        let measured = font.nsFont(scale: 1)
        #expect(measured.pointSize == 16, "premise: unscaled, so only the face is in question")

        // The face: 42.042 against the 40.745 the digits font alone reports.
        let digitsOnly = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        #expect(abs(rawWidth("1234", measured) - 42.042) < 0.05,
                "\"1234\" measured \(rawWidth("1234", measured))pt, expected the rounded face's 42.042")
        #expect(abs(rawWidth("1234", digitsOnly) - 40.745) < 0.05,
                "the pre-fix answer moved: \(rawWidth("1234", digitsOnly))pt, expected 40.745")
        #expect(rawWidth("1234", measured) - rawWidth("1234", digitsOnly) > 1,
                "the two measured within 1pt — the rounded design is probably not applied")

        // The digits, as widths of real strings rather than a trait lookup, because a trait can be
        // present on a descriptor the text system then ignores.
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

    /// `.monospaced` goes the other way: the monospaced face is fixed-pitch throughout, so it
    /// answers a `monospacedDigit()` request on its own and must win outright. The digits font
    /// instead gives the proportional face, wrong for every letter: 72.745pt for "18.4k tok" at
    /// 16pt semibold where the monospaced face lays out 89.016pt.
    ///
    /// No shipping call site combines the two; this pins the answer before one does.
    @Test(.machinePinned(.pixelSampling)) func theMonospacedFaceAnswersADigitRequestOnItsOwn() {
        let font = ScaledFont.system(size: 16, weight: .semibold).monospaced().monospacedDigit()
        let measured = font.nsFont(scale: 1)
        let digitsOnly = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        #expect(rawWidth("18.4k tok", measured) - rawWidth("18.4k tok", digitsOnly) > 1,
                "the proportional digits face measured within 1pt of the monospaced one (\(rawWidth("18.4k tok", measured)) vs \(rawWidth("18.4k tok", digitsOnly)))")
        // The digit guarantee still holds: it is the point of the face, not something it gave up.
        #expect(rawWidth("1", measured) == rawWidth("0", measured))
        #expect(rawWidth("W", measured) == rawWidth("1", measured),
                "the monospaced face is fixed-pitch across letters too")

        // And asking for digits must not mint a second font for the same face. `LabelMetrics`
        // keys both caches on `NSFont`, so two objects that measure alike but compare unequal are
        // two entries, one missing on every lookup. Routing `.monospaced` through the descriptor
        // transform instead of `NSFont.monospacedSystemFont` gives exactly that (at every weight
        // but `.regular`).
        #expect(measured == ScaledFont.system(size: 16, weight: .semibold).monospaced().nsFont(scale: 1),
                "the digit request built a different font object for the same face")
        #expect(measured == NSFont.monospacedSystemFont(ofSize: 16, weight: .semibold),
                "not the canonical monospaced font — a caller that built one would miss the cache")

        for scale in appFontScales {
            #expect(LabelMetrics.width(of: "18.4k tok", font: font, scale: scale)
                    == hostedWidth(Text("18.4k tok").font(font.resolved(scale: scale))))
        }
    }

    /// `.serif` must measure the serif face too. Nothing in SyncCloud draws it, but a `default:`
    /// that silently swallows a design is how a rounded font measured as the default face.
    ///
    /// Pinned as a width, so it is a claim about the face rather than about a branch existing:
    /// "Birth Certificate" is 98.872pt in New York against 95.729pt in SF Pro at 13pt.
    @Test(.machinePinned(.pixelSampling)) func aSerifFontMeasuresTheSerifFace() {
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
    /// full of `@ViewBuilder` `if`s (the verify button, the selection chip, the overflow), so a gap
    /// per absent control would make a row wider than this arithmetic says.
    @Test(.machinePinned(.pixelSampling)) func anAbsentChildCostsNoSpacing() {
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
    /// gap on each side. `ActionBarLadderTests` pins that a row containing one still sheds; this
    /// pins the arithmetic the ladder does with it.
    @Test(.machinePinned(.pixelSampling)) func aSpacerContributesItsMinimumToTheIdealWidth() {
        let measured = hostedWidth(HStack(spacing: 10) {
            Color.clear.frame(width: 50, height: 10)
            Spacer(minLength: 16)
            Color.clear.frame(width: 50, height: 10)
        })
        // Annotated, not inferred: an unannotated `50 + 10 + 16 + 10 + 50` types as `Int`, and the
        // mixed comparison `#expect` then picks reports 136.0 != 136.
        let expected: CGFloat = 50 + 10 + 16 + 10 + 50
        #expect(measured == expected)
    }
}
