import Foundation

/// How a file's lines are terminated, as the status line names it.
///
/// Cloud folders hold files from Windows, which are CRLF. Edit writes LF only, converting a file on
/// its first edit and never on opening it (``EditorLineEndings`` has the rule). This only names
/// what is in the buffer: CRLF for a file opened and not yet edited, LF once it has been.
enum EditorLineEnding: String, Equatable, Sendable, CaseIterable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"
    /// More than one kind in the same file. Its own case, not the first or commonest kind, so the
    /// status line never hides a mixed file, including one Edit made (a bug in the LF-only rule).
    case mixed = "Mixed"

    /// The status line's word: the kind, or "Mixed endings", since a bare "Mixed" after the
    /// encoding doesn't say what is mixed.
    var statusCaption: String { self == .mixed ? "Mixed endings" : rawValue }

    /// What terminates the lines in `text`, or `nil` when it has no line break at all: a single
    /// line has no line ending, and "LF" would describe bytes that aren't there. The status line
    /// omits the segment instead.
    static func detect(in text: String) -> EditorLineEnding? {
        var sawLF = false, sawCRLF = false, sawCR = false
        var previousWasCR = false
        for unit in text.unicodeScalars {
            switch unit {
            case "\r":
                // Not counted yet: whether this is a lone CR or half a CRLF depends on the next
                // scalar. Deciding here would report every CRLF file as mixed.
                if previousWasCR { sawCR = true }
                previousWasCR = true
            case "\n":
                if previousWasCR { sawCRLF = true } else { sawLF = true }
                previousWasCR = false
            default:
                if previousWasCR { sawCR = true }
                previousWasCR = false
            }
        }
        // A trailing CR with nothing after it is a lone CR.
        if previousWasCR { sawCR = true }
        let kinds = [sawLF, sawCRLF, sawCR].filter { $0 }.count
        guard kinds > 0 else { return nil }
        guard kinds == 1 else { return .mixed }
        if sawCRLF { return .crlf }
        if sawCR { return .cr }
        return .lf
    }
}

/// Where the caret is, in the terms a person reads.
struct EditorCaret: Equatable, Sendable {
    /// 1-based, so it matches ``MarkdownBlock/line`` and every "go to line" a person has ever used.
    var line: Int
    /// 1-based, counted in characters rather than UTF-16 units, so an emoji is one column: the
    /// column says where the caret looks like it is.
    var column: Int

    /// The caret's position, given an offset into `text`'s UTF-16 view. UTF-16 in, because
    /// `NSTextView` reports `NSRange`; characters out, because that is how a person reads columns.
    /// Converting here keeps the column from jumping by two through an emoji.
    static func at(utf16Offset offset: Int, in text: String) -> EditorCaret {
        var line = 1
        var column = 1
        var consumed = 0
        guard offset > 0 else { return EditorCaret(line: 1, column: 1) }
        // One pass over Characters, counting UTF-16 as it goes. Converting the offset to a
        // `String.Index` has no answer inside a surrogate pair; here such an offset consumes the
        // whole character, which is where the caret can actually stand.
        for character in text {
            if consumed >= offset { break }
            consumed += character.utf16.count
            // `"\r\n"` is one Character in Swift, so three comparisons suffice: the pair can't be
            // split across two iterations.
            if character == "\n" || character == "\r\n" || character == "\r" {
                line += 1
                column = 1
            } else {
                column += 1
            }
        }
        return EditorCaret(line: line, column: column)
    }

    /// The UTF-16 offset where a 1-based line begins, or `nil` when the text has no such line.
    ///
    /// The exact inverse of ``at(utf16Offset:in:)``: it turns an outline row into a scroll and
    /// "go to line" into a caret, and one character out would land on the end of the line before.
    /// `nil` rather than clamping, so asking for line 900 of a 400-line file isn't hidden.
    static func utf16Offset(ofLine target: Int, in text: String) -> Int? {
        guard target >= 1 else { return nil }
        guard target > 1 else { return 0 }
        var line = 1
        var offset = 0
        for character in text {
            offset += character.utf16.count
            if character == "\n" || character == "\r\n" || character == "\r" {
                line += 1
                if line == target { return offset }
            }
        }
        return nil
    }
}

