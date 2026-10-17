import Testing
import Foundation
@testable import FileExplorer

/// The markup verbs: what each one does to a selection, and what it does the second time.
///
/// **Every case asserts the whole buffer and the selection.** Where the selection lands is not a
/// detail — a verb that leaves the caret in the wrong place makes the next one act on the wrong
/// text, which is how a menu of toggles turns into a menu of accidents.
@Suite struct MarkupVerbTests {

    private func apply(_ verb: MarkupVerb, _ text: String, _ selection: NSRange) -> MarkupEdit? {
        MarkdownEdits.apply(verb, to: text, selection: selection)
    }

    private func range(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    // MARK: Inline wrapping

    @Test func boldWrapsTheSelection() {
        let edit = apply(.bold, "one two", range(4, 3))
        #expect(edit?.text == "one **two**")
        // The words stay selected, so a second verb aims at the same ones.
        #expect(edit?.selection == range(6, 3))
    }

    @Test func boldOnBoldTextTakesItOff() {
        // Selected between the asterisks.
        #expect(apply(.bold, "one **two**", range(6, 3))?.text == "one two")
        // Selected including them.
        #expect(apply(.bold, "one **two**", range(4, 7))?.text == "one two")
    }

    @Test func anEmptySelectionLeavesTheCaretBetweenTheDelimiters() {
        let edit = apply(.bold, "one ", range(4, 0))
        #expect(edit?.text == "one ****")
        #expect(edit?.selection == range(6, 0))
    }

    /// The ambiguity the guard exists for: one `*` on each side of the selection inside `**bold**`
    /// is not an italic wrapper, and unwrapping it would silently demote bold to italic.
    @Test func italicInsideBoldAddsRatherThanUnwraps() {
        let edit = apply(.italic, "**bold**", range(2, 4))
        #expect(edit?.text == "***bold***", "italic on bold produced \(edit?.text ?? "nil")")
    }

    @Test func italicOnPlainItalicStillUnwraps() {
        #expect(apply(.italic, "one *two* three", range(5, 3))?.text == "one two three")
    }

    /// **Italic on bold text makes it bold-italic, and the next press gives back the bytes it
    /// started from** (FMT-4, FMT-11). A star is half of `**`, so Italic reads the whole run beside
    /// the selection: two is bold alone, one or three is italic. Selected with its asterisks,
    /// `**loud**` lost its bold to Italic (`*loud*`), and Italic lit over it as if it were italic;
    /// selected between them, a second press added an eighth star instead of taking the third off.
    ///
    /// Mutation: route Italic back through the neighbour guard (drop `italicState`) and the first
    /// three expectations fail.
    @Test func italicOnBoldGivesBoldItalicAndComesBack() throws {
        // Selected whole, asterisks and all.
        let whole = apply(.italic, "say **loud** now", range(4, 8))
        let wholeText = whole?.text
        #expect(wholeText == "say ***loud*** now", "Italic on **loud** wrote \(String(describing: wholeText))")
        let litOverBold = MarkdownEdits.isApplied(.italic, in: "say **loud** now", selection: range(4, 8))
        #expect(!litOverBold, "Italic lights over a word that is only bold")
        // Selected between the asterisks — a double-click — and pressed twice.
        let first = try #require(apply(.italic, "a **bold** word", range(4, 4)))
        #expect(first.text == "a ***bold*** word" && first.selection == range(5, 4))
        let litAfter = MarkdownEdits.isApplied(.italic, in: first.text, selection: first.selection)
        #expect(litAfter, "bold-italic text does not light Italic")
        let second = apply(.italic, first.text, first.selection)
        let secondText = second?.text, secondSelection = second?.selection
        #expect(secondText == "a **bold** word" && secondSelection == range(4, 4),
                "the second press wrote \(String(describing: secondText)) at \(String(describing: secondSelection))")
        // Bold-italic selected whole loses its italic and keeps its bold.
        let all = apply(.italic, "***x***", range(0, 7))?.text
        #expect(all == "**x**")
        // A star of a bold pair inside the selection is still bold's.
        let half = apply(.italic, "**x**", range(1, 3))?.text
        #expect(half == "***x***")
        // An empty bold pair: Italic goes inside it, and comes back out.
        let caret = try #require(apply(.italic, "****", range(2, 0)))
        #expect(caret.text == "******" && caret.selection == range(3, 0))
        let back = apply(.italic, caret.text, caret.selection)?.text
        #expect(back == "****")
        // A star after a backslash is a literal, not a delimiter.
        let escaped = apply(.italic, "\\*x\\*", range(2, 1))?.text
        #expect(escaped == "\\**x*\\*")
    }

