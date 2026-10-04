import Testing
import Foundation
import cmark_gfm
@testable import FileExplorer

/// cmark's code-block kind, as `Leaf.kind` carries it.
let CMARK_NODE_CODE_BLOCK_RAW = CMARK_NODE_CODE_BLOCK.rawValue

/// TE54: what Return, Tab and ⇧Tab do in a Markdown list — and, as much, where they do NOTHING new.
///
/// **The buffer is written with `|` for the caret** and the rules are asserted character for
/// character. Where a rule is about nesting, the result is handed to ``MarkdownBlocks`` — the
/// preview's own parse — rather than trusted from the indent arithmetic.
struct MarkdownListEditsTests {

    /// Splits `"- a|"` into the buffer and the caret.
    private func caret(_ marked: String) -> (text: String, selection: NSRange) {
        let ns = marked as NSString
        let at = ns.range(of: "|")
        return (ns.replacingCharacters(in: at, with: ""), NSRange(location: at.location, length: 0))
    }

    /// Splits `"- [a]"`… no — `"- «ab»"` into the buffer and a selection.
    private func selecting(_ marked: String) -> (text: String, selection: NSRange) {
        let ns = marked as NSString
        let open = ns.range(of: "«")
        let without = ns.replacingCharacters(in: open, with: "") as NSString
        let close = without.range(of: "»")
        return (without.replacingCharacters(in: close, with: ""),
                NSRange(location: open.location, length: close.location - open.location))
    }

    private func returnEdit(_ marked: String) -> MarkdownListEdits.ReturnEdit? {
        let (text, selection) = caret(marked)
        return MarkdownListEdits.returnEdit(in: text, selection: selection)
    }

    /// The buffer after Return: the newline as typed, then the opening — what the coordinator does.
    private func afterReturn(_ marked: String) -> String? {
        let (text, selection) = caret(marked)
        switch MarkdownListEdits.returnEdit(in: text, selection: selection) {
        case .continueWith(let opening)?:
            return (text as NSString).replacingCharacters(in: selection, with: "\n" + opening)
        case .endList(let range)?, .clearMarker(let range)?:
            // The marker off; for `.endList` the text view then puts the Return in after it.
            return (text as NSString).replacingCharacters(in: range, with: "")
        case nil:
            return nil
        }
    }

    // MARK: - Return carries the list on

    @Test(arguments: [
        ("- Parmesan to finish|", "- Parmesan to finish\n- "),
        ("* one|", "* one\n* "),
        ("+ one|", "+ one\n+ "),
        // The spacing after the marker is the item's own, and is kept.
        ("-   wide|", "-   wide\n-   "),
        ("-\ttabbed|", "-\ttabbed\n-\t"),
        // Nested: the indent comes with it.
        ("- a\n  - b|", "- a\n  - b\n  - "),
    ])
    func aBulletCarriesOnWithItsOwnMarker(_ before: String, _ after: String) {
        #expect(afterReturn(before) == after)
    }

    @Test(arguments: [
        ("3. Toss with a splash…\n4. Finish with parsley…|", "3. Toss with a splash…\n4. Finish with parsley…\n5. "),
        ("1) one|", "1) one\n2) "),
        ("9. nine|", "9. nine\n10. "),
        // A leading zero is kept.
        ("01. one|", "01. one\n02. "),
    ])
    func aNumberCountsOn(_ before: String, _ after: String) {
        #expect(afterReturn(before) == after)
    }

    /// **The items after it are not renumbered** — Return writes the one new opening, nothing else.
    @Test func theItemsAfterAreLeftAlone() {
        #expect(afterReturn("1. one|\n2. two\n3. three") == "1. one\n2. \n2. two\n3. three")
    }

    @Test(arguments: [
        ("- [ ] eggs|", "- [ ] eggs\n- [ ] "),
        ("- [x] eggs|", "- [x] eggs\n- [ ] "),
        ("- [X] eggs|", "- [X] eggs\n- [ ] "),
        ("* [x] eggs|", "* [x] eggs\n* [ ] "),
        ("1. [x] eggs|", "1. [x] eggs\n2. [ ] "),
    ])
    func aTaskCarriesOnUnticked(_ before: String, _ after: String) {
        #expect(afterReturn(before) == after)
    }