/// Where every line of a buffer begins, in UTF-16 offsets.
///
/// Built once off the main actor, in the task that counts the status line's facts, and answered by
/// binary search. The split's scroll sync asks "which line is at the top?" on every bounds change,
/// and a walk from index 0 each time would cost a whole 4 MiB document per frame on the main thread.
///
/// It is rebuilt on the facts' 150 ms debounce, so it can trail the buffer. That is fine for scroll
/// sync but not for the caret, which is why ``utf16Length`` is carried: callers that need exactness
/// check it and fall back to the exact walk when it disagrees.
struct EditorLineIndex: Equatable, Sendable {

    /// The UTF-16 offset each 1-based line begins at. Always starts with `0`, so an empty buffer
    /// has a line 1 at 0, as ``EditorCaret/utf16Offset(ofLine:in:)`` answers.
    private(set) var lineStarts: [Int]
    /// The UTF-16 offset each line terminator begins at, in order. One shorter than
    /// ``lineStarts`` by construction.
    private(set) var terminatorStarts: [Int]
    /// The length of the text this describes, in UTF-16 units: the staleness check.
    private(set) var utf16Length: Int

    static let empty = EditorLineIndex(lineStarts: [0], terminatorStarts: [], utf16Length: 0)

    /// Walks `text` once, by exactly ``EditorCaret``'s rules. `"\r\n"` is one `Character` in
    /// Swift, so three comparisons suffice.
    init(text: String) {
        var starts: [Int] = [0]
        var terminators: [Int] = []
        var offset = 0
        for character in text {
            let start = offset
            offset += character.utf16.count
            if character == "\n" || character == "\r\n" || character == "\r" {
                terminators.append(start)
                starts.append(offset)
            }
        }
        self.lineStarts = starts
        self.terminatorStarts = terminators
        self.utf16Length = offset
    }

    private init(lineStarts: [Int], terminatorStarts: [Int], utf16Length: Int) {
        self.lineStarts = lineStarts
        self.terminatorStarts = terminatorStarts
        self.utf16Length = utf16Length
    }

    /// The 1-based line an offset falls on, as ``EditorCaret/at(utf16Offset:in:)`` answers. A
    /// terminator counts once the offset is past its first unit, so an offset between a CRLF's `\r`
    /// and `\n` lands on the next line, as the walk does.
    func line(atUTF16Offset offset: Int) -> Int {
        guard offset > 0 else { return 1 }
        // Lower bound: the number of terminators that begin strictly before `offset`.
        var low = 0
        var high = terminatorStarts.count
        while low < high {
            let mid = (low + high) / 2
            if terminatorStarts[mid] < offset { low = mid + 1 } else { high = mid }
        }
        return low + 1
    }

    /// Where a 1-based line begins, or `nil` when the text has no such line, as
    /// ``EditorCaret/utf16Offset(ofLine:in:)`` answers.
    func utf16Offset(ofLine target: Int) -> Int? {
        guard target >= 1, target <= lineStarts.count else { return nil }
        return lineStarts[target - 1]
    }

    /// How many lines the caret can stand on — one more than the line breaks, so a text ending in a
    /// line break has an empty last line after it, as ``EditorCaret`` counts.
    var lineCount: Int { lineStarts.count }

    /// Where a 1-based line's terminator begins — the end of its text — or `nil` for the last line,
    /// which has none (and for a line that does not exist).
    func terminatorStart(ofLine target: Int) -> Int? {
        guard target >= 1, target <= terminatorStarts.count else { return nil }
        return terminatorStarts[target - 1]
    }
}

/// What the status line says about the open buffer.
///
/// Derived from the text, never stored, so nothing can go stale. Computing it walks the buffer,
/// so the host does it on a debounce off the main actor (``EditorWorkspaceView``), not in a body.
struct EditorDocumentFacts: Equatable, Sendable {

    /// Runs of non-whitespace. Markup counts: a `##` is a word. Excluding it would mean deciding
    /// what markup is, which only the preview's parser knows, and would count the same text
    /// differently depending on whether it is Markdown.
    var words: Int
    /// Characters as a person counts them: grapheme clusters, so an emoji is one.
    var characters: Int
    /// Lines, counting a final line with no terminator. An empty buffer is 0 lines, not 1.
    var lines: Int
    var lineEnding: EditorLineEnding?
    /// How the bytes were decoded, or `nil` for a document that was never decoded at all.
    var encoding: String?

