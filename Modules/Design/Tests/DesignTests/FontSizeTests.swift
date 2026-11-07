import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Design

/// Pins the app-wide text-size setting: the stored format, the scaling math, and that the default
/// size renders exactly what a plain `.font(…)` renders while the other sizes really move the type.
///
/// The rendered checks measure `NSHostingView.fittingSize`, never a constant: the risk is a font
/// specified differently but laid out the same (or the reverse), which only layout can reveal.
@Suite @MainActor struct FontSizeTests {

    /// Laid-out width of a fixed string under a font. The probe string mixes wide and narrow
    /// glyphs plus digits so a weight change moves it, not just a size change.
    private func renderedWidth(_ font: Font) -> CGFloat {
        NSHostingView(rootView: Text("Hamburgefonstiv 0123").font(font)).fittingSize.width
    }

    /// Laid-out width of a `ScaledFont` as the app applies it, through the environment rather than
    /// `resolved`, so it proves the modifier is wired.
    private func renderedWidth(_ font: ScaledFont, scale: CGFloat) -> CGFloat {
        NSHostingView(rootView: Text("Hamburgefonstiv 0123")
            .scaledFont(font)
            .environment(\.appFontScale, scale)).fittingSize.width
    }

    // MARK: Stored format

    @Test func defaultsKeyIsStable() {
        // Persisted in UserDefaults; changing it silently resets everyone to the default size.
        #expect(FontSize.defaultsKey == "fontSize")
    }

    @Test func presetPercentsAreStable() {
        // The four presets, Small/Default/Large/Larger, are the values on disk for everyone who
        // chose one. Moving a number here silently changes the size an existing user sees.
        #expect(FontSize.small.percent == 90)
        #expect(FontSize.medium.percent == 100)
        #expect(FontSize.large.percent == 125)
        #expect(FontSize.extraLarge.percent == 135)
        // Order is the row's left-to-right order: smallest first.
        #expect(FontSize.allCases == [.small, .medium, .large, .extraLarge])
    }

    @Test func initClampsToTheSelectableRange() {
        #expect(FontSize(percent: 10).percent == FontSize.minimumPercent)
        #expect(FontSize(percent: 400).percent == FontSize.maximumPercent)
        // Not snapped to `step`: a value typed or restored between stops is honoured.
        #expect(FontSize(percent: 113).percent == 113)
    }

    @Test func everySelectablePercentIsInRangeAndOnTheStep() {
        let stops = FontSize.selectablePercents
        #expect(stops.first == FontSize.minimumPercent)
        #expect(stops.last == FontSize.maximumPercent)
        #expect(stops.allSatisfy { $0 % FontSize.step == 0 })
        // Every named preset has to be reachable by the slider, or the detent labels point at
        // values the control cannot land on.
        for preset in FontSize.allCases {
            #expect(stops.contains(preset.percent), "\(preset.percent)% is not a slider stop")
        }
    }
    // MARK: Stepping from the keyboard (View ▸ Text Size)

    /// The keyboard can't reach a size the slider can't: every step from every slider stop lands
    /// on another stop. Width budgets such as the version line's are measured over
    /// `selectablePercents`, so this keeps the menu inside them.
    @Test func everyStepFromASliderStopLandsOnASliderStop() {
        let stops = Set(FontSize.selectablePercents)
        for percent in FontSize.selectablePercents {
            let size = FontSize(percent: percent)
            if let up = size.bigger {
                #expect(stops.contains(up.percent), "\(percent)% stepped up to \(up.percent)%, which is not a stop")
                #expect(up.percent > percent)
            }
            if let down = size.smaller {
                #expect(stops.contains(down.percent), "\(percent)% stepped down to \(down.percent)%, which is not a stop")
                #expect(down.percent < percent)
            }
        }
    }

