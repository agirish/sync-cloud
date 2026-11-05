import AppKit
import SwiftUI

/// The width SwiftUI will give a run of text or an SF Symbol, computed instead of laid out, so a
/// shedding ladder can pick its rung by arithmetic rather than having `ViewThatFits` build every
/// candidate to measure it. A toolbar of text buttons needs this; the pane bar doesn't, since its
/// pills are fixed-size glyphs with published `PaneNavMetrics` widths.
///
/// Every number here was calibrated against a hosted `NSHostingView`, and `LabelMetricsTests`
/// re-checks all of them, widths and line height, against the drawn view on every run.
///
/// Four measured facts, each the sort of thing an SDK update could change:
///
/// - **SwiftUI rounds a text run UP to the next half point.** `NSAttributedString.size()` reports
///   76.565pt for "Review 1234" at 13pt and the hosted `Text` measures 77.0: a ceiling, not
///   nearest-half.
/// - **An SF Symbol's laid-out width is its image's `alignmentRect`, not its `size`.** They differ
///   by up to half a point (`checklist` at 13pt: 18.0pt image, 17.5pt alignment rect, and 17.5 is
///   laid out). The alignment rect matched across 768 symbol × size × weight combinations.
/// - **A `Label`'s icon and title are separated by 8pt**, whatever the icon's width, so the icon
///   occupies its intrinsic width rather than a fixed slot.
/// - **A line box is `NSAttributedString.size().height`, NOT
///   `NSLayoutManager.defaultLineHeight(for:)`**, which is 1pt short at many sizes. A reservation
///   built on it would leave the text hanging out.
@MainActor
public enum LabelMetrics {

    /// The gap `Label(_:systemImage:)` puts between its icon and its title.
    public static let labelIconSpacing: CGFloat = 8

    // MARK: - Text

    /// The laid-out width of a single-line `Text` in `font` at `scale`.
    public static func width(of text: String, font: ScaledFont, scale: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let key = TextKey(text: text, font: font.nsFont(scale: scale))
        if let cached = textCache[key] { return cached }
        let measured = ceilToHalf(NSAttributedString(string: text, attributes: [.font: key.font])
            .size().width)
        // Text keys are unbounded (every count is a new string), so the cache is dropped wholesale
        // at the cap rather than grown. A header's working set is a dozen strings, so a refill
        // costs microseconds; an LRU would add a structure and a per-hit write, and an eviction
        // scan per store past the cap would cost far more.
        if textCache.count >= cacheLimit { textCache.removeAll(keepingCapacity: true) }
        textCache[key] = measured
        return measured
    }

    // MARK: - Symbols

    /// The laid-out width of `Image(systemName:)` drawn in `font` at `scale`.
    ///
    /// Zero for a symbol this system does not have, which is what SwiftUI draws for one too.
    public static func symbolWidth(_ systemName: String, font: ScaledFont, scale: CGFloat) -> CGFloat {
        let key = SymbolKey(name: systemName,
                            pointSize: font.pointSize(scale: scale),
                            weight: font.symbolWeight)
        if let cached = symbolCache[key] { return cached }
        // Bounded by construction (a fixed set of symbol names, point sizes from the font scales),
        // so this cache only fills, never clears.
        let measured = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: key.pointSize, weight: key.weight))?
            .alignmentRect.width ?? 0
        symbolCache[key] = measured
        return measured
    }

    // MARK: - Height

    /// The height one line of `font` occupies at `scale`: the box SwiftUI gives a single-line
    /// `Text`, which is what a caller reserving a row for one must reserve.
    ///
    /// Measured, not derived from the point size, because the system font steps its line height:
    /// 10pt and 10.5pt give 13.0, 11pt jumps to 14.0 (the cliff behind `FontSize.maximumPercent`).
    /// A fixed-height row priced on a guess goes wrong where it is tightest.
    ///
    /// **Through `NSAttributedString.size()`, NOT `NSLayoutManager.defaultLineHeight(for:)`**; see
    /// `defaultLineHeightIsNotTheDrawnLineBoxButTheAttributedSizeIs`.
    ///
    /// `PaneBarTitleMetrics.rowHeight` needs it: a titled bar row is a pill, a 2pt gap and one line
    /// of title, inside a pinned 81pt pane header.
    public static func lineHeight(font: ScaledFont, scale: CGFloat) -> CGFloat {
        let key = TextKey(text: lineHeightSample, font: font.nsFont(scale: scale))
        if let cached = lineHeightCache[key] { return cached }
        let measured = NSAttributedString(string: key.text, attributes: [.font: key.font])
            .size().height
        lineHeightCache[key] = measured
        return measured
    }

    /// The run `lineHeight` measures. A line box doesn't depend on its contents (checked across
    /// ascenders, descenders, accents and CJK), so any single-line string works, but **never an
    /// empty one**: with no characters there is no font run, and `size()` answers for a default
    /// face (14.0 at both 10pt and 11pt, where the real boxes are 13.0 and 14.0).
    private static let lineHeightSample = "Hg"

    // MARK: - Composites

    /// The laid-out width of `Label(title, systemImage:)` in `font` at `scale`.
    public static func labelWidth(_ title: String, systemImage: String,
                                  font: ScaledFont, scale: CGFloat) -> CGFloat {
        symbolWidth(systemImage, font: font, scale: scale)
            + labelIconSpacing
            + width(of: title, font: font, scale: scale)
    }

    /// The laid-out width of an `.actionBar` button: `ActionBarMetrics`' padding around a label.
    ///
    /// `nonisolated`, unlike the measuring calls above: pure arithmetic over published constants
    /// with no cache, so a caller off the main actor need not hop.
    nonisolated public static func actionBarWidth(labelWidth: CGFloat) -> CGFloat {
        labelWidth + 2 * ActionBarMetrics.horizontalPadding
    }

    /// The width of an icon-only `.actionBar` control: a circle, so its height.
    nonisolated public static var actionBarIconOnlyWidth: CGFloat { ActionBarMetrics.height }

    // MARK: - Rounding

    /// SwiftUI's own rounding for a text run: up to the next half point.
    nonisolated public static func ceilToHalf(_ value: CGFloat) -> CGFloat { (value * 2).rounded(.up) / 2 }

    // MARK: - Caches

    /// Measuring a symbol costs ~25µs, 0.4ms per layout pass across a header's worth, which is the
    /// cost this mechanism exists to remove. Both caches key on everything that can change the
    /// answer, so a stale hit is impossible.
    private static let cacheLimit = 512
    private static var textCache: [TextKey: CGFloat] = [:]
    private static var symbolCache: [SymbolKey: CGFloat] = [:]
    /// Bounded like `symbolCache` (one entry per font × scale, both fixed sets), so it only fills.
    private static var lineHeightCache: [TextKey: CGFloat] = [:]

    private struct TextKey: Hashable {
        let text: String
        let font: NSFont
    }

    private struct SymbolKey: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: NSFont.Weight
    }
}
