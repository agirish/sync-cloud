import SwiftUI
import AppKit
import Design
import Events

/// What the format bar shows lit, for one selection in one buffer.
///
/// Derived off the main actor on the caret's debounce (`EditorWorkspaceView`'s format task): every
/// answer walks the lines the selection touches, too costly for a body pass on every keystroke.
/// The same trade ``EditorCaret`` makes for the status line.
struct MarkupFormatState: Equatable, Sendable {
    /// The verbs whose press would take their formatting off (``MarkdownEdits/isApplied(_:in:selection:)``).
    var lit: Set<MarkupVerb>
    /// What the Body menu names.
    var heading: MarkdownEdits.HeadingLevel
    /// The Table items that would do something here (``MarkdownTables/available(in:selection:)``).
    /// Holding Format Table (`.tidy`) means the selection starts in a table: the Table capsule's cue.
    var tables: Set<TableVerb> = [.insert]
    /// Whether either end of the selection is in a table, where the verbs that rewrite whole lines
    /// would break it and so are greyed (``MarkdownTables/touches(_:_:)``).
    var touchesTable = false
    /// Whether the selection runs across a table's cells, where the inline marks and Link would
    /// break it and so are greyed (``MarkdownEdits/crossesCells(_:_:touches:)``).
    var crossesCells = false
    /// Whether the selection's paragraph runs straight into a table below, which a list or quote
    /// would swallow, so they are greyed (``MarkdownTables/abuts(_:_:)``).
    var abutsTable = false

    static let none = MarkupFormatState(lit: [], heading: .body)

    /// Every verb asked about one selection, over one bridge of the buffer and one survey of the
    /// lines the selection touches, handed to each verb's own test.
    static func of(_ text: String, selection: NSRange) -> MarkupFormatState {
        let ns = text as NSString
        guard MarkdownEdits.isValid(selection, in: ns) else { return .none }
        let survey = MarkdownEdits.LineSurvey(covering: selection, in: ns)
        let tables = MarkdownTables.reading(ns, selection)
        return MarkupFormatState(
            lit: Set(MarkupVerb.menuOrder.compactMap { $0 }.filter {
                MarkdownEdits.isApplied($0, ns, selection, survey: survey)
            }),
            heading: MarkdownEdits.headingLevel(ns, selection, survey: survey),
            tables: tables.available,
            touchesTable: tables.touches,
            crossesCells: MarkdownEdits.crossesCells(ns, selection, touches: tables.touches),
            abutsTable: tables.abuts)
    }

    /// This state with `verbs` lit as well: editable Preview's pending styles, set at a caret for
    /// what is typed next, which the selection can't show.
    func lighting(_ verbs: Set<MarkupVerb>) -> MarkupFormatState {
        guard !verbs.isEmpty else { return self }
        var lit = self
        lit.lit.formUnion(verbs)
        return lit
    }

    /// Whether the selection starts in a table, which is when the Table capsule is drawn.
    var isInTable: Bool { tables.contains(.tidy) }
}

/// The document's text view, for the controls drawn beside it rather than inside it.
///
/// A weak reference handed to `PlainTextEditor`, not a request token: a verb edits the buffer,
/// which publishes the text, and a write from inside `updateNSView` is what SwiftUI warns about.
/// The handle lets the bar's button act in its own action, outside any update. (Find can be a
/// counter, since opening a find bar writes no SwiftUI state.)
@MainActor
final class EditorTextViewHandle {
    weak var textView: NSTextView?
    /// Split with Preview editable: Preview's half. The bar and the header's Find act on the half
    /// the caret is in, or was last in (a click on a button can take it out of both), as the
    /// Markup menu does.
    weak var splitPreview: NSTextView?
    /// Whether the caret was last in ``splitPreview`` rather than Source's half. Written as each
    /// half reports its selection; a plain property, so the write re-renders nothing.
    var caretInSplitPreview = false

