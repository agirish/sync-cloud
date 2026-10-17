import Foundation

/// Edits made to Markdown source by something other than typing.
///
/// **Pure functions over a string, with the buffer handed in and a new buffer — or the edit that
/// makes it — handed back.** The
/// alternative — reaching into the `NSTextView` and splicing — would put the app's only unattended
/// writes to somebody's file behind a view, where nothing can test them. Everything here can be run
/// against a fixture and asserted character for character, which is the bar for code that edits
/// files in his cloud folders.
enum MarkdownEdits {

    /// The edit that flips the checkbox on a 1-based source line — the one UTF-16 unit of the box
    /// that changes, and what goes there — or `nil` when there is not one to flip.
    ///
    /// **`nil` is the honest answer to a stale click, and it has to be checked.** The preview is
    /// rendered from a parse that is up to 150ms behind the buffer, so a click can arrive naming a
    /// line whose checkbox has just been typed away. Rewriting that line anyway would put an `[x]`
    /// into whatever now stands there.
    ///
    /// The match is deliberately narrow: leading whitespace, a list marker, whitespace, then the
    /// box. A `[ ]` written in the middle of a sentence is not a checkbox and is left alone — the
    /// same distinction ``MarkdownListMarker/task(done:)`` exists to make.
    ///
    /// **Read in place, and only as far as the line** (P52). A tick is one click on one line of a
    /// document that can be 4 MiB, and it used to copy the whole text, walk it a Character at a time,
    /// build a new text and diff the two in full: 19 ms at 200 KB. Now it reads the UTF-16 up to the
    /// line's end and works on that line alone. The flip is the same Character rules applied to the
    /// same line, so what a tick writes is unchanged.
    static func taskToggle(onLine target: Int, in text: NSString) -> (range: NSRange, text: String)? {
        guard let range = lineRange(of: target, in: text) else { return nil }
        let line = text.substring(with: range)
        guard let flipped = flippedCheckbox(in: line) else { return nil }
        let change = minimalReplacement(from: line, to: flipped)
        return (NSRange(location: range.location + change.range.location, length: change.range.length), change.text)
    }

    /// The line's own range in UTF-16, not including its terminator.
    ///
    /// **LF, CR and CRLF end a line, as in ``EditorLineIndex``** — counted by unit, which counts the
    /// same lines as a walk by Character: a CR or an LF is always a Character of its own, or the
    /// two are one, `"\r\n"`. Read ``lineScanChunk`` units at a time, so finding line 3 of a long
    /// document reads one chunk of it.
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
    /// `[X]` is checked too — GFM accepts either case, and a file written by another tool routinely
    /// uses the capital. It is flipped to a lowercase `[x]`, because the flip has to choose one and
    /// this is what the app writes everywhere else.
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
        // **At least one space between the marker and the box.** `-[x]` is not a task item to any
        // parser, so it must not become one here either.
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
