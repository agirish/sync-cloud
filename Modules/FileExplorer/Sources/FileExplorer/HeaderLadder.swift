import Design
import SwiftUI

/// The environment the header card puts every control on its row into.
///
/// Shared rather than inline in `DifferencesView.body`, because `HeaderLadder` prices the filter's
/// funnel and the search magnifier at the font they inherit from here, and `HeaderLadderTests`
/// renders the row under the same environment. A hand-restated copy would drift from the header.
///
/// No tint of its own: the row's buttons take theirs from `.actionBar(…, tint:)` and
/// `.accentedProminent()`, and a raw accent here would only reach native controls, drawing them in
/// the raw shade over the window root's deepened one (`nativeControlAccent`).
struct HeaderCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Match the top action bar's glass pills: capsule, the taller `.large` height, and the
            // font pinned to the top bar's ~13pt `.body`, which `.large` would otherwise scale up.
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .scaledFont(HeaderLadder.ambientFont)
    }
}

/// The differences header's shedding ladder: how wide each `HeaderCompaction` rung is, and which one
/// a given offered width gets.
///
/// Arithmetic rather than a six-child `ViewThatFits`, which **builds every child to measure it**: a
/// rung here is a whole toolbar, two of its `Menu`s build their content eagerly, and `body`
/// re-evaluates once per copied file during a bulk sync. `ViewThatFits` gets two children, so the
/// layout engine keeps the final say. `PaneHeader.navCluster` uses the same fix.
///
/// Unlike `PaneBarLadder`, which sums glyph-pill constants, this bar is mostly text, so widths come
/// from `Design.LabelMetrics`. Each figure uses the drawing view's own published constants
/// (`ActionBarMetrics`, `PillVariant`), and `HeaderLadderTests` pins each against the drawn row.
///
/// **The ladder is walked in declaration order, not sorted by width**, because that is
/// `ViewThatFits`'s own rule. This ladder never widens as it sheds
/// (`HeaderLadderTests.theLadderNeverWidensAsItSheds`), but it has ties: a rung whose concession
/// doesn't apply costs zero, and a tie must resolve to the earlier rung, which sorting wouldn't
/// reliably do.
struct HeaderLadder {

    /// Everything about the header's contents that can change a rung's width, snapshotted once per
    /// render. A struct so `HeaderLadderTests` can build one, render the row from the same values,
    /// and compare.
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
        /// `DifferenceActionTargets.heldText` — "2 need your decision" — or nil when nothing is held.
        var heldText: String? = nil
        var reverseIsMajority: Bool
        var leftName: String
        var rightName: String
        /// ⇧/⌘ held: every transfer button says "Move" instead of "Copy", which is wider.
        var isMove: Bool

        // View zone
        var showsCollapseToggle: Bool

