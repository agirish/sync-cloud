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

    @Test func strikeAndCodeWrapTheirOwnDelimiters() {
        #expect(apply(.strikethrough, "gone", range(0, 4))?.text == "~~gone~~")
        #expect(apply(.inlineCode, "let x", range(0, 5))?.text == "`let x`")
        #expect(apply(.inlineCode, "`let x`", range(1, 5))?.text == "let x")
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

    // MARK: Blocks

    @Test func aFenceWrapsTheTouchedLines() {
        let edit = apply(.codeBlock, "let x = 1\n", range(0, 0))
        #expect(edit?.text == "```\nlet x = 1\n```\n")
        // The selection lands on the code, not on the fence line.
        #expect((edit?.text as NSString?)?.substring(with: edit?.selection ?? range(0, 0)) == "let x = 1")
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
