import Foundation
import Testing
@testable import FileExplorer

/// The ordering that turns two read sides into a diff, or into a reason there is none.
///
/// **This is the half that had no test until it was lifted.** It used to be the body of a
/// `Task.detached` closure inside a private view method, where nothing could reach it: the compare
/// pane's tests could assert the reader and they could assert the differ, and the sequence between
/// them — refuse first, notes second, pre-filter THIRD, walk LAST — was covered by nobody. That
/// sequence is the stall guard, and the failure mode when it is wrong is not a wrong answer, it is
/// two seconds of a pinned core on a pair the pre-filter exists to wave off.
@Suite struct TextPairDiffPipelineTests {

    private func text(_ value: String) -> BoundedTextRead.Outcome {
        .text(value, lossy: false, encoding: .utf8)
    }

    private func run(_ left: BoundedTextRead.Outcome, _ right: BoundedTextRead.Outcome,
                     leftLabel: String = TextPairDiffPipeline.defaultLeftLabel,
                     rightLabel: String = TextPairDiffPipeline.defaultRightLabel,
                     isCancelled: @escaping () -> Bool = { false })
        -> TextPairDiffPipeline.Outcome {
        TextPairDiffPipeline.diff(left: left, right: right, leftLabel: leftLabel,
                                  rightLabel: rightLabel, isCancelled: isCancelled)
    }

    // MARK: The ordinary answer

    @Test func twoReadableSidesComeBackAsRows() throws {
        let outcome = run(text("one\ntwo\n"), text("one\nTWO\n"))
        let diff = try #require(outcome.diff)
        #expect(diff.changedLineCount == 1)
        #expect(!outcome.cancelled)
    }

    /// The reading notes ride along with the rows — a diff of a CRLF file against an LF one shows
    /// no changed lines at all, and only the note says the two files are not the same bytes.
    @Test func howTheBytesWereReadIsReportedBesideTheRows() {
        let outcome = run(text("one\r\ntwo\r\n"), text("one\ntwo\n"))
        #expect(outcome.diff?.changedLineCount == 0)
        #expect(outcome.notes.contains { $0.contains("Line endings differ") },
                "a CRLF/LF pair diffs as identical — the note is the only thing that says otherwise")
    }

    // MARK: A side with no text

    /// **Named per side, and nothing is diffed.** A pane that simply drew nothing would leave the
    /// reader to guess which of the two files was the problem.
    @Test(arguments: [BoundedTextRead.Outcome.tooLarge(bytes: 99_000_000),
                      .cloudOnly, .binary, .unreadable])
    func aSideThatIsNotTextRefusesTheWholeDiffAndSaysWhich(bad: BoundedTextRead.Outcome) throws {
        let onLeft = run(bad, text("one\n"))
        #expect(onLeft.diff == nil)
        #expect(onLeft.notes.count == 1)
        let leftNote = try #require(onLeft.notes.first)
        #expect(leftNote.hasPrefix("Left: "), "got \(leftNote)")
        // The REASON travels, not just a refusal — "too large" and "not downloaded" are different
        // things for the reader to do something about.
        #expect(leftNote.hasSuffix(try #require(bad.caption)))

        let onRight = run(text("one\n"), bad)
        #expect(onRight.diff == nil)
        #expect(onRight.notes.first?.hasPrefix("Right: ") == true, "got \(onRight.notes)")
    }

    /// Both sides bad names both, so a reader is not told about one problem and left to discover
    /// the other by fixing the first.
    @Test func bothSidesUnreadableNamesBoth() {
        let outcome = run(.binary, .cloudOnly)
        #expect(outcome.notes.count == 2)
        #expect(outcome.notes[0].hasPrefix("Left: "))
        #expect(outcome.notes[1].hasPrefix("Right: "))
    }

    /// **The labels are the caller's**, because the editor's two sides are not a left and a right
    /// column in the reader's head — they are the buffer and the file.
    @Test func theRefusalUsesTheCallersOwnNamesForTheTwoSides() {
        let outcome = run(text("one\n"), .tooLarge(bytes: 99_000_000),
                          leftLabel: "In the editor", rightLabel: "On disk")
        #expect(outcome.notes.first?.hasPrefix("On disk: ") == true, "got \(outcome.notes)")
        #expect(outcome.notes.first?.contains("Too large to diff") == true)
    }

    // MARK: The order the guards run in

    /// **The pre-filter runs BEFORE the walk, and this is the pair that proves it.**
    ///
    /// Two large arrays with nothing in common price far above ``TextPairDiff/maxEstimatedCost``,
    /// so the linear pass refuses them and the walk is never entered. If the two were swapped the
    /// answer would be the same sentence — `refusalCaption` is shared — so the observable
    /// difference is the *cancellation flag*: a walk that ran would have asked `isCancelled`, and
    /// a pipeline that reached one here would come back cancelled instead of refused.
    @Test func anEnormousUnrelatedPairIsRefusedWithoutEnteringTheWalk() {
        let left = (0..<40_000).map { "left line \($0)" }.joined(separator: "\n")
        let right = (0..<40_000).map { "right line \($0)" }.joined(separator: "\n")
        var asked = false
        let outcome = run(text(left), text(right), isCancelled: { asked = true; return true })
        #expect(outcome.diff == nil)
        #expect(!outcome.cancelled, "the walk was entered — the pre-filter did not run first")
        #expect(!asked, "the walk was entered — the pre-filter did not run first")
        #expect(outcome.notes.contains(TextPairDiff.refusalCaption))
    }

    /// And a pair the pre-filter waves through does reach the walk, so the test above is about the
    /// order rather than about a pipeline that never walks anything.
    @Test func aPairTheEstimateAllowsDoesReachTheWalk() {
        var asked = false
        let outcome = run(text("one\ntwo\n"), text("one\nTWO\n"),
                          isCancelled: { asked = true; return false })
        #expect(asked, "the walk was never entered, so the order test above proves nothing")
        #expect(outcome.diff != nil)
    }

    /// A cancelled pass lands nowhere: no diff, and no notes to write over a real answer with.
    @Test func aCancelledPassCarriesNothing() {
        let outcome = run(text("one\ntwo\n"), text("one\nTWO\n"), isCancelled: { true })
        #expect(outcome.cancelled)
        #expect(outcome.diff == nil)
        #expect(outcome.notes.isEmpty,
                "a cancelled pass knows nothing about the pair — its notes would replace a real answer with silence")
    }

    /// The coarse note is a fact about the diff that came back, so it is appended last — after the
    /// reading notes, and only on the path that produced rows.
    @Test func aRowTooLongForTheWordPassSaysSoAfterTheReadingNotes() {
        let long = String(repeating: "word ", count: TextPairDiff.maxWordsForIntraLine + 10)
        let outcome = run(text("one\r\n" + long), text("one\n" + long + "x"))
        #expect(outcome.diff != nil)
        #expect(outcome.notes.first?.contains("Line endings differ") == true,
                "the reading notes come first — got \(outcome.notes)")
        #expect(outcome.notes.last == TextPairDiff.coarseNote(rows: outcome.diff?.coarseRows ?? 0),
                "got \(outcome.notes)")
    }
}
