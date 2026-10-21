import Foundation
import Design

/// A markup verb: what the reader asked to do to the selection.
///
/// **Toggles, not inserts.** Every one of these that can be undone by repeating it is — pressing
/// bold on bold text takes the asterisks off. An editor whose Bold only ever adds `**` is one that
/// requires the keyboard to correct what the menu just did.
///
/// Public since the Markup menu joined the menu bar (roadmap RD1): the app target builds that menu
/// from ``menuOrder`` — the same list the context menu is built from, so the two cannot disagree
/// about the verbs or their order — and reaches each verb through ``PlainTextEditor/apply(_:to:)``.
public enum MarkupVerb: Hashable, Sendable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    /// `0` is Body: the heading marker comes off and nothing replaces it.
    case heading(Int)
    case bulletList
    case numberedList
    case taskItem
    case blockQuote
    case codeBlock
    case horizontalRule
    /// One of the Table submenu's items (TE65, TE66) — see ``TableVerb``.
    case table(TableVerb)

    /// The verbs the context menu offers, in the order it offers them; `nil` is a separator.
    ///
    /// **One flat list, because a menu item carries an `Int` and not an enum.** `NSMenuItem.tag` is
    /// how the click gets back here, so the index in this array IS the identity. Nothing stores a
    /// tag, so the order may change, but every builder must read the tag back through this list.
    ///
    /// **Grouped by what each verb changes (TE68, decision AA = C6)**, the format bar's capsules:
    /// the three plain marks; the paragraph's kind (the bar's Body menu); the lists; the two Codes
    /// with Quote, the three ways to set text apart from the prose; and what adds something new,
    /// Link, Table and Divider. **The table verbs run together inside that last group**, and every
    /// menu draws the run as one Table submenu where it starts, divided where ``tableSections``
    /// divides it; the format bar draws it as one Table button there.
    public static let menuOrder: [MarkupVerb?] = [
        .bold, .italic, .strikethrough,
        nil,
        .heading(1), .heading(2), .heading(3), .heading(0),
        nil,
        .bulletList, .numberedList, .taskItem,
        nil,
        .inlineCode, .codeBlock, .blockQuote,
        nil,
        .link,
    ] + tableSections.joined().map(Optional.some) + [.horizontalRule]

    /// The Table submenu, in its order, cut where it draws its separators: making a table, adding
    /// to one, taking from one, tidying one.
    public static let tableSections: [[MarkupVerb]] = [
        [.table(.insert), .table(.fromSelection)],
        [.table(.addRowAbove), .table(.addRowBelow), .table(.addColumnLeft), .table(.addColumnRight)],
        [.table(.deleteRow), .table(.deleteColumn)],
        [.table(.tidy)],
    ]

    /// The submenu's own title, and the format bar's Table button's word.
    public static let tableMenuTitle = "Table"

    /// **Whether this verb would take a table's lines out of it** (TE76) — the verbs that rewrite
    /// whole lines: a heading, a list or a quote marker in front of a row, a fence around rows, or
    /// a divider between them each end the table there. The inline marks and Link only wrap words
    /// inside a cell, and the Table items are the table's own. See ``MarkdownEdits/breaksTable(_:in:selection:)``.
    public var breaksTables: Bool {
        switch self {
        case .heading, .bulletList, .numberedList, .taskItem, .blockQuote, .codeBlock, .horizontalRule:
            return true
        case .bold, .italic, .strikethrough, .inlineCode, .link, .table:
            return false
        }
    }

    /// **Whether this verb wraps words in delimiters** — the inline marks and Link, which work
    /// inside one table cell and break the table when they cross into another (FMT-1).
    public var wrapsWords: Bool {
        switch self {
        case .bold, .italic, .strikethrough, .inlineCode, .link: return true
        case .heading, .bulletList, .numberedList, .taskItem, .blockQuote, .codeBlock, .horizontalRule, .table:
            return false
        }
    }

    /// **Whether this verb opens a block a paragraph's next lines join lazily** (FMT-2) — a list
    /// item or a quote. On a paragraph line right above a table, with no blank line between, the
    /// table's lines would become that item's or quote's text and cmark would draw no table; a
    /// heading ends at its own line, and a fence or divider stands on lines of its own.
    var continuesLazily: Bool {
        switch self {
        case .bulletList, .numberedList, .taskItem, .blockQuote: return true
        default: return false
        }
    }

    /// Whether this is one of the Table submenu's items.
    public var isTable: Bool {
        if case .table = self { return true }
        return false
    }

    /// The chord the menu bar registers for this verb, or `nil` for the verbs that are menu-only.
    ///
    /// **Only the five inline verbs carry one.** ⌘1…⌘4 are the workspaces, ⌥ is barred (the ⌥-hold
    /// reveal), and ⌃⌘1/2/3 went to the view modes — so headings and lists have no free chord that
    /// a Mac user would guess, and a chord nobody guesses is a chord in the ⌘/ reference for nothing.
    /// Declared on the verb rather than beside the menu item so the context menu (`PlainTextEditor`)
    /// and the Markup menu draw the same key from one place.
    public var chord: AppChord? {
        switch self {
        case .bold: return .bold
        case .italic: return .italic
        case .strikethrough: return .strikethrough
        case .inlineCode: return .inlineCode
        case .link: return .link
        case .heading, .bulletList, .numberedList, .taskItem, .blockQuote, .codeBlock,
             .horizontalRule, .table:
            return nil
        }
    }

    public var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .inlineCode: return "Inline Code"
        // No ellipsis (TE124): it opens no dialog — it writes `[text](url)` and selects the url.
        // The menus, the format bar's tooltip, VoiceOver and Undo all read this one title.
        case .link: return "Link"
        case .heading(0): return "Body"
        case .heading(let level): return "Heading \(level)"
        case .bulletList: return "Bulleted List"
        case .numberedList: return "Numbered List"
        case .taskItem: return "Task Item"
        case .blockQuote: return "Block Quote"
        case .codeBlock: return "Code Block"
        // "Divider", not "Horizontal Rule" (TE69, decision X): what you get, in one word. The case
        // keeps its Markdown name.
        case .horizontalRule: return "Divider"
        case .table(let op): return op.title
        }
    }
}

/// **What the Table submenu does** (TE65, TE66): make a table, add a row or column to one, take
/// one away, or format one so its pipes line up — Format Table, `.tidy` in code. (Not "Tidy" on
/// screen: Help retires that word, which was Organize's old name.) Each is a plain edit of the buffer —
/// ``MarkdownTables`` — taken back with one ⌘Z, like every other Markup verb.
public enum TableVerb: Hashable, Sendable, CaseIterable {
    case insert
    case fromSelection
    case addRowAbove
    case addRowBelow
    case addColumnLeft
    case addColumnRight
    case deleteRow
    case deleteColumn
    case tidy

    public var title: String {
        switch self {
        case .insert: return "Insert Table"
        case .fromSelection: return "Make Table from Selection"
        case .addRowAbove: return "Add Row Above"
        case .addRowBelow: return "Add Row Below"
        case .addColumnLeft: return "Add Column Left"
        case .addColumnRight: return "Add Column Right"
        case .deleteRow: return "Delete Row"
        case .deleteColumn: return "Delete Column"
        case .tidy: return "Format Table"
        }
    }

    /// Why the item did nothing, for the log — the menu bar's items cannot know where the caret is
    /// when they draw, so they stay enabled and a press that has nothing to do says so.
    public var refusal: String {
        switch self {
        // Either end: Insert Table goes after the line the selection ends on (FMT-16 — this said
        // "the caret is in a table" to a press whose caret was in the prose above one).
        case .insert: return "the selection starts or ends in a table, and a table cannot hold one"
        case .fromSelection: return "the selected lines hold no tabs or commas to split into cells"
        case .addRowAbove: return "the caret is not in a table's body — nothing goes above the header"
        case .deleteRow: return "the caret is not in a table's body — the header cannot be deleted"
        case .deleteColumn: return "the caret is not in a table, or it has one column left"
        case .addRowBelow, .addColumnLeft, .addColumnRight, .tidy: return "the caret is not in a table"
        }
    }
}