    // MARK: - Return on an empty item ends the list

    @Test(arguments: [
        ("- Parmesan to finish\n- |", "- Parmesan to finish\n"),
        ("1. one\n2. |", "1. one\n"),
        ("- [ ] a\n- [ ] |", "- [ ] a\n"),
        // Nested: the indent goes too, so no line of stray spaces is left. CommonMark reads this
        // empty line as paragraph text (an empty item may not interrupt one), and it is still the
        // item Tab just made — so it is read as though a word followed the marker.
        ("- a\n  - |", "- a\n"),
        ("some words\n- |", "some words\n"),
    ])
    func returnOnAnEmptyItemTakesItsMarkerOff(_ before: String, _ after: String) {
        #expect(afterReturn(before) == after)
    }

    /// The positive control for the case above: it is the EMPTY item that ends the list — the same
    /// marker with words after it carries on.
    @Test func anItemWithWordsDoesNotEndTheList() {
        guard case .continueWith = returnEdit("- a\n- b|") else {
            Issue.record("a non-empty item ended the list")
            return
        }
    }

    // MARK: - Return does what it always did

    @Test(arguments: [
        "plain prose|",
        "# - not a list|",
        // Caret not at the end of the item.
        "- Parmes|an",
        "|- Parmesan",
        // A rule, which CommonMark reads before a list item.
        "- - -|",
        "* * *|",
        // A lone marker with no space after it.
        "-|",
        // Inside a fenced block.
        "```\n- a|",
        "~~~\n- a|",
        "- a\n\n```\n- b|",
        // An indented code block.
        "para\n\n    - code|",
        // The front matter.
        "---\ntags:\n- a|\n---\n\nBody",
        // Raw HTML.
        "<div>\n- a|",
        // A quoted list: its marker is after `> `, and re-indenting would rewrite the quote.
        "> - a|",
        // A tenth digit is not a list marker.
        "999999999. a|",
    ])
    func returnIsLeftAlone(_ marked: String) {
        #expect(returnEdit(marked) == nil, "\(marked.debugDescription)")
    }

    @Test func aSelectionIsLeftAlone() {
        let (text, selection) = selecting("- «ab»")
        #expect(MarkdownListEdits.returnEdit(in: text, selection: selection) == nil)
    }

    /// The front matter's closing line is the boundary: the same `- a` BELOW it is the body's.
    @Test func belowTheFrontMatterIsTheBody() {
        #expect(returnEdit("---\ntags: x\n---\n- a|") == .continueWith("- "))
    }

    /// The fence's closing line is a boundary too.
    @Test func afterAClosedFenceIsTheBody() {
        #expect(returnEdit("```\ncode\n```\n- a|") == .continueWith("- "))
    }

    /// **U+2028 is a character to the parser, so the line holding it is ONE line** — on the caret's
    /// own line and on the line Tab walks up to. Broken there the NSString way, the caret's line
    /// would read "c" (no marker) and the item above would read "x".
    @Test func aLineSeparatorInsideALineIsPartOfIt() throws {
        #expect(returnEdit("- a\n- b\u{2028}c|") == .continueWith("- "))
        #expect(try #require(tab("- a\u{2028}x\n- b|")).0 == "- a\u{2028}x\n  - b")
    }

    @Test func aWindowsFileCarriesOnToo() {
        #expect(returnEdit("- a\r\n- b|") == .continueWith("- "))
    }

    // MARK: - Tab and ⇧Tab

    private func tab(_ marked: String, outdent: Bool = false) -> (String, NSRange)? {
        let (text, selection) = marked.contains("«") ? selecting(marked) : caret(marked)
        switch MarkdownListEdits.tabEdit(in: text, selection: selection, outdent: outdent) {
        case .rewrite(let range, let replacement, let after)?:
            return ((text as NSString).replacingCharacters(in: range, with: replacement), after)
        case .unchanged?:
            return (text, selection)
        case nil:
            return nil
        }
    }

