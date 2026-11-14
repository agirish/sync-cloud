import Testing
import Foundation

/// Every path that clears the rasters must also orphan the render in flight. Cancellation is
/// cooperative, so a superseded render still finishes, and only `guard rasterToken == token` keeps
/// it from landing. A clearer that doesn't rotate the token lets it re-fill what was just cleared,
/// with images of a page or pair no longer on screen.
///
/// Both clearers call one `clearRasters()`; this pins what that can't: it rotates before it clears,
/// and no clearer has its own copy of the assignments. A scan, not a mounted test, because racing a
/// real render and asserting on what didn't land is a timing test over an absence.
///
/// Its own file, like `TrashFallbackWiringTests`, so it isn't lost inside an unrelated suite.
@Suite struct CompareRasterTokenScanTests {

    private func source() throws -> String { try SourceText.fileExplorer("CompareCopiesSheet.swift") }

    /// Nothing writes that state without rotating the token or standing behind it. A clearer
    /// (`clearRasters`) rotates first; a completion writes only past `guard rasterToken == token`.
    /// A bare `pageComparison = PageComparison()` with neither above it is what a well-meant
    /// "clear it here too" edit looks like.
    @Test func everyWriteEitherRotatesTheTokenOrStandsBehindIt() throws {
        let source = try source()
        // Split into members, so the question is asked within the function that writes. A
        // character window would excuse a write whose guard is merely nearby, and fail when an
        // unrelated block widens the gap in a correct function.
        let members = source.components(separatedBy: "\n    private func ")
            .flatMap { $0.components(separatedBy: "\n    func ") }
        // The `@State` declaration is a property, not a write; the leading indent tells them apart.
        let marker = "        pageComparison = PageComparison("
        var writing = 0
        for member in members {
            guard let write = member.range(of: marker) else { continue }
            writing += 1
            let before = String(member[member.startIndex..<write.lowerBound])
            #expect(before.contains("rasterToken = UUID()")
                        || before.contains("guard rasterToken == token"), """
                    \(member.prefix(while: { $0 != "(" })) writes `pageComparison` without either \
                    rotating `rasterToken` first or standing behind its guard, so a superseded \
                    render can land on top of what it just wrote
                    """)
        }
        // The positive control: the split really found the members, and more than one writes.
        #expect(writing == 2, """
                found \(writing) members writing `pageComparison` rather than 2 (`clearRasters` \
                and `refreshRasters`) — re-aim this scan
                """)
        #expect(source.components(separatedBy: "clearRasters()").count - 1 >= 3,
                "the two clearers no longer call `clearRasters` — re-aim this scan")
    }

    /// `refreshRasters` re-reads its token after the comparison's hop too, not only the render's.
    /// The comparison runs in a `Task.detached`, which `.task(id:)` cancellation does not reach, so
    /// a page turn in that time rotates `rasterToken`; without the second guard the superseded
    /// verdict lands in `heldComparisonKey`, `pageComparison` and the strip's dot. The scan above
    /// reads each member only up to its first write, which the render's guard already answers.
    @Test func theComparisonsResultIsGuardedBeforeItIsHeld() throws {
        let body = try SourceText.body(of: "private func refreshRasters() async {", in: try source())
        let comparison = try #require(body.range(of: "BitmapDiff.compare"),
                                      "`refreshRasters` no longer runs the comparison — re-aim this scan")
        let hop = try #require(body.range(of: "}.value", range: comparison.upperBound..<body.endIndex),
                               "the comparison is no longer awaited off the main actor — re-aim this scan")
        let held = try #require(body.range(of: "heldComparisonKey = decodeKey", range: hop.upperBound..<body.endIndex),
                                "the comparison's result is no longer held — re-aim this scan")
        #expect(body[hop.upperBound..<held.lowerBound].contains("guard rasterToken == token"), """
                the comparison's result is written without re-reading `rasterToken` after its hop, \
                so a verdict for a page already left lands on the strip
                """)
    }
}
