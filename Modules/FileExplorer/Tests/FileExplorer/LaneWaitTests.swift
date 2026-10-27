import AppKit
import Testing

/// `LaneWait.pump`'s ceiling: a lane that never comes free fails the wait, naming the pass, instead
/// of hanging the run.
@MainActor
struct LaneWaitTests {
    @Test func aLaneThatNeverComesFreeFailsTheWaitNamingThePass() async throws {
        let hold = LaneHold()
        defer { hold.release() }
        try #require(await hold.waitUntilHeld(), "the lane never came free to be held")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        var result: (held: Bool, passes: Int) = (true, 0)
        await withKnownIssue("the ceiling's own issue") {
            result = await LaneWait.pump(window, ceiling: 0.3) { false }
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("the lane gave no turn within 0.3 s — stopped at pass 1 of") }
        }
        #expect(result.held == false)
        #expect(result.passes == 1)
    }
}