    /// **Two italic spans and the words between them are two spans, not one** (FMT-5) — the rule
    /// Bold, Strikethrough and Code were given in TE52, now Italic's too. Selected whole or between
    /// the outer stars, Italic took the outer pair off and left `Warning* read the *docs`, which
    /// renders with no italic at all, and lit as if the run were one span. A bold pair inside one
    /// italic span still comes off whole.
    ///
    /// Mutation: drop the `holdsLoneStar` terms from `italicState` and the inverted text is back.
    @Test func italicOverTwoItalicSpansAddsRatherThanInverts() {
        let text = "*Warning* read the *docs*"
        let italicBefore = Self.italicCharacters(text)
        for selection in [range(0, 25), range(1, 23)] {
            let lit = MarkdownEdits.isApplied(.italic, in: text, selection: selection)
            #expect(!lit, "Italic lights over two italic spans at \(selection)")
            let edit = apply(.italic, text, selection)
            let written = edit?.text ?? ""
            #expect(written == "**Warning* read the *docs**", "Italic at \(selection) wrote \(written)")
            let italicAfter = Self.italicCharacters(written)
            #expect(italicAfter >= italicBefore, "Italic at \(selection) took italic away: \(italicAfter) of \(italicBefore)")
        }
        let nested = apply(.italic, "*a **b** c*", range(0, 11))?.text
        #expect(nested == "a **b** c")
    }

    /// How many rendered characters are italic.
    static func italicCharacters(_ text: String) -> Int {
        MarkdownBlocks.blocks(from: text).reduce(0) { count, block in
            guard case .paragraph(let line) = block.kind else { return count }
            return count + line.runs.filter(\.isItalic).reduce(0) { $0 + $1.text.count }
        }
    }

    @Test func strikeAndCodeWrapTheirOwnDelimiters() {
        #expect(apply(.strikethrough, "gone", range(0, 4))?.text == "~~gone~~")
        #expect(apply(.inlineCode, "let x", range(0, 5))?.text == "`let x`")
        #expect(apply(.inlineCode, "`let x`", range(1, 5))?.text == "let x")
    }

    /// **Inline Code around text holding backticks uses a longer run, and comes back off** (FMT-20).
    /// One backtick around `` use `a` here `` closed at the first backtick inside, and rendered as
    /// code, plain and code. A span is read as CommonMark reads it: a run opens it and the next run
    /// of the SAME length closes it, so a span written with two backticks comes off whole, and the
    /// words between two spans are not taken for one span's code.
    ///
    /// Mutation: wrap with a single backtick again (drop `codeDelimiters`), and the first two cases
    /// fail; read only one backtick each side again, and the `` ``y`` `` case does.
    @Test func inlineCodeAroundBackticksUsesALongerRunAndComesBack() throws {
        let inner = "use `a` here"
        let on = try #require(apply(.inlineCode, inner, range(0, 12)))
        #expect(on.text == "``use `a` here``")
        let code = MarkdownBlocks.blocks(from: on.text).first.map { block -> [MarkdownRun] in
            if case .paragraph(let line) = block.kind { return line.runs }
            return []
        } ?? []
        #expect(code == [MarkdownRun(text: "use `a` here", isCode: true)], "renders as \(code)")
        let off = apply(.inlineCode, on.text, on.selection)
        let offText = off?.text
        #expect(offText == inner, "pressed again: \(String(describing: offText))")

        // Text that starts with a backtick is padded, and the padding comes off with the run.
        let spans = "`a` and `b`"
        let padded = try #require(apply(.inlineCode, spans, range(0, 11)))
        #expect(padded.text == "`` `a` and `b` ``")
        let lit = MarkdownEdits.isApplied(.inlineCode, in: padded.text, selection: padded.selection)
        #expect(lit, "the code of a padded span does not light Code")
        let back = apply(.inlineCode, padded.text, padded.selection)?.text
        #expect(back == spans)
        let whole = apply(.inlineCode, padded.text, range(0, (padded.text as NSString).length))?.text
        #expect(whole == spans)

        // A span written with two backticks comes off whole.
        let doubled = apply(.inlineCode, "x ``y`` z", range(4, 1))?.text
        #expect(doubled == "x y z")
        // The words between two spans are not one span's code.
        let between = MarkdownEdits.isApplied(.inlineCode, in: spans, selection: range(3, 5))
        #expect(!between, "Code lights over the words between two spans")
        let inverted = apply(.inlineCode, spans, range(3, 5))?.text
        #expect(inverted != "`a and b`")
    }

    /// **An inline mark wraps the selection's words, line by line** (FMT-10). A triple-click takes
    /// the line break, a drag often takes a space, and a selection can run over paragraphs — Bold
    /// wrote `**first line\n**`, `**word **` and `**one\n\ntwo**`, every one of them literal
    /// asterisks. The ends' spaces and breaks are left out, each line gets its own pair, a list or
    /// heading marker stays outside it, and across lines code and table rows are left alone. The
    /// press comes off the same way, and lights the same way.
    ///
    /// Mutation: have `inlineRuns` answer `[selection]`, and every case but the caret fails.
    @Test func inlineMarksWrapTheWordsLineByLine() throws {
        let triple = try #require(apply(.bold, "first line\nsecond", range(0, 11)))
        #expect(triple.text == "**first line**\nsecond" && triple.selection == range(2, 10),
                "a triple-click and Bold wrote \(triple.text) at \(triple.selection)")
        let tripleLit = MarkdownEdits.isApplied(.bold, in: triple.text, selection: range(0, 15))
        #expect(tripleLit, "Bold is dark over a bold line selected by a triple-click")
        let tripleOff = apply(.bold, triple.text, range(0, 15))?.text
        #expect(tripleOff == "first line\nsecond")

