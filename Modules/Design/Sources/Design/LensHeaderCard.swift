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
    /// Row 1 — the lens's name, its actions, and the search toggle. 27pt is a 12pt label
    /// (15pt line) plus its 6pt vertical padding.
    ///
    /// This row used to hold the lens tabs. They moved to the window's workspace bar, and the
    /// row did **not** go with them: it now names the lens the tabs used to select, which is the
    /// one thing their removal would otherwise have deleted from the screen. Keeping the row also
    /// keeps `restingHeight` at 81 — the pane's header↔list boundary is pinned to it.
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

/// The one header card of a lensed workspace: the lens's name and controls on row 1, a summary of
/// what the lens found on row 2, and an expanding search below — 81pt tall at rest, in every lens
/// and every state.
///
/// **Ungated by design.** The card it replaces rendered only once a lens had results, and the two
/// lenses that had no card at all (Rename, Automations) pinned a bare row inside their *content*
/// card instead — so the header under the tabs was two unrelated mechanisms landing at 42 / 53 /
/// 83 / 115pt depending on lens and state. Being present in the empty and scanning states is what
/// makes the height a promise rather than a coincidence.
///
/// The host supplies the slots; the card owns the geometry, the search toggle's placement (last
/// on row 1, mirroring Compare's `standardHeaderControls`), and the field/chips rows.
public struct LensHeaderCard<Title: View, Actions: View, Summary: View, Trailing: View>: View {
    @Binding private var searchText: String
    @Binding private var isSearchExpanded: Bool
    private let searchPlaceholder: String
    private let searchHelp: String
    /// Whether this lens offers search **at all** — see the initializer.
    private let showsSearch: Bool
    private let chips: [TokenChipsRow.Item]
    private let onRemoveChip: (String) -> Void

    private let accent: Color
    private let surfaceStyle: SurfaceStyle
    private let level: GlassLevel
    private let hue: LiquidGlassHue
    private let tint: Double

    private let title: () -> Title
    private let actions: () -> Actions
    private let summary: () -> Summary
    private let trailing: () -> Trailing

