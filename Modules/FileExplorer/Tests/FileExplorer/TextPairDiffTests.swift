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
                    == .text("one\ntwo\n", lossy: false))
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
        guard case .text(let text, let lossy) = outcome else {
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
                    == .text("", lossy: false))
    }

    @Test func aMissingFileIsUnreadable() {
        #expect(BoundedTextRead.read(path: "/nope/gone.txt", isCloudOnly: { _ in false })
                    == .unreadable)
    }

    /// Each refusal says something a reader can act on — the size, or that the file needs
    /// downloading — rather than one generic failure.
    @Test func everyRefusalCarriesItsOwnReason() throws {
        #expect(BoundedTextRead.Outcome.text("x", lossy: false).caption == nil)
        let large = try #require(BoundedTextRead.Outcome.tooLarge(bytes: 9_000_000).caption)
        #expect(large.contains("MB"))
        #expect(BoundedTextRead.Outcome.cloudOnly.caption?.contains("downloaded") == true)
        #expect(BoundedTextRead.Outcome.binary.caption?.contains("not text") == true)
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
}
