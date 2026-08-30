import AppKit
import SwiftUI

/// The width SwiftUI will give a run of text or an SF Symbol, computed instead of laid out.
///
/// This exists so a shedding ladder can pick its rung by arithmetic rather than by handing every
/// candidate row to `ViewThatFits` and letting it *build* each one to measure it — the defect fixed
/// in the pane bar by `772b6ca` and in the differences header by the change that added this file.
/// `PaneBarLadder` needed nothing like it, because every item on the pane bar is a fixed-size glyph
/// pill whose width is a published `PaneNavMetrics` constant. A toolbar of text buttons has no such
/// constant: its width is whatever the system font makes of "Copy 1,284 to OneDrive".
///
/// Every number here was calibrated against a hosted `NSHostingView` before it was written down,
/// and `LabelMetricsTests` re-checks all of them against the drawn view on every run — which is the
/// only thing that makes this file trustworthy.
///
/// **That sentence was false from the day `lineHeight` joined the file (`c7b8aab0`), about the one
/// member it did not name.** It said "all of them" while meaning the widths: `lineHeight` had no
/// test anywhere — `grep -rn lineHeight Modules/*/Tests` returned nothing — and it was returning
/// `NSLayoutManager.defaultLineHeight`, which is **1pt SHORT** of the box SwiftUI gives a `Text` at
/// 9.5–11.5pt and 15–16pt. Its sole caller reserves a row with it, so the error ran in the unsafe
/// direction, a reservation the text hangs out of; and a header promising blanket coverage is
/// exactly why nobody went to look. Both are fixed — the claim above is now the whole file, and the
/// fourth fact below is what the height rests on.
///
/// Four facts, each measured rather than assumed, and each the sort of thing an SDK update could
/// change:
///
/// - **SwiftUI rounds a text run UP to the next half point.** `NSAttributedString.size()` reports
///   76.565pt for "Review 1234" at 13pt and the hosted `Text` measures 77.0. Nearest-half would give
///   76.5 and be wrong; this is a ceiling, not a rounding.
/// - **An SF Symbol's laid-out width is its image's `alignmentRect`, not its `size`.** The two differ
///   by up to half a point — `checklist` at 13pt is a 18.0pt image with a 17.5pt alignment rect, and
///   17.5 is what SwiftUI lays out. Checked across 768 symbol × size × weight combinations, the
///   alignment rect matched the hosted width every single time and `size` did not.
/// - **A `Label`'s icon and title are separated by 8pt**, constant across icons of different widths
///   — so the icon occupies its intrinsic width rather than a fixed slot.
/// - **A line box is `NSAttributedString.size().height`, and NOT
///   `NSLayoutManager.defaultLineHeight(for:)`** — the obvious API, and the one this file used to
///   call. Swept over 8–24pt in half-point steps at four weights: the attributed size matched the
///   hosted `Text` in all 132 pairs, `defaultLineHeight` missed 60 of them, and every miss was
///   short by exactly 1pt. Same shape as the symbol fact above — the obvious property is right
///   often enough to look correct.
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
        // Text keys are unbounded — every distinct count renders a distinct string — so the cache is
        // dropped wholesale rather than grown without limit. Dropped, not evicted one entry at a
        // time: a header's whole working set is a dozen strings, so a refill costs microseconds,
        // whereas an LRU would cost a second data structure and a per-hit write. (`4028b23` is the
        // cautionary tale for the other choice: an eviction scan that ran per store past the cap.)
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
        // Bounded by construction — the symbol names in the app are a fixed set and the point sizes
        // come from four font scales — so this cache only ever needs filling, never clearing.
        let measured = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: key.pointSize, weight: key.weight))?
            .alignmentRect.width ?? 0
        symbolCache[key] = measured
        return measured
    }

    // MARK: - Height

    /// The height one line of `font` occupies at `scale` — the box SwiftUI gives a single-line
    /// `Text`, which is what a caller reserving a row for one has to reserve.
    ///
    /// Here rather than derived from the point size, because the two do not track: the system font
    /// steps its line height rather than scaling it smoothly. Measured, 10pt gives 13.0 and 10.5pt
    /// gives 13.0 too, but 11pt jumps to 14.0 — the same cliff `FontSize.scale`'s comment describes
    /// for the 1.35 top step. A caller pricing a fixed-height row against a text label has to ask
    /// for the real number or it will be wrong exactly where the row is tightest.
    ///
    /// **Measured through `NSAttributedString.size()`, the same call the widths above make, and
    /// NOT through `NSLayoutManager.defaultLineHeight(for:)`** — see
    /// `defaultLineHeightIsNotTheDrawnLineBoxButTheAttributedSizeIs`, which pins the difference.
    ///
    /// `PaneBarTitleMetrics.rowHeight` is the caller that needs it: a titled bar row is a pill, a
    /// 2pt gap and one line of title, inside a pinned 81pt pane header.
    public static func lineHeight(font: ScaledFont, scale: CGFloat) -> CGFloat {
        let key = TextKey(text: lineHeightSample, font: font.nsFont(scale: scale))
        if let cached = lineHeightCache[key] { return cached }
        let measured = NSAttributedString(string: key.text, attributes: [.font: key.font])
            .size().height
        lineHeightCache[key] = measured
        return measured
    }

    /// The run `lineHeight` measures. A line box does not depend on what is in it — checked across
    /// ascenders, descenders, accents and CJK, all one answer per font — so any single-line string
    /// does, with one exception that has to be avoided rather than reasoned about: it must not be
    /// **empty**. An attributed string with no characters carries no font run at all, and `size()`
    /// answers for a default face instead — 14.0 at both 10pt and 11pt, where the real line boxes
    /// are 13.0 and 14.0. The key this used to build carried exactly that empty string.
    private static let lineHeightSample = "Hg"

    // MARK: - Composites

    /// The laid-out width of `Label(title, systemImage:)` in `font` at `scale`.
    public static func labelWidth(_ title: String, systemImage: String,
                                  font: ScaledFont, scale: CGFloat) -> CGFloat {
        symbolWidth(systemImage, font: font, scale: scale)
            + labelIconSpacing
            + width(of: title, font: font, scale: scale)
    }

    /// The laid-out width of an `.actionBar` button — `ActionBarMetrics`' own padding around a
    /// label, or the circle an icon-only one is pinned to.
    ///
    /// `nonisolated`, unlike the measuring calls above: these are pure arithmetic over published
    /// constants and touch no cache, so a caller pricing a rung off the main actor need not hop.
    nonisolated public static func actionBarWidth(labelWidth: CGFloat) -> CGFloat {
        labelWidth + 2 * ActionBarMetrics.horizontalPadding
    }

    /// The width of an icon-only `.actionBar` control: a circle, so its height.
    nonisolated public static var actionBarIconOnlyWidth: CGFloat { ActionBarMetrics.height }

    // MARK: - Rounding

    /// SwiftUI's own rounding for a text run: up to the next half point.
    nonisolated public static func ceilToHalf(_ value: CGFloat) -> CGFloat { (value * 2).rounded(.up) / 2 }

    // MARK: - Caches

    /// Measuring a symbol costs ~25µs — nothing on its own, and 0.4ms per layout pass across a
    /// header's worth of them, which is the very cost this whole mechanism exists to remove. Both
    /// caches are keyed by everything that can change the answer, so a stale hit is not possible.
    private static let cacheLimit = 512
    private static var textCache: [TextKey: CGFloat] = [:]
    private static var symbolCache: [SymbolKey: CGFloat] = [:]
    /// Bounded like `symbolCache` — one entry per font × scale, and both are fixed sets — so this
    /// only ever needs filling.
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
