import Testing
import Foundation
@testable import FileExplorer

/// The line table, held against the walks it replaced.
///
/// **Equivalence is the whole test, so it is asserted rather than argued.** `EditorLineIndex` exists
/// only to answer two questions `EditorCaret` already answers by walking the buffer from index 0 —
/// which line an offset is on, and where a line begins. The table is what the split's scroll sync
/// and the outline's caret now read, so a table that disagrees with the walk is the editor being off
/// by one in the two places a reader would notice immediately.
///
/// So every case below asks BOTH, at every offset and for every line, and compares. A table that
/// agreed with the walk only on ASCII with LF endings would pass a hand-picked assertion and fail
/// on the first file that arrived from Windows.
@Suite struct EditorLineIndexTests {

    /// The inputs that have historically broken line maths in this repo, plus the ordinary ones.
    ///
    /// `"\r\n"` is ONE `Character` in Swift — the fact that makes `hasSuffix("\n")` false for every
    /// CRLF file on earth, and the reason an offset can land *inside* a line terminator.
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

    /// **Every UTF-16 offset, including the ones inside a surrogate pair and inside a CRLF.**
    ///
    /// Those two are the interesting ones: an `NSTextView` reports selections in UTF-16, and the
    /// walk's documented behaviour for an offset that lands mid-character is to consume the whole
    /// character — "the position the caret can actually occupy". The table has to make the same
    /// choice, and the only way to know it does is to ask at every offset rather than at the ones
    /// that look like boundaries.
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

    /// The inverse, over every line the buffer has and two it does not.
    ///
    /// **`nil` past the end is part of the contract**, not an accident: a caller asking for line 900
    /// of a 400-line file has made a mistake worth reporting, and silently landing at the end would
    /// hide it. So the out-of-range cases are asserted rather than skipped.
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

    /// The positive control the two tests above need.
    ///
    /// **Without it, a table that answered `1` to everything would agree with a walk that also
    /// answered `1` to everything on a one-line sample and be caught by nothing.** This pins that
    /// the samples really do span several lines and several offsets, so "they agree" is a claim
    /// about a range of answers rather than about a constant.
    @Test func theSamplesReallyExerciseMoreThanOneLine() {
        let lines = Self.samples.map { EditorLineIndex(text: $0.text).lineStarts.count }
        #expect(lines.contains { $0 >= 4 }, "no sample has four lines: \(lines)")
        #expect(lines.contains { $0 == 1 }, "no sample is a single line: \(lines)")
        let crlf = EditorLineIndex(text: "one\r\ntwo")
        #expect(crlf.line(atUTF16Offset: 4) == 2,
                "an offset between the CR and the LF did not land on the next line")
        #expect(crlf.utf16Offset(ofLine: 2) == 5, "line 2 does not begin after the whole CRLF")
    }

    /// A table built from one buffer must be rejected by the caret path when it is shown another.
    ///
    /// **The caret cannot take a stale answer, and the length is what says so.** The table is
    /// rebuilt on the status line's 150 ms debounce, so a scroll request arriving in the same render
    /// pass as the text it names — opening a file straight at a heading — would otherwise be
    /// answered against the previous document's line starts.
    @Test func theCaretPathFallsBackToTheWalkWhenTheTableDescribesAnotherBuffer() {
        let stale = EditorLineIndex(text: "one\ntwo\nthree\n")
        let now = "a\nb\nc\nd\ne\n"
        // Line 5 does not exist in the stale table at all; the walk finds it in the current text.
        #expect(stale.utf16Offset(ofLine: 5) == nil)
        #expect(EditorCaret.utf16Offset(ofLine: 5, in: now) == 8)
        #expect(PlainTextEditor.utf16Offset(ofLine: 5, in: now, using: stale) == 8,
                "a table describing another buffer was trusted for a caret")
        // And a line BOTH describe: the stale table's answer for line 2 is 4, the buffer's is 2,
        // so taking the table here would be silently wrong rather than absent.
        #expect(stale.utf16Offset(ofLine: 2) == 4)
        #expect(PlainTextEditor.utf16Offset(ofLine: 2, in: now, using: stale) == 2)
        // And where the table does describe the buffer, it is used and gives the same answer.
        let fresh = EditorLineIndex(text: now)
        #expect(PlainTextEditor.utf16Offset(ofLine: 4, in: now, using: fresh)
                == EditorCaret.utf16Offset(ofLine: 4, in: now))
    }
}
