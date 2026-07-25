import Testing
import Foundation
import Sync
@testable import FileExplorer

/// Pins the per-file filing cursor — the gate in front of `applyAutomationFiling`, which MOVES
/// files. It lived as four loose `@State` vars in `AutomationsLens`, so none of these rules were
/// reachable by a test: which rows reach the destructive call, whether a cancel can leak approvals,
/// and whether the cursor can run past its queue.
@Suite struct FilingWalkthroughTests {

    private func row(_ name: String) -> AutomationDryRunRow {
        AutomationDryRunRow(id: "/inbox/\(name)", fileName: name, ruleID: UUID(), ruleName: "Rule",
                            verdict: .wouldFile(destination: "Docs"),
                            destinationDir: URL(fileURLWithPath: "/root/Docs"), destinationLabel: "Docs")
    }

    @Test func approvingEveryFileFilesEveryFile() {
        var walk = FilingWalkthrough()
        walk.start([row("a.pdf"), row("b.pdf")])

        #expect(walk.advance(approved: true) == nil)          // not the last row yet
        let toFile = walk.advance(approved: true)
        #expect(toFile?.map(\.fileName) == ["a.pdf", "b.pdf"])
        #expect(!walk.isRunning)                              // and the walkthrough is over
    }

    @Test func skippedFilesAreNotFiled() {
        var walk = FilingWalkthrough()
        walk.start([row("keep.pdf"), row("skip.pdf"), row("keep2.pdf")])

        _ = walk.advance(approved: true)
        _ = walk.advance(approved: false)
        let toFile = walk.advance(approved: true)

        // The skipped row must not ride along — this is the assertion that a wrong cursor would
        // break by appending the row at the OLD index, filing something the user declined.
        #expect(toFile?.map(\.fileName) == ["keep.pdf", "keep2.pdf"])
    }

    @Test func skippingEverythingFilesNothing() {
        var walk = FilingWalkthrough()
        walk.start([row("a.pdf"), row("b.pdf")])
        _ = walk.advance(approved: false)
        let toFile = walk.advance(approved: false)
        // Non-nil (the walkthrough ended) but EMPTY — the caller must not read "finished" as
        // "file everything".
        #expect(toFile != nil)
        #expect(toFile?.isEmpty == true)
    }

    @Test func cancellingDiscardsApprovalsSoNothingIsFiled() {
        var walk = FilingWalkthrough()
        walk.start([row("a.pdf"), row("b.pdf"), row("c.pdf")])
        _ = walk.advance(approved: true)
        _ = walk.advance(approved: true)

        walk.cancel()

        // The card promises nothing moves until the last decision; a cancel must honour that even
        // with approvals already banked.
        #expect(!walk.isRunning)
        #expect(walk.approved.isEmpty)
        #expect(walk.queue.isEmpty)
        #expect(walk.current == nil)
    }

    @Test func theCursorNeverRunsPastItsQueue() {
        var walk = FilingWalkthrough()
        walk.start([row("only.pdf")])
        #expect(walk.current?.fileName == "only.pdf")

        _ = walk.advance(approved: true)

        // After the last decision `current` is nil rather than an out-of-range read. The view used
        // to do `filingQueue[filingIndex]` behind a bounds check its caller made separately, and a
        // Swift array subscript out of range is a fatal trap — drift there crashes the app.
        #expect(walk.current == nil)
        // Further advances are inert rather than trapping or re-filing.
        #expect(walk.advance(approved: true) == nil)
    }

    @Test func startingWithNoRowsStartsNothing() {
        var walk = FilingWalkthrough()
        walk.start([])
        #expect(!walk.isRunning)
        #expect(walk.current == nil)
    }

    @Test func theDisplayPositionIsOneBasedAndClamped() {
        var walk = FilingWalkthrough()
        walk.start([row("a.pdf"), row("b.pdf")])
        #expect(walk.displayPosition == 1)
        _ = walk.advance(approved: true)
        #expect(walk.displayPosition == 2)
    }

    @Test func aFreshStartClearsThePreviousRunsApprovals() {
        var walk = FilingWalkthrough()
        walk.start([row("old.pdf"), row("old2.pdf")])
        _ = walk.advance(approved: true)

        walk.start([row("new.pdf")])
        let toFile = walk.advance(approved: true)

        #expect(toFile?.map(\.fileName) == ["new.pdf"])
    }
}