    /// - Parameters:
    ///   - searchPlaceholder: this lens's vocabulary — see ``ExpandingSearchField``. It must
    ///     advertise exactly the tokens this lens binds and no others.
    ///   - searchHelp: names what this lens searches, for the toggle's tooltip and a11y label.
    ///   - showsSearch: whether this lens answers a query at all. **Defaults to true, and the
    ///     default is the right answer for every lens with a list.** It exists for the two pages
    ///     that have none: Organize's overview, which draws every lens's answer and filters none
    ///     of them, and Storage before its analysis has run, which has nothing to search yet.
    ///     Both were given a search toggle by this card unconditionally, so both offered a control
    ///     that could not do anything — and the honest repair is not to make the toggle's write a
    ///     no-op (a control that does nothing invisibly is worse) but to not draw it. False also
    ///     suppresses the field and chip rows, so a query parked by another lens cannot surface
    ///     here through `isSearching`.
    ///
    ///     The card's height does not change with it: the toggle sits in a fixed-height row
    ///     (``LensHeaderMetrics/tabRow``), so a header without it is the same 81pt as one with it.
    ///   - chips: the parsed tokens of the live query. Empty ⇒ no chip row, so the card only
    ///     grows the extra 30pt once a token actually parses.
    ///   - title: row 1 leading — the lens's name, which is what tells you where you are now
    ///     that the tabs no longer do.
    ///   - actions: row 1 trailing, before the search toggle — this lens's controls.
    ///   - summary: row 2 leading — the scanned-folder chip and stat pills.
    ///   - trailing: row 2 trailing — the detail line or "N of M" filtered count.
    public init(
        searchText: Binding<String>,
        isSearchExpanded: Binding<Bool>,
        searchPlaceholder: String,
        searchHelp: String,
        showsSearch: Bool = true,
        chips: [TokenChipsRow.Item] = [],
        onRemoveChip: @escaping (String) -> Void = { _ in },
        accent: Color,
        surfaceStyle: SurfaceStyle,
        level: GlassLevel,
        hue: LiquidGlassHue = .blue,
        tint: Double = 0,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() },
        @ViewBuilder summary: @escaping () -> Summary = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self._searchText = searchText
        self._isSearchExpanded = isSearchExpanded
        self.searchPlaceholder = searchPlaceholder
        self.searchHelp = searchHelp
        self.showsSearch = showsSearch
        self.chips = chips
        self.onRemoveChip = onRemoveChip
        self.accent = accent
        self.surfaceStyle = surfaceStyle
        self.level = level
        self.hue = hue
        self.tint = tint
        self.title = title
        self.actions = actions
        self.summary = summary
        self.trailing = trailing
    }

    /// Whether the field is showing: expanded, or collapsed-but-still-filtering (which the
    /// toggle's clear-on-collapse makes unreachable, but a host that seeds a query can produce).
    private var isSearching: Bool { showsSearch && (isSearchExpanded || !searchText.isEmpty) }

    public var body: some View {
        VStack(alignment: .leading, spacing: LensHeaderMetrics.rowGap) {
            HStack(spacing: 8) {
                title()
                Spacer(minLength: 8)
                actions()
                if showsSearch {
                    ExpandingSearchToggle(
                        text: $searchText,
                        isExpanded: $isSearchExpanded,
                        accent: accent,
                        help: searchHelp
                    )
                }
            }
            .frame(height: LensHeaderMetrics.tabRow)

            HStack(spacing: 8) {
                // **The prose yields first** — the rule this row has always stated, and now the
                // one it can keep.
                //
                // A layout priority only decides who is *asked* to shrink; it cannot make a child
                // that refuses do it. What every lens puts here is a run of `.fixedSize()` pills,
                // so the low priority bought nothing: the row insisted on its natural width, the
                // card's `maxWidth: .infinity` frame reported that larger width rather than the
                // proposal (see the note below, and `LensHeaderCardOverflowTests`), and the parent
                // CENTRED the oversized card — spilling it past **both** edges of the column. On
                // Duplicates at 492pt that clipped the scan-root chip on the leading edge and
                // "Apply 31 recommended" on the trailing one, in the same render.
                //
                // **A `ScrollView` was tried here first and is wrong in the other direction.** It
                // is greedy, so in an `HStack` it soaks up the row's slack like a `Spacer` and
                // starves a flexible sibling: To File's folder-survey sentence, which has room for
                // its full 490pt at a 1,400pt card, came out at a constant 414 at every width and
                // every text size. `ShrinkableRun` reports the content's width as ideal AND
                // maximum, so it takes what it needs and no more.
                //
                // What a squeeze cuts is the run's tail, and the cut is silent — there is no
                // indicator, because this row is 22pt and cannot spare the height. That is a real
                // cost and the lesser one: a readout you must widen the window to finish reading
                // beats a readout AND a destructive button both drawn cut in half.
                ShrinkableRun { summary() }
                    .clipped()
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
        // **This frame does NOT constrain the card to the width it was offered, and that is the
        // whole shape of the defect.** With `maxWidth: .infinity` the frame reports the LARGER of
        // the proposal and what its child insists on — and a row of `.fixedSize()` children insists
        // — so a card offered 340pt resolves to ~600pt and the parent centres it, spilling ~130pt
        // past each edge. A `.clipped()` here is therefore a no-op: it clips to 600.
        //
        // The clip that works belongs to whoever owns a DEFINITE width, which is the split —
        // `ContentView+SplitLayout` gives the workspace `.frame(width: totalWidth - railWidth)` and
        // clips there. Stated here because this is where the next person will reach for it, and
        // where it would look like it had worked. Measured: 6,678 pixels of ink outside the column
        // with the clip on this line, 0 with it at the split
        // (`LensHeaderCardOverrunTests`).
        .bottomSectionCard(surfaceStyle, level: level, hue: hue, tint: tint)
    }
}
