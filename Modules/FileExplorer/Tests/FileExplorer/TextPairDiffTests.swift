import Foundation
import Sync
import Testing
@testable import FileExplorer

/// The bounded reader and the line diff behind the text compare pane.
@Suite struct TextPairDiffTests {

    // MARK: The reader

    private final class Fixture {
        let dir: URL
        init() throws {
            dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("TextPairDiffTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        func write(_ name: String, _ data: Data) throws -> String {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return url.path
        }
    }

    @Test func anOrdinaryFileReadsExactly() throws {
        let fixture = try Fixture()
        let path = try fixture.write("a.txt", Data("one\ntwo\n".utf8))
        #expect(BoundedTextRead.read(path: path, isCloudOnly: { _ in false })
                    == .text("one\ntwo\n", lossy: false, encoding: .utf8))
    }

    /// **The LogViewer trap, designed out rather than caught late.** `String(contentsOf:)` throws
    /// on invalid UTF-8, so a rotated log truncated mid-character came back as an error with its
    /// readable 99% sitting on disk. A lossy decode is a file with a few replacement characters
    /// in it, which is what the reader wants — and the lossiness is disclosed, because a diff of
    /// two lossily decoded files can show a difference that is really two invalid sequences.
    @Test func aTruncatedMultibyteTailDecodesLossilyAndSaysSo() throws {
        let fixture = try Fixture()
        var bytes = Data("héllo\n".utf8)
        bytes.append(0xC3)   // a lead byte with no continuation — the truncated tail
        let path = try fixture.write("bad.txt", bytes)
        let outcome = BoundedTextRead.read(path: path, isCloudOnly: { _ in false })
        guard case .text(let text, let lossy, _) = outcome else {
            Issue.record("expected text, got \(outcome)")
            return
        }
        #expect(lossy, "an invalid tail decoded without being disclosed as lossy")
        #expect(text.hasPrefix("héllo"), "the readable part was lost with the unreadable byte")
    }

