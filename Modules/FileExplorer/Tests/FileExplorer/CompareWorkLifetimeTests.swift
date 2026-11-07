import Foundation
import Testing
@testable import FileExplorer

/// Work on the compare card must not outlive it, or be redone for nothing. Two long jobs are out
/// of `.task(id:)`'s reach: the line diff is a `Task.detached`, which doesn't inherit
/// cancellation, and the ↑/↓ page walk is a `Task` from a button handler. A token only discards a
/// stale result while the work runs on, so each needs cancelling too.
///
/// A scan, not a mounted test, for `CompareRasterTokenScanTests`' reason: proving a task stopped
/// would be a timing test over an absence.
@Suite struct CompareWorkLifetimeTests {

    private func source() throws -> String { try SourceText.fileExplorer("CompareCopiesSheet.swift") }

    /// Closing the card cancels both handles; otherwise only finishing stops either job.
    @Test func closingTheSurfaceCancelsBothLongJobs() throws {
        let body = try SourceText.block(opening: ".onDisappear {", in: try source())
        #expect(body.contains("textDiffTask?.cancel()"),
                "closing the card leaves the line diff walking two files nobody is looking at")
        #expect(body.contains("pageSearchTask?.cancel()"),
                "closing the card leaves the page search queueing PDF opens on the serial lane")
    }

    /// The walk between candidate pages asks both questions: the token says a newer search
    /// superseded this one, cancellation says nobody wants any search.
    @Test func thePageSearchChecksCancellationBetweenCandidates() throws {
        let body = try SourceText.body(of: "private func stepToDifferingPage(", in: try source())
        #expect(body.contains("!Task.isCancelled"), """
                the page walk checks only its token, so a cancelled search still renders up to \
                `PageDifferenceStepper.renderBudget` page pairs
                """)
        // The positive control: the token guard is still there, so green can't mean the loop lost
        // its guards altogether.
        #expect(body.contains("pageSearchToken == token"),
                "the search no longer guards on its token — re-aim this scan")
    }

    /// The diff is keyed on the pair, not the mode, so a `1`→`2` press doesn't re-read and re-diff
    /// both files. It stays lazy (a pair never shown in Diff costs nothing) without eviction;
    /// `textDiffPairKey` is the memo.
    @Test func theTextDiffIsNotRecomputedOnEveryModeToggle() throws {
        let source = try source()
        #expect(!source.contains("(pairKey)|\\(activeMode.rawValue)"), """
                the text diff task is keyed on the mode again, so leaving and re-entering Diff \
                re-reads and re-diffs both files
                """)
        #expect(source.contains("textDiffPairKey"),
                "the memo that makes the diff survive a mode toggle is gone — re-aim this scan")
        let body = try SourceText.body(of: "private func refreshTextDiff(", in: source)
        #expect(body.contains("guard textDiffPairKey != pairKey else { return }"),
                "the diff is recomputed even when one for this pair is already in hand")
    }

    /// The rasters are keyed on what they are of, and the comparison on what is asked of them (see
    /// `decodeKey`), so entering or leaving a pixel mode doesn't re-decode both sides.
    @Test func aModeChangeDoesNotThrowAwayTheDecode() throws {
        let source = try source()
        #expect(source.contains("private var decodeKey: String {"),
                "the decode key is gone — re-aim this scan")
        let decode = try SourceText.body(of: "private var decodeKey: String {", in: source)
        #expect(!decode.contains("showsOverlayModes"), """
                the decode key carries the mode again, so entering a pixel mode re-renders both \
                sides rather than reusing them
                """)
        let raster = try SourceText.body(of: "private var rasterKey: String {", in: source)
        #expect(raster.contains("showsOverlayModes") && raster.contains("decodeKey"), """
                the render key no longer builds on the decode key plus the mode — re-aim this scan
                """)
        let refresh = try SourceText.body(of: "private func refreshRasters(", in: source)
        #expect(refresh.contains("heldRasterKey == decodeKey"),
                "the refresh no longer reuses rasters it already has")
    }

    /// The difference raster is a third full-page image, and its de-skew is ~565 ms of a ~605 ms
    /// comparison; swipe and onion read neither, so only Difference runs it. This keeps the strip
    /// uniform: `comparedState(atPage:)`, which fills it for the ↑/↓ walk, is always unaligned.
    @Test func theExpensiveComparisonIsOnlyRunForTheModeThatReadsIt() throws {
        let source = try source()
        #expect(source.contains(
                    "private var wantsAlignedDifference: Bool { activeMode == .difference }"),
                "the de-skew and the difference raster are no longer gated on the mode")
        let refresh = try SourceText.body(of: "private func refreshRasters(", in: source)
        #expect(refresh.contains("guard wantsAligned else { return (nil, BitmapDiff.compare("), """
                the visible page is de-skewed whatever the mode, which is ~565 ms per page of an                 estimate that swipe and onion read nothing of
                """)
        #expect(refresh.contains("BitmapDiff.compareAligning("),
                "the difference mode no longer aligns at all — re-aim this scan")
        // The premise of the above, pinned where it can rot: the page walk is unaligned.
        let walk = try SourceText.body(of: "private func comparedState(", in: source)
        #expect(walk.contains("BitmapDiff.compare(") && !walk.contains("compareAligning"), """
                `comparedState` now aligns too — the strip is no longer uniformly unaligned                 outside the difference mode, and the gate's justification needs re-reading
                """)
    }

    /// Leaving the difference mode must not downgrade what was computed. The rule is a value so it
    /// can be asserted without a mounted surface, two PDFs and a dot's colour.
    @Test func anAlignedVerdictSurvivesAModeToggleAndAnUnalignedOneIsUpgraded() {
        let page = "pair|3|pdf|true|true|12"
        // Difference → swipe: aligned in hand, alignment no longer wanted. Keep it.
        #expect(PageComparisonReuse.isEnough(held: page, decode: page,
                                             heldAligned: true, wantsAligned: false),
                "a mode press threw away an aligned verdict and would recompute a weaker one")
        // Swipe → difference: unaligned in hand, alignment wanted. Recompute.
        #expect(!PageComparisonReuse.isEnough(held: page, decode: page,
                                              heldAligned: false, wantsAligned: true),
                "entering the difference mode reused a comparison that was never aligned")
        // Swipe → onion: unaligned in hand, unaligned wanted. Keep it.
        #expect(PageComparisonReuse.isEnough(held: page, decode: page,
                                             heldAligned: false, wantsAligned: false))
        // A different page, and nothing in hand at all: always recompute.
        #expect(!PageComparisonReuse.isEnough(held: page, decode: "pair|4|pdf|true|true|12",
                                              heldAligned: true, wantsAligned: false))
        #expect(!PageComparisonReuse.isEnough(held: nil, decode: page,
                                              heldAligned: true, wantsAligned: false))
    }
}
