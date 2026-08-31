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
    @Test func aFreshPairClearsTheTextDiffAndItsFocus() throws {
        let text = try Self.source()
        #expect(text.contains("textDiff = nil"))
        #expect(text.contains("focusedRegion = nil"),
                "the stepper keeps the previous pair's position, and ↓ resumes mid-file")
    }
}
