import Testing
import Foundation

/// **`refreshRasters` re-reads its token after the comparison's hop too, not only the render's.**
///
/// The page comparison runs in a `Task.detached`, which `.task(id:)` cancellation does not reach,
/// and takes milliseconds on a full page. A page turn or mode change in that time rotates
/// `rasterToken`; without the second `guard rasterToken == token` the superseded verdict still lands
/// in `heldComparisonKey`, `pageComparison` and the strip's dot for a page nobody is looking at.
///
/// `CompareCopiesStaleWriteTests` asks only whether the file re-reads the token somewhere, and
/// `CompareRasterTokenScanTests` reads each member up to its first write; the render's guard
/// answers both, so either would pass with this one deleted. Source-level for the reason those
/// are: the race needs a detached pass to finish after a page turn, which no hosted view arranges.
@Suite struct CompareDiffHopGuardScanTests {

    private static func refreshRasters() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/CompareCopiesSheet.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read CompareCopiesSheet.swift — this check is vacuous")
        let start = try #require(source.range(of: "private func refreshRasters() async {"),
                                 "`refreshRasters` is gone or renamed — re-aim this scan")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ")?.lowerBound
            ?? rest.range(of: "\n    func ")?.lowerBound ?? rest.endIndex
        // Whole-line comments out: a comment quoting the guard is not the guard.
        return rest[..<end].split(separator: "\n")
            .filter { !$0.drop { $0 == " " }.hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test func theComparisonsResultIsGuardedBeforeItIsHeld() throws {
        let body = try Self.refreshRasters()
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
