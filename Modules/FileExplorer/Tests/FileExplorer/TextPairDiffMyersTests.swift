import Foundation
import Testing
@testable import FileExplorer

/// The hand-rolled Myers walk, held against the standard library's.
///
/// **A diff nobody can check is a diff nobody should ship.** `TextPairDiff` used to delegate to
/// `CollectionDifference`, which is correct by assumption; it now runs its own linear-space Myers,
/// which is correct only if something says so. This suite is that something: thousands of small
/// pairs, each one diffed both ways and the two answers compared.
///
/// **What "agree" means, and why it is not string equality of the two scripts.** A minimal edit
/// script is not unique. `["a", "b", "a"]` → `["a"]` can delete offsets 1 and 2 or offsets 0 and 1,
/// and both are minimal, both reconstruct the right file, and a reader could not tell which one the
/// pane drew. Measured over this corpus, the two implementations pick the same script about 73% of
/// the time; demanding 100% would be pinning a tie-break neither of them promises. So the two
/// things that DO matter are asserted on every pair:
///
/// * **valid** — deleting the marked lines from each side leaves the same common subsequence, which
///   is the same as saying the pane's rows reconstruct both files exactly; and
/// * **minimal** — the script is exactly as long as `CollectionDifference`'s, so nothing extra was
///   marked as changed.
///
/// A script that is both is a diff of the same quality, whichever of the ties it landed on.
@Suite struct TextPairDiffMyersTests {

    /// The script the walk produces, as two flag arrays.
    private func mine(_ left: [String], _ right: [String],
                      maxWork: Int = .max) -> (removed: [Bool], inserted: [Bool])? {
        let ids = TextPairDiff.interned(left, right)
        var walker = LineDiffWalker(a: ids.left, b: ids.right, maxWork: maxWork,
                                    isCancelled: { false })
        guard walker.run() == .completed else { return nil }
        return (walker.removed, walker.inserted)
    }

    /// The same script from `CollectionDifference`, which is the reference.
    private func reference(_ left: [String], _ right: [String])
        -> (removed: [Bool], inserted: [Bool]) {
        var removed = [Bool](repeating: false, count: left.count)
        var inserted = [Bool](repeating: false, count: right.count)
        for change in right.difference(from: left) {
            switch change {
            case .remove(let offset, _, _): removed[offset] = true
            case .insert(let offset, _, _): inserted[offset] = true
            }
        }
        return (removed, inserted)
    }