    @Test(arguments: [
        // Two columns under `- `, three under `1. `, four under `10. ` — the previous item's words.
        ("- a\n- b|", "- a\n  - b"),
        // A list that interrupts a paragraph may only start at 1, so the first item of a new
        // sub-list is renumbered — its own number only.
        ("1. a\n2. b|", "1. a\n   1. b"),
        ("10. a\n11. b|", "10. a\n    1. b"),
        // Joining a sub-list that is already there, it keeps its number.
        ("1. a\n   1. x\n2. b|", "1. a\n   1. x\n   2. b"),
        ("-   a\n- b|", "-   a\n    - b"),
        // A second level, under an item that already has a child.
        ("- a\n  - x\n  - y|", "- a\n  - x\n    - y"),
        // A bullet character changed starts a new list, and still nests under the item above.
        ("- a\n* b|", "- a\n  * b"),
        // Tasks.
        ("- [ ] a\n- [ ] b|", "- [ ] a\n  - [ ] b"),
    ])
    func tabNestsUnderThePreviousItem(_ before: String, _ after: String) throws {
        let result = try #require(tab(before))
        #expect(result.0 == after)
    }

    /// **The real check: the preview's parser nests what Tab wrote.** The item that was moved now
    /// draws one level in, under the item above it.
    @Test(arguments: ["- a\n- b|", "1. a\n2. b|", "10. a\n11. b|", "- [ ] a\n- [ ] b|", "-   a\n- b|",
                      "1) a\n2) b|"])
    func thePreviewNestsWhatTabWrote(_ before: String) throws {
        let result = try #require(tab(before)).0
        let items = MarkdownBlocks.blocks(from: result).filter {
            if case .listItem = $0.kind { return true } else { return false }
        }
        #expect(items.map(\.indent) == [0, 1], "\(result.debugDescription) draws at \(items.map(\.indent))")
    }

    @Test func outdentGoesBackToTheParentsColumnAndThePreviewAgrees() throws {
        let result = try #require(tab("- a\n  - b|", outdent: true))
        #expect(result.0 == "- a\n- b")
        let items = MarkdownBlocks.blocks(from: result.0).filter {
            if case .listItem = $0.kind { return true } else { return false }
        }
        #expect(items.map(\.indent) == [0, 0])
        #expect(try #require(tab("1. a\n   - b\n     - c|", outdent: true)).0 == "1. a\n   - b\n   - c")
        // Out of a sub-list, a number other than 1 is kept: the item ends the paragraph's container
        // rather than interrupting it, and the preview draws it as an item at the top.
        let out = try #require(tab("- a\n  1. b\n  2. c|", outdent: true)).0
        #expect(out == "- a\n  1. b\n2. c")
        #expect(MarkdownBlocks.blocks(from: out).map(\.indent) == [0, 1, 0])
    }

    /// **The item Tab just made, before anything is typed in it**, moves back out with ⇧Tab and
    /// ends with Return — though CommonMark calls that line paragraph text until it has a word.
    @Test func anEmptyNestedItemStillMoves() throws {
        #expect(try #require(tab("- a\n- |")).0 == "- a\n  - ")
        #expect(try #require(tab("- a\n  - |", outdent: true)).0 == "- a\n- ")
    }

    /// Tab then ⇧Tab is where you started.
    @Test func tabThenBacktabIsARoundTrip() throws {
        for start in ["- a\n- b|", "1. a\n1. b|", "- a\n  - x\n  - y|", "- a\n- |"] {
            let (text, selection) = caret(start)
            guard case .rewrite(let r1, let t1, let s1)? = MarkdownListEdits.tabEdit(in: text, selection: selection,
                                                                                     outdent: false) else {
                Issue.record("Tab did nothing on \(start.debugDescription)")
                continue
            }
            let once = (text as NSString).replacingCharacters(in: r1, with: t1)
            guard case .rewrite(let r2, let t2, let s2)? = MarkdownListEdits.tabEdit(in: once, selection: s1,
                                                                                     outdent: true) else {
                Issue.record("⇧Tab did nothing after Tab on \(start.debugDescription)")
                continue
            }
            #expect((once as NSString).replacingCharacters(in: r2, with: t2) == text)
            #expect(s2 == selection)
        }
    }