    /// **The cloud-only check comes FIRST**, before the size read and before the open: opening a
    /// placeholder is what makes the provider fetch the whole file, which for a compare pane is a
    /// multi-gigabyte transfer nobody asked for.
    @Test func aCloudOnlyPlaceholderIsNeverOpened() throws {
        let fixture = try Fixture()
        let path = try fixture.write("cloud.txt", Data("real content".utf8))
        #expect(BoundedTextRead.read(path: path, isCloudOnly: { _ in true }) == .cloudOnly,
                "the file's content was read despite it being a placeholder")
    }

    @Test func aBinaryFileIsNotOfferedAsLines() throws {
        let fixture = try Fixture()
        let path = try fixture.write("bin", Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x0D, 0x0A]))
        #expect(BoundedTextRead.read(path: path, isCloudOnly: { _ in false }) == .binary)
    }

    @Test func anEmptyFileIsEmptyTextAndNotAFailure() throws {
        let fixture = try Fixture()
        let path = try fixture.write("empty.txt", Data())
        #expect(BoundedTextRead.read(path: path, isCloudOnly: { _ in false })
                    == .text("", lossy: false, encoding: .utf8))
    }

    /// **A UTF-16 file is text, and used to be called binary.** Every ASCII character in one is a
    /// byte pair holding a zero, so the NUL sniff — which runs on the first 8 KB and is right about
    /// PNGs — reported "this is not text" over a file any editor opens, with no mention of the
    /// encoding to act on. Driven for both endiannesses, because the two BOMs are byte-reversed
    /// and a test of one proves nothing about the other.
    @Test(arguments: [(String.Encoding.utf16LittleEndian, [UInt8]([0xFF, 0xFE]),
                       BoundedTextRead.TextEncoding.utf16LittleEndian),
                      (String.Encoding.utf16BigEndian, [UInt8]([0xFE, 0xFF]),
                       BoundedTextRead.TextEncoding.utf16BigEndian)])
    func aUTF16FileIsReadAsTextAndNamesItsEncoding(
        cocoa: String.Encoding, bom: [UInt8], expected: BoundedTextRead.TextEncoding) throws {
        let fixture = try Fixture()
        var bytes = Data(bom)
        bytes.append(try #require("one\ntwo\n".data(using: cocoa)))
        let path = try fixture.write("wide.txt", bytes)
        let outcome = BoundedTextRead.read(path: path, isCloudOnly: { _ in false })
        guard case .text(let text, let lossy, let encoding) = outcome else {
            Issue.record("expected text, got \(outcome)")
            return
        }
        #expect(text == "one\ntwo\n", "the BOM or the decode leaked into the text")
        #expect(!lossy, "a well-formed file was reported as lossily decoded")
        #expect(encoding == expected)
    }

    /// **UTF-32 LE's BOM begins with UTF-16 LE's whole BOM**, so the shorter match must not be
    /// tested first: read as UTF-16, every other character of a UTF-32 file is a NUL.
    @Test func aUTF32FileIsNotMistakenForUTF16() throws {
        let fixture = try Fixture()
        var bytes = Data([0xFF, 0xFE, 0x00, 0x00])
        bytes.append(try #require("hi\n".data(using: .utf32LittleEndian)))
        let path = try fixture.write("wider.txt", bytes)
        let outcome = BoundedTextRead.read(path: path, isCloudOnly: { _ in false })
        #expect(outcome == .text("hi\n", lossy: false, encoding: .utf32LittleEndian))
    }

    /// A UTF-8 BOM is stripped rather than diffed as an invisible first character — and the file
    /// still says it carried one, which is what makes the note below possible.
    @Test func aUTF8BOMIsStrippedAndDisclosed() throws {
        let fixture = try Fixture()
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data("one\n".utf8))
        let path = try fixture.write("bom.txt", bytes)
        #expect(BoundedTextRead.read(path: path, isCloudOnly: { _ in false })
                    == .text("one\n", lossy: false, encoding: .utf8WithBOM))
    }

    /// **A binary file stays binary.** The BOM check runs before the NUL sniff, which is exactly
    /// the ordering that could have let a PNG through — this is the positive control for that.
    @Test func aBOMlessBinaryFileIsStillNotOfferedAsLines() throws {
        let fixture = try Fixture()
        let path = try fixture.write("bin2", Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x0D, 0x0A]))
        #expect(BoundedTextRead.read(path: path, isCloudOnly: { _ in false }) == .binary)
    }

    /// The diff compares DECODED text, so two files whose only difference is the encoding show no
    /// changed rows at all. Only this note tells the reader the bytes differ.
    @Test func differingEncodingsAreDisclosedAndMatchingOnesAreSilent() {
        let note = BoundedTextRead.encodingNote(left: .utf16LittleEndian, right: .utf8)
        #expect(note?.contains("UTF-16 LE") == true)
        #expect(note?.contains("UTF-8") == true)
        #expect(BoundedTextRead.encodingNote(left: .utf8, right: .utf8) == nil,
                "two files read the same way were given a difference to read about")
    }

    /// **A truncated UTF-16 file loses its tail, and has to SAY so.**
    ///
    /// `String(data:encoding:.utf16LittleEndian)` over an odd number of bytes returns the whole
    /// code units and reports nothing — so a rotated UTF-16 log came back as clean text with its
    /// last character quietly missing, and a file holding one stray byte came back as the empty
    /// string. That is the silent-loss failure this type exists to prevent, reached through the
    /// BOM door: the same file read as UTF-8 has always been reported lossy.
    @Test func aTruncatedUTF16FileKeepsWhatItHasAndIsReportedLossy() throws {
        let fixture = try Fixture()
        var bytes = Data([0xFF, 0xFE])
        bytes.append(try #require("hi".data(using: .utf16LittleEndian)))
        bytes.append(0x41)   // half a code unit — a file cut mid-character
        let path = try fixture.write("cut.txt", bytes)
        let outcome = BoundedTextRead.read(path: path, isCloudOnly: { _ in false })
        guard case .text(let text, let lossy, let encoding) = outcome else {
            Issue.record("expected text, got \(outcome)")
            return
        }
        #expect(text.hasPrefix("hi"), "the readable part was lost with the unreadable byte")
        #expect(text.hasSuffix("\u{FFFD}"), "the dropped byte left no mark, so the loss is invisible")
        #expect(lossy, "bytes were dropped and the read called itself exact")
        #expect(encoding == .utf16LittleEndian)
    }

    /// **A BOM that names an encoding the bytes then fail to be** — an unpaired surrogate is a
    /// whole code unit and still not text. The decode fails outright, and the read falls through
    /// to the ordinary path, which finds the NULs and keeps the conservative answer rather than
    /// letting a bad BOM swallow the file.
    @Test func aBOMThatLiesFallsThroughRatherThanSwallowingTheFile() throws {
        let fixture = try Fixture()
        let path = try fixture.write("lying.txt", Data([0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00]))
        #expect(BoundedTextRead.read(path: path, isCloudOnly: { _ in false }) == .binary,
                "a BOM naming an encoding the bytes are not was trusted anyway")
    }

    /// **The notes are built in ONE place, and the reason is the call site rather than the rules.**
    /// Every rule below takes a left and a right, so a caller handing them over the wrong way round
    /// satisfies every test of the rules themselves and tells the reader the UTF-16 file is the
    /// UTF-8 one. The same failure `CompareCopiesSheet.trashTitle` exists as a seam to prevent.
    ///
    /// Asymmetric fixture on purpose: swap the arguments and every assertion here changes.
    @Test func theNotesNameTheSideEachFindingIsAbout() {
        let left = BoundedTextRead.Outcome.text("a\r\nb", lossy: false, encoding: .utf16LittleEndian)
        let right = BoundedTextRead.Outcome.text("a\nb", lossy: true, encoding: .utf8)
        let notes = BoundedTextRead.readingNotes(left: left, right: right)

        let lossy = try? #require(notes.first { $0.contains("\u{FFFD}") })
        #expect(lossy?.hasPrefix("The right file") == true,
                "the lossy decode was reported against the side that decoded cleanly")
        let encoding = try? #require(notes.first { $0.hasPrefix("Encodings differ") })
        #expect(encoding?.contains("UTF-16 LE on the left") == true)
        #expect(encoding?.contains("UTF-8 on the right") == true)
        let endings = try? #require(notes.first { $0.hasPrefix("Line endings differ") })
        #expect(endings?.contains("CRLF on the left") == true)
        #expect(endings?.contains("LF on the right") == true)

        // Two files read the same way, cleanly, with the same endings, have nothing to say.
        let clean = BoundedTextRead.Outcome.text("a\nb", lossy: false, encoding: .utf8)
        #expect(BoundedTextRead.readingNotes(left: clean, right: clean).isEmpty,
                "a note was invented for two files that were read identically")
    }

    @Test func aMissingFileIsUnreadable() {
        #expect(BoundedTextRead.read(path: "/nope/gone.txt", isCloudOnly: { _ in false })
                    == .unreadable)
    }

    /// Each refusal says something a reader can act on — the size, or that the file needs
    /// downloading — rather than one generic failure.
    @Test func everyRefusalCarriesItsOwnReason() throws {
        #expect(BoundedTextRead.Outcome.text("x", lossy: false, encoding: .utf8).caption == nil)
        let large = try #require(BoundedTextRead.Outcome.tooLarge(bytes: 9_000_000).caption)
        #expect(large.contains("MB"))
        #expect(BoundedTextRead.Outcome.cloudOnly.caption?.contains("downloaded") == true)
        #expect(BoundedTextRead.Outcome.binary.caption?.contains("readable as text") == true)
    }

    // MARK: Line endings

    /// **CRLF against LF is a byte difference, not a content difference.** A diff that showed
    /// every line as changed because one file came off Windows would be reporting the encoding as
    /// the finding. The difference is real and IS reported — separately, in one line.
    @Test func crlfAgainstLfDiffsAsIdenticalAndIsNotedSeparately() throws {
        let left = "one\r\ntwo\r\nthree"
        let right = "one\ntwo\nthree"
        let diff = TextPairDiff.make(left: BoundedTextRead.lines(left),
                                     right: BoundedTextRead.lines(right))
        #expect(diff.isIdentical, "a line-ending difference read as \(diff.changedLineCount) changed lines")
        let note = try #require(BoundedTextRead.lineEndingNote(left: left, right: right))
        #expect(note.contains("CRLF"))
        #expect(note.contains("LF"))
        #expect(BoundedTextRead.lineEndingNote(left: right, right: right) == nil)
    }

    // MARK: The diff

    @Test func identicalTextHasNoRegions() {
        let diff = TextPairDiff.make(left: ["a", "b"], right: ["a", "b"])
        #expect(diff.isIdentical)
        #expect(diff.rows.allSatisfy { $0.kind == .same })
        #expect(diff.summary == "The text is identical.")
    }

    /// **The alignment `CollectionDifference` does not give.** A removal facing an insertion is
    /// ONE changed row with both texts on it — not a deleted row above an added one, which the
    /// reader then has to line up by eye.
    @Test func anEditedLineIsOneChangedRowNotADeleteAboveAnAdd() throws {
        let diff = TextPairDiff.make(left: ["alpha", "beta", "gamma"],
                                     right: ["alpha", "BETA", "gamma"])
        #expect(diff.rows.count == 3, "the pane would show \(diff.rows.count) rows for a 3-line file")
        let changed = try #require(diff.rows.first { $0.kind == .changed })
        #expect(changed.left == "beta")
        #expect(changed.right == "BETA")
        #expect(changed.leftNumber == 2 && changed.rightNumber == 2)
        #expect(diff.regions == [1..<2])
    }

    @Test func anInsertedLineIsAddedOnTheRightOnly() throws {
        let diff = TextPairDiff.make(left: ["a", "c"], right: ["a", "b", "c"])
        let added = try #require(diff.rows.first { $0.kind == .added })
        #expect(added.right == "b")
        #expect(added.left == nil)
        #expect(added.leftNumber == nil)
        #expect(diff.rows.filter { $0.kind == .same }.count == 2)
    }

    @Test func aDeletedLineIsRemovedOnTheLeftOnly() throws {
        let diff = TextPairDiff.make(left: ["a", "b", "c"], right: ["a", "c"])
        let removed = try #require(diff.rows.first { $0.kind == .removed })
        #expect(removed.left == "b")
        #expect(removed.right == nil)
    }

    /// **↑/↓ step between regions, not lines.** A twelve-line replacement is one thing that
    /// happened, and twelve stops for it is twelve presses to get past one edit.
    @Test func aRunOfChangedLinesIsOneRegion() {
        let diff = TextPairDiff.make(left: ["a", "1", "2", "3", "z"],
                                     right: ["a", "x", "y", "w", "z"])
        #expect(diff.regions.count == 1)
        #expect(diff.regions.first == 1..<4)
        #expect(diff.changedLineCount == 3)
        #expect(diff.summary == "1 change, 3 lines.")
    }

    @Test func separateEditsAreSeparateRegions() {
        let diff = TextPairDiff.make(left: ["a", "b", "c", "d", "e"],
                                     right: ["a", "B", "c", "D", "e"])
        #expect(diff.regions.count == 2)
        #expect(diff.summary == "2 changes, 2 lines.")
    }

    /// A region running to the end of the file is still a region — the loop that closes regions
    /// on the next `.same` row would drop it without the flush after the walk.
    @Test func aRegionAtTheEndOfTheFileIsClosed() {
        let diff = TextPairDiff.make(left: ["a", "b"], right: ["a", "B"])
        #expect(diff.regions == [1..<2])
    }

    /// A whitespace-only edit is a real edit. Ignoring it would be a policy nobody asked for, on a
    /// surface that exists to say whether two files are the same.
    @Test func aWhitespaceOnlyChangeIsStillAChange() {
        let diff = TextPairDiff.make(left: ["total  = 4"], right: ["total = 4"])
        #expect(!diff.isIdentical)
    }

    @Test func twoEmptyFilesAreIdentical() {
        #expect(TextPairDiff.make(left: [], right: []).isIdentical)
        #expect(TextPairDiff.make(left: [], right: ["a"]).regions == [0..<1])
    }

    // MARK: The intra-line pass

    /// One word changed in a long line has to be findable. A character-level diff of a reflowed
    /// sentence marks nearly everything, which is visually the same as marking nothing.
    @Test func onlyTheChangedWordIsMarked() {
        let (left, right) = TextPairDiff.segments("Total due: $4,120.00 by 15 March",
                                                  "Total due: $9,999.00 by 15 March")
        #expect(left.filter(\.changed).map(\.text) == ["$4,120.00 "])
        #expect(right.filter(\.changed).map(\.text) == ["$9,999.00 "])
    }

    /// **The runs reconstruct the line exactly.** A pane that rendered its own reassembly of a
    /// line would be showing the reader text the file does not contain — a space collapsed here,
    /// an indent lost there, on a surface whose whole claim is fidelity.
    @Test func theSegmentsJoinBackToTheOriginalLine() {
        let line = "    let total  =   4   // trailing"
        let (left, _) = TextPairDiff.segments(line, "different")
        #expect(left.map(\.text).joined() == line)
    }

    /// Adjacent changed words collapse into one highlight rather than five touching ones.
    @Test func adjacentChangedWordsMergeIntoOneRun() {
        let (_, right) = TextPairDiff.segments("a b c d", "a X Y d")
        #expect(right.filter(\.changed).count == 1, "\(right)")
    }

    @Test func anUnchangedLineHasNoMarkedRuns() {
        let (left, right) = TextPairDiff.segments("same line", "same line")
        #expect(left.allSatisfy { !$0.changed })
        #expect(right.allSatisfy { !$0.changed })
    }

    // MARK: Stepping between changes

    /// **The first ↓ goes to the FIRST change.** It used to start the count at region 0 and add
    /// one, so the opening press skipped straight to the second change and the first was reachable
    /// only by wrapping the whole way round — on the one press every reader makes first.
    @Test func theFirstStepDownLandsOnTheFirstChange() {
        #expect(TextPairDiff.steppedRegion(from: nil, direction: 1, count: 5) == 0)
    }

    /// The mirror: stepping up from nowhere is the last change, not the second-to-first.
    @Test func theFirstStepUpLandsOnTheLastChange() {
        #expect(TextPairDiff.steppedRegion(from: nil, direction: -1, count: 5) == 4)
    }

    /// Every position steps to its neighbour, and both ends wrap — the stepper's stated contract.
    @Test func steppingWalksEveryRegionAndWrapsAtBothEnds() {
        #expect(TextPairDiff.steppedRegion(from: 0, direction: 1, count: 3) == 1)
        #expect(TextPairDiff.steppedRegion(from: 1, direction: 1, count: 3) == 2)
        #expect(TextPairDiff.steppedRegion(from: 2, direction: 1, count: 3) == 0)
        #expect(TextPairDiff.steppedRegion(from: 0, direction: -1, count: 3) == 2)
    }

    /// A diff with nothing in it has nowhere to step, and says so rather than returning a position
    /// the pane would then try to scroll to.
    @Test func anIdenticalPairHasNoRegionToStepTo() {
        #expect(TextPairDiff.steppedRegion(from: nil, direction: 1, count: 0) == nil)
        #expect(TextPairDiff.steppedRegion(from: 0, direction: 1, count: 0) == nil)
    }

    /// One change: both directions stay on it rather than stepping off the end.
    @Test func aSingleChangeIsItsOwnNeighbourInBothDirections() {
        #expect(TextPairDiff.steppedRegion(from: nil, direction: 1, count: 1) == 0)
        #expect(TextPairDiff.steppedRegion(from: 0, direction: 1, count: 1) == 0)
        #expect(TextPairDiff.steppedRegion(from: 0, direction: -1, count: 1) == 0)
    }
}

