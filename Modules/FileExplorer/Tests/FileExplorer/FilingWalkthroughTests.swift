import Testing
import Events
import EventsTestSupport
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
                            destinationDir: URL(fileURLWithPath: "/root/Docs"), destinationLabel: "Docs",
                            destinationAnchor: URL(fileURLWithPath: "/root"))
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

        walk.cancel(because: .dismissed)

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

    @Test func aNewDryRunRetiresAWalkthroughOverTheSupersededReport() {
        var walk = FilingWalkthrough()
        walk.start([row("a.pdf"), row("b.pdf"), row("c.pdf")])
        _ = walk.advance(approved: true)          // mid-review: "File 2 of 3", one approval banked

        walk.dryRunRunningChanged(to: true)       // the user hits "Preview all"

        // The queue's rows carry the destinations the OLD preview computed. Resuming the review
        // over them would file to homes the fresh preview no longer proposes, so the walkthrough
        // is retired outright — and its banked approval goes with it, since nothing has moved yet.
        #expect(!walk.isRunning)
        #expect(walk.current == nil)
        #expect(walk.approved.isEmpty)
        #expect(walk.queue.isEmpty)
    }

    @Test func aDryRunFinishingLeavesAWalkthroughAlone() {
        var walk = FilingWalkthrough()
        walk.start([row("a.pdf"), row("b.pdf")])
        _ = walk.advance(approved: true)

        // Only the RISING edge supersedes. The same flag goes back to false when the run ends, and
        // clearing on that edge would silently discard a review the user had legitimately started.
        walk.dryRunRunningChanged(to: false)

        #expect(walk.isRunning)
        #expect(walk.current?.fileName == "b.pdf")
        let toFile = walk.advance(approved: true)
        #expect(toFile?.map(\.fileName) == ["a.pdf", "b.pdf"])
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

/// Every retirement of an in-progress walkthrough writes ONE log line naming its cause. From the
/// user's side a dismissal and a new-preview retirement look identical — the card just vanishes —
/// and neither used to leave a trace, so "my walkthrough disappeared" was undiagnosable from
/// `~/sync-cloud.log`.
///
/// `@MainActor` because `LogCapture` is main-actor state, and `.serialized` because the three tests
/// assert on (and one asserts the ABSENCE of) the same process-wide log stream — in-suite
/// parallelism would let one test's retirement line land inside another's window. Every reading
/// comes from a capture opened before the call, which the shared buffer's 1000-line trim cannot
/// empty, and `#require`s a closing line of its own from it, so the absence cannot pass on a
/// capture that heard nothing.
@MainActor
@Suite(.serialized) struct FilingWalkthroughLogTests {

    private func row(_ name: String) -> AutomationDryRunRow {
        AutomationDryRunRow(id: "/inbox/\(name)", fileName: name, ruleID: UUID(), ruleName: "Rule",
                            verdict: .wouldFile(destination: "Docs"),
                            destinationDir: URL(fileURLWithPath: "/root/Docs"), destinationLabel: "Docs",
                            destinationAnchor: URL(fileURLWithPath: "/root"))
    }

    /// Everything logged while `act` runs, read from a capture opened before it — never from
    /// `Logger.shared.entries`, which is a rolled 1000-line window.
    private func window(_ act: () -> Void) async throws -> [String] {
        let log = LogCapture()
        act()
        let close = "walkthrough log window close \(UUID().uuidString.prefix(8))"
        Logger.shared.debug(close)
        let messages = await log.entries.map(\.message)
        let closed = messages.contains(close)
        try #require(closed, "the capture never saw this window's own closing line — this reading is vacuous")
        return messages
    }

    @Test func aDismissalSaysWhereItStoppedAndWhatItDiscarded() async throws {
        var walk = FilingWalkthrough()
        walk.start([row("a.pdf"), row("b.pdf"), row("c.pdf")])
        _ = walk.advance(approved: true)   // "File 2 of 3", one approval banked

        let logged = try await window { walk.cancel(because: .dismissed) }
        #expect(logged.contains(where: {
            $0.contains("Filing walkthrough dismissed (esc or Cancel) at file 2 of 3 — 1 approval(s) discarded, nothing filed")
        }), "no dismissal line in \(Array(logged))")
    }

    @Test func aNewPreviewRetirementNamesThePreviewAsTheCause() async throws {
        var walk = FilingWalkthrough()
        walk.start([row("a.pdf"), row("b.pdf"), row("c.pdf")])
        _ = walk.advance(approved: false)

        let logged = try await window { walk.dryRunRunningChanged(to: true) }
        #expect(logged.contains(where: {
            $0.contains("Filing walkthrough retired by a new rules preview at file 2 of 3 — 0 approval(s) discarded, nothing filed")
        }), "no retirement line in \(Array(logged))")
    }

    /// A cancel with nothing running is a state reset, not a loss — logging it would fabricate
    /// disappearances (the dry-run rising edge fires whether or not a walkthrough exists).
    @Test func retiringNothingWritesNothing() async throws {
        var walk = FilingWalkthrough()
        let logged = try await window {
            walk.cancel(because: .dismissed)
            walk.dryRunRunningChanged(to: true)
        }
        #expect(!logged.contains(where: { $0.contains("Filing walkthrough") }),
                "an idle cancel wrote a retirement line: \(Array(logged))")
    }
}