    /// The text view the bar acts on: Split's Preview half while the caret was last there.
    var target: NSTextView? {
        if caretInSplitPreview, let splitPreview, splitPreview.window != nil { return splitPreview }
        return textView
    }

    /// Whether the bar acts on Split's Preview half now, where the header's Find goes too.
    var targetsSplitPreview: Bool { splitPreview != nil && target === splitPreview }

    /// Out of Split: no Preview half to act on.
    func leaveSplit() {
        splitPreview = nil
        caretInSplitPreview = false
    }

    /// The Markup menu's verb, run as the menu runs it, through
    /// ``EditorDocumentSurface/applyMarkup(_:in:)`` and so `PlainTextEditor.apply`.
    ///
    /// Except that the caret is put back first. The menu refuses a key pressed in a field, which is
    /// ambiguous about which text it means; a click on this bar isn't, since the bar sits on the
    /// text it formats. So the text view takes the first responder back, keeping its selection
    /// (`NSTextView` holds it across a resign), and the menu's function finds the caret there.
    @discardableResult
    func applyMarkup(_ verb: MarkupVerb) -> Bool {
        guard let view = target, let window = view.window, view.isEditable else {
            Logger.shared.info("Format bar ▸ \(verb.title) ignored: no writable text view on screen")
            return false
        }
        if window.firstResponder !== view {
            // Logged, because here the bar does what the menu would not; naming what held the
            // caret makes the log useful to a surprised reader.
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

/// The format bar: the Markup menu's verbs as buttons, in a persistent strip above a Markdown
/// document's source.
///
/// In the text card, not the header, which is pinned to `LiquidGlass.headerHeight` to share its
/// edge with the pane's toolbar card. In Split it spans the Source half, the half it acts on.
///
/// A capsule per menu group, as Notes groups its toolbar: the Body menu (headings folded in, since
/// H1 H2 H3 ¶ would be the widest group for the least-pressed verbs), then Bold, Italic and
/// Strikethrough, the lists, Code, Code Block and Quote, then Link, Table and Divider. ``groups``
/// derives them from ``MarkupVerb/menuOrder``, so the bar can't gain or lose a verb the menu
/// doesn't. In a table a Table capsule joins them, and buttons that would break the table grey
/// (``MarkdownEdits/breaksTable(_:in:selection:)``).
///
/// It narrows group by group (``ladder(showsLabels:inTable:)``), so a hidden button is under its
/// group's icon, not an anonymous ». Icon and Text starts with every word, Icon Only without;
/// the right-click menu (``EditorFormatBarMenu``) chooses.
///
/// `Equatable`, and wrapped in `.equatable()` by its host, which every keystroke redraws; without
/// it each keystroke would re-measure every rung of an unchanged bar.
struct EditorFormatBar: View, Equatable {

    let state: MarkupFormatState
    let accent: Color
    /// Icon and Text (`true`) or Icon Only: the reader's choice from the right-click menu
    /// (``EditorTextSettings/formatBarShowsLabelsKey``). Only a preference; the width decides
    /// whether the words are drawn.
    let showsLabels: Bool
    /// The press. The host routes it through ``EditorTextViewHandle/applyMarkup(_:)``.
    let onVerb: (MarkupVerb) -> Void
    /// Forces a rung. `nil` picks by width; the fit test forces each in turn, as with
    /// ``EditorModeBar/forcedRung``.
    let forcedRung: Rung?

    @Environment(\.appFontScale) private var scale
    /// ⌥ held: read so the bar redraws when it is, and asks where the caret is.
    @Environment(\.shortcutRevealActive) private var isRevealing
    /// The Body menu's popover: one flag for every rung, because `ViewThatFits` draws one.
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

    /// Compared on everything it draws, leaving out the closure, as `PageStrip` does: it can't be
    /// compared, and its one call site captures the host's `@State` handle, which doesn't move.
    /// `nonisolated`, because `Equatable` is; every member read is an immutable `Sendable` `let`.
    nonisolated static func == (lhs: EditorFormatBar, rhs: EditorFormatBar) -> Bool {
        lhs.state == rhs.state && lhs.accent == rhs.accent && lhs.showsLabels == rhs.showsLabels
            && lhs.forcedRung == rhs.forcedRung
    }

    // MARK: - What it holds

    /// The Markup menu's groups: ``MarkupVerb/menuOrder`` cut at its separators. Derived once, as
    /// every rung asks for it.
    static let menuGroups: [[MarkupVerb]] =
        MarkupVerb.menuOrder.split(separator: nil).map { $0.compactMap { $0 } }

    /// The menu's heading group: Heading 1–3 and Body. The bar draws it as the Body menu.
    static let headingVerbs: [MarkupVerb] = menuGroups.first { $0.allSatisfy { isHeading($0) } } ?? []

    /// What stands for the table run among the bar's buttons: where the Table button sits, and what
    /// its group's folded menu lists. A plain button that inserts a table or makes one from the
    /// selected lines (``tableVerb(in:)``).
    static let tableMenuStandIn = MarkupVerb.table(.insert)

    /// The bar's capsules after the Body menu, in the menu's order: the menu's groups but the
    /// headings, each table run as one Table button where it starts. Bold, Italic, Strikethrough ·
    /// the three lists · Code, Code Block, Quote · Link, Table, Divider.
    static let groups: [[MarkupVerb]] = menuGroups.filter { !$0.allSatisfy { isHeading($0) } }.map { group in
        var buttons: [MarkupVerb] = []
        for verb in group where !verb.isTable || !buttons.contains(tableMenuStandIn) {
            buttons.append(verb.isTable ? tableMenuStandIn : verb)
        }
        return buttons
    }

    /// The Table capsule's items: the table run but its first section, which makes tables; this
    /// capsule only appears with the caret already in one.
    static let tableEditVerbs: [MarkupVerb] = Array(MarkupVerb.tableSections.dropFirst().joined())

    /// One control of the Table capsule: a press with a chevron beside it for both sides, a menu
    /// asking which, or a plain button.
    enum TableCapsuleControl: Equatable, Sendable {
        case press(TableVerb, chevron: [TableVerb])
        case menu([TableVerb])
        case button(TableVerb)
    }

    /// What each of the Table capsule's controls does, in order, the one list it draws from: Row adds
    /// one below and Column one to the right, each with a chevron for both sides; Delete asks Row or
    /// Column; Format formats. A list so a test can tell Above from Below, which the words can't.
    static let tableCapsule: [TableCapsuleControl] = [
        .press(.addRowBelow, chevron: [.addRowAbove, .addRowBelow]),
        .press(.addColumnRight, chevron: [.addColumnLeft, .addColumnRight]),
        .menu([.deleteRow, .deleteColumn]),
        .button(.tidy),
    ]

    private nonisolated static func isHeading(_ verb: MarkupVerb) -> Bool {
        if case .heading = verb { return true }
        return false
    }

    /// Each button's glyph. `EditorFormatBarTests.everyGlyphIsASymbolTheSystemHas` checks every
    /// name, since a misspelt symbol draws nothing and fails nothing.
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
        // A page cut in two, since a bare dash reads as a minus.
        case .horizontalRule: return "rectangle.split.1x2"
        case .table(.addRowAbove), .table(.addRowBelow): return "rectangle.bottomthird.inset.filled"
        case .table(.addColumnLeft), .table(.addColumnRight): return "rectangle.rightthird.inset.filled"
        case .table(.deleteRow), .table(.deleteColumn): return "trash"
        case .table(.tidy): return "align.horizontal.left"
        case .table: return "tablecells"
        }
    }

    /// The glyph a folded part's button wears: its group's first glyph, or + for Insert.
    static func symbol(_ part: Part) -> String {
        switch part {
        case .group(let index) where index == groups.count - 1: return "plus"
        case .group(let index): return groups.indices.contains(index) ? symbol(groups[index][0]) : "plus"
        case .table: return "tablecells"
        }
    }

    /// The merged menu's glyph: the last resort, at the narrowest widths.
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

    /// Whether a button gets a word beside its glyph in Icon and Text: all but Bold, Italic and
    /// Strikethrough, whose glyphs are their letters (“B Bold” says it twice).
    static func wearsWord(_ verb: MarkupVerb) -> Bool {
        switch verb {
        case .bold, .italic, .strikethrough: return false
        default: return true
        }
    }

    /// The word a button wears in Icon and Text: the menu title, shortened to fit a row. The
    /// tooltip (``tooltip(_:)``) and both menus keep the full name.
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

    /// Whether a verb can ever be lit: the ones whose press can take formatting off. Link, Code
    /// Block, Divider and the Table items only insert or edit, and Body only removes, so in a menu
    /// they are plain items, not toggles that are always off.
    static func canLight(_ verb: MarkupVerb) -> Bool {
        switch verb {
        case .link, .codeBlock, .horizontalRule, .heading(0), .table: return false
        default: return true
        }
    }

    /// The key a verb's button shows while ⌥ is held: its chord, or none.
    static func keycap(_ verb: MarkupVerb) -> String? { verb.chord?.display }

    /// Whether the caret is in the document's text, the only place the bar's keys are its verbs
    /// (`EditorDocumentSurface.caretTextView`). Asked only while ⌥ is held, when once is enough: a
    /// key or a click ends the reveal before the caret can move.
    @MainActor
    static func caretIsInText(revealing: Bool) -> Bool {
        revealing && EditorDocumentSurface.caretTextView(in: NSApp.keyWindow) != nil
    }

    /// What a button says under the pointer: the verb's name, and its chord where it has one, from
    /// ``MarkupVerb/chord``, the value the menu bar registers, so a tooltip can't advertise a key
    /// the menu doesn't answer.
    static func tooltip(_ verb: MarkupVerb) -> String {
        guard let chord = verb.chord else { return verb.title }
        return ShortcutHint.tooltip(verb.title, chord.display)
    }

    /// What the Table button does here: make a table from the selected lines when they split into
    /// cells, else insert a new one. One button for both, named by its tooltip.
    static func tableVerb(in state: MarkupFormatState) -> MarkupVerb {
        state.tables.contains(.fromSelection) ? .table(.fromSelection) : .table(.insert)
    }

    /// Whether a press would do something for this selection: the Table items where the caret's
    /// place allows them, the Table button where it can make a table, and every verb but those that
    /// would break a table it is in. A button that wouldn't is greyed.
    static func isOffered(_ verb: MarkupVerb, in state: MarkupFormatState) -> Bool {
        if verb == tableMenuStandIn {
            return state.tables.contains(.insert) || state.tables.contains(.fromSelection)
        }
        if case .table(let op) = verb { return state.tables.contains(op) }
        return !(verb.breaksTables && state.touchesTable) && !(verb.wrapsWords && state.crossesCells)
            && !(verb.continuesLazily && state.abutsTable)
    }

    /// Whether a menu item would do something: ``isOffered(_:in:)`` without the Table button's own
    /// rule. The button is live when either Insert or Make from Selection would act, but a folded
    /// menu lists the two as separate items, and each must be live only where it would act.
    static func isItemOffered(_ verb: MarkupVerb, in state: MarkupFormatState) -> Bool {
        if case .table(let op) = verb { return state.tables.contains(op) }
        return isOffered(verb, in: state)
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

    /// Every label the Body menu can show, so it is laid out at the widest and doesn't move the
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

    /// Shown only where a verb can do what it says: a writable Markdown document, open (not
    /// refused), in Source or Split, with View ▸ Format Bar on, or in Preview while it is editable
    /// (`previewEditing`), where the verbs go through Preview's translation. Read-only Preview has
    /// no text view to act on, plain text has no Markdown to write, and a read-only file withholds
    /// the verbs everywhere.
    ///
    /// Takes the unresolved mode and resolves it here (`EditorMode.resolved`), so no caller has to
    /// remember the narrowing to Source.
    static func isShown(preference: Bool, hasDocument: Bool, isRefused: Bool, isMarkdown: Bool,
                        isReadOnly: Bool, mode: EditorMode, previewEditing: Bool = false) -> Bool {
        preference && hasDocument && !isRefused && isMarkdown && !isReadOnly
            && (EditorMode.resolved(mode, isMarkdown: isMarkdown) != .preview || previewEditing)
    }

    // MARK: - Narrow widths

    /// A capsule the ladder can strip of its words or fold: one of ``groups`` after the plain
    /// marks (by index), or the Table capsule a table brings.
    enum Part: Hashable, Sendable {
        case group(Int)
        case table
    }

    /// One way of drawing the bar: whether the Body menu wears its word, which parts wear words,
    /// which are folded into one button each, and, as the last resort, whether the folded parts
    /// are one » menu instead, with B, I and S in it too when `marksFolded`.
    struct Rung: Equatable, Sendable {
        var headingWorded = true
        var worded: Set<Part> = []
        var folded: Set<Part> = []
        var merged = false
        var marksFolded = false
    }

    /// The parts after B, I and S that can lose their words and fold: Lists, Code and Quote, Insert.
    static let foldableGroups: [Part] = groups.indices.dropFirst().map(Part.group)

    /// The degrade order, widest first; `ViewThatFits` draws the first rung that fits.
    ///
    /// Words come off group by group, least-pressed end first (in a table, the greyed groups first
    /// and the Table capsule's last). Then the Body menu shortens to ¶. Then each group folds into
    /// one button, in the same order. Then the folded groups merge into one » beside B, I and S,
    /// and only then does the Table capsule fold in, so a table's edits outlast every group (half a
    /// Split keeps it open). Last, B, I and S join the ». Icon Only starts where the words are off.
    /// `EditorFormatBarTests` pins each rung narrower than the last, at every size, in a table or not.
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

    /// The parts a rung folds, in the bar's order: what the merged » holds, a submenu each.
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

    /// A folded part's or the merged menu's accessibility value: what it hides that is applied, by
    /// name, as its accent says on screen.
    static func appliedValue(_ verbs: [MarkupVerb], lit: Set<MarkupVerb>) -> String {
        let applied = verbs.filter { lit.contains($0) }.map(\.title)
        return applied.isEmpty ? "" : "Applied: " + applied.joined(separator: ", ")
    }

    /// The glyph's point size at the default text size, the square button it sits in, and the
    /// words' size.
    static let glyphPoint: CGFloat = 14
    static let boxSize: CGFloat = 25
    static let wordPoint: CGFloat = 12.5
    static let chevronPoint: CGFloat = 10
    /// The room between two capsules, and around a capsule's buttons.
    static let capsuleGap: CGFloat = 8
    static let capsuleInset: CGFloat = 3
    /// The room between two buttons in one capsule, which a keycap over each must fit.
    static let buttonGap: CGFloat = 2

    /// The box at `scale`, through the type ramp, by ``CapsuleGlyph``'s rule, so the glyph never
    /// overflows it at large sizes.
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
            // The merged » rides in B, I and S's capsule: one of its own would cost a gap and insets
            // the narrowest Split half has no room for at 135%.
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
            // Folded, the Table capsule is a submenu of the merged »; it folds only after the merge.
            if inTable && !rung.folded.contains(.table) {
                capsule(accented: true) { tableCapsule(worded: rung.worded.contains(.table)) }
            }
        }
        .fixedSize()
    }

