import Testing
import Events
import EventsTestSupport
import Foundation
import Sync
@testable import FileExplorer

/// Pins the per-file filing cursor, the gate in front of `applyAutomationFiling`, which moves
/// files: which rows reach the destructive call, whether a cancel can leak approvals, and whether
/// the cursor can run past its queue.
@Suite struct FilingWalkthroughTests {

    private func row(_ name: String) -> AutomationDryRunRow { .walkFixture(name) }

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

        // A wrong cursor would append the row at the old index, filing something declined.
        #expect(toFile?.map(\.fileName) == ["keep.pdf", "keep2.pdf"])
    }

    @Test func skippingEverythingFilesNothing() {
        var walk = FilingWalkthrough()
        walk.start([row("a.pdf"), row("b.pdf")])
        _ = walk.advance(approved: false)
        let toFile = walk.advance(approved: false)
        // Non-nil (ended) but empty: "finished" must not read as "file everything".
        #expect(toFile != nil)
        #expect(toFile?.isEmpty == true)
    }

    @Test func cancellingDiscardsApprovalsSoNothingIsFiled() {
        var walk = FilingWalkthrough()
        walk.start([row("a.pdf"), row("b.pdf"), row("c.pdf")])
        _ = walk.advance(approved: true)
        _ = walk.advance(approved: true)

        walk.cancel(because: .dismissed)

        // Nothing moves until the last decision, even with approvals already banked.
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

        // Nil rather than an out-of-range subscript, which would crash the app; further advances
        // are inert rather than trapping or re-filing.
        #expect(walk.current == nil)
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

        // The queue carries the old preview's destinations, so resuming would file to homes the
        // fresh preview no longer proposes: retired outright, banked approval and all.
        #expect(!walk.isRunning)
        #expect(walk.current == nil)
        #expect(walk.approved.isEmpty)
        #expect(walk.queue.isEmpty)
    }

    @Test func aDryRunFinishingLeavesAWalkthroughAlone() {
        var walk = FilingWalkthrough()
        walk.start([row("a.pdf"), row("b.pdf")])
        _ = walk.advance(approved: true)

        // Only the rising edge supersedes; clearing on the falling edge, when the run ends, would
        // discard a review the user had started.
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

/// Every retirement of an in-progress walkthrough writes one log line naming its cause: to the user
/// a dismissal and a new-preview retirement look identical, so only `~/sync-cloud.log` can tell.
///
/// `@MainActor` because `LogCapture` is main-actor state; `.serialized` because the tests share one
/// process-wide log stream and one asserts an absence. Each reading comes from a capture opened
/// before the call and `#require`s its own closing line, so the absence cannot pass on a capture
/// that heard nothing.
@MainActor
@Suite(.serialized) struct FilingWalkthroughLogTests {

    private func row(_ name: String) -> AutomationDryRunRow { .walkFixture(name) }

    /// Everything logged while `act` runs, read from a capture opened before it, never from
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

    /// A cancel with nothing running is a reset, not a loss; logging it would fabricate
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
