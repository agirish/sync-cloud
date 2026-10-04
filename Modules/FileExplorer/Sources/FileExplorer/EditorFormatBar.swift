import SwiftUI
import AppKit
import Design
import Events

/// What the format bar shows lit, for one selection in one buffer (TE52).
///
/// **Derived off the main actor, on the caret's debounce** — see `EditorWorkspaceView`'s format
/// task. Every answer walks the lines the selection touches, and a body pass happens on every
/// keystroke; storing the cheap thing (the selection) and paying for this on a debounce is the trade
/// ``EditorCaret`` already makes for the status line.
struct MarkupFormatState: Equatable, Sendable {
    /// The verbs whose press would take their formatting off — ``MarkdownEdits/isApplied(_:in:selection:)``.
    var lit: Set<MarkupVerb>
    /// What the Heading menu names.
    var heading: MarkdownEdits.HeadingLevel

    static let none = MarkupFormatState(lit: [], heading: .body)

    /// Every verb asked about one selection, over ONE bridge of the buffer and ONE walk of the
    /// lines the selection touches — the verbs' own tests, handed what they would each have found.
    static func of(_ text: String, selection: NSRange) -> MarkupFormatState {
        let ns = text as NSString
        guard MarkdownEdits.isValid(selection, in: ns) else { return .none }
        let lines = MarkdownEdits.lineRanges(covering: selection, in: ns)
        return MarkupFormatState(
            lit: Set(MarkupVerb.menuOrder.compactMap { $0 }.filter {
                MarkdownEdits.isApplied($0, ns, selection, lines: lines)
            }),
            heading: MarkdownEdits.headingLevel(ns, selection, lines: lines))
    }
}

/// The document's text view, for the controls drawn beside it rather than inside it.
///
/// **A weak reference handed down to `PlainTextEditor`, not a request token handed down to it.**
/// The header's Find button can be a counter the text view answers in `updateNSView`, because
/// opening a find bar writes no SwiftUI state. A verb does — it edits the buffer, which publishes
/// the text — and a write made from inside an update pass is the one SwiftUI warns about. A handle
/// lets the bar's button act in its own action, outside any update, on the view that is there.
@MainActor
final class EditorTextViewHandle {
    weak var textView: NSTextView?

    /// **The Markup menu's verb, run exactly as the menu runs it** — through
    /// ``EditorDocumentSurface/applyMarkup(_:in:)``, and so through `PlainTextEditor.apply`, the one
    /// implementation every door into the verbs shares.
    ///
    /// **Except that the caret is put back first.** The menu refuses when the caret is not in the
    /// document's text, because a KEY pressed in the Go-to field or the find bar's own field is
    /// ambiguous about which text it means. A click on this bar is not: the bar sits on the text it
    /// formats. So if the click, or anything before it, took the first responder away, the text view
    /// takes it back — keeping the selection it had, which `NSTextView` holds across a resign — and
    /// the menu's own function then finds the caret where it expects it. That is also what keeps a
    /// click from leaving the caret anywhere but the text.
    @discardableResult
    func applyMarkup(_ verb: MarkupVerb) -> Bool {
        guard let view = textView, let window = view.window, view.isEditable else {
            Logger.shared.info("Format bar ▸ \(verb.title) ignored: no writable text view on screen")
            return false
        }
        if window.firstResponder !== view {
            // Said, because it is the one place the bar does what the menu would not: the menu
            // refuses a KEY pressed with the caret in a field; a click on this bar is aimed at the
            // text under it. Naming what held the caret makes a surprised reader's log useful.
            let holder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing"
            window.makeFirstResponder(view)
            Logger.shared.info("Format bar ▸ \(verb.title): the caret was in \(holder) — put back in the document first")
        }
        guard EditorDocumentSurface.applyMarkup(verb, in: window) else {
            Logger.shared.info("Format bar ▸ \(verb.title) ignored: the text view would not take the caret")
            return false
        }
        return true
    }
}

