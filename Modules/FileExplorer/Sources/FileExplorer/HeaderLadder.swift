import Design
import SwiftUI

/// The differences header's shedding ladder: how wide each `HeaderCompaction` rung is, and which one
/// a given offered width gets.
///
/// The header used to hand all six rungs to `ViewThatFits` and let it search. That works, but
/// `ViewThatFits` **builds every child in order to measure it** — and a rung here is not a row of
/// glyph pills, it is a whole toolbar: count pill, item-counts readout, fold-all toggle, filter
/// `Menu`, selection chip, overflow `Menu`, verify, review, two transfer buttons and an expanding
/// search field. Six of those per layout pass, in a `body` that re-evaluates on every render — which
/// during a bulk sync means once per copied file. Worse, `filterMenu`'s own comment already records
/// that **a `Menu`'s content builder is not lazy**, so each of the six eagerly materialised both
/// menus, filter counts and a `ForEach` over `DifferenceFilter.allCases` included.
///
/// This is the same defect `772b6ca` fixed in `PaneHeader.navCluster`, and it takes the same shape of
/// fix: compute the rung arithmetically from the offered width, hand `ViewThatFits` two children
/// instead of six so the layout engine keeps the final say, and restate what the old `ViewThatFits`
/// reported as its own minimum width.
///
/// **What is new here, and why this file is longer than `PaneBarLadder`.** Every item on the pane bar
/// is a fixed-size glyph pill whose width is a published `PaneNavMetrics` constant, so that ladder is
/// a sum of constants. This bar is mostly *text* — "Copy 1,284 to OneDrive — Personal" has no
/// constant — so the widths come from `Design.LabelMetrics`, which measures a run of text or an SF
/// Symbol the way SwiftUI lays it out without laying it out. Everything else is the same idea: each
/// figure below is the arithmetic of the view that draws the control, in that view's own published
/// constants (`ActionBarMetrics`, `PillVariant`) rather than a second opinion about them, and
/// `HeaderLadderTests` pins every one against the drawn row.
///
/// **The ladder is walked in declaration order, not sorted by width** — because that is exactly
/// `ViewThatFits`'s own rule, and reproducing it is the whole point.
///
/// Worth being precise about how this differs from the pane bar, since the shape of the fix is
/// borrowed from it. `PaneBarLadder` records that its ladder is deliberately **not** monotonic —
/// shedding the preview toggle to gain a ⋯ pill makes that bar four points *wider*, so the rung can
/// never be chosen and sorting by width would pick a different bar. This ladder has no such
/// inversion: measured across every fixture in `HeaderLadderTests.theLadderNeverWidensAsItSheds`, it
/// is monotonically non-increasing, because every rung here either sheds a run of text or does
/// nothing. What it does have is **ties** — a rung whose concession does not apply (no reverse button
/// to shorten, nothing verifiable to fold away) costs exactly zero — and a tie must resolve to the
/// earlier rung, which walking in order does and sorting would not reliably do.
/// The environment the header card puts every control on its row into.
///
/// Named and shared rather than left inline in `DifferencesView.body` because two things now depend
/// on it being exactly this. `HeaderLadder` prices the filter's funnel and the search magnifier at
/// `.body`, which is the font they inherit *from here* — neither names one — and `HeaderLadderTests`
/// has to render the row under the same environment for its measurements to mean anything. Restated
/// by hand in either place, both would keep agreeing with a header that had moved on.
struct HeaderCardChrome: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .tint(tint)
            // Match the top action bar's glass pills: capsule shape, the taller `.large` control
            // height, but the label font pinned to the top bar's ~13pt `.body` (otherwise `.large`
            // would scale the text up too). Result: same pill height AND same text size.
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .scaledFont(HeaderLadder.ambientFont)
    }
}

struct HeaderLadder {

