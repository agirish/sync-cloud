import Testing
import Foundation

/// **Every path that clears the rasters must also orphan the render in flight.**
///
/// `.task(id:)` cancels the running render when the mode, page or pair changes, and Swift
/// cancellation is cooperative: the two `PagePairRaster` awaits resume regardless and nothing
/// below them asks `Task.isCancelled`. So the ONLY thing standing between a superseded render and
/// the state it is about to overwrite is `guard rasterToken == token`. The two completion points
/// take that guard; the two CLEARERS have to rotate the token, or that guard is still satisfied
/// when the superseded run lands and it re-fills what was just cleared — two full-page CGImages
/// and a difference image retained by a mode that draws none of them, ready to be shown as this
/// page's answer the moment an overlay mode comes back. On the pair reset it is worse than
/// wasteful: the render describes two files that are no longer on screen.
///
/// The rule is enforced by construction — one `clearRasters()` both call — so this scan pins the
/// two things construction cannot: that the helper rotates BEFORE it clears, and that neither
/// clearer has grown its own copy of the three assignments.
///
/// **A scan rather than a mounted-view test, deliberately.** Reproducing the window means racing a
/// real PDF render against a mode switch and asserting on what did NOT land — a timing test over
/// an absence, which is how flakes are written. The rule is three lines in one function; this pins
/// the rule and says so, rather than pretending to have measured the race.
///
/// Its own file for the reason `TrashFallbackWiringTests` is in its own file: a scan filed inside
/// a suite about something else is a scan nobody opens and nobody maintains.
@Suite struct CompareRasterTokenScanTests {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer/CompareCopiesSheet.swift")
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read CompareCopiesSheet.swift — this check is vacuous")
    }

    @Test func theOneClearerRotatesTheTokenBeforeItClears() throws {
        let source = try source()
        // The positive control for the read itself: a rename fails this loudly rather than
        // passing over a file it could not find the subject in.
        let start = try #require(source.range(of: "private func clearRasters() {"),
                                 "`clearRasters` is gone or renamed — re-aim this scan")
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])

        let rotate = try #require(body.range(of: "rasterToken = UUID()"), """
                `clearRasters` drops the rasters without rotating `rasterToken`, so a render \
                already in flight still satisfies its own guard and re-fills them
                """)
        let clear = try #require(body.range(of: "pageComparison = PageComparison()"),
                                 "`clearRasters` no longer clears the comparison — re-aim this scan")
        #expect(rotate.lowerBound < clear.lowerBound,
                "the token is rotated after the clear, which leaves the same window open")
    }

    /// And nothing clears that state without either rotating the token or standing behind it.
    ///
    /// There are exactly two legal shapes. A CLEARER rotates first — that is `clearRasters`. A
    /// COMPLETION writes what it just computed, and reaches its write only past
    /// `guard rasterToken == token`, so a superseded run never gets there. A third shape — a bare
    /// `pageComparison = PageComparison()` with neither above it — is the defect this whole file
    /// is about, and it is what a well-meant "clear it here too" edit looks like.
    @Test func everyWriteEitherRotatesTheTokenOrStandsBehindIt() throws {
        let source = try source()
        // Split into members, so the question is asked WITHIN the function that writes rather
        // than over a window of characters. A character window was the first shape of this scan
        // and it was wrong twice over: it excused a write whose guard happened to be near, and it
        // failed the moment an unrelated log block widened the gap in a function that was correct.
        let members = source.components(separatedBy: "\n    private func ")
            .flatMap { $0.components(separatedBy: "\n    func ") }
        // The `@State` declaration is a property, not a write, and carries no token — the leading
        // indent tells them apart.
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
}
