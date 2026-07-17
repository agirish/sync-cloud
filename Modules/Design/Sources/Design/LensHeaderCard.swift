import SwiftUI

/// The row geometry of ``LensHeaderCard``, spelled out so the resting height is *derived* from
/// the rows rather than asserted as a lone magic number.
///
/// At rest the card is two rows: the tabs/controls row and the summary row. The search field and
/// its token chips are additional rows that appear only while searching — the card GROWS to fit
/// them (81 → 122 → 152 total), which is the accepted cost of Compare's expand-in-place pattern.
/// The alternative (swapping the search row in where the pills are) would hide the exact counts
/// you're watching change as you type, which is most of the value of filtering here.
public enum LensHeaderMetrics {
    /// Row 1 — the lens tabs, this lens's actions, and the search toggle. 27pt is a 12pt tab
    /// label (15pt line) plus its 6pt vertical padding; the active tab's underline is an
    /// `.overlay`, which adds ZERO height, so it must not enter this sum.
    public static let tabRow: CGFloat = 27
    /// Row 2 — the scanned-folder chip, the stat pills, and the trailing detail / "N of M".
    /// 22pt is a `.standard` `Pill` (12pt semibold number + 2×4pt padding, capsule).
    public static let summaryRow: CGFloat = 22
    /// The revealed search field (`ExpandingSearchField`): 16pt of text over 2×6pt padding.
    public static let searchRow: CGFloat = 28
    /// The parsed token chips, when a query contains any.
    public static let chipRow: CGFloat = 22
    /// The gap between any two rows of the card.
    public static let rowGap: CGFloat = 8
    /// The card's internal padding on all four sides.
    public static let padding: CGFloat = 12

    /// 12 + 27 + 8 + 22 + 12 = 81 — the card's VISIBLE height with the search collapsed, which
    /// must equal `LiquidGlass.headerHeight` so the card's bottom edge lands on the file pane's
    /// header↔list boundary. Derived, not typed: change a row and this follows.
    public static var restingHeight: CGFloat {
        padding + tabRow + rowGap + summaryRow + padding
    }

    /// What the card occupies in its parent at rest, including the half-gutter it insets itself
    /// by on each side (`bottomSectionCard`): 2.5 + 81 + 2.5 = 86.
    public static var restingTotalHeight: CGFloat {
        restingHeight + 2 * LiquidGlass.cardInset
    }
}

/// The one header card of a lensed workspace: lens tabs and controls on row 1, a summary of what
/// the lens found on row 2, and an expanding search below — 81pt tall at rest, in every lens and
/// every state.
///
/// **Ungated by design.** The card it replaces rendered only once a lens had results, and the two
/// lenses that had no card at all (Rename, Automations) pinned a bare row inside their *content*
/// card instead — so the header under the tabs was two unrelated mechanisms landing at 42 / 53 /
/// 83 / 115pt depending on lens and state. Being present in the empty and scanning states is what
/// makes the height a promise rather than a coincidence, and it's why the tabs can ride row 1:
/// the objection that kept them off the old card (`fd63c8b` — a results-gated card would shift
/// the tabs the moment a scan landed) dies with the gate.
///
/// The host supplies the slots; the card owns the geometry, the search toggle's placement (last
/// on row 1, mirroring Compare's `standardHeaderControls`), and the field/chips rows.
public struct LensHeaderCard<Tabs: View, Actions: View, Summary: View, Trailing: View>: View {
    @Binding private var searchText: String
    @Binding private var isSearchExpanded: Bool
    private let searchPlaceholder: String
    private let searchHelp: String
    private let chips: [TokenChipsRow.Item]
    private let onRemoveChip: (String) -> Void

    private let accent: Color
    private let surfaceStyle: SurfaceStyle
    private let level: GlassLevel
    private let hue: LiquidGlassHue
    private let tint: Double

    private let tabs: () -> Tabs
    private let actions: () -> Actions
    private let summary: () -> Summary
    private let trailing: () -> Trailing

    /// - Parameters:
    ///   - searchPlaceholder: this lens's vocabulary — see ``ExpandingSearchField``. It must
    ///     advertise exactly the tokens this lens binds and no others.
    ///   - searchHelp: names what this lens searches, for the toggle's tooltip and a11y label.
    ///   - chips: the parsed tokens of the live query. Empty ⇒ no chip row, so the card only
    ///     grows the extra 30pt once a token actually parses.
    ///   - tabs: row 1 leading — the lens picker.
    ///   - actions: row 1 trailing, before the search toggle — this lens's controls.
    ///   - summary: row 2 leading — the scanned-folder chip and stat pills.
    ///   - trailing: row 2 trailing — the detail line or "N of M" filtered count.
    public init(
        searchText: Binding<String>,
        isSearchExpanded: Binding<Bool>,
        searchPlaceholder: String,
        searchHelp: String,
        chips: [TokenChipsRow.Item] = [],
        onRemoveChip: @escaping (String) -> Void = { _ in },
        accent: Color,
        surfaceStyle: SurfaceStyle,
        level: GlassLevel,
        hue: LiquidGlassHue = .blue,
        tint: Double = 0,
        @ViewBuilder tabs: @escaping () -> Tabs,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() },
        @ViewBuilder summary: @escaping () -> Summary = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self._searchText = searchText
        self._isSearchExpanded = isSearchExpanded
        self.searchPlaceholder = searchPlaceholder
        self.searchHelp = searchHelp
        self.chips = chips
        self.onRemoveChip = onRemoveChip
        self.accent = accent
        self.surfaceStyle = surfaceStyle
        self.level = level
        self.hue = hue
        self.tint = tint
        self.tabs = tabs
        self.actions = actions
        self.summary = summary
        self.trailing = trailing
    }

    /// Whether the field is showing: expanded, or collapsed-but-still-filtering (which the
    /// toggle's clear-on-collapse makes unreachable, but a host that seeds a query can produce).
    private var isSearching: Bool { isSearchExpanded || !searchText.isEmpty }

    public var body: some View {
        VStack(alignment: .leading, spacing: LensHeaderMetrics.rowGap) {
            HStack(spacing: 8) {
                tabs()
                Spacer(minLength: 8)
                actions()
                ExpandingSearchToggle(
                    text: $searchText,
                    isExpanded: $isSearchExpanded,
                    accent: accent,
                    help: searchHelp
                )
            }
            .frame(height: LensHeaderMetrics.tabRow)

            HStack(spacing: 8) {
                summary()
                Spacer(minLength: 8)
                trailing()
            }
            .frame(height: LensHeaderMetrics.summaryRow)

            if isSearching {
                ExpandingSearchField(
                    text: $searchText,
                    isExpanded: $isSearchExpanded,
                    placeholder: searchPlaceholder
                )
                .frame(height: LensHeaderMetrics.searchRow)

                // Chips are their own row BELOW the field's surface here (unlike Compare, which
                // nests them inside it): this card's rows are a fixed ladder, so the chips need a
                // height the card can account for rather than one the field absorbs.
                if !chips.isEmpty {
                    TokenChipsRow(items: chips, tint: accent, onRemove: onRemoveChip)
                        .frame(height: LensHeaderMetrics.chipRow, alignment: .leading)
                }
            }
        }
        .padding(LensHeaderMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bottomSectionCard(surfaceStyle, level: level, hue: hue, tint: tint)
    }
}
