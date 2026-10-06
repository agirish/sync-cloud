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
    /// What the Body menu names.
    var heading: MarkdownEdits.HeadingLevel
    /// The Table items that would do something here — ``MarkdownTables/available(in:selection:)``.
    /// Holding Format Table (`.tidy`) means the selection starts IN a table: the Table capsule's cue.
    var tables: Set<TableVerb> = [.insert]
    /// Whether either end of the selection is in a table — where the verbs that rewrite whole lines
    /// would break it, and so are greyed (TE76, ``MarkdownTables/touches(_:_:)``).
    var touchesTable = false

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
            heading: MarkdownEdits.headingLevel(ns, selection, lines: lines),
            tables: MarkdownTables.available(in: ns, selection: selection),
            touchesTable: MarkdownTables.touches(ns, selection))
    }

    /// Whether the selection starts in a table — when the Table capsule is drawn (TE73).
    var isInTable: Bool { tables.contains(.tidy) }
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
/// **A capsule for each of the menu's groups** (TE68, TE70, decision AA = C6): the Body menu, then
/// Bold, Italic and Strikethrough, then the lists, then Code, Code Block and Quote, then Link, Table
/// and Divider — each its own capsule, apart from the next, as Notes groups its toolbar. Headings
/// lead, folded into the Body menu, because four buttons reading H1 H2 H3 ¶ would be the widest
/// group for the least-pressed verbs. Every other group keeps the menu's order — ``groups``
/// derives all of it from ``MarkupVerb/menuOrder``, so the bar cannot gain or lose a verb the menu
/// does not.
///
/// **In a table, a Table capsule joins them** (TE73) with the edits a table needs, and the buttons
/// that would take the table's lines out of it grey (TE76, ``MarkdownEdits/breaksTable(_:in:selection:)``).
///
/// **A quarter larger than it first shipped** (TE75, decision AD): 14-point glyphs in 25-point
/// buttons, 12.5-point words.
///
/// **It narrows group by group** (TE72, decision Y) — see ``ladder(showsLabels:inTable:)``: the
/// words come off, the Body menu shortens to ¶, and then each group folds into one button of its own,
/// so a hidden button is under its group's icon rather than behind an anonymous ». Icon and Text,
/// the default, starts with every word; Icon Only starts where the words are off. Its right-click
/// menu (``EditorFormatBarMenu``) chooses between the two.
///
/// **`Equatable`, and wrapped in `.equatable()` by its host**, because the host is the view a
/// keystroke redraws (`EditorWorkspaceView` observes the buffer), and without it every keystroke
/// rebuilt and re-measured every rung of a bar whose look had not changed.
struct EditorFormatBar: View, Equatable {

    let state: MarkupFormatState
    let accent: Color
    /// Icon and Text (`true`) or Icon Only — the reader's choice from the right-click menu,
    /// ``EditorTextSettings/formatBarShowsLabelsKey``. Only ever a preference: the width decides
    /// whether the words are drawn.
    let showsLabels: Bool
    /// The press. The host routes it through ``EditorTextViewHandle/applyMarkup(_:)``.
    let onVerb: (MarkupVerb) -> Void
    /// Forces a rung. `nil` picks by width; the fit test forces each in turn, the way
    /// ``EditorModeBar/forcedRung`` lets its tests ask for one rung rather than provoke it.
    let forcedRung: Rung?

    @Environment(\.appFontScale) private var scale
    /// The Body menu's popover (TE74) — one flag for every rung, because `ViewThatFits` draws one.
    @State private var showsStyles = false

    init(state: MarkupFormatState, accent: Color,
         showsLabels: Bool = EditorTextSettings.formatBarShowsLabelsDefault,
         onVerb: @escaping (MarkupVerb) -> Void, forcedRung: Rung? = nil) {
        self.state = state
        self.accent = accent
        self.showsLabels = showsLabels
        self.onVerb = onVerb
        self.forcedRung = forcedRung
    }