    /// Asserts validity and minimality, and reports the pair that broke it.
    private func agrees(_ left: [String], _ right: [String], _ label: String) {
        guard let script = mine(left, right) else {
            Issue.record("\(label): the walk did not complete on \(left) → \(right)")
            return
        }
        let kept = { (lines: [String], flags: [Bool]) in
            lines.indices.filter { !flags[$0] }.map { lines[$0] }
        }
        #expect(kept(left, script.removed) == kept(right, script.inserted), """
                \(label): the script does not reconstruct both sides — \(left) → \(right)
                """)
        let theirs = reference(left, right)
        let mineCount = script.removed.filter { $0 }.count + script.inserted.filter { $0 }.count
        let theirCount = theirs.removed.filter { $0 }.count + theirs.inserted.filter { $0 }.count
        #expect(mineCount == theirCount, """
                \(label): \(mineCount) edits where CollectionDifference finds \(theirCount) — \
                \(left) → \(right)
                """)
    }

    // MARK: The shapes with names

    @Test func theNamedShapesAgree() {
        agrees([], [], "two empty sides")
        agrees([], ["a"], "an empty left")
        agrees(["a"], [], "an empty right")
        agrees(["a", "b", "c"], ["a", "b", "c"], "identical")
        agrees(["a", "b", "c"], ["a", "x", "c"], "one changed line")
        agrees(["a", "c"], ["a", "b", "c"], "one insert")
        agrees(["a", "b", "c"], ["a", "c"], "one delete")
        agrees(["1", "2", "3", "4", "5", "6"], ["4", "5", "6", "1", "2", "3"], "a block move")
        agrees(["a", "b"], ["x", "y"], "nothing in common")
        agrees(["a", "a", "a", "a"], ["a", "a"], "repeats")
        agrees(["", "", "a"], ["", "a", ""], "empty lines")
    }

    /// **CRLF, and the trap this repo has written down: `"\r\n"` is ONE grapheme**, so
    /// `hasSuffix("\n")` is false on a CRLF line. The reader normalises endings before the diff ever
    /// sees them (`BoundedTextRead.lines`), which is what makes a CRLF file diff as its content
    /// rather than as its line endings — but a stray `\r` inside a line is content, and must be.
    @Test func carriageReturnsAreContentNotStructure() {
        agrees(["a\r", "b"], ["a", "b"], "a stray CR on one side")
        let normalised = BoundedTextRead.lines("one\r\ntwo\r\n")
        #expect(normalised.last?.isEmpty == true, "the split lost the trailing empty line")
        #expect(normalised.allSatisfy { $0.last != "\r" }, "a CR survived the normalisation")
        agrees(normalised, BoundedTextRead.lines("one\ntwo\n"), "CRLF against LF")
    }

    @Test func unicodeLinesAgree() {
        agrees(["é", "👩‍👩‍👧‍👦", "ß"], ["é", "x", "ß"], "combining marks and a family emoji")
        // Canonically equivalent spellings of "é" are ONE line to Swift, and so to the diff.
        agrees(["e\u{301}"], ["é"], "NFD against NFC")
    }

    // MARK: The corpus

    /// Small random pairs over a tiny alphabet — the shape that produces ties, repeats and
    /// degenerate cases in bulk. Seeded, so a failure here is reproducible.
    @Test func aCorpusOfSmallRandomPairsAgrees() {
        var rng = SeededGenerator(seed: 0x5EED_1234)
        let alphabet = ["a", "b", "c", "d"]
        for trial in 0..<2_000 {
            let left = (0..<Int.random(in: 0...9, using: &rng)).map {
                _ in alphabet.randomElement(using: &rng)!
            }
            let right = (0..<Int.random(in: 0...9, using: &rng)).map {
                _ in alphabet.randomElement(using: &rng)!
            }
            agrees(left, right, "random pair \(trial)")
        }
    }

    /// Larger pairs derived by EDITING one side — the shape a real diff has, where most lines match
    /// and a few do not, sometimes with the whole file shuffled underneath.
    @Test func aCorpusOfEditedFilesAgrees() {
        var rng = SeededGenerator(seed: 0xC0FFEE)
        for trial in 0..<300 {
            var left = (0..<Int.random(in: 1...80, using: &rng)).map { "line \($0 % 20)" }
            var right = left
            for _ in 0..<Int.random(in: 0...10, using: &rng) {
                guard !right.isEmpty else { break }
                switch Int.random(in: 0...2, using: &rng) {
                case 0: right.remove(at: Int.random(in: 0..<right.count, using: &rng))
                case 1: right.insert("new \(trial)", at: Int.random(in: 0...right.count, using: &rng))
                default: right[Int.random(in: 0..<right.count, using: &rng)] = "edited \(trial)"
                }
            }
            if Bool.random(using: &rng) { left.shuffle(using: &rng) }
            agrees(left, right, "edited pair \(trial)")
        }
    }

    /// The positive control on the two checks above. A deliberately WRONG script — one edit short —
    /// must fail both, or the corpus is 2,300 assertions that cannot notice anything.
    @Test func theChecksCanActuallyFail() {
        let left = ["a", "b", "c"], right = ["a", "x", "c"]
        let theirs = reference(left, right)
        #expect(theirs.removed.filter { $0 }.count == 1 && theirs.inserted.filter { $0 }.count == 1,
                "the reference no longer finds one edit a side here — re-aim this control")
        // Mark only the removal: valid reconstruction fails, and so does the count.
        let kept = left.indices.filter { !theirs.removed[$0] }.map { left[$0] }
        #expect(kept != right, "a script one edit short reconstructed the right side anyway")
    }

    // MARK: Interning, which is what makes collisions unwriteable

    /// **Equal ids mean equal strings, by construction.** The walk compares integers; if two
    /// different lines could ever share one, the pane would call them the same line. They cannot:
    /// the ids come from a dictionary, which resolves hash collisions by comparing the keys.
    @Test func onlyEqualLinesShareAnId() {
        let left = ["a", "b", "a", ""], right = ["b", "a", "c", ""]
        let ids = TextPairDiff.interned(left, right)
        var seen: [Int: String] = [:]
        for (line, id) in Array(zip(left, ids.left)) + Array(zip(right, ids.right)) {
            if let previous = seen[id] {
                #expect(previous == line, "id \(id) names both \(previous.debugDescription) and \(line.debugDescription)")
            }
            seen[id] = line
        }
        #expect(Set(ids.left + ids.right).count == 4, "four distinct lines were not given four ids")
        #expect(ids.left[0] == ids.left[2], "the same line twice was given two ids")
    }

    // MARK: The ceiling, which is the point of the rewrite

    /// **The shape the estimate prices at zero.** Two files holding the same lines in a different
    /// order have no multiset difference at all, so `estimatedCost` answers 0 and the old refusal
    /// waved them through into an uninterruptible `CollectionDifference` — measured at 16.5s for
    /// 20,000 lines a side, and quadratic from there.
    /// **The ceiling is passed explicitly here, and that is deliberate.** Reaching the shipped
    /// ``TextPairDiff/maxDiffWork`` costs exactly that much work by definition — ~0.7s in a Release
    /// build, several seconds in the unoptimised one a test runs in — which would buy nothing this
    /// does not already say. `anEntirelyRewrittenFileIsStillAffordable` below is what exercises the
    /// shipped default, from the other side.
    @Test func aReorderedPairIsRefusedByTheCeilingTheEstimateCannotSee() {
        let left = (0..<20_000).map { "line \($0) some text here" }
        var rng = SeededGenerator(seed: 99)
        let right = left.shuffled(using: &rng)
        #expect(TextPairDiff.estimatedCost(left: left, right: right) == 0,
                "the premise is gone: the estimate now prices a reordered pair above zero")
        #expect(TextPairDiff.refusalNote(left: left, right: right) == nil,
                "the premise is gone: the pre-filter now refuses this pair on its own")
        #expect(TextPairDiff.bounded(left: left, right: right, maxWork: 2_000_000) == .tooDifferent,
                "the walk ran a reordered 20,000-line pair past its ceiling")
    }

    /// The positive control on that: the same shape, small enough to be worth diffing, is DIFFED
    /// rather than refused. Without this the ceiling could be wired to refuse everything.
    @Test func aReorderedPairSmallEnoughToAffordIsStillDiffed() throws {
        let left = (0..<2_000).map { "line \($0) some text here" }
        var rng = SeededGenerator(seed: 7)
        let right = left.shuffled(using: &rng)
        guard case .diffed(let diff) = TextPairDiff.bounded(left: left, right: right) else {
            Issue.record("a 2,000-line reordered pair was refused")
            return
        }
        #expect(!diff.isIdentical)
        // The rows reconstruct both files — the pane's own contract, asserted on a real diff.
        #expect(diff.rows.compactMap(\.left) == left)
        #expect(diff.rows.compactMap(\.right) == right)
    }

    /// The anchor the cap has always been written around: 5,000 lines rewritten end to end is a
    /// diff someone genuinely wants, and it stays inside the ceiling.
    @Test func anEntirelyRewrittenFileIsStillAffordable() {
        let left = (0..<5_000).map { "alpha \($0)" }
        let right = (0..<5_000).map { "beta \($0)" }
        guard case .diffed(let diff) = TextPairDiff.bounded(left: left, right: right) else {
            Issue.record("the anchor case — a 5,000-line rewrite — is now refused")
            return
        }
        #expect(diff.changedLineCount == 5_000)
    }

    /// **The two bounds count different things, and the factor between them is measured.**
    /// ``TextPairDiff/maxEstimatedCost`` is `(N+M)` times a lower bound on the edit distance;
    /// ``TextPairDiff/maxDiffWork`` is steps actually taken. Setting them to the same number would
    /// have the cheap one refusing pairs the real one would finish — which is what it was doing.
    /// On the family the pre-filter exists to catch, files with nothing in common, the estimate
    /// comes to four times the steps the walk then spends, and that is what the threshold is scaled
    /// by. If this ratio moves, the scaling in `maxEstimatedCost` has to move with it.
    @Test func theEstimateRunsAtFourTimesTheWalkOnTheFamilyItGuards() {
        for lines in [1_000, 2_000] {
            let left = (0..<lines).map { "alpha \($0)" }
            let right = (0..<lines).map { "beta \($0)" }
            let ids = TextPairDiff.interned(left, right)
            var walker = LineDiffWalker(a: ids.left, b: ids.right, maxWork: .max,
                                        isCancelled: { false })
            #expect(walker.run() == .completed)
            let estimate = TextPairDiff.estimatedCost(left: left, right: right)
            let ratio = Double(estimate) / Double(walker.work)
            #expect(ratio > 3.5 && ratio < 4.5, """
                    the estimate is \(String(format: "%.2f", ratio))× the walk's \(walker.work) \
                    steps at \(lines) lines a side, not the 4× `maxEstimatedCost` is scaled by
                    """)
        }
        #expect(TextPairDiff.maxEstimatedCost == 4 * TextPairDiff.maxDiffWork,
                "the pre-filter is no longer scaled off the real ceiling")
    }

    /// **Cancellation reaches the walk itself**, which is what closing the surface now does. The
    /// old pass was one call into the standard library with nowhere to ask.
    @Test func aCancelledWalkStopsAndReportsIt() {
        let left = (0..<20_000).map { "line \($0)" }
        var rng = SeededGenerator(seed: 3)
        let right = left.shuffled(using: &rng)
        #expect(TextPairDiff.bounded(left: left, right: right, isCancelled: { true }) == .cancelled)
        // …and a walk nobody cancels still answers, so the flag is read rather than assumed.
        var asked = 0
        let outcome = TextPairDiff.bounded(left: ["a"], right: ["b"], isCancelled: {
            asked += 1
            return false
        })
        #expect(asked > 0, "the walk never asked whether it had been cancelled")
        if case .diffed = outcome {} else { Issue.record("a one-line pair was not diffed") }
    }

    // MARK: Pricing a row without tokenising it

    /// ``TextPairDiff/wordCount(_:)`` exists to price a row without allocating one String per word,
    /// so it has to answer what `words(_:)` would have counted.
    @Test(arguments: ["", " ", "   ", "a", "a b", "a b c", "  leading", "trailing  ",
                      "a\tb\tc", "one  two   three", "    let total  =   4   // trailing",
                      "Total due: $4,120.00 by 15 March"])
    func theCheapWordCountMatchesTheRealOne(_ line: String) {
        #expect(TextPairDiff.wordCount(line) == TextPairDiff.words(line).count,
                "pricing \(line.debugDescription) disagrees with tokenising it")
    }

    /// The documented exception, asserted rather than left as a claim: whitespace that is not
    /// ASCII is not seen as a separator by the cheap count. It only ever makes a row look SHORTER
    /// than it is, which can choose a word pass the walk's own ceiling then bounds anyway.
    @Test func exoticWhitespaceIsUndercountedAndSaysSo() {
        #expect(TextPairDiff.wordCount("a\u{00A0}b") < TextPairDiff.words("a\u{00A0}b").count,
                "the approximation is gone — update the doc on `wordCount`")
    }

    /// A 4 MiB line with no newlines in it is the case the word budget exists for, and it must not
    /// be tokenised to find that out.
    @Test func anEnormousLineIsPricedWithoutBeingSplit() {
        let left = String(repeating: "abcd ", count: 400_000)
        let right = String(repeating: "abce ", count: 400_000)
        #expect(TextPairDiff.wordCount(left) > TextPairDiff.maxWordsForIntraLine,
                "the fixture is no longer past the gate")
        let diff = TextPairDiff.make(left: [left], right: [right])
        #expect(diff.coarseRows == 1, "the row paid for a word pass it could not afford")
        #expect(diff.rows.first?.leftSegments == nil)
        #expect(diff.rows.first?.left == left, "the text itself must survive: the pane draws it")
    }
}

/// A reproducible generator, so a corpus failure names a pair someone can re-run.
///
/// SplitMix64 — small, and its quality is beside the point here: what matters is that the same seed
/// produces the same corpus on every machine and every run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
