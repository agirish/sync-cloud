import Design
import SwiftUI
import Sync

/// Everything one pane row draws differently because a search is running.
///
/// One value rather than four separate row properties, for the reason `FileRowInfo` is one value:
/// both presentations build a row per visible item on every render, and each property added to a row
/// is a property added to every row's comparison. It also means the tree row and the column row take
/// the *same* thing, so the two cannot drift about what a match looks like.
///
/// `.none` is the resting value and is what every caller that knows nothing about search passes, so
/// a pane with no query renders exactly the row it rendered before this existed.
struct PaneSearchRowContext: Equatable {
    /// The matched run, as character offsets into the row's name. `nil` when this row is not a hit.
    var match: Range<Int>?
    /// Whether the row recedes: a search is running and neither this row nor anything under it
    /// matched.
    var isDimmed: Bool = false
    /// How many hits lie beneath this folder, drawn only while it is closed — see
    /// `showsContainedCount`.
    var containedMatchCount: Int = 0
    /// Whether the folder is showing its contents. A count on an OPEN folder says nothing the rows
    /// under it are not already saying, and in Columns it would sit on the very folder you drilled
    /// through.
    var isExpanded: Bool = false
    /// Which side(s) this hit is on, or `nil` — for a non-hit, and on the single-source rail, where
    /// there is no second tree to be “only” with respect to.
    var side: PaneSearchSide?

    /// No search running.
    static let none = PaneSearchRowContext()

    /// Whether this row draws the “N matches” pill: a closed folder with hits inside it.
    var showsContainedCount: Bool { containedMatchCount > 0 && !isExpanded }

    /// Builds the row's context from one pane's results. The two presentations differ only in what
    /// “expanded” means — a `Set` membership in the tree, being on the browse path in Columns — so
    /// that is the one thing the caller supplies.
    init(results: PaneSearchResults, path: String, isExpanded: Bool) {
        self.match = results.match(forPath: path)
        self.isDimmed = results.isDimmed(path: path)
        self.containedMatchCount = results.containedMatchCount(forPath: path)
        self.isExpanded = isExpanded
        self.side = results.side(forPath: path)
    }

    private init() {}
}

// A `PaneSearchRevealToken` of (results generation, hit index) used to live here as the reveal's
// trigger. It is gone, and deliberately not resurrected: the generation moves on every republish
// of either tree, so the token re-fired the reveal — selection, scroll, Columns navigation — over
// whatever the user had done since the walk. The reveal now fires on the host's `revealNonce`
// (see `PaneSearchFieldState`), which moves only for a new query or ↩/⇧↩.

/// How far a non-matching row recedes while a search is running.
///
/// It has to stay READABLE. This is a find, not a filter: the tree's shape is the answer to “where
/// is this?”, and a dimming deep enough to make the surrounding rows unreadable would be a filter
/// drawn slowly. Matched to the mockup's own value.
enum PaneSearchDim {
    static let opacity: Double = 0.55
}

/// The row's name with its matched run emphasized.
///
/// Concatenated `Text` rather than an `AttributedString`: three `Text`s compose at draw time with no
/// per-row attributed-string allocation, and this runs for every visible row of a pane whose render
/// budget is the app's tightest.
///
/// The range indexes the name as `PaneTreeSearch` found it, and the label draws
/// `NameDisplay.visibleName`, which substitutes affix whitespace one character for one — so the
/// offsets line up on the marked form too. It is still clamped: the range and the string reach this
/// view from different places (results computed against the tree that was published when the query
/// ran, rows rendered from the tree published since), and one republish between them must not be
/// able to crash a pane.
struct PaneSearchName: View {
    let name: String
    let match: Range<Int>?
    let font: Font

    var body: some View {
        // **The unmatched path must not pay for the matched one.** This view replaced a bare
        // `Text(NameDisplay.visibleName(name))` on EVERY row of the pane — the app's tightest render
        // budget — and building the `[Character]` array unconditionally taxed every row of every
        // render with an allocation, including every pane that is not searching at all. The split
        // costs the highlighted rows nothing: there are at most a screenful of them.
        guard let match else { return Text(NameDisplay.visibleName(name)).font(font) }
        let display = Array(NameDisplay.visibleName(name))
        // Clamped: the range and the string reach this view from different places — results computed
        // against the tree published when the query ran, rows rendered from the tree published since
        // — so one republish between them hands it a range past the end. Without this
        // `display[..<match.lowerBound]` traps and takes the process with it.
        guard match.lowerBound >= 0, match.upperBound <= display.count, !match.isEmpty else {
            return Text(String(display)).font(font)
        }
        return (Text(String(display[..<match.lowerBound]))
            + Text(String(display[match])).bold()
            + Text(String(display[match.upperBound...])))
            .font(font)
    }
}

/// The trailing note a search puts on a row: which side(s) a hit is on, or how many matches are
/// hiding inside a closed folder.
///
/// Both are text rather than glyphs, deliberately. “left only” is the answer to the question that
/// usually prompted the search, and a shape would need learning; “2 matches” is a count, and a
/// count with no noun beside it reads as one of the difference badges it sits next to.
struct PaneSearchAnnotation: View {
    let context: PaneSearchRowContext
    /// Which side this pane is, so a one-sided hit can name it (“left only”).
    let isLeft: Bool
    /// The OPPOSITE pane's display name. It never appears in the label — “left only” is what the
    /// mockup says and what fits a pane this narrow — but it is what makes the tooltip specific
    /// (“No item at this relative path in Dropbox”), which is the sentence the label is short for.
    let otherPaneName: String
    /// The pane's accent, passed rather than read from `.tint`: this text sits inside a `List` row,
    /// and a tint that failed to propagate through the row host would fail silently, as the colour
    /// the label happened to inherit.
    let accent: Color
    let fonts: PaneRowFonts

    /// The label a one-sided hit carries. Named and non-private so `PaneSearchRowTests` pins the
    /// side rather than the sentence — the two panes must not both say “left only”.
    static func onlyHereLabel(isLeft: Bool) -> String { isLeft ? "left only" : "right only" }

    var body: some View {
        // **Show it whole or not at all.** The annotation yields width to the name (the row's
        // identity anchor, the same rule the pane header applies to the provider capsule), and a
        // `Text` that yields does not vanish — it truncates. Measured at the 250pt pane clamp with a
        // 60-character filename, that left a bare "…" in the trailing slot: a glyph with no meaning,
        // whose tooltip nobody will find. The degradation ladder the header uses is the right shape
        // here too — the full label, or nothing.
        ViewThatFits(in: .horizontal) {
            label
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private var label: some View {
        if context.showsContainedCount {
            Text(context.containedMatchCount == 1 ? "1 match" : "\(context.containedMatchCount) matches")
                .font(fonts.countPill)
                .foregroundStyle(accent)
                .lineLimit(1)
                .help("\(context.containedMatchCount) match\(context.containedMatchCount == 1 ? "" : "es") inside — press ↩ to go there")
        } else if let side = context.side {
            switch side {
            case .bothSides:
                Text("both sides")
                    .font(fonts.countPill)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("\(otherPaneName) has an item at this relative path too")
            case .thisSideOnly:
                // The one annotation that carries a tint. “Where is the copy that ISN'T here” is
                // usually the reason for searching at all, so it is the finding, not the footnote.
                Text(Self.onlyHereLabel(isLeft: isLeft))
                    .font(fonts.countPill)
                    .foregroundStyle(SemanticColor.warning)
                    .lineLimit(1)
                    .help("No item at this relative path in \(otherPaneName)")
            }
        }
    }
}
