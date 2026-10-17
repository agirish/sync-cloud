import Testing
import Foundation
@testable import FileExplorer

/// Edits made to somebody's file by a click rather than by typing.
///
/// **The bar here is character-for-character.** These functions write to real files in real cloud
/// folders, so "it looked right in the preview" is not the standard — every case asserts the whole
/// buffer, including the lines that must not have moved.
@Suite struct MarkdownEditsTests {

    // MARK: Ticking

    @Test func anUntickedBoxBecomesTicked() {
        let source = "- [ ] one\n- [ ] two\n"
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: source) == "- [x] one\n- [ ] two\n")
        #expect(MarkdownEdits.toggleTask(onLine: 2, in: source) == "- [ ] one\n- [x] two\n")
    }

    @Test func aTickedBoxBecomesUnticked() {
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "- [x] one\n") == "- [ ] one\n")
    }

    /// GFM accepts a capital and other tools write one; the flip has to recognise it, and it
    /// normalises to the lowercase the app writes everywhere else.
    @Test func aCapitalXIsRecognisedAndNormalised() {
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "- [X] one\n") == "- [ ] one\n")
    }

    @Test func indentedAndNumberedItemsAreBothHandled() {
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "    - [ ] nested\n")
                == "    - [x] nested\n")
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "1. [ ] first\n") == "1. [x] first\n")
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "12) [ ] twelfth\n") == "12) [x] twelfth\n")
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "* [ ] star\n") == "* [x] star\n")
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "+ [ ] plus\n") == "+ [x] plus\n")
    }

    /// The whole reason the walk parses real GFM rather than pattern-matching: a bracket pair in
    /// prose is not a checkbox, and this must not turn one into an `[x]`.
    @Test func aBracketPairInProseIsLeftAlone() {
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "See [ ] for the blank.\n") == nil)
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "A sentence with - [ ] inside it.\n") == nil)
    }

    /// `-[x]` is not a task item to any parser, so it must not become one here.
    @Test func aMarkerWithNoSpaceIsNotATaskItem() {
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "-[ ] tight\n") == nil)
    }

    @Test func aNonCheckboxBracketAfterAMarkerIsLeftAlone() {
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "- [link](url)\n") == nil)
        #expect(MarkdownEdits.toggleTask(onLine: 1, in: "- [] empty\n") == nil)
    }

    /// A click can arrive up to a debounce after the buffer changed, naming a line that no longer
    /// holds a checkbox. Refusing is what stops it writing an `[x]` into whatever is there now.
    @Test func aStaleClickChangesNothing() {
        #expect(MarkdownEdits.toggleTask(onLine: 2, in: "- [ ] one\nplain prose now\n") == nil)
        #expect(MarkdownEdits.toggleTask(onLine: 90, in: "- [ ] one\n") == nil)
        #expect(MarkdownEdits.toggleTask(onLine: 0, in: "- [ ] one\n") == nil)
    }

    /// Nothing outside the three characters moves — including the line's own trailing content and
    /// the line endings of a file that came from Windows.
    @Test func onlyTheBoxIsRewritten() {
        let crlf = "# Notes\r\n\r\n- [ ] one **bold**\r\n- [x] two\r\n"
        #expect(MarkdownEdits.toggleTask(onLine: 3, in: crlf)
                == "# Notes\r\n\r\n- [x] one **bold**\r\n- [x] two\r\n")
    }

    @Test func theLastLineWithNoTerminatorIsStillALine() {
        #expect(MarkdownEdits.toggleTask(onLine: 2, in: "- [ ] one\n- [ ] two")
                == "- [ ] one\n- [x] two")
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

    /// A lone CR ends a line, and a CR before a CRLF ends one too — the chunked walk's only state.
    @Test func loneCarriageReturnsEndLinesAsTheyDoInTheLineIndex() {
        let text = "a\rb\r\r\nc"
        #expect([1, 2, 3, 4].map { line($0, of: text) } == ["a", "b", "", "c"])
        #expect(line(5, of: text) == nil)
    }

    /// **A CRLF split across two chunks is still one line ending.** The walk reads
    /// ``MarkdownEdits/lineScanChunk`` units at a time, and the CR and the LF can fall either side.
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

    // MARK: The tick before P52, as the oracle

    /// **Every tick makes exactly the edit the old tick made** — the same range and the same
    /// character, or the same refusal. Thousands of generated documents with every line ending,
    /// combining marks next to the box and its brackets, emoji, tabs and digits that are not ASCII,
    /// each ticked on every line and one past the end, against ``PreP52Tick`` — the code this
    /// replaced, copied verbatim. Compared by UTF-16 unit, because `==` on two Strings would call
    /// `é` and `e` + U+0301 the same.
    @Test func everyTickMakesTheEditTheOldTickMade() {
        var random = SeededGenerator(seed: 52)   // TextPairDiffMyersTests' SplitMix64
        let pieces = ["- ", "* ", "+ ", "1. ", "12) ", "\u{663}. ", "\u{1D7D9}. ", "- [ ] ", "- [x] ", "- [X] ", "[ ]", "[x]", "[",
                      "]", " ", "\t", "-", "x", "a", "\u{E9}", "e\u{301}", "\u{301}", "[\u{301}]", "[ \u{301}]",
                      "\u{1F44D}\u{1F3FD}", "\n", "\n", "\r\n", "\r"]
        var cases = 0
        var flips = 0
        var mismatches: [String] = []
        for _ in 0..<4_000 {
            let text = (0..<Int.random(in: 1...14, using: &random))
                .map { _ in pieces.randomElement(using: &random)! }.joined()
            let lines = text.filter { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }.count + 1
            for target in 0...(lines + 1) {
                let old = PreP52Tick.toggleTask(onLine: target, in: text)
                    .map { MarkdownEdits.minimalReplacement(from: text, to: $0) }
                let new = MarkdownEdits.taskToggle(onLine: target, in: text as NSString)
                let same = switch (old, new) {
                case (nil, nil): true
                case let (old?, new?): old.range == new.range && old.text.utf16.elementsEqual(new.text.utf16)
                default: false
                }
                if !same {
                    mismatches.append("line \(target) of \(text.debugDescription): was \(String(describing: old)), now \(String(describing: new))")
                }
                cases += 1
                if new != nil { flips += 1 }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(cases) ticks differ, e.g. \(mismatches.prefix(5))")
        // Both halves have to be exercised: refusals are most cases, and flips are the ones that write.
        #expect(cases > 12_000 && flips > 1_000, "the generator no longer means anything: \(cases) cases, \(flips) flips")
    }

    /// **The tick reads the document only as far as its line** — the speed half of P52, counted in
    /// units read rather than timed. A box on line 2 of a 1 MB document reads one chunk of it; the
    /// tick it replaced copied and walked all of it.
    @Test func aTickNearTheTopReadsOneChunkOfALongDocument() throws {
        let text = CountingString.of("# Title\n- [ ] milk\n" + String(repeating: "filler line\n", count: 90_000))
        let change = try #require(MarkdownEdits.taskToggle(onLine: 2, in: text))
        #expect(change.range == NSRange(location: 11, length: 1) && change.text == "x")
        #expect(text.unitsRead <= MarkdownEdits.lineScanChunk + 32,
                "a tick on line 2 read \(text.unitsRead) of \(text.length) units")
    }
}