/// A buffer and where the selection should be in it afterwards.
struct MarkupEdit: Equatable, Sendable {
    var text: String
    /// **In UTF-16, because that is what `NSTextView` speaks.** Everything else in this app counts
    /// characters; this one value is handed straight to `setSelectedRange`, so converting it would
    /// mean converting it back.
    var selection: NSRange
}

extension MarkdownEdits {

    /// Applies a verb to a selection, or answers `nil` when it does not apply.
    static func apply(_ verb: MarkupVerb, to text: String, selection: NSRange) -> MarkupEdit? {
        let ns = text as NSString
        guard selection.location != NSNotFound,
              selection.location >= 0,
              NSMaxRange(selection) <= ns.length else { return nil }
        // Refused, not applied, where it would break a table (TE76) — the format bar greys these
        // buttons there, and the menus that cannot grey them say so in the log.
        if breaksTable(verb, ns, selection) { return nil }

        switch verb {
        case .bold, .italic, .strikethrough, .inlineCode:
            guard let mark = inlineDelimiter(for: verb) else { return nil }
            let runs = inlineRuns(selection, in: ns)
            guard !runs.isEmpty else { return nil }
            return wrapRuns(text, runs, with: mark)
        case .link: return link(text, selection)
        case .heading, .bulletList, .numberedList, .taskItem, .blockQuote:
            guard let prefix = linePrefix(for: verb) else { return nil }
            return prefixLines(text, selection, prefix)
        case .codeBlock: return fence(text, selection)
        case .horizontalRule: return rule(text, selection)
        case .table(let op): return MarkdownTables.apply(op, to: text, selection: selection)
        }
    }

    /// **Whether `verb` would break a table here** (TE76): it rewrites whole lines
    /// (``MarkupVerb/breaksTables``) and the selection starts or ends inside a table, so the lines
    /// it would rewrite include rows. A heading, list or quote marker in front of a row, or a fence
    /// or divider among them, ends the table at that line, and the rows after it read as text.
    ///
    /// **Pure, and the one rule for every door** — ``apply(_:to:selection:)`` refuses on it, the
    /// format bar greys on it (``MarkupFormatState/touchesTable``), and editable Preview (TE67) can
    /// ask it of the same buffer. A selection running from prose before a table to prose after it
    /// is not refused: it says, by its own ends, that the table is part of what it means.
    static func breaksTable(_ verb: MarkupVerb, in text: String, selection: NSRange) -> Bool {
        let ns = text as NSString
        guard isValid(selection, in: ns) else { return false }
        return breaksTable(verb, ns, selection)
    }

    static func breaksTable(_ verb: MarkupVerb, _ ns: NSString, _ selection: NSRange) -> Bool {
        (verb.breaksTables && (MarkdownTables.touches(ns, selection)
                               || verb.continuesLazily && MarkdownTables.abuts(ns, selection)))
            || (verb.wrapsWords && crossesCells(ns, selection))
    }

    /// **Whether a selection in a table runs across its cells** (FMT-1) — over a pipe, or over a
    /// line break into another row or out of the table — where an inline mark or a link would break
    /// it. A triple-clicked row wrapped in Bold became `**| Day | Where |\n**|-----|…`: three cells
    /// in the header over a delimiter row that no longer was one, and the table read as paragraphs.
    /// The marks were offered there because they "only wrap words inside a cell"; inside one they
    /// still do.
    ///
    /// `touches`, when the caller has it already — the format bar and both right-click menus read
    /// it with the rest through ``MarkdownTables/reading(_:_:)`` — so the selection is parsed once
    /// (TBL-19) rather than again here.
    static func crossesCells(_ ns: NSString, _ selection: NSRange, touches: Bool? = nil) -> Bool {
        guard selection.length > 0, isValid(selection, in: ns),
              touches ?? MarkdownTables.touches(ns, selection) else { return false }
        let selected = ns.substring(with: selection)
        return selected.contains(where: \.isNewline) || MarkdownTables.hasUnescapedPipe(selected)
    }

    /// **Whether pressing `verb` now would TAKE its formatting off** — the format bar's lit state
    /// (TE52), answered by the very tests ``apply(_:to:selection:)`` uses to choose between adding
    /// and removing: ``wrapState(_:_:delimiter:guardingAgainst:)`` for the inline verbs and
    /// ``everyLineHas(_:_:in:)`` for the line verbs. So a lit button is exactly a button whose press
    /// would unwrap, and a dark one exactly a press that would wrap.
    ///
    /// **Which means it is about the SELECTION, not about the caret's surroundings.** A caret parked
    /// in the middle of `**plenty**` is not lit, because Bold there inserts a second pair; double-
    /// click the word — which selects it between its asterisks — and it is. That is the verbs' own
    /// rule, kept rather than widened: a button that lit for a press that would then add `****`
    /// would be promising a toggle the verb does not perform.
    ///
    /// **Never lit:** Link, Code Block and Divider, which only ever insert; Body, which only
    /// ever removes and so has no "on"; and a line verb over blank lines alone, where the press
    /// changes nothing (``prefixLines(_:_:_:)`` answers `nil` there).
    static func isApplied(_ verb: MarkupVerb, in text: String, selection: NSRange) -> Bool {
        let ns = text as NSString
        guard isValid(selection, in: ns) else { return false }
        return isApplied(verb, ns, selection, survey: LineSurvey(covering: selection, in: ns))
    }

    /// The core of ``isApplied(_:in:selection:)``, over a buffer already bridged and the lines the
    /// selection touches already surveyed — so ``MarkupFormatState`` can ask every verb about one
    /// selection and walk (and parse) its lines ONCE. On a selection of a few lines that is
    /// nothing; on ⌘A in a long note it is one walk instead of a dozen. `selection` must be in range.
    static func isApplied(_ verb: MarkupVerb, _ ns: NSString, _ selection: NSRange,
                          survey: LineSurvey) -> Bool {
        switch verb {
        case .bold, .italic, .strikethrough, .inlineCode:
            guard let mark = inlineDelimiter(for: verb) else { return false }
            let runs = inlineRuns(selection, in: ns, survey: survey)
            return !runs.isEmpty && runs.allSatisfy {
                wrapState(ns, $0, delimiter: mark.delimiter, guardingAgainst: mark.neighbour, nests: mark.nests) != nil
            }
        case .heading(let level) where level <= 0:
            return false
        case .heading, .bulletList, .numberedList, .taskItem, .blockQuote:
            guard let prefix = linePrefix(for: verb) else { return false }
            let written = survey.written(for: prefix)
            return !written.isEmpty && everyLineHas(prefix, written, in: ns, survey: survey)
        case .link, .codeBlock, .horizontalRule, .table:
            // Inserts, or a submenu — never a toggle that is on. Where the caret is IN a table is
            // `MarkupFormatState.tables`, which the bar's Table button and capsule read.
            return false
        }
    }

    /// What the format bar's Body menu names: the level the selection's lines are at.
    enum HeadingLevel: Equatable, Sendable {
        /// Heading 1, 2 or 3 — the three the menu offers — on every written line.
        case level(Int)
        /// Every written line is a heading, but not one the menu ticks: levels 4–6, or headings at
        /// different levels.
        case otherHeading
        /// Headings and body text together. Neither name would be true of the selection, so the
        /// menu names neither and ticks nothing.
        case mixed
        /// No written line is a heading.
        case body
    }

    /// **Level-exact first, and only then level-agnostic** — never the other way round. A `# Title`
    /// line answers Heading 1 because ``isApplied(_:in:selection:)`` says Heading 1 would come off
    /// it, not because it "is a heading"; asking the second question first is the conflation that
    /// once demoted `# Title` when Heading 3 was asked for. The level-agnostic pattern
    /// (``LinePrefix/pattern``, what a heading verb strips) is asked only of what is left: whether
    /// the written lines are all headings, none, or some of each.
    static func headingLevel(in text: String, selection: NSRange) -> HeadingLevel {
        let ns = text as NSString
        guard isValid(selection, in: ns) else { return .body }
        return headingLevel(ns, selection, survey: LineSurvey(covering: selection, in: ns))
    }

