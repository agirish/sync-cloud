import Foundation

/// **Markdown tables as text** (TE65, TE66): which table a position is in, and the edits the Table
/// menu makes — insert one, make one from tab- or comma-separated lines, add and delete rows and
/// columns, and tidy one so its pipes line up.
///
/// **Pure functions over the buffer, like the rest of `MarkdownEdits`**, answering a ``MarkupEdit``
/// (the new text and where the caret goes) or `nil` when the edit does not apply. The verbs reach
/// them through ``MarkdownEdits/apply(_:to:selection:)`` and so through `PlainTextEditor.apply`,
/// the one path every door into the Markup verbs shares — one edit, one ⌘Z.
///
/// **Two ways in.** The menus and the format bar have a selection, and go through
/// ``apply(_:to:selection:)``. Editable Preview (TE67) has a table and a cell instead — it knows
/// both from its own projection — and calls ``edit(_:source:table:row:column:offsetInCell:)``,
/// ``tidy(source:table:)`` and ``isAligned(source:table:)`` directly, with no selection at all.
///
/// **What counts as a table** is GitHub's: a header row, a delimiter row of dashes (colons for
/// alignment) with as many cells as the header, then body rows; every row holds an unescaped `|`,
/// and the table ends at the first line that does not. Not inside a fenced code block.
///
/// **An edit keeps the table's style** (decided 2026-10-04). A table whose pipes already line up is
/// re-padded after a row or column changes, so it stays lined up. A ragged, hand-typed one gets
/// only the row or column the edit is about — every other line is left byte for byte, so a synced
/// file shows a one-line change. Format Table (`.tidy`) lines a table up when asked, and never loses a cell: a
/// row with more cells than the header widens the table rather than dropping the extra.
enum MarkdownTables {

    enum Alignment: Equatable, Sendable { case none, left, center, right }

    /// Where a position sits in a table.
    struct Location: Equatable, Sendable {
        /// The table's lines, from the header's first character to the last row's last — no line
        /// break at either end.
        var table: NSRange
        /// The cell row: 0 is the header, 1… the body rows. The delimiter row is not a cell row; a
        /// position on it answers row 0 with ``onDelimiter`` set.
        var row: Int
        /// The cell, 0-based, clamped to the table's columns.
        var column: Int
        var onDelimiter: Bool
        /// How far into its cell's text the position is, in UTF-16 — what Tidy keeps.
        var offsetInCell: Int
    }

    /// A table read off its lines.
    struct Table: Equatable, Sendable {
        /// What every row starts with — a table indented under a list item stays indented.
        var indent: String
        /// The cell rows, header first, each as wide as ``alignments``.
        var rows: [[String]]
        var alignments: [Alignment]
        /// `"\n"`, or `"\r\n"` when every line of the table ended with one.
        var lineBreak: String

        var columns: Int { alignments.count }
    }

    // MARK: - Reading

    /// The text of a row's cells, trimmed: outer pipes dropped, split at every pipe not escaped
    /// with a backslash. Escapes are kept as written.
    static func cells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") && !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in body {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == "|" { cells.append(current); current = ""; continue }
            current.append(ch)
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func hasUnescapedPipe(_ line: String) -> Bool {
        var escaped = false
        for ch in line {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { return true }
        }
        return false
    }

