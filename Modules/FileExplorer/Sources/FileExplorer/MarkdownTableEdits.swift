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
/// **What counts as a table is what cmark draws as one** — asked of the preview's own parser
/// (``MarkdownSourceContext/tableLines(at:in:)``): a header row, a delimiter row of dashes (colons
/// for alignment) with as many cells as the header, then body rows, to the first blank line or the
/// first line that starts another block — a list item, a quote, a heading. A body row needs no
/// pipe. Never in a code block, front matter or HTML. The cells are read here.
///
/// **An edit keeps the table's style** (decided 2026-10-04). A table written the way Format Table
/// writes it — pipes lined up, cells padded (``keepsLinedUp(source:table:)``) — is re-padded after
/// a row or column changes, so it stays lined up, a compact delimiter row staying compact. Any other
/// — ragged, compact `|a|b|`, pipe-less — gets only the row or column the edit is about: every
/// other line is left byte for byte, so a synced file shows only that row, or that column's cells.
/// Format Table (`.tidy`) lines a table up when asked, and never loses a cell: a row with more cells
/// than the header widens the table rather than dropping the extra.
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
        /// The cells the header and the delimiter row hold — the columns the table HAS (TBL-1). A
        /// body row may hold more, which cmark does not draw; ``columns`` counts those too, so that
        /// no cell is lost, and so cannot say whether a column is the last one there is.
        var headerColumns: Int
        /// Whether the delimiter row is written without spaces — `|------|:----:|` — which a
        /// re-padded table keeps (TBL-4): each run as wide as its column's padded cells, so the
        /// pipes still line up.
        var compactDelimiter = false

        var columns: Int { alignments.count }
    }

    // MARK: - Reading

    /// What pads a cell: spaces and tabs, and nothing else — GFM trims no other space from one
    /// (TBL-8). `.whitespaces` is every Unicode space, and Format Table deleted a no-break space or
    /// an ideographic space at a cell's edge, which Preview draws.
    static let padding = CharacterSet(charactersIn: " \t")

    /// **What a row starts with before its cells**: its indent, and the `>` of any quote it is in,
    /// with their spaces — `  `, `> `, `>> `, `> > ` (TBL-5). Read past, and written back on every
    /// line an edit writes. A `>` read as the first cell's text hid every quoted table: no Table
    /// capsule, no TE76 guard, and Insert Table split one in two.
    static func linePrefix<S: StringProtocol>(_ line: S) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" || $0 == ">" })
    }

    /// A line's quote markers — through its prefix's last `>`, then one space — or nothing outside
    /// a quote: what Insert Table and Make Table from Selection put before a table they write, so
    /// one made in a quote stays in it. Only the quote: a table written at a paragraph's indent, or
    /// after all of a quoted line's spaces, could land in an indented code block.
    static func quotePrefix<S: StringProtocol>(_ line: S) -> String {
        let prefix = linePrefix(line)
        guard let last = prefix.lastIndex(of: ">") else { return "" }
        return String(prefix[...last]) + " "
    }

    /// The text of a row's cells, trimmed: outer pipes dropped, split at every pipe not escaped
    /// with a backslash. Escapes are kept as written.
    static func cells(_ line: String) -> [String] {
        var body = Substring(line.dropFirst(linePrefix(line).count).trimmingCharacters(in: padding))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if endsInUnescapedPipe(body) { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var previous: Character?
        for ch in body {
            defer { previous = ch }
            if ch == "|", previous != "\\" { cells.append(current); current = ""; continue }
            current.append(ch)
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: padding) }
    }

    /// **Which pipes are escaped is cmark's table scanner's rule** (TBL-15): a pipe right after a
    /// backslash, every time — whatever stands before that backslash. `b\\|` ends in an escaped
    /// pipe to cmark, which reads `|a|b\\|` as two cells, `a` and `b\\|`. The rule here took a
    /// backslash to escape any character, so `\\` escaped itself, the pipe split a third cell off,
    /// and the table cmark draws was not found.
    static func endsInUnescapedPipe<S: StringProtocol>(_ text: S) -> Bool {
        text.last == "|" && text.dropLast().last != "\\"
    }

    static func hasUnescapedPipe(_ line: String) -> Bool {
        var previous: Character?
        for ch in line {
            if ch == "|", previous != "\\" { return true }
            previous = ch
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
        // A body row needs no pipe (TBL-9): GFM carries a table on through any written line that
        // starts no other block, and Preview draws it as a row. A blank line is never one.
        guard lines.count >= 2, let aligns = alignments(lines[1]),
              hasUnescapedPipe(lines[0]), cells(lines[0]).count == aligns.count,
              lines.dropFirst(2).allSatisfy({ !$0.trimmingCharacters(in: padding).isEmpty }) else { return nil }
        var rows = [cells(lines[0])] + lines.dropFirst(2).map(cells)
        let columns = max(aligns.count, rows.map(\.count).max() ?? 0)
        rows = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
        return Table(indent: linePrefix(lines[0]), rows: rows,
                     alignments: aligns + Array(repeating: .none, count: columns - aligns.count),
                     lineBreak: lineBreak, headerColumns: aligns.count,
                     compactDelimiter: !lines[1].dropFirst(linePrefix(lines[1]).count).contains { $0 == " " || $0 == "\t" })
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

    /// **Whether a delimiter row stands at or above `location`'s line — or just under it, for a
    /// header — in the run of written lines holding it**: the cheap question ``locate(in:at:)``
    /// asks before the parser, on every caret move, so a caret in prose costs a walk up its
    /// paragraph and no parse. A delimiter row is `|`, `-`, `:`, spaces and tabs, with a pipe and
    /// a dash, after any indent and quote markers.
    static func mayBeInTable(_ ns: NSString, at location: Int) -> Bool {
        func blank(_ line: MarkdownSourceLines.Line) -> Bool {
            (0..<line.content.length).allSatisfy {
                let unit = ns.character(at: line.content.location + $0)
                return unit == 0x20 || unit == 0x09
            }
        }
        var line = MarkdownSourceLines.line(containing: location, in: ns)
        guard !blank(line) else { return false }
        if let next = MarkdownSourceLines.line(after: line, in: ns), !blank(next) { line = next }
        while let above = MarkdownSourceLines.line(before: line, in: ns), !blank(above) {
            if looksLikeDelimiter(ns, line) { return true }
            line = above
        }
        return false
    }

    /// Whether `line` could be a delimiter row: `|`, `-`, `:`, spaces and tabs, a pipe and a dash
    /// among them, after any indent and quote markers. Cheap — no string is made.
    static func looksLikeDelimiter(_ ns: NSString, _ line: MarkdownSourceLines.Line) -> Bool {
        var pipe = false, dash = false, lead = true
        for offset in 0..<line.content.length {
            switch ns.character(at: line.content.location + offset) {
            case 0x20, 0x09: continue
            case 0x3E where lead: continue                     // `>`
            case 0x7C: pipe = true; lead = false               // `|`
            case 0x2D: dash = true; lead = false               // `-`
            case 0x3A: lead = false                            // `:`
            default: return false
            }
        }
        return pipe && dash
    }

    /// **The table `location` is in**, with its row and column — or `nil`.
    static func locate(in ns: NSString, at location: Int) -> Location? {
        guard location >= 0, location <= ns.length, mayBeInTable(ns, at: location),
              // **The table's lines are cmark's** (TBL-3, TBL-9): a run of lines holding pipes
              // took in a list item, quote or heading written right under a table — Format Table
              // made it a row — and left out a row with no pipe, which Preview draws in the table.
              let lines = MarkdownSourceContext.tableLines(at: location, in: ns) else { return nil }
        // cmark's table starts where the paragraph its header ended did — `Intro⏎| a | b |⏎…` is a
        // table from `Intro` to cmark — so the header is found among its lines: the line before
        // the first delimiter row that matches it.
        var header = lines.first
        var delimiter: MarkdownSourceLines.Line?
        while delimiter == nil, header.content.location < lines.last.content.location,
              let next = MarkdownSourceLines.line(after: header, in: ns) {
            let text = ns.substring(with: next.content)
            if let aligns = alignments(text), cells(ns.substring(with: header.content)).count == aligns.count {
                delimiter = next
            } else {
                header = next
            }
        }
        let here = MarkdownSourceLines.line(containing: location, in: ns).content
        guard delimiter != nil, here.location >= header.content.location else { return nil }
        let range = NSRange(location: header.content.location,
                            length: NSMaxRange(lines.last.content) - header.content.location)
        guard let table = table(in: ns, range: range) else { return nil }
        // The line in the table: 0 the header, 1 the delimiter row, then the body.
        var lineIndex = 0
        for unit in range.location..<here.location where ns.character(at: unit) == 0x0A { lineIndex += 1 }
        let delimiterIndex = 1

        // Which cell: the last one opened before the position.
        let starts = cellStarts(ns.substring(with: here))
        let offset = location - here.location
        var column = 0
        for (index, start) in starts.enumerated() where start.pipe < offset { column = index }
        column = min(column, table.columns - 1)
        let content = starts.indices.contains(column) ? starts[column].content : 0
        return Location(table: range, row: lineIndex <= delimiterIndex ? 0 : lineIndex - delimiterIndex, column: column,
                        onDelimiter: lineIndex == delimiterIndex, offsetInCell: max(0, offset - content))
    }

    /// For each pipe-opened cell of `line`, in UTF-16: where the pipe that opens it is (`-1` for a
    /// first cell with no leading pipe) and where its text starts after the spaces. A trailing pipe
    /// opens one more, empty, entry — callers count cells with ``cells(_:)``.
    static func cellStarts(_ line: String) -> [(pipe: Int, content: Int)] {
        let units = Array(line.utf16)
        let pipe = UInt16(UInt8(ascii: "|")), backslash = UInt16(UInt8(ascii: "\\"))
        let space = UInt16(UInt8(ascii: " ")), tab = UInt16(UInt8(ascii: "\t"))
        var index = 0
        let quote = UInt16(UInt8(ascii: ">"))
        while index < units.count, units[index] == space || units[index] == tab || units[index] == quote { index += 1 }
        // `-1` whatever the indent: `index - 1` named the indent's last space, and Add Column Left
        // then put the new cell after it — read as a leading border, which broke the table (TBL-2).
        var opens: [Int] = index < units.count && units[index] == pipe ? [] : [-1]
        for i in index..<units.count where units[i] == pipe && (i == 0 || units[i - 1] != backslash) {
            opens.append(i)
        }
        return opens.map { open in
            var content = open < 0 ? index : open + 1
            while content < units.count, units[content] == space { content += 1 }
            return (open, content)
        }
    }

    // MARK: - Lined up or not

    /// How many columns of a monospaced font `text` is counted as: two for the wide East Asian
    /// scripts and for emoji — those drawn as emoji by default, and those a variation selector
    /// (U+FE0F) asks to be, like ⚠️ and ❤️ (TBL-12) — one for everything else.
    ///
    /// **A count, and only nearly what the editor draws.** SF Mono has no glyphs for either: 寿司
    /// comes from a fallback font a little narrower than four columns, an emoji from one a little
    /// wider than two (measured 2026-10-16 at 13pt: 寿司 6pt short, ✅ 3pt over). So a table holding
    /// them lines up in its characters, and on screen to within a column — not exactly.
    static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { total, character in
            let scalars = character.unicodeScalars
            guard let first = scalars.first else { return total }
            let emoji = scalars.contains { $0.properties.isEmojiPresentation || $0 == "\u{FE0F}" }
            return total + (isWide(first) || emoji ? 2 : 1)
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
        var previous: Character?
        for ch in line {
            if ch == "|", previous != "\\" { columns.append(width) }
            width += displayWidth(String(ch))
            previous = ch
        }
        return columns
    }

    /// **Whether the table at `range` is lined up** — every row's pipes at the same columns. Not
    /// on its own what decides whether an edit re-pads it: see ``keepsLinedUp(source:table:)``.
    static func isAligned(source: String, table range: NSRange) -> Bool {
        let ns = source as NSString
        guard table(in: ns, range: range) != nil else { return false }
        let columns = lines(of: ns, in: range).lines.map(pipeColumns)
        return columns.dropFirst().allSatisfy { $0 == columns[0] }
    }

    /// **Whether an edit re-pads the table at `range`** — the ONE rule the Table menu and typing
    /// in editable Preview share (TBL-4; TE67's decision T asks it as
    /// `PreviewEditTranslator.realignsAsYouType`): its pipes line up AND its header is written
    /// padded, `| a`, the way Format Table writes it. A compact `|a|b|` or a pipe-less `a | b` can
    /// line up too, but re-padding rewrote every line of it into Format Table's style; those keep
    /// theirs, as a ragged table does, and change only in the row or column an edit is about.
    static func keepsLinedUp(source: String, table range: NSRange) -> Bool {
        guard isAligned(source: source, table: range),
              let header = lines(of: source as NSString, in: range).lines.first else { return false }
        return header.dropFirst(linePrefix(header).count).hasPrefix("| ")
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
                    // Compact, each run spans its column's padded cells, a space either side.
                    if table.compactDelimiter {
                        let run = width + 2
                        switch alignment {
                        case .none: return String(repeating: "-", count: run) + "|"
                        case .left: return ":" + String(repeating: "-", count: run - 1) + "|"
                        case .right: return String(repeating: "-", count: run - 1) + ":|"
                        case .center: return ":" + String(repeating: "-", count: run - 2) + ":|"
                        }
                    }
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
        guard endsInUnescapedPipe(trimmed) else { return nil }
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
                let indent = linePrefix(line).utf16.count
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
        let indent = linePrefix(line).utf16.count
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
        // A lone `|` is no row to cmark — the table ended there and every row below it fell out
        // (TBL-1) — so a row the removal leaves without a cell keeps an empty one.
        if result.trimmingCharacters(in: padding) == "|" { return String(line.prefix(indent)) + "| |" }
        guard !hasUnescapedPipe(result) else { return result }
        let text = result.trimmingCharacters(in: padding)
        return String(line.prefix(indent)) + "| " + text + (text.isEmpty ? "" : " ") + "|"
    }

    /// Where the caret goes in the cell at `column` of `lines[line]`: its text's start — or, in an
    /// empty cell, one space in rather than against its closing pipe.
    private static func caret(at range: NSRange, lines: [String], breaks: [String], line: Int, column: Int) -> Int {
        var offset = range.location
        for index in 0..<line { offset += (lines[index] as NSString).length + (breaks[index] as NSString).length }
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
        // **Each line keeps the break it had** (TBL-18): joined with one, the lines of a table whose
        // breaks were mixed lost their `\r` though nothing else in them changed. A new line takes
        // the table's own break; a removed one takes its break with it.
        var breaks = (source as NSString).substring(with: range).components(separatedBy: "\n").dropLast()
            .map { $0.hasSuffix("\r") ? "\r\n" : "\n" }
        func insert(_ line: String, at index: Int) {
            lines.insert(line, at: index)
            breaks.insert(lineBreak, at: min(index, breaks.count))
        }
        func remove(at index: Int) {
            lines.remove(at: index)
            breaks.remove(at: min(index, breaks.count - 1))
        }
        // Cell row `r` is line 0 for the header, line r + 1 for the body (the delimiter is line 1).
        func line(ofRow r: Int) -> Int { r == 0 ? 0 : r + 1 }
        let caretLine: Int
        let caretColumn: Int
        switch op {
        case .addRowAbove:
            guard row > 0 else { return nil }
            insert(emptyRow(table), at: line(ofRow: row))
            (caretLine, caretColumn) = (line(ofRow: row), column)
        case .addRowBelow:
            let at = row == 0 ? 2 : line(ofRow: row) + 1
            insert(emptyRow(table), at: at)
            (caretLine, caretColumn) = (at, column)
        case .deleteRow:
            guard row > 0 else { return nil }
            remove(at: line(ofRow: row))
            let next = min(line(ofRow: row), lines.count - 1)
            (caretLine, caretColumn) = (next == 1 ? 0 : next, column)
        case .addColumnLeft, .addColumnRight:
            let at = op == .addColumnLeft ? column : column + 1
            lines = lines.enumerated().map { index, line in
                // The header and the delimiter row reach the new column first (TBL-10): from a cell
                // past the header's last, the cell went into that row alone, which cmark ignores.
                var line = line
                for _ in 0..<(index < 2 ? at : 0) where cells(line).count < at {
                    line = insertingCell(into: line, at: cells(line).count, delimiter: index == 1)
                }
                return insertingCell(into: line, at: at, delimiter: index == 1)
            }
            (caretLine, caretColumn) = (line(ofRow: row), at)
        case .deleteColumn:
            guard table.headerColumns > 1 else { return nil }
            lines = lines.map { removingCell(from: $0, at: column) }
            (caretLine, caretColumn) = (line(ofRow: row), min(column, table.columns - 2))
        case .tidy, .insert, .fromSelection:
            return nil
        }
        let text = zip(lines, breaks + [""]).map { $0 + $1 }.joined()
        let newRange = NSRange(location: range.location, length: (text as NSString).length)
        return MarkupEdit(text: (source as NSString).replacingCharacters(in: range, with: text),
                          selection: NSRange(location: caret(at: newRange, lines: lines, breaks: breaks,
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
        guard keepsLinedUp(source: source, table: range) else {
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
            guard table.headerColumns > 1 else { return nil }
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

    /// **Whether either end of the selection is inside a table** — what decides that a verb
    /// rewriting whole lines would break one (``MarkdownEdits/breaksTable(_:in:selection:)``, TE76).
    /// Either end, not both: a selection from a row down into the prose after it still rewrites
    /// the row. **The end is the line the selection ends ON** (FMT-12, ``selectionEnd(_:_:)``): a
    /// triple-clicked heading just above a table ends at the start of the table's first line, and
    /// its Heading and list buttons greyed for a table they would not have touched.
    static func touches(_ ns: NSString, _ selection: NSRange) -> Bool {
        guard selection.location != NSNotFound, selection.location >= 0,
              NSMaxRange(selection) <= ns.length else { return false }
        return locate(in: ns, at: selection.location) != nil
            || locate(in: ns, at: selectionEnd(ns, selection)) != nil
    }

    /// **Where a selection ends, for the line it ends on**: a selection ending just after a line
    /// break — a triple-clicked line — ends on the line it selected, not at the start of the one
    /// after it (TBL-11, FMT-17). Insert Table put its table after that NEXT line.
    static func selectionEnd(_ ns: NSString, _ selection: NSRange) -> Int {
        let end = NSMaxRange(selection)
        return selection.length > 0 && end > selection.location && ns.character(at: end - 1) == 0x0A ? end - 1 : end
    }

    /// **Whether the paragraph the selection ends in runs straight into a table** (FMT-2): no blank
    /// line between the selection's last line and a table's header below it. A list or quote verb
    /// there would make the table's lines lazy continuation text of its item or quote, and cmark
    /// would draw no table — so those verbs treat it as touched (``MarkupVerb/continuesLazily``).
    /// Any written line between counts as the paragraph, a heading too: refusing a list on a line
    /// whose table it would not have swallowed is the safe side.
    static func abuts(_ ns: NSString, _ selection: NSRange) -> Bool {
        guard selection.location != NSNotFound, selection.location >= 0,
              NSMaxRange(selection) <= ns.length else { return false }
        func blank(_ line: MarkdownSourceLines.Line) -> Bool {
            (0..<line.content.length).allSatisfy {
                let unit = ns.character(at: line.content.location + $0)
                return unit == 0x20 || unit == 0x09
            }
        }
        let last = MarkdownSourceLines.line(containing: selectionEnd(ns, selection), in: ns)
        guard !blank(last) else { return false }
        var line = last
        while let next = MarkdownSourceLines.line(after: line, in: ns), !blank(next) {
            if looksLikeDelimiter(ns, next), let table = locate(in: ns, at: next.content.location) {
                return table.table.location > last.content.location
            }
            line = next
        }
        return false
    }

    /// Which Table menu items apply at `selection` — what the bar's Table button and Table capsule,
    /// and the text's right-click menu, enable: exactly the ones ``apply(_:to:selection:)`` would
    /// not refuse.
    /// Inside a table: the row and column edits and Tidy, but no row above the header, no deleting
    /// it, and no deleting the only column. Outside: Insert Table, and Make Table from Selection
    /// over lines holding tabs or commas.
    static func available(in ns: NSString, selection: NSRange) -> Set<TableVerb> {
        reading(ns, selection).available
    }

    /// **What the format bar and the right-click menus ask of one selection, asked once** (TBL-19):
    /// the Table items that apply, whether it touches a table, and whether its paragraph runs into
    /// one. Each ``locate(in:at:)`` that finds a table parses the note down to it — the price of
    /// knowing it is not in a code block — and asked one at a time, available, touches and abuts
    /// parsed the same lines up to three times a caret move, on the main thread for a right-click.
    /// Read together, an end on the start's line reuses its answer, and nothing in a table asks
    /// whether a table is below.
    static func reading(_ ns: NSString, _ selection: NSRange) -> (available: Set<TableVerb>, touches: Bool, abuts: Bool) {
        guard selection.location != NSNotFound, selection.location >= 0,
              NSMaxRange(selection) <= ns.length else { return ([], false, false) }
        let start = locate(in: ns, at: selection.location)
        let endLocation = selectionEnd(ns, selection)
        let sameLine = MarkdownSourceLines.line(containing: endLocation, in: ns).content.location
            == MarkdownSourceLines.line(containing: selection.location, in: ns).content.location
        let endInTable = sameLine ? start != nil : locate(in: ns, at: endLocation) != nil
        if let at = start {
            var verbs: Set<TableVerb> = [.addRowBelow, .addColumnLeft, .addColumnRight, .tidy]
            if at.row > 0 { verbs.formUnion([.addRowAbove, .deleteRow]) }
            if (table(in: ns, range: at.table)?.headerColumns ?? 0) > 1 { verbs.insert(.deleteColumn) }
            return (verbs, true, false)
        }
        var verbs: Set<TableVerb> = []
        if !endInTable { verbs.insert(.insert) }
        if conversion(ns, selection) != nil { verbs.insert(.fromSelection) }
        // In a table every verb that would swallow one is refused already; abuts asks only outside.
        return (verbs, endInTable, endInTable ? false : abuts(ns, selection))
    }

    /// **Why a Table item had nothing to do here** — for the log, from the menu bar, which cannot
    /// grey its items (TBL-13). ``TableVerb/refusal`` names the usual reason; Make Table from
    /// Selection has four, and logged "no tabs or commas" for a caret on `a,b` with nothing
    /// selected, and for a selection ending in a table.
    static func refusal(_ op: TableVerb, in ns: NSString, selection: NSRange) -> String {
        guard op == .fromSelection, selection.location != NSNotFound,
              NSMaxRange(selection) <= ns.length else { return op.refusal }
        if selection.length == 0 { return "nothing is selected — select the lines to make into a table" }
        if locate(in: ns, at: selection.location) != nil || locate(in: ns, at: selectionEnd(ns, selection)) != nil {
            return "the selection starts or ends in a table"
        }
        var line = MarkdownSourceLines.line(containing: selection.location, in: ns)
        while line.content.location <= selectionEnd(ns, selection) {
            if looksLikeDelimiter(ns, line), locate(in: ns, at: line.content.location) != nil {
                return "the selection holds a table"
            }
            guard let next = MarkdownSourceLines.line(after: line, in: ns) else { break }
            line = next
        }
        return op.refusal
    }

    /// The placeholder words a new table's header carries. The first is selected after Insert
    /// Table, so typing replaces it.
    static let placeholderHeader = ["Column 1", "Column 2", "Column 3"]

    /// **Insert Table**: three columns, the header and two empty rows, after the line the selection
    /// ends on (``selectionEnd(_:_:)``) — or on that line, when it is blank — with a blank line either
    /// side, so it is read as a table and not as part of a paragraph. Nothing selected is replaced.
    /// Refused in a table.
    static func insert(_ text: String, _ selection: NSRange) -> MarkupEdit? {
        let ns = text as NSString
        let end = selectionEnd(ns, selection)
        guard locate(in: ns, at: selection.location) == nil, locate(in: ns, at: end) == nil else { return nil }
        let line = contentRange(of: ns, lineAt: end)
        let lineBreak = lineBreak(of: ns, after: line)
        // In a quote, the table and the blank lines either side of it stay in the quote (TBL-5).
        let quote = quotePrefix(ns.substring(with: line))
        let gap = blankLine(in: quote)
        let table = Table(indent: quote, rows: [placeholderHeader, ["", "", ""], ["", "", ""]],
                          alignments: [.none, .none, .none], lineBreak: lineBreak, headerColumns: 3)
        let rendered = render(table).text
        let replace: NSRange
        let lead: String
        if isBlank(ns, line) {
            replace = line
            let hasWrittenLineAbove = line.location > 0 && !isBlank(ns, contentRange(of: ns, lineAt: line.location - 1))
            lead = hasWrittenLineAbove ? gap + lineBreak : ""
        } else {
            replace = NSRange(location: NSMaxRange(line), length: 0)
            lead = lineBreak + gap + lineBreak
        }
        let trail = nextLine(ns, after: line).map { isBlank(ns, $0) ? "" : lineBreak + gap } ?? ""
        let header = replace.location + ((lead + quote) as NSString).length + 2  // after "| "
        return MarkupEdit(text: ns.replacingCharacters(in: replace, with: lead + rendered + trail),
                          selection: NSRange(location: header, length: (placeholderHeader[0] as NSString).length))
    }

    /// The selection's lines, whole, and whether they split on tabs (`true`) or commas — or `nil`
    /// when no written line holds either, or the lines start or end in a table. The cheap half of
    /// ``convertibleRows(_:_:)``: what the Table menu's enabling asks on every caret move, without
    /// reading a cell.
    static func conversion(_ ns: NSString, _ selection: NSRange)
        -> (range: NSRange, lines: [String], tabs: Bool, quote: String)? {
        guard selection.length > 0, NSMaxRange(selection) <= ns.length else { return nil }
        // A selection ending just after a line break does not take the line after it.
        let end = selectionEnd(ns, selection)
        let first = contentRange(of: ns, lineAt: selection.location)
        let last = contentRange(of: ns, lineAt: max(end, selection.location))
        let range = NSRange(location: first.location, length: max(NSMaxRange(last), NSMaxRange(first)) - first.location)
        guard locate(in: ns, at: range.location) == nil, locate(in: ns, at: NSMaxRange(range)) == nil else { return nil }
        // Nor a table anywhere between (TBL-6): its rows were flattened into one escaped cell each
        // and the blank lines around it dropped. A table holds a delimiter row, so only a line that
        // looks like one is asked about.
        var line = MarkdownSourceLines.line(containing: range.location, in: ns)
        while line.content.location <= NSMaxRange(range) {
            if looksLikeDelimiter(ns, line), locate(in: ns, at: line.content.location) != nil { return nil }
            guard let next = MarkdownSourceLines.line(after: line, in: ns) else { break }
            line = next
        }
        var lines = lines(of: ns, in: range).lines.filter { !isBlankText($0) }
        // Lines in a quote lose their `>` to the table's indent, and keep it (TBL-5): read as text,
        // the first cell of every row began `> `, and the table was written outside the quote.
        // Only the markers and the one space after the last go: a tab after them is a cell's edge.
        let depth = { (line: String) in linePrefix(line).filter { $0 == ">" }.count }
        let opening = lines.first.map(quotePrefix) ?? ""
        let quote = !opening.isEmpty && lines.allSatisfy({ depth($0) == depth(opening) }) ? opening : ""
        if !quote.isEmpty {
            lines = lines.map { line in
                let markers = quotePrefix(line).count - 1
                let rest = line.dropFirst(markers)
                return String(rest.hasPrefix(" ") ? rest.dropFirst() : rest)
            }
        }
        if lines.contains(where: { $0.contains("\t") }) { return (range, lines, true, quote) }
        if lines.contains(where: { $0.contains(",") }) { return (range, lines, false, quote) }
        return nil
    }

    /// The selection's lines, whole, split into cells — on tabs when any line has one, else on
    /// commas, reading quoted fields as CSV does — or `nil` (see ``conversion(_:_:)``). Blank lines
    /// are left out; a table cannot hold one.
    static func convertibleRows(_ ns: NSString, _ selection: NSRange)
        -> (range: NSRange, rows: [[String]], quote: String)? {
        guard let (range, lines, tabs, quote) = conversion(ns, selection) else { return nil }
        let rows = tabs ? lines.map { $0.components(separatedBy: "\t") } : lines.map(csvFields)
        return (range, rows.map { $0.map(escapedCell) }, quote)
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

    /// A cell's text made safe for a row: trimmed, its pipes escaped — each one a backslash does
    /// not already escape, by cmark's rule (``endsInUnescapedPipe(_:)``).
    static func escapedCell(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for ch in text.trimmingCharacters(in: padding) {
            result += ch == "|" && previous != "\\" ? "\\|" : String(ch)
            previous = ch
        }
        return result
    }

    /// **Make Table from Selection**: the selected lines, whole, become a table — the first line its
    /// header — lined up, with a blank line either side, and the caret after it.
    static func fromSelection(_ text: String, _ selection: NSRange) -> MarkupEdit? {
        let ns = text as NSString
        guard let (range, rows, quote) = convertibleRows(ns, selection) else { return nil }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return nil }
        let lineBreak = lineBreak(of: ns, after: contentRange(of: ns, lineAt: range.location))
        let table = Table(indent: quote, rows: rows.map { $0 + Array(repeating: "", count: columns - $0.count) },
                          alignments: Array(repeating: .none, count: columns), lineBreak: lineBreak,
                          headerColumns: columns)
        let rendered = render(table).text
        let gap = blankLine(in: quote)
        let hasWrittenLineAbove = range.location > 0 && !isBlank(ns, contentRange(of: ns, lineAt: range.location - 1))
        let lead = hasWrittenLineAbove ? gap + lineBreak : ""
        let trail = nextLine(ns, after: contentRange(of: ns, lineAt: NSMaxRange(range)))
            .map { isBlank(ns, $0) ? "" : lineBreak + gap } ?? ""
        return MarkupEdit(text: ns.replacingCharacters(in: range, with: lead + rendered + trail),
                          selection: NSRange(location: range.location + ((lead + rendered) as NSString).length, length: 0))
    }

    /// Whether a line holds nothing past its prefix — `>` alone is a blank line in a quote.
    private static func isBlank(_ ns: NSString, _ line: NSRange) -> Bool {
        isBlankText(ns.substring(with: line))
    }

    private static func isBlankText(_ line: String) -> Bool {
        line.dropFirst(linePrefix(line).count).trimmingCharacters(in: padding).isEmpty
    }

    /// The blank line that keeps a quote open between its paragraphs: its prefix without the spaces
    /// after it — `>` — or nothing outside a quote.
    private static func blankLine(in quote: String) -> String {
        String(quote.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
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