    /// The core of ``headingLevel(in:selection:)`` — see ``isApplied(_:_:_:survey:)`` for why the
    /// survey is handed in.
    static func headingLevel(_ ns: NSString, _ selection: NSRange, survey: LineSurvey) -> HeadingLevel {
        for level in 1...3 where isApplied(.heading(level), ns, selection, survey: survey) {
            return .level(level)
        }
        var headings = false
        var body = false
        for range in survey.written(for: .heading(1)) {
            if survey.setext(range) != nil { headings = true; if body { return .mixed }; continue }
            let full = ns.substring(with: range)
            let line = (full as NSString).substring(from: containerLength(full, for: .heading(1)))
            if firstMatch(LinePrefix.heading(1).pattern, in: line) != nil { headings = true } else { body = true }
            if headings && body { return .mixed }
        }
        return headings ? .otherHeading : .body
    }

    /// **The lines a line verb covers, and what each one is** (FMT-6) — found once per selection,
    /// so the format bar asks every verb about one walk and one parse.
    struct LineSurvey: Equatable, Sendable {
        var lines: [NSRange]
        var roles: [MarkdownSourceContext.LineRole]
        /// The setext headings among the lines, by their words' start (FMT-13).
        private var setexts: [Int: Setext] = [:]

        /// A setext heading's level and its underline's line.
        struct Setext: Equatable, Sendable {
            var level: Int
            var underline: NSRange
        }

        init(covering selection: NSRange, in ns: NSString) {
            lines = MarkdownEdits.lineRanges(covering: selection, in: ns)
            roles = MarkdownSourceContext.roles(of: lines, in: ns)
            for (line, role) in zip(lines, roles) {
                if case .setext(let level, let underline) = role {
                    setexts[line.location] = Setext(level: level, underline: underline)
                }
            }
        }

        /// The setext heading `line` is the words of, if it is one.
        func setext(_ line: NSRange) -> Setext? { setexts[line.location] }

        /// The lines `prefix` rewrites: words — never a blank line, and never code, front matter,
        /// raw HTML or a divider, which are left byte for byte and decide nothing. **For a list
        /// verb, not the indented lines that carry an item on either** (FMT-7): `  continued` under
        /// `- long item` is the item's own words, and Bullets made it an item of its own,
        /// `-   continued`.
        ///
        /// **A setext heading is its words' line** (FMT-13), its underline going with it — except
        /// for Quote, which quotes the underline as a line of its own, so the heading stays one
        /// inside the quote.
        func written(for prefix: LinePrefix) -> [NSRange] {
            var written: [NSRange] = []
            let quotes: Bool
            if case .quote = prefix { quotes = true } else { quotes = false }
            for (line, role) in zip(lines, roles) {
                switch role {
                case .text, .tableRow: written.append(line)
                case .continuation: if !prefix.isList { written.append(line) }
                case .setext(_, let underline):
                    written.append(line)
                    if quotes, !lines.contains(underline) { written.append(underline) }
                case .underline: if quotes { written.append(line) }
                case .blank, .literal: break
                }
            }
            return written
        }

        /// Blank lines and nothing else — where a verb STARTS an item. A blank line in a code
        /// block is code's.
        var isBlankOnly: Bool { !roles.isEmpty && roles.allSatisfy { $0 == .blank } }
    }

    /// Whether `selection` lies in `ns` — the guard every entry point here starts with.
    static func isValid(_ selection: NSRange, in ns: NSString) -> Bool {
        selection.location != NSNotFound && selection.location >= 0 && NSMaxRange(selection) <= ns.length
    }

    /// A line holding nothing but spaces and tabs — which every line verb leaves alone.
    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The delimiter an inline verb wraps with, the character that must not sit just beyond it for
    /// an unwrap to count, and whether one span of it may hold the delimiter again (`nests` — see
    /// ``wrapState(_:_:delimiter:guardingAgainst:nests:)``). One table, read by
    /// ``apply(_:to:selection:)`` and ``isApplied(_:in:selection:)`` alike.
    static func inlineDelimiter(for verb: MarkupVerb)
        -> (delimiter: String, neighbour: String?, nests: Bool)? {
        switch verb {
        case .bold: return ("**", nil, false)
        case .italic: return ("*", "*", true)
        case .strikethrough: return ("~~", nil, false)
        case .inlineCode: return ("`", nil, false)
        default: return nil
        }
    }

    /// The line prefix a line verb adds or removes. One table, for the reason
    /// ``inlineDelimiter(for:)`` is one.
    static func linePrefix(for verb: MarkupVerb) -> LinePrefix? {
        switch verb {
        case .heading(let level): return .heading(level)
        case .bulletList: return .bullet
        case .numberedList: return .numbered
        case .taskItem: return .task
        case .blockQuote: return .quote
        default: return nil
        }
    }

    // MARK: Inline

