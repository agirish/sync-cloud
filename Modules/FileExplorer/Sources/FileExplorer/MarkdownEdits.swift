import Foundation

/// Edits made to Markdown source by something other than typing.
///
/// **Pure functions over a string, with the buffer handed in and a new buffer handed back.** The
/// alternative — reaching into the `NSTextView` and splicing — would put the app's only unattended
/// writes to somebody's file behind a view, where nothing can test them. Everything here can be run
/// against a fixture and asserted character for character, which is the bar for code that edits
/// files in his cloud folders.
enum MarkdownEdits {

    /// Flips the checkbox on a 1-based source line, or answers `nil` when there is not one to flip.
    ///
    /// **`nil` is the honest answer to a stale click, and it has to be checked.** The preview is
    /// rendered from a parse that is up to 150ms behind the buffer, so a click can arrive naming a
    /// line whose checkbox has just been typed away. Rewriting that line anyway would put an `[x]`
    /// into whatever now stands there.
    ///
    /// The match is deliberately narrow: leading whitespace, a list marker, whitespace, then the
    /// box. A `[ ]` written in the middle of a sentence is not a checkbox and is left alone — the
    /// same distinction ``MarkdownListMarker/task(done:)`` exists to make.
    static func toggleTask(onLine target: Int, in text: String) -> String? {
        guard let range = lineRange(of: target, in: text) else { return nil }
        let line = String(text[range])
        guard let flipped = flippedCheckbox(in: line) else { return nil }
        return text.replacingCharacters(in: range, with: flipped)
    }

    /// The line's own range, not including its terminator.
    static func lineRange(of target: Int, in text: String) -> Range<String.Index>? {
        guard target >= 1 else { return nil }
        var line = 1
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\n" || character == "\r\n" || character == "\r" {
                if line == target { return start..<index }
                line += 1
                start = next
            }
            index = next
        }
        // The last line, which has no terminator after it.
        return line == target ? start..<text.endIndex : nil
    }

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