    /// The ends are `nil`, which greys the menu item, and only the ends are.
    @Test func onlyTheEndsOfTheRangeRefuseToStep() {
        #expect(FontSize(percent: FontSize.maximumPercent).bigger == nil)
        #expect(FontSize(percent: FontSize.minimumPercent).smaller == nil)
        #expect(FontSize(percent: FontSize.maximumPercent).smaller != nil)
        #expect(FontSize(percent: FontSize.minimumPercent).bigger != nil)
        // The positive control on the step itself: from the default it moves by exactly one stop.
        #expect(FontSize.medium.bigger?.percent == FontSize.medium.percent + FontSize.step)
        #expect(FontSize.medium.smaller?.percent == FontSize.medium.percent - FontSize.step)
    }

    /// A value between stops (`init(percent:)` clamps but doesn't snap) steps to the nearest stop in
    /// the direction asked, so one ⌘+ puts a stray 113 back on the rail at 115, not 118.
    @Test func aValueBetweenStopsSnapsToTheNextStop() {
        #expect(FontSize(percent: 113).bigger?.percent == 115)
        #expect(FontSize(percent: 113).smaller?.percent == 110)
    }

    // MARK: The stored value changed shape


    @Test func migrationRewritesLegacyStringsOnceAndLeavesNumbersAlone() {
        let defaults = ScratchDefaults("FontSizeTests.migrate")

        defaults.set("extraLarge", forKey: FontSize.defaultsKey)
        let migrated = FontSize.migrateLegacyValue(in: defaults)
        #expect(migrated?.size == .extraLarge)
        // The raw string is carried out for the launch log, so it names what was on disk, not the
        // size's current label.
        #expect(migrated?.raw == "extraLarge")
        // What is on disk is now an Int, the only shape `@AppStorage(...) var percent: Int` can
        // see. Checks what it wrote back, not that it decoded: a tolerant reader would pass
        // without the store ever changing.
        #expect(defaults.object(forKey: FontSize.defaultsKey) as? Int == 135)

        // Idempotent: a second run has nothing to do, and must not re-examine its own output.
        #expect(FontSize.migrateLegacyValue(in: defaults) == nil)
        #expect(defaults.object(forKey: FontSize.defaultsKey) as? Int == 135)

        // A fresh install has nothing to migrate, and must not be given a value.
        let fresh = ScratchDefaults("FontSizeTests.migrateFresh")
        #expect(FontSize.migrateLegacyValue(in: fresh) == nil)
        #expect(fresh.object(forKey: FontSize.defaultsKey) == nil)

        // An unrecognised string is left exactly where it is, for `resolved` to fall back on.
        let junk = ScratchDefaults("FontSizeTests.migrateJunk")
        junk.set("gigantic", forKey: FontSize.defaultsKey)
        #expect(FontSize.migrateLegacyValue(in: junk) == nil)
        #expect(junk.string(forKey: FontSize.defaultsKey) == "gigantic")
    }