    /// Compared on everything it DRAWS. **The closure is the one member left out**, as
    /// `PageStrip`'s is: a closure cannot be compared, and this one is written at the single call
    /// site over the host's `@State` handle, which does not move. `nonisolated`, because
    /// `Equatable` is; every member read is an immutable `let` of a `Sendable` type.
    nonisolated static func == (lhs: EditorFormatBar, rhs: EditorFormatBar) -> Bool {
        lhs.state == rhs.state && lhs.accent == rhs.accent && lhs.showsLabels == rhs.showsLabels
            && lhs.forcedRung == rhs.forcedRung
    }

    // MARK: - What it holds

    /// The Markup menu's groups — ``MarkupVerb/menuOrder`` cut at its separators. Derived once:
    /// the list is a constant, and the bar asks for it in every rung it lays out.
    static let menuGroups: [[MarkupVerb]] =
        MarkupVerb.menuOrder.split(separator: nil).map { $0.compactMap { $0 } }

    /// The menu's heading group: Heading 1–3 and Body. The bar draws it as the Body menu.
    static let headingVerbs: [MarkupVerb] = menuGroups.first { $0.allSatisfy { isHeading($0) } } ?? []

    /// The menu's table run (TE65): every menu draws it as one Table submenu; the bar draws one
    /// Table button where it starts, and the editing items in the Table capsule (TE73).
    static let tableVerbs: [MarkupVerb] = MarkupVerb.menuOrder.compactMap { $0 }.filter(\.isTable)

    /// What stands for the table run among the bar's buttons — where the Table button sits, what
    /// its group's folded menu lists. **A plain button that makes tables** (decision AB): it
    /// inserts one, or makes one from the selected lines — ``tableVerb(in:)``.
    static let tableMenuStandIn = MarkupVerb.table(.insert)

    /// **The bar's capsules after the Body menu, in the menu's order** — the menu's groups but the
    /// headings, each table run drawn as the one Table button where it starts. With C6 that is
    /// Bold, Italic, Strikethrough · the three lists · Code, Code Block, Quote · Link, Table, Divider.
    static let groups: [[MarkupVerb]] = menuGroups.filter { !$0.allSatisfy { isHeading($0) } }.map { group in
        var buttons: [MarkupVerb] = []
        for verb in group where !verb.isTable || !buttons.contains(tableMenuStandIn) {
            buttons.append(verb.isTable ? tableMenuStandIn : verb)
        }
        return buttons
    }

    /// The bar's whole reading order, headings first and the table run where its button is — what
    /// the parity test holds against the menu.
    static var barOrder: [MarkupVerb] {
        headingVerbs + groups.flatMap { $0 }.flatMap { $0 == tableMenuStandIn ? tableVerbs : [$0] }
    }