    /// **The item's own lines go with it** — its children and its continuation text — and a blank
    /// line among them stays blank (no trailing spaces written into it).
    @Test func theItemsOwnLinesMoveWithIt() throws {
        let before = "- a\n- b|\n  - child\n\n    more of child\n- c"
        let result = try #require(tab(before)).0
        #expect(result == "- a\n  - b\n    - child\n\n      more of child\n- c")
        let items = MarkdownBlocks.blocks(from: result).compactMap { block -> Int? in
            if case .listItem = block.kind { return block.indent } else { return nil }
        }
        #expect(items == [0, 1, 2, 0])
    }

    /// **A tab inside a code block under the item is code**, and is not rewritten as spaces.
    @Test func aTabInsideTheItemsCodeIsKept() throws {
        let before = "- a\n- b|\n  ```\n  \tindented\n  ```"
        #expect(try #require(tab(before)).0 == "- a\n  - b\n    ```\n    \tindented\n    ```")
    }

    @Test func theCaretMovesWithItsWords() throws {
        // `- b|` (caret after b) → `  - b|`.
        #expect(try #require(tab("- a\n- b|")).1 == NSRange(location: 9, length: 0))
        // A selection inside the line moves with it.
        #expect(try #require(tab("- a\n- «b»")).1 == NSRange(location: 8, length: 1))
        // A caret at the start of the line lands on the marker.
        #expect(try #require(tab("- a\n|- b")).1 == NSRange(location: 6, length: 0))
    }

    @Test(arguments: [
        // The first item has nothing to nest under.
        ("- a|", false),
        ("para\n\n- a|", false),
        // A top-level item has nowhere to go out to.
        ("- a|", true),
        ("- a\n- b|", true),
    ])
    func anItemThatCannotMoveTakesTheKeyAndChangesNothing(_ marked: String, _ outdent: Bool) {
        let (text, selection) = caret(marked)
        #expect(MarkdownListEdits.tabEdit(in: text, selection: selection, outdent: outdent) == .unchanged)
    }

    @Test(arguments: [
        "plain prose|",
        "```\n- a\n- b|",
        "---\nx:\n- a\n- b|\n---",
        "> - a\n> - b|",
    ])
    func outsideAListTabIsLeftAlone(_ marked: String) {
        let (text, selection) = caret(marked)
        #expect(MarkdownListEdits.tabEdit(in: text, selection: selection, outdent: false) == nil)
        #expect(MarkdownListEdits.tabEdit(in: text, selection: selection, outdent: true) == nil)
    }

    @Test func aSelectionAcrossLinesIsLeftAlone() {
        let (text, selection) = selecting("- a\n- «b\n- c»")
        #expect(MarkdownListEdits.tabEdit(in: text, selection: selection, outdent: false) == nil)
    }

    // MARK: - Found by the 2026-10-04 review, each a case the preview's parse settles

    private func items(_ text: String) -> [Int] {
        MarkdownBlocks.blocks(from: text).compactMap { block in
            if case .listItem = block.kind { return block.indent } else { return nil }
        }
    }

    /// **⇧Tab inside a numbered sub-list: the item after it stays an item.** It becomes the first
    /// of a sub-list under the moved one, which may only start at 1 — so it is renumbered `1.`.
    @Test(arguments: [
        ("1. Preheat\n   1. Oven to 200\n   2. Tray in|\n   3. Wait\n2. Bake",
         "1. Preheat\n   1. Oven to 200\n2. Tray in\n   1. Wait\n2. Bake", [0, 1, 0, 1, 0]),
        ("1. a\n   1. x|\n   2. y", "1. a\n1. x\n   1. y", [0, 0, 1]),
    ])
    func outdentKeepsTheNextItemAnItem(_ before: String, _ after: String, _ indents: [Int]) throws {
        let out = try #require(tab(before, outdent: true)).0
        #expect(out == after)
        #expect(items(out) == indents, "\(out.debugDescription) draws \(items(out))")
    }