extension MarkdownEdits {
    /// The whole text after a tick, so these cases can assert every line of it — the edit
    /// ``taskToggle(onLine:in:)`` answers, applied.
    static func toggleTask(onLine target: Int, in text: String) -> String? {
        let text = text as NSString
        guard let change = taskToggle(onLine: target, in: text) else { return nil }
        return text.replacingCharacters(in: change.range, with: change.text)
    }
}

/// An `NSString` that counts the UTF-16 units read out of it.
///
/// **No initializer of its own, and `base` is set after**: a Swift subclass of `NSString` that
/// declares one must also provide `init(stringLiteral:)`, which Foundation declares in an extension
/// where it cannot be overridden. Declaring none inherits them all.
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

/// **`MarkdownEdits.toggleTask` and `lineRange` as they were before P52, verbatim** — a String
/// walked a Character at a time and rewritten whole. Kept as the oracle the new tick is held to.
private enum PreP52Tick {
    static func toggleTask(onLine target: Int, in text: String) -> String? {
        guard let range = lineRange(of: target, in: text) else { return nil }
        let line = String(text[range])
        guard let flipped = flippedCheckbox(in: line) else { return nil }
        return text.replacingCharacters(in: range, with: flipped)
    }

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
        return line == target ? start..<text.endIndex : nil
    }

    private static func flippedCheckbox(in line: String) -> String? {
        var index = line.startIndex
        func skipWhitespace() {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" {
                index = line.index(after: index)
            }
        }
        skipWhitespace()
        guard index < line.endIndex else { return nil }
        if line[index] == "-" || line[index] == "*" || line[index] == "+" {
            index = line.index(after: index)
        } else if line[index].isNumber {
            while index < line.endIndex, line[index].isNumber { index = line.index(after: index) }
            guard index < line.endIndex, line[index] == "." || line[index] == ")" else { return nil }
            index = line.index(after: index)
        } else {
            return nil
        }
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