    /// **What an inline verb wraps: the selection's words, line by line** (FMT-10). The spaces and
    /// line breaks at its ends are left out — a triple-click takes the line break, and
    /// `**first line\n**` is no bold — and a selection over several lines is cut at each break,
    /// because emphasis cannot cross a paragraph and `**one\n\ntwo**` is two literal pairs. Each
    /// line's run starts past its quote, list or heading marker, so `- one` selected whole becomes
    /// `- **one**`, not `**- one**`, which is no list item. Across several lines, code, front
    /// matter, raw HTML, dividers and table rows are skipped: their characters are not prose.
    ///
    /// A selection that is all spaces is left as it is, and so is a bare caret.
    static func inlineRuns(_ selection: NSRange, in ns: NSString, survey known: LineSurvey? = nil) -> [NSRange] {
        guard selection.length > 0 else { return [selection] }
        let words = trimmed(selection, in: ns, characters: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\n\r")))
        guard words.length > 0 else { return [selection] }
        // Cut at the parser's line breaks — `\n`, `\r\n`, `\r` — and not at U+2028 or U+2029,
        // which NSString breaks lines at and Markdown reads as characters of the line.
        var runs: [NSRange] = []
        var line = MarkdownSourceLines.line(containing: words.location, in: ns)
        while true {
            let piece = NSIntersectionRange(line.content, words)
            if piece.length > 0 {
                let text = ns.substring(with: NSRange(location: line.content.location,
                                                      length: NSMaxRange(piece) - line.content.location))
                let markerEnd = line.content.location + markerLength(of: text)
                var run = piece
                if run.location < markerEnd {
                    run = NSRange(location: markerEnd, length: max(0, NSMaxRange(run) - markerEnd))
                }
                run = trimmed(run, in: ns, characters: .whitespaces)
                if run.length > 0 { runs.append(run) }
            }
            guard line.end < NSMaxRange(words), let next = MarkdownSourceLines.line(after: line, in: ns) else { break }
            line = next
        }
        if runs.count > 1 {
            let survey = known ?? LineSurvey(covering: selection, in: ns)
            let prose = Set(zip(survey.lines, survey.roles).compactMap { line, role -> Int? in
                switch role {
                case .text, .continuation, .setext: return line.location
                case .blank, .literal, .underline, .tableRow: return nil
                }
            })
            // None at all when every line is code, a table or the like: nothing for a mark to wrap.
            return runs.filter { run in
                prose.contains(ns.lineRange(for: NSRange(location: run.location, length: 0)).location)
            }
        }
        return runs.isEmpty ? [selection] : runs
    }

    /// `range` without the `characters` at either end.
    private static func trimmed(_ range: NSRange, in ns: NSString, characters: CharacterSet) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        while start < end, let scalar = UnicodeScalar(ns.character(at: start)), characters.contains(scalar) { start += 1 }
        while end > start, let scalar = UnicodeScalar(ns.character(at: end - 1)), characters.contains(scalar) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// How far into `line` its block markers run: quote markers and indentation, then a task's,
    /// a bullet's, a number's or a heading's marker.
    private static func markerLength(of line: String) -> Int {
        let container = containerLength(line, for: .bullet)
        let rest = (line as NSString).substring(from: container)
        for prefix in [LinePrefix.task, .bullet, .numbered, .heading(1)] {
            if let match = firstMatch(prefix.pattern, in: rest) { return container + match.length }
        }
        return container
    }

    /// **The inline verb over each run** (FMT-10): every run already wrapped comes off; otherwise
    /// the ones that are not get a pair — the line verbs' "every one" rule, so a mixed selection is
    /// finished rather than turned inside out. One run is ``wrap(_:_:with:guardingAgainst:nests:)``
    /// exactly. Several are made left to right, and the selection runs from the first run to the
    /// last — their delimiters included where they are wrapped, so the selection reads as wrapped
    /// and the next press of the same verb takes every pair off again.
    static func wrapRuns(_ text: String, _ runs: [NSRange],
                         with mark: (delimiter: String, neighbour: String?, nests: Bool)) -> MarkupEdit {
        if runs.count == 1 {
            return wrap(text, runs[0], with: mark.delimiter, guardingAgainst: mark.neighbour, nests: mark.nests)
        }
        let ns = text as NSString
        let states = runs.map { wrapState(ns, $0, delimiter: mark.delimiter, guardingAgainst: mark.neighbour, nests: mark.nests) }
        let unwrapping = states.allSatisfy { $0 != nil }
        var current = text
        var shift = 0
        var covered: [NSRange] = []
        for (run, state) in zip(runs, states) {
            let here = NSRange(location: run.location + shift, length: run.length)
            if !unwrapping, let state {
                // Already wrapped: left as it is, its pair inside the selection.
                switch state {
                case .inside: covered.append(here)
                case .outside(let open, let close):
                    covered.append(NSRange(location: here.location - open, length: open + here.length + close))
                }
                continue
            }
            let edit = wrap(current, here, with: mark.delimiter, guardingAgainst: mark.neighbour, nests: mark.nests)
            let added = (edit.text as NSString).length - (current as NSString).length
            shift += added
            current = edit.text
            covered.append(unwrapping ? edit.selection : NSRange(location: here.location, length: here.length + added))
        }
        let start = covered.first?.location ?? 0
        let end = covered.last.map(NSMaxRange) ?? start
        return MarkupEdit(text: current, selection: NSRange(location: start, length: max(0, end - start)))
    }

    /// Wraps the selection, or unwraps it when it is already wrapped.
    ///
    /// - Parameter guardingAgainst: a character that must NOT sit just outside the delimiters for
    ///   an unwrap to count. This is what stops Italic on the inside of `**bold**` seeing one `*`
    ///   on each side and quietly demoting it — with the guard, italic on bold text produces
    ///   `***both***`, which is what was asked for.
    static func wrap(_ text: String, _ selection: NSRange, with delimiter: String,
                     guardingAgainst neighbour: String? = nil, nests: Bool = true) -> MarkupEdit {
        let ns = text as NSString
        let selected = ns.substring(with: selection)

        switch wrapState(ns, selection, delimiter: delimiter, guardingAgainst: neighbour, nests: nests) {
        case .inside(let open, let close):
            // Wrapped inside the selection: `**bold**` selected whole.
            let inner = (selected as NSString).substring(
                with: NSRange(location: open, length: (selected as NSString).length - open - close))
            return MarkupEdit(text: ns.replacingCharacters(in: selection, with: inner),
                              selection: NSRange(location: selection.location,
                                                 length: (inner as NSString).length))
        case .outside(let open, let close):
            // Wrapped just outside it: `bold` selected between the asterisks.
            let outer = NSRange(location: selection.location - open, length: open + selection.length + close)
            return MarkupEdit(text: ns.replacingCharacters(in: outer, with: selected),
                              selection: NSRange(location: outer.location, length: selection.length))
        case nil:
            // Otherwise wrap it. An empty selection becomes an empty pair with the caret inside,
            // which is what somebody who pressed Bold before typing the word meant.
            let (opening, closing) = delimiter == "`" ? codeDelimiters(around: selected) : (delimiter, delimiter)
            let wrapped = opening + selected + closing
            return MarkupEdit(text: ns.replacingCharacters(in: selection, with: wrapped),
                              selection: NSRange(location: selection.location + (opening as NSString).length,
                                                 length: selection.length))
        }
    }

    /// Where an inline verb's delimiters already are, if they are — which is what makes a press
    /// take them off rather than add a second pair — and how many characters they take at the
    /// start and at the end: a code span's run of backticks can be any length, with a space inside
    /// it (FMT-20).
    enum WrapState: Equatable {
        /// The selection's own ends: `**bold**` selected whole.
        case inside(open: Int, close: Int)
        /// Just outside it: `bold` selected between the asterisks.
        case outside(open: Int, close: Int)
    }

    /// **What Inline Code wraps `selected` in** (FMT-20): one backtick, or — when the text holds
    /// backticks of its own — a run one longer than its longest, with a space inside it where the
    /// text starts or ends with one. A single backtick around `` use `a` here `` closed at the
    /// first backtick inside and left three runs, code, plain and code.
    static func codeDelimiters(around selected: String) -> (String, String) {
        var longest = 0, run = 0
        for character in selected {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = selected.hasPrefix("`") || selected.hasSuffix("`") ? " " : ""
        return (fence + pad, pad + fence)
    }

    /// **The "already applied" half of ``wrap(_:_:with:guardingAgainst:)``, on its own.** One test,
    /// asked by the verb (to decide between wrapping and unwrapping) and by the format bar (to
    /// decide whether the button is lit), so a button can never light for a press that would add
    /// delimiters, nor stay dark for one that would remove them (TE52).
    ///
    /// `.inside` is `**bold**` selected whole; `.outside` is `bold` selected between its
    /// delimiters, with `neighbour` refusing the case where one more of the same character sits
    /// beyond them — see `guardingAgainst`. `nil` is "not wrapped": the press would add a pair.
    ///
    /// **`nests: false` — every inline verb but Italic — and a run holding the delimiter is not one
    /// span.** `**Warning** read the **docs**` selected whole starts and ends with `**`, and was taken
    /// for one bold span: Bold "took it off" by deleting the outer pairs, leaving
    /// `Warning** read the **docs` — the two bold words plain and the words between them bold, the
    /// formatting turned inside out. The same for `` `a` and `b` `` and for `~~`. For the rest such
    /// a run is "not wrapped", and the press adds a pair instead of destroying two.
    /// `MarkupWrapEquivalenceTests` holds every other case to the old answer.
    ///
    /// **Italic is read by its runs of stars instead** — ``italicState(_:_:)`` — because its
    /// delimiter is also half of Bold's: `neighbour` and `nests` say nothing for it.
    static func wrapState(_ ns: NSString, _ selection: NSRange, delimiter: String,
                          guardingAgainst neighbour: String? = nil,
                          nests: Bool = true) -> WrapState? {
        if delimiter == "*" { return italicState(ns, selection) }
        if delimiter == "`" { return codeState(ns, selection) }
        let width = (delimiter as NSString).length
        let selected = ns.substring(with: selection)
        let length = (selected as NSString).length
        if length >= width * 2, selected.hasPrefix(delimiter), selected.hasSuffix(delimiter) {
            let inner = (selected as NSString).substring(with: NSRange(location: width, length: length - width * 2))
            if nests || !inner.contains(delimiter) { return .inside(open: width, close: width) }
        }
        let before = NSRange(location: selection.location - width, length: width)
        let after = NSRange(location: NSMaxRange(selection), length: width)
        if selection.location >= width, NSMaxRange(after) <= ns.length,
           ns.substring(with: before) == delimiter, ns.substring(with: after) == delimiter,
           !isNeighboured(ns, before: before, after: after, by: neighbour),
           nests || !selected.contains(delimiter) {
            return .outside(open: width, close: width)
        }
        return nil
    }

    /// **A code span, read as CommonMark reads one** (FMT-20): a run of backticks opens it and the
    /// next run of the SAME length closes it, whatever lies between; one space inside each run is
    /// padding when the code both starts and ends with one. Selected whole, the span is `.inside`;
    /// its code selected — padding or not — is `.outside`. One backtick on each side was all this
    /// knew, so a span written with two (`` ``y`` ``) lost one per press and stayed code; a span
    /// Code had written around backticks could not be taken off; and the words BETWEEN two spans
    /// (`` `a` and `b` `` with ` and ` selected) were read as the code of one.
    private static func codeState(_ ns: NSString, _ selection: NSRange) -> WrapState? {
        let tick: unichar = 0x60
        func run(at index: Int, limit: Int) -> Int {
            var end = index
            while end < limit, ns.character(at: end) == tick { end += 1 }
            return end - index
        }
        // A caret between an empty pair — what a press over nothing wrote — is in that pair.
        if selection.length == 0, selection.location > 0, selection.location < ns.length,
           ns.character(at: selection.location - 1) == tick, ns.character(at: selection.location) == tick,
           (selection.location < 2 || ns.character(at: selection.location - 2) != tick),
           (selection.location + 1 >= ns.length || ns.character(at: selection.location + 1) != tick) {
            return .outside(open: 1, close: 1)
        }
        let lines = ns.lineRange(for: selection)
        let limit = NSMaxRange(lines)
        var index = lines.location
        while index < limit {
            guard ns.character(at: index) == tick else { index += 1; continue }
            let length = run(at: index, limit: limit)
            // The next run of exactly this length closes it; any other run is part of the code.
            var probe = index + length
            var close: Int?
            while probe < limit {
                guard ns.character(at: probe) == tick else { probe += 1; continue }
                let other = run(at: probe, limit: limit)
                if other == length { close = probe; break }
                probe += other
            }
            guard let close else { index += length; continue }
            let span = NSRange(location: index, length: close + length - index)
            if span == selection {
                let pad = padding(ns, index + length, close)
                return .inside(open: length + pad, close: length + pad)
            }
            let code = NSRange(location: index + length, length: close - index - length)
            let pad = padding(ns, code.location, NSMaxRange(code))
            let padded = NSRange(location: code.location + pad, length: code.length - 2 * pad)
            if selection == code || selection == padded {
                return .outside(open: selection.location - index, close: NSMaxRange(span) - NSMaxRange(selection))
            }
            index = NSMaxRange(span)
        }
        return nil
    }

    /// 1 when the code between `start` and `end` is padded — a space at each end and something
    /// else between — and 0 otherwise.
    private static func padding(_ ns: NSString, _ start: Int, _ end: Int) -> Int {
        guard end - start >= 3, ns.character(at: start) == 0x20, ns.character(at: end - 1) == 0x20 else { return 0 }
        let inner = ns.substring(with: NSRange(location: start + 1, length: end - start - 2))
        return inner.allSatisfy({ $0 == " " }) ? 0 : 1
    }

    /// **Italic, read by the length of each run of stars** (FMT-4, FMT-11). A `*` is also half of
    /// `**`, so one star beside the selection says nothing until its whole run is counted: a run of
    /// one or three is italic (`*x*`, `***x***`), a run of two is bold alone (`**x**`).
    ///
    /// The neighbour guard this replaces asked only "is there one more star", and got both ends
    /// wrong. Italic on `**loud**` selected whole found a star at each end and took them off —
    /// bold demoted to italic, and the button lit as if the word were italic. Pressed on `bold`
    /// inside `***bold***` it saw the extra star, refused, and added an eighth, so the second press
    /// of Italic on a bold word never came back to the bytes it started from.
    ///
    /// `.inside`: the selection starts and ends with stars, each run odd counting the stars just
    /// outside it — the press takes the selection's first and last star. `.outside`: the selection
    /// holds no star at either end and an odd run sits against each — the press takes the star on
    /// each side. A run of two gets a third, which is bold-italic, and a third press takes it back.
    private static func italicState(_ ns: NSString, _ selection: NSRange) -> WrapState? {
        let start = selection.location, end = NSMaxRange(selection)
        let lead = starRun(ns, from: start, forward: true, limit: end)
        let trail = starRun(ns, from: end, forward: false, limit: start)
        let before = starRun(ns, from: start, forward: false, limit: 0)
        let after = starRun(ns, from: end, forward: true, limit: ns.length)
        if lead > 0, trail > 0 {
            // All stars, or one run read from both ends: not a span with words in it.
            guard lead + trail < selection.length,
                  (lead + before) % 2 == 1, (trail + after) % 2 == 1,
                  !holdsLoneStar(ns, NSRange(location: start + 1, length: selection.length - 2))
            else { return nil }
            return .inside(open: 1, close: 1)
        }
        guard lead == 0, trail == 0, before % 2 == 1, after % 2 == 1,
              !holdsLoneStar(ns, selection) else { return nil }
        // A bare caret inside ONE run of stars (`*|***`) splits nothing: only an even split is a pair.
        guard selection.length > 0 || before == after else { return nil }
        return .outside(open: 1, close: 1)
    }

    /// **Whether `range` holds a run of stars of odd length** — an italic opening or closing of
    /// its own, so what lies between the outer stars is two spans, not one (FMT-5). Bold's pairs
    /// inside are fine: `*a **b** c*` is one italic span holding a bold word. `*Warning* read the
    /// *docs*` selected whole is not, and taking its outer stars off turned it inside out —
    /// `Warning* read the *docs`, every italic gone — the defect Bold, Strikethrough and Code were
    /// mended of in TE52.
    private static func holdsLoneStar(_ ns: NSString, _ range: NSRange) -> Bool {
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            guard ns.character(at: index) == 0x2A else { index += 1; continue }
            var runEnd = index
            while runEnd < end, ns.character(at: runEnd) == 0x2A { runEnd += 1 }
            var run = runEnd - index
            // `\*` is a literal star, not part of any run.
            if index > 0, ns.character(at: index - 1) == 0x5C { run -= 1 }
            if run % 2 == 1 { return true }
            index = runEnd
        }
        return false
    }

    /// How many unescaped `*` run from `from` — forward through `from…`, or backward through
    /// `…from-1` — stopping at `limit`. A star after a backslash is a literal, not a delimiter.
    private static func starRun(_ ns: NSString, from: Int, forward: Bool, limit: Int) -> Int {
        let star: unichar = 0x2A, backslash: unichar = 0x5C
        var count = 0
        if forward {
            var index = from
            while index < limit, ns.character(at: index) == star { count += 1; index += 1 }
            if count > 0, from > 0, ns.character(at: from - 1) == backslash { count -= 1 }
        } else {
            var index = from - 1
            while index >= limit, index >= 0, ns.character(at: index) == star { count += 1; index -= 1 }
            if count > 0, index >= 0, ns.character(at: index) == backslash { count -= 1 }
        }
        return count
    }

    private static func isNeighboured(_ ns: NSString, before: NSRange, after: NSRange,
                                      by neighbour: String?) -> Bool {
        guard let neighbour else { return false }
        let width = (neighbour as NSString).length
        let outerBefore = NSRange(location: before.location - width, length: width)
        if outerBefore.location >= 0, ns.substring(with: outerBefore) == neighbour { return true }
        let outerAfter = NSRange(location: NSMaxRange(after), length: width)
        if NSMaxRange(outerAfter) <= ns.length, ns.substring(with: outerAfter) == neighbour {
            return true
        }
        return false
    }

    /// `[selection](url)`, with the half that still needs typing selected.
    ///
    /// **Which half depends on what was selected.** With words selected, the words are the link
    /// text and the destination is what is missing; with nothing selected, both are missing and the
    /// text is what gets typed first.
    static func link(_ text: String, _ selection: NSRange) -> MarkupEdit {
        let ns = text as NSString
        let selected = ns.substring(with: selection)
        if selection.length == 0 {
            let inserted = "[text](url)"
            return MarkupEdit(text: ns.replacingCharacters(in: selection, with: inserted),
                              selection: NSRange(location: selection.location + 1, length: 4))
        }
        let inserted = "[\(selected)](url)"
        // The `url` placeholder: past `[`, the text, `](`.
        let start = selection.location + 1 + (selected as NSString).length + 2
        return MarkupEdit(text: ns.replacingCharacters(in: selection, with: inserted),
                          selection: NSRange(location: start, length: 3))
    }

    // MARK: Line prefixes

    /// What a line-level verb does to one line.
    enum LinePrefix {
        case heading(Int)
        case bullet
        case numbered
        case task
        case quote

        var isQuote: Bool {
            if case .quote = self { return true }
            return false
        }

        /// Bulleted, Numbered or Task — the verbs a list item's carried-on lines belong to.
        var isList: Bool {
            switch self {
            case .bullet, .numbered, .task: return true
            case .heading, .quote: return false
            }
        }

        /// What already-applied looks like.
        var pattern: String {
            switch self {
            case .heading: return "^#{1,6}[ \t]+"
            // **Not a task**, which also opens with a bullet: pressing Bulleted List on a checklist
            // should make it a plain list, not strip the dash and leave the boxes behind.
            case .bullet: return "^[-*+][ \t]+(?!\\[[ xX]\\](?:[ \t]|$))"
            case .numbered: return "^[0-9]+[.)][ \t]+"
            // **A box with nothing after it is a task too** (FMT-21): `- [ ]` with its trailing
            // space trimmed was read as a bullet whose text is `[ ]`, and Tasks on it wrote a
            // second box — `- [ ] [ ]`.
            case .task: return "^[-*+][ \t]+\\[[ xX]\\](?:[ \t]+|$)"
            case .quote: return "^>[ \t]?"
            }
        }

        /// What counts as "this verb is ALREADY applied here", which decides whether a press adds
        /// or removes.
        ///
        /// **Not the same question as ``pattern``, and conflating them broke headings.** `pattern`
        /// is what gets stripped — any heading marker — while this is what the press asked for. A
        /// document line reading `# Title` matches "is a heading", so asking for Heading 3 on it
        /// was read as "it already has one, take it off" and demoted the line to a paragraph.
        /// Level-exact here, level-agnostic there.
        var appliedPattern: String {
            switch self {
            case .heading(let level):
                guard level > 0 else { return "(?!)" }   // matches nothing: Body only ever removes
                return "^#{\(min(level, 6))}[ \t]+"
            default: return pattern
            }
        }

        /// Prefixes of OTHER kinds this one replaces rather than stacks on.
        ///
        /// **Quote replaces nothing**, which is the one asymmetry here and it is Markdown's: `> `
        /// nests in front of whatever the line already was, so quoting a bulleted list leaves a
        /// quoted bulleted list. The rest are alternatives to each other — a line is a heading or a
        /// list item, not both.
        var replaces: [String] {
            switch self {
            case .quote: return []
            default: return [LinePrefix.heading(1).pattern, LinePrefix.bullet.pattern,
                             LinePrefix.numbered.pattern, LinePrefix.task.pattern]
            }
        }

        func text(at index: Int) -> String {
            switch self {
            case .heading(let level):
                return level <= 0 ? "" : String(repeating: "#", count: min(level, 6)) + " "
            case .bullet: return "- "
            case .numbered: return "\(index + 1). "
            case .task: return "- [ ] "
            case .quote: return "> "
            }
        }
    }

    /// Adds a line prefix to every line the selection touches, or takes it off when every one of
    /// them already has it.
    ///
    /// **"Every one" is the rule, and the alternative is worse.** Toggling per line turns a mixed
    /// selection inside out — the plain lines become quoted and the quoted ones plain — which is
    /// never what somebody dragging across a paragraph meant. Asking whether they ALL have it means
    /// the first press finishes the job and the second undoes it.
    static func prefixLines(_ text: String, _ selection: NSRange, _ prefix: LinePrefix) -> MarkupEdit? {
        let ns = text as NSString
        let survey = LineSurvey(covering: selection, in: ns)
        let lines = survey.lines
        guard !lines.isEmpty else { return nil }

        // **On blank lines alone the verb STARTS one** — a caret on an empty line, or an empty
        // note: Bullets writes "- ", Numbered "1. ", Tasks "- [ ] ", a heading "# ", Quote "> ",
        // and the caret goes after it. Reported 2026-10-05 ("Bullets, Numbered, Tasks don't seem
        // to work … not on blank lines"): the blank-line rule below left nothing to change, so the
        // press did nothing, where every editor starts the item.
        if survey.isBlankOnly {
            return startingLines(ns, selection, lines, prefix)
        }
        // **Only words are rewritten** (FMT-6): code, front matter, raw HTML and dividers are left
        // as they are, and decide nothing about whether the verb adds or removes. Over nothing
        // else — a caret in a code block — the verb does nothing.
        let written = survey.written(for: prefix)
        guard !written.isEmpty else { return nil }

        // Body is a removal with nothing to put back, so it is never a toggle.
        let isRemoval: Bool
        if case .heading(let level) = prefix, level <= 0 {
            isRemoval = true
        } else {
            isRemoval = everyLineHas(prefix, written, in: ns, survey: survey)
        }

        // **Each line's change is its marker, and nothing else** — the characters a marker
        // occupies at the line's start, replaced by the marker the verb writes (or by nothing).
        // Kept as edits rather than rewritten lines so the selection can be carried through them
        // (FMT-8) and the buffer is still spliced once.
        var edits: [LineEdit] = []
        // **Counted per level** (FMT-7): a nested item numbers from 1 under its parent, and the
        // count of a level goes when a shallower line comes back to the one above it.
        var counts: [String: Int] = [:]
        var lastLineAfter = ""
        // A blank line inside a selection keeps its blankness: prefixing it would put a lone `- `
        // between two paragraphs.
        for range in written {
            let line = ns.substring(with: range) as NSString
            // **The marker goes after the line's container** — its quote markers and indentation
            // (FMT-7) — so `> Title` becomes `> ## Title`, not `## > Title`, and `  - b` keeps its
            // nesting rather than gaining a second marker, `-   - b`.
            let start = containerLength(line as String, for: prefix)
            let container = line.substring(to: start)
            let rest = line.substring(from: start)
            counts = counts.filter { $0.key.count <= container.count }
            let number = counts[container, default: 0]
            counts[container] = number + 1
            let marker = isRemoval ? "" : prefix.text(at: number)
            let rewritten = isRemoval ? stripping(prefix, from: rest)
                                      : applying(prefix, to: rest, at: number)
            lastLineAfter = container + rewritten
            // `stripping` and `applying` only take a marker off the front and put one there, so
            // what follows the new marker is the line's own tail.
            let kept = (rewritten as NSString).length - (marker as NSString).length
            let replaced = NSRange(location: range.location + start, length: (rest as NSString).length - kept)
            if ns.substring(with: replaced) != marker { edits.append(LineEdit(range: replaced, text: marker)) }
            // **A setext heading's underline goes when its words take a marker or lose their
            // heading** (FMT-13): `## Title` over a stray `=====` paragraph was what Heading 2 left.
            // Quote keeps it, quoted with the words.
            if let setext = survey.setext(range), !prefix.isQuote {
                let underline = NSRange(location: NSMaxRange(range),
                                        length: NSMaxRange(setext.underline) - NSMaxRange(range))
                edits.append(LineEdit(range: underline, text: ""))
            }
        }
        guard !edits.isEmpty else { return nil }
        // **The inverse of a started item** (FMT-3): a bare marker that comes off between two
        // blank lines takes the room it was given with it, so a second press gives back the bytes
        // the first one started from.
        if isRemoval, let only = written.first, written.count == 1, isBlank(lastLineAfter) {
            let line = MarkdownSourceLines.line(containing: only.location, in: ns)
            if line.content == only, line.terminatorLength > 0,
               let above = MarkdownSourceLines.line(before: line, in: ns), isBlank(ns.substring(with: above.content)),
               let below = MarkdownSourceLines.line(after: line, in: ns), isBlank(ns.substring(with: below.content)) {
                let gone = NSRange(location: NSMaxRange(above.content), length: line.end - NSMaxRange(above.content))
                let collapse = [LineEdit(range: gone, text: "")]
                return MarkupEdit(text: spliced(collapse, into: ns), selection: mapped(selection, through: collapse))
            }
        }
        return MarkupEdit(text: spliced(edits, into: ns), selection: mapped(selection, through: edits))
    }

    /// One line's change: the characters at `range` become `text`. Line verbs produce these in
    /// order, none overlapping.
    struct LineEdit: Equatable {
        var range: NSRange
        var text: String
    }

    /// **The buffer with `edits` made, spliced once** — never the whole buffer rebuilt per line,
    /// which was O(n · lines): quoting a 500-line section of a 200 KB note copied 100 MB.
    static func spliced(_ edits: [LineEdit], into ns: NSString) -> String {
        guard let first = edits.first, let last = edits.last else { return ns as String }
        let covered = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var rebuilt = ""
        var cursor = covered.location
        for edit in edits {
            if edit.range.location > cursor {
                rebuilt += ns.substring(with: NSRange(location: cursor, length: edit.range.location - cursor))
            }
            rebuilt += edit.text
            cursor = NSMaxRange(edit.range)
        }
        return ns.replacingCharacters(in: covered, with: rebuilt)
    }

    /// **Where `position` is once `edits` are made: beside the same character** (FMT-8). Past an
    /// edit, it moves by what the edit added or took; inside the characters an edit replaced — a
    /// marker that came off or changed — it goes to the end of what replaced them, the start of
    /// the line's words. A selection keeps the words it held, not the index: Bullets on `one`
    /// selected used to leave `- one` selected, marker and all, and Bold then wrote `**- one**`,
    /// which is no list item; taking a marker off left the selection a character short, on `e`.
    static func mapped(_ position: Int, through edits: [LineEdit]) -> Int {
        var shift = 0
        for edit in edits {
            let added = (edit.text as NSString).length
            if position >= NSMaxRange(edit.range) {
                shift += added - edit.range.length
                continue
            }
            if position >= edit.range.location { return edit.range.location + shift + added }
            break
        }
        return position + shift
    }

    /// A selection carried through `edits` — each end by ``mapped(_:through:)``.
    static func mapped(_ selection: NSRange, through edits: [LineEdit]) -> NSRange {
        let start = mapped(selection.location, through: edits)
        let end = max(start, mapped(NSMaxRange(selection), through: edits))
        return NSRange(location: start, length: end - start)
    }

    /// **A list, heading or quote started on blank lines** — the case ``prefixLines(_:_:_:)``
    /// hands here: each covered line becomes the bare marker (a line of spaces loses them, since
    /// nothing is on it to indent), numbered on from a numbered item directly above, so a "3." is
    /// the next one under "2.". A caret lands after its marker; a selection holds the markers' run.
    /// Body has nothing to put on a blank line and answers `nil`.
    ///
    /// **A list or quote keeps a blank line between it and a paragraph either side** (FMT-3). On
    /// the one blank line between two paragraphs the marker took that line's place, and so stood
    /// against both: `Para.` over a bare `- ` read as a setext heading, `1. ` as words of the
    /// paragraph, and once the item was typed the paragraph below ran on into it as a lazy line.
    /// A heading needs no room — it is one line, and nothing runs into it.
    static func startingLines(_ ns: NSString, _ selection: NSRange, _ lines: [NSRange],
                              _ prefix: LinePrefix) -> MarkupEdit? {
        if case .heading(let level) = prefix, level <= 0 { return nil }
        let first = numberAbove(lines[0], in: ns, for: prefix)
        let covered = NSRange(location: lines[0].location,
                              length: NSMaxRange(lines[lines.count - 1]) - lines[0].location)
        var rebuilt = ""
        var cursor = covered.location
        for (index, range) in lines.enumerated() {
            if range.location > cursor {
                rebuilt += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            cursor = NSMaxRange(range)
            rebuilt += prefix.text(at: first + index)
        }
        let roomy = prefix.isList || prefix.isQuote
        let firstLine = MarkdownSourceLines.line(containing: covered.location, in: ns)
        let lastLine = MarkdownSourceLines.line(containing: NSMaxRange(covered), in: ns)
        let lead = roomy && (MarkdownSourceLines.line(before: firstLine, in: ns).map { isParagraphText($0.content, in: ns) } ?? false)
            ? "\n" : ""
        let trail = roomy && (MarkdownSourceLines.line(after: lastLine, in: ns).map { isParagraphText($0.content, in: ns) } ?? false)
            ? "\n" : ""
        let result = ns.replacingCharacters(in: covered, with: lead + rebuilt + trail)
        let start = covered.location + (lead as NSString).length
        if selection.length == 0, lines.count == 1 {
            let marker = (prefix.text(at: first) as NSString).length
            return MarkupEdit(text: result, selection: NSRange(location: start + marker, length: 0))
        }
        return MarkupEdit(text: result, selection: NSRange(location: start, length: (rebuilt as NSString).length))
    }

    /// **Whether `line` is a paragraph's words** — what a list or quote must not be written against
    /// (FMT-3): not blank, and not opening with a list, heading or quote marker, a fence, a table's
    /// pipe, raw HTML, or a divider's or an underline's run.
    static func isParagraphText(_ line: NSRange, in ns: NSString) -> Bool {
        let text = ns.substring(with: line)
        guard !isBlank(text) else { return false }
        let rest = (text as NSString).substring(from: containerLength(text, for: .bullet))
        guard (text as NSString).length == (rest as NSString).length || !text.contains(">") else { return false }
        for prefix in [LinePrefix.bullet, .numbered, .task, .heading(1), .quote]
            where firstMatch(prefix.pattern, in: rest) != nil { return false }
        if let lead = rest.first, "|`~<".contains(lead) { return false }
        let marks = rest.filter { $0 != " " && $0 != "\t" }
        if let mark = marks.first, "-*_=".contains(mark), marks.allSatisfy({ $0 == mark }) { return false }
        return true
    }

    /// The number a numbered list started on `line` takes up from: the number of a numbered item on
    /// the line directly above it, or `0` — the index ``LinePrefix/text(at:)`` counts from.
    static func numberAbove(_ line: NSRange, in ns: NSString, for prefix: LinePrefix) -> Int {
        guard case .numbered = prefix, line.location > 0 else { return 0 }
        let above = ns.substring(with: ns.lineRange(for: NSRange(location: line.location - 1, length: 0)))
        guard firstMatch(LinePrefix.numbered.pattern, in: above) != nil else { return 0 }
        return Int(above.prefix(while: \.isNumber)) ?? 0
    }

    /// **The "already applied" half of ``prefixLines(_:_:_:)``, on its own** — whether every line
    /// the selection touches already carries `prefix`, blank lines counting as carrying it. One test,
    /// asked by the verb (to decide between adding and removing) and by the format bar (to decide
    /// whether the button is lit), so the two can never disagree about a line (TE52).
    ///
    /// **Level-exact for headings, by way of ``LinePrefix/appliedPattern``** — the bug that note
    /// records was exactly these two questions sharing one answer.
    static func everyLineHas(_ prefix: LinePrefix, _ lines: [NSRange], in ns: NSString,
                             survey: LineSurvey? = nil) -> Bool {
        lines.allSatisfy { range in
            // A setext heading has its level's marker without writing one (FMT-13).
            if !prefix.isQuote, let setext = survey?.setext(range) {
                if case .heading(let level) = prefix { return level == setext.level }
                return false
            }
            let line = ns.substring(with: range)
            let rest = (line as NSString).substring(from: containerLength(line, for: prefix))
            return isBlank(line) || firstMatch(prefix.appliedPattern, in: rest) != nil
        }
    }

    /// **What stands in front of a line's own marker: its quote markers and its indentation**
    /// (FMT-7), which a list or heading verb reads past and writes after. The patterns were
    /// anchored at column 0, so a nested item, a quoted one or a quoted heading was read as no
    /// marker at all: Bullets over `- a` and `  - b` wrote `-   - b`, Heading 2 on `> Title` wrote
    /// `## > Title`. Quote is the exception — it nests in front of everything, so it reads from
    /// column 0 — and answers 0.
    static func containerLength(_ line: String, for prefix: LinePrefix) -> Int {
        if case .quote = prefix { return 0 }
        return firstMatch("^(?:[ \t]{0,3}>[ \t]?)*[ \t]*", in: line)?.length ?? 0
    }

    /// Internal rather than private, so `MarkupPrefixLinesEquivalenceTests` can run the OLD
    /// `prefixLines` algorithm beside the new one over the same helpers — which is what makes
    /// "the rewrite is behaviour-preserving" a measurement rather than an argument.
    static func stripping(_ prefix: LinePrefix, from line: String) -> String {
        guard let match = firstMatch(prefix.pattern, in: line) else { return line }
        return (line as NSString).replacingCharacters(in: match, with: "")
    }

    /// Internal for the reason ``stripping(_:from:)`` is.
    static func applying(_ prefix: LinePrefix, to line: String, at index: Int) -> String {
        var body = line
        // Its own kind first, so re-applying at a different level replaces rather than stacks.
        body = stripping(prefix, from: body)
        for pattern in prefix.replaces {
            if let match = firstMatch(pattern, in: body) {
                body = (body as NSString).replacingCharacters(in: match, with: "")
            }
        }
        return prefix.text(at: index) + body
    }

    /// The selection after an edit that changed the buffer's length by `delta`.
    ///
    /// **The whole run stays selected**, growing or shrinking with it, because the next verb is
    /// usually aimed at the same lines — quote it, then make it a list. A caret left at the end
    /// would mean re-dragging between every pair of verbs.
    static func selectionAfter(_ selection: NSRange, delta: Int, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(selection.location, 0), length)
        return NSRange(location: location, length: min(max(selection.length + delta, 0), length - location))
    }

    // MARK: Blocks

    /// Wraps the touched lines in a fence.
    ///
    /// **Insert only, never a toggle**, and the reason is that the opposite operation is ambiguous:
    /// the fence that would have to come off is not in the selection, it is the line above and the
    /// line below it, and a "selection" of a fenced block made by dragging usually includes neither.
    static func fence(_ text: String, _ selection: NSRange) -> MarkupEdit {
        let ns = text as NSString
        let lines = lineRanges(covering: selection, in: ns)
        let start = lines.first?.location ?? selection.location
        let end = lines.last.map { NSMaxRange($0) } ?? NSMaxRange(selection)
        let body = ns.substring(with: NSRange(location: start, length: end - start))
        let marker = String(repeating: "`", count: fenceLength(around: body))
        let fenced = marker + "\n" + body + "\n" + marker
        let replaced = NSRange(location: start, length: end - start)
        return MarkupEdit(text: ns.replacingCharacters(in: replaced, with: fenced),
                          // Inside the fence, on the code — not on the fence line nobody edits.
                          selection: NSRange(location: start + (marker as NSString).length + 1,
                                             length: (body as NSString).length))
    }

    /// **How many backticks the fence needs to hold `body`** (FMT-9): three, or one more than the
    /// longest run of them opening any of its lines — the only lines that could close it. Code
    /// Block around a note that already showed a fenced example wrote ```` ``` ```` around it, and
    /// the example's own first fence closed the new block there: the rest fell out as a paragraph
    /// and an empty block.
    static func fenceLength(around body: String) -> Int {
        var longest = 0
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let indent = line.prefix { $0 == " " }
            guard indent.count <= 3 else { continue }
            longest = max(longest, line.dropFirst(indent.count).prefix { $0 == "`" }.count)
        }
        return max(3, longest + 1)
    }

