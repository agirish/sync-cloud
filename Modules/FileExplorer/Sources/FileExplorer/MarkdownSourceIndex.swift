import Foundation

/// Where each line of a Markdown source starts, in the two units that disagree about it.
///
/// **swift-markdown counts columns in UTF-8 bytes; `NSTextView` counts in UTF-16 units.** In
/// `Café **naïve**` the parser puts `Strong` at column 7, because `"Café "` is six bytes, while the
/// text view puts it at offset 5. Every position the editable preview maps from the parser into the
/// buffer passes through ``utf16Offset(line:utf8Column:)``, so the conversion has one home.
///
/// **Line endings are cmark's, not `components(separatedBy: "\n")`'s:** `\n`, `\r\n` and a lone `\r`
/// each end a line. The parser numbers lines that way, so an index that split on `\n` alone would
/// put every line of a classic-Mac file on line 1.
struct MarkdownSourceIndex: Sendable {

    struct Line: Equatable, Sendable {
        /// UTF-16 offset of the line's first unit.
        var start: Int
        /// UTF-16 offset just past the line's content, before its terminator.
        var end: Int
        /// 0 on a last line with no terminator, 2 for `\r\n`, otherwise 1.
        var terminatorLength: Int
        /// Where the next line starts.
        var next: Int { end + terminatorLength }
    }

    /// The source as UTF-16 units, the text view's own unit.
    let units: [UInt16]
    let lines: [Line]

    init(_ source: String) {
        let units = Array(source.utf16)
        var lines: [Line] = []
        var start = 0
        var index = 0
        while index < units.count {
            switch units[index] {
            case 0x0A:
                lines.append(Line(start: start, end: index, terminatorLength: 1))
                index += 1
                start = index
            case 0x0D:
                let pair = index + 1 < units.count && units[index + 1] == 0x0A
                lines.append(Line(start: start, end: index, terminatorLength: pair ? 2 : 1))
                index += pair ? 2 : 1
                start = index
            default:
                index += 1
            }
        }
        // The last line, which has no terminator. A source ending in a newline still has one: an
        // empty line after it, which is where a caret at the very end sits.
        lines.append(Line(start: start, end: units.count, terminatorLength: 0))
        self.units = units
        self.lines = lines
    }

    var length: Int { units.count }

    /// The 1-based line `number`, or `nil` past either end.
    func line(_ number: Int) -> Line? {
        guard number >= 1, number <= lines.count else { return nil }
        return lines[number - 1]
    }

    /// The UTF-16 offset of a parser position: a 1-based line and a 1-based **UTF-8 byte** column.
    ///
    /// The column may run past the line's content into its terminator, but no further — the caller
    /// asking about a column beyond that has a position this source does not contain, and `nil` says
    /// so rather than clamping to somewhere it was never told to go. `nil` too for a column that
    /// lands inside a multi-byte character.
    func utf16Offset(line number: Int, utf8Column column: Int) -> Int? {
        guard let line = line(number), column >= 1 else { return nil }
        return advance(from: line.start, utf8Bytes: column - 1, limit: line.next)
    }

    /// The offset `bytes` UTF-8 bytes after `start`, stopping at `limit`; `nil` when that falls
    /// past `limit` or inside a character.
    func advance(from start: Int, utf8Bytes bytes: Int, limit: Int) -> Int? {
        var offset = start
        var remaining = bytes
        while remaining > 0 {
            guard offset < limit else { return nil }
            let width = Self.utf8Width(at: offset, in: units)
            guard width <= remaining else { return nil }
            remaining -= width
            offset += Self.isHighSurrogate(units[offset]) && offset + 1 < units.count ? 2 : 1
        }
        return offset
    }

    /// How many UTF-8 bytes the units in `range` encode to.
    func utf8Count(from start: Int, to end: Int) -> Int {
        var count = 0
        var offset = start
        while offset < end {
            count += Self.utf8Width(at: offset, in: units)
            offset += Self.isHighSurrogate(units[offset]) && offset + 1 < units.count ? 2 : 1
        }
        return count
    }

    /// The 1-based line holding UTF-16 `offset`. An offset on a terminator belongs to its line.
    func lineNumber(containing offset: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].start <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    private static func isHighSurrogate(_ unit: UInt16) -> Bool { (0xD800...0xDBFF).contains(unit) }

    /// Bytes for the character starting at `offset`: a surrogate pair is one four-byte scalar.
    private static func utf8Width(at offset: Int, in units: [UInt16]) -> Int {
        let unit = units[offset]
        if unit < 0x80 { return 1 }
        if unit < 0x800 { return 2 }
        if isHighSurrogate(unit), offset + 1 < units.count,
           (0xDC00...0xDFFF).contains(units[offset + 1]) { return 4 }
        return 3
    }
}