    /// **A child indented with a tab moves by what it LOOKS like**, not by spaces in front of the
    /// tab, which its stop would swallow.
    @Test func aTabIndentedChildMovesWithItsParent() throws {
        let out = try #require(tab("1. a\n2. b|\n\t- c")).0
        #expect(items(out) == [0, 1, 2], "\(out.debugDescription) draws \(items(out))")
    }

    /// **The parser decides the item's lines**: a lazy line does not strand the child after it,
    /// and a note indented under the list but outside its last item is not pulled in.
    @Test func theItemsLinesAreTheParsers() throws {
        let lazy = try #require(tab("- a\n- b|\nlazy\n  - child")).0
        #expect(items(lazy) == [0, 1, 2], "\(lazy.debugDescription) draws \(items(lazy))")
        let note = try #require(tab("1. Step one\n2. Step two|\n\n  Note under the list")).0
        #expect(note.hasSuffix("\n\n  Note under the list"), "\(note.debugDescription)")
        let fence = try #require(tab("- a\n- b|\n ```\n x\n ```")).0
        #expect(fence.hasSuffix("\n ```\n x\n ```"), "a fence outside the item moved: \(fence.debugDescription)")
    }

    /// A selection inside a marker that shrinks (`100.` → `1.`) never comes out reversed.
    @Test func aSelectionNeverComesOutReversed() throws {
        let (text, _) = caret("99. a\n100. b|")
        guard case .rewrite(_, _, let after)? = MarkdownListEdits.tabEdit(in: text, selection: NSRange(location: 9, length: 1),
                                                                         outdent: false) else {
            Issue.record("Tab did nothing")
            return
        }
        // The `.` of `100.` selected; the marker is now `1.`, so the selection collapses onto the
        // end of the new marker — at 6 (line start) + 4 (under `99. `) + 2 (`1.`).
        #expect(after == NSRange(location: 12, length: 0))
    }

    /// An ideographic space is content to CommonMark — the item is not empty, and is carried on.
    @Test func anIdeographicSpaceIsNotEmpty() {
        #expect(returnEdit("- \u{3000}|") == .continueWith("- "))
    }

    // MARK: - Found by the second review: whatever moves must read back as the same document

    /// The parser's leaves of `text` — block kinds, depths and words — for "nothing but the
    /// moved item changed" assertions.
    private func shape(_ text: String) -> [MarkdownSourceContext.Leaf] {
        MarkdownSourceContext.leaves(in: text as NSString)
    }

    /// **Code under the item moves with it, tab-indented or not, byte for byte** — a Makefile's
    /// tabs stay tabs, and the preview reads the same code block in the same place.
    @Test(arguments: [
        "1. Install the tools\n2. Add the build rule:|\n\t```make\n\tall:\n\t\tcc main.c\n\t```\n3. Run make",
        "1. a\n2. b|\n\n\t\tindented code",
        "- a\n- b|\n  ```\n  \tx\n  ```",
    ])
    func codeUnderTheItemMovesIntact(_ before: String) throws {
        let out = try #require(tab(before)).0
        #expect(out != caret(before).text, "Tab changed nothing, so this proves nothing")
        let old = shape(caret(before).text).filter { $0.kind == CMARK_NODE_CODE_BLOCK_RAW }
        let new = shape(out).filter { $0.kind == CMARK_NODE_CODE_BLOCK_RAW }
        #expect(old.map(\.text) == new.map(\.text), "the code changed: \(out.debugDescription)")
        #expect(out.contains("\tcc main.c") || !before.contains("cc main.c"), "a tab inside the code was rewritten")
    }

    /// ⇧Tab over tab-indented code: the code and the paragraph after it stay what they were.
    @Test func outdentOverTabbedCodeKeepsTheDocument() throws {
        let before = "- a\n  - b|\n    ```\n\tx\n\t  ```\n    para in b"
        let out = try #require(tab(before, outdent: true)).0
        let kinds = shape(out).map(\.text)
        #expect(kinds.contains("para in b"), "\(out.debugDescription) → \(kinds)")
    }

