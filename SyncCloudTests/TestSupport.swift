import Testing
import Foundation

/// Polls a main-actor condition until it holds or the timeout expires, recording a labeled failure
/// on timeout. The app target's counterpart to `Modules/Sync/Tests/Sync/TestSupport.swift`'s helper,
/// and for the same reason: a fixed `Task.sleep` long enough to be reliable is also long enough to
/// be slow, and one short enough to be quick flakes the moment a parallel suite congests the main
/// actor. 13cfb93 removed the last of those from the Sync suites after proving they lose the race
/// on a loaded CI runner; always wait for the observable effect, never a guessed duration.
@MainActor
func waitUntil(_ what: Comment, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), what)
}