        /// The room the host's status pill takes after the count (one-way sync's): its widest,
        /// which the drawn pill is capped at. Zero without one.
        var accessoryWidth: CGFloat = 0
    }

    /// Every control's laid-out width: the price list. Which controls a rung draws is `width(of:)`'s
    /// business. Measured once per ladder, not per rung, because the rungs share most controls and
    /// a symbol measurement costs ~25µs.
    private struct Widths {
        var countPill: CGFloat = 0
        var itemCounts: CGFloat = 0
        var held: CGFloat = 0
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
    }

    let facts: Facts
    private let widths: Widths

    // MARK: - The constants the row is built from

    /// `standardHeaderRow`'s `HStack(spacing:)`.
    static let itemGap: CGFloat = 10
    /// Its `Spacer(minLength:)`. A Spacer adds exactly its minimum to a row's ideal width
    /// (`ActionBarLadderTests` pins it), which is what makes a rung's width finite.
    static let zoneGap: CGFloat = 16
    /// `foldAllToggle` and `collapseToggle` both pin their glyph to this square. Read directly in
    /// `width(of:)`, not cached in `Widths`, which holds only what must be measured.
    ///
    /// The glyph's point size plays no part: a `.frame(width:)` is its width whatever it holds, so
    /// these are the only controls on the row that don't grow with the font scale
    /// (`everyRungMeasuresWhatItDrawsAtOtherFontScales`).
    static let glyphButtonSide: CGFloat = 24
    /// `filterMenu`'s label `HStack(spacing:)`, and `selectionChip`'s is one point tighter.
    static let filterLabelGap: CGFloat = 6
    static let selectionChipGap: CGFloat = 5
    /// The trailing chevron on the filter's full label, and the count pill's affordance.
    static let smallChevronFont: ScaledFont = .system(size: 9, weight: .semibold)
    /// The font `HeaderCardChrome` puts in the environment, which the filter's funnel and the search
    /// magnifier inherit because neither names one.
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
            // caption size, too little for a three-figure fixture to show, so the suite has a
            // four-figure one.
            w.itemCounts = LabelMetrics.width(of: text, font: ScaledFont.caption.monospacedDigit(),
                                              scale: scale)
        }

        if let text = facts.heldText {
            w.held = LabelMetrics.width(of: text, font: .caption, scale: scale)
        }

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
            // Plain interpolation, not `.formatted()`, because `reviewTitle` writes "Review 1284"
            // (the count pill writes "1,284"). A separator priced here but not drawn would be 4pt
            // too wide per thousand.
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

    /// The ideal width of one rung, without building it.
    ///
    /// Composed like the row: the controls this rung draws, with one `itemGap` between neighbours.
    /// Omitted controls are dropped from the list, not zeroed: an `HStack` charges no spacing for a
    /// child that resolves to nothing, so a zero entry would add a stray 10pt gap (`LabelMetrics`
    /// tests pin that).
    func width(of compaction: HeaderCompaction) -> CGFloat {
        var run: [CGFloat] = [widths.countPill]
        if facts.itemCountsText != nil { run.append(widths.itemCounts) }
        if facts.accessoryWidth > 0 { run.append(facts.accessoryWidth) }
        run.append(Self.dividerWidth)
        if FoldAllAction.isOffered(sectionCount: facts.sectionCount, compaction: compaction) {
            run.append(Self.glyphButtonSide)
        }
        run.append(compaction < .glyphFilter ? widths.filterFull : LabelMetrics.actionBarIconOnlyWidth)
        if facts.isSelectionScoped { run.append(widths.selectionChip) }
        run.append(Self.zoneGap)

        // The overflow exists only once the row has folded something into it: the same two
        // conditions `overflowMenu` checks, not just "compaction >= .foldVerify".
        let foldedReview = compaction >= .foldReview && facts.targetCount > 0
        let foldedVerify = compaction >= .foldVerify && facts.verifiableCount > 0
        if foldedReview || foldedVerify { run.append(LabelMetrics.actionBarIconOnlyWidth) }
        if compaction < .foldVerify, facts.verifiableCount > 0 { run.append(widths.verify) }
        if compaction < .foldReview, facts.targetCount > 0 { run.append(widths.review) }
        if facts.heldText != nil { run.append(widths.held) }
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
        if facts.showsCollapseToggle { run.append(Self.glyphButtonSide) }

        return run.reduce(0, +) + CGFloat(run.count - 1) * Self.itemGap
    }

    /// `ActionBarDivider`'s hairline.
    private static let dividerWidth: CGFloat = 1

    // MARK: - Choosing a rung

    /// The narrowest rung, and the one every ladder ends at.
    var terminal: HeaderCompaction { DifferencesView.renderedCompactionLadder.last ?? .shortPrimary }

    /// The rung an offer of `width` gets: the first that fits, `ViewThatFits`'s own rule, or the
    /// narrowest when nothing does. Walked in `renderedCompactionLadder` order, not sorted by width
    /// (see the type doc).
    func rung(fitting width: CGFloat) -> HeaderCompaction {
        for compaction in DifferencesView.renderedCompactionLadder
        where self.width(of: compaction) <= width {
            return compaction
        }
        return terminal
    }
}