    /// **A tab after the marker, or a marker that changes width, keeps the item's children its own.**
    @Test(arguments: [
        ("1. Open Settings\n2.\tChoose General|\n\t- Turn on Sync\n\t- Pick a folder", [0, 1, 2, 2]),
        ("9. a\n10. b|\n       - c", [0, 1, 2]),
    ])
    func childrenStayWithAnItemWhoseLeadChanges(_ before: String, _ indents: [Int]) throws {
        let out = try #require(tab(before)).0
        #expect(items(out) == indents, "\(out.debugDescription) draws \(items(out))")
    }

    @Test func aRenumberedItemsCodeKeepsItsIndent() throws {
        let out = try #require(tab("9. a\n10. b|\n\n        code")).0
        let code = shape(out).filter { $0.kind == CMARK_NODE_CODE_BLOCK_RAW }.map(\.text)
        #expect(code == ["code\n"], "\(out.debugDescription) → \(code)")
    }

    /// The renumbered item after it is checked where it really is, `10.` becoming `1.` included.
    @Test func theRenumberedNextItemIsCheckedWhereItLands() throws {
        let before = "1. a\n   1. w\n   9. x|\n   10. y"
        let out = try #require(tab(before, outdent: true)).0
        if out != caret(before).text {
            #expect(items(out).count == 4, "\(out.debugDescription) draws \(items(out))")
        }
    }

    /// A setext heading inside the item does not hide its lines from the move.
    @Test func aSetextHeadingDoesNotHideTheItemsLines() throws {
        let before = "10. a\n    Title\n    -----\n    - x|\n      more about x\n      - child"
        let out = try #require(tab(before, outdent: true)).0
        #expect(out != caret(before).text, "⇧Tab did nothing")
        #expect(items(out).count == 3, "\(out.debugDescription) draws \(items(out))")
    }

    /// Tab on an empty item takes its children along.
    @Test func anEmptyItemsChildrenGoWithIt() throws {
        let out = try #require(tab("- Groceries\n- |\n  - eggs")).0
        #expect(out == "- Groceries\n  - \n    - eggs")
    }

    /// **Return on an empty item with another after it clears the marker and nothing else** — a
    /// blank line there would make the next item the words of whatever is typed above it.
    @Test func anEmptyItemMidListOnlyLosesItsMarker() {
        #expect(returnEdit("1. Preheat\n2. |\n3. Bake") == .clearMarker(NSRange(location: 11, length: 3)))
        #expect(returnEdit("1. Preheat\n2. |") == .endList(NSRange(location: 11, length: 3)))
    }

    // MARK: - Found by the third review

    /// **Tab and ⇧Tab in a Windows file** — every neighbour used to read as a blank line, because
    /// the line before was looked up between the `\r` and the `\n`.
    @Test func tabWorksInAWindowsFile() throws {
        #expect(try #require(tab("- a\r\n- b|")).0 == "- a\r\n  - b")
        #expect(try #require(tab("- a\r\n  - b|", outdent: true)).0 == "- a\r\n- b")
        #expect(try #require(tab("1. a\r\n2. b|\r\n   - c")).0 == "1. a\r\n   1. b\r\n      - c")
    }

