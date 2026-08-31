import Foundation
import Testing
@testable import FileExplorer

/// Every asynchronous write into the compare surface's state is guarded against landing late.
///
/// **The surface has three of them and only two were guarded.** The raster path takes a token
/// before its hop and re-reads it after; so does the verify. The text diff did neither — it ran its
/// Myers pass in a `Task.detached`, which `.task(id:)` cancellation does not reach and which has no
/// ordering against another detached pass, then assigned the result unconditionally. Swapping from
/// a large text pair to a small one could therefore draw the small pair's diff and then overwrite
/// it with the large pair's, under the new pair's name, until the mode was left and re-entered.
///
/// **Source-level, and that is a real limitation — it pins the shape, not the behaviour.** The race
/// needs two detached passes to finish out of order, which no deterministic test can arrange
/// through a hosted view; what a test can do is refuse to let the guard be deleted. Deleting either
/// line of any pair below fails this suite. `ComparePairViewingTests` owns the behaviour that IS
/// drivable — the observers, the latch, the page turn.
@Suite struct CompareCopiesStaleWriteTests {

    private static let sheet = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // …/Tests/FileExplorer
        .deletingLastPathComponent()   // …/Tests
        .deletingLastPathComponent()   // …/FileExplorer
        .appendingPathComponent("Sources/FileExplorer/CompareCopiesSheet.swift")

    private static func source() throws -> String {
        try #require(try? String(contentsOf: sheet, encoding: .utf8),
                     "cannot read \(sheet.path) — every check below would be vacuous")
    }

    /// The three async paths, each named by the state it writes.
    @Test(arguments: ["rasterToken", "verifyToken", "textDiffToken"])
    func everyAsyncWriteTakesATokenAndRechecksIt(_ token: String) throws {
        let text = try Self.source()
        #expect(text.contains("\(token) = token"),
                "\(token) is never taken before the hop — nothing to compare afterwards")
        #expect(text.contains("guard \(token) == token"),
                "\(token) is never re-read after the hop — a superseded result still lands")
    }

    /// The positive control. Without it, renaming the tokens would empty the suite silently: every
    /// case above would look for strings nothing contains, and find nothing, and pass.
    @Test func theSurfaceStillHasThreeAsyncWriters() throws {
        let text = try Self.source()
        for anchor in ["private func refreshRasters", "private func runVerify",
                       "private func refreshTextDiff"] {
            #expect(text.contains(anchor), "\(anchor) is gone — this suite is guarding nothing")
        }
    }

    /// The reset that runs when a new pair arrives has to clear the diff too — the guard above
    /// stops a stale write, and this stops a stale *read* of what the previous pair left behind.
    ///
    /// **Read out of the reset block, not out of the file.** Both lines also appear in
    /// `refreshTextDiff`, which clears the same two states when the mode leaves the diff — so a
    /// whole-file `contains` passed on those copies alone and would have gone on passing with the
    /// reset's own lines deleted.
    @Test func aFreshPairClearsTheTextDiffAndItsFocus() throws {
        let reset = try #require(Self.pairResetBlock(try Self.source()),
                                 "the pair reset block moved — this check is reading the wrong code")
        #expect(reset.contains("textDiff = nil"))
        #expect(reset.contains("focusedRegion = nil"),
                "the stepper keeps the previous pair's position, and ↓ resumes mid-file")
    }

    /// **A verify in flight when the pair changes has to be orphaned by the reset itself.**
    ///
    /// The other two tokens look after themselves: `refreshRasters` and `refreshTextDiff` are taken
    /// inside `.task(id:)`s keyed on the pair, so a new pair re-runs them and rotates them on the
    /// way in. A verify is started by the READER, from a button, and nothing re-runs it — so
    /// clearing `verify` left an in-flight hash whose token still matched, and its verdict landed
    /// under the new pair's name. "These two are byte-for-byte identical right now" about two files
    /// the surface is no longer showing is the worst sentence this pane can print.
    @Test func aFreshPairOrphansAVerifyThatIsStillRunning() throws {
        let text = try Self.source()
        let reset = try #require(Self.pairResetBlock(text),
                                 "the pair reset block moved — this check is reading the wrong code")
        #expect(reset.contains("verifyToken = UUID()"),
                "the reset clears the verdict but leaves the token, so a stale hash still lands")
        // The premise, so this cannot pass because the reset stopped clearing things generally.
        #expect(reset.contains("verify = .idle"))
    }

    /// The reset block's text, from the marker that opens it to the end of the `.task`. Isolated
    /// rather than searched for in the whole file: `verifyToken = UUID()` also appears where the
    /// state is declared, and a whole-file `contains` would pass on that alone.
    private static func pairResetBlock(_ text: String) -> String? {
        guard let start = text.range(of: "**A fresh pair inherits nothing.**"),
              let end = text.range(of: "if !modes.contains(mode)", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// The isolation itself, since every check above rests on it. A block that had swallowed the
    /// whole file would make those checks vacuous in exactly the way they were written to avoid.
    @Test func theResetBlockIsTheResetBlockAndNotTheWholeFile() throws {
        let text = try Self.source()
        let reset = try #require(Self.pairResetBlock(text))
        #expect(reset.count < text.count / 4, "the block spans \(reset.count) of \(text.count) characters")
        #expect(!reset.contains("private func refreshTextDiff"),
                "the block reaches into refreshTextDiff, whose own clears would satisfy every check")
        #expect(!reset.contains("private func runVerify"),
                "the block reaches into runVerify, whose own token take would satisfy every check")
    }
}