// MARK: - The cost cap
//
// The byte cap bounds memory; this one bounds TIME, and they are not the same limit. Two 4 MB
// logs pass `BoundedTextRead` and then put Myers at 10⁹–10¹⁰ operations, uncancellable, under a
// spinner. The estimate has to separate that from an ordinary large diff, or a refusal is worse
// than the wait.
@Suite struct TextPairDiffCostTests {

    /// Lines that appear the same number of times on both sides cost nothing to match, so a big
    /// file with a small edit must stay well inside the budget. **This is the case a size-only cap
    /// would have refused**, which is why the estimator counts difference rather than length.
    @Test func aBigFileWithASmallEditIsCheap() {
        var left = (0..<100_000).map { "line \($0)" }
        var right = left
        right[500] = "line 500 — edited"
        left[900] = "line 900 — edited"
        #expect(TextPairDiff.refusalNote(left: left, right: right) == nil)
    }

    /// Two files with nothing in common: every line on both sides is an edit, so the estimate is
    /// (N+M)·(N+M) and lands far outside the budget. Two rotated logs, which is the pair this
    /// whole cap exists for.
    @Test func twoLargeFilesWithNothingInCommonAreRefused() {
        let left = (0..<100_000).map { "alpha \($0)" }
        let right = (0..<100_000).map { "beta \($0)" }
        let note = TextPairDiff.refusalNote(left: left, right: right)
        #expect(note != nil)
        // Named for what it found, not for the number — the reader can act on "too different".
        #expect(note?.contains("too different") == true)
    }

