import SwiftUI
import Design

// MARK: - One verb on a card

/// A verb offered by an overview card.
///
/// **Rank, not style.** Every call site used to pick its own button dress, and the screen ended up
/// with three: `.borderedProminent` on a pass card's run, `.bordered` on a finding's rescan, and a
/// bare accent `Text` masquerading as a link on the receipts. Three dresses for one kind of thing —
/// "press this and something happens" — and the eye had no way to learn which was which. Here a
/// call site says only how important the verb is; ``OverviewCard`` owns what that looks like.
struct OverviewCardAction: Identifiable {

    /// **At most one primary per card, and it is the rightmost control.**
    ///
    /// Rightmost because that is where macOS puts a default button and where the eye lands last,
    /// and — the reason this screen needed the rule — because a primary flush against the card's
    /// trailing padding puts every card's main verb on **one vertical line down the page**. The
    /// complaint that started this redesign was literally that: a Refresh at a card's top-right, a
    /// Refresh buried under a finding's examples, and a run button somewhere between them.
    enum Rank {
        case primary
        case secondary
    }

    let title: String
    var rank: Rank = .secondary
    /// Drawn, but inert — a verb whose work is already running says so by staying in place rather
    /// than vanishing, which is how the header's own scan buttons behave.
    var isDisabled = false
    /// The tooltip: what the click costs, where there is a cost worth stating.
    var help: String?
    /// VoiceOver's version, where the visible words are a bare verb that needs its object.
    var accessibilityLabel: String?
    let run: () -> Void

    var id: String { title }

    /// The order the buttons are drawn in: secondaries first, the primary last.
    ///
    /// A function rather than an ordering baked into the view's `ForEach`, so the rule can be
    /// asserted without mounting anything — the same seam ``OrganizeOverview/offersRescan(for:)``
    /// cut for the same reason. It is stable within a rank, so two secondaries keep the order the
    /// card listed them in.
    static func drawingOrder(_ actions: [Self]) -> [Self] {
        actions.filter { $0.rank == .secondary } + actions.filter { $0.rank == .primary }
    }
}

// MARK: - What a card has to report

/// The badge at the end of a card's heading row.
///
/// One of four, and the distinction between the last two is the one this screen has always been
/// careful about: a card whose scan is in flight draws a spinner rather than redrawing last scan's
/// number in confident bold.
enum OverviewCardStatus: Equatable {
    case none
    /// The C1 mini pill in the count + unit shape — "53 findings".
    case count(Int, unit: String)
    /// The same pill over a headline that does not lead with its count.
    case text(String)
    /// A spinner and a word. Replaces the pill; never drawn beside it.
    case working(String)
}

/// Whether this card is reporting work or merely reporting.
///
/// **This is the whole of the accent's job on the overview now.** A findings card used to be a
/// tinted slab with an accent bar down its leading edge while everything around it was grey, so
/// one card in six looked like it belonged to a different app. The signal it was carrying is real
/// — *there is something here for you* — but it costs a glyph tile and a pill to say, not a
/// coloured card.
enum OverviewCardTone {
    case reporting
    case quiet
}

/// The line under a card's rule: what the click costs, or where the answer came from.
struct OverviewCardNote {
    var symbol: String?
    let text: String
    /// Opens Help at whatever this line points to. nil draws no question mark.
    var help: (() -> Void)?
    var helpLabel: String?
    var helpTip: String?

    init(_ text: String, symbol: String? = nil, help: (() -> Void)? = nil,
         helpLabel: String? = nil, helpTip: String? = nil) {
        self.text = text
        self.symbol = symbol
        self.help = help
        self.helpLabel = helpLabel
        self.helpTip = helpTip
    }
}

// MARK: - The card

/// **The one card recipe on Organize's overview**, and the answer to a screen that had grown five.
///
/// What was there before this: a findings card (accent wash, accent stripe, buttons under the
/// examples), a pass card (grey well, prominent button top-right, two dividers), a receipt card
/// (grey well, two link-buttons top-right, no rule), the document survey's card (grey well, one
/// link-button, one rule) and — for Storage before it has ever run — no card at all, just a line of
/// tertiary grey text in the footer. Five anatomies describing one kind of thing: *a lens, what it
/// has to say, and what you can do about it*. They disagreed about the surface, the corner radius,
/// where a verb goes, what a verb looks like, whether there is a rule above the small print, and
/// how tall the whole thing is.
///
/// So: one anatomy, four slots, and the call sites choose only what goes in them.
///
/// ```
/// ┌───────────────────────────────────────────────────────────────┐
/// │ ▣  Title                            [status]  [second] [MAIN] │  heading
/// │    Subtitle                                                   │
/// │    content()                                                  │  body, on the title's spine
/// ├───────────────────────────────────────────────────────────────┤
/// │ 🔒 note                                                       │  small print
/// └───────────────────────────────────────────────────────────────┘
/// ```
///
/// **Every card wears `lensCard()`** — the app's one card recipe (C2), which the rest of the app's
/// lenses have used all along while this screen hand-rolled `.quaternary.opacity(0.35)` wells at a
/// different radius. The tone changes the glyph tile and the pill, and nothing else.
///
/// The body slot is inset to the title's leading edge rather than the card's, so the examples under
/// a finding, the lens rows under a pass and the progress bar under the survey all hang off one
/// spine that runs the length of the page.
struct OverviewCard<Content: View>: View {

