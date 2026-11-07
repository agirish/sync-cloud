import Foundation

/// Edits made to Markdown source by something other than typing.
///
/// Pure functions: the buffer goes in, and a new buffer, or the edit that makes it, comes back.
/// Splicing inside the `NSTextView` would put unattended writes to a user's file behind a view,
/// where nothing can test them; here every edit is asserted character for character.
enum MarkdownEdits {

    /// The edit that flips the checkbox on a 1-based source line (the one UTF-16 unit of the box
    /// that changes, and what goes there), or `nil` when there is none to flip.
    ///
    /// `nil` answers a stale click, and callers must check it: the preview's parse can be up to
    /// 150 ms behind the buffer, so a click may name a line whose checkbox was just typed away, and
    /// rewriting it would put an `[x]` into whatever stands there now.
    ///
    /// The match is narrow: leading whitespace, a list marker, whitespace, then the box. A `[ ]`
    /// mid-sentence is not a checkbox (as in ``MarkdownListMarker/task(done:)``). Reads the text in
    /// place, only as far as the line, since a document can be 4 MiB.
    static func taskToggle(onLine target: Int, in text: NSString) -> (range: NSRange, text: String)? {
        guard let range = lineRange(of: target, in: text) else { return nil }
        let line = text.substring(with: range)
        guard let flipped = flippedCheckbox(in: line) else { return nil }
        let change = minimalReplacement(from: line, to: flipped)
        return (NSRange(location: range.location + change.range.location, length: change.range.length), change.text)
    }

    /// The line's own range in UTF-16, not including its terminator.
    ///
    /// LF, CR and CRLF end a line, as in ``EditorLineIndex``. Counted by UTF-16 unit, which finds the
    /// same lines as a walk by Character: CR and LF are each a Character, or together `"\r\n"`.
    /// Reads ``lineScanChunk`` units at a time, so line 3 of a long document costs one chunk.
    static func lineRange(of target: Int, in text: NSString) -> NSRange? {
        guard target >= 1 else { return nil }
        let length = text.length
        var line = 1
        var start = 0
        var afterCR = false
        var units = [unichar](repeating: 0, count: lineScanChunk)
        var chunk = 0
        while chunk < length {
            let count = min(lineScanChunk, length - chunk)
            text.getCharacters(&units, range: NSRange(location: chunk, length: count))
            for index in 0..<count {
                let unit = units[index]
                if unit == 0x0A && afterCR {
                    // A CRLF's LF: its CR has already ended the line.
                    start = chunk + index + 1
                } else if unit == 0x0A || unit == 0x0D {
                    if line == target { return NSRange(location: start, length: chunk + index - start) }
                    line += 1
                    start = chunk + index + 1
                }
                afterCR = unit == 0x0D
            }
            chunk += count
        }
        // The last line, which has no terminator after it.
        return line == target ? NSRange(location: start, length: length - start) : nil
    }

    /// How many UTF-16 units ``lineRange(of:in:)`` reads at a time.
    static let lineScanChunk = 4096

    /// The same line with its checkbox flipped, or `nil` when it has none.
    ///
    /// `[X]` counts as checked too, since GFM accepts either case and other tools write it. Ticking
    /// writes a lowercase `[x]`, as the app does everywhere else.
    private static func flippedCheckbox(in line: String) -> String? {
        var index = line.startIndex
        func skipWhitespace() {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" {
                index = line.index(after: index)
            }
        }
        skipWhitespace()
        guard index < line.endIndex else { return nil }
        // The list marker: a bullet, or a number followed by `.` or `)`.
        if line[index] == "-" || line[index] == "*" || line[index] == "+" {
            index = line.index(after: index)
        } else if line[index].isNumber {
            while index < line.endIndex, line[index].isNumber { index = line.index(after: index) }
            guard index < line.endIndex, line[index] == "." || line[index] == ")" else { return nil }
            index = line.index(after: index)
        } else {
            return nil
        }
        // At least one space between the marker and the box: `-[x]` is no task item to a parser.
        let beforeSpace = index
        skipWhitespace()
        guard index > beforeSpace else { return nil }

        guard index < line.endIndex, line[index] == "[" else { return nil }
        let open = index
        let state = line.index(after: open)
        guard state < line.endIndex else { return nil }
        let close = line.index(after: state)
        guard close < line.endIndex, line[close] == "]" else { return nil }

        switch line[state] {
        case " ":
            return line.replacingCharacters(in: open...close, with: "[x]")
        case "x", "X":
            return line.replacingCharacters(in: open...close, with: "[ ]")
        default:
            return nil
        }
    }
}