    /// One group's capsule, its own glass track apart from the next: glass in Frosted and Clear,
    /// the quaternary capsule in Solid (`ChromeGlass`). The Table capsule wears an accent tint,
    /// because it comes and goes with the caret.
    private func capsule<Content: View>(accented: Bool = false,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Self.buttonGap) { content() }
            .padding(.horizontal, Self.capsuleInset)
            // One whole-point height for every capsule on every rung, so the text under the bar
            // never moves as it narrows. Whole, because a fractional height (the scaled box) rounds
            // differently alone and in the card, putting the text a point off.
            .frame(height: (Self.box(at: scale) + 4).rounded())
            .chromeGlassTrack()
            // A tint, not an outline: a 1pt ring breaks up at the capsule's ends, where the curve
            // runs nearly vertical; a fill antialiases cleanly.
            .background(Capsule().fill(accent.opacity(accented ? 0.12 : 0)))
    }

    /// What every button wears: the glyph, its word in Icon and Text, a chevron on a menu, in one
    /// wash, so a lit Bullets lights its word too. As tall as a bare glyph's box: words don't grow
    /// the bar.
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
        // Label colour lit or not; the wash below is the lit state. Accent words on their own
        // 0.18 wash would be as low as 1.9:1 on white.
        .foregroundStyle(.primary)
        .padding(.leading, padded ? 6 : 0)
        .padding(.trailing, padded ? (word == nil ? 5 : 8) : 0)
        .frame(minWidth: box, minHeight: box, maxHeight: box)
        // Lit: a soft accent wash, as the header's Expand wears it.
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(lit ? accent.opacity(0.18) : .clear))
        // Greyed where it would do nothing, or break the table the caret is in.
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
        // ⌥ shows the key only with the caret in the text: elsewhere ⌘I is the Info inspector and
        // the rest do nothing. Compact, because B, I and S sit closer than a full key.
        .shortcutKeycap(Self.keycap(verb), compact: true, shown: Self.caretIsInText(revealing: isRevealing))
        .disabled(!offered)
        .help(Self.tooltip(verb))
        .accessibilityLabel(verb.title)
        // "Click Bullets", the word on screen, as well as the name VoiceOver reads.
        .accessibilityInputLabels(EditorSpokenNames.names(word: Self.word(verb), label: verb.title))
        .accessibilityAddTraits(lit ? [.isButton, .isSelected] : .isButton)
    }

    /// The Table button: one press makes a table, from the selected lines when they split into
    /// cells, else a new one, named by its tooltip. Greyed in a table, where the Table capsule is.
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
        .accessibilityInputLabels(EditorSpokenNames.names(word: Self.word(Self.tableMenuStandIn), label: verb.title))
    }

    /// The Body menu: a popover of the styles, each drawn as it looks, as Notes draws its Aa list
    /// (a menu can't size each item). Labelled with the selection's level; greyed in a table,
    /// where every heading would break it.
    private func headingMenu(worded: Bool) -> some View {
        let box = Self.box(at: scale)
        let offered = !state.touchesTable
        // Accent while the selection is a heading, not over body text or a mix.
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
            EditorStylePicker(current: state.heading, accent: accent) { verb in
                showsStyles = false
                onVerb(verb)
            }
        }
        .help("Paragraph style")
        .accessibilityLabel("Paragraph style: \(Self.headingTitle(state.heading, worded: true))")
        .accessibilityInputLabels(Self.headingInputLabels(state.heading, worded: worded))
    }

    /// What Voice Control answers to on the Body menu: the word on screen ("Body", "Heading 2", or
    /// "H2" where there is no room for words), its spelled-out form, and the menu's name. A mark
    /// that can't be said ("¶", "–") is not offered.
    static func headingInputLabels(_ heading: MarkdownEdits.HeadingLevel, worded: Bool) -> [String] {
        let shown = headingTitle(heading, worded: worded)
        var names = EditorSpokenNames.names(word: headingTitle(heading, worded: true), label: "Paragraph style")
        if shown != names[0], shown.first?.isLetter == true { names.insert(shown, at: 0) }
        return names
    }

    /// The Table capsule, there while the caret is in a table. Row adds one below and Column one to
    /// the right, each with a chevron for both sides; Delete asks Row or Column; Format lines up the
    /// pipes. Each greyed where it would do nothing, such as deleting the header or the only column.
    @ViewBuilder
    private func tableCapsule(worded: Bool) -> some View {
        Image(systemName: Self.symbol(.table(.insert)))
            .scaledFont(.system(size: Self.glyphPoint, weight: .medium))
            .foregroundStyle(accent)
            .padding(.leading, 6)
            .padding(.trailing, 2)
            .accessibilityLabel("Table")
        ForEach(Array(Self.tableCapsule.enumerated()), id: \.offset) { _, control in
            switch control {
            case .press(let verb, let chevron):
                // The press does `verb`; the chevron beside it offers both sides.
                verbButton(.table(verb), worded: worded)
                tableChoice(chevron.map(MarkupVerb.table), worded: false, chevronOnly: true)
            case .menu(let verbs):
                tableChoice(verbs.map(MarkupVerb.table), worded: worded)
            case .button(let verb):
                verbButton(.table(verb), worded: worded)
            }
        }
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

    /// A folded group: one button with its group's glyph and a chevron, its verbs in a menu. Lit
    /// while one of them is applied, so a narrow bar still answers "is this already a list?".
    private func foldMenu(_ part: Part) -> some View {
        let verbs = Self.verbs(of: part)
        let lit = verbs.contains { state.lit.contains($0) }
        let offered = Self.isFoldOffered(part, in: state)
        return Menu {
            items(of: part)
        } label: {
            label(Self.symbol(part), word: nil, lit: lit, offered: offered, chevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.hoverAffordance(.glyph, tint: accent))
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!offered)
        .help(Self.title(part))
        .accessibilityLabel(Self.title(part))
        .accessibilityValue(Self.appliedValue(verbs, lit: state.lit))
    }

    /// The last resort: every folded group in one » menu, a submenu each, with Bold, Italic and
    /// Strikethrough at its top once they fold too.
    private func mergedMenu(_ rung: Rung) -> some View {
        let parts = Self.foldedParts(rung, inTable: state.isInTable)
        let marks = rung.marksFolded ? (Self.groups.first ?? []) : []
        let hidden = marks + parts.flatMap(Self.verbs(of:))
        let lit = hidden.contains { state.lit.contains($0) }
        return Menu {
            mergedItems(rung)
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

    /// The » menu's items: the marks when folded, then a submenu per folded group, or, where
    /// ``isFoldOffered(_:in:)`` greys the group, its name as a disabled item.
    ///
    /// An item, not a disabled submenu: `.disabled` on a SwiftUI `Menu` inside a menu greys only its
    /// items, and AppKit still draws the submenu live.
    @ViewBuilder
    func mergedItems(_ rung: Rung) -> some View {
        let marks = rung.marksFolded ? (Self.groups.first ?? []) : []
        ForEach(marks, id: \.self) { item($0) }
        if !marks.isEmpty { Divider() }
        ForEach(Array(Self.foldedParts(rung, inTable: state.isInTable).enumerated()), id: \.offset) { _, part in
            if Self.isFoldOffered(part, in: state) {
                Menu(Self.title(part)) { items(of: part) }
            } else {
                Button(Self.title(part)) {}
                    .disabled(true)
            }
        }
    }

    /// A folded part's items, in its order: ticked toggles for what can be lit, plain items for the
    /// rest, the Table button as its two items. Each greyed where the bar would grey it.
    private func items(of part: Part) -> some View {
        ForEach(Self.itemVerbs(of: part), id: \.self) { item($0) }
    }

    /// The items a folded part's menu lists, in its order, the Table button as its two items.
    static func itemVerbs(of part: Part) -> [MarkupVerb] {
        verbs(of: part).flatMap { verb in
            verb == tableMenuStandIn ? (MarkupVerb.tableSections.first ?? []) : [verb]
        }
    }

    /// Whether a folded group's button is live: while one of its items would do something. In a
    /// table, Lists would otherwise open a menu of nothing but greyed items.
    static func isFoldOffered(_ part: Part, in state: MarkupFormatState) -> Bool {
        itemVerbs(of: part).contains { isItemOffered($0, in: state) }
    }

    @ViewBuilder
    private func item(_ verb: MarkupVerb) -> some View {
        if Self.canLight(verb) {
            Toggle(verb.title, isOn: Binding(get: { state.lit.contains(verb) }, set: { _ in onVerb(verb) }))
                .disabled(!Self.isItemOffered(verb, in: state))
        } else {
            Button(verb.title) { onVerb(verb) }
                .disabled(!Self.isItemOffered(verb, in: state))
        }
    }
}

/// The Body menu's styles, each drawn as it looks, from Heading 1 large and bold down to Body,
/// ticked at the selection's level, as Notes draws its Aa list.
struct EditorStylePicker: View {
    let current: MarkdownEdits.HeadingLevel
    /// The window's hue, for the row under the pointer: the format bar's own.
    var accent: Color = LiquidGlassHue.stored().accentColor
    let onPick: (MarkupVerb) -> Void

    /// Each style's size and weight in the list: Preview's own, from its ramp, so a heading is drawn
    /// here as the document draws it; the body at Preview's 13 points.
    static func font(_ verb: MarkupVerb) -> (size: CGFloat, weight: Font.Weight) {
        switch verb {
        case .heading(let level) where level > 0: return (MarkdownBlockView.headingSize(level), .semibold)
        default: return (13, .regular)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(EditorFormatBar.headingVerbs, id: \.self) { verb in
                EditorStyleRow(verb: verb, isCurrent: EditorFormatBar.isCurrent(verb, current), accent: accent) { onPick(verb) }
            }
        }
        .padding(6)
        .frame(minWidth: 190)
    }
}

/// One style in ``EditorStylePicker``: a tick where it is current, its name in its own size, and
/// the row filled in the window's hue under the pointer, as a menu item is, deepened so the white
/// label clears AA (`AccentFill`).
private struct EditorStyleRow: View {
    let verb: MarkupVerb
    let isCurrent: Bool
    var accent: Color = LiquidGlassHue.stored().accentColor
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
            // Deepened as every accent fill under a white label is, so a light hue still reads.
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(hovering ? AccentFill.deepened(accent) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(verb.title)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

/// The format bar's right-click menu: Icon and Text or Icon Only, ticked at the one in force, and
/// Hide Format Bar, as Finder's toolbar offers on its right-click.
///
/// Bindings to the two stored settings, not state of its own (Icon and Text is
/// ``EditorTextSettings/formatBarShowsLabelsKey``; Hide turns off View ▸ Format Bar's setting), so
/// the menus can't disagree. No Text Only, the widest and slowest to read, and no Customize
/// Toolbar…, which would let the bar stop matching the Markup menu.
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

    /// Icon and Text (`labels`) or Icon Only, logged when it changes, as Expand's switch is, so a
    /// bar that "lost its words" can be traced to a click.
    static func choose(labels: Bool, _ showsLabels: Binding<Bool>) {
        guard showsLabels.wrappedValue != labels else { return }
        showsLabels.wrappedValue = labels
        Logger.shared.info("[edit] Format bar ▸ \(labels ? iconAndText : iconOnly)")
    }

    /// Hide Format Bar: View ▸ Format Bar's setting turned off, with the way back named in the log.
    static func hide(_ showsBar: Binding<Bool>) {
        showsBar.wrappedValue = false
        Logger.shared.info("[edit] Format bar hidden from its menu — Format Bar on the text's right-click menu, or View ▸ Format Bar, shows it again")
    }
}
