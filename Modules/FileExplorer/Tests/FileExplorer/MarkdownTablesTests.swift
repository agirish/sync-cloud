import Testing
import AppKit
@testable import FileExplorer
import EventsTestSupport

/// The Table menu's edits (TE65, TE66): which table the caret is in, inserting and converting,
/// rows and columns — keeping a table's style — and Tidy.
@MainActor
@Suite(.serialized) struct MarkdownTablesTests {

    /// **cmark's reading, through the preview's own projection** (TBL-16): each table Preview draws,
    /// with its columns and its lines. Structure is graded with this, not only with
    /// `MarkdownTables.table(in:)` — the reader under test grading its own writing passed a row cmark
    /// does not read as one. (cmark's lines for a table whose header ended a paragraph begin at that
    /// paragraph's first line.)
    static func cmarkTables(_ text: String) -> [(columns: Int, lines: [String])] {
        MarkdownProjection.project(text).blocks.compactMap { block in
            guard case .table(let columns) = block.kind else { return nil }
            return (columns, (text as NSString).substring(with: block.source).components(separatedBy: "\n"))
        }
    }

    static func whole(_ text: String) -> NSRange { NSRange(location: 0, length: (text as NSString).length) }

    // MARK: Finding the table

    static let simple = "| a | b |\n| --- | --- |\n| 1 | 2 |"

    /// The position's row and column, the header as row 0 and the delimiter row as no cell row.
    @Test func aPositionNamesItsTableRowAndColumn() throws {
        let ns = Self.simple as NSString
        func at(_ needle: String, _ occurrence: Int = 0) throws -> MarkdownTables.Location {
            var range = ns.range(of: needle)
            for _ in 0..<occurrence { range = ns.range(of: needle, range: NSRange(location: NSMaxRange(range), length: ns.length - NSMaxRange(range))) }
            return try #require(MarkdownTables.locate(in: ns, at: range.location), "no table at \(needle)")
        }
        let one = try at("1")
        #expect(one.table == NSRange(location: 0, length: ns.length))
        #expect((one.row, one.column, one.onDelimiter) == (1, 0, false))
        #expect((try at("2").row, try at("2").column) == (1, 1))
        #expect((try at("b").row, try at("b").column) == (0, 1))
        let delimiter = try at("---", 1)
        #expect((delimiter.row, delimiter.column, delimiter.onDelimiter) == (0, 1, true))
        // Before the first pipe of a row, still that row's first cell.
        #expect(MarkdownTables.locate(in: ns, at: 0)?.column == 0)
    }

    /// GitHub's rule, not "any line with a pipe": a delimiter row matching the header, no fence
    /// around it, and the lines above the header not part of it.
    @Test func onlyAHeaderAndAMatchingDelimiterMakeATable() {
        func found(_ text: String, at needle: String) -> Bool {
            let ns = text as NSString
            return MarkdownTables.locate(in: ns, at: ns.range(of: needle).location) != nil
        }
        #expect(!found("a | b\nplain words\n1 | 2", at: "1"), "no delimiter row")
        #expect(!found("| a | b |\n| --- |\n| 1 | 2 |", at: "1"), "a delimiter with fewer cells than the header")
        #expect(!found("```\n| a | b |\n| --- | --- |\n| 1 | 2 |\n```", at: "1"), "inside a fenced code block")
        #expect(found("```\ncode\n```\n\n| a | b |\n| --- | --- |\n| 1 | 2 |", at: "1"), "after a closed fence")
        #expect(found("a | b\n--- | ---\n1 | 2", at: "2"), "rows without outer pipes are rows")
        #expect(!found("Intro | aside\n| a | b |\n| - | - |\n| 1 | 2 |", at: "Intro"), "a line above the header")
        #expect(found("Intro | aside\n| a | b |\n| - | - |\n| 1 | 2 |", at: "2"))
        #expect(!found("| a | b |\n| --- | --- |\n\n| 1 | 2 |", at: "1"), "a blank line ends the table")
        // Handed a range directly — editable Preview's way in — the same rule holds: a delimiter
        // row narrower than the header is no table, so nothing is edited.
        let mismatched = "| a | b |\n| --- |\n| 1 | 2 |"
        let all = NSRange(location: 0, length: (mismatched as NSString).length)
        #expect(MarkdownTables.table(in: mismatched as NSString, range: all) == nil)
        #expect(MarkdownTables.edit(.addRowBelow, source: mismatched, table: all, row: 1, column: 0) == nil)
        #expect(MarkdownTables.tidy(source: mismatched, table: all) == nil)
        // An escaped pipe is text, not a cell edge.
        #expect(MarkdownTables.cells("| a \\| b | c |") == ["a \\| b", "c"])
    }

    /// **A table's lines are the ones cmark draws** (TBL-3, TBL-9). A line right under a table that
    /// starts another block — a list item, a quote, a heading, a rule — ends it, pipes or not, and
    /// Format Table had turned one into a row. A written line that starts none is a row, pipe or
    /// not, and the Table menu had said a caret there was not in a table.
    @Test func aTableEndsWhereCmarkEndsIt() throws {
        for tail in ["- x | y", "> q | r", "# h | i", "1. n | m", "***"] {
            let text = "| a | b |\n|---|---|\n| 1 | 2 |\n" + tail
            let ns = text as NSString
            let one = NSRange(location: ns.range(of: "| 1 |").location + 2, length: 0)
            let at = try #require(MarkdownTables.locate(in: ns, at: one.location), "“\(tail)”: no table")
            #expect(ns.substring(with: at.table) == "| a | b |\n|---|---|\n| 1 | 2 |", "“\(tail)” was taken into the table")
            #expect(MarkdownTables.locate(in: ns, at: ns.length - 1) == nil, "a caret on “\(tail)” is in the table")
            let tidy = try #require(MarkdownTables.apply(.tidy, to: text, selection: one))
            #expect(tidy.text.hasSuffix("\n" + tail), "Format Table rewrote “\(tail)”: “\(tidy.text)”")
            #expect(Self.cmarkTables(tidy.text).first?.lines.count == 3)
        }
        let text = "| a | b |\n|---|---|\n| 1 | 2 |\nnext"
        let ns = text as NSString
        let next = NSRange(location: ns.range(of: "next").location, length: 0)
        #expect(Self.cmarkTables(text).first?.lines.count == 4, "the case is wrong: cmark does not draw “next” as a row")
        let at = try #require(MarkdownTables.locate(in: ns, at: next.location), "a row with no pipe is not in the table")
        #expect(at.row == 2 && at.table == Self.whole(text))
        #expect(MarkdownTables.available(in: ns, selection: next).contains(.deleteRow))
        #expect(MarkdownTables.touches(ns, next), "the verbs that would take the row out of the table are not greyed there")
        let tidy = try #require(MarkdownTables.apply(.tidy, to: text, selection: next))
        #expect(tidy.text.hasSuffix("\n| next |     |"), "“\(tidy.text)”")
        #expect(Self.cmarkTables(tidy.text).first?.lines.count == 4)
    }