/// **The format bar: the Markup menu's verbs as buttons, above a Markdown document's source**
/// (TE52, decision L = A — a persistent strip, not a bar over the selection).
///
/// **In the text card, not the header.** The header is pinned to `LiquidGlass.headerHeight` so it
/// shares its bottom edge with the pane's toolbar card; a row added there would break that. Here
/// the card simply starts with the bar and the text starts under it — and in Split the bar spans the
/// Source half alone, because that is the half it acts on.
///
/// **The menu's verbs, in the menu's groups, with one move.** Headings lead, folded into one menu
/// that names the level the caret is at, because four buttons reading H1 H2 H3 ¶ would be the
/// widest group for the least-pressed verbs, and a heading is the first thing a writer sets on a
/// line. Every other group keeps its place and its order — ``groups`` derives all of it from
/// ``MarkupVerb/menuOrder``, so the bar cannot gain or lose a verb the menu does not.
///
/// **It sheds from the end when it is narrow** — see ``ladder``.
///
/// **`Equatable`, and wrapped in `.equatable()` by its host**, because the host is the view a
/// keystroke redraws (`EditorWorkspaceView` observes the buffer), and without it every keystroke
/// rebuilt and re-measured all six rungs of a bar whose look had not changed.
struct EditorFormatBar: View, Equatable {

    let state: MarkupFormatState
    let accent: Color
    /// The press. The host routes it through ``EditorTextViewHandle/applyMarkup(_:)``.
    let onVerb: (MarkupVerb) -> Void
    /// Forces a rung. `nil` picks by width; the fit test forces each in turn, the way
    /// ``EditorModeBar/forcedRung`` lets its tests ask for one rung rather than provoke it.
    let forcedRung: Rung?

    @Environment(\.appFontScale) private var scale

    init(state: MarkupFormatState, accent: Color, onVerb: @escaping (MarkupVerb) -> Void,
         forcedRung: Rung? = nil) {
        self.state = state
        self.accent = accent
        self.onVerb = onVerb
        self.forcedRung = forcedRung
    }

    /// Compared on everything it DRAWS. **The closure is the one member left out**, as
    /// `PageStrip`'s is: a closure cannot be compared, and this one is written at the single call
    /// site over the host's `@State` handle, which does not move. `nonisolated`, because
    /// `Equatable` is; every member read is an immutable `let` of a `Sendable` type.
    nonisolated static func == (lhs: EditorFormatBar, rhs: EditorFormatBar) -> Bool {
        lhs.state == rhs.state && lhs.accent == rhs.accent && lhs.forcedRung == rhs.forcedRung
    }

    // MARK: - What it holds

    /// The Markup menu's groups — ``MarkupVerb/menuOrder`` cut at its separators. Derived once:
    /// the list is a constant, and the bar asks for it in every rung it lays out.
    static let menuGroups: [[MarkupVerb]] =
        MarkupVerb.menuOrder.split(separator: nil).map { $0.compactMap { $0 } }

    /// The menu's heading group: Heading 1–3 and Body. The bar draws it as one menu.
    static let headingVerbs: [MarkupVerb] = menuGroups.first { $0.allSatisfy { isHeading($0) } } ?? []

    /// The menu's other groups, in the menu's order — what the bar draws as buttons, after the
    /// Heading menu: the inline five, the four line kinds, the two blocks.
    static let groups: [[MarkupVerb]] = menuGroups.filter { !$0.allSatisfy { isHeading($0) } }

    /// The bar's whole reading order, headings first — what the parity test holds against the menu.
    static var barOrder: [MarkupVerb] { headingVerbs + groups.flatMap { $0 } }

    private nonisolated static func isHeading(_ verb: MarkupVerb) -> Bool {
        if case .heading = verb { return true }
        return false
    }

