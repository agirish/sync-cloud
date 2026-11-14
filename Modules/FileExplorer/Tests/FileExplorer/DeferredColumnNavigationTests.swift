import Testing
import Sync
@testable import FileExplorer

/// A column click's navigation runs on the next runloop turn, because writing `browsePath` inside
/// the List's own selection commit drops clicks. These pin the check that decides whether the
/// block still speaks for the stack when it runs.
@Suite struct DeferredColumnNavigationTests {

    /// (current, computed against, target) as path components, and whether the block applies.
    /// Nothing moved: it applies. The tap gesture drills synchronously on mouse-up, so the stack
    /// can already equal the target: not stale, though a naive check calls it so. `‹` popped the
    /// stack before the block drained: re-applying would silently undo the Back press. A mirrored
    /// drill or a republish prune landed a different stack: stand down.
    @Test(arguments: [
        ([], [], ["Documents"], true),
        (["Documents"], [], ["Documents"], true),
        ([], ["Documents"], ["Documents", "Invoices"], false),
        (["Photos"], [], ["Documents"], false),
    ] as [([String], [String], [String], Bool)])
    func testIsStillValid(current: [String], computedAgainst: [String], target: [String], applies: Bool) {
        #expect(DeferredColumnNavigation.isStillValid(
            current: PaneBrowsePath(components: current),
            computedAgainst: PaneBrowsePath(components: computedAgainst),
            target: PaneBrowsePath(components: target)) == applies)
    }
}
