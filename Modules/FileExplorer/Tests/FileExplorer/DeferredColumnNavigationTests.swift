import Testing
import Sync
@testable import FileExplorer

/// A column click's navigation runs on the next runloop turn, because writing `browsePath` inside
/// the List's own selection commit drops clicks. These pin the check that decides whether the
/// block still speaks for the stack when it runs.
@Suite struct DeferredColumnNavigationTests {

    private func path(_ components: String...) -> PaneBrowsePath {
        PaneBrowsePath(components: components)
    }

    /// Nothing moved: the block is the only navigation in flight and must apply.
    @Test func testAppliesWhenTheStackHasNotMoved() {
        let atWrite = path()
        #expect(DeferredColumnNavigation.isStillValid(
            current: atWrite, computedAgainst: atWrite, target: path("Documents")))
    }

    /// The common path, which a naive check breaks: the tap gesture drills synchronously on
    /// mouse-up, so the stack already equals the target when the block runs. That is not stale.
    @Test func testAppliesWhenTheTapGestureAlreadyDrilledToTheSameTarget() {
        let target = path("Documents")
        #expect(DeferredColumnNavigation.isStillValid(
            current: target, computedAgainst: path(), target: target))
    }

    /// `‹` pops the stack to the root before the block drains; re-applying the click's drill would
    /// silently undo the Back press.
    @Test func testStandsDownWhenBackHasAlreadyMovedTheStack() {
        #expect(DeferredColumnNavigation.isStillValid(
            current: path(), computedAgainst: path("Documents"), target: path("Documents", "Invoices")
        ) == false)
    }

    /// The same from the other direction: a mirrored drill or a republish prune landed a different
    /// stack while this block was queued.
    @Test func testStandsDownWhenSomethingElseNavigatedElsewhere() {
        #expect(DeferredColumnNavigation.isStillValid(
            current: path("Photos"), computedAgainst: path(), target: path("Documents")
        ) == false)
    }
}
