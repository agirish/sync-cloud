import Foundation
import Testing

/// Polls until `condition` holds, and fails at the caller when it never does.
///
/// A copy of the helpers in `SyncCloudTests/TestSupport.swift` and
/// `Modules/Sync/Tests/Sync/TestSupport.swift`: a test target can't import another's test code. A
/// wait that just returns when it gives up makes "it happened" and "I stopped waiting" the same
/// result (`docs/flaky-tests.md`, "Fixed pumps and fixed sleeps").
///
/// A deadline in seconds shrinks under load, so the loop runs at least `waitPollFloor` times
/// whatever the clock says, and the failure reports the poll count: a handful means starved,
/// hundreds means disproved.
@MainActor
func waitUntil(
    _ what: Comment,
    timeout: TimeInterval = 5,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    var polls = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    while polls < waitPollFloor || ContinuousClock.now < deadline {
        polls += 1
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "\(what.rawValue) — still false after \(polls) polls",
            sourceLocation: sourceLocation)
}

/// The fewest polls `waitUntil` makes before it may give up, however little of its deadline is
/// left. Same number, for the same reason, as the copies in `Modules/Sync/Tests/Sync/TestSupport
/// .swift` and `SyncCloudTests/TestSupport.swift`.
let waitPollFloor = 50
