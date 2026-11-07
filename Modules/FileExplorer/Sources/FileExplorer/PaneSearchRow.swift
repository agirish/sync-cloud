import Design
import SwiftUI
import Sync

/// Everything one pane row draws differently because a search is running.
///
/// One value, not separate row properties, for `FileRowInfo`'s reason: every visible row is
/// compared on every render, and each property is one more comparison. The tree row and the column
/// row take the same value, so they can't drift about what a match looks like. `.none` is the
/// resting value, passed by every caller that knows nothing about search.
struct PaneSearchRowContext: Equatable {
    /// The matched run, as character offsets into the row's name. `nil` when this row is not a hit.
    var match: Range<Int>?
    /// Whether the row recedes: a search is running and neither this row nor anything under it
    /// matched.
    var isDimmed: Bool = false
    /// How many hits lie beneath this folder, drawn only while it is closed — see
    /// `showsContainedCount`.
    var containedMatchCount: Int = 0
    /// Whether the folder is showing its contents. A count on an open folder repeats the rows under
    /// it, and in Columns would sit on the folder you drilled through.
    var isExpanded: Bool = false
    /// Which side(s) this hit is on, or `nil` for a non-hit and on the single-source rail, which has
    /// no second tree.
    var side: PaneSearchSide?
    /// The type filter's pill for a closed folder ("2 images", "9 files"), or nil. Carried here so
    /// the row keeps one trailing slot with one precedence rule: a running search's count outranks it.
    var typeFilterPhrase: String?

    /// No search running.
    static let none = PaneSearchRowContext()

    /// Whether this row draws the “N matches” pill: a closed folder with hits inside it.
    var showsContainedCount: Bool { containedMatchCount > 0 && !isExpanded }

    /// What `PaneSearchAnnotation` says on this row, if anything: the count of matches inside a
    /// closed folder, else the type filter's pill on a closed folder, else which side(s) a hit is
    /// on. The row's gate and the annotation's label both read it, so they can't disagree.
    enum Annotation: Equatable {
        case containedMatches(Int)
        case typeFilterMatches(String)
        case bothSides
        case thisSideOnly
    }

    var annotation: Annotation? {
        if showsContainedCount { return .containedMatches(containedMatchCount) }
        if let typeFilterPhrase, !isExpanded { return .typeFilterMatches(typeFilterPhrase) }
        switch side {
        case .bothSides?: return .bothSides
        case .thisSideOnly?: return .thisSideOnly
        case nil: return nil
        }
    }

    /// Whether this row mounts the annotation at all, so a pane that is not searching pays for none.
    var hasAnnotation: Bool { annotation != nil }

    /// Builds the row's context from one pane's results. The caller supplies `isExpanded`, the one
    /// thing the presentations differ on: set membership in the tree, the browse path in Columns.
    init(results: PaneSearchResults, path: String, isExpanded: Bool) {
        self.match = results.match(forPath: path)
        self.isDimmed = results.isDimmed(path: path)
        self.containedMatchCount = results.containedMatchCount(forPath: path)
        self.isExpanded = isExpanded
        self.side = results.side(forPath: path)
    }

    /// A row of a pane with no search running, carrying only the type filter's pill.
    static func typeFilter(_ phrase: String?, isExpanded: Bool) -> PaneSearchRowContext {
        guard let phrase else { return .none }
        var context = PaneSearchRowContext()
        context.typeFilterPhrase = phrase
        context.isExpanded = isExpanded
        return context
    }

    private init() {}
}

// The reveal fires on the host's `revealNonce` (see `PaneSearchFieldState`), which moves only for a
// new query or ↩/⇧↩. Keyed on the results generation, it would re-fire on every republish of either
// tree and undo what the user did since.

/// How far a non-matching row recedes while a search is running.
///
/// It has to stay readable: this is a find, not a filter, and the tree's shape is the answer to
/// “where is this?”. The mockup's value.
enum PaneSearchDim {
    static let opacity: Double = 0.55
}

/// The row's name with its matched run emphasized.
///
/// Concatenated `Text`, not an `AttributedString`, so no row allocates one: this runs for every
/// visible row of the pane, the app's tightest render budget.
///
/// The range indexes the name as `PaneTreeSearch` found it; `NameDisplay.visibleName` substitutes
/// affix whitespace one character for one, so the offsets line up on the drawn form too.
struct PaneSearchName: View {
    let name: String
    let match: Range<Int>?
    let font: Font

    var body: some View {
        // The unmatched path must not pay for the matched one: every row of every pane comes here,
        // so only a hit builds the `[Character]` array.
        guard let match else { return Text(NameDisplay.visibleName(name)).font(font) }
        let display = Array(NameDisplay.visibleName(name))
        // Clamped: results come from the tree published when the query ran, rows from the tree
        // published since, so one republish between them can hand a range past the end, and
        // `display[..<match.lowerBound]` would trap and take the process with it.
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
/// Text, not glyphs: “left only” answers the question that usually prompted the search, where a
/// shape would need learning, and a bare count would read as one of the difference badges beside it.
struct PaneSearchAnnotation: View {
    let context: PaneSearchRowContext
    /// Which side this pane is, so a one-sided hit can name it (“left only”).
    let isLeft: Bool
    /// The opposite pane's display name. Never in the label, which must fit a narrow pane, but it
    /// makes the tooltip specific (“No item at this relative path in Dropbox”).
    let otherPaneName: String
    /// The pane's accent, passed rather than read from `.tint`: inside a `List` row, a tint that
    /// failed to propagate would fail silently, as whatever colour the label inherited.
    let accent: Color
    let fonts: PaneRowFonts
    /// The gap the label keeps from the name before it. Carried inside the label, so when
    /// `ViewThatFits` falls back to nothing, no strip of empty width is left in `FileRowView`'s
    /// zero-spaced row.
    var leadingGap: CGFloat = 0

    /// The label a one-sided hit carries. Non-private so `PaneSearchRowTests` can pin the side: the
    /// two panes must not both say “left only”.
    static func onlyHereLabel(isLeft: Bool) -> String { isLeft ? "left only" : "right only" }

    var body: some View {
        // Whole or not at all. The annotation yields width to the name, and a yielding `Text`
        // truncates rather than vanishing, which in a narrow pane leaves a bare "…" in the trailing
        // slot. So, like the pane header's ladder: the full label, or nothing.
        ViewThatFits(in: .horizontal) {
            label.padding(.leading, leadingGap)
            Color.clear.frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch context.annotation {
        case .containedMatches(let count)?:
            Text(count == 1 ? "1 match" : "\(count) matches")
                .font(fonts.countPill)
                .foregroundStyle(accent)
                .lineLimit(1)
                .help("\(count) match\(count == 1 ? "" : "es") inside — press ↩ to go there")
        case .typeFilterMatches(let phrase)?:
            Text(phrase)
                .font(fonts.countPill)
                .foregroundStyle(accent)
                .lineLimit(1)
                .help("\(phrase) inside, shown by the filter")
        case .bothSides?:
            Text("both sides")
                .font(fonts.countPill)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("\(otherPaneName) has an item at this relative path too")
        case .thisSideOnly?:
            // The one annotation tinted as a warning: the missing copy is usually why the user
            // searched, so it is the finding, not a footnote.
            Text(Self.onlyHereLabel(isLeft: isLeft))
                .font(fonts.countPill)
                .foregroundStyle(SemanticColor.warning)
                .lineLimit(1)
                .help("No item at this relative path in \(otherPaneName)")
        case nil:
            EmptyView()
        }
    }
}