    /// **A table in a block quote is a table** (TBL-5): its rows are read past their `>` and
    /// written back with it, and it is guarded like any other. The `>` was read as a first cell,
    /// which hid the table — no capsule, Bulleted List took a row out of it, Insert Table split it
    /// in two — and a table made in a quote was written outside it.
    @Test func aTableInABlockQuoteIsOne() throws {
        let text = "> | a | bb |\n> | - | - |\n> | 1 | 2 |\n> | 3 | 4 |"
        let ns = text as NSString
        let one = NSRange(location: ns.range(of: "1").location, length: 0)
        #expect(Self.cmarkTables(text).first?.columns == 2, "the case is wrong: cmark draws no table")
        let at = try #require(MarkdownTables.locate(in: ns, at: one.location), "a quoted table is not found")
        #expect(at.row == 1 && at.column == 0 && at.table == Self.whole(text))
        #expect(MarkdownTables.touches(ns, one) && MarkdownEdits.apply(.bulletList, to: text, selection: one) == nil,
                "Bulleted List takes a quoted row out of its table")
        #expect(MarkdownTables.apply(.insert, to: text, selection: one) == nil, "Insert Table splits a quoted table")
        for op in [TableVerb.addRowAbove, .addRowBelow, .addColumnLeft, .addColumnRight, .deleteRow, .deleteColumn, .tidy] {
            let edit = try #require(MarkdownTables.apply(op, to: text, selection: one), "\(op.title) refused in a quote")
            #expect(edit.text.components(separatedBy: "\n").allSatisfy { $0.hasPrefix(">") },
                    "\(op.title) took a row out of the quote: “\(edit.text)”")
            #expect(Self.cmarkTables(edit.text).count == 1, "\(op.title): cmark reads “\(edit.text)” as \(Self.cmarkTables(edit.text))")
        }
        #expect(MarkdownTables.apply(.addRowBelow, to: text, selection: one)?.text
                == "> | a | bb |\n> | - | - |\n> | 1 | 2 |\n> |  |  |\n> | 3 | 4 |")
        // A table made in a quote stays in it.
        let note = "> Prices:\n> after"
        let inserted = try #require(MarkdownTables.apply(.insert, to: note, selection: NSRange(location: 3, length: 0)))
        #expect(inserted.text.components(separatedBy: "\n").allSatisfy { $0.hasPrefix(">") }, "“\(inserted.text)”")
        #expect(Self.cmarkTables(inserted.text).first?.columns == 3, "“\(inserted.text)”")
        #expect((inserted.text as NSString).substring(with: inserted.selection) == "Column 1")
        let csv = "> a,b\n> c,d"
        let made = try #require(MarkdownTables.apply(.fromSelection, to: csv, selection: Self.whole(csv)))
        #expect(made.text == "> | a   | b   |\n> | --- | --- |\n> | c   | d   |", "“\(made.text)”")
    }

    /// **A triple-clicked line just above a table does not touch it** (FMT-12): its selection ends at
    /// the start of the table's header line, but the line it selected is the one above, and that is
    /// all a line verb rewrites. Heading greyed there, and was refused from the menu bar, for a table
    /// it leaves alone.
    @Test func aTripleClickedLineAboveATableDoesNotTouchIt() throws {
        let text = "Title\n| a | b |\n| - | - |\n| 1 | 2 |"
        let title = NSRange(location: 0, length: 6)
        #expect(!MarkdownTables.touches(text as NSString, title), "the line above a table touches it")
        #expect(!MarkupFormatState.of(text, selection: title).touchesTable)
        let heading = try #require(MarkdownEdits.apply(.heading(1), to: text, selection: title), "Heading 1 refused")
        #expect(heading.text.hasPrefix("# Title\n| a | b |"), "“\(heading.text)”")
        #expect(Self.cmarkTables(heading.text).first?.lines.count == 3, "the heading took the table's lines: “\(heading.text)”")
        // A selection that does run onto the table's line still touches it.
        #expect(MarkdownTables.touches(text as NSString, NSRange(location: 0, length: 7)))
    }

    /// **A list or quote on the paragraph line right above a table would swallow it** (FMT-2): with
    /// no blank line between, the table's lines become lazy text of the new item or quote, and cmark
    /// draws no table. Those verbs are refused there, and greyed on the bar and in the right-click
    /// menu. Heading is not — a heading ends at its own line — and a blank line between frees them.
    @Test func aListOrQuoteRightAboveATableWouldSwallowIt() throws {
        let text = "Intro\n| a | b |\n| - | - |\n| 1 | 2 |"
        let intro = NSRange(location: 2, length: 0)
        #expect(Self.cmarkTables(text).count == 1)
        let state = MarkupFormatState.of(text, selection: intro)
        for (verb, marker) in [(MarkupVerb.bulletList, "- "), (.numberedList, "1. "), (.taskItem, "- [ ] "), (.blockQuote, "> ")] {
            #expect(Self.cmarkTables(marker + text).isEmpty, "the case is wrong: “\(marker)Intro” leaves the table whole")
            #expect(MarkdownEdits.apply(verb, to: text, selection: intro) == nil, "\(verb.title) swallowed the table")
            #expect(!EditorFormatBar.isOffered(verb, in: state), "\(verb.title) is not greyed above the table")
        }
        let heading = try #require(MarkdownEdits.apply(.heading(1), to: text, selection: intro), "Heading 1 refused above a table")
        #expect(Self.cmarkTables(heading.text).count == 1, "“\(heading.text)”")
        #expect(EditorFormatBar.isOffered(.heading(1), in: state))
        let menu = PlainTextEditor.Coordinator.markupMenu(target: nil, action: #selector(NSText.copy(_:)), tables: [.insert],
                                                          inTable: false, abutsTable: state.abutsTable)
        #expect(menu.items.first { $0.title == MarkupVerb.bulletList.title }?.isEnabled == false, "the right-click menu offers Bulleted List")
        #expect(menu.items.first { $0.title == MarkupVerb.heading(1).title }?.isEnabled == true)
        let apart = "Intro\n\n| a | b |\n| - | - |\n| 1 | 2 |"
        #expect(MarkdownEdits.apply(.bulletList, to: apart, selection: intro) != nil, "a blank line between and the list is still refused")
    }

    /// **Code that looks like a table is code** (TBL-7): where cmark draws a code block, front
    /// matter or HTML, no table is found and Format Table rewrites nothing. A walk for open fences
    /// took a ```` ```js ```` line inside a fence for its close, skipped a fence indented in a
    /// list item, and never saw an indented code block, front matter or an HTML block at all.
    @Test func codeThatLooksLikeATableIsNotOne() {
        let cases = [
            "an info string inside a fence": "```\n```js\n| a | b |\n| - | - |\n| 1 | 2 |\n```",
            "a fence in a list item, indented four": "1. item\n\n    ```\n    | a | b |\n    | - | - |\n    | 1 | 2 |\n    ```",
            "an indented code block": "text\n\n    | a | b |\n    | - | - |\n    | 1 | 2 |",
            "front matter": "---\n| a | b |\n| - | - |\n---\n\nbody",
            "an HTML block": "<div>\n| a | b |\n| - | - |\n| 1 | 2 |\n</div>",
        ]
        for (name, text) in cases.sorted(by: { $0.key < $1.key }) {
            let ns = text as NSString
            let header = NSRange(location: ns.range(of: "| a").location + 2, length: 0)
            #expect(Self.cmarkTables(text).isEmpty, "\(name): cmark draws a table — the case is wrong")
            #expect(MarkdownTables.locate(in: ns, at: header.location) == nil, "\(name): found a table cmark does not draw")
            #expect(MarkdownTables.apply(.tidy, to: text, selection: header) == nil, "\(name): Format Table rewrote code")
            #expect(!MarkdownTables.touches(ns, header), "\(name): the line verbs grey in code")
        }
        // The control: the same lines, out of the code, are a table.
        #expect(MarkdownTables.locate(in: "| a | b |\n| - | - |\n| 1 | 2 |", at: 2) != nil)
    }

    // MARK: Insert Table

    @Test func insertTablePutsATableOnAParagraphOfItsOwnAndSelectsTheFirstHeader() throws {
        let after = try #require(MarkdownTables.apply(.insert, to: "Hello world\nnext", selection: NSRange(location: 5, length: 0)))
        #expect(after.text == """
            Hello world

            | Column 1 | Column 2 | Column 3 |
            | -------- | -------- | -------- |
            |          |          |          |
            |          |          |          |

            next
            """, "Insert Table wrote “\(after.text)”")
        #expect((after.text as NSString).substring(with: after.selection) == "Column 1")
        // On a blank line between paragraphs: that line, a blank line kept on each side.
        let between = try #require(MarkdownTables.apply(.insert, to: "a\n\nb", selection: NSRange(location: 2, length: 0)))
        #expect(between.text.hasPrefix("a\n\n| Column 1") && between.text.hasSuffix("|\n\nb"), "“\(between.text)”")
        // At the very end of a note with no last line break.
        let end = try #require(MarkdownTables.apply(.insert, to: "a", selection: NSRange(location: 1, length: 0)))
        #expect(end.text.hasPrefix("a\n\n| Column 1") && end.text.hasSuffix("|"))
        // Never inside a table.
        #expect(MarkdownTables.apply(.insert, to: Self.simple, selection: NSRange(location: 2, length: 0)) == nil)
        // What it writes is a table, three columns wide.
        let ns = after.text as NSString
        let table = try #require(MarkdownTables.locate(in: ns, at: after.selection.location))
        #expect(MarkdownTables.table(in: ns, range: table.table)?.columns == 3)
    }

    /// **Insert Table after a triple-clicked line goes after THAT line** (TBL-11, FMT-17). Such a
    /// selection ends just past the line break, at the start of the next line, and the table went
    /// after the next line instead. The same end made a triple-clicked line just above a table
    /// count as in the table, and Insert was refused there.
    @Test func insertTableAfterAWholeLineSelectionGoesAfterThatLine() throws {
        let text = "one\ntwo\nthree"
        let edit = try #require(MarkdownTables.apply(.insert, to: text, selection: NSRange(location: 0, length: 4)))
        #expect(edit.text.hasPrefix("one\n\n| Column 1") && edit.text.hasSuffix("|\n\ntwo\nthree"), "“\(edit.text)”")
        let above = "Title\n| a | b |\n| - | - |\n| 1 | 2 |"
        let title = NSRange(location: 0, length: 6)
        #expect(MarkdownTables.available(in: above as NSString, selection: title).contains(.insert))
        let inserted = try #require(MarkdownTables.apply(.insert, to: above, selection: title))
        #expect(inserted.text.hasPrefix("Title\n\n| Column 1"), "“\(inserted.text)”")
        #expect(Self.cmarkTables(inserted.text).count == 2, "cmark reads “\(inserted.text)” as \(Self.cmarkTables(inserted.text))")
    }

    // MARK: Make Table from Selection

    @Test func linesPastedFromASpreadsheetBecomeATable() throws {
        let tsv = "Pasta\tCook (min)\tWater (L)\nSpaghetti\t9\t2\nPenne\t11\t2"
        let made = try #require(MarkdownTables.apply(.fromSelection, to: tsv, selection: NSRange(location: 0, length: (tsv as NSString).length)))
        #expect(made.text == """
            | Pasta     | Cook (min) | Water (L) |
            | --------- | ---------- | --------- |
            | Spaghetti | 9          | 2         |
            | Penne     | 11         | 2         |
            """, "“\(made.text)”")
        #expect(made.selection == NSRange(location: (made.text as NSString).length, length: 0))
        // Commas, with CSV's quoting; a pipe in a cell escaped; a blank line left out.
        let csv = "name,note\n\nx,\"a, b\"\ny,\"he said \"\"hi\"\" | ok\""
        let fromCSV = try #require(MarkdownTables.apply(.fromSelection, to: csv, selection: NSRange(location: 0, length: (csv as NSString).length)))
        let rows = fromCSV.text.components(separatedBy: "\n").map(MarkdownTables.cells)
        #expect(rows.count == 4 && rows[0] == ["name", "note"] && rows[2] == ["x", "a, b"]
                && rows[3] == ["y", "he said \"hi\" \\| ok"], "CSV became \(rows)")
        // A selection ending at the start of the next line does not take it.
        let partial = "a\tb\n1\t2\nafter"
        let two = try #require(MarkdownTables.apply(.fromSelection, to: partial, selection: NSRange(location: 0, length: 8)))
        #expect(two.text.hasSuffix("\n\nafter"), "“\(two.text)”")
        // No tabs or commas: nothing to split.
        #expect(MarkdownTables.apply(.fromSelection, to: "just words\nmore", selection: NSRange(location: 0, length: 15)) == nil)
        // Lines that run into a table are not made into another one.
        let intoTable = "x,y\n| a | b |\n| - | - |\n| 1 | 2 |"
        #expect(MarkdownTables.apply(.fromSelection, to: intoTable, selection: NSRange(location: 0, length: 9)) == nil,
                "a selection ending in a table was converted")
        #expect(!MarkdownTables.available(in: intoTable as NSString, selection: NSRange(location: 0, length: 9)).contains(.fromSelection))
        #expect(MarkdownTables.available(in: tsv as NSString, selection: NSRange(location: 0, length: 5)).contains(.fromSelection))
    }

    /// **Make Table from Selection leaves a table inside the selection alone** (TBL-6) — it is
    /// refused, and not offered. Only the selection's two ends were asked about, so a table between
    /// them was flattened, each row one escaped cell, and the blank lines around it were dropped.
    @Test func makeTableFromSelectionRefusesATableInsideIt() {
        let text = "x,y\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nz,w"
        let all = Self.whole(text)
        #expect(MarkdownTables.apply(.fromSelection, to: text, selection: all) == nil, "a table in the selection was flattened")
        #expect(!MarkdownTables.available(in: text as NSString, selection: all).contains(.fromSelection))
        // The control: the same lines without the table convert.
        let plain = "x,y\n\nz,w"
        #expect(MarkdownTables.apply(.fromSelection, to: plain, selection: Self.whole(plain)) != nil)
    }

    // MARK: Rows and columns, keeping the table's style

    static let aligned = """
        | a   | b   |
        | --- | --- |
        | 1   | 2   |
        """

    /// **A lined-up table comes back lined up** — every edit re-pads it.
    @Test func anAlignedTableStaysAligned() throws {
        #expect(MarkdownTables.isAligned(source: Self.aligned, table: NSRange(location: 0, length: (Self.aligned as NSString).length)))
        let one = (Self.aligned as NSString).range(of: "1").location
        for op in [TableVerb.addRowAbove, .addRowBelow, .addColumnLeft, .addColumnRight, .deleteColumn] {
            let edit = try #require(MarkdownTables.apply(op, to: Self.aligned, selection: NSRange(location: one, length: 0)), "\(op.title) refused")
            #expect(MarkdownTables.isAligned(source: edit.text, table: NSRange(location: 0, length: (edit.text as NSString).length)),
                    "\(op.title) left “\(edit.text)” ragged")
        }
        let wider = try #require(MarkdownTables.apply(.addColumnRight, to: Self.aligned, selection: NSRange(location: one, length: 0)))
        #expect(wider.text == "| a   |     | b   |\n| --- | --- | --- |\n| 1   |     | 2   |", "“\(wider.text)”")
        // The caret lands in the new column's cell, on the caret's row.
        let caret = MarkdownTables.locate(in: wider.text as NSString, at: wider.selection.location)
        #expect((caret?.row, caret?.column) == (1, 1))
    }

    static let ragged = "|a|bb|\n|-|-|\n|1|2|\n|3|4|"

    /// **A ragged table changes only where the edit is** — every other line byte for byte.
    @Test func aRaggedTableChangesOnlyTheRowOrColumnTouched() throws {
        let ns = Self.ragged as NSString
        #expect(!MarkdownTables.isAligned(source: Self.ragged, table: NSRange(location: 0, length: ns.length)))
        // One-letter cells put every pipe in the same column: that table IS lined up — but it is
        // compact, not written as Format Table writes, so it keeps its style like a ragged one.
        // (TBL-4: this line pinned that it was re-padded, every line of it rewritten.)
        let compact = "|a|b|\n|-|-|\n|1|2|"
        #expect(MarkdownTables.isAligned(source: compact, table: NSRange(location: 0, length: 17)))
        #expect(!MarkdownTables.keepsLinedUp(source: compact, table: NSRange(location: 0, length: 17)))
        #expect(MarkdownTables.apply(.addRowBelow, to: compact, selection: NSRange(location: 12, length: 0))?.text
                == "|a|b|\n|-|-|\n|1|2|\n|  |  |")
        let one = ns.range(of: "1").location
        func apply(_ op: TableVerb, at location: Int) throws -> String {
            try #require(MarkdownTables.apply(op, to: Self.ragged, selection: NSRange(location: location, length: 0)), "\(op.title) refused").text
        }
        #expect(try apply(.addRowBelow, at: one) == "|a|bb|\n|-|-|\n|1|2|\n|  |  |\n|3|4|")
        #expect(try apply(.addRowAbove, at: one) == "|a|bb|\n|-|-|\n|  |  |\n|1|2|\n|3|4|")
        #expect(try apply(.addRowBelow, at: 1) == "|a|bb|\n|-|-|\n|  |  |\n|1|2|\n|3|4|", "below the header is the first body row")
        #expect(try apply(.deleteRow, at: one) == "|a|bb|\n|-|-|\n|3|4|")
        #expect(try apply(.addColumnLeft, at: ns.range(of: "2").location) == "|a|  |bb|\n|-| --- |-|\n|1|  |2|\n|3|  |4|")
        #expect(try apply(.addColumnRight, at: ns.range(of: "2").location) == "|a|bb|  |\n|-|-| --- |\n|1|2|  |\n|3|4|  |")
        #expect(try apply(.deleteColumn, at: one) == "|bb|\n|-|\n|2|\n|4|")
        // Rows without outer pipes keep that style, and stay rows.
        let bare = "a | b\n--- | ---\n1 | 2"
        let bareNS = bare as NSString
        let wider = try #require(MarkdownTables.apply(.addColumnRight, to: bare, selection: NSRange(location: bareNS.range(of: "2").location, length: 0)))
        #expect(wider.text == "a | b |  |\n--- | --- | --- |\n1 | 2 |  |", "“\(wider.text)”")
        let narrower = try #require(MarkdownTables.apply(.deleteColumn, to: bare, selection: NSRange(location: bareNS.range(of: "1").location, length: 0)))
        #expect(narrower.text == "| b |\n| --- |\n| 2 |", "“\(narrower.text)”")
        let leftmost = try #require(MarkdownTables.apply(.addColumnLeft, to: bare, selection: NSRange(location: 0, length: 0)))
        #expect(MarkdownTables.table(in: leftmost.text as NSString, range: NSRange(location: 0, length: (leftmost.text as NSString).length))?.rows
                == [["", "a", "b"], ["", "1", "2"]], "“\(leftmost.text)”")
    }

    /// **Only a table written the way Format Table writes it is re-padded** (TBL-4). Pipe-less and
    /// compact tables that happen to line up kept no line of their own on Add Row Below — each was
    /// rewritten padded, with outer pipes — and a padded one lost its compact delimiter row. Now
    /// every original line survives, and the menu asks the same question typing in Preview asks.
    @Test func anEditKeepsTheStyleOfATableNotWrittenPadded() throws {
        let tables = ["|a|b|\n|-|-|\n|1|2|", "a  | b\n-- | --\n1  | 2", "Name | Age\n---- | ---\nBob  | 30",
                      "| Name | Age |\n|------|-----|\n| Bob  | 30  |", "| Name | Age |\n|:-----|----:|\n| Bob  | 30  |",
                      "| Name | Age |\n| ---- | --- |\n| Bob  | 30  |"]
        for text in tables {
            let range = Self.whole(text)
            #expect(MarkdownTables.keepsLinedUp(source: text, table: range)
                    == PreviewEditTranslator.realignsAsYouType(text, table: range), "the menu and typing disagree about “\(text)”")
            let caret = (text as NSString).range(of: text.contains("Bob") ? "Bob" : "1").location
            let edit = try #require(MarkdownTables.apply(.addRowBelow, to: text, selection: NSRange(location: caret, length: 0)))
            let after = edit.text.components(separatedBy: "\n")
            #expect(after.count == 4 && text.components(separatedBy: "\n").allSatisfy(after.contains),
                    "Add Row Below rewrote lines of “\(text)”: “\(edit.text)”")
            #expect(Self.cmarkTables(edit.text).first?.lines.count == 4, "cmark reads “\(edit.text)” as \(Self.cmarkTables(edit.text))")
        }
        // A padded table with a compact delimiter row is still re-padded, its delimiter compact.
        let padded = "| Name | Age |\n|------|-----|\n| Bob  | 30  |"
        let wider = try #require(MarkdownTables.apply(.addColumnRight, to: padded, selection: NSRange(location: 2, length: 0)))
        #expect(wider.text == "| Name |     | Age |\n|------|-----|-----|\n| Bob  |     | 30  |", "“\(wider.text)”")
    }

    /// **A new first column in an indented table without outer pipes** (TBL-2): the row takes a
    /// leading pipe at its indent. Put after the indent's last space instead, the new cell read as
    /// a border, the delimiter row had a cell more than the header, and there was no table left.
    @Test func anIndentedTableWithoutOuterPipesTakesANewFirstColumn() throws {
        let text = "  a | b\n  --- | ---\n  1 | 2"
        let edit = try #require(MarkdownTables.apply(.addColumnLeft, to: text, selection: NSRange(location: 2, length: 0)))
        let tables = Self.cmarkTables(edit.text)
        #expect(tables.count == 1 && tables.first?.columns == 3 && tables.first?.lines.count == 3,
                "cmark reads “\(edit.text)” as \(tables)")
        #expect(MarkdownTables.table(in: edit.text as NSString, range: Self.whole(edit.text))?.rows
                == [["", "a", "b"], ["", "1", "2"]], "“\(edit.text)”")
        #expect(MarkdownTables.cellStarts("  a | b").first?.pipe == -1, "a first cell with no pipe is opened by -1, indent or not")
    }

    /// **Delete Column leaves every row a row** (TBL-1): a short row whose only cell goes keeps an
    /// empty one — a lone `|` is no row to cmark, so the table ended there and the rows under it
    /// fell out — and a table whose HEADER has one cell cannot lose it, even when a body row holds
    /// a second (it was offered, and left `|`, `|`, `| 2 |`: no table at all).
    @Test func deleteColumnLeavesEveryRowARow() throws {
        let short = "| a | b |\n| - | - |\n| x |\n| 1 | 2 |"
        let edit = try #require(MarkdownTables.apply(.deleteColumn, to: short, selection: NSRange(location: 2, length: 0)))
        #expect(edit.text == "| b |\n| - |\n| |\n| 2 |", "“\(edit.text)”")
        let tables = Self.cmarkTables(edit.text)
        #expect(tables.count == 1 && tables.first?.lines.count == 4, "cmark reads “\(edit.text)” as \(tables)")

        let single = "| a |\n| - |\n| 1 | 2 |"
        let header = NSRange(location: 2, length: 0)
        #expect(!MarkdownTables.available(in: single as NSString, selection: header).contains(.deleteColumn),
                "Delete Column offered on a table whose header has one cell")
        #expect(MarkdownTables.apply(.deleteColumn, to: single, selection: header) == nil)
        #expect(MarkdownTables.edit(.deleteColumn, source: single, table: Self.whole(single), row: 1, column: 1) == nil,
                "the cell past the header's last took the header's only column with it")
    }

    /// **Add Column from a cell past the header's last** (TBL-10): the header and the delimiter row
    /// are widened out to it, so the new column is one cmark draws. It went into that row alone,
    /// which cmark ignores — the press did nothing anybody could see.
    @Test func addColumnPastTheHeadersLastCellWidensTheHeader() throws {
        let text = "|a|b|\n|-|-|\n|1|2|3|"
        let three = NSRange(location: (text as NSString).range(of: "3").location, length: 0)
        let edit = try #require(MarkdownTables.apply(.addColumnRight, to: text, selection: three))
        #expect(edit.text == "|a|b|  |  |\n|-|-| --- | --- |\n|1|2|3|  |", "“\(edit.text)”")
        #expect(Self.cmarkTables(text).first?.columns == 2)
        #expect(Self.cmarkTables(edit.text).first?.columns == 4, "cmark reads “\(edit.text)” as \(Self.cmarkTables(edit.text))")
    }

    /// **A pipe right after a backslash is escaped, as cmark's table scanner reads it** (TBL-15) —
    /// whatever stands before the backslash: `|a|b\\|` is two cells to cmark, `a` and `b\\|`. A
    /// backslash was taken to escape any character, so `\\` escaped itself, the last pipe split a
    /// third cell off, and the table cmark draws was not found.
    @Test func aPipeAfterABackslashIsEscapedAsCmarkReadsIt() throws {
        let text = "|a|b\\\\|\n|-|-|\n|1|2|"
        #expect(Self.cmarkTables(text).first?.columns == 2, "the case is wrong: cmark does not draw two columns")
        #expect(MarkdownTables.cells("|a|b\\\\|") == ["a", "b\\\\|"])
        #expect(MarkdownTables.cells("| a \\| b | c |") == ["a \\| b", "c"], "an escaped pipe is still text")
        #expect(MarkdownTables.locate(in: text as NSString, at: (text as NSString).range(of: "1").location) != nil,
                "the table cmark draws is not found")
        // A column added after that cell: the row is closed first, as a row ending in text is.
        let wider = try #require(MarkdownTables.apply(.addColumnRight, to: text, selection: NSRange(location: 3, length: 0)))
        #expect(wider.text == "|a|b\\\\| |  |\n|-|-| --- |\n|1|2|  |", "“\(wider.text)”")
        #expect(Self.cmarkTables(wider.text).first?.columns == 3, "cmark reads “\(wider.text)” as \(Self.cmarkTables(wider.text))")
        let tidy = try #require(MarkdownTables.tidy(source: text, table: Self.whole(text)))
        #expect(Self.cmarkTables(tidy.text).first?.columns == 2, "Format Table split the cell: “\(tidy.text)”")
    }

    /// **Only spaces and tabs pad a cell** (TBL-8) — GFM trims nothing else. A no-break space or an
    /// ideographic space at a cell's edge is text Preview draws, and Format Table deleted it.
    @Test func formatTableKeepsOtherSpacesAtACellsEdge() throws {
        let text = "| \u{00A0}x | b\u{3000} |\n|---|---|\n| 1 | 2 |"
        let tidy = try #require(MarkdownTables.tidy(source: text, table: Self.whole(text)))
        #expect(MarkdownTables.cells(tidy.text.components(separatedBy: "\n")[0]) == ["\u{00A0}x", "b\u{3000}"],
                "“\(tidy.text)”")
        #expect(MarkdownProjection.project(tidy.text).renderedString == MarkdownProjection.project(text).renderedString,
                "Format Table changed what Preview draws")
    }

    /// **A ragged table's untouched lines keep their own line breaks** (TBL-18). Joined with one
    /// break, a table whose breaks were mixed lost the `\r` of every line the edit never touched.
    /// Not reachable from Source or Preview today — both convert a file to LF before a verb reads
    /// it — but `edit` is a door of its own.
    @Test func untouchedLinesKeepTheirOwnLineBreaks() throws {
        let text = "| a | bb |\r\n|-|-|\n|1|2|\r\n|3|4|"
        let below = try #require(MarkdownTables.edit(.addRowBelow, source: text, table: Self.whole(text), row: 2, column: 0))
        #expect(below.text == "| a | bb |\r\n|-|-|\n|1|2|\r\n|3|4|\n|  |  |", "\(String(reflecting: below.text))")
        let above = try #require(MarkdownTables.edit(.addRowAbove, source: text, table: Self.whole(text), row: 1, column: 0))
        #expect(above.text == "| a | bb |\r\n|-|-|\n|  |  |\n|1|2|\r\n|3|4|", "\(String(reflecting: above.text))")
        let deleted = try #require(MarkdownTables.edit(.deleteRow, source: text, table: Self.whole(text), row: 2, column: 0))
        #expect(deleted.text == "| a | bb |\r\n|-|-|\n|1|2|", "\(String(reflecting: deleted.text))")
        let wider = try #require(MarkdownTables.edit(.addColumnRight, source: text, table: Self.whole(text), row: 1, column: 1))
        #expect(wider.text.components(separatedBy: "\r\n").count == 3, "\(String(reflecting: wider.text))")
    }

    /// Every edit, on every cell of several tables, leaves a table — one row or column more or
    /// fewer, as it said — and lands the caret in it; and the ones refused are exactly those
    /// ``MarkdownTables/available(in:selection:)`` leaves out.
    ///
    /// **Graded by cmark too** (TBL-16): the table cmark draws after each edit ends where the one
    /// the Table menu reads ends, with the columns its header has. Graded only by
    /// `MarkdownTables.table(in:)` — the reader under test — a lone `|` row passed (TBL-1), and the
    /// corpus held none of the shapes the review broke: an indented table without outer pipes, a
    /// short row, a row wider than the header, a quote, a row with no pipe, a list item right under
    /// a table, a compact delimiter row, an escaped pipe, a header ending a paragraph.
    @Test func everyEditLeavesATableAndAvailabilityMatchesWhatApplies() throws {
        let tables = [Self.simple, Self.aligned, Self.ragged, "a | b\n--- | ---\n1 | 2", "| solo |\n| --- |\n| x |",
                      "  | in | list |\n  | -- | -- |\n  | 1 | 2 |", "| a | b |\r\n| - | - |\r\n| 1 | 2 |",
                      "| solo |\n| ---- |\n| x    |",
                      "before\n\n| a | b |\n| :- | -: |\n| 寿司 | 2 |\n\nafter",
                      "  a | b\n  --- | ---\n  1 | 2", "| a | b | c |\n| - | - | - |\n| x |\n| 1 | 2 | 3 |",
                      "| a | b |\n| - | - |\n| 1 | 2 | 3 |", "> | a | bb |\n> | - | - |\n> | 1 | 2 |",
                      "| a | b |\n|---|---|\n| 1 | 2 |\nnext", "| a | b |\n|---|---|\n| 1 | 2 |\n- x | y",
                      "| Name | Age |\n|------|-----|\n| Bob  | 30  |", "|a|b\\\\|\n|-|-|\n|1|2|",
                      "Intro\n| a | b |\n| - | - |\n| 1 | 2 |"]
        /// cmark's table overlapping `range`: its columns and where its lines end.
        func cmark(_ text: String, over range: NSRange) -> (columns: Int, end: Int)? {
            MarkdownProjection.project(text).blocks.lazy.compactMap { block -> (Int, Int)? in
                guard case .table(let columns) = block.kind, NSIntersectionRange(block.source, range).length > 0 else { return nil }
                return (columns, NSMaxRange(block.source))
            }.first
        }
        var checked = 0
        for text in tables {
            let ns = text as NSString
            for location in 0...ns.length {
                let selection = NSRange(location: location, length: 0)
                let offered = MarkdownTables.available(in: ns, selection: selection)
                guard let at = MarkdownTables.locate(in: ns, at: location),
                      let before = MarkdownTables.table(in: ns, range: at.table) else {
                    #expect(!offered.contains(.tidy), "Tidy offered outside a table in “\(text)” at \(location)")
                    continue
                }
                #expect(!offered.contains(.insert) && !offered.contains(.fromSelection),
                        "a new table offered inside “\(text)” at \(location)")
                for op in TableVerb.allCases where op != .insert && op != .fromSelection {
                    let edit = MarkdownTables.apply(op, to: text, selection: selection)
                    #expect((edit != nil) == offered.contains(op),
                            "\(op.title) in “\(text)” at \(location): \(edit == nil ? "refused" : "applied") but \(offered.contains(op) ? "offered" : "not offered")")
                    guard let edit else { continue }
                    checked += 1
                    let after = try #require(MarkdownTables.locate(in: edit.text as NSString, at: edit.selection.location),
                                             "\(op.title) in “\(text)” at \(location) left the caret outside a table: “\(edit.text)”")
                    let table = try #require(MarkdownTables.table(in: edit.text as NSString, range: after.table))
                    let rows = table.rows.count - before.rows.count
                    // A row edit is held to the header's columns: deleting a row wider than the
                    // header narrows `columns`, which counts every cell any row has.
                    let columns = op == .addRowAbove || op == .addRowBelow || op == .deleteRow
                        ? table.headerColumns - before.headerColumns : table.columns - before.columns
                    let expected: (Int, Int) = switch op {
                    case .addRowAbove, .addRowBelow: (1, 0)
                    case .deleteRow: (-1, 0)
                    case .addColumnLeft, .addColumnRight: (0, 1)
                    case .deleteColumn: (0, -1)
                    default: (0, 0)
                    }
                    #expect((rows, columns) == expected, "\(op.title) in “\(text)” at \(location) changed rows by \(rows), columns by \(columns)")
                    // cmark draws that table: to the same last line, with the header's columns.
                    let drawn = cmark(edit.text, over: after.table)
                    #expect(drawn?.end == NSMaxRange(after.table) && drawn?.columns == table.headerColumns,
                            "\(op.title) in “\(text)” at \(location): cmark reads “\(edit.text)” as \(String(describing: drawn)), the menu as \(after.table) with \(table.headerColumns) columns")
                    // The text around the table is never touched.
                    #expect(edit.text.hasPrefix(ns.substring(to: at.table.location))
                            && edit.text.hasSuffix(ns.substring(from: NSMaxRange(at.table))), "\(op.title) touched text outside the table")
                    // A CRLF table stays CRLF.
                    if text.contains("\r\n") {
                        #expect(!edit.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "\(op.title) wrote a bare \\n into a CRLF table")
                    }
                    // An indented table stays indented, and a quoted one in its quote.
                    for prefix in ["  ", "> "] where text.hasPrefix(prefix) {
                        #expect(edit.text.components(separatedBy: "\n").allSatisfy { $0.hasPrefix(prefix) },
                                "\(op.title) lost the “\(prefix)”: “\(edit.text)”")
                    }
                }
            }
        }
        #expect(checked > 300, "only \(checked) edits were made — the sweep is near-vacuous")
    }

    // MARK: Tidy

    @Test func tidyLinesThePipesUpAndKeepsEverything() throws {
        let messy = "|Name|Qty|Note|\n|:-|-:|:-:|\n|寿司|2|ok|\n|x|10|a \\| b|extra|"
        let ns = messy as NSString
        let tidy = try #require(MarkdownTables.tidy(source: messy, table: NSRange(location: 0, length: ns.length)))
        let range = NSRange(location: 0, length: (tidy.text as NSString).length)
        #expect(MarkdownTables.isAligned(source: tidy.text, table: range), "“\(tidy.text)” is not lined up")
        let table = try #require(MarkdownTables.table(in: tidy.text as NSString, range: range))
        #expect(table.alignments == [.left, .right, .center, .none], "the colons were lost: \(table.alignments)")
        #expect(table.rows.last == ["x", "10", "a \\| b", "extra"], "a cell was lost: \(table.rows)")
        #expect(table.rows[1][0] == "寿司")
        // A wide character takes two columns of the monospaced font, so it pads by two.
        #expect(MarkdownTables.displayWidth("寿司") == 4 && MarkdownTables.displayWidth("ab") == 2)
        let wide = "|寿司|x|\n|-|-|"
        #expect(MarkdownTables.tidy(source: wide, table: NSRange(location: 0, length: (wide as NSString).length))?.text
                == "| 寿司 | x   |\n|------|-----|", "a compact delimiter row stays compact (TBL-4)")
        // Tidy is a fixed point.
        #expect(MarkdownTables.tidy(source: tidy.text, table: range)?.text == tidy.text)
        // From the menu, the caret keeps its place in its cell.
        let caret = ns.range(of: "10").location + 1
        let fromMenu = try #require(MarkdownTables.apply(.tidy, to: messy, selection: NSRange(location: caret, length: 0)))
        #expect((fromMenu.text as NSString).substring(with: NSRange(location: fromMenu.selection.location - 1, length: 2)) == "10")
        // An indented table keeps its indent.
        let indented = "  |a|b|\n  |-|-|\n  |1|2|"
        let kept = try #require(MarkdownTables.tidy(source: indented, table: NSRange(location: 0, length: (indented as NSString).length)))
        #expect(kept.text == "  | a   | b   |\n  |-----|-----|\n  | 1   | 2   |", "“\(kept.text)”")
    }

    /// **An emoji a variation selector asks for counts two columns** (TBL-12) — ⚠️, ❤️, ✔️ are
    /// text-style symbols with U+FE0F after them, drawn as emoji, and were counted one, so Format
    /// Table's pipes after one sat 11pt from the rows below in the editor's font.
    @Test func aVariationSelectorEmojiCountsTwoColumns() {
        #expect(["⚠️", "❤️", "✔️", "1️⃣", "✅", "寿"].map(MarkdownTables.displayWidth) == [2, 2, 2, 2, 2, 2])
        #expect(MarkdownTables.displayWidth("⚠") == 1, "without the selector it is a text symbol")
    }

    /// **Measured in the editor's font, a tidied table holding emoji or CJK lines up to within one
    /// column** (TBL-12) — what the doc comment and Help now say, rather than "lines up": SF Mono's
    /// fallbacks for them are not exactly two columns wide. Pinned: it measures laid-out text.
    @Test(.machinePinned(.layoutMetrics)) func formatTableLinesUpEmojiAndCJKToWithinAColumnOnScreen() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let column = NSAttributedString(string: "a", attributes: [.font: font]).size().width
        func pipes(_ line: String) -> [CGFloat] {
            let ns = line as NSString
            return (0..<ns.length).filter { ns.character(at: $0) == 0x7C }.map {
                NSAttributedString(string: ns.substring(to: $0), attributes: [.font: font]).size().width
            }
        }
        for cell in ["⚠️", "❤️", "✅", "寿司"] {
            let messy = "|\(cell)|x|\n|-|-|\n|ok|y|"
            let lines = try #require(MarkdownTables.tidy(source: messy, table: Self.whole(messy))).text.components(separatedBy: "\n")
            let xs = lines.map(pipes)
            for index in xs[0].indices {
                let spread = (xs.map { $0[index] }.max() ?? 0) - (xs.map { $0[index] }.min() ?? 0)
                #expect(spread < column, "with “\(cell)”, pipe \(index) is \(spread)pt apart across rows — more than a column (\(column)pt)")
            }
        }
    }

    /// **Help says what a table edit changes, as the code does it** (TBL-14, TBL-12). It promised a
    /// hand-typed table "changes only in the row or column you asked for, so a synced file shows
    /// just that line" — a column edit changes a cell on every row, and a hand-typed table that
    /// lined up was rewritten whole — and that Format Table's pipes "line up", which emoji and CJK
    /// do only nearly. Read from source: `MacApp/` is in no package, so nothing else reads it here.
    @Test func helpSaysWhatATableEditChanges() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let help = try #require(try? String(contentsOf: root.appendingPathComponent("MacApp/HelpBook.swift"), encoding: .utf8),
                                "cannot read MacApp/HelpBook.swift — this check would be vacuous")
        #expect(help.contains("In the Table submenu, Insert Table"), "the Table paragraph moved — this check reads the wrong text")
        #expect(!help.contains("so a synced file shows just that line"), "Help still promises a one-line change for a column edit")
        #expect(help.contains("a new row is one new line, and adding or deleting a column changes just that cell on each row"))
        #expect(help.contains("A table written the way Format Table writes it"), "Help does not say which tables stay lined up")
        #expect(help.contains("only nearly, in cells holding emoji or Chinese, Japanese or Korean text"))
        // And the code does what that says: a column added to a hand-typed table changes each row
        // by one cell, every row still there.
        let edit = try #require(MarkdownTables.apply(.addColumnRight, to: Self.ragged, selection: NSRange(location: 1, length: 0)))
        let before = Self.ragged.components(separatedBy: "\n"), after = edit.text.components(separatedBy: "\n")
        #expect(after.count == before.count && zip(before, after).allSatisfy { MarkdownTables.cells($1).count == MarkdownTables.cells($0).count + 1 })
    }

    // MARK: Through the Markup verbs

    /// The verbs reach these functions through `MarkdownEdits.apply`, and the bar's state carries
    /// the same availability the context menu enables by.
    @Test func theMarkupVerbsAndTheBarReadTheSameTables() {
        let one = (Self.simple as NSString).range(of: "1").location
        let selection = NSRange(location: one, length: 0)
        for op in TableVerb.allCases {
            #expect(MarkdownEdits.apply(.table(op), to: Self.simple, selection: selection)
                    == MarkdownTables.apply(op, to: Self.simple, selection: selection), "\(op.title) is wired elsewhere")
            #expect(!MarkdownEdits.isApplied(.table(op), in: Self.simple, selection: selection), "\(op.title) lights as a toggle")
        }
        #expect(MarkupFormatState.of(Self.simple, selection: selection).tables
                == MarkdownTables.available(in: Self.simple as NSString, selection: selection))
        #expect(MarkupFormatState.of(Self.simple, selection: selection).isInTable)
        // The bar's Table menu enables exactly what is available.
        let outside = MarkupFormatState(lit: [], heading: .body, tables: [.insert])
        #expect(EditorFormatBar.isOffered(.table(.insert), in: outside))
        #expect(!EditorFormatBar.isOffered(.table(.deleteRow), in: outside), "Delete Row offered outside a table")
        #expect(EditorFormatBar.isOffered(.bold, in: outside))
        // The right-click menu's Table items too.
        let menu = PlainTextEditor.Coordinator.markupMenu(target: nil, action: #selector(NSText.copy(_:)), tables: [.insert])
        let table = menu.items.first { $0.title == MarkupVerb.tableMenuTitle }?.submenu
        #expect(table?.items.filter { !$0.isSeparatorItem && $0.isEnabled }.map(\.title) == ["Insert Table"],
                "the right-click Table menu enables \(table?.items.filter { $0.isEnabled }.map(\.title) ?? [])")
        #expect(!MarkupFormatState.of("plain", selection: NSRange(location: 1, length: 0)).isInTable)
    }

    /// **Make Table from Selection says WHY it did nothing** (TBL-13). It logged "no tabs or commas"
    /// for every refusal — a caret on `a,b` with nothing selected, and a selection ending in a
    /// table, read as if the lines held neither.
    @Test func makeTableFromSelectionSaysWhyItDidNothing() async {
        let csv = "a,b\nc,d" as NSString
        let into = "x,y\n| a | b |\n| - | - |\n| 1 | 2 |" as NSString
        let holding = "x,y\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\nz,w" as NSString
        let prose = "just words\nmore" as NSString
        #expect(MarkdownTables.refusal(.fromSelection, in: csv, selection: NSRange(location: 1, length: 0))
                == "nothing is selected — select the lines to make into a table")
        #expect(MarkdownTables.refusal(.fromSelection, in: into, selection: NSRange(location: 0, length: 9))
                == "the selection starts or ends in a table")
        #expect(MarkdownTables.refusal(.fromSelection, in: holding, selection: NSRange(location: 0, length: holding.length))
                == "the selection holds a table")
        #expect(MarkdownTables.refusal(.fromSelection, in: prose, selection: NSRange(location: 0, length: prose.length))
                == TableVerb.fromSelection.refusal)
        #expect(MarkdownTables.refusal(.deleteRow, in: csv, selection: NSRange(location: 1, length: 0)) == TableVerb.deleteRow.refusal)

        // Through the menu bar's door, into the log.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scroll.identifier = EditorDocumentSurface.identifier
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! NSTextView
        view.string = csv as String
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 1, length: 0))
        let log = LogCapture()
        #expect(EditorDocumentSurface.applyMarkup(.table(.fromSelection), in: window))
        #expect(await log.holds(containing: "Markup ▸ Make Table from Selection did nothing: nothing is selected — select the lines"),
                "the log did not say nothing was selected")
    }

    /// **One selection's table questions are read together** (TBL-19), and answer as each asked
    /// apart would: the items that apply, whether the selection touches a table, and whether its
    /// paragraph runs into one (outside a table — inside, every verb that would swallow one is
    /// refused already).
    @Test func readingASelectionOnceAnswersAsTheQuestionsAskedApart() {
        let texts = [Self.simple, Self.ragged, "Intro\n| a | b |\n| - | - |\n| 1 | 2 |",
                     "x,y\n\n| a | b |\n| - | - |\n| 1 | 2 |\nnext\n\nz,w", "> | a | bb |\n> | - | - |\n> | 1 | 2 |"]
        for text in texts {
            let ns = text as NSString
            for start in stride(from: 0, through: ns.length, by: 3) {
                for length in [0, 4, ns.length - start] where start + length <= ns.length {
                    let selection = NSRange(location: start, length: length)
                    let read = MarkdownTables.reading(ns, selection)
                    let touches = MarkdownTables.touches(ns, selection)
                    #expect(read.touches == touches, "touches differs in “\(text)” over \(selection)")
                    #expect(read.abuts == (!touches && MarkdownTables.abuts(ns, selection)), "abuts differs in “\(text)” over \(selection)")
                }
            }
        }
    }

    /// **…and cost one parse where they cost two or three** (TBL-19). Each answer that finds a table
    /// parses the note down to it; asked apart, the format bar's state and a right-click at the end
    /// of a long note paid that once per question. Counted, not timed: a timing ratio passed and
    /// failed the same mutation on a loaded machine.
    @Test func readingASelectionParsesTheNoteOnce() {
        let text = "Prose.\n\n| a | b |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |\n\nMore prose."
        let ns = text as NSString
        func parses(_ body: () -> Void) -> Int {
            let count = MarkdownSourceContext.ParseCount()
            MarkdownSourceContext.$tableParses.withValue(count) { body() }
            return count.count
        }
        let caret = NSRange(location: ns.range(of: "1").location, length: 0)
        #expect(parses { _ = MarkdownTables.reading(ns, caret) } == 1, "a caret in a table is read with more than one parse")
        #expect(parses { _ = MarkdownTables.available(in: ns, selection: caret); _ = MarkdownTables.touches(ns, caret) } >= 2,
                "the control: asked apart, it parses for each")
        // Two rows: the end is on another line, and is asked about too.
        let rows = NSRange(location: caret.location, length: ns.range(of: "3").location - caret.location)
        #expect(parses { _ = MarkdownTables.reading(ns, rows) } == 2)
        // Prose with no table near it parses nothing.
        #expect(parses { _ = MarkdownTables.reading(ns, NSRange(location: 2, length: 0)) } == 0)
        #expect(parses { _ = MarkupFormatState.of(text, selection: caret) } == 1, "the format bar's state reads it apart")
    }

    /// **One ⌘Z takes a table edit back**, and a Table item with nothing to do says why.
    @Test func aTableEditIsOneUndoAndANoOpSaysWhy() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scroll.identifier = EditorDocumentSurface.identifier
        window.contentView?.addSubview(scroll)
        let view = scroll.documentView as! NSTextView
        view.allowsUndo = true
        view.string = Self.ragged
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (Self.ragged as NSString).range(of: "1").location, length: 0))
        #expect(EditorDocumentSurface.applyMarkup(.table(.addRowBelow), in: window))
        #expect(view.string == "|a|bb|\n|-|-|\n|1|2|\n|  |  |\n|3|4|")
        view.undoManager?.undo()
        #expect(view.string == Self.ragged, "one ⌘Z left “\(view.string)”")

        let log = LogCapture()
        view.string = "plain words"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(EditorDocumentSurface.applyMarkup(.table(.deleteRow), in: window))
        #expect(view.string == "plain words")
        #expect(await log.holds(containing: "Markup ▸ Delete Row did nothing: the caret is not in a table's body"),
                "a Table item with nothing to do said nothing")

        // TE76: a verb that would take the table's lines out of it, chosen from the menu bar —
        // which cannot grey it — leaves the table alone and says why.
        view.string = Self.ragged
        view.setSelectedRange(NSRange(location: (Self.ragged as NSString).range(of: "3").location, length: 0))
        #expect(EditorDocumentSurface.applyMarkup(.bulletList, in: window))
        #expect(view.string == Self.ragged, "Bulleted List on a table row left “\(view.string)”")
        #expect(await log.holds(containing: "Markup ▸ Bulleted List did nothing: the selection is in a table"),
                "a verb refused in a table said nothing")
    }
}
