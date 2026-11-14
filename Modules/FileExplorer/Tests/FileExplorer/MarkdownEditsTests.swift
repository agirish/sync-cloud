import Testing
import Foundation
@testable import FileExplorer

/// Edits made to somebody's file by a click rather than by typing.
///
/// The bar is character-for-character. These functions write to real files in real cloud folders,
/// so "it looked right in the preview" is not the standard: every case asserts the whole buffer,
/// including the lines that must not move.
@Suite struct MarkdownEditsTests {

    // MARK: Ticking

    /// Every case asserts the whole buffer after the tick, or `nil` where the click must change
    /// nothing.
    @Test(arguments: [
        ("- [ ] one\n- [ ] two\n", 1, "- [x] one\n- [ ] two\n"),
        ("- [ ] one\n- [ ] two\n", 2, "- [ ] one\n- [x] two\n"),
        ("- [x] one\n", 1, "- [ ] one\n"),
        // GFM accepts a capital and other tools write one; the flip normalises it to lowercase.
        ("- [X] one\n", 1, "- [ ] one\n"),
        // Indented and numbered items, and every bullet.
        ("    - [ ] nested\n", 1, "    - [x] nested\n"),
        ("1. [ ] first\n", 1, "1. [x] first\n"),
        ("12) [ ] twelfth\n", 1, "12) [x] twelfth\n"),
        ("* [ ] star\n", 1, "* [x] star\n"),
        ("+ [ ] plus\n", 1, "+ [x] plus\n"),
        // Read a Character at a time: `isNumber` is Unicode's, so another script's digit numbers an
        // item, and a combining mark joins the character before it, so `[ \u{301}]` holds no box.
        ("\u{663}. [ ] three\n", 1, "\u{663}. [x] three\n"),
        ("\u{1D7D9}. [x] one\n", 1, "\u{1D7D9}. [ ] one\n"),
        ("- [ \u{301}] mark\n", 1, nil),
        ("- [x\u{301}] mark\n", 1, nil),
        // Real GFM, not a pattern: a bracket pair in prose is not a checkbox.
        ("See [ ] for the blank.\n", 1, nil),
        ("A sentence with - [ ] inside it.\n", 1, nil),
        // `-[x]` is not a task item to any parser.
        ("-[ ] tight\n", 1, nil),
        ("- [link](url)\n", 1, nil),
        ("- [] empty\n", 1, nil),
        // A click can arrive up to a debounce after the buffer changed, naming a line that no
        // longer holds a checkbox: refused, so it writes no `[x]` into whatever is there now.
        ("- [ ] one\nplain prose now\n", 2, nil),
        ("- [ ] one\n", 90, nil),
        ("- [ ] one\n", 0, nil),
        // Nothing outside the three characters moves: the line's trailing content, a Windows
        // file's line endings.
        ("# Notes\r\n\r\n- [ ] one **bold**\r\n- [x] two\r\n", 3, "# Notes\r\n\r\n- [x] one **bold**\r\n- [x] two\r\n"),
        // The last line with no terminator is still a line.
        ("- [ ] one\n- [ ] two", 2, "- [ ] one\n- [x] two"),
    ] as [(String, Int, String?)])
    func aTickRewritesOnlyTheBox(_ text: String, line: Int, expected: String?) {
        #expect(MarkdownEdits.toggleTask(onLine: line, in: text) == expected, "\(text.debugDescription) line \(line)")
    }

    // MARK: Line ranges

    private func line(_ target: Int, of text: String) -> String? {
        MarkdownEdits.lineRange(of: target, in: text as NSString).map { (text as NSString).substring(with: $0) }
    }

    @Test func lineRangesCoverTheLineWithoutItsTerminator() {
        let text = "one\ntwo\nthree"
        #expect(line(1, of: text) == "one")
        #expect(line(2, of: text) == "two")
        #expect(line(3, of: text) == "three")
        #expect(line(4, of: text) == nil)
        #expect(line(0, of: text) == nil)
    }