    @Test func everyLegacyRawValueStillMapsToTheSizeItNamed() {
        // Derived from the table rather than restated, so a key removed from `legacyRawValues`
        // fails here instead of quietly resetting the users who still have it on disk.
        #expect(Set(FontSize.legacyRawValues.keys)
                == ["small", "medium", "large", "extraLarge"])
        #expect(FontSize.legacyRawValues["medium"] == .medium)
    }

    // MARK: Scale range

    @Test func mediumIsExactlyUnscaled() {
        // The identity short-circuit in `resolved(scale:)` keys off `scale == 1`, so this is not
        // cosmetic: if medium drifted to 0.99 the whole app would re-synthesize its fonts.
        #expect(FontSize.medium.scale == 1)
    }

    @Test func scalesAreStrictlyIncreasingAcrossTheCases() {
        let scales = FontSize.allCases.map(\.scale)
        #expect(scales == scales.sorted())
        #expect(Set(scales).count == scales.count, "two sizes that scale the same are one setting")
    }

    @Test func rangeStaysWithinLegibleBounds() {
        // Legible at both ends: keeps the range from widening into unreadable-small or
        // layout-breaking-large.
        let scales = FontSize.allCases.map(\.scale)
        #expect(scales.min()! >= 0.85, "smaller than this and 11pt body text stops being readable")
        #expect(scales.max()! <= 1.5, "larger than this and the fixed chrome starts clipping")
    }

    // MARK: Scaling math

    @Test func unscaledPointSizeIsTheBaseExactly() {
        for base in [CGFloat(8), 9, 10, 11, 12, 13, 17, 26] {
            #expect(FontSize.scaledPointSize(base, scale: 1) == base)
        }
    }

    @Test func scalingUpAppliesTheFullMultiplierThroughTheKnee() {
        // At and below the 11pt knee the whole boost applies: this is the text the larger settings
        // exist for.
        #expect(FontSize.scaledPointSize(10, scale: 1.25) == 12.5)
        #expect(FontSize.scaledPointSize(11, scale: 1.25) == 13.75)
        #expect(FontSize.scaledPointSize(10, scale: 1.4) == 14)
        #expect(FontSize.scaledPointSize(8, scale: 1.25) == 10)
    }

    @Test func scalingUpDampsAboveTheKnee() {
        // Above the knee each base point adds only `surplusSlope` scaled points: 13pt body at
        // Large is 11 × 1.25 + 2 × 0.5 = 14.75, not the 16.25 a flat multiply would give. These
        // literals pin the curve: if `knee` or `surplusSlope` moves, this fails and the new numbers
        // get chosen deliberately.
        #expect(FontSize.scaledPointSize(13, scale: 1.25) == 14.75)
        #expect(FontSize.scaledPointSize(15, scale: 1.25) == 15.75)
        #expect(FontSize.scaledPointSize(13, scale: 1.4) == 16.4)
    }

    @Test func titlesPastTheCrossoverKeepTheirDefaultSize() {
        // The damped curve dips below `base` past 16.5pt at Large (19.8 at Larger), and the clamp
        // holds the font at its default size, so titles don't grow at all.
        #expect(FontSize.scaledPointSize(17, scale: 1.25) == 17)
        #expect(FontSize.scaledPointSize(22, scale: 1.25) == 22)
        #expect(FontSize.scaledPointSize(26, scale: 1.4) == 26)
        // Just under the crossover still grows, so the clamp is a tail, not a cliff.
        #expect(FontSize.scaledPointSize(16, scale: 1.25) == 16.25)
    }

    @Test func chromeTextAtTheKneeStaysUnderThePinnedRowCliff() {
        // Measured cliff: one line of system-font text is 18pt tall through 14.85pt and 19pt from
        // 15.0pt. Header chrome carries 11pt text in pinned 28pt rows with exactly 18pt to spare
        // (the differences count pill's inset age capsule: 19 + 2 + 8 would be 29). Every
        // selectable size must keep knee-sized text under 15pt, or those rows grow a pixel and
        // `theRowIsAlwaysTheActionBarHeight` fails across the ladder.
        for percent in FontSize.selectablePercents {
            let size = FontSize(percent: percent)
            #expect(FontSize.scaledPointSize(FontSize.knee, scale: size.scale) < 15,
                    "\(percent)% renders 11pt chrome at \(FontSize.scaledPointSize(FontSize.knee, scale: size.scale))pt — over the 19pt line-height cliff")
        }
    }

    @Test func theCeilingIsTheLargestPercentUnderTheCliff() {
        // Pins why the range stops where it does, not only that its stops are safe. 136% puts
        // knee text at 14.96 and 137% at 15.07, so 137 is the first unsafe whole percent and 135
        // the round number under it.
        #expect(FontSize.scaledPointSize(FontSize.knee, scale: 1.36) < 15)
        #expect(FontSize.scaledPointSize(FontSize.knee, scale: 1.37) >= 15)
        #expect(FontSize.maximumPercent == 135)
    }

    @Test func scalingUpNeverShrinksAnyFont() {
        for scale in [FontSize.large.scale, FontSize.extraLarge.scale] {
            for base in stride(from: CGFloat(4), through: 54, by: 0.5) {
                #expect(FontSize.scaledPointSize(base, scale: scale) >= base,
                        "\(base)pt shrank under scale \(scale)")
            }
        }
    }

    @Test func theCurveIsMonotonicSoTheTypeHierarchyCannotInvert() {
        // A bigger base font must never render smaller than a smaller one at the same setting.
        // Interpolating the multiplier between bands would make f(b) = b·s(b) non-monotonic near
        // the upper band; the knee model is monotone by construction, and this sweep keeps it so.
        for size in FontSize.allCases {
            var previous: CGFloat = 0
            for base in stride(from: CGFloat(4), through: 54, by: 0.25) {
                let scaled = FontSize.scaledPointSize(base, scale: size.scale)
                #expect(scaled >= previous,
                        "\(base)pt renders \(scaled) < \(previous) at \(size.percent)%")
                previous = scaled
            }
        }
    }

    @Test func smallTextGetsProportionallyMoreBoostThanLargeText() {
        // Under a flat multiplier captions stay small while titles balloon, which the curve exists
        // to avoid. Growth ratio must never increase with base size.
        for scale in [FontSize.large.scale, FontSize.extraLarge.scale] {
            let ratios = [CGFloat(9), 10, 11, 13, 15, 17, 22, 26]
                .map { FontSize.scaledPointSize($0, scale: scale) / $0 }
            #expect(ratios == ratios.sorted(by: >),
                    "growth ratios \(ratios) are not nonincreasing at scale \(scale)")
            #expect(ratios.first! > ratios.last!,
                    "the curve is flat — captions and titles grew alike at scale \(scale)")
        }
    }

    @Test func scalingDownStopsAtTheLegibilityFloor() {
        // 10pt × 0.9 = 9pt, exactly the floor — allowed.
        #expect(FontSize.scaledPointSize(10, scale: 0.9) == 9)
        // A hypothetical deeper scale must not go under it.
        #expect(FontSize.scaledPointSize(10, scale: 0.5) == FontSize.legibilityFloor)
        #expect(FontSize.scaledPointSize(13, scale: 0.5) == FontSize.legibilityFloor)
    }

    @Test func fontsAlreadyBelowTheFloorAreNeverGrownByShrinking() {
        // The app draws 8pt and 9pt badge glyphs. Flooring them at 9 flat would make Small render
        // them bigger than Default, so the floor is `min(base, floor)`. Catches a naive
        // `max(base * scale, floor)`.
        #expect(FontSize.scaledPointSize(8, scale: 0.9) == 8)
        #expect(FontSize.scaledPointSize(4, scale: 0.9) == 4)
        for base in [CGFloat(4), 8, 9, 10, 11, 13] {
            let small = FontSize.scaledPointSize(base, scale: FontSize.small.scale)
            #expect(small <= base, "Small must never enlarge \(base)pt")
        }
    }

    @Test func noAppFontEverShrinksBelowTheFloorAtTheSmallestSize() {
        // Sweep every point size the app actually uses.
        for base in [CGFloat(4), 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 19, 22, 26, 30, 40, 54] {
            let small = FontSize.scaledPointSize(base, scale: FontSize.small.scale)
            #expect(small >= min(base, FontSize.legibilityFloor))
        }
    }

    // MARK: Text-style metrics are the system's, not invented

    @Test func textStyleSizesMatchTheSystem() {
        // `ScaledFont` re-creates a text style as an explicitly sized font, so its table of base
        // sizes has to equal what macOS resolves the style to. Pinned against the live NSFont so
        // an OS change fails here instead of silently re-sizing scaled text.
        let pairs: [(Font.TextStyle, NSFont.TextStyle)] = [
            (.largeTitle, .largeTitle), (.title, .title1), (.title2, .title2), (.title3, .title3),
            (.headline, .headline), (.body, .body), (.callout, .callout),
            (.subheadline, .subheadline), (.footnote, .footnote),
            (.caption, .caption1), (.caption2, .caption2),
        ]
        for (swiftUIStyle, appKitStyle) in pairs {
            let expected = NSFont.preferredFont(forTextStyle: appKitStyle).pointSize
            #expect(ScaledFont.metrics(for: swiftUIStyle).size == expected,
                    "\(swiftUIStyle) base size drifted from the system's \(expected)pt")
        }
    }

    @Test func textStyleWeightsMatchTheSystem() {
        // `.headline` is bold and `.caption2` is medium, measured, not assumed. Each style's
        // recorded weight is confirmed by rendering: the explicitly sized equivalent must lay out
        // to the same width.
        for style in [Font.TextStyle.largeTitle, .title, .title2, .title3, .headline, .body,
                      .callout, .subheadline, .footnote, .caption, .caption2] {
            let metrics = ScaledFont.metrics(for: style)
            let semantic = renderedWidth(.system(style))
            let explicit = renderedWidth(.system(size: metrics.size, weight: metrics.weight))
            #expect(semantic == explicit,
                    "\(style) recorded as \(metrics.weight) but lays out differently")
        }
    }

    @Test func headlineAndCaption2AreNotPlainRegular() {
        // Guards the test above: if `metrics(for:)` collapsed to a flat `.regular`, the width check
        // would still pass for the 9 regular styles. These two would break, so assert them
        // directly.
        #expect(ScaledFont.metrics(for: .headline).weight == .bold)
        #expect(ScaledFont.metrics(for: .caption2).weight == .medium)
        #expect(renderedWidth(.system(size: 13, weight: .bold))
                != renderedWidth(.system(size: 13, weight: .regular)),
                "the probe string must be weight-sensitive for the check above to mean anything")
    }

    // MARK: The default size changes nothing

    /// Every `.font(…)` shape the app uses, paired with its `ScaledFont` equivalent.
    private var migratedShapes: [(name: String, original: Font, scaled: ScaledFont)] {
        [
            ("caption", .caption, .caption),
            ("caption2", .caption2, .caption2),
            ("callout", .callout, .callout),
            ("headline", .headline, .headline),
            ("body", .body, .body),
            ("subheadline", .subheadline, .subheadline),
            ("footnote", .footnote, .footnote),
            ("title2", .title2, .title2),
            ("title3", .title3, .title3),
            ("size11", .system(size: 11), .system(size: 11)),
            ("size12semibold", .system(size: 12, weight: .semibold), .system(size: 12, weight: .semibold)),
            ("size9bold", .system(size: 9, weight: .bold), .system(size: 9, weight: .bold)),
            ("size11mono", .system(size: 11, design: .monospaced), .system(size: 11, design: .monospaced)),
            ("calloutMono", .system(.callout, design: .monospaced), .system(.callout, design: .monospaced)),
            ("subheadlineMono", .system(.subheadline, design: .monospaced), .system(.subheadline, design: .monospaced)),
            ("bodyRounded", .system(.body, design: .rounded), .system(.body, design: .rounded)),
            ("caption2semibold", .caption2.weight(.semibold), .caption2.weight(.semibold)),
            ("captionMedium", .caption.weight(.medium), .caption.weight(.medium)),
            ("title2semibold", .title2.weight(.semibold), .title2.weight(.semibold)),
            ("captionMonospaced", .caption.monospaced(), .caption.monospaced()),
            ("calloutMonoMedium", .system(.callout, design: .monospaced).weight(.medium),
             .system(.callout, design: .monospaced).weight(.medium)),
            ("size16semiboldRounded", .system(size: 16, weight: .semibold, design: .rounded),
             .system(size: 16, weight: .semibold, design: .rounded)),
        ]
    }

    @Test func defaultSizeRendersIdenticallyToThePreSettingFont() {
        // At the default setting, every `ScaledFont` call site must lay out exactly as the plain
        // `.font(…)` it stands for.
        for shape in migratedShapes {
            #expect(renderedWidth(shape.scaled, scale: FontSize.medium.scale)
                    == renderedWidth(shape.original),
                    "\(shape.name) shifted at the default size")
        }
    }

    @Test func defaultSizeReturnsTheOriginalFontValueItself() {
        // Stronger than equal layout: `resolved(scale: 1)` hands back the very `Font` it stands
        // for, so the default can't drift even in a property no measurement here covers.
        for shape in migratedShapes {
            #expect(shape.scaled.resolved(scale: 1) == shape.original, "\(shape.name)")
        }
    }

    // MARK: The other sizes actually move the type

    @Test func largerSizesRenderWider() {
        // Guards the identity tests: if `scaledFont` ignored the scale, every "unchanged at
        // default" check above would still pass. This one fails.
        for shape in migratedShapes {
            let widths = FontSize.allCases.map { renderedWidth(shape.scaled, scale: $0.scale) }
            #expect(widths == widths.sorted(), "\(shape.name) is not monotonic across sizes")
            #expect(widths.last! > widths.first!, "\(shape.name) never changed size at all")
        }
    }

    @Test func theSmallestSizeStaysReadableAndTheLargestStaysBounded() {
        for shape in migratedShapes {
            let base = renderedWidth(shape.scaled, scale: FontSize.medium.scale)
            let small = renderedWidth(shape.scaled, scale: FontSize.small.scale)
            let largest = renderedWidth(shape.scaled, scale: FontSize.extraLarge.scale)
            #expect(small >= base * 0.85, "\(shape.name) shrank far past its scale")
            #expect(largest <= base * 1.45, "\(shape.name) grew far past its scale")
        }
    }

    @Test func scalingPreservesTheMonospacedDigitTreatment() {
        // `Pill` puts `.monospacedDigit()` on the font, not the `Text`; the scaled synthesis has to
        // re-apply it, or count pills jitter at non-default sizes.
        func digitWidths(_ font: ScaledFont, scale: CGFloat) -> (CGFloat, CGFloat) {
            func width(_ s: String) -> CGFloat {
                NSHostingView(rootView: Text(s).scaledFont(font)
                    .environment(\.appFontScale, scale)).fittingSize.width
            }
            return (width("111111"), width("000000"))
        }
        for size in FontSize.allCases {
            let (ones, zeros) = digitWidths(ScaledFont.system(size: 12).monospacedDigit(), scale: size.scale)
            #expect(ones == zeros, "digits stopped being monospaced at \(size.percent)%")
        }
        // And the guard that this probe can detect the difference at all.
        let (ones, zeros) = digitWidths(.system(size: 12), scale: 1)
        #expect(ones != zeros, "proportional digits must differ, or the check above is vacuous")
    }

    // MARK: The default font for text that names none

    @Test func textThatNamesNoFontStillScales() {
        // Not every label names a font: a plain `Label` in a button, a `TextField`'s contents.
        // `appFontSize(_:)` supplies a scaled default for those; without it they stay at 13pt
        // while everything around them grows.
        func width(_ size: FontSize) -> CGFloat {
            NSHostingView(rootView: Text("Hamburgefonstiv 0123").appFontSize(size)).fittingSize.width
        }
        #expect(width(.extraLarge) > width(.medium))
        #expect(width(.small) < width(.medium))
    }

    @Test func theDefaultSizeLeavesTheAmbientFontUntouched() {
        // At the default size the environment font must be left alone, not written as `.body`.
        // Writing it replaces SwiftUI's implicit default for every unstyled control, a silent
        // app-wide shift for users who never touched the setting. Compared against no modifier at
        // all, not against `.body`.
        let bare = NSHostingView(rootView: Text("Hamburgefonstiv 0123")).fittingSize
        let defaulted = NSHostingView(
            rootView: Text("Hamburgefonstiv 0123").appFontSize(.medium)).fittingSize
        #expect(bare == defaulted)

        // A control is the case that actually differs: SwiftUI's implicit default for one is not
        // `Font.body`, so a naive root write would resize it.
        let bareButton = NSHostingView(rootView: Button("Reveal") {}).fittingSize
        let defaultedButton = NSHostingView(
            rootView: Button("Reveal") {}.appFontSize(.medium)).fittingSize
        #expect(bareButton == defaultedButton)
    }

    @Test func anExplicitFontStillOutranksTheScaledDefault() {
        // The scaled default is published at the root, so any view that names its own font must
        // still win, or the default would override every explicit call site.
        let explicit = NSHostingView(rootView: Text("Hamburgefonstiv 0123")
            .scaledFont(.system(size: 11))
            .appFontSize(.extraLarge)).fittingSize.width
        let defaulted = NSHostingView(rootView: Text("Hamburgefonstiv 0123")
            .appFontSize(.extraLarge)).fittingSize.width
        #expect(explicit != defaulted, "the root default overrode an explicit font")
        #expect(explicit == renderedWidth(.system(size: 11), scale: FontSize.extraLarge.scale))
    }

    // MARK: Reaching the places the built-in levers do not

    @Test func theScaleReachesTableCells() {
        // A SwiftUI `Table` drops `defaultMinListRowHeight`, `controlSize` and the ambient `\.font`
        // at its boundary (see `listDensity(_:)`), which is why Compare's table sets fonts per
        // cell. A custom environment key isn't dropped, but the Differences table is the app's
        // most text-heavy surface, so prove it rather than assume it.
        let large = Self.scalesSeenInsideTableCells(scale: FontSize.extraLarge.scale)
        #expect(!large.isEmpty, "no cell ever realized — the probe is broken, not the behaviour")
        #expect(large == [FontSize.extraLarge.scale],
                "the text size does not reach Table cells")
        // The control: the default scale arrives as the default, not as a leaked larger one.
        #expect(Self.scalesSeenInsideTableCells(scale: 1) == [1])
    }

    /// Collects `\.appFontScale` as seen from *inside* a realized `Table` cell.
    ///
    /// Reported from within the cell, because a SwiftUI `Table` draws its cell text itself and
    /// there are no `NSTextField`s to inspect.
    ///
    /// Mounted in a borderless window never ordered in,
    /// with `isReleasedWhenClosed = false`. Ordering a window in and closing it inside the test
    /// host segfaults it.
    @MainActor
    private static func scalesSeenInsideTableCells(scale: CGFloat) -> [CGFloat] {
        final class Box: @unchecked Sendable { var seen: Set<CGFloat> = [] }
        struct Reporter: View {
            @Environment(\.appFontScale) private var appFontScale
            let box: Box
            var body: some View {
                Color.clear.onAppear { box.seen.insert(appFontScale) }
            }
        }
        struct Row: Identifiable { let id: Int }

        let box = Box()
        let table = Table([Row(id: 0)]) {
            TableColumn("A") { _ in
                Text("Hamburgefonstiv").scaledFont(.system(size: 11)).background(Reporter(box: box))
            }
            TableColumn("B") { _ in Text("x").scaledFont(.system(size: 11)) }
        }
        let size = CGSize(width: 420, height: 140)
        let host = NSHostingView(rootView: AnyView(
            table.environment(\.appFontScale, scale).frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // A `Table` builds its cells lazily during a display pass, not during layout. Drawing it
        // realizes them, and a brief runloop turn lets `onAppear`
        // fire. The caller's non-empty guard fails the test if the cells stop realizing.
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return box.seen.sorted()
    }

    // MARK: Compact rows make room for bigger text

    @Test func compactRowHeightGrowsWithTheTextButNeverShrinks() {
        let compact = ListDensity.compact.metrics.tableMinRowHeight
        #expect(compact != nil, "compact is the density that pins a height")

        // Grows for the larger sizes, or the pinned 20pt row would clip 14pt text.
        let base = ListDensity.tableRowHeight(compact, fontScale: 1)
        let largest = ListDensity.tableRowHeight(compact, fontScale: FontSize.extraLarge.scale)
        #expect(base == compact)
        #expect(largest! > base!)

        // Grow-only: Small must not tighten rows further. That is List density's job, and
        // shrinking risks clipping row content that isn't text.
        #expect(ListDensity.tableRowHeight(compact, fontScale: FontSize.small.scale) == compact)

        // Comfortable pins nothing at any size; the Table measures its own rows.
        for size in FontSize.allCases {
            #expect(ListDensity.tableRowHeight(ListDensity.comfortable.metrics.tableMinRowHeight,
                                               fontScale: size.scale) == nil)
        }
    }
}
