import Testing
import Sync
@testable import FileExplorer

/// A column click's navigation is handed to the next runloop turn (writing `browsePath` from
/// inside the List's own selection commit is the mid-commit sibling write that drops clicks).
/// These pin the staleness test that decides whether that block still speaks for the stack when
/// it finally runs.
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

    /// The common path, and the one a naive check breaks: the tap gesture fires on mouse-up and
    /// drills synchronously, so by the time the block runs the stack ALREADY equals the target.
    /// Treating that as stale would drop every navigation the tap made — i.e. all of them.
    @Test func testAppliesWhenTheTapGestureAlreadyDrilledToTheSameTarget() {
        let target = path("Documents")
        #expect(DeferredColumnNavigation.isStillValid(
            current: target, computedAgainst: path(), target: target))
    }

    /// The regression. `‹` pops the stack back to the root before the block drains; re-applying
    /// the click's drill on top of it silently undoes the Back press.
    @Test func testStandsDownWhenBackHasAlreadyMovedTheStack() {
        #expect(DeferredColumnNavigation.isStillValid(
            current: path(), computedAgainst: path("Documents"), target: path("Documents", "Invoices")
        ) == false)
    }

    /// Same shape from the other direction: a mirrored drill (or a republish prune) landed a
    /// different stack while this block was queued.
    @Test func testStandsDownWhenSomethingElseNavigatedElsewhere() {
        #expect(DeferredColumnNavigation.isStillValid(
            current: path("Photos"), computedAgainst: path(), target: path("Documents")
        ) == false)
    }
}
