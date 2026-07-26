import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Design

/// Pins the app-wide text-size setting: the stored format, the scaling math, and — the load-bearing
/// part — that the *default* size renders byte-for-byte what the app rendered before the setting
/// existed, while the other sizes genuinely move the type.
///
/// The rendered assertions all measure `NSHostingView.fittingSize`, never a constant: the whole
/// risk here is a font that is *specified* differently but *laid out* the same (or vice versa), and
/// only a laid-out measurement can tell those apart.
@Suite @MainActor struct FontSizeTests {

    /// Laid-out width of a fixed string under a font. The probe string mixes wide and narrow
    /// glyphs plus digits so a weight change moves it, not just a size change.
    private func renderedWidth(_ font: Font) -> CGFloat {
        NSHostingView(rootView: Text("Hamburgefonstiv 0123").font(font)).fittingSize.width
    }

    /// Laid-out width of a `ScaledFont` as the app applies it — through the environment, not by
    /// calling `resolved` directly. This is what proves the modifier is actually wired.
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

    @Test func rawValuesAreStable() {
        #expect(FontSize.small.rawValue == "small")
        #expect(FontSize.medium.rawValue == "medium")
        #expect(FontSize.large.rawValue == "large")
        #expect(FontSize.extraLarge.rawValue == "extraLarge")
        // Order is the picker's left-to-right order: smallest first.
        #expect(FontSize.allCases == [.small, .medium, .large, .extraLarge])
    }

    @Test func unknownRawValueFailsSoItCanFallBackToDefault() {
        #expect(FontSize(rawValue: "huge") == nil)
    }

    @Test func resolvedFallsBackToMediumForMissingAndGarbageValues() throws {
        let defaults = try #require(UserDefaults(suiteName: "FontSizeTests.resolved"))
        defaults.removePersistentDomain(forName: "FontSizeTests.resolved")
        #expect(FontSize.resolved(defaults) == .medium, "fresh install must be the default size")

        defaults.set("gigantic", forKey: FontSize.defaultsKey)
        #expect(FontSize.resolved(defaults) == .medium, "garbage must not trap or match")

        defaults.set(FontSize.large.rawValue, forKey: FontSize.defaultsKey)
        #expect(FontSize.resolved(defaults) == .large)
        defaults.removePersistentDomain(forName: "FontSizeTests.resolved")
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
        // The user's brief: reasonable on both ends, illegible on neither. Guards against someone
        // later widening the range into unreadable-small or layout-breaking-large.
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

    @Test func scalingUpMultipliesCleanly() {
        #expect(FontSize.scaledPointSize(10, scale: 1.3) == 13)
        #expect(FontSize.scaledPointSize(20, scale: 1.15) == 23)
    }

    @Test func scalingDownStopsAtTheLegibilityFloor() {
        // 10pt × 0.9 = 9pt, exactly the floor — allowed.
        #expect(FontSize.scaledPointSize(10, scale: 0.9) == 9)
        // A hypothetical deeper scale must not go under it.
        #expect(FontSize.scaledPointSize(10, scale: 0.5) == FontSize.legibilityFloor)
        #expect(FontSize.scaledPointSize(13, scale: 0.5) == FontSize.legibilityFloor)
    }

    @Test func fontsAlreadyBelowTheFloorAreNeverGrownByShrinking() {
        // The app draws 8pt and 9pt badge glyphs. Flooring them at 9 flat would make "Small"
        // render them BIGGER than "Default" — the floor is `min(base, floor)` to prevent exactly
        // that. This is the assertion that catches a naive `max(base * scale, floor)`.
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
        // `.headline` is bold and `.caption2` is medium — measured, not assumed. A scaled headline
        // that came back regular would be a visible regression, so each style's recorded weight is
        // confirmed by rendering: the explicitly-sized equivalent must lay out to the same width.
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
        // Mutation guard for the test above: if `metrics(for:)` ever collapsed to a flat
        // `.regular`, the width comparison would still pass for the 9 regular styles. These two
        // are the ones that would actually break, so assert their weights directly.
        #expect(ScaledFont.metrics(for: .headline).weight == .bold)
        #expect(ScaledFont.metrics(for: .caption2).weight == .medium)
        #expect(renderedWidth(.system(size: 13, weight: .bold))
                != renderedWidth(.system(size: 13, weight: .regular)),
                "the probe string must be weight-sensitive for the check above to mean anything")
    }

    // MARK: The default size changes nothing