    /// **The empty last item of a sub-list, with a numbered item after it**: Return clears the
    /// marker and leaves no blank line, or `2. Next` would be the words of what is typed above it.
    /// A bullet after it can follow a paragraph, so there the list ends properly.
    @Test func anEmptyLastSubItemKeepsTheOuterListItsItems() {
        #expect(returnEdit("1. Step\n   - detail\n   - |\n2. Next\n3. Last")
                == .clearMarker(NSRange(location: 20, length: 5)))
        #expect(returnEdit("- a\n  - |\n- b") == .endList(NSRange(location: 4, length: 4)))
        #expect(returnEdit("- a\n  - |\n1. b") == .endList(NSRange(location: 4, length: 4)))
    }

    /// **A whitespace-only line inside code under the item moves with the code** — kept as it was,
    /// its code would change by the move's width and the whole move would be refused.
    @Test func aBlankLineInsideCodeMovesWithIt() throws {
        let before = "- a\n- b|\n  ```py\n  def f():\n      x = 1\n      \n      return x\n  ```"
        let out = try #require(tab(before)).0
        #expect(out != caret(before).text, "Tab was refused")
        let code = shape(out).filter { $0.kind == CMARK_NODE_CODE_BLOCK_RAW }.map(\.text)
        #expect(code == shape(caret(before).text).filter { $0.kind == CMARK_NODE_CODE_BLOCK_RAW }.map(\.text))
    }

    /// **A closing fence is structure, not code**: a tab in its indent past the item's edge is
    /// written as the columns it was, or the fence would land four columns in and stop closing.
    @Test func aClosingFenceWithATabStillCloses() throws {
        let before = "- a\n- b|\n  ```\n  x\n  \t```\n  after"
        let out = try #require(tab(before)).0
        #expect(out != caret(before).text, "Tab was refused")
        #expect(shape(out).map(\.text) == shape(caret(before).text).map(\.text), "\(out.debugDescription)")
    }

    // MARK: - Fuzzed

    /// **Return, Tab and ⇧Tab on every line of 1,500 small generated lists — tabs, numbers, fences,
    /// quotes, front matter, lazy lines — and none of them crashes, reaches past its range, or
    /// leaves a document the parser reads differently from the one asked for.** Seeded, so a
    /// failure names a case that reproduces.
    @Test func fuzzedListsAreNeverCorrupted() {
        let vocabulary = ["- a", "  - b", "    - c", "1. d", "   2. e", "10. f", "\t- g", "-\th", "* i",
                          "- [ ] j", "- [x] k", "```", "\t```", "  code", "\tcode", "", "para", "lazy",
                          "    indented", "> - q", "---", "- ", "  - ", "1. ", "<!-- x -->", "Title", "-----"]
        var seed: UInt64 = 0x5EED_2026_1004
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        var rewrites = 0
        var windowsRewrites = 0
        for _ in 0..<1_500 {
            let lines = (0..<(2 + next(7))).map { _ in vocabulary[next(vocabulary.count)] }
          for ending in ["\n", "\r\n"] {
            let text = lines.joined(separator: ending) as NSString
            var start = 0
            for line in lines {
                let end = start + (line as NSString).length
                let caret = NSRange(location: end, length: 0)
                if let edit = MarkdownListEdits.returnEdit(in: text, selection: caret) {
                    switch edit {
                    case .endList(let range), .clearMarker(let range):
                        #expect(NSMaxRange(range) <= text.length && range.location >= start,
                                "Return reached outside its line in \((text as String).debugDescription)")
                    case .continueWith(let opening):
                        #expect(!opening.isEmpty)
                    }
                }
                for outdent in [false, true] {
                    guard case .rewrite(let range, let replacement, let selection)? =
                            MarkdownListEdits.tabEdit(in: text, selection: caret, outdent: outdent) else { continue }
                    if ending == "\n" { rewrites += 1 } else { windowsRewrites += 1 }
                    #expect(range.location == start && NSMaxRange(range) <= text.length,
                            "\(outdent ? "⇧Tab" : "Tab") reached outside its item in \((text as String).debugDescription)")
                    let result = text.replacingCharacters(in: range, with: replacement) as NSString
                    #expect(NSMaxRange(selection) <= result.length && selection.length >= 0)
                    // Nothing but whitespace and marker digits may differ inside the range.
                    let squeeze = { (s: String) in s.filter { !$0.isWhitespace && !$0.isNumber } }
                    #expect(squeeze(text.substring(with: range)) == squeeze(replacement),
                            "\(outdent ? "⇧Tab" : "Tab") changed words in \((text as String).debugDescription)")
                }
                start = end + (ending as NSString).length
            }
          }
        }
        // The positive control: the generator does produce lists Tab and ⇧Tab move.
        #expect(rewrites > 500, "only \(rewrites) rewrites — the fuzz has gone vacuous")
        // **A Windows file moves exactly as often** — the same lists, the same moves.
        #expect(windowsRewrites == rewrites, "\(rewrites) moves with \\n, \(windowsRewrites) with \\r\\n")
    }

    // MARK: - The line's shape

    @Test func theContentColumnIsCommonMarks() throws {
        #expect(try #require(MarkdownListLine.parse("- a")).contentColumn == 2)
        #expect(try #require(MarkdownListLine.parse("1. a")).contentColumn == 3)
        #expect(try #require(MarkdownListLine.parse("-    a")).contentColumn == 5)
        // Five spaces: the content is one in, and the rest is code inside the item.
        #expect(try #require(MarkdownListLine.parse("-     a")).contentColumn == 2)
        #expect(try #require(MarkdownListLine.parse("  - a")).contentColumn == 4)
        #expect(try #require(MarkdownListLine.parse("\t- a")).contentColumn == 6)
    }
}