    let symbol: String
    let title: String
    var subtitle: String?
    var tone: OverviewCardTone = .quiet
    let accent: Color
    var status: OverviewCardStatus = .none
    var actions: [OverviewCardAction] = []
    var note: OverviewCardNote?
    /// VoiceOver's summary of the card. Defaults to the title.
    var accessibilityLabel: String?
    @ViewBuilder var content: () -> Content

    /// The card's own inset. One number, so a card cannot be a point wider inside than the one
    /// above it — which two of the five previously were (11 against 10).
    static var padding: CGFloat { 11 }
    /// The glyph tile, and therefore the offset of the text spine: 21 + 9.
    static var glyphSize: CGFloat { 21 }
    static var glyphGap: CGFloat { 9 }
    static var contentInset: CGFloat { glyphSize + glyphGap }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                heading
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Self.contentInset)
            }
            .padding(Self.padding)

            if let note {
                Divider()
                noteLine(note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lensCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel ?? title)
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: Self.glyphGap) {
            glyph
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scaledFont(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            statusView
            actionRow
        }
    }

    /// The tinted square every row on this screen starts with. Accent when the card is reporting,
    /// quiet otherwise — one glyph, two inks, and the only place the accent survives on a card.
    private var glyph: some View {
        Image(systemName: symbol)
            .scaledFont(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone == .reporting ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            .frame(width: Self.glyphSize, height: Self.glyphSize)
            .background(RoundedRectangle(cornerRadius: Radius.chip)
                .fill(tone == .reporting ? AnyShapeStyle(accent.opacity(0.14))
                                         : AnyShapeStyle(.quaternary.opacity(0.5))))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .none:
            EmptyView()
        case .count(let n, let unit):
            Pill(.mini, tint: accent, count: n, label: unit)
        case .text(let text):
            Pill(.mini, tint: accent, text: text)
        case .working(let word):
            HStack(spacing: 5) {
                InlineSpinner()
                Text(word)
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
        }
    }

    /// Secondaries, then the primary — see ``OverviewCardAction/drawingOrder(_:)``.
    ///
    /// `.small` on both, `.fixedSize()` on both, one spacing: a row of controls that agree about
    /// their height is the difference between a card and a collage.
    @ViewBuilder
    private var actionRow: some View {
        let ordered = OverviewCardAction.drawingOrder(actions)
        if !ordered.isEmpty {
            HStack(spacing: 6) {
                ForEach(ordered) { action in
                    button(action)
                }
            }
        }
    }

    @ViewBuilder
    private func button(_ action: OverviewCardAction) -> some View {
        let shaped = Group {
            if action.rank == .primary {
                Button(action.title, action: action.run).buttonStyle(.borderedProminent)
            } else {
                Button(action.title, action: action.run).buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .chromeHover()
        .fixedSize()
        .disabled(action.isDisabled)
        .accessibilityLabel(action.accessibilityLabel ?? action.title)
        // Conditional rather than `.help(action.help ?? "")`: an empty help string still arms a
        // tooltip, and a tooltip that opens onto nothing reads as a rendering fault.
        if let help = action.help {
            shaped.help(help)
        } else {
            shaped
        }
    }

    private func noteLine(_ note: OverviewCardNote) -> some View {
        HStack(spacing: 5) {
            if let symbol = note.symbol {
                Image(systemName: symbol)
                    .scaledFont(.system(size: 9))
                    .accessibilityHidden(true)
            }
            Text(note.text)
                .scaledFont(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            if let help = note.help {
                Button(action: help) {
                    Image(systemName: "questionmark.circle")
                        .scaledFont(.system(size: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(note.helpLabel ?? "More about this")
                .help(note.helpTip ?? "What this line is about.")
                .chromeHover()
            }
            Spacer(minLength: 0)
        }
        // `.secondary`, not `.tertiary`. This is the line stating what a click costs, and rendering
        // it a shade quieter read back as barely legible grey — the weight a footnote gets, not the
        // weight a cost disclosure deserves.
        .foregroundStyle(.secondary)
        .padding(.horizontal, Self.padding)
        .padding(.vertical, 7)
    }
}

// MARK: - The quiet row

/// A row that is **not** a card: news, or an offer about where to look next.
///
/// Kept deliberately distinct from ``OverviewCard`` — a nudge about the new year and a shortcut to
/// the inbox are not lenses and must not read as one — but aligned to it, which is the part that
/// was missing. Same glyph tile, same 11pt inset, same text spine, one step quieter in surface. The
/// eye follows one column down the whole page instead of two.
struct OverviewQuietRow<Label: View, Trailing: View>: View {
    let symbol: String
    let accent: Color
    /// Whether the glyph takes the accent — an offer you can act on does, a piece of news does not.
    var tinted: Bool = false
    @ViewBuilder var label: () -> Label
    @ViewBuilder var trailing: () -> Trailing

    /// The same geometry the cards use, read off the card rather than restated — a second copy of
    /// `21` and `9` here is exactly how the two columns drifted apart the first time.
    private typealias Metrics = OverviewCard<EmptyView>

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.glyphGap) {
            Image(systemName: symbol)
                .scaledFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(tinted ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                .frame(width: Metrics.glyphSize, height: Metrics.glyphSize)
                .background(RoundedRectangle(cornerRadius: Radius.chip)
                    .fill(tinted ? AnyShapeStyle(accent.opacity(0.14))
                                 : AnyShapeStyle(.quaternary.opacity(0.5))))
                .accessibilityHidden(true)
            label()
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.well).fill(.quaternary.opacity(0.35)))
    }
}