    /// **The positive control on the refusal.** A test that only ever sees "refused" cannot tell a
    /// working cap from one wired to `true`, and a test that only ever sees "allowed" cannot tell
    /// it from `false` — so the same shape of input is run at both sides of the budget.
    @Test func anEntirelyRewrittenFileIsAllowedUntilItIsBigEnoughToRefuse() {
        func rewrite(lines: Int) -> (left: [String], right: [String]) {
            ((0..<lines).map { "alpha \($0)" }, (0..<lines).map { "beta \($0)" })
        }
        // 5,000 lines rewritten end to end — ~10⁸, the diff someone genuinely wants.
        let small = rewrite(lines: 5_000)
        #expect(TextPairDiff.refusalNote(left: small.left, right: small.right) == nil)
        // 20,000 — the same shape, past the budget.
        let large = rewrite(lines: 20_000)
        #expect(TextPairDiff.refusalNote(left: large.left, right: large.right) != nil)
    }

    /// Identical files estimate zero however long they are: nothing is unmatched, so the product
    /// is zero rather than (N+M)². The degenerate case a multiset estimator has to get right.
    @Test func identicalFilesCostNothingAtAnySize() {
        let lines = (0..<200_000).map { "line \($0)" }
        #expect(TextPairDiff.estimatedCost(left: lines, right: lines) == 0)
        #expect(TextPairDiff.refusalNote(left: lines, right: lines) == nil)
    }