    /// Each button's glyph. **Every name is checked against the system** by
    /// `EditorFormatBarTests.everyGlyphIsASymbolTheSystemHas` — a misspelt symbol draws nothing and
    /// fails nothing.
    static func symbol(_ verb: MarkupVerb) -> String {
        switch verb {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .inlineCode: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .heading: return "textformat.size"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .taskItem: return "checklist"
        case .blockQuote: return "text.quote"
        case .codeBlock: return "curlybraces.square"
        case .horizontalRule: return "minus"
        }
    }

    /// The overflow menu's glyph — the » the hidden verbs sit behind.
    static let overflowSymbol = "chevron.right.2"

    /// **Whether a verb can ever be lit** — the ones whose press can take formatting off. Link, Code
    /// Block and Horizontal Rule only insert, and Body only removes, so ``MarkdownEdits/isApplied(_:in:selection:)``
    /// never answers yes for them; in a menu they are plain items, not toggles that are always off.
    static func canLight(_ verb: MarkupVerb) -> Bool {
        switch verb {
        case .link, .codeBlock, .horizontalRule, .heading(0): return false
        default: return true
        }
    }

    /// **What a button says under the pointer: the verb's name, and its chord where it has one** —
    /// the chord from `AppChord.display` by way of ``MarkupVerb/chord``, the value the menu bar
    /// registers, so a tooltip cannot advertise a key the menu does not answer.
    static func tooltip(_ verb: MarkupVerb) -> String {
        guard let chord = verb.chord else { return verb.title }
        return ShortcutHint.tooltip(verb.title, chord.display)
    }

    /// What the Heading menu's label reads.
    static func headingTitle(_ heading: MarkdownEdits.HeadingLevel, worded: Bool) -> String {
        switch heading {
        case .level(let level): return worded ? "Heading \(level)" : "H\(level)"
        case .otherHeading: return worded ? "Heading" : "H"
        case .mixed: return worded ? "Mixed" : "–"
        case .body: return worded ? "Body" : "¶"
        }
    }

    /// Every label the Heading menu can show, so it is laid out at the widest and does not move the
    /// buttons after it as the caret crosses from a heading into body text.
    private static func headingTitles(worded: Bool) -> [String] {
        ([.body, .mixed, .otherHeading] + (1...3).map { .level($0) }).map { headingTitle($0, worded: worded) }
    }

    // MARK: - Where it is drawn

    /// **Shown only where a verb can do what it says:** a writable Markdown document, open (not
    /// refused), in Source or Split, with Text ▸ Format Bar on. Preview has no text view to act on;
    /// plain text has no Markdown for the verbs to write (the Markup menu still offers them there,
    /// but a strip of formatting buttons above a `.txt` would claim the file has formatting); a
    /// read-only file withholds the verbs everywhere, its Markup menu and context menu included.
    ///
    /// The UNRESOLVED mode, resolved here: `EditorMode.resolved` narrows any mode to Source on a
    /// plain-text file, and asking the resolved one here alone would leave that narrowing to the
    /// caller to remember.
    static func isShown(preference: Bool, hasDocument: Bool, isRefused: Bool, isMarkdown: Bool,
                        isReadOnly: Bool, mode: EditorMode) -> Bool {
        preference && hasDocument && !isRefused && isMarkdown && !isReadOnly
            && EditorMode.resolved(mode, isMarkdown: isMarkdown) != .preview
    }

    // MARK: - Narrow widths

    /// One way of drawing the bar: whether the Heading menu wears its word, and how many of the
    /// buttons — counted along ``groups`` flattened — stay on the bar. The rest go behind the ».
    struct Rung: Equatable, Sendable {
        var headingWorded: Bool
        var visible: Int
    }