    /// Everything about the header's contents that can change how wide a rung is, snapshotted once
    /// per render.
    ///
    /// A struct rather than a pile of parameters because that is what makes the arithmetic testable:
    /// `HeaderLadderTests` builds one of these, renders the row from the same values, and compares.
    struct Facts: Equatable {
        // State zone
        var differencesCount: Int
        /// The count pill's freshness run, and whether it wears its own inset capsule (which costs
        /// `DetailRunCapsule`'s horizontal padding).
        var detail: String?
        var detailIsCapsuled: Bool
        /// `CountPillChevron.symbol` — nil pre-scan, which is when the pill withholds the affordance.
        var chevronSymbol: String?
        /// The per-side totals, present only while the pill is expanded.
        var itemCountsText: String?

        // Scope zone
        var sectionCount: Int
        var filterName: String
        var isSelectionScoped: Bool

        // Action zone
        /// What the header acts on — the selection when one scopes it, else the whole filtered set.
        /// The selection chip and the Review button both count this, so it is one field.
        var targetCount: Int
        var verifiableCount: Int
        var copyToLeftCount: Int
        var copyToRightCount: Int
        var reverseIsMajority: Bool
        var leftName: String
        var rightName: String
        /// ⇧/⌘ held: every transfer button says "Move" instead of "Copy", which is wider.
        var isMove: Bool

        // View zone
        var showsCollapseToggle: Bool
    }

    /// Every control's laid-out width, measured once. Which controls a rung actually *draws* is the
    /// rung's business (`width(of:)`); this is just the price list.
    ///
    /// Measured once per ladder rather than per rung because the six rungs share most of their
    /// controls, and because a symbol measurement costs ~25µs — cheap once, not cheap six times over
    /// ten symbols on every layout pass.
    private struct Widths {
        var countPill: CGFloat = 0
        var itemCounts: CGFloat = 0
        var foldAll: CGFloat = 0
        var filterFull: CGFloat = 0
        var selectionChip: CGFloat = 0
        var verify: CGFloat = 0
        var review: CGFloat = 0
        /// The reverse transfer button with and without its destination name.
        var reverseNamed: CGFloat = 0
        var reverseBare: CGFloat = 0
        var primaryNamed: CGFloat = 0
        var primaryBare: CGFloat = 0
        var search: CGFloat = 0
        var collapse: CGFloat = 0
    }

    let facts: Facts
    private let widths: Widths

    // MARK: - The constants the row is built from

    /// `standardHeaderRow`'s `HStack(spacing:)`.
    static let itemGap: CGFloat = 10
    /// Its `Spacer(minLength:)` — a Spacer contributes exactly its minimum to a row's ideal width,
    /// which is what `ActionBarLadderTests` pins and what makes a rung's width finite at all.
    static let zoneGap: CGFloat = 16
    /// `foldAllToggle` and `collapseToggle` both pin their glyph to this square.
    static let glyphButtonSide: CGFloat = 24
    /// `filterMenu`'s label `HStack(spacing:)`, and `selectionChip`'s is one point tighter.
    static let filterLabelGap: CGFloat = 6
    static let selectionChipGap: CGFloat = 5
    /// The trailing chevron on the filter's full label, and the count pill's affordance.
    static let smallChevronFont: ScaledFont = .system(size: 9, weight: .semibold)
    /// The glyph size `foldAllToggle` and `collapseToggle` draw at.
    static let glyphFont: ScaledFont = .system(size: 12, weight: .semibold)
    /// The font the header card puts in the environment (`body`'s `.scaledFont(.body)`), which is
    /// what the filter's funnel and the search magnifier — neither of which names a font — inherit.
    static let ambientFont: ScaledFont = .body

    // MARK: - Measuring

    @MainActor
    init(facts: Facts, scale: CGFloat) {
        self.facts = facts
        self.widths = Self.measure(facts, scale: scale)
    }