    /// Empty sides are not a refusal — there is nothing to diff, and `make` handles it. Guarding
    /// the arithmetic rather than the caller.
    @Test func emptySidesAreNotRefused() {
        #expect(TextPairDiff.refusalNote(left: [], right: []) == nil)
        #expect(TextPairDiff.refusalNote(left: [], right: ["one"]) == nil)
    }

    // MARK: The intra-line pass has a budget too

    /// **A file with no newlines in it walks straight past the line cap.** `estimatedCost` on the
    /// LINE arrays answers 4 for one line against one line, so a 4 MiB minified script — or JSON
    /// saved in one line, or a log whose writer never flushed — is admitted, and the row is then a
    /// changed row whose words go through the same Myers. Measured: such a file holds ~800,000
    /// words a side, where 8,000 already costs a second. The pane hung, and nothing in the line cap
    /// could see it coming.
    @Test func oneEnormousLineIsMarkedWholeRatherThanHangingThePane() throws {
        let left = (0..<40_000).map { "alpha\($0)" }.joined(separator: " ")
        let right = (0..<40_000).map { "beta\($0)" }.joined(separator: " ")
        // The premise: the LINE cap admits this pair, so the intra-line budget is the only thing
        // standing between the reader and the hang.
        #expect(TextPairDiff.refusalNote(left: [left], right: [right]) == nil,
                "the line cap now refuses this, and this test no longer tests what it says")