    /// **The degrade order, widest first.** `ViewThatFits` draws the first rung that fits.
    ///
    /// Trailing groups go first, whole — the two blocks, then the four line kinds — because they are
    /// the least pressed and because a group split across the » reads as a mistake. Then the Heading
    /// menu's word shortens ("Heading 2" → "H2"), then the inline group sheds Code and Link, and last
    /// of all everything but the Heading menu goes behind the ». The inline five outlast the line
    /// kinds because three of them carry the chords somebody is most likely to be looking up.
    ///
    /// **Pinned by measurement**: `EditorFormatBarTests.theBarFitsTheNarrowestSplitHalfAtEveryTextSize`
    /// finds, at ``EditorLayoutMetrics/minSplitColumnWidth`` and every selectable text size, which
    /// rung is drawn. Measured 2026-10-03: the inline five stay up to 105%, and Bold, Italic and
    /// Strikethrough at every size above it — the test fails if the bar overflows, keeps fewer than
    /// those three anywhere, or fewer than the five at the default size. Below 220pt (a Split at the
    /// smallest windows halves a narrower column) the last two rungs carry on shedding.
    static let ladder: [Rung] = {
        let all = groups.map(\.count)
        let inline = all.first ?? 0
        return [
            Rung(headingWorded: true, visible: all.reduce(0, +)),
            Rung(headingWorded: true, visible: all.dropLast().reduce(0, +)),
            Rung(headingWorded: true, visible: inline),
            Rung(headingWorded: false, visible: inline),
            Rung(headingWorded: false, visible: max(inline - 2, 0)),
            Rung(headingWorded: false, visible: 0),
        ]
    }()

    /// **What one rung draws: the button groups kept on the bar, and the groups behind the »** —
    /// the first ``Rung/visible`` buttons along ``groups``, then the rest, each piece still in the
    /// menu's order and still divided where the menu divides it. The » is drawn exactly when
    /// `hidden` is not empty.
    static func layout(_ rung: Rung) -> (shown: [[MarkupVerb]], hidden: [[MarkupVerb]]) {
        var remaining = max(rung.visible, 0)
        var shown: [[MarkupVerb]] = []
        var hidden: [[MarkupVerb]] = []
        for group in groups {
            let kept = Array(group.prefix(remaining))
            remaining -= kept.count
            if !kept.isEmpty { shown.append(kept) }
            let rest = Array(group.dropFirst(kept.count))
            if !rest.isEmpty { hidden.append(rest) }
        }
        return (shown, hidden)
    }

    /// The glyph's point size at the default text size, and the square button it sits in.
    static let glyphPoint: CGFloat = 11
    static let boxSize: CGFloat = 20

    /// The box at `scale`, through the type ramp — ``CapsuleGlyph``'s rule: a box that did not
    /// scale left the glyph overflowing it at the large sizes.
    static func box(at scale: CGFloat) -> CGFloat {
        FontSize.scaledBox(boxSize, basePoint: glyphPoint, scale: scale)
    }