    static let empty = EditorDocumentFacts(words: 0, characters: 0, lines: 0,
                                           lineEnding: nil, encoding: nil)

    /// `1 word` / `412 words`, grouped for reading. The count passes through 1 as someone types,
    /// so the singular matters.
    var wordsCaption: String { Self.count(words, "word") }
    var charactersCaption: String { Self.count(characters, "character") }

    /// Static, so a caller holding only the number says it the same way: the divergence diff's
    /// `In Edit · 1,204 words` has no facts value to ask.
    static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted(.number)) \(noun)\(value == 1 ? "" : "s")"
    }

    static func of(_ text: String, encoding: String?) -> EditorDocumentFacts {
        let counted = wordsAndCharacters(in: text)
        return EditorDocumentFacts(words: counted.words,
                                   characters: counted.characters,
                                   lines: lineCount(of: text),
                                   lineEnding: EditorLineEnding.detect(in: text),
                                   encoding: encoding)
    }

    /// The word and character counts in one walk. ``EditorSelectionFacts`` shares it, so the two
    /// numbers on the line agree.
    static func wordsAndCharacters(in text: String) -> (words: Int, characters: Int) {
        var words = 0
        var inWord = false
        var characters = 0
        for character in text {
            characters += 1
            if character.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        return (words, characters)
    }

    /// Lines in `text`. A trailing newline opens no new line: `"a\n"` is one line, which is why
    /// this counts rather than using `components(separatedBy:).count`.
    static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var lines = 1
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r":
                if previousWasCR { lines += 1 }
                previousWasCR = true
            case "\n":
                lines += 1
                previousWasCR = false
            default:
                if previousWasCR { lines += 1 }
                previousWasCR = false
            }
        }
        if previousWasCR { lines += 1 }
        // A text that ends with a terminator has no line after it. `text.last`, not `hasSuffix`:
        // `"\r\n"` is one grapheme, so `hasSuffix("\n")` is false for a CRLF file and would count
        // a line too many.
        if let last = text.last, last == "\n" || last == "\r\n" || last == "\r" { lines -= 1 }
        return max(lines, 1)
    }
}

/// What the status line says about the selected text: its words, characters and lines, by exactly
/// ``EditorDocumentFacts``' rules, so "12 of 78 words" can never read 79 of 78 on a select-all.
///
/// A word cut by the selection's edge counts as one. Lines are the lines the selection touches,
/// and a trailing line break opens none, so a triple-clicked line reads as one line.
struct EditorSelectionFacts: Equatable, Sendable {
    var words: Int
    var characters: Int
    var lines: Int

    /// The counts for `selection` (UTF-16, as `NSTextView` reports it) in `text`, or `nil` for a
    /// bare caret, which puts the status line back to the document's counts.
    ///
    /// Clamped to the text, never trapped on: the text is read later, off the main actor, so the
    /// two can disagree by whatever was typed in between.
    ///
    /// A whole-text selection (⌘A) reuses `facts` when its version matches `version`, saving a
    /// second walk of the buffer. Matched by version, not length: a same-length edit or reload
    /// leaves counts that describe another text.
    static func of(_ text: String, selection: NSRange,
                   facts: (facts: EditorDocumentFacts, version: Int)? = nil,
                   version: Int? = nil) -> EditorSelectionFacts? {
        let utf16 = text.utf16
        let length = utf16.count
        let start = min(max(selection.location, 0), length)
        let end = min(max(selection.location + selection.length, start), length)
        guard end > start else { return nil }
        if start == 0, end == length, let facts, facts.version == version {
            return EditorSelectionFacts(words: facts.facts.words, characters: facts.facts.characters,
                                        lines: facts.facts.lines)
        }
        // Sliced as a Swift string, never through `NSString`: walking Characters of the NSString
        // that `substring(with:)` returns costs about four times the native walk.
        let from = utf16.index(utf16.startIndex, offsetBy: start)
        let selected = String(text[from..<utf16.index(from, offsetBy: end - start)])
        let counted = EditorDocumentFacts.wordsAndCharacters(in: selected)
        return EditorSelectionFacts(words: counted.words, characters: counted.characters,
                                    lines: EditorDocumentFacts.lineCount(of: selected))
    }
}