/// Where a line sits, as the preview's parser reads it — the context every TE54–TE56 rule asks.
struct MarkdownSourceContextTests {

    private func block(_ marked: String) -> MarkdownSourceContext.Block {
        let ns = marked as NSString
        let at = ns.range(of: "|").location
        let text = ns.replacingCharacters(in: NSRange(location: at, length: 1), with: "") as NSString
        return MarkdownSourceContext.block(at: at, in: text)
    }

    @Test func theNeighboursAreTheParsersLines() {
        guard case .listItem(let item) = block("- a\n  - x\n- b\n- c|") else {
            Issue.record("not read as a list item")
            return
        }
        #expect(item.line == 4)
        #expect(item.previousSiblingLine == 3)
        #expect(item.parentItemLine == nil)

        guard case .listItem(let nested) = block("1. a\n\n   - x\n   - y|") else {
            Issue.record("not read as a list item")
            return
        }
        #expect(nested.line == 4)
        #expect(nested.previousSiblingLine == 3)
        #expect(nested.parentItemLine == 1)
    }

    /// Line numbers count from the top of the FILE, front matter and all.
    @Test func linesAreTheFilesBelowFrontMatter() {
        guard case .listItem(let item) = block("---\na: 1\n---\n- x\n- y|") else {
            Issue.record("not read as a list item")
            return
        }
        #expect(item.line == 5)
        #expect(item.previousSiblingLine == 4)
    }

    @Test func eachLiteralPlaceIsNamed() {
        #expect(block("---\nkey: |v\n---\n") == .frontMatter)
        #expect(block("```\nco|de\n```") == .code)
        #expect(block("```\ncode\n```|") == .code)
        #expect(block("para\n\n    co|de") == .code)
        #expect(block("<div>\nin|side") == .html)
        #expect(block("plain |words") == .other)
        #expect(block("```\ncode\n```\nafter|") == .other)
    }

    /// **cmark's lines, not NSString's.** A U+2028 inside a line is one line to the parser and two
    /// to `lineRange(for:)` — counted the NSString way, the item below it is a line off.
    @Test func aLineSeparatorDoesNotShiftTheLines() {
        guard case .listItem(let item) = block("- a\u{2028}still a\n- b|") else {
            Issue.record("not read as a list item")
            return
        }
        #expect(item.line == 2)
        #expect(item.previousSiblingLine == 1)
    }

    /// The last line of an HTML block that closes on its own end condition is still HTML — cmark
    /// reports the block one line short.
    @Test func theClosingLineOfAnHTMLBlockIsHTML() {
        #expect(block("<!--\nnote\nend of note -->|") == .html)
        #expect(block("<pre>\nx\nmore</pre>|") == .html)
        #expect(block("<!--\nnote -->\n\nafter|") == .other)
    }

    /// `bodyStart` is `split`'s answer, reached without splitting — the same line and its offset.
    @Test(arguments: [
        "no front matter\n- a",
        "---\ntitle: x\n---\nBody",
        "---\ntitle: x\n...\nBody",
        "  ---  \ntitle: x\n---\r\nBody",
        "---\nno closer\n- a",
        "---",
        "",
        "---\na: 1\n---",
        // A newline followed by a combining mark is still the newline `split` cuts at.
        "---\n---\n\u{301}.",
    ])
    func bodyStartIsSplitsAnswer(_ source: String) {
        let split = MarkdownFrontMatter.split(source)
        let start = MarkdownFrontMatter.bodyStart(in: source as NSString)
        #expect(start.line == split.bodyStartLine, "\(source.debugDescription)")
        if split.frontMatter != nil {
            #expect((source as NSString).substring(from: start.offset) == split.body, "\(source.debugDescription)")
        } else {
            #expect(start.offset == 0)
        }
    }
}