    @MainActor
    private static func measure(_ facts: Facts, scale: CGFloat) -> Widths {
        var w = Widths()
        let bar = ActionBarMetrics.font

        w.countPill = countPillWidth(facts, scale: scale)

        if let text = facts.itemCountsText {
            // `.monospacedDigit()`, because `itemCountsReadout` applies it. Worth 0.37pt per digit at
            // caption size — 3pt across this readout's eight, which is small enough to hide behind a
            // three-figure fixture and is why the suite carries a four-figure one.
            w.itemCounts = LabelMetrics.width(of: text, font: ScaledFont.caption.monospacedDigit(),
                                              scale: scale)
        }

        w.foldAll = glyphButtonSide

        // The full filter label: funnel, name, chevron, at 6pt apart, inside an action-bar capsule.
        w.filterFull = LabelMetrics.actionBarWidth(labelWidth:
            LabelMetrics.symbolWidth("line.3.horizontal.decrease.circle", font: ambientFont, scale: scale)
            + filterLabelGap
            + LabelMetrics.width(of: facts.filterName, font: bar, scale: scale)
            + filterLabelGap
            + LabelMetrics.symbolWidth("chevron.down", font: smallChevronFont, scale: scale))

        if facts.isSelectionScoped {
            w.selectionChip = LabelMetrics.actionBarWidth(labelWidth:
                LabelMetrics.width(of: "\(facts.targetCount) selected", font: bar, scale: scale)
                + selectionChipGap
                + LabelMetrics.symbolWidth("xmark.circle.fill", font: bar, scale: scale))
        }

        if facts.verifiableCount > 0 {
            w.verify = LabelMetrics.actionBarWidth(labelWidth: LabelMetrics.labelWidth(
                "Verify \(facts.verifiableCount)", systemImage: "checkmark.shield",
                font: bar, scale: scale))
        }
        if facts.targetCount > 0 {
            // Plain interpolation, NOT `.formatted()` — `reviewTitle` writes "Review 1284" where the
            // count pill beside it writes "1,284". Matching the row matters more than being tidy: a
            // separator this priced and the button did not draw is 4pt per thousand, and this user's
            // comparisons run to five figures.
            w.review = LabelMetrics.actionBarWidth(labelWidth: LabelMetrics.labelWidth(
                "Review \(facts.targetCount)", systemImage: "checklist", font: bar, scale: scale))
        }

        if facts.copyToLeftCount > 0 {
            w.reverseNamed = transferWidth(count: facts.copyToLeftCount, destination: facts.leftName,
                                           toRight: false, facts: facts, scale: scale)
            w.reverseBare = transferWidth(count: facts.copyToLeftCount, destination: nil,
                                          toRight: false, facts: facts, scale: scale)
        }
        if facts.copyToRightCount > 0 {
            w.primaryNamed = transferWidth(count: facts.copyToRightCount, destination: facts.rightName,
                                           toRight: true, facts: facts, scale: scale)
            w.primaryBare = transferWidth(count: facts.copyToRightCount, destination: nil,
                                          toRight: true, facts: facts, scale: scale)
        }

        // `ExpandingSearchToggle` pads its glyph by 5 and pulls the padding straight back off, so its
        // footprint is the bare symbol at the ambient font.
        w.search = LabelMetrics.symbolWidth("magnifyingglass", font: ambientFont, scale: scale)
        // Priced unconditionally, like `foldAll`: whether a control is on the row is `width(of:)`'s
        // question, and a zero here would be a second place that has to agree with it.
        w.collapse = glyphButtonSide
        return w
    }

    /// `StatPill`'s semantic path: no leading icon (the flat fill drops it), then the count, the
    /// label, an optional divider-plus-age run, and an optional chevron — `Pill.contentSpacing`
    /// apart, inside `PillVariant.standard`'s horizontal padding.
    @MainActor
    private static func countPillWidth(_ facts: Facts, scale: CGFloat) -> CGFloat {
        let variant = PillVariant.standard
        var runs: [CGFloat] = [
            LabelMetrics.width(of: facts.differencesCount.formatted(),
                               font: variant.numberFont.monospacedDigit(), scale: scale),
            LabelMetrics.width(of: "Differences", font: variant.labelFont, scale: scale),
        ]
        if let detail = facts.detail {
            runs.append(detailDividerWidth)
            let text = LabelMetrics.width(of: detail,
                                          font: variant.labelFont.monospacedDigit(), scale: scale)
            runs.append(text + (facts.detailIsCapsuled ? 2 * detailCapsuleInset : 0))
        }
        if let chevron = facts.chevronSymbol {
            runs.append(LabelMetrics.symbolWidth(chevron, font: smallChevronFont, scale: scale))
        }
        return runs.reduce(0, +)
            + CGFloat(runs.count - 1) * Pill.contentSpacing
            + 2 * variant.horizontalPadding
    }