        let spaced = apply(.bold, "a word here", range(2, 5))
        #expect(spaced?.text == "a **word** here" && spaced?.selection == range(4, 4))

        let paragraphs = "one\n\ntwo"
        let both = try #require(apply(.bold, paragraphs, range(0, 8)))
        #expect(both.text == "**one**\n\n**two**" && both.selection == range(0, 16),
                "Bold over two paragraphs wrote \(both.text) at \(both.selection)")
        let bothLit = MarkdownEdits.isApplied(.bold, in: both.text, selection: both.selection)
        #expect(bothLit)
        let bothOff = apply(.bold, both.text, both.selection)
        #expect(bothOff?.text == paragraphs && bothOff?.selection == range(0, 8))
        // A mixed run is finished, not turned inside out.
        let mixed = apply(.italic, "*one*\ntwo", range(0, 9))?.text
        #expect(mixed == "*one*\n*two*")

        let items = apply(.bold, "- one\n- two", range(0, 11))?.text
        #expect(items == "- **one**\n- **two**", "Bold over a list wrote \(String(describing: items))")
        let heading = apply(.strikethrough, "## Old title", range(0, 12))?.text
        #expect(heading == "## ~~Old title~~")

        let withCode = "a\n```\nb\n```\nc"
        let aroundCode = apply(.bold, withCode, range(0, (withCode as NSString).length))?.text
        #expect(aroundCode == "**a**\n```\nb\n```\n**c**", "Bold over code wrote \(String(describing: aroundCode))")
        let withTable = "Intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter"
        let aroundTable = apply(.bold, withTable, range(0, (withTable as NSString).length))?.text
        #expect(aroundTable == "**Intro**\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n**After**",
                "Bold over a table wrote \(String(describing: aroundTable))")

        // Over lines that are all code there is nothing to wrap — not the fences, as one code span.
        let fenced = "```\n# c\n```"
        let overFence = apply(.inlineCode, fenced, range(0, 11))
        #expect(overFence == nil, "Code over a fenced block wrote \(String(describing: overFence?.text))")
        let fenceLit = MarkdownEdits.isApplied(.inlineCode, in: fenced, selection: range(0, 11))
        #expect(!fenceLit, "Code lights over a fenced block, as if its fences were one span")
        // U+2028 and U+2029 are characters of the line to Markdown, not breaks: one run over them.
        let separated = apply(.bold, "x plenty\u{2029}here", range(2, 11))?.text
        #expect(separated == "x **plenty\u{2029}here**", "Bold split at a U+2029: \(String(describing: separated))")
        // A caret, and a selection of spaces alone, are as they were.
        #expect(apply(.bold, "one ", range(4, 0))?.text == "one ****")
        #expect(apply(.bold, "a  b", range(1, 2))?.text == "a**  **b")
    }

    // MARK: Links

    @Test func aLinkOverWordsSelectsTheDestination() {
        let edit = apply(.link, "see the notes", range(8, 5))
        #expect(edit?.text == "see the [notes](url)")
        // `url`, so typing replaces it.
        #expect(edit?.selection == range(16, 3))
        #expect((edit?.text as NSString?)?.substring(with: edit?.selection ?? range(0, 0)) == "url")
    }

    @Test func aLinkWithNothingSelectedSelectsTheTextInstead() {
        let edit = apply(.link, "", range(0, 0))
        #expect(edit?.text == "[text](url)")
        #expect((edit?.text as NSString?)?.substring(with: edit?.selection ?? range(0, 0)) == "text")
    }

    // MARK: Line prefixes

    @Test func aHeadingIsAppliedAndRemoved() {
        #expect(apply(.heading(2), "Title\n", range(0, 0))?.text == "## Title\n")
        #expect(apply(.heading(2), "## Title\n", range(0, 0))?.text == "Title\n")
    }

    /// Re-applying at another level replaces the marker rather than stacking a second one.
    @Test func changingHeadingLevelReplacesTheMarker() {
        #expect(apply(.heading(3), "# Title\n", range(0, 0))?.text == "### Title\n")
    }

    /// Body is a removal with nothing to put back, so it is never a toggle — pressing it twice
    /// leaves a paragraph a paragraph.
    @Test func bodyOnlyEverRemoves() {
        #expect(apply(.heading(0), "### Title\n", range(0, 0))?.text == "Title\n")
        #expect(apply(.heading(0), "Title\n", range(0, 0)) == nil)
    }

    @Test func listsNumberThemselvesAcrossTheSelection() {
        let source = "one\ntwo\nthree\n"
        let edit = apply(.numberedList, source, range(0, 13))
        #expect(edit?.text == "1. one\n2. two\n3. three\n", "produced \(edit?.text ?? "nil")")
    }

    @Test func aBulletedListTogglesOffWhenEveryLineHasOne() {
        let listed = "- one\n- two\n"
        #expect(apply(.bulletList, listed, range(0, 11))?.text == "one\ntwo\n")
    }

    /// A mixed selection is finished rather than inverted: the first press gives every line the
    /// prefix, and only then does a second press take it away.
    @Test func aMixedSelectionIsCompletedNotInverted() {
        let mixed = "- one\ntwo\n"
        let first = apply(.bulletList, mixed, range(0, 9))
        #expect(first?.text == "- one\n- two\n", "produced \(first?.text ?? "nil")")
    }

    /// A bulleted list and a checklist both open with a dash, so Bulleted List on a checklist has
    /// to mean "make it a plain list" rather than "strip the dash and leave the boxes".
    @Test func bulletOnATaskListMakesItAPlainList() {
        #expect(apply(.bulletList, "- [ ] one\n", range(0, 0))?.text == "- one\n")
    }

    @Test func taskItemsAreAppliedAndRemoved() {
        #expect(apply(.taskItem, "one\n", range(0, 0))?.text == "- [ ] one\n")
        #expect(apply(.taskItem, "- [x] one\n", range(0, 0))?.text == "one\n")
    }

    /// **A box with nothing after it — its trailing space trimmed — is still a task** (FMT-21). It
    /// was read as a bullet whose text is `[ ]`: Tasks did not light on it, and its press wrote a
    /// second box, `- [ ] [ ]` or `- [ ] [x]`. Mutation: require a space after the box in the task
    /// pattern again, and every line here fails.
    @Test func aBoxWithNothingAfterItIsATask() {
        for line in ["- [ ]", "- [x]", "* [X]"] {
            let lit = MarkdownEdits.isApplied(.taskItem, in: line, selection: range(line.count, 0))
            #expect(lit, "Tasks is dark on “\(line)”")
            let off = apply(.taskItem, line, range(line.count, 0))?.text
            #expect(off == "", "Tasks on “\(line)” wrote \(String(describing: off))")
            let bullet = apply(.bulletList, line, range(line.count, 0))?.text
            #expect(bullet == "- ", "Bullets on “\(line)” wrote \(String(describing: bullet))")
        }
    }

    /// Markdown nests a quote in front of whatever the line already was, so quoting a list leaves a
    /// quoted list — unlike the list verbs, which are alternatives to each other.
    @Test func quotingKeepsWhateverTheLineAlreadyWas() {
        #expect(apply(.blockQuote, "- one\n", range(0, 0))?.text == "> - one\n")
        #expect(apply(.blockQuote, "> - one\n", range(0, 0))?.text == "- one\n")
    }

    /// A blank line inside a selection stays blank: prefixing it would put a lone `- ` between two
    /// paragraphs, and the toggle must not read it as "this line is missing the prefix" either.
    @Test func blankLinesInsideASelectionAreLeftAlone() {
        let source = "- one\n\n- two\n"
        #expect(apply(.bulletList, source, range(0, 12))?.text == "one\n\ntwo\n",
                "the blank line broke the toggle")
    }

    /// **A list or heading verb reads past a line's quote markers and indentation, and writes
    /// after them** (FMT-7). The patterns were anchored at column 0: Bullets over a nested list
    /// wrote `-   - b`, Numbered `2.   - b`, Tasks a second box, Bullets on a quoted item
    /// `- > - item`, Heading 2 on a quoted line `## > Title`. And an indented line carrying on a
    /// list item is the item's words — a list verb leaves it, where Bullets made it an item of its
    /// own. A lazy line, not indented, is still completed into the list.
    ///
    /// Mutation: have `containerLength` answer 0, and the nested and quoted cases fail; drop the
    /// `.continuation` role, and the carried-on line does.
    @Test func listAndHeadingVerbsReadPastQuotesAndIndentation() {
        let nested = "- a\n  - b"
        let all = range(0, (nested as NSString).length)
        let litNested = MarkdownEdits.isApplied(.bulletList, in: nested, selection: all)
        #expect(litNested, "Bullets is dark over a nested bulleted list")
        let bulletsOff = apply(.bulletList, nested, all)?.text
        #expect(bulletsOff == "a\n  b", "Bullets wrote \(String(describing: bulletsOff))")
        let numbered = apply(.numberedList, nested, all)?.text
        #expect(numbered == "1. a\n  1. b", "Numbered wrote \(String(describing: numbered))")
        let tasks = "- [ ] a\n  - [ ] b"
        let tasksOff = apply(.taskItem, tasks, range(0, (tasks as NSString).length))?.text
        #expect(tasksOff == "a\n  b", "Tasks wrote \(String(describing: tasksOff))")
        let quotedItem = apply(.bulletList, "> - item", range(8, 0))?.text
        #expect(quotedItem == "> item", "Bullets on a quoted item wrote \(String(describing: quotedItem))")
        let quotedHeading = apply(.heading(2), "> Title", range(7, 0))?.text
        #expect(quotedHeading == "> ## Title", "Heading 2 on a quoted line wrote \(String(describing: quotedHeading))")
        // Two levels count apart, and the outer count carries on past the inner list.
        let levels = "a\n  b\n  c\nd"
        let counted = apply(.numberedList, levels, range(0, (levels as NSString).length))?.text
        #expect(counted == "1. a\n  1. b\n  2. c\n2. d", "Numbered wrote \(String(describing: counted))")

        let carried = "- long item\n  continued"
        let carriedAll = range(0, (carried as NSString).length)
        let carriedLit = MarkdownEdits.isApplied(.bulletList, in: carried, selection: carriedAll)
        #expect(carriedLit, "Bullets is dark over one item and its carried-on line")
        let carriedOff = apply(.bulletList, carried, carriedAll)?.text
        #expect(carriedOff == "long item\n  continued", "Bullets wrote \(String(describing: carriedOff))")
        // A lazy line, at the margin, is still completed.
        let lazy = "- one\nplain\n- three"
        let completed = apply(.bulletList, lazy, range(0, (lazy as NSString).length))?.text
        #expect(completed == "- one\n- plain\n- three")
    }

    /// **A setext heading — words over `=====` or `-----` — is a heading to the verbs and the Body
    /// menu** (FMT-13). The menu named it Body, Heading 1 did not light, and Heading 2 wrote
    /// `## Title` over a stray `=====` paragraph. The underline goes when the words take a marker or
    /// lose their heading; Quote quotes it with them, so the heading stays one inside the quote.
    ///
    /// Mutation: drop the `.setext` role (answer `.text`), and every line but the control fails.
    @Test func aSetextHeadingIsAHeading() {
        let source = "Title\n=====\n\nBody"
        let caret = range(2, 0)
        let level = MarkdownEdits.headingLevel(in: source, selection: caret)
        #expect(level == .level(1), "the Body menu names a setext heading \(level)")
        let lit = MarkupFormatState.of(source, selection: caret).lit
        #expect(lit == [.heading(1)], "a setext heading lights \(lit.map(\.title))")
        let cases: [(MarkupVerb, String)] = [
            (.heading(2), "## Title\n\nBody"),
            (.heading(1), "Title\n\nBody"),        // lit, so it comes off
            (.heading(0), "Title\n\nBody"),
            (.bulletList, "- Title\n\nBody"),
            (.blockQuote, "> Title\n> =====\n\nBody"),
        ]
        for (verb, expected) in cases {
            let written = apply(verb, source, caret)?.text
            #expect(written == expected, "\(verb.title) on a setext heading wrote \(String(describing: written))")
        }
        let heading2 = apply(.heading(2), source, range(5, 0))
        #expect(heading2?.selection == range(8, 0), "the caret did not stay at the words' end")
        let rendered = MarkdownBlocks.blocks(from: "## Title\n\nBody").count
        #expect(rendered == 2)
        // Dashes make a level-2 one; a quoted one is read past its `> `.
        let dashes = MarkdownEdits.headingLevel(in: "Sub\n---\n", selection: range(1, 0))
        #expect(dashes == .level(2))
        let quoted = apply(.heading(3), "> Title\n> =====", range(4, 0))?.text
        #expect(quoted == "> ### Title")
        // The control: a paragraph over a divider after a blank line is no heading.
        let control = MarkdownEdits.headingLevel(in: "Para\n\n---\n", selection: range(1, 0))
        #expect(control == .body)
    }

    /// **Code, front matter, raw HTML and dividers are not prose, and a line verb leaves them byte
    /// for byte** (FMT-6) — they decide nothing about whether the verb adds or removes, either.
    /// Body over a section stripped the `# ` from a shell comment in its code; Bullets put `- ` in
    /// front of the fences; ⌘A then Numbered List made the front matter list items and a divider
    /// an empty one. A caret inside code reads as no heading and no list, and a verb there does
    /// nothing.
    ///
    /// Mutation: have `LineSurvey.written` keep `.literal` lines, and every case fails.
    @Test func codeFrontMatterHTMLAndDividersAreLeftAlone() {
        let section = "# Setup\n```sh\n# install deps\nbrew install x\n```"
        let whole = range(0, (section as NSString).length)
        let body = apply(.heading(0), section, whole)?.text
        #expect(body == "Setup\n```sh\n# install deps\nbrew install x\n```", "Body wrote \(String(describing: body))")
        let bullets = apply(.bulletList, section, whole)?.text
        #expect(bullets == "- Setup\n```sh\n# install deps\nbrew install x\n```", "Bullets wrote \(String(describing: bullets))")

        let comment = range((section as NSString).range(of: "install deps").location, 0)
        let commentLevel = MarkdownEdits.headingLevel(in: section, selection: comment)
        #expect(commentLevel == .body, "a shell comment reads as \(commentLevel)")
        let lit = MarkupFormatState.of(section, selection: comment).lit
        #expect(lit.isEmpty, "a caret in code lights \(lit.map(\.title))")
        let inCode = apply(.heading(0), section, comment)
        #expect(inCode == nil, "Body in code wrote \(String(describing: inCode?.text))")
        let blankInCode = apply(.bulletList, "```\n\n```", range(4, 0))
        #expect(blankInCode == nil, "Bullets started an item inside code")

        let matter = "---\ntitle: x\n---\n\nBody line"
        let numbered = apply(.numberedList, matter, range(0, (matter as NSString).length))?.text
        #expect(numbered == "---\ntitle: x\n---\n\n1. Body line", "Numbered wrote \(String(describing: numbered))")

        let divided = "Para\n\n* * *\n\nMore"
        let around = apply(.numberedList, divided, range(0, (divided as NSString).length))?.text
        #expect(around == "1. Para\n\n* * *\n\n2. More", "Numbered wrote \(String(describing: around))")

        let indented = "Para\n\n    # not a heading\n"
        let indentedBody = apply(.heading(0), indented, range(12, 0))
        #expect(indentedBody == nil, "Body rewrote an indented code line")

        let html = "<div>\n# x\n</div>"
        let htmlBody = apply(.heading(0), html, range(7, 0))
        #expect(htmlBody == nil, "Body rewrote a line of raw HTML")
    }

    // MARK: Starting on a blank line (reported 2026-10-05)

    /// The line verbs and the marker each writes on a blank line.
    private static let starts: [(MarkupVerb, String)] = [
        (.bulletList, "- "), (.numberedList, "1. "), (.taskItem, "- [ ] "),
        (.heading(1), "# "), (.heading(2), "## "), (.heading(3), "### "), (.blockQuote, "> "),
    ]

    /// **On a blank line — or in an empty note — a list, heading or quote verb STARTS one**, the
    /// caret after its marker so typing begins the item. He found Bullets, Numbered and Tasks did
    /// nothing there. Body has nothing to put on a blank line. Mutation: return `nil` for blank
    /// lines again (the old rule) and every line fails.
    @Test func aLineVerbOnABlankLineStartsOne() {
        for (verb, marker) in Self.starts {
            // A list or quote keeps a blank line from the paragraphs either side (FMT-3); a heading
            // needs none. These lines read "Para.\n\(marker)\nNext." for every verb until then.
            let room: String
            if case .heading = verb { room = "" } else { room = "\n" }
            let between = apply(verb, "Para.\n\nNext.", range(6, 0))
            #expect(between?.text == "Para.\n\(room)\(marker)\n\(room)Next.", "\(verb.title) on a blank line wrote \(String(describing: between?.text))")
            #expect(between?.selection == range(6 + room.count + marker.count, 0), "\(verb.title) left the caret at \(String(describing: between?.selection))")
            let empty = apply(verb, "", range(0, 0))
            #expect(empty?.text == marker && empty?.selection == range(marker.count, 0),
                    "\(verb.title) in an empty note wrote \(String(describing: empty?.text))")
            // The last line, after the final line break, and a line of spaces.
            #expect(apply(verb, "Para.\n", range(6, 0))?.text == "Para.\n\(room)\(marker)")
            #expect(apply(verb, "Para.\n   \nNext.", range(8, 0))?.text == "Para.\n\(room)\(marker)\n\(room)Next.")
        }
        #expect(apply(.heading(0), "Para.\n\nNext.", range(6, 0)) == nil, "Body put something on a blank line")
    }

    /// **A list or quote started on the one blank line between two paragraphs keeps a blank line
    /// on each side** (FMT-3). The marker took that blank line's place and stood against both: a
    /// bare `- ` under `Para.` read as a setext underline (`Para.` an H2), a bare `1. ` as words of
    /// the paragraph, and once the item was typed `Next.` ran on into it as a lazy line. Pressed
    /// again, the bare marker comes off with the room it was given, back to the bytes it started
    /// from. Under a list item there is no room to keep — the list carries on.
    ///
    /// Mutation: drop the lead and trail from `startingLines`, and the rendering lines fail; drop
    /// the collapse, and the round trip does.
    @Test func aStartedListKeepsABlankLineFromTheParagraphsEitherSide() throws {
        for verb in [MarkupVerb.bulletList, .numberedList, .taskItem, .blockQuote] {
            let source = "Para.\n\nNext."
            let on = try #require(apply(verb, source, range(6, 0)))
            let bare = MarkdownBlocks.blocks(from: on.text).map(\.kind)
            #expect(bare.first == .paragraph(MarkdownText(runs: [MarkdownRun(text: "Para.")])),
                    "\(verb.title): the paragraph above reads as \(String(describing: bare.first))")
            let typed = (on.text as NSString).replacingCharacters(in: on.selection, with: "item")
            let blocks = MarkdownBlocks.blocks(from: typed)
            #expect(blocks.count == 3, "\(verb.title): typed, the note reads as \(blocks.map(\.kind))")
            let off = apply(verb, on.text, on.selection)
            let offText = off?.text, offSelection = off?.selection
            #expect(offText == source && offSelection == range(6, 0),
                    "\(verb.title) again wrote \(String(describing: offText)) at \(String(describing: offSelection))")
        }
        let underList = apply(.bulletList, "- a\n\nNext.", range(4, 0))?.text
        #expect(underList == "- a\n- \n\nNext.", "Bullets under a list item wrote \(String(describing: underList))")
    }

    /// **Numbered on a blank line takes up from a numbered item directly above** — "3." under
    /// "2." — and starts at 1 anywhere else.
    @Test func numberedOnABlankLineCarriesOnFromTheItemAbove() {
        #expect(apply(.numberedList, "1. one\n2. two\n", range(14, 0))?.text == "1. one\n2. two\n3. ")
        #expect(apply(.numberedList, "9) nine\n\n", range(8, 0))?.text == "9) nine\n10. \n")
        #expect(apply(.numberedList, "Para.\n\n", range(6, 0))?.text == "Para.\n\n1. \n")
        #expect(apply(.numberedList, "- one\n", range(6, 0))?.text == "- one\n1. ")
    }

    /// **Pressed again on the bare marker, the verb takes it off** and the caret goes back to the
    /// line's start — and the bare marker lights its button, as the bar's lit state promises.
    @Test func pressedAgainOnTheBareMarkerItComesOff() throws {
        for (verb, marker) in Self.starts {
            let on = try #require(apply(verb, "a\n\nb", range(2, 0)))
            #expect(MarkdownEdits.isApplied(verb, in: on.text, selection: on.selection),
                    "the bare \(marker) does not light \(verb.title)")
            #expect(MarkupFormatState.of(on.text, selection: on.selection).lit.contains(verb))
            let off = apply(verb, on.text, on.selection)
            #expect(off?.text == "a\n\nb" && off?.selection == range(2, 0),
                    "\(verb.title) again left \(String(describing: off?.text)) at \(String(describing: off?.selection))")
        }
    }

    /// **A selection keeps its inner blank lines blank** (the rule above it), and one that covers
    /// ONLY blank lines starts an item on each.
    @Test func aSelectionKeepsItsInnerBlankLinesUnlessThatIsAllItHolds() {
        #expect(apply(.bulletList, "one\n\ntwo", range(0, 8))?.text == "- one\n\n- two")
        #expect(apply(.numberedList, "one\n\ntwo", range(0, 8))?.text == "1. one\n\n2. two")
        #expect(apply(.bulletList, "a\n\n\nb", range(2, 2))?.text == "a\n\n- \n- \n\nb")
    }

    /// **A bare caret stays with its text when a marker goes on or comes off** — after Bullets on
    /// "foo|" the caret is still after "foo", not at "- f|oo".
    @Test func aCaretStaysWithItsTextWhenAMarkerGoesOnOrOff() {
        #expect(apply(.bulletList, "foo", range(3, 0))?.selection == range(5, 0))
        #expect(apply(.bulletList, "- foo", range(5, 0))?.selection == range(3, 0))
        #expect(apply(.heading(2), "x\nfoo", range(3, 0))?.selection == range(6, 0))
        #expect(apply(.bulletList, "- foo", range(1, 0))?.selection == range(0, 0), "a caret inside the marker left the line")
        // A selection keeps its words — not the marker too (FMT-8). This line read range(0, 5),
        // `- foo` selected, until Bold on that selection wrote `**- foo**`.
        #expect(apply(.bulletList, "foo", range(0, 3))?.selection == range(2, 3))
    }

    /// **A selection stays on its words when a marker goes on, comes off or changes** (FMT-8), so
    /// the next verb aims at the same words. It kept its index and grew by the change instead:
    /// Bullets on `one` left `- one` selected and Bold then wrote `**- one**`, which is no list
    /// item; Bullets off `- one` left `e` selected, and Bold wrote `on**e**`.
    ///
    /// Mutation: map the selection's start by the total change again (`selectionAfter`), and the
    /// chained Bold and the multi-line selection both fail.
    @Test func aSelectionStaysOnItsWordsWhenAMarkerGoesOnOrOff() throws {
        let on = try #require(apply(.bulletList, "one", range(0, 3)))
        #expect(on.text == "- one" && on.selection == range(2, 3))
        let boldOn = apply(.bold, on.text, on.selection)?.text
        #expect(boldOn == "- **one**", "Bold after Bullets wrote \(String(describing: boldOn))")
        let off = try #require(apply(.bulletList, "- one", range(2, 3)))
        #expect(off.text == "one" && off.selection == range(0, 3))
        let boldOff = apply(.bold, off.text, off.selection)?.text
        #expect(boldOff == "**one**", "Bold after Bullets off wrote \(String(describing: boldOff))")
        // A marker that changes: the words after it stay selected.
        let level = apply(.heading(2), "# Title", range(2, 5))
        let levelSelection = level?.selection
        #expect(level?.text == "## Title" && levelSelection == range(3, 5))
        // Several lines: from the first line's words to the last line's end.
        let lines = apply(.numberedList, "one\ntwo\nthree", range(0, 13))
        let linesSelection = lines?.selection
        #expect(lines?.text == "1. one\n2. two\n3. three" && linesSelection == range(3, 19),
                "the run is selected as \(String(describing: linesSelection))")
        // A selection starting inside a marker that comes off starts where the words do.
        let inside = apply(.bulletList, "- one\n- two", range(1, 10))?.selection
        #expect(inside == range(0, 7))
    }

    // MARK: Blocks

    @Test func aFenceWrapsTheTouchedLines() {
        let edit = apply(.codeBlock, "let x = 1\n", range(0, 0))
        #expect(edit?.text == "```\nlet x = 1\n```\n")
        // The selection lands on the code, not on the fence line.
        #expect((edit?.text as NSString?)?.substring(with: edit?.selection ?? range(0, 0)) == "let x = 1")
    }

    /// **A fence around lines that already hold one is longer than theirs** (FMT-9). Three backticks
    /// around a note with a fenced example closed at the example's first fence: the rest fell out
    /// as a paragraph and an empty block. Mutation: always write three, and the block splits.
    @Test func aFenceAroundAFenceIsLongerThanIt() throws {
        let source = "Example:\n```\ncode\n```"
        let edit = try #require(apply(.codeBlock, source, range(0, (source as NSString).length)))
        #expect(edit.text == "````\nExample:\n```\ncode\n```\n````")
        let blocks = MarkdownBlocks.blocks(from: edit.text).map(\.kind)
        #expect(blocks == [.codeBlock(language: nil, code: "Example:\n```\ncode\n```\n")],
                "the fenced block reads as \(blocks)")
        let code = (edit.text as NSString).substring(with: edit.selection)
        #expect(code == source, "the selection is on “\(code)”, not the code")
        // Indented four or more, a run is code inside the block and closes nothing.
        #expect(MarkdownEdits.fenceLength(around: "    ```\nx") == 3)
        #expect(MarkdownEdits.fenceLength(around: "  `````") == 6)
    }

    /// `---` directly under a paragraph is a setext heading, not a rule — the exact confusion front
    /// matter runs into — so the insert carries its own blank line.
    @Test func aRuleKeepsItsBlankLine() {
        #expect(apply(.horizontalRule, "A paragraph.\n", range(0, 0))?.text
                == "A paragraph.\n\n---\n")
    }

    // MARK: Refusals

    @Test func aSelectionOutsideTheBufferIsRefused() {
        #expect(apply(.bold, "short", range(90, 2)) == nil)
        #expect(apply(.bold, "short", range(NSNotFound, 0)) == nil)
        #expect(apply(.bold, "short", range(3, 90)) == nil)
    }
}