    /// A thematic break on its own line, below the line the caret is on.
    ///
    /// **Inserted after the line's TERMINATOR, not after its last character.** Landing before the
    /// newline pushes it down and leaves a stray blank line behind the rule. And the rule carries a
    /// blank line above it, which is what makes `---` a thematic break rather than a setext heading
    /// underlining the paragraph — the exact confusion ``MarkdownFrontMatter`` documents.
    static func rule(_ text: String, _ selection: NSRange) -> MarkupEdit {
        let ns = text as NSString
        let clamped = NSRange(location: min(selection.location, ns.length),
                              length: min(selection.length, max(ns.length - min(selection.location, ns.length), 0)))
        let end = ns.length == 0 ? 0 : NSMaxRange(ns.lineRange(for: clamped))
        // At the very end of a buffer whose last line has no terminator, the rule needs one of its
        // own before the blank line.
        let terminated = end > 0
            && CharacterSet.newlines.contains(UnicodeScalar(ns.character(at: end - 1)) ?? " ")
        let inserted = (terminated ? "" : "\n") + "\n---\n"
        return MarkupEdit(text: ns.replacingCharacters(in: NSRange(location: end, length: 0),
                                                       with: inserted),
                          selection: NSRange(location: end + (inserted as NSString).length, length: 0))
    }