    var body: some View {
        Group {
            if let forcedRung {
                bar(forcedRung)
            } else {
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(Self.ladder.enumerated()), id: \.offset) { _, rung in
                        bar(rung)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Format bar")
    }

    private func bar(_ rung: Rung) -> some View {
        let layout = Self.layout(rung)
        return HStack(spacing: 2) {
            headingMenu(worded: rung.headingWorded)
            ForEach(Array(layout.shown.enumerated()), id: \.offset) { _, group in
                separator
                ForEach(group, id: \.self) { button($0) }
            }
            if !layout.hidden.isEmpty {
                separator
                overflowMenu(layout.hidden)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .fixedSize()
        // Frosted and Clear: one glass track under the whole bar, as Finder's toolbar groups its
        // buttons; Solid: today's quaternary capsule (`ChromeGlass`).
        .chromeGlassTrack()
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 1, height: Self.box(at: scale) * 0.6)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }

    private func button(_ verb: MarkupVerb) -> some View {
        let lit = state.lit.contains(verb)
        let box = Self.box(at: scale)
        return Button { onVerb(verb) } label: {
            Image(systemName: Self.symbol(verb))
                .scaledFont(.system(size: Self.glyphPoint, weight: .medium))
                .foregroundStyle(lit ? accent : .primary)
                .frame(width: box, height: box)
                // Lit: the accent ink on a soft accent wash, as the header's Expand wears it — in
                // the chip-cornered square a glyph button's hover takes, where Expand's word makes
                // its wash a capsule. The hover style paints its own wash over it.
                .background(RoundedRectangle(cornerRadius: Radius.chip)
                    .fill(lit ? accent.opacity(0.18) : .clear))
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .help(Self.tooltip(verb))
        .accessibilityLabel(verb.title)
        .accessibilityAddTraits(lit ? [.isButton, .isSelected] : .isButton)
    }

    /// **The Heading menu — Heading 1, 2, 3 and Body, ticked at the level the selection is at**, and
    /// labelled with it. A `Menu` in the button style, as the header's folded crumb is, so it takes
    /// this bar's hover wash and type size rather than AppKit's pop-up chrome.
    private func headingMenu(worded: Bool) -> some View {
        let box = Self.box(at: scale)
        // Accent while what the selection IS is a heading — not over body text, nor over a mix.
        let isHeading: Bool = {
            switch state.heading {
            case .level, .otherHeading: return true
            case .mixed, .body: return false
            }
        }()
        return Menu {
            ForEach(Self.headingVerbs, id: \.self) { verb in
                Toggle(verb.title, isOn: Binding(
                    get: { Self.isCurrent(verb, state.heading) },
                    set: { _ in onVerb(verb) }))
            }
        } label: {
            HStack(spacing: 3) {
                // Laid out at the widest label, so the buttons after it never move.
                ZStack(alignment: .leading) {
                    ForEach(Self.headingTitles(worded: worded), id: \.self) { title in
                        Text(title).hidden()
                    }
                    Text(Self.headingTitle(state.heading, worded: worded))
                        .foregroundStyle(isHeading ? accent : .primary)
                }
                .scaledFont(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                Image(systemName: "chevron.down")
                    .scaledFont(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(height: box)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.hoverAffordance(.segment, tint: accent))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Heading level")
        .accessibilityLabel("Heading level: \(Self.headingTitle(state.heading, worded: true))")
    }

    static func isCurrent(_ verb: MarkupVerb, _ heading: MarkdownEdits.HeadingLevel) -> Bool {
        switch (verb, heading) {
        case (.heading(0), .body): return true
        case (.heading(let a), .level(let b)): return a == b
        default: return false
        }
    }

    /// **The verbs the bar had no room for, in the bar's order, divided where it divides them** —
    /// each a ticked item while its formatting is applied. The » lights when it hides a lit verb,
    /// so a narrow bar never hides the answer to "is this already a list?".
    private func overflowMenu(_ hidden: [[MarkupVerb]]) -> some View {
        let box = Self.box(at: scale)
        let lit = hidden.joined().contains { state.lit.contains($0) }
        return Menu {
            ForEach(Array(hidden.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.self) { verb in
                    if Self.canLight(verb) {
                        Toggle(verb.title, isOn: Binding(
                            get: { state.lit.contains(verb) },
                            set: { _ in onVerb(verb) }))
                    } else {
                        Button(verb.title) { onVerb(verb) }
                    }
                }
            }
        } label: {
            Image(systemName: Self.overflowSymbol)
                .scaledFont(.system(size: Self.glyphPoint, weight: .medium))
                .foregroundStyle(lit ? accent : .primary)
                .frame(width: box, height: box)
                .background(RoundedRectangle(cornerRadius: Radius.chip)
                    .fill(lit ? accent.opacity(0.18) : .clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More formatting")
        .accessibilityLabel("More formatting")
        // What the accent says to a sighted reader — "something behind this is applied here" —
        // said to VoiceOver as the verbs themselves.
        .accessibilityValue(Self.overflowValue(hidden: hidden, lit: state.lit))
    }

    /// The » menu's accessibility value: the hidden verbs that are applied, by name, or nothing.
    static func overflowValue(hidden: [[MarkupVerb]], lit: Set<MarkupVerb>) -> String {
        let applied = hidden.joined().filter { lit.contains($0) }.map(\.title)
        return applied.isEmpty ? "" : "Applied: " + applied.joined(separator: ", ")
    }
}
