import Testing
import Foundation
@testable import FileExplorer

/// What the status line says about the buffer: the counts, the caret, and the line endings.
///
/// **Every rule here is one somebody would otherwise get wrong once and ship.** A trailing newline
/// that invents a line, a CRLF file reported as mixed, a column that counts an emoji twice — each
/// is invisible in the fixture you would write by hand and wrong in a file of his.
@Suite struct EditorDocumentFactsTests {

    // MARK: Line endings

    @Test func aFileOfOneKindReportsThatKind() {
        #expect(EditorLineEnding.detect(in: "a\nb\n") == .lf)
        #expect(EditorLineEnding.detect(in: "a\r\nb\r\n") == .crlf)
        #expect(EditorLineEnding.detect(in: "a\rb\r") == .cr)
    }

    /// The one that a naive scan gets wrong: every CRLF contains a CR, so counting CRs and LFs
    /// separately reports a perfectly ordinary Windows file as mixed.
    @Test func aWindowsFileIsCRLFRatherThanMixed() {
        #expect(EditorLineEnding.detect(in: "one\r\ntwo\r\nthree\r\n") == .crlf)
    }

    @Test func genuinelyMixedIsReportedAsMixed() {
        #expect(EditorLineEnding.detect(in: "one\r\ntwo\nthree\n") == .mixed)
        #expect(EditorLineEnding.detect(in: "one\rtwo\nthree") == .mixed)
    }

    /// A single line with no terminator has no line ending, and the status line omits the segment
    /// rather than claiming one.
    @Test func noLineBreakMeansNoAnswer() {
        #expect(EditorLineEnding.detect(in: "one line, no terminator") == nil)
        #expect(EditorLineEnding.detect(in: "") == nil)
    }

    @Test func aTrailingCarriageReturnIsALoneCR() {
        #expect(EditorLineEnding.detect(in: "a\r") == .cr)
    }

    // MARK: Counts

    @Test func wordsAreRunsOfNonWhitespace() {
        let facts = EditorDocumentFacts.of("one two  three\nfour\n", encoding: nil)
        #expect(facts.words == 4, "counted \(facts.words) words")
    }

    /// Stated on the label and pinned here: markup is words. The alternative would mean this type
    /// knowing what Markdown is.
    @Test func markupCountsAsWords() {
        #expect(EditorDocumentFacts.of("## Heading\n", encoding: nil).words == 2)
    }

    @Test func charactersAreGraphemeClusters() {
        // One family emoji: four scalars, seven UTF-16 units, one character.
        let facts = EditorDocumentFacts.of("👩‍👩‍👦", encoding: nil)
        #expect(facts.characters == 1, "counted \(facts.characters) characters")
    }

    /// `"a\n"` is one line. Splitting on the separator answers two, which is the bug this count
    /// exists to avoid.
    @Test func aTrailingNewlineDoesNotOpenANewLine() {
        #expect(EditorDocumentFacts.lineCount(of: "a\n") == 1)
        #expect(EditorDocumentFacts.lineCount(of: "a\nb") == 2)
        #expect(EditorDocumentFacts.lineCount(of: "a\nb\n") == 2)
        #expect(EditorDocumentFacts.lineCount(of: "a\r\nb\r\n") == 2)
        #expect(EditorDocumentFacts.lineCount(of: "") == 0)
    }

    @Test func theEncodingIsCarriedThroughUntouched() {
        #expect(EditorDocumentFacts.of("x", encoding: "UTF-16 LE").encoding == "UTF-16 LE")
        #expect(EditorDocumentFacts.of("x", encoding: nil).encoding == nil)
    }

    // MARK: Caret

    @Test func theCaretCountsLinesAndColumnsFromOne() {
        let text = "one\ntwo\nthree"
        #expect(EditorCaret.at(utf16Offset: 0, in: text) == EditorCaret(line: 1, column: 1))
        #expect(EditorCaret.at(utf16Offset: 3, in: text) == EditorCaret(line: 1, column: 4))
        // Just past the first newline: the top of line 2.
        #expect(EditorCaret.at(utf16Offset: 4, in: text) == EditorCaret(line: 2, column: 1))
        #expect(EditorCaret.at(utf16Offset: 9, in: text) == EditorCaret(line: 3, column: 2))
    }

    /// The reason the conversion counts UTF-16 in and characters out: an emoji is two UTF-16 units
    /// and one column. A column derived straight from the `NSRange` reads 3 here.
    @Test func anEmojiIsOneColumnNotTwo() {
        let text = "a😀b"
        #expect(EditorCaret.at(utf16Offset: 3, in: text) == EditorCaret(line: 1, column: 3))
    }

    /// CRLF is one Character in Swift, so it advances the line exactly once.
    @Test func aCRLFAdvancesOneLine() {
        let text = "one\r\ntwo"
        #expect(EditorCaret.at(utf16Offset: 5, in: text) == EditorCaret(line: 2, column: 1))
    }

    /// An offset past the end cannot come from a text view describing its own buffer, but the
    /// conversion is called with a remembered offset after the document has been replaced — so it
    /// answers the end rather than trapping.
    @Test func anOffsetPastTheEndLandsAtTheEnd() {
        #expect(EditorCaret.at(utf16Offset: 999, in: "abc") == EditorCaret(line: 1, column: 4))
    }

    // MARK: Captions

    @Test func oneIsSingular() {
        let one = EditorDocumentFacts.of("x", encoding: nil)
        #expect(one.wordsCaption == "1 word")
        #expect(one.charactersCaption == "1 character")
    }

    @Test func zeroAndManyArePlural() {
        let none = EditorDocumentFacts.empty
        #expect(none.wordsCaption == "0 words")
        #expect(none.charactersCaption == "0 characters")
        #expect(EditorDocumentFacts.of("a b", encoding: nil).wordsCaption == "2 words")
    }

    @Test func theCaretCaptionNamesBothNumbers() {
        #expect(EditorStatusLine.caretCaption(EditorCaret(line: 48, column: 12)) == "Line 48, Col 12")
    }

    /// VoiceOver gets one sentence rather than five stops, and the two segments that can be absent
    /// are absent from it too — a label reading "nil line endings" is worse than one that stops.
    @Test func theAccessibilityLabelSkipsWhatIsNotThere() {
        let bare = EditorDocumentFacts.of("one two", encoding: nil)
        let label = EditorStatusLine.accessibilityLabel(facts: bare,
                                                        caret: EditorCaret(line: 1, column: 8))
        #expect(label == "2 words, 7 characters, Line 1, Col 8", "the label read \(label)")

        let full = EditorDocumentFacts.of("one two\r\n", encoding: "UTF-8")
        let both = EditorStatusLine.accessibilityLabel(facts: full,
                                                       caret: EditorCaret(line: 1, column: 1))
        #expect(both.hasSuffix("UTF-8, CRLF line endings"), "the label read \(both)")
    }
}
