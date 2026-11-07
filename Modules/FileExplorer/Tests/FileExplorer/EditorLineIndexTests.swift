import Testing
import Foundation
@testable import FileExplorer

/// The line table, held against the walks it replaced. `EditorLineIndex` answers what
/// `EditorCaret` answers by walking the buffer (which line an offset is on, where a line begins),
/// for the split's scroll sync and the outline's caret. Any disagreement is the editor off by one,
/// so every case asks both, at every offset and every line, across CRLF, CR and emoji samples.
@Suite struct EditorLineIndexTests {

    /// Inputs that break line maths, plus the ordinary ones. `"\r\n"` is one `Character` in Swift,
    /// so `hasSuffix("\n")` is false for a CRLF file and an offset can land inside a terminator.
    private static let samples: [(name: String, text: String)] = [
        ("empty", ""),
        ("one line, no terminator", "hello"),
        ("one line, LF", "hello\n"),
        ("two lines, LF", "one\ntwo"),
        ("trailing LF", "one\ntwo\n"),
        ("blank lines", "\n\n\na\n\n"),
        ("CRLF", "one\r\ntwo\r\nthree"),
        ("CRLF, trailing", "one\r\ntwo\r\n"),
        ("lone CR", "one\rtwo\rthree"),
        ("mixed endings", "one\r\ntwo\nthree\rfour"),
        ("emoji", "a😀b\n😀\nc"),
        ("family sequence", "👨‍👩‍👧‍👦\nnext\n"),
        ("combining marks", "e\u{0301}cole\ncafe\u{0301}\n"),
        ("emoji astride a CRLF", "😀\r\n😀\r\n"),
        ("only a terminator", "\n"),
        ("only a CRLF", "\r\n"),
        ("nothing but CRs", "\r\r\r"),
    ]

    /// Every UTF-16 offset, including those inside a surrogate pair or a CRLF: an `NSTextView`
    /// reports selections in UTF-16, and for a mid-character offset the walk consumes the whole
    /// character. The table must make the same choice.
    @Test func theTableAgreesWithTheWalkAtEveryOffset() {
        for sample in Self.samples {
            let index = EditorLineIndex(text: sample.text)
            let length = (sample.text as NSString).length
            #expect(index.utf16Length == length,
                    "\(sample.name): the table measured \(index.utf16Length) against \(length)")
            // Past the end as well: `characterIndexForInsertion(at:)` can answer with the length.
            for offset in 0...(length + 2) {
                let walked = EditorCaret.at(utf16Offset: offset, in: sample.text).line
                let looked = index.line(atUTF16Offset: offset)
                #expect(walked == looked,
                        "\(sample.name): offset \(offset) walked to line \(walked), table said \(looked)")
            }
        }
    }

    /// The inverse, over every line the buffer has and a few it doesn't. `nil` out of range is part
    /// of the contract: asking for line 900 of a 400-line file is a mistake that landing at the end
    /// would hide.
    @Test func theTableAgreesWithTheWalkForEveryLineStart() {
        for sample in Self.samples {
            let index = EditorLineIndex(text: sample.text)
            for line in -1...(EditorDocumentFacts.lineCount(of: sample.text) + 3) {
                let walked = EditorCaret.utf16Offset(ofLine: line, in: sample.text)
                let looked = index.utf16Offset(ofLine: line)
                let report = "\(sample.name): line \(line) walked to \(String(describing: walked)),"
                    + " table said \(String(describing: looked))"
                #expect(walked == looked, "\(report)")
            }
        }
    }

    /// The positive control for the two tests above: the samples span several lines, so "they
    /// agree" covers a range of answers, not a constant both sides could return.
    @Test func theSamplesReallyExerciseMoreThanOneLine() {
        let lines = Self.samples.map { EditorLineIndex(text: $0.text).lineStarts.count }
        #expect(lines.contains { $0 >= 4 }, "no sample has four lines: \(lines)")
        #expect(lines.contains { $0 == 1 }, "no sample is a single line: \(lines)")
        let crlf = EditorLineIndex(text: "one\r\ntwo")
        #expect(crlf.line(atUTF16Offset: 4) == 2,
                "an offset between the CR and the LF did not land on the next line")
        #expect(crlf.utf16Offset(ofLine: 2) == 5, "line 2 does not begin after the whole CRLF")
    }

    /// The caret path rejects a table built from another buffer, told apart by its length. The
    /// table is rebuilt on the status line's debounce, so a request arriving with the text it names
    /// (opening a file straight at a heading) would otherwise use the previous document's lines.
    @Test func theCaretPathFallsBackToTheWalkWhenTheTableDescribesAnotherBuffer() {
        let stale = EditorLineIndex(text: "one\ntwo\nthree\n")
        let now = "a\nb\nc\nd\ne\n"
        // Line 5 does not exist in the stale table at all; the walk finds it in the current text.
        #expect(stale.utf16Offset(ofLine: 5) == nil)
        #expect(EditorCaret.utf16Offset(ofLine: 5, in: now) == 8)
        #expect(PlainTextEditor.utf16Offset(ofLine: 5, in: now, using: stale) == 8,
                "a table describing another buffer was trusted for a caret")
        // A line both describe: the stale table says 4, the buffer 2, so trusting the table would
        // be silently wrong rather than absent.
        #expect(stale.utf16Offset(ofLine: 2) == 4)
        #expect(PlainTextEditor.utf16Offset(ofLine: 2, in: now, using: stale) == 2)
        // And where the table does describe the buffer, it is used and gives the same answer.
        let fresh = EditorLineIndex(text: now)
        #expect(PlainTextEditor.utf16Offset(ofLine: 4, in: now, using: fresh)
                == EditorCaret.utf16Offset(ofLine: 4, in: now))
    }
}
