import Testing
import Foundation
@testable import FileExplorer

/// Edits made to somebody's file by a click rather than by typing.
///
/// **The bar here is character-for-character.** These functions write to real files in real cloud
/// folders, so "it looked right in the preview" is not the standard — every case asserts the whole
/// buffer, including the lines that must not have moved.
@Suite struct MarkdownEditsTests {

    // MARK: Ticking

    @Test func anUntickedBoxBecomesTicked() {
        let source = "- [ ] one\n- [ ] two\n"
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: source) == "- [x] one\n- [ ] two\n")
        #expect(MarkdownEdits.toggleTask(onLine: 2, in: source) == "- [ ] one\n- [x] two\n")
    }

    @Test func aTickedBoxBecomesUnticked() {
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "- [x] one\n") == "- [ ] one\n")
    }

    /// GFM accepts a capital and other tools write one; the flip has to recognise it, and it
    /// normalises to the lowercase the app writes everywhere else.
    @Test func aCapitalXIsRecognisedAndNormalised() {
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "- [X] one\n") == "- [ ] one\n")
    }

    @Test func indentedAndNumberedItemsAreBothHandled() {
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "    - [ ] nested\n")
                == "    - [x] nested\n")
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "1. [ ] first\n") == "1. [x] first\n")
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "12) [ ] twelfth\n") == "12) [x] twelfth\n")
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "* [ ] star\n") == "* [x] star\n")
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "+ [ ] plus\n") == "+ [x] plus\n")
    }

    /// The whole reason the walk parses real GFM rather than pattern-matching: a bracket pair in
    /// prose is not a checkbox, and this must not turn one into an `[x]`.
    @Test func aBracketPairInProseIsLeftAlone() {
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "See [ ] for the blank.\n") == nil)
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "A sentence with - [ ] inside it.\n") == nil)
    }

    /// `-[x]` is not a task item to any parser, so it must not become one here.
    @Test func aMarkerWithNoSpaceIsNotATaskItem() {
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "-[ ] tight\n") == nil)
    }

    @Test func aNonCheckboxBracketAfterAMarkerIsLeftAlone() {
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "- [link](url)\n") == nil)
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "- [] empty\n") == nil)
    }

    /// A click can arrive up to a debounce after the buffer changed, naming a line that no longer
    /// holds a checkbox. Refusing is what stops it writing an `[x]` into whatever is there now.
    @Test func aStaleClickChangesNothing() {
        #expect(MarkdownEdits.toggleTask(onLine: 2, in: "- [ ] one\nplain prose now\n") == nil)
        #expect(MarkdownEdits.toggleTask(onLine: 90, in: "- [ ] one\n") == nil)
        #expect(MarkdownEdits.toggleTask(onLine: 0, in: "- [ ] one\n") == nil)
    }

    /// Nothing outside the three characters moves — including the line's own trailing content and
    /// the line endings of a file that came from Windows.
    @Test func onlyTheBoxIsRewritten() {
        let crlf = "# Notes\r\n\r\n- [ ] one **bold**\r\n- [x] two\r\n"
        #expect(MarkdownEdits.toggleTask(onLine: 3, in: crlf)
                == "# Notes\r\n\r\n- [x] one **bold**\r\n- [x] two\r\n")
    }

    @Test func theLastLineWithNoTerminatorIsStillALine() {
        #expect(MarkdownEdits.toggleTask(onLine: 2, in: "- [ ] one\n- [ ] two")
                == "- [ ] one\n- [x] two")
    }

    // MARK: Line ranges

    @Test func lineRangesCoverTheLineWithoutItsTerminator() {
        let text = "one\ntwo\nthree"
        #expect(text[MarkdownEdits.lineRange(of: 1, in: text) ?? text.startIndex..<text.startIndex] == "one")
        #expect(text[MarkdownEdits.lineRange(of: 2, in: text) ?? text.startIndex..<text.startIndex] == "two")
        #expect(text[MarkdownEdits.lineRange(of: 3, in: text) ?? text.startIndex..<text.startIndex] == "three")
        #expect(MarkdownEdits.lineRange(of: 4, in: text) == nil)
    }

    @Test func aCRLFLineRangeStopsBeforeBothCharacters() {
        let text = "one\r\ntwo\r\n"
        #expect(text[MarkdownEdits.lineRange(of: 1, in: text) ?? text.startIndex..<text.startIndex] == "one")
        #expect(text[MarkdownEdits.lineRange(of: 2, in: text) ?? text.startIndex..<text.startIndex] == "two")
    }
}
