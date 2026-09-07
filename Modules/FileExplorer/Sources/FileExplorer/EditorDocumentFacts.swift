import Foundation

/// How a file's lines are terminated.
///
/// **A real question for a real folder.** These are cloud folders shared with other machines, and a
/// file that arrived from Windows is CRLF; saving it back from an editor that silently normalised
/// would rewrite every line of a file the user changed one word in, and every sync client would
/// report the whole file as modified. Nothing here converts anything — this only *names* what is
/// already in the buffer, which is the half that was missing.
enum EditorLineEnding: String, Equatable, Sendable, CaseIterable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"
    /// More than one kind in the same file. Worth its own case rather than reporting the first or
    /// the commonest: a mixed file is the one a careless normalise would damage most, so it is
    /// exactly the state the status line should not smooth over.
    case mixed = "Mixed"

    /// What terminates the lines in `text`, or `nil` when it has no line break at all.
    ///
    /// `nil` rather than a default, for the same reason ``MarkdownBlock/line`` is optional: a
    /// single line with no terminator genuinely has no line ending, and answering "LF" would be a
    /// claim about bytes that are not there. The status line omits the segment instead.
    static func detect(in text: String) -> EditorLineEnding? {
        var sawLF = false, sawCRLF = false, sawCR = false
        var previousWasCR = false
        for unit in text.unicodeScalars {
            switch unit {
            case "\r":
                // Not counted yet: a lone CR and the CR of a CRLF are the same scalar, and which
                // one it is depends on the NEXT one. Deciding here is the classic off-by-one that
                // reports every CRLF file as mixed.
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
    /// 1-based, counted in **characters** rather than UTF-16 units — an emoji is one column, not
    /// two, because the column is a claim about where the caret looks like it is.
    var column: Int

    /// The caret's position, given an offset into `text`'s UTF-16 view.
    ///
    /// **UTF-16 in, characters out, and the asymmetry is the point.** `NSTextView` reports
    /// selections as `NSRange`, which is UTF-16, so that is what the caller has; a person reads
    /// columns in characters. Converting at this one seam is what stops a `column` that jumps by
    /// two through an emoji or by four through a family sequence.
    static func at(utf16Offset offset: Int, in text: String) -> EditorCaret {
        var line = 1
        var column = 1
        var consumed = 0
        guard offset > 0 else { return EditorCaret(line: 1, column: 1) }
        // **One pass over Characters, counting UTF-16 as it goes** — rather than converting the
        // offset to a `String.Index` first, which has no answer at all when the offset lands inside
        // a surrogate pair. Here such an offset simply consumes the whole character, which is the
        // position the caret can actually occupy.
        for character in text {
            if consumed >= offset { break }
            consumed += character.utf16.count
            // `"\r\n"` is ONE Character in Swift, which is what makes this three comparisons
            // rather than a state machine: the pair cannot be split across two iterations.
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
    /// **The inverse of ``at(utf16Offset:in:)``, and it has to be exact rather than close.** It is
    /// what turns an outline row into a scroll and a "go to line" into a caret, and an offset one
    /// character out puts the caret at the end of the line before — which reads as the feature
    /// being off by one every time.
    ///
    /// `nil` rather than clamping to the end: a caller asking for line 900 of a 400-line file has
    /// made a mistake worth reporting, and silently landing at the end would hide it.
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
/// **Built once off the main actor; asked thousands of times on it.** ``EditorCaret/at(utf16Offset:in:)``
/// and ``EditorCaret/utf16Offset(ofLine:in:)`` each walk the buffer from index 0, breaking graphemes
/// as they go. That is the right shape for a one-off question and the wrong shape for the split's
/// scroll sync, which asks "which line is at the top?" on every clip-view bounds notification — once
/// per scrolled row, and once per keystroke at the end of a long file, because typing there
/// autoscrolls. On a 4 MiB document that walk is the whole document, on the main thread, per frame.
///
/// So the walk happens once, in the task that already walks the buffer for the status line's counts,
/// and the answers come out of a binary search.
///
/// **Slightly stale is fine for scroll sync and NOT fine for the caret**, which is why
/// ``utf16Length`` is carried: the table is rebuilt on the same 150 ms debounce as the facts, so
/// between a keystroke and that rebuild it describes the buffer as it was. A preview that follows
/// the text by a line or two during a burst of typing is invisible; a caret sent to the wrong
/// offset by an outline click is the feature being off by one. Callers that need exactness check
/// the length first and fall back to the exact walk when it disagrees.
struct EditorLineIndex: Equatable, Sendable {

    /// The UTF-16 offset each 1-based line begins at. Always starts with `0`, so an empty buffer
    /// still has a line 1 that begins at 0 — which is what ``EditorCaret/utf16Offset(ofLine:in:)``
    /// answers for the same input.
    private(set) var lineStarts: [Int]
    /// The UTF-16 offset each line **terminator** begins at, in order. One shorter than
    /// ``lineStarts`` by construction.
    private(set) var terminatorStarts: [Int]
    /// The length of the text this describes, in UTF-16 units — the staleness check.
    private(set) var utf16Length: Int

    static let empty = EditorLineIndex(lineStarts: [0], terminatorStarts: [], utf16Length: 0)

    /// Walks `text` once, applying exactly ``EditorCaret``'s rules.
    ///
    /// `"\r\n"` is ONE `Character` in Swift, which is what makes three comparisons enough rather
    /// than a state machine — the same fact ``EditorCaret/at(utf16Offset:in:)`` relies on, and the
    /// same fact that makes `hasSuffix("\n")` false for a CRLF file.
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

    /// The 1-based line an offset falls on — the answer ``EditorCaret/at(utf16Offset:in:)`` gives.
    ///
    /// **A terminator counts once the offset is past its FIRST unit**, which is what makes this
    /// agree with the walk on an offset landing between the `\r` and the `\n` of a CRLF: the walk
    /// consumes the whole two-unit character and lands on the next line, because that is the
    /// position the caret can actually occupy.
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

    /// Where a 1-based line begins, or `nil` when the text has no such line — the answer
    /// ``EditorCaret/utf16Offset(ofLine:in:)`` gives.
    func utf16Offset(ofLine target: Int) -> Int? {
        guard target >= 1, target <= lineStarts.count else { return nil }
        return lineStarts[target - 1]
    }
}

/// What the status line says about the open buffer.
///
/// **Derived, never stored.** Every field here is a function of the text and the selection, so
/// there is nothing to keep in step and nothing that can go stale — the cost is that computing it
/// walks the buffer, which is why the host does it on a debounce off the main actor rather than in
/// a body pass. See ``EditorWorkspaceView`` for that task.
struct EditorDocumentFacts: Equatable, Sendable {

    /// Runs of non-whitespace.
    ///
    /// **Markup counts as words, and that is the honest simple answer.** A `##` at the head of a
    /// line is a word by this count. Excluding it would mean deciding what markup *is* — which the
    /// preview's parser knows and this does not — and would give two different numbers for the
    /// same file depending on whether it happened to be Markdown. One rule, stated on the label.
    var words: Int
    /// Characters as a person counts them: grapheme clusters, so an emoji is one.
    var characters: Int
    /// Lines, counting a final line with no terminator. An empty buffer is 0 lines, not 1 — there
    /// is nothing in it to be a line.
    var lines: Int
    var lineEnding: EditorLineEnding?
    /// How the bytes were decoded, or `nil` for a document that was never decoded at all.
    var encoding: String?

    static let empty = EditorDocumentFacts(words: 0, characters: 0, lines: 0,
                                           lineEnding: nil, encoding: nil)

    /// `1 word` / `412 words`, grouped for reading.
    ///
    /// **Singular is not a nicety here.** The status line is beside a document somebody is typing
    /// into, so it passes through 1 on the way to everything else, and "1 words" is the kind of
    /// thing that is noticed once and remembered.
    var wordsCaption: String { Self.count(words, "word") }
    var charactersCaption: String { Self.count(characters, "character") }

    /// **Static, so a caller holding only the number can say it the same way.** The divergence
    /// diff's left column is `In the editor · 1,204 words` and has no facts value to ask — a second
    /// spelling of the same rule there is how "1 words" gets back in through a door nobody watches.
    static func count(_ value: Int, _ noun: String) -> String {
        "\(value.formatted(.number)) \(noun)\(value == 1 ? "" : "s")"
    }

    static func of(_ text: String, encoding: String?) -> EditorDocumentFacts {
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
        return EditorDocumentFacts(words: words,
                                   characters: characters,
                                   lines: lineCount(of: text),
                                   lineEnding: EditorLineEnding.detect(in: text),
                                   encoding: encoding)
    }

    /// **A trailing newline does not open a new line.** `"a\n"` is one line, not two — which is the
    /// opposite of what splitting on the separator answers, and the reason this is a count rather
    /// than a `components(separatedBy:).count`.
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
        // The count above counted the terminator; a text that ENDS with one has no line after it.
        //
        // **`text.last`, not `hasSuffix`.** `String` compares by grapheme cluster and `"\r\n"` is
        // ONE of those, so `hasSuffix("\n")` is false for every CRLF file on earth — which made a
        // Windows file report one line too many while the LF file beside it was right. The same
        // fact makes the three comparisons below sufficient rather than a state machine.
        if let last = text.last, last == "\n" || last == "\r\n" || last == "\r" { lines -= 1 }
        return max(lines, 1)
    }
}