    @Test func aCRLFLineRangeStopsBeforeBothCharacters() {
        let text = "one\r\ntwo\r\n"
        #expect(line(1, of: text) == "one")
        #expect(line(2, of: text) == "two")
        #expect(line(3, of: text) == "", "the empty line after the last terminator")
        #expect(line(4, of: text) == nil)
    }

    /// A lone CR ends a line, and a CR before a CRLF ends one too: the chunked walk's only state.
    @Test func loneCarriageReturnsEndLinesAsTheyDoInTheLineIndex() {
        let text = "a\rb\r\r\nc"
        #expect([1, 2, 3, 4].map { line($0, of: text) } == ["a", "b", "", "c"])
        #expect(line(5, of: text) == nil)
    }

    /// A CRLF split across two chunks is still one line ending. The walk reads
    /// ``MarkdownEdits/lineScanChunk`` units at a time, and the CR and LF can fall either side.
    @Test(arguments: [MarkdownEdits.lineScanChunk - 2, MarkdownEdits.lineScanChunk - 1, MarkdownEdits.lineScanChunk])
    func aCRLFAcrossAChunkBoundaryIsOneEnding(_ firstLineLength: Int) {
        let text = String(repeating: "x", count: firstLineLength) + "\r\n- [ ] two\r\nthree"
        #expect(line(2, of: text) == "- [ ] two")
        #expect(line(3, of: text) == "three")
        #expect(MarkdownEdits.toggleTask(onLine: 2, in: text)
                == String(repeating: "x", count: firstLineLength) + "\r\n- [x] two\r\nthree")
        // A lone CR in the same places ends its line just the same.
        let lone = String(repeating: "x", count: firstLineLength) + "\r- [ ] two\rthree"
        #expect(line(2, of: lone) == "- [ ] two")
        #expect(line(3, of: lone) == "three")
    }

    /// The tick reads the document only as far as its line, counted in units read rather than
    /// timed: a box on line 2 of a 1 MB document reads one chunk of it, not the whole document.
    @Test func aTickNearTheTopReadsOneChunkOfALongDocument() throws {
        let text = CountingString.of("# Title\n- [ ] milk\n" + String(repeating: "filler line\n", count: 90_000))
        let change = try #require(MarkdownEdits.taskToggle(onLine: 2, in: text))
        #expect(change.range == NSRange(location: 11, length: 1) && change.text == "x")
        #expect(text.unitsRead <= MarkdownEdits.lineScanChunk + 32,
                "a tick on line 2 read \(text.unitsRead) of \(text.length) units")
    }
}

extension MarkdownEdits {
    /// The whole text after a tick, so these cases can assert every line of it: the edit
    /// ``taskToggle(onLine:in:)`` answers, applied.
    static func toggleTask(onLine target: Int, in text: String) -> String? {
        let text = text as NSString
        guard let change = taskToggle(onLine: target, in: text) else { return nil }
        return text.replacingCharacters(in: change.range, with: change.text)
    }
}

/// An `NSString` that counts the UTF-16 units read out of it.
///
/// No initializer of its own, and `base` is set after: a Swift subclass of `NSString` that declares
/// one must also provide `init(stringLiteral:)`, which Foundation declares in an extension where it
/// can't be overridden. Declaring none inherits them all.
private final class CountingString: NSString {
    var base: NSString = ""
    private(set) var unitsRead = 0

    static func of(_ text: String) -> CountingString {
        let counting = CountingString()
        counting.base = text as NSString
        return counting
    }

    override var length: Int { base.length }

    override func character(at index: Int) -> unichar {
        unitsRead += 1
        return base.character(at: index)
    }

    override func getCharacters(_ buffer: UnsafeMutablePointer<unichar>, range: NSRange) {
        unitsRead += range.length
        base.getCharacters(buffer, range: range)
    }
}