    /// The 1pt rule before the age run, and `DetailRunCapsule`'s horizontal padding around it.
    private static let detailDividerWidth: CGFloat = 1
    private static let detailCapsuleInset: CGFloat = 6

    @MainActor
    private static func transferWidth(count: Int, destination: String?, toRight: Bool,
                                      facts: Facts, scale: CGFloat) -> CGFloat {
        let title = BulkActionLabel.text(count: count, destination: destination, isMove: facts.isMove)
        let symbol = facts.isMove ? TransferGlyph.move(toRight: toRight) : TransferGlyph.copy(toRight: toRight)
        return LabelMetrics.actionBarWidth(labelWidth: LabelMetrics.labelWidth(
            title, systemImage: symbol, font: ActionBarMetrics.font, scale: scale))
    }

    // MARK: - Rung widths

    /// The ideal width of one rung — the number `ViewThatFits` used to discover by building it.
    ///
    /// Composed the same way the row is: a list of the controls this rung actually draws, summed with
    /// one `itemGap` between neighbours. Controls a rung omits are *dropped from the list*, not zeroed
    /// — an `HStack` charges no spacing for a child that resolves to nothing, so a zero-width entry
    /// would wrongly add a 10pt gap (`LabelMetrics` tests pin that behaviour).
    func width(of compaction: HeaderCompaction) -> CGFloat {
        var run: [CGFloat] = [widths.countPill]
        if facts.itemCountsText != nil { run.append(widths.itemCounts) }
        run.append(Self.dividerWidth)
        if FoldAllAction.isOffered(sectionCount: facts.sectionCount, compaction: compaction) {
            run.append(widths.foldAll)
        }
        run.append(compaction < .glyphFilter ? widths.filterFull : LabelMetrics.actionBarIconOnlyWidth)
        if facts.isSelectionScoped { run.append(widths.selectionChip) }
        run.append(Self.zoneGap)

        // The overflow exists only once the row has folded something into it — the same two
        // conditions `overflowMenu` itself checks, not a restatement of "compaction >= .foldVerify".
        let foldedReview = compaction >= .foldReview && facts.targetCount > 0
        let foldedVerify = compaction >= .foldVerify && facts.verifiableCount > 0
        if foldedReview || foldedVerify { run.append(LabelMetrics.actionBarIconOnlyWidth) }
        if compaction < .foldVerify, facts.verifiableCount > 0 { run.append(widths.verify) }
        if compaction < .foldReview, facts.targetCount > 0 { run.append(widths.review) }
        if facts.copyToLeftCount > 0 {
            run.append(BulkActionLabel.reverseNamesDestination(
                reverseIsMajority: facts.reverseIsMajority, compaction: compaction)
                ? widths.reverseNamed : widths.reverseBare)
        }
        if facts.copyToRightCount > 0 {
            run.append(BulkActionLabel.primaryNamesDestination(compaction: compaction)
                ? widths.primaryNamed : widths.primaryBare)
        }
        run.append(Self.dividerWidth)
        run.append(widths.search)
        if facts.showsCollapseToggle { run.append(widths.collapse) }

        return run.reduce(0, +) + CGFloat(run.count - 1) * Self.itemGap
    }

    /// `ActionBarDivider`'s hairline.
    private static let dividerWidth: CGFloat = 1

    // MARK: - Choosing a rung

    /// The narrowest rung, and the one every ladder ends at.
    var terminal: HeaderCompaction { DifferencesView.renderedCompactionLadder.last ?? .shortPrimary }

    /// The rung an offer of `width` gets: the first one that fits, which is exactly `ViewThatFits`'s
    /// own rule, and the narrowest when nothing does.
    ///
    /// Walked in `renderedCompactionLadder` order rather than sorted by width — see the type doc.
    func rung(fitting width: CGFloat) -> HeaderCompaction {
        for compaction in DifferencesView.renderedCompactionLadder
        where self.width(of: compaction) <= width {
            return compaction
        }
        return terminal
    }
}
