import Foundation
import Testing
@testable import FileExplorer

/// **Work on this surface must not outlive the surface, and must not be redone for nothing.**
///
/// Three rules, all about the same thing: the compare card starts two long jobs that no
/// `.task(id:)` can reach into. The line diff is a `Task.detached` — cancellation does not inherit
/// into one — and the ↑/↓ page walk is a `Task` created inside a button handler. Both were guarded
/// only by a token, which discards a stale RESULT while the work runs on: closing the card left a
/// Myers walk on two 4 MB files running, and a page search with up to fifty PDF opens still queued
/// on the serial lane a running scan shares.
///
/// **A scan rather than a mounted-view test, for `CompareRasterTokenScanTests`' reason.** Proving
/// a task stopped means asserting on work that did NOT happen, against a real PDF and a real
/// window — a timing test over an absence, which is how flakes get written. The rules are single
/// lines in a file; this pins the lines and says so.
@Suite struct CompareWorkLifetimeTests {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/CompareCopiesSheet.swift")
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read CompareCopiesSheet.swift — this check is vacuous")
    }

    /// The member a rule is about, so the question is asked inside the function that has to answer
    /// it rather than over a window of characters — the shape `CompareRasterTokenScanTests` settled
    /// on after a character window excused one defect and invented another.
    private func member(_ name: String, in source: String,
                        endingWith terminator: String = "\n    }\n") throws -> String {
        let start = try #require(source.range(of: name),
                                 "`\(name)` is gone or renamed — re-aim this scan")
        let end = try #require(source.range(of: terminator,
                                            range: start.upperBound..<source.endIndex))
        return String(source[start.upperBound..<end.lowerBound])
    }

    /// Closing the card cancels both handles. Without this the only thing that stops either job is
    /// the work finishing.
    @Test func closingTheSurfaceCancelsBothLongJobs() throws {
        let body = try member(".onDisappear {", in: try source(), endingWith: "\n        }")
        #expect(body.contains("textDiffTask?.cancel()"),
                "closing the card leaves the line diff walking two files nobody is looking at")
        #expect(body.contains("pageSearchTask?.cancel()"),
                "closing the card leaves the page search queueing PDF opens on the serial lane")
    }

    /// The walk between candidate pages asks BOTH questions, and they are different ones: the token
    /// says a newer search has superseded this one, cancellation says nobody wants any search.
    @Test func thePageSearchChecksCancellationBetweenCandidates() throws {
        let body = try member("private func stepToDifferingPage(", in: try source())
        #expect(body.contains("!Task.isCancelled"), """
                the page walk checks only its token, so a cancelled search still renders up to \
                `PageDifferenceStepper.renderBudget` page pairs
                """)
        // The positive control: the token guard it stands beside is still there, so a green here
        // cannot mean the loop lost its guards altogether.
        #expect(body.contains("pageSearchToken == token"),
                "the search no longer guards on its token — re-aim this scan")
    }

    /// **The diff is keyed on the PAIR, not on the mode.** Keyed on `activeMode.rawValue` — with a
    /// guard that cleared the held diff on the way out — every `1`→`2` press re-read both files (up
    /// to 8 MB), re-split them into lines and re-walked them. The comment that justified that key
    /// is about laziness: a pair the reader never switches to Diff should cost nothing. Laziness
    /// needs no eviction, and `textDiffPairKey` is what separates the two.
    @Test func theTextDiffIsNotRecomputedOnEveryModeToggle() throws {
        let source = try source()
        #expect(!source.contains("(pairKey)|\\(activeMode.rawValue)"), """
                the text diff task is keyed on the mode again, so leaving and re-entering Diff \
                re-reads and re-diffs both files
                """)
        #expect(source.contains("textDiffPairKey"),
                "the memo that makes the diff survive a mode toggle is gone — re-aim this scan")
        let body = try member("private func refreshTextDiff(", in: try source)
        #expect(body.contains("guard textDiffPairKey != pairKey else { return }"),
                "the diff is recomputed even when one for this pair is already in hand")
    }

    /// The rasters are keyed on what they are OF, and the comparison on what is being asked of
    /// them — see `decodeKey`. Without the split, entering or leaving a pixel mode re-decoded both
    /// sides before comparing anything, which for an image pair throws away rasters already in hand.
    @Test func aModeChangeDoesNotThrowAwayTheDecode() throws {
        let source = try source()
        #expect(source.contains("private var decodeKey: String {"),
                "the decode key is gone — re-aim this scan")
        let decode = try member("private var decodeKey: String {", in: source)
        #expect(!decode.contains("showsOverlayModes"), """
                the decode key carries the mode again, so entering a pixel mode re-renders both \
                sides rather than reusing them
                """)
        let raster = try member("private var rasterKey: String {", in: source)
        #expect(raster.contains("showsOverlayModes") && raster.contains("decodeKey"), """
                the render key no longer builds on the decode key plus the mode — re-aim this scan
                """)
        let refresh = try member("private func refreshRasters(", in: source)
        #expect(refresh.contains("heldRasterKey == decodeKey"),
                "the refresh no longer reuses rasters it already has")
    }

    /// The difference raster is a third full-page image, and the de-skew that produces the number
    /// beside it is 565 ms of a 605 ms comparison. Swipe and onion read neither.
    ///
    /// **The justification, so the next reader does not re-litigate it** (this session did, and was
    /// wrong): `comparedState(atPage:)` — the walk that fills the strip for every page the ↑/↓
    /// search touches — has always used the plain unaligned `BitmapDiff.compare`. Only the visible
    /// page went through the aligned path, so the strip already carried one aligned dot among a row
    /// of unaligned ones. Gating removes that mixture rather than creating one.
    @Test func theExpensiveComparisonIsOnlyRunForTheModeThatReadsIt() throws {
        let source = try source()
        #expect(source.contains(
                    "private var wantsAlignedDifference: Bool { activeMode == .difference }"),
                "the de-skew and the difference raster are no longer gated on the mode")
        let refresh = try member("private func refreshRasters(", in: source)
        #expect(refresh.contains("guard wantsAligned else { return (nil, BitmapDiff.compare("), """
                the visible page is de-skewed whatever the mode, which is ~565 ms per page of an                 estimate that swipe and onion read nothing of
                """)
        #expect(refresh.contains("BitmapDiff.compareAligning("),
                "the difference mode no longer aligns at all — re-aim this scan")
        // The premise of all of the above, pinned where it can rot: the page walk is unaligned.
        let walk = try member("private func comparedState(", in: source)
        #expect(walk.contains("BitmapDiff.compare(") && !walk.contains("compareAligning"), """
                `comparedState` now aligns too — the strip is no longer uniformly unaligned                 outside the difference mode, and the gate's justification needs re-reading
                """)
    }

    /// **Leaving the difference mode must not downgrade what was already computed.** The rule is a
    /// value so it can be asserted at all — the alternative is a mounted surface, two real PDFs and
    /// a mode press, asserting on a dot's colour.
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