    /// The delimiter row's alignments, or `nil` when `line` is not one.
    static func alignments(_ line: String) -> [Alignment]? {
        guard hasUnescapedPipe(line) else { return nil }
        var result: [Alignment] = []
        for cell in cells(line) {
            guard cell.contains("-"), cell.allSatisfy({ $0 == "-" || $0 == ":" }),
                  !cell.dropFirst().dropLast().contains(":") else { return nil }
            switch (cell.hasPrefix(":"), cell.count > 1 && cell.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.left)
            case (false, true): result.append(.right)
            case (false, false): result.append(.none)
            }
        }
        return result
    }

    /// The lines of `range`, with any `\r` taken off their ends, and the break between them.
    static func lines(of ns: NSString, in range: NSRange) -> (lines: [String], lineBreak: String) {
        let raw = ns.substring(with: range).components(separatedBy: "\n")
        let crlf = raw.count > 1 && raw.dropLast().allSatisfy { $0.hasSuffix("\r") }
        return (raw.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }, crlf ? "\r\n" : "\n")
    }

    /// Reads the table whose lines are exactly `range`, or `nil` when they are not one.
    static func table(in ns: NSString, range: NSRange) -> Table? {
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return nil }
        let (lines, lineBreak) = lines(of: ns, in: range)
        guard lines.count >= 2, let aligns = alignments(lines[1]),
              cells(lines[0]).count == aligns.count,
              lines.allSatisfy(hasUnescapedPipe) else { return nil }
        var rows = [cells(lines[0])] + lines.dropFirst(2).map(cells)
        let columns = max(aligns.count, rows.map(\.count).max() ?? 0)
        rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
        return Table(indent: String(lines[0].prefix { $0 == " " || $0 == "\t" }), rows: rows,
                     alignments: aligns + Array(repeating: .none, count: columns - aligns.count),
                     lineBreak: lineBreak)
    }

    /// The line holding `location`, without its line break.
    static func contentRange(of ns: NSString, lineAt location: Int) -> NSRange {
        let full = ns.lineRange(for: NSRange(location: min(max(location, 0), ns.length), length: 0))
        var end = NSMaxRange(full)
        while end > full.location, ns.character(at: end - 1) == 0x0A || ns.character(at: end - 1) == 0x0D {
            end -= 1
        }
        return NSRange(location: full.location, length: end - full.location)
    }

    /// Whether the line holding `location` is inside a fenced code block — a ``` or ~~~ fence
    /// opened on a line above it and not yet closed. Walks from the top, so it is asked only about a
    /// line that already looks like a table row.
    static func isInFence(_ ns: NSString, at location: Int) -> Bool {
        let target = ns.lineRange(for: NSRange(location: min(max(location, 0), ns.length), length: 0)).location
        var open: (char: Character, count: Int)?
        var index = 0
        while index < target {
            let full = ns.lineRange(for: NSRange(location: index, length: 0))
            if let fence = fence(ns.substring(with: contentRange(of: ns, lineAt: index))) {
                if let current = open {
                    if fence.char == current.char && fence.count >= current.count { open = nil }
                } else {
                    open = fence
                }
            }
            guard NSMaxRange(full) > index else { break }
            index = NSMaxRange(full)
        }
        return open != nil
    }

    /// A fence line's character and length: up to three spaces, then three or more ` or ~.
    private static func fence(_ line: String) -> (char: Character, count: Int)? {
        let lead = line.prefix { $0 == " " }.count
        guard lead <= 3 else { return nil }
        let rest = line.dropFirst(lead)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let run = rest.prefix { $0 == first }.count
        return run >= 3 ? (first, run) : nil
    }

    /// **The table `location` is in**, with its row and column — or `nil`.
    static func locate(in ns: NSString, at location: Int) -> Location? {
        guard location >= 0, location <= ns.length else { return nil }
        let here = contentRange(of: ns, lineAt: location)
        guard hasUnescapedPipe(ns.substring(with: here)) else { return nil }
        // The run of lines holding pipes, around this one.
        var block = [here]
        while let first = block.first, first.location > 0 {
            let previous = contentRange(of: ns, lineAt: first.location - 1)
            guard previous.location < first.location,
                  hasUnescapedPipe(ns.substring(with: previous)) else { break }
            block.insert(previous, at: 0)
        }
        while let last = block.last {
            let after = NSMaxRange(ns.lineRange(for: NSRange(location: last.location, length: 0)))
            guard after > NSMaxRange(last), after < ns.length else { break }
            let next = contentRange(of: ns, lineAt: after)
            guard hasUnescapedPipe(ns.substring(with: next)) else { break }
            block.append(next)
        }
        // The header is the line before the first delimiter row whose cells it matches.
        let texts = block.map { ns.substring(with: $0) }
        guard let delimiter = texts.indices.dropFirst().first(where: { index in
            alignments(texts[index]).map { cells(texts[index - 1]).count == $0.count } ?? false
        }) else { return nil }
        let header = delimiter - 1
        guard let lineIndex = block.firstIndex(where: { $0.location == here.location }),
              lineIndex >= header else { return nil }
        let start = block[header].location
        let range = NSRange(location: start, length: NSMaxRange(block[block.count - 1]) - start)
        guard !isInFence(ns, at: start), let table = table(in: ns, range: range) else { return nil }

        // Which cell: the last one opened before the position.
        let starts = cellStarts(ns.substring(with: here))
        let offset = location - here.location
        var column = 0
        for (index, start) in starts.enumerated() where start.pipe < offset { column = index }
        column = min(column, table.columns - 1)
        let content = starts.indices.contains(column) ? starts[column].content : 0
        return Location(table: range, row: lineIndex <= delimiter ? 0 : lineIndex - delimiter, column: column,
                        onDelimiter: lineIndex == delimiter, offsetInCell: max(0, offset - content))
    }

    /// For each pipe-opened cell of `line`, in UTF-16: where the pipe that opens it is (`-1` for a
    /// first cell with no leading pipe) and where its text starts after the spaces. A trailing pipe
    /// opens one more, empty, entry — callers count cells with ``cells(_:)``.
    static func cellStarts(_ line: String) -> [(pipe: Int, content: Int)] {
        let units = Array(line.utf16)
        let pipe = UInt16(UInt8(ascii: "|")), backslash = UInt16(UInt8(ascii: "\\"))
        let space = UInt16(UInt8(ascii: " ")), tab = UInt16(UInt8(ascii: "\t"))
        var index = 0
        while index < units.count, units[index] == space || units[index] == tab { index += 1 }
        var opens: [Int] = index < units.count && units[index] == pipe ? [] : [index - 1]
        var escaped = false
        for i in index..<units.count {
            if escaped { escaped = false; continue }
            if units[i] == backslash { escaped = true; continue }
            if units[i] == pipe { opens.append(i) }
        }
        return opens.map { open in
            var content = open + 1
            while content < units.count, units[content] == space { content += 1 }
            return (open, content)
        }
    }

    // MARK: - Lined up or not

    /// How many columns of a monospaced font `text` takes: two for the wide East Asian scripts and
    /// for emoji, one for everything else — so a table holding 寿司 still lines up.
    static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { total, character in
            let scalars = character.unicodeScalars
            guard let first = scalars.first else { return total }
            return total + (isWide(first) || scalars.contains { $0.properties.isEmojiPresentation } ? 2 : 1)
        }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    /// The display columns the unescaped pipes of `line` stand at.
    static func pipeColumns(_ line: String) -> [Int] {
        var columns: [Int] = []
        var width = 0
        var escaped = false
        for ch in line {
            if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "|" { columns.append(width) }
            width += displayWidth(String(ch))
        }
        return columns
    }

    /// **Whether the table at `range` is lined up** — every row's pipes at the same columns — which
    /// decides whether an edit re-pads it or touches only the row or column it is about.
    static func isAligned(source: String, table range: NSRange) -> Bool {
        let ns = source as NSString
        guard table(in: ns, range: range) != nil else { return false }
        let columns = lines(of: ns, in: range).lines.map(pipeColumns)
        return columns.dropFirst().allSatisfy { $0 == columns[0] }
    }

    // MARK: - Writing a whole table

    /// **The table, tidied**: each column as wide as its widest cell (three at least), a space each
    /// side of every cell, the delimiter row keeping its colons. And where each cell row's cells'
    /// text starts, in UTF-16 from the table's start.
    static func render(_ table: Table) -> (text: String, cellStarts: [[Int]]) {
        let widths = (0..<table.columns).map { column in
            max(3, table.rows.map { displayWidth($0[column]) }.max() ?? 0)
        }
        var lines: [String] = []
        var starts: [[Int]] = []
        var offset = 0
        let breakLength = (table.lineBreak as NSString).length
        for (index, cells) in table.rows.enumerated() {
            var line = table.indent + "|"
            var rowStarts: [Int] = []
            for (column, cell) in cells.enumerated() {
                line += " "
                rowStarts.append(offset + (line as NSString).length)
                line += cell + String(repeating: " ", count: max(0, widths[column] - displayWidth(cell))) + " |"
            }
            starts.append(rowStarts)
            lines.append(line)
            offset += (line as NSString).length + breakLength
            if index == 0 {
                let delimiter = table.indent + "|" + zip(table.alignments, widths).map { alignment, width in
                    switch alignment {
                    case .none: return " " + String(repeating: "-", count: width) + " |"
                    case .left: return " :" + String(repeating: "-", count: width - 1) + " |"
                    case .right: return " " + String(repeating: "-", count: width - 1) + ": |"
                    case .center: return " :" + String(repeating: "-", count: width - 2) + ": |"
                    }
                }.joined()
                lines.append(delimiter)
                offset += (delimiter as NSString).length + breakLength
            }
        }
        return (lines.joined(separator: table.lineBreak), starts)
    }

    /// `table`, tidied, written over `range` in `source`, with the caret in cell (`row`,
    /// `column`), `offset` into its text.
    private static func write(_ table: Table, over range: NSRange, in source: String,
                              row: Int, column: Int, offset: Int = 0) -> MarkupEdit {
        let (text, starts) = render(table)
        let r = min(max(row, 0), table.rows.count - 1)
        let c = min(max(column, 0), table.columns - 1)
        let caret = range.location + starts[r][c] + min(max(offset, 0), (table.rows[r][c] as NSString).length)
        return MarkupEdit(text: (source as NSString).replacingCharacters(in: range, with: text),
                          selection: NSRange(location: caret, length: 0))
    }

    // MARK: - Touching only what the edit is about

    /// A row of `columns` empty cells: pipes both ends, whatever the table's rows do, because a
    /// row of empty cells without them would not be a row at all.
    private static func emptyRow(_ table: Table) -> String {
        table.indent + "|" + Array(repeating: "  ", count: table.columns).joined(separator: "|") + "|"
    }

    /// The UTF-16 offset in `line` just after its last unescaped pipe, when the line ends with one.
    private static func trailingPipeEnd(_ line: String) -> Int? {
        let trimmed = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") else { return nil }
        return (trimmed as NSString).length
    }

    /// `line` with a new, empty cell at `at` — `---` on the delimiter row — and nothing else moved.
    /// A row shorter than `at` is left as it is: its missing cells are already empty.
    static func insertingCell(into line: String, at: Int, delimiter: Bool) -> String {
        let ns = line as NSString
        let count = cells(line).count
        let piece = delimiter ? " --- |" : "  |"
        let starts = cellStarts(line)
        if at < count {
            let open = starts[at].pipe
            if open < 0 {
                // No leading pipe: give the row one, or the new first cell would be read as a border.
                let indent = (line.prefix { $0 == " " || $0 == "\t" } as Substring).utf16.count
                return ns.replacingCharacters(in: NSRange(location: indent, length: 0), with: "|" + piece)
            }
            return ns.replacingCharacters(in: NSRange(location: open + 1, length: 0), with: piece)
        }
        guard at == count else { return line }
        if let end = trailingPipeEnd(line) {
            return ns.replacingCharacters(in: NSRange(location: end, length: 0), with: piece)
        }
        // No trailing pipe: close the last cell first, or the new one would be read as a border.
        let content = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        return content + " |" + piece
    }

    /// `line` without its cell at `at`, and nothing else moved. A row whose last pipe the removal
    /// takes keeps one, so it is still a row.
    static func removingCell(from line: String, at: Int) -> String {
        let ns = line as NSString
        guard at < cells(line).count else { return line }
        let starts = cellStarts(line)
        let open = starts[at].pipe
        let indent = (line.prefix { $0 == " " || $0 == "\t" } as Substring).utf16.count
        let result: String
        if starts.indices.contains(at + 1) {
            // From just after the pipe that opens the cell through the pipe that closes it — or,
            // with no leading pipe, from the row's first character.
            let from = open < 0 ? indent : open + 1
            result = ns.replacingCharacters(in: NSRange(location: from, length: starts[at + 1].pipe + 1 - from), with: "")
        } else {
            // The last cell, with no trailing pipe: from the pipe that opens it to the end.
            let from = max(open, indent)
            result = ns.replacingCharacters(in: NSRange(location: from, length: ns.length - from), with: "")
        }
        guard !hasUnescapedPipe(result) else { return result }
        let text = result.trimmingCharacters(in: .whitespaces)
        return String(line.prefix(indent)) + "| " + text + (text.isEmpty ? "" : " ") + "|"
    }

    /// Where the caret goes in the cell at `column` of `lines[line]`: its text's start — or, in an
    /// empty cell, one space in rather than against its closing pipe.
    private static func caret(at range: NSRange, lines: [String], lineBreak: String, line: Int, column: Int) -> Int {
        var offset = range.location
        for index in 0..<line { offset += (lines[index] as NSString).length + (lineBreak as NSString).length }
        let starts = cellStarts(lines[line])
        guard !starts.isEmpty else { return offset }
        let c = min(max(column, 0), starts.count - 1)
        var content = starts[c].content
        if starts.indices.contains(c + 1), content >= starts[c + 1].pipe {
            content = min(starts[c].pipe + 2, starts[c + 1].pipe)
        }
        return offset + max(0, content)
    }

    /// The edit made to a ragged table: the row or column alone. `nil` where ``edit`` refuses.
    private static func editKeepingStyle(_ op: TableVerb, _ table: Table, source: String, range: NSRange,
                                         row: Int, column: Int) -> MarkupEdit? {
        var (lines, lineBreak) = lines(of: source as NSString, in: range)
        // Cell row `r` is line 0 for the header, line r + 1 for the body (the delimiter is line 1).
        func line(ofRow r: Int) -> Int { r == 0 ? 0 : r + 1 }
        let caretLine: Int
        let caretColumn: Int
        switch op {
        case .addRowAbove:
            guard row > 0 else { return nil }
            lines.insert(emptyRow(table), at: line(ofRow: row))
            (caretLine, caretColumn) = (line(ofRow: row), column)
        case .addRowBelow:
            let at = row == 0 ? 2 : line(ofRow: row) + 1
            lines.insert(emptyRow(table), at: at)
            (caretLine, caretColumn) = (at, column)
        case .deleteRow:
            guard row > 0 else { return nil }
            lines.remove(at: line(ofRow: row))
            let next = min(line(ofRow: row), lines.count - 1)
            (caretLine, caretColumn) = (next == 1 ? 0 : next, column)
        case .addColumnLeft, .addColumnRight:
            let at = op == .addColumnLeft ? column : column + 1
            lines = lines.enumerated().map { insertingCell(into: $1, at: at, delimiter: $0 == 1) }
            (caretLine, caretColumn) = (line(ofRow: row), at)
        case .deleteColumn:
            guard table.columns > 1 else { return nil }
            lines = lines.map { removingCell(from: $0, at: column) }
            (caretLine, caretColumn) = (line(ofRow: row), min(column, table.columns - 2))
        case .tidy, .insert, .fromSelection:
            return nil
        }
        let text = lines.joined(separator: lineBreak)
        let newRange = NSRange(location: range.location, length: (text as NSString).length)
        return MarkupEdit(text: (source as NSString).replacingCharacters(in: range, with: text),
                          selection: NSRange(location: caret(at: newRange, lines: lines, lineBreak: lineBreak,
                                                             line: caretLine, column: caretColumn), length: 0))
    }

    // MARK: - The edits, by table and cell

    /// **One Table menu edit on the table at `range`, at cell (`row`, `column`)** — the entry point
    /// that needs no selection (rows: 0 the header, 1… the body). A lined-up table comes back lined
    /// up; a ragged one changes only in the row or column the edit is about (see the type's notes).
    ///
    /// `nil` where the edit does not apply: a row above the header, deleting the header or the only
    /// column, a cell outside the table, a range that is not a table — and Insert and Make Table
    /// from Selection, which are not edits OF a table.
    static func edit(_ op: TableVerb, source: String, table range: NSRange,
                     row: Int, column: Int, offsetInCell: Int = 0) -> MarkupEdit? {
        guard var table = table(in: source as NSString, range: range),
              table.rows.indices.contains(row), (0..<table.columns).contains(column) else { return nil }
        if op == .tidy { return write(table, over: range, in: source, row: row, column: column, offset: offsetInCell) }
        guard isAligned(source: source, table: range) else {
            return editKeepingStyle(op, table, source: source, range: range, row: row, column: column)
        }
        switch op {
        case .addRowAbove:
            guard row > 0 else { return nil }
            table.rows.insert(Array(repeating: "", count: table.columns), at: row)
            return write(table, over: range, in: source, row: row, column: column)
        case .addRowBelow:
            table.rows.insert(Array(repeating: "", count: table.columns), at: row + 1)
            return write(table, over: range, in: source, row: row + 1, column: column)
        case .addColumnLeft, .addColumnRight:
            let at = op == .addColumnLeft ? column : column + 1
            for index in table.rows.indices { table.rows[index].insert("", at: at) }
            table.alignments.insert(.none, at: at)
            return write(table, over: range, in: source, row: row, column: at)
        case .deleteRow:
            guard row > 0 else { return nil }
            table.rows.remove(at: row)
            return write(table, over: range, in: source, row: min(row, table.rows.count - 1), column: column)
        case .deleteColumn:
            guard table.columns > 1 else { return nil }
            for index in table.rows.indices { table.rows[index].remove(at: column) }
            table.alignments.remove(at: column)
            return write(table, over: range, in: source, row: row, column: min(column, table.columns - 1))
        case .tidy, .insert, .fromSelection:
            return nil
        }
    }

    /// **Tidy on its own**: the table at `range` padded so its pipes line up, the caret at the start
    /// of the header's first cell — or `nil` when `range` is not a table. For editable Preview,
    /// which does not re-pad as you type (TE67, decision T) and offers this instead.
    static func tidy(source: String, table range: NSRange) -> MarkupEdit? {
        edit(.tidy, source: source, table: range, row: 0, column: 0)
    }

    // MARK: - The edits, by selection

    /// **A Table menu item, applied to a selection** — what the menus and the format bar call.
    static func apply(_ op: TableVerb, to text: String, selection: NSRange) -> MarkupEdit? {
        let ns = text as NSString
        guard selection.location != NSNotFound, selection.location >= 0,
              NSMaxRange(selection) <= ns.length else { return nil }
        switch op {
        case .insert: return insert(text, selection)
        case .fromSelection: return fromSelection(text, selection)
        default:
            guard let at = locate(in: ns, at: selection.location) else { return nil }
            return edit(op, source: text, table: at.table, row: at.row, column: at.column,
                        offsetInCell: at.offsetInCell)
        }
    }

    /// Which Table menu items apply at `selection` — what the bar's Table menu and the text's
    /// right-click menu enable, exactly the ones ``apply(_:to:selection:)`` would not refuse.
    /// Inside a table: the row and column edits and Tidy, but no row above the header, no deleting
    /// it, and no deleting the only column. Outside: Insert Table, and Make Table from Selection
    /// over lines holding tabs or commas.
    static func available(in ns: NSString, selection: NSRange) -> Set<TableVerb> {
        guard selection.location != NSNotFound, selection.location >= 0,
              NSMaxRange(selection) <= ns.length else { return [] }
        if let at = locate(in: ns, at: selection.location) {
            var verbs: Set<TableVerb> = [.addRowBelow, .addColumnLeft, .addColumnRight, .tidy]
            if at.row > 0 { verbs.formUnion([.addRowAbove, .deleteRow]) }
            if (table(in: ns, range: at.table)?.columns ?? 0) > 1 { verbs.insert(.deleteColumn) }
            return verbs
        }
        var verbs: Set<TableVerb> = []
        if locate(in: ns, at: NSMaxRange(selection)) == nil { verbs.insert(.insert) }
        if conversion(ns, selection) != nil { verbs.insert(.fromSelection) }
        return verbs
    }

    /// The placeholder words a new table's header carries. The first is selected after Insert
    /// Table, so typing replaces it.
    static let placeholderHeader = ["Column 1", "Column 2", "Column 3"]

    /// **Insert Table**: three columns, the header and two empty rows, after the line the selection
    /// ends on — or on that line, when it is blank — with a blank line either side, so it is read as
    /// a table and not as part of a paragraph. Nothing selected is replaced. Refused in a table.
    static func insert(_ text: String, _ selection: NSRange) -> MarkupEdit? {
        let ns = text as NSString
        guard locate(in: ns, at: selection.location) == nil,
              locate(in: ns, at: NSMaxRange(selection)) == nil else { return nil }
        let line = contentRange(of: ns, lineAt: NSMaxRange(selection))
        let lineBreak = lineBreak(of: ns, after: line)
        let table = Table(indent: "", rows: [placeholderHeader, ["", "", ""], ["", "", ""]],
                          alignments: [.none, .none, .none], lineBreak: lineBreak)
        let rendered = render(table).text
        let replace: NSRange
        let lead: String
        if isBlank(ns, line) {
            replace = line
            let hasWrittenLineAbove = line.location > 0 && !isBlank(ns, contentRange(of: ns, lineAt: line.location - 1))
            lead = hasWrittenLineAbove ? lineBreak : ""
        } else {
            replace = NSRange(location: NSMaxRange(line), length: 0)
            lead = lineBreak + lineBreak
        }
        let trail = nextLine(ns, after: line).map { isBlank(ns, $0) ? "" : lineBreak } ?? ""
        let header = replace.location + (lead as NSString).length + 2  // after "| "
        return MarkupEdit(text: ns.replacingCharacters(in: replace, with: lead + rendered + trail),
                          selection: NSRange(location: header, length: (placeholderHeader[0] as NSString).length))
    }

    /// The selection's lines, whole, and whether they split on tabs (`true`) or commas — or `nil`
    /// when no written line holds either, or the lines start or end in a table. The cheap half of
    /// ``convertibleRows(_:_:)``: what the Table menu's enabling asks on every caret move, without
    /// reading a cell.
    static func conversion(_ ns: NSString, _ selection: NSRange) -> (range: NSRange, lines: [String], tabs: Bool)? {
        guard selection.length > 0, NSMaxRange(selection) <= ns.length else { return nil }
        var end = NSMaxRange(selection)
        // A selection ending just after a line break does not take the line after it.
        if end > selection.location, ns.character(at: end - 1) == 0x0A { end -= 1 }
        let first = contentRange(of: ns, lineAt: selection.location)
        let last = contentRange(of: ns, lineAt: max(end, selection.location))
        let range = NSRange(location: first.location, length: max(NSMaxRange(last), NSMaxRange(first)) - first.location)
        guard locate(in: ns, at: range.location) == nil, locate(in: ns, at: NSMaxRange(range)) == nil else { return nil }
        let lines = lines(of: ns, in: range).lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.contains(where: { $0.contains("\t") }) { return (range, lines, true) }
        if lines.contains(where: { $0.contains(",") }) { return (range, lines, false) }
        return nil
    }

    /// The selection's lines, whole, split into cells — on tabs when any line has one, else on
    /// commas, reading quoted fields as CSV does — or `nil` (see ``conversion(_:_:)``). Blank lines
    /// are left out; a table cannot hold one.
    static func convertibleRows(_ ns: NSString, _ selection: NSRange) -> (range: NSRange, rows: [[String]])? {
        guard let (range, lines, tabs) = conversion(ns, selection) else { return nil }
        let rows = tabs ? lines.map { $0.components(separatedBy: "\t") } : lines.map(csvFields)
        return (range, rows.map { $0.map(escapedCell) })
    }

    /// One line of CSV: fields split at commas, a quoted field keeping its commas, `""` inside one
    /// standing for a quote.
    static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if quoted {
                if ch == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" { current.append("\""); index += 1 } else { quoted = false }
                } else {
                    current.append(ch)
                }
            } else if ch == "\"", current.trimmingCharacters(in: .whitespaces).isEmpty {
                quoted = true
                current = ""
            } else if ch == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            index += 1
        }
        fields.append(current)
        return fields
    }

    /// A cell's text made safe for a row: trimmed, its pipes escaped.
    static func escapedCell(_ text: String) -> String {
        var result = ""
        var escaped = false
        for ch in text.trimmingCharacters(in: .whitespaces) {
            if escaped { result.append(ch); escaped = false; continue }
            if ch == "\\" { result.append(ch); escaped = true; continue }
            result += ch == "|" ? "\\|" : String(ch)
        }
        return result
    }

    /// **Make Table from Selection**: the selected lines, whole, become a table — the first line its
    /// header — lined up, with a blank line either side, and the caret after it.
    static func fromSelection(_ text: String, _ selection: NSRange) -> MarkupEdit? {
        let ns = text as NSString
        guard let (range, rows) = convertibleRows(ns, selection) else { return nil }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return nil }
        let lineBreak = lineBreak(of: ns, after: contentRange(of: ns, lineAt: range.location))
        let table = Table(indent: "", rows: rows.map { $0 + Array(repeating: "", count: columns - $0.count) },
                          alignments: Array(repeating: .none, count: columns), lineBreak: lineBreak)
        let rendered = render(table).text
        let hasWrittenLineAbove = range.location > 0 && !isBlank(ns, contentRange(of: ns, lineAt: range.location - 1))
        let lead = hasWrittenLineAbove ? lineBreak : ""
        let trail = nextLine(ns, after: contentRange(of: ns, lineAt: NSMaxRange(range))).map { isBlank(ns, $0) ? "" : lineBreak } ?? ""
        return MarkupEdit(text: ns.replacingCharacters(in: range, with: lead + rendered + trail),
                          selection: NSRange(location: range.location + ((lead + rendered) as NSString).length, length: 0))
    }

    private static func isBlank(_ ns: NSString, _ line: NSRange) -> Bool {
        ns.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The line after `line`, when there is one with a line break before it.
    private static func nextLine(_ ns: NSString, after line: NSRange) -> NSRange? {
        let after = NSMaxRange(ns.lineRange(for: NSRange(location: line.location, length: 0)))
        guard after > NSMaxRange(line), after < ns.length else { return nil }
        return contentRange(of: ns, lineAt: after)
    }

    /// The break that ends `line` — `"\r\n"` when it is one — or `"\n"`.
    private static func lineBreak(of ns: NSString, after line: NSRange) -> String {
        let end = NSMaxRange(line)
        if end + 1 < ns.length, ns.character(at: end) == 0x0D, ns.character(at: end + 1) == 0x0A { return "\r\n" }
        return "\n"
    }
}
