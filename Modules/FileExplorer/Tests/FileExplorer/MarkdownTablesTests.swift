import Testing
import AppKit
@testable import FileExplorer
import EventsTestSupport

/// The Table menu's edits (TE65, TE66): which table the caret is in, inserting and converting,
/// rows and columns — keeping a table's style — and Tidy.
@MainActor
@Suite(.serialized) struct MarkdownTablesTests {

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
        // One-letter cells put every pipe in the same column: that table IS lined up, and is re-padded.
        #expect(MarkdownTables.isAligned(source: "|a|b|\n|-|-|\n|1|2|", table: NSRange(location: 0, length: 17)))
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

    /// Every edit, on every cell of several tables, leaves a table — one row or column more or
    /// fewer, as it said — and lands the caret in it; and the ones refused are exactly those
    /// ``MarkdownTables/available(in:selection:)`` leaves out.
    @Test func everyEditLeavesATableAndAvailabilityMatchesWhatApplies() throws {
        let tables = [Self.simple, Self.aligned, Self.ragged, "a | b\n--- | ---\n1 | 2", "| solo |\n| --- |\n| x |",
                      "  | in | list |\n  | -- | -- |\n  | 1 | 2 |", "| a | b |\r\n| - | - |\r\n| 1 | 2 |",
                      "| solo |\n| ---- |\n| x    |",
                      "before\n\n| a | b |\n| :- | -: |\n| 寿司 | 2 |\n\nafter"]
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
                    let columns = table.columns - before.columns
                    let expected: (Int, Int) = switch op {
                    case .addRowAbove, .addRowBelow: (1, 0)
                    case .deleteRow: (-1, 0)
                    case .addColumnLeft, .addColumnRight: (0, 1)
                    case .deleteColumn: (0, -1)
                    default: (0, 0)
                    }
                    #expect((rows, columns) == expected, "\(op.title) in “\(text)” at \(location) changed rows by \(rows), columns by \(columns)")
                    // The text around the table is never touched.
                    #expect(edit.text.hasPrefix(ns.substring(to: at.table.location))
                            && edit.text.hasSuffix(ns.substring(from: NSMaxRange(at.table))), "\(op.title) touched text outside the table")
                    // A CRLF table stays CRLF.
                    if text.contains("\r\n") {
                        #expect(!edit.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "\(op.title) wrote a bare \\n into a CRLF table")
                    }
                    // An indented table stays indented.
                    if text.hasPrefix("  |") {
                        #expect(edit.text.components(separatedBy: "\n").allSatisfy { $0.hasPrefix("  ") }, "\(op.title) lost the indent: “\(edit.text)”")
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
                == "| 寿司 | x   |\n| ---- | --- |")
        // Tidy is a fixed point.
        #expect(MarkdownTables.tidy(source: tidy.text, table: range)?.text == tidy.text)
        // From the menu, the caret keeps its place in its cell.
        let caret = ns.range(of: "10").location + 1
        let fromMenu = try #require(MarkdownTables.apply(.tidy, to: messy, selection: NSRange(location: caret, length: 0)))
        #expect((fromMenu.text as NSString).substring(with: NSRange(location: fromMenu.selection.location - 1, length: 2)) == "10")
        // An indented table keeps its indent.
        let indented = "  |a|b|\n  |-|-|\n  |1|2|"
        let kept = try #require(MarkdownTables.tidy(source: indented, table: NSRange(location: 0, length: (indented as NSString).length)))
        #expect(kept.text == "  | a   | b   |\n  | --- | --- |\n  | 1   | 2   |", "“\(kept.text)”")
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
        let table = menu.items.last?.submenu
        #expect(table?.items.filter { !$0.isSeparatorItem && $0.isEnabled }.map(\.title) == ["Insert Table"],
                "the right-click Table menu enables \(table?.items.filter { $0.isEnabled }.map(\.title) ?? [])")
        #expect(!MarkupFormatState.of("plain", selection: NSRange(location: 1, length: 0)).isInTable)
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
    }
}