/// The minimal replacement, which is how a verb reaches the text view as an edit it can undo.
@Suite struct MinimalReplacementTests {

    private func change(_ old: String, _ new: String) -> (range: NSRange, text: String) {
        MarkdownEdits.minimalReplacement(from: old, to: new)
    }

    /// Applying it by hand has to reproduce the new buffer exactly — this is the property the whole
    /// undo path rests on, so it is asserted rather than assumed.
    private func applied(_ old: String, _ new: String) -> String {
        let edit = change(old, new)
        return (old as NSString).replacingCharacters(in: edit.range, with: edit.text)
    }

    @Test func anInsertionIsJustTheInsertedText() {
        let edit = change("one two", "one **two")
        #expect(edit.range == NSRange(location: 4, length: 0))
        #expect(edit.text == "**")
        #expect(applied("one two", "one **two") == "one **two")
    }

    @Test func aDeletionHasNoReplacement() {
        let edit = change("one **two**", "one two")
        #expect(edit.text.isEmpty || edit.text == "two")
        #expect(applied("one **two**", "one two") == "one two")
    }

    /// A verb that rewrites several lines still produces one contiguous range — which is what makes
    /// it one undo step rather than several.
    @Test func aMultiLineEditIsStillOneRange() {
        let before = "one\ntwo\nthree\n"
        let after = "1. one\n2. two\n3. three\n"
        #expect(applied(before, after) == after)
        #expect(change(before, after).range.length < (before as NSString).length,
                "the replacement covered the whole buffer rather than the changed run")
    }

    @Test func identicalBuffersProduceAnEmptyEdit() {
        let edit = change("same", "same")
        #expect(edit.range.length == 0)
        #expect(edit.text.isEmpty)
    }

    /// The prefix and suffix scans must not overlap and eat the same characters twice — the classic
    /// way this goes wrong is a repeated substring at both ends.
    @Test func aRepeatedRunAtBothEndsIsNotCountedTwice() {
        #expect(applied("aaaa", "aa") == "aa")
        #expect(applied("aa", "aaaa") == "aaaa")
        #expect(applied("abab", "abcab") == "abcab")
    }
}