    // MARK: Helpers

    /// The individual lines the selection touches, terminators excluded.
    static func lineRanges(covering selection: NSRange, in ns: NSString) -> [NSRange] {
        guard ns.length > 0 else { return [NSRange(location: 0, length: 0)] }
        let clamped = NSRange(location: min(selection.location, ns.length),
                              length: min(selection.length, ns.length - min(selection.location, ns.length)))
        let paragraph = ns.lineRange(for: clamped)
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: paragraph, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        // A selection sitting on a trailing empty line produces no substrings at all.
        return ranges.isEmpty ? [NSRange(location: paragraph.location, length: 0)] : ranges
    }

    /// The smallest edit that turns `old` into `new`: one range and one replacement.
    ///
    /// **So the change goes through the text view as an edit rather than as a new buffer.** Handing
    /// `NSTextView` a whole new string is not an edit it can undo — ⌘Z after a Bold would step back
    /// to whatever the last *typed* change was, past the verb entirely — and on a 4 MiB document it
    /// relayouts everything to change two characters. Common prefix and common suffix in UTF-16,
    /// which is all these verbs ever produce: every one of them touches a contiguous run.
    static func minimalReplacement(from old: String, to new: String) -> (range: NSRange, text: String) {
        let a = old as NSString
        let b = new as NSString
        var prefix = 0
        let shortest = min(a.length, b.length)
        while prefix < shortest, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix,
              a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) {
            suffix += 1
        }
        let range = NSRange(location: prefix, length: a.length - prefix - suffix)
        let replacement = b.substring(with: NSRange(location: prefix,
                                                    length: b.length - prefix - suffix))
        return (range, replacement)
    }

    /// The compiled line-prefix patterns, kept because there are only ever six of them.
    ///
    /// **Compiled once, not once per line.** `applying(_:to:at:)` asks `firstMatch` up to five
    /// times for a single line — its own pattern plus the four it replaces — and every ask built a
    /// fresh `NSRegularExpression` from source. Applying a list verb to a 500-line selection
    /// compiled 2,500 regular expressions to match strings that are a few characters long.
    ///
    /// The patterns are a closed set written in ``LinePrefix``, and none of them depends on
    /// anything but the verb, so the cache cannot grow without bound and cannot go stale. It is
    /// `nonisolated(unsafe)` behind a lock rather than main-actor isolated because `MarkdownEdits`
    /// is a plain namespace these verbs are also applied from off the main actor in tests.
    private final class RegexCache: @unchecked Sendable {
        private let lock = NSLock()
        private var compiled: [String: NSRegularExpression] = [:]

        func regex(_ pattern: String) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            if let hit = compiled[pattern] { return hit }
            guard let built = try? NSRegularExpression(pattern: pattern) else { return nil }
            compiled[pattern] = built
            return built
        }
    }

    private static let regexCache = RegexCache()

    private static func firstMatch(_ pattern: String, in line: String) -> NSRange? {
        guard let regex = regexCache.regex(pattern) else { return nil }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return regex.firstMatch(in: line, range: range)?.range
    }
}