    /// **The Table capsule's items** (TE73): the table run but its first section, which makes
    /// tables — this capsule is only there when the caret is already in one.
    static let tableEditVerbs: [MarkupVerb] = Array(MarkupVerb.tableSections.dropFirst().joined())

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
        // A page cut in two, rather than the bare dash that read as a minus (TE69).
        case .horizontalRule: return "rectangle.split.1x2"
        case .table(.addRowAbove), .table(.addRowBelow): return "rectangle.bottomthird.inset.filled"
        case .table(.addColumnLeft), .table(.addColumnRight): return "rectangle.rightthird.inset.filled"
        case .table(.deleteRow), .table(.deleteColumn): return "trash"
        case .table(.tidy): return "align.horizontal.left"
        case .table: return "tablecells"
        }
    }

    /// The glyph a folded part's button wears — its group's first glyph, Insert's +.
    static func symbol(_ part: Part) -> String {
        switch part {
        case .group(let index) where index == groups.count - 1: return "plus"
        case .group(let index): return groups.indices.contains(index) ? symbol(groups[index][0]) : "plus"
        case .table: return "tablecells"
        }
    }

    /// The merged menu's glyph — the last resort, at the narrowest widths.
    static let overflowSymbol = "chevron.right.2"

    /// What a folded part's button and its submenu in the merged menu are called.
    static func title(_ part: Part) -> String {
        switch part {
        case .group(1): return "Lists"
        case .group(2): return "Code and Quote"
        case .group(let index) where index == groups.count - 1: return "Insert"
        case .group: return "Formatting"
        case .table: return MarkupVerb.tableMenuTitle
        }
    }

    /// **Whether a button gets a word beside its glyph in Icon and Text** — every one but Bold,
    /// Italic and Strikethrough, whose glyphs ARE their letters: “B Bold” says one thing twice.
    static func wearsWord(_ verb: MarkupVerb) -> Bool {
        switch verb {
        case .bold, .italic, .strikethrough: return false
        default: return true
        }
    }

    /// **The word a button wears in Icon and Text: the menu title, shortened** — the bar is a row.
    /// The tooltip and both menus keep the full name; ``tooltip(_:)`` is unchanged.
    static func word(_ verb: MarkupVerb) -> String {
        switch verb {
        case .inlineCode: return "Code"
        case .link: return "Link"
        case .bulletList: return "Bullets"
        case .numberedList: return "Numbered"
        case .taskItem: return "Tasks"
        case .blockQuote: return "Quote"
        case .codeBlock: return "Code Block"
        case .horizontalRule: return "Divider"
        case .table(.addRowAbove), .table(.addRowBelow): return "Row"
        case .table(.addColumnLeft), .table(.addColumnRight): return "Column"
        case .table(.deleteRow), .table(.deleteColumn): return "Delete"
        case .table(.tidy): return "Format"
        case .table: return MarkupVerb.tableMenuTitle
        default: return verb.title
        }
    }

    /// **Whether a verb can ever be lit** — the ones whose press can take formatting off. Link, Code
    /// Block and Divider only insert, and Body only removes, so ``MarkdownEdits/isApplied(_:in:selection:)``
    /// never answers yes for them; in a menu they are plain items, not toggles that are always off.
    static func canLight(_ verb: MarkupVerb) -> Bool {
        switch verb {
        case .link, .codeBlock, .horizontalRule, .heading(0), .table: return false
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

    /// **What the Table button does here: make a table from the selected lines when they split
    /// into cells, else insert a new one** (decision AB) — the one button for both, named by its
    /// tooltip.
    static func tableVerb(in state: MarkupFormatState) -> MarkupVerb {
        state.tables.contains(.fromSelection) ? .table(.fromSelection) : .table(.insert)
    }

    /// **Whether a press would do something for this selection** — the Table items where the
    /// caret's place allows them, the Table button where it can make a table, and every verb but
    /// those that would break a table it is in (TE76). A button that would not is greyed.
    static func isOffered(_ verb: MarkupVerb, in state: MarkupFormatState) -> Bool {
        if verb == tableMenuStandIn {
            return state.tables.contains(.insert) || state.tables.contains(.fromSelection)
        }
        if case .table(let op) = verb { return state.tables.contains(op) }
        return !(verb.breaksTables && state.touchesTable)
    }

    /// What the Body menu's label reads.
    static func headingTitle(_ heading: MarkdownEdits.HeadingLevel, worded: Bool) -> String {
        switch heading {
        case .level(let level): return worded ? "Heading \(level)" : "H\(level)"
        case .otherHeading: return worded ? "Heading" : "H"
        case .mixed: return worded ? "Mixed" : "–"
        case .body: return worded ? "Body" : "¶"
        }
    }

    /// Every label the Body menu can show, so it is laid out at the widest and does not move the
    /// buttons after it as the caret crosses from a heading into body text.
    private static func headingTitles(worded: Bool) -> [String] {
        ([.body, .mixed, .otherHeading] + (1...3).map { .level($0) }).map { headingTitle($0, worded: worded) }
    }

    static func isCurrent(_ verb: MarkupVerb, _ heading: MarkdownEdits.HeadingLevel) -> Bool {
        switch (verb, heading) {
        case (.heading(0), .body): return true
        case (.heading(let a), .level(let b)): return a == b
        default: return false
        }
    }

    // MARK: - Where it is drawn

    /// **Shown only where a verb can do what it says:** a writable Markdown document, open (not
    /// refused), in Source or Split, with View ▸ Format Bar on — or in Preview while it is
    /// editable (`previewEditing`, TE67), where the verbs go through Preview's translation. A read-only
    /// Preview has no text view to act on;
    /// plain text has no Markdown for the verbs to write (the Markup menu still offers them there,
    /// but a strip of formatting buttons above a `.txt` would claim the file has formatting); a
    /// read-only file withholds the verbs everywhere, its Markup menu and context menu included.
    ///
    /// The UNRESOLVED mode, resolved here: `EditorMode.resolved` narrows any mode to Source on a
    /// plain-text file, and asking the resolved one here alone would leave that narrowing to the
    /// caller to remember.
    static func isShown(preference: Bool, hasDocument: Bool, isRefused: Bool, isMarkdown: Bool,
                        isReadOnly: Bool, mode: EditorMode, previewEditing: Bool = false) -> Bool {
        preference && hasDocument && !isRefused && isMarkdown && !isReadOnly
            && (EditorMode.resolved(mode, isMarkdown: isMarkdown) != .preview || previewEditing)
    }

    // MARK: - Narrow widths

    /// A capsule the ladder can strip of its words or fold: one of ``groups`` after the plain
    /// marks (by index), or the Table capsule a table brings (TE73).
    enum Part: Hashable, Sendable {
        case group(Int)
        case table
    }

    /// One way of drawing the bar: whether the Body menu wears its word, which parts wear words
    /// beside their glyphs, which are folded into one button each, and — the last resort — whether
    /// the folded parts are one » menu instead, with B, I and S in it too when `marksFolded`.
    struct Rung: Equatable, Sendable {
        var headingWorded = true
        var worded: Set<Part> = []
        var folded: Set<Part> = []
        var merged = false
        var marksFolded = false
    }

    /// The parts after B, I and S that can lose their words and fold — Lists, Code and Quote, Insert.
    static let foldableGroups: [Part] = groups.indices.dropFirst().map(Part.group)

    /// **The degrade order, widest first** (TE72). `ViewThatFits` draws the first rung that fits.
    ///
    /// The words come off group by group — Insert's, then Code and Quote's, then the lists', the
    /// end people press least first; in a table, the greyed groups first and the Table capsule's
    /// last. Then the Body menu shortens to ¶. Then each group folds into ONE button of its own, in
    /// the same order, so what is hidden is under its group's icon. Then the folded groups merge
    /// into one » beside Bold, Italic and Strikethrough, a submenu each — and only after that does
    /// the Table capsule fold into it, so in a table the table's own edits outlast every group's:
    /// measured 2026-10-05, half of a Split (490pt to draw in) keeps the Table capsule open, where
    /// folding it before the merge would have hidden it there. Last of all B, I and S join the ».
    ///
    /// **Icon Only starts where the words are off**; Icon and Text has the worded rungs ahead.
    /// Pinned by measurement in `EditorFormatBarTests`: each rung narrower than the one before, at
    /// every text size, in a table and out of one.
    static func ladder(showsLabels: Bool, inTable: Bool) -> [Rung] {
        let parts = foldableGroups + (inTable ? [.table] : [])
        let wordOrder: [Part] = inTable ? parts : foldableGroups.reversed()
        let foldOrder: [Part] = inTable ? foldableGroups : foldableGroups.reversed()
        var rungs: [Rung] = []
        var rung = Rung(worded: Set(parts))
        if showsLabels {
            rungs.append(rung)
            for part in wordOrder.dropLast() {
                rung.worded.remove(part)
                rungs.append(rung)
            }
        }
        rung.worded = []
        rungs.append(rung)
        rung.headingWorded = false
        rungs.append(rung)
        for part in foldOrder {
            rung.folded.insert(part)
            rungs.append(rung)
        }
        rung.merged = true
        rungs.append(rung)
        if inTable {
            rung.folded.insert(.table)
            rungs.append(rung)
        }
        rung.marksFolded = true
        rungs.append(rung)
        return rungs
    }

    /// The parts a rung folds, in the bar's order — what the merged » holds, a submenu each.
    static func foldedParts(_ rung: Rung, inTable: Bool) -> [Part] {
        (foldableGroups + (inTable ? [.table] : [])).filter { rung.folded.contains($0) }
    }

    /// The verbs a folded part holds, in its order.
    static func verbs(of part: Part) -> [MarkupVerb] {
        switch part {
        case .group(let index): return groups.indices.contains(index) ? groups[index] : []
        case .table: return tableEditVerbs
        }
    }

    /// **A folded part's — or the merged menu's — accessibility value: what it hides that is
    /// applied**, by name, as its accent says it on screen.
    static func appliedValue(_ verbs: [MarkupVerb], lit: Set<MarkupVerb>) -> String {
        let applied = verbs.filter { lit.contains($0) }.map(\.title)
        return applied.isEmpty ? "" : "Applied: " + applied.joined(separator: ", ")
    }

    /// The glyph's point size at the default text size, the square button it sits in, and the
    /// words' size — a quarter larger than the bar first shipped (11, 20, 11; TE75).
    static let glyphPoint: CGFloat = 14
    static let boxSize: CGFloat = 25
    static let wordPoint: CGFloat = 12.5
    static let chevronPoint: CGFloat = 10
    /// The room between two capsules, and around a capsule's buttons.
    static let capsuleGap: CGFloat = 8
    static let capsuleInset: CGFloat = 3

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
                    ForEach(Array(Self.ladder(showsLabels: showsLabels, inTable: state.isInTable).enumerated()),
                            id: \.offset) { _, rung in
                        bar(rung)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Format bar")
    }

    private func bar(_ rung: Rung) -> some View {
        let inTable = state.isInTable
        return HStack(spacing: Self.capsuleGap) {
            capsule { headingMenu(worded: rung.headingWorded) }
            // The merged », when there is one, rides in B, I and S's capsule: a capsule of its own
            // would cost the gap and the insets the narrowest Split half has no room for at 135%.
            if !rung.marksFolded, let marks = Self.groups.first {
                capsule {
                    ForEach(marks, id: \.self) { button($0, worded: false) }
                    if rung.merged { mergedMenu(rung) }
                }
            } else if rung.merged {
                capsule { mergedMenu(rung) }
            }
            ForEach(Array(Self.foldableGroups.enumerated()), id: \.offset) { _, part in
                if !rung.folded.contains(part) {
                    capsule {
                        ForEach(Self.verbs(of: part), id: \.self) { button($0, worded: rung.worded.contains(part)) }
                    }
                } else if !rung.merged {
                    capsule { foldMenu(part) }
                }
            }
            // Folded, the Table capsule is a submenu of the merged » — it folds only after the merge.
            if inTable && !rung.folded.contains(.table) {
                capsule(accented: true) { tableCapsule(worded: rung.worded.contains(.table)) }
            }
        }
        .fixedSize()
    }

    /// **One group's capsule** — its own glass track, apart from the next (TE70): Frosted and Clear
    /// draw glass, Solid the quaternary capsule (`ChromeGlass`). The Table capsule wears an accent
    /// tint, because it comes and goes with the caret.
    private func capsule<Content: View>(accented: Bool = false,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, Self.capsuleInset)
            // One WHOLE-point height for every capsule on every rung, so the text under the bar
            // never moves as it narrows. Whole, because the scaled box is fractional (27.2pt at
            // 125%) and a fractional bar rounds one way measured alone and the other in the card —
            // measured 2026-10-05, the text sat a point off what the bar's own height said.
            .frame(height: (Self.box(at: scale) + 4).rounded())
            .chromeGlassTrack()
            // A tint, not an outline: a 1pt ring broke up at the capsule's ends where the curve
            // runs nearly vertical (rendered 2026-10-05); a fill antialiases cleanly.
            .background(Capsule().fill(accent.opacity(accented ? 0.12 : 0)))
    }

    /// **What every button wears**: the glyph, its word in Icon and Text, a chevron on a menu — in
    /// one wash, so a lit Bullets lights its word with it. As tall as a bare glyph's box: words do
    /// not grow the bar.
    private func label(_ symbol: String, word: String?, lit: Bool, offered: Bool = true,
                       chevron: Bool = false) -> some View {
        let box = Self.box(at: scale)
        let padded = word != nil || chevron
        return HStack(spacing: word == nil ? 2 : 4) {
            Image(systemName: symbol)
                .scaledFont(.system(size: Self.glyphPoint, weight: .medium))
            if let word {
                Text(word)
                    .scaledFont(.system(size: Self.wordPoint, weight: .medium))
                    .lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.down")
                    .scaledFont(.system(size: Self.chevronPoint, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(lit ? accent : .primary)
        .padding(.leading, padded ? 6 : 0)
        .padding(.trailing, padded ? (word == nil ? 5 : 8) : 0)
        .frame(minWidth: box, minHeight: box, maxHeight: box)
        // Lit: the accent ink on a soft accent wash, as the header's Expand wears it.
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(lit ? accent.opacity(0.18) : .clear))
        // Greyed where it would do nothing, or break the table the caret is in (TE76).
        .opacity(offered ? 1 : 0.35)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func button(_ verb: MarkupVerb, worded: Bool) -> some View {
        if verb == Self.tableMenuStandIn {
            tableButton(worded: worded)
        } else {
            verbButton(verb, worded: worded)
        }
    }

    private func verbButton(_ verb: MarkupVerb, worded: Bool) -> some View {
        let lit = state.lit.contains(verb)
        let offered = Self.isOffered(verb, in: state)
        return Button { onVerb(verb) } label: {
            label(Self.symbol(verb), word: worded && Self.wearsWord(verb) ? Self.word(verb) : nil,
                  lit: lit, offered: offered)
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .disabled(!offered)
        .help(Self.tooltip(verb))
        .accessibilityLabel(verb.title)
        .accessibilityAddTraits(lit ? [.isButton, .isSelected] : .isButton)
    }

    /// **The Table button** (decision AB): one press makes a table — from the selected lines when
    /// they split into cells, else a new one — named by its tooltip. Greyed in a table; the Table
    /// capsule is there for that.
    private func tableButton(worded: Bool) -> some View {
        let verb = Self.tableVerb(in: state)
        let offered = Self.isOffered(Self.tableMenuStandIn, in: state)
        return Button { onVerb(verb) } label: {
            label(Self.symbol(Self.tableMenuStandIn), word: worded ? Self.word(Self.tableMenuStandIn) : nil,
                  lit: false, offered: offered)
        }
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .disabled(!offered)
        .help(verb.title)
        .accessibilityLabel(verb.title)
    }

    /// **The Body menu — a popover of the styles, each drawn as it looks** (TE74, decision AC), as
    /// Notes draws its Aa list: a menu cannot set a size per item, a popover can. Labelled with the
    /// level the selection is at; greyed in a table, where every heading would break it (TE76).
    private func headingMenu(worded: Bool) -> some View {
        let box = Self.box(at: scale)
        let offered = !state.touchesTable
        // Accent while what the selection IS is a heading — not over body text, nor over a mix.
        let isHeading: Bool = {
            switch state.heading {
            case .level, .otherHeading: return true
            case .mixed, .body: return false
            }
        }()
        return Button { showsStyles.toggle() } label: {
            HStack(spacing: 3) {
                // Laid out at the widest label, so the buttons after it never move.
                ZStack(alignment: .leading) {
                    ForEach(Self.headingTitles(worded: worded), id: \.self) { title in
                        Text(title).hidden()
                    }
                    Text(Self.headingTitle(state.heading, worded: worded))
                        .foregroundStyle(isHeading ? accent : .primary)
                }
                .scaledFont(.system(size: Self.wordPoint, weight: .semibold))
                .lineLimit(1)
                Image(systemName: "chevron.down")
                    .scaledFont(.system(size: Self.chevronPoint, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: box)
            .opacity(offered ? 1 : 0.35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.segment, tint: accent))
        .disabled(!offered)
        .fixedSize()
        .popover(isPresented: $showsStyles, arrowEdge: .bottom) {
            EditorStylePicker(current: state.heading) { verb in
                showsStyles = false
                onVerb(verb)
            }
        }
        .help("Paragraph style")
        .accessibilityLabel("Paragraph style: \(Self.headingTitle(state.heading, worded: true))")
    }

    /// **The Table capsule** (TE73): there while the caret is in a table, gone when it leaves. Row
    /// adds one below and Column one to the right, each with a chevron for the other side; Delete
    /// asks Row or Column; Format lines up the pipes. Each greyed where it would do nothing — no row
    /// above the header, no deleting the header or the only column.
    @ViewBuilder
    private func tableCapsule(worded: Bool) -> some View {
        Image(systemName: Self.symbol(.table(.insert)))
            .scaledFont(.system(size: Self.glyphPoint, weight: .medium))
            .foregroundStyle(accent)
            .padding(.leading, 6)
            .padding(.trailing, 2)
            .accessibilityLabel("Table")
        tableEdit(.addRowBelow, other: .addRowAbove, worded: worded)
        tableEdit(.addColumnRight, other: .addColumnLeft, worded: worded)
        tableChoice([.table(.deleteRow), .table(.deleteColumn)], worded: worded)
        verbButton(.table(.tidy), worded: worded)
    }

    /// An edit with a side: the press does `primary`, the chevron beside it offers both.
    @ViewBuilder
    private func tableEdit(_ primary: TableVerb, other: TableVerb, worded: Bool) -> some View {
        verbButton(.table(primary), worded: worded)
        tableChoice([.table(other), .table(primary)], worded: false, chevronOnly: true)
    }

    /// A menu of table items, each enabled where it would do something.
    private func tableChoice(_ verbs: [MarkupVerb], worded: Bool, chevronOnly: Bool = false) -> some View {
        let offered = verbs.contains { Self.isOffered($0, in: state) }
        let lead = verbs[0]
        return Menu {
            ForEach(verbs, id: \.self) { verb in
                Button(verb.title) { onVerb(verb) }
                    .disabled(!Self.isOffered(verb, in: state))
            }
        } label: {
            Group {
                if chevronOnly {
                    Image(systemName: "chevron.down")
                        .scaledFont(.system(size: Self.chevronPoint, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.box(at: scale) * 0.6, height: Self.box(at: scale))
                        .opacity(offered ? 1 : 0.35)
                        .contentShape(Rectangle())
                } else {
                    label(Self.symbol(lead), word: worded ? Self.word(lead) : nil, lit: false,
                          offered: offered, chevron: true)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!offered)
        .help(verbs.map(\.title).joined(separator: " or "))
        .accessibilityLabel(chevronOnly ? "More: " + verbs.map(\.title).joined(separator: ", ") : Self.word(lead))
    }

    /// **A folded group: one button, its group's glyph and a chevron, its verbs in a menu** (TE72) —
    /// lit while one of them is applied, so a narrow bar never hides the answer to "is this already
    /// a list?".
    private func foldMenu(_ part: Part) -> some View {
        let verbs = Self.verbs(of: part)
        let lit = verbs.contains { state.lit.contains($0) }
        return Menu {
            items(of: part)
        } label: {
            label(Self.symbol(part), word: nil, lit: lit, chevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Self.title(part))
        .accessibilityLabel(Self.title(part))
        .accessibilityValue(Self.appliedValue(verbs, lit: state.lit))
    }

    /// **The last resort: every folded group in one » menu, a submenu each** — and Bold, Italic and
    /// Strikethrough at its top once they fold too.
    private func mergedMenu(_ rung: Rung) -> some View {
        let parts = Self.foldedParts(rung, inTable: state.isInTable)
        let marks = rung.marksFolded ? (Self.groups.first ?? []) : []
        let hidden = marks + parts.flatMap(Self.verbs(of:))
        let lit = hidden.contains { state.lit.contains($0) }
        return Menu {
            ForEach(marks, id: \.self) { item($0) }
            if !marks.isEmpty { Divider() }
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Menu(Self.title(part)) { items(of: part) }
            }
        } label: {
            label(Self.overflowSymbol, word: nil, lit: lit)
        }
        .menuStyle(.button)
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More formatting")
        .accessibilityLabel("More formatting")
        .accessibilityValue(Self.appliedValue(hidden, lit: state.lit))
    }

    /// A folded part's items, in its order: ticked toggles for what can be lit, plain items for the
    /// rest, the Table button as its two items. Each greyed where the bar would grey it.
    @ViewBuilder
    private func items(of part: Part) -> some View {
        ForEach(Self.verbs(of: part), id: \.self) { verb in
            if verb == Self.tableMenuStandIn {
                ForEach(MarkupVerb.tableSections.first ?? [], id: \.self) { item($0) }
            } else {
                item(verb)
            }
        }
    }

    @ViewBuilder
    private func item(_ verb: MarkupVerb) -> some View {
        if Self.canLight(verb) {
            Toggle(verb.title, isOn: Binding(get: { state.lit.contains(verb) }, set: { _ in onVerb(verb) }))
                .disabled(!Self.isOffered(verb, in: state))
        } else {
            Button(verb.title) { onVerb(verb) }
                .disabled(!Self.isOffered(verb, in: state))
        }
    }
}

/// **The Body menu's styles, each drawn as it looks** (TE74, decision AC) — Heading 1 large and
/// bold down to Body, ticked at the level the selection is at, as Notes draws its Aa list.
struct EditorStylePicker: View {
    let current: MarkdownEdits.HeadingLevel
    let onPick: (MarkupVerb) -> Void

    /// Each style's size and weight in the list — the headings in steps above the body's 13 points.
    static func font(_ verb: MarkupVerb) -> (size: CGFloat, weight: Font.Weight) {
        switch verb {
        case .heading(1): return (21, .bold)
        case .heading(2): return (17, .bold)
        case .heading(3): return (14.5, .bold)
        default: return (13, .regular)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(EditorFormatBar.headingVerbs, id: \.self) { verb in
                EditorStyleRow(verb: verb, isCurrent: EditorFormatBar.isCurrent(verb, current)) { onPick(verb) }
            }
        }
        .padding(6)
        .frame(minWidth: 190)
    }
}

/// One style in ``EditorStylePicker``: a tick where it is current, its name in its own size, the
/// row washed in the accent under the pointer, as a menu item is.
private struct EditorStyleRow: View {
    let verb: MarkupVerb
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let font = EditorStylePicker.font(verb)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .opacity(isCurrent ? 1 : 0)
                Text(verb.title)
                    .scaledFont(.system(size: font.size, weight: font.weight))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(hovering ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(verb.title)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

/// **The format bar's right-click menu** (TE64): Icon and Text or Icon Only — ticked at the one in
/// force — and Hide Format Bar, as Finder's toolbar offers on its own right-click.
///
/// **Bindings to the two stored settings, not state of its own**: Icon and Text is
/// ``EditorTextSettings/formatBarShowsLabelsKey``, and Hide Format Bar turns off the very setting
/// View ▸ Format Bar ticks, so the menu bar and this menu cannot disagree. No Text Only (a bar of
/// bare words is the widest of the three and the slowest to read) and no Customize Toolbar…, which
/// would let the bar stop matching the Markup menu verb for verb.
struct EditorFormatBarMenu: View {
    @Binding var showsLabels: Bool
    @Binding var showsBar: Bool

    static let iconAndText = "Icon and Text"
    static let iconOnly = "Icon Only"
    static let hide = "Hide Format Bar"

    var body: some View {
        // Toggles, so each draws its tick; a press on the ticked one leaves it ticked, which is
        // what a pair of radio items does.
        Toggle(Self.iconAndText, isOn: Binding(get: { showsLabels },
                                               set: { _ in Self.choose(labels: true, $showsLabels) }))
        Toggle(Self.iconOnly, isOn: Binding(get: { !showsLabels },
                                            set: { _ in Self.choose(labels: false, $showsLabels) }))
        Divider()
        Button(Self.hide) { Self.hide($showsBar) }
    }

    /// Icon and Text (`labels`) or Icon Only — said in the log when it changes, as Expand's switch
    /// is, so a bar that "lost its words" can be traced to a click.
    static func choose(labels: Bool, _ showsLabels: Binding<Bool>) {
        guard showsLabels.wrappedValue != labels else { return }
        showsLabels.wrappedValue = labels
        Logger.shared.info("[edit] Format bar ▸ \(labels ? iconAndText : iconOnly)")
    }

    /// Hide Format Bar — View ▸ Format Bar's setting, turned off, and the way back named in the log.
    static func hide(_ showsBar: Binding<Bool>) {
        showsBar.wrappedValue = false
        Logger.shared.info("[edit] Format bar hidden from its menu — Format Bar on the text's right-click menu, or View ▸ Format Bar, shows it again")
    }
}
