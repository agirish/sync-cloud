import Foundation
import Testing
@testable import FileExplorer

/// Every asynchronous write into the compare surface's state is guarded against landing late: the
/// raster, verify and text-diff paths each take a token before their hop and re-read it after. The
/// text diff runs in a `Task.detached`, which `.task(id:)` cancellation doesn't reach, so without
/// the token a large pair's diff could land after a small one's, under the new pair's name.
/// Source-level, since no deterministic test can make two detached passes finish out of order.
/// `ComparePairViewingTests` owns the drivable behaviour.
@Suite struct CompareCopiesStaleWriteTests {

    private static func source() throws -> String { try SourceText.fileExplorer("CompareCopiesSheet.swift") }

    /// The three async paths, each named by the state it writes.
    @Test(arguments: ["rasterToken", "verifyToken", "textDiffToken"])
    func everyAsyncWriteTakesATokenAndRechecksIt(_ token: String) throws {
        let text = try Self.source()
        #expect(text.contains("\(token) = token"),
                "\(token) is never taken before the hop — nothing to compare afterwards")
        #expect(text.contains("guard \(token) == token"),
                "\(token) is never re-read after the hop — a superseded result still lands")
    }

    /// The reset for a new pair clears the diff too: the guard stops a stale write, this stops a
    /// stale read of what the previous pair left. Read from the reset block, not the file, because
    /// `refreshTextDiff` clears the same two states and would satisfy a whole-file `contains`.
    @Test func aFreshPairClearsTheTextDiffAndItsFocus() throws {
        let reset = try #require(Self.pairResetBlock(try Self.source()),
                                 "the pair reset block moved — this check is reading the wrong code")
        #expect(reset.contains("textDiff = nil"))
        #expect(reset.contains("focusedRegion = nil"),
                "the stepper keeps the previous pair's position, and ↓ resumes mid-file")
    }

    /// The reset itself must orphan a verify in flight. The raster and text-diff tokens rotate in
    /// `.task(id:)`s keyed on the pair, but a verify starts from a button and nothing re-runs it,
    /// so a stale hash would print "byte-for-byte identical" about two files no longer shown.
    @Test func aFreshPairOrphansAVerifyThatIsStillRunning() throws {
        let text = try Self.source()
        let reset = try #require(Self.pairResetBlock(text),
                                 "the pair reset block moved — this check is reading the wrong code")
        #expect(reset.contains("verifyToken = UUID()"),
                "the reset clears the verdict but leaves the token, so a stale hash still lands")
        // The premise, so this cannot pass because the reset stopped clearing things generally.
        #expect(reset.contains("verify = .idle"))
    }

    /// The reset block's text, from its marker to the end of the `.task`. Isolated because
    /// `verifyToken = UUID()` also appears where the state is declared.
    private static func pairResetBlock(_ text: String) -> String? {
        guard let start = text.range(of: "**A fresh pair inherits nothing.**"),
              let end = text.range(of: "if !modes.contains(mode)", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    /// The isolation itself, which every check above rests on: a block that swallowed the whole
    /// file would make them vacuous.
    @Test func theResetBlockIsTheResetBlockAndNotTheWholeFile() throws {
        let text = try Self.source()
        let reset = try #require(Self.pairResetBlock(text))
        #expect(reset.count < text.count / 4, "the block spans \(reset.count) of \(text.count) characters")
        #expect(!reset.contains("private func refreshTextDiff"),
                "the block reaches into refreshTextDiff, whose own clears would satisfy every check")
        #expect(!reset.contains("private func runVerify"),
                "the block reaches into runVerify, whose own token take would satisfy every check")
        // The positive control for those absences, and for the suite: renaming the async writers
        // would leave it guarding code that no longer exists.
        for anchor in ["private func refreshRasters", "private func runVerify",
                       "private func refreshTextDiff"] {
            #expect(text.contains(anchor), "\(anchor) is gone — this suite is guarding nothing")
        }
    }
}