    /// Every `.font(…)` shape the app actually uses, paired with the `ScaledFont` it migrated to.
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
        // The correctness bar for the migration: at the default setting, every one of the ~290
        // rewritten call sites must lay out exactly as its `.font(…)` predecessor did.
        for shape in migratedShapes {
            #expect(renderedWidth(shape.scaled, scale: FontSize.medium.scale)
                    == renderedWidth(shape.original),
                    "\(shape.name) shifted at the default size")
        }
    }

    @Test func defaultSizeReturnsTheOriginalFontValueItself() {
        // Stronger than equal layout: `resolved(scale: 1)` hands back the very `Font` the old code
        // passed, so the default cannot drift even in a property no measurement here covers.
        for shape in migratedShapes {
            #expect(shape.scaled.resolved(scale: 1) == shape.original, "\(shape.name)")
        }
    }

    // MARK: The other sizes actually move the type

    @Test func largerSizesRenderWider() {
        // Mutation guard for the identity tests: if `scaledFont` silently ignored the scale, every
        // "unchanged at default" assertion above would still pass. This is the one that fails.
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
        // `Pill` moved `.monospacedDigit()` from the `Text` onto the font; the scaled synthesis
        // has to re-apply it, or count pills would start jittering at non-default sizes.
        func digitWidths(_ font: ScaledFont, scale: CGFloat) -> (CGFloat, CGFloat) {
            func width(_ s: String) -> CGFloat {
                NSHostingView(rootView: Text(s).scaledFont(font)
                    .environment(\.appFontScale, scale)).fittingSize.width
            }
            return (width("111111"), width("000000"))
        }
        for size in FontSize.allCases {
            let (ones, zeros) = digitWidths(ScaledFont.system(size: 12).monospacedDigit(), scale: size.scale)
            #expect(ones == zeros, "digits stopped being monospaced at \(size.rawValue)")
        }
        // And the guard that this probe can detect the difference at all.
        let (ones, zeros) = digitWidths(.system(size: 12), scale: 1)
        #expect(ones != zeros, "proportional digits must differ, or the check above is vacuous")
    }

    // MARK: The default font for text that names none

    @Test func textThatNamesNoFontStillScales() {
        // Not every label in the app has a `.font(…)` call site to migrate — a plain `Label` in a
        // button, a `TextField`'s contents. `appFontSize(_:)` supplies a scaled default font for
        // those; without it they sat at 13pt while everything around them grew.
        func width(_ size: FontSize) -> CGFloat {
            NSHostingView(rootView: Text("Hamburgefonstiv 0123").appFontSize(size)).fittingSize.width
        }
        #expect(width(.extraLarge) > width(.medium))
        #expect(width(.small) < width(.medium))
    }

    @Test func theDefaultSizeLeavesTheAmbientFontUntouched() {
        // The other half of that: at the default size the environment font must be left ALONE,
        // not written with an explicit `.body`. Writing it would replace SwiftUI's own implicit
        // default for every unstyled control in the app — a silent, app-wide shift for users who
        // never touched the setting. Compared against no modifier at all, not against `.body`.
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
        // The scaled default is published at the ROOT, so any view that names its own font must
        // still win. Otherwise the default would stomp all ~290 migrated call sites.
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
        // at its boundary (see `listDensity(_:)`), which is why the app's Compare table sets fonts
        // per cell. A custom environment key is not subject to that — but the Differences table is
        // the single most text-heavy surface in the app, so prove it rather than assume it.
        let large = Self.scalesSeenInsideTableCells(scale: FontSize.extraLarge.scale)
        #expect(!large.isEmpty, "no cell ever realized — the probe is broken, not the behaviour")
        #expect(large == [FontSize.extraLarge.scale],
                "the text size does not reach Table cells")
        // The control: the default scale arrives as the default, not as a leaked 1.3.
        #expect(Self.scalesSeenInsideTableCells(scale: 1) == [1])
    }

    /// Collects `\.appFontScale` as seen from *inside* a realized `Table` cell.
    ///
    /// Reported from within the cell rather than read back off an `NSTextField`, because a SwiftUI
    /// `Table` draws its cell text itself — there are no `NSTextField`s in the subtree to inspect.
    ///
    /// Mounted the way `SnapshotRendering` mounts its subjects: a borderless window that is never
    /// ordered in, with `isReleasedWhenClosed = false`. Ordering a window in and closing it inside
    /// the test host segfaults it.
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
        // (the same call `SnapshotRendering` uses to capture) realizes them, and a brief runloop
        // turn lets the tiling settle so `onAppear` fires. The caller's non-empty guard is what
        // keeps this honest: if the cells ever stop realizing, the test fails rather than passing
        // vacuously.
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

        // Grow-only: Small must not tighten rows further — that is List density's job, and
        // shrinking risks clipping the row content that is not text.
        #expect(ListDensity.tableRowHeight(compact, fontScale: FontSize.small.scale) == compact)

        // Comfortable pins nothing at any size; the Table measures its own rows.
        for size in FontSize.allCases {
            #expect(ListDensity.tableRowHeight(ListDensity.comfortable.metrics.tableMinRowHeight,
                                               fontScale: size.scale) == nil)
        }
    }
}
