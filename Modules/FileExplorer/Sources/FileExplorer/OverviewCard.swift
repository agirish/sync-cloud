import SwiftUI
import Design

// MARK: - One verb on a card

/// A verb offered by an overview card.
///
/// No disabled state: while the work runs, a card swaps its status to a spinner and withdraws the
/// verb, so a greyed button would say the same thing twice. Unpressable verbs aren't offered.
///
/// A call site gives only the verb's rank; ``OverviewCard`` owns how it looks, so every verb on
/// the screen wears one of two dresses the eye can learn.
struct OverviewCardAction: Identifiable {

    /// At most one primary per card, and it is the rightmost control: where macOS puts a default
    /// button, and flush to the trailing padding, so every card's main verb sits on one vertical
    /// line down the page.
    enum Rank {
        case primary
        case secondary
    }

    let title: String
    var rank: Rank = .secondary
    /// The tooltip: what the click costs, where there is a cost worth stating.
    var help: String?
    /// VoiceOver's version, where the visible words are a bare verb that needs its object.
    var accessibilityLabel: String?
    let run: () -> Void

    var id: String { title }

    /// The order the buttons are drawn in: secondaries first, the primary last. A function, not an
    /// ordering inside the view's `ForEach`, so the rule can be asserted without mounting anything.
    /// Stable within a rank.
    static func drawingOrder(_ actions: [Self]) -> [Self] {
        actions.filter { $0.rank == .secondary } + actions.filter { $0.rank == .primary }
    }
}

// MARK: - What a card has to report

/// The badge at the end of a card's heading row. A card whose scan is in flight draws a spinner
/// rather than redrawing the last scan's number in confident bold.
enum OverviewCardStatus: Equatable {
    case none
    /// The mini pill in the count + unit shape: "53 findings".
    case count(Int, unit: String)
    /// The same pill over a headline that does not lead with its count.
    case text(String)
    /// A spinner and a word. Replaces the pill; never drawn beside it.
    case working(String)
}

/// Whether this card is reporting work or merely reporting. This is the accent's whole job on the
/// overview: "there is something here for you" is said by the glyph tile and the pill, not by a
/// coloured card that looks like it belongs to a different app.
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

/// The one card recipe on Organize's overview: a lens, what it has to say, and what you can do
/// about it. One anatomy, four slots, and call sites choose only what goes in them, so findings,
/// passes, receipts and the survey agree on surface, radius, where a verb goes and its look.
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
/// Every card wears `lensCard()`, the app's one card recipe. The tone changes the glyph tile and
/// the pill, and nothing else.
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
    /// The × that makes a notice go away, where there is one. Outside the action row and drawn
    /// before it: dismissal is not a verb and must not be mistaken for the primary, and after it
    /// would push the primary off the line every other card's lands on.
    var dismiss: OverviewCardDismiss?
    /// VoiceOver's summary of the card. Defaults to the title.
    var accessibilityLabel: String?
    @ViewBuilder var content: () -> Content

    /// The card's own inset. One number, so no card is a point wider inside than the one above it.
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
                // A title with a lede under it is a heading and set semibold; a title that is the
                // card's whole line is a sentence and set regular, since semibold news reads as a
                // shout. Decided by the subtitle, not a flag that would have to agree with it.
                Text(title)
                    .scaledFont(.system(size: subtitle == nil ? 11.5 : 12.5,
                                        weight: subtitle == nil ? .regular : .semibold))
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
            // Before the buttons, not at the trailing edge, so the primary stays flush to the
            // trailing padding on every card. A macOS alert orders them the same way: the way out
            // to the left of the default button.
            if let dismiss { dismissControl(dismiss) }
            actionRow
        }
    }

    private func dismissControl(_ dismiss: OverviewCardDismiss) -> some View {
        Button(action: dismiss.run) {
            Image(systemName: "xmark")
                .scaledFont(.system(size: 9))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .accessibilityLabel(dismiss.accessibilityLabel)
        .help(dismiss.help)
        .chromeHover()
        // Enough air that the cancel and the primary are not one target to a quick cursor.
        .padding(.trailing, 4)
    }

    /// The tinted square every row on this screen starts with. Accent when the card is reporting,
    /// quiet otherwise, and the only place the accent appears on a card.
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

    /// Secondaries, then the primary (``OverviewCardAction/drawingOrder(_:)``). One control size,
    /// `.fixedSize()` and one spacing for both ranks, so the row agrees about its height.
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
                Button(action.title, action: action.run).buttonStyle(.borderedProminent).accentedProminent()
            } else {
                Button(action.title, action: action.run).buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .chromeHover()
        .fixedSize()
        .accessibilityLabel(action.accessibilityLabel ?? action.title)
        // Conditional, not `.help(action.help ?? "")`: an empty help string still arms a tooltip,
        // which opens onto nothing.
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
        // `.secondary`, not `.tertiary`: this line states what a click costs, and tertiary is
        // barely legible grey.
        .foregroundStyle(.secondary)
        .padding(.horizontal, Self.padding)
        .padding(.vertical, 7)
    }
}

// MARK: - Dismissal

/// The × on a notice.
///
/// Its own type, not an ``OverviewCardAction``, because it isn't a verb: it makes the card go away
/// without doing what it asks. Ranked, it would sit in the row ending in the primary, and the
/// control nearest the main verb should never be the one that cancels the card.
struct OverviewCardDismiss {
    let accessibilityLabel: String
    let help: String
    let run: () -> Void
}