        let diff = TextPairDiff.make(left: [left], right: [right])

        #expect(diff.coarseRows == 1, "the row paid for a word pass it could not afford")
        let row = try #require(diff.rows.first)
        #expect(row.kind == .changed, "the row is still a changed row — only its word runs are gone")
        #expect(row.leftSegments == nil && row.rightSegments == nil)
        #expect(row.left == left, "the text itself must survive: the pane still renders the line")
    }

    /// The positive control, and the line this feature is actually for: ordinary changed lines
    /// still get their word runs, so the budget has not simply turned the intra-line pass off.
    @Test func anOrdinaryChangedLineStillGetsItsWordRuns() throws {
        let diff = TextPairDiff.make(left: ["Total due: $4,120.00 by 15 March"],
                                     right: ["Total due: $9,999.00 by 15 March"])
        #expect(diff.coarseRows == 0)
        let row = try #require(diff.rows.first)
        let marked = try #require(row.rightSegments).filter(\.changed).map(\.text)
        #expect(marked == ["$9,999.00 "])
    }

    /// A whole document of ordinary changed lines stays inside the budget — the aggregate is what
    /// the budget bounds, and a diff of this shape is the common case, not the pathological one.
    @Test func aWholeDocumentOfShortChangedLinesStaysInsideTheBudget() {
        let left = (0..<2_000).map { "the quick brown fox number \($0) jumps over the lazy dog" }
        let right = (0..<2_000).map { "the quick brown cat number \($0) jumps over the lazy dog" }
        let diff = TextPairDiff.make(left: left, right: right)
        #expect(diff.coarseRows == 0, "\(diff.coarseRows) ordinary lines lost their word runs")
        #expect(diff.rows.allSatisfy { $0.kind != .changed || $0.leftSegments != nil })
    }

    /// The budget is spent in order, so what the reader sees first is what keeps its detail. Two
    /// unaffordable rows: both go coarse, and the note counts them rather than mentioning one.
    @Test func theNoteCountsEveryRowThatLostItsWords() throws {
        let long = { (tag: String, seed: Int) in
            (0..<20_000).map { "\(tag)\($0 + seed)" }.joined(separator: " ")
        }
        let diff = TextPairDiff.make(left: [long("alpha", 0), long("gamma", 0)],
                                     right: [long("beta", 0), long("delta", 0)])
        #expect(diff.coarseRows == 2)
        let note = try #require(TextPairDiff.coarseNote(rows: diff.coarseRows))
        #expect(note.contains("2 lines"))
        #expect(TextPairDiff.coarseNote(rows: 1)?.contains("One line") == true)
        #expect(TextPairDiff.coarseNote(rows: 0) == nil, "a clean diff must say nothing")
    }
}
