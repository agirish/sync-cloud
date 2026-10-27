import AppKit
import os
import Sync
import Testing

/// The wait for a mounted view whose condition rests on work queued in `PDFKitSerialAccess`'s
/// lane — a `PDFPairView`'s two opens, a PDF find's page turns. **Paced by the lane, not by
/// seconds or main-actor turns.**
///
/// In a full package run the lane is shared by every PDF suite, and some of them hold it on purpose
/// (`LaneHold`), so a turn queued there can wait past 30 s (`LaneHold.patience`). A
/// `LayoutPumpWait.pump` spends its deadline and its floor while the work it waits for is still in
/// the queue, and fails with nothing wrong: `ComparePairViewingTests` reported "the pair never
/// loaded (51 pumps)" after 616 s on CI (run 40214697085), and `EditorContentOpenMountedTests`
/// counted one of a PDF's two matches, its find still searching page two (run 40216946771).
///
/// Each pass here lays the window out, checks, and then takes a lane turn of its own. The lane is
/// serial and first come, first served, so that turn ends only after everything queued ahead of
/// it, and the sleep after gives the main actor the turn the work's answer hops back on. A pass is
/// therefore at least one lane pass AND one main-actor turn, and `LayoutPumpWait.pumpFloor` of them
/// clears both.
///
/// **A lane that never comes free fails the wait, after `ceiling`** — a time no healthy run reaches,
/// twice `LaneHold.patience`, since a turn can wait behind holds that each take up to that. It
/// records an issue naming the pass it stopped at, rather than hanging the run until CI's own
/// timeout, which names nothing.
enum LaneWait {
    static let ceiling: TimeInterval = 2 * LaneHold.patience

    @MainActor
    static func pump(_ window: NSWindow, passes: Int = LayoutPumpWait.pumpFloor,
                     ceiling: TimeInterval = ceiling,
                     until condition: () -> Bool) async -> (held: Bool, passes: Int) {
        let deadline = Date().addingTimeInterval(ceiling)
        for pass in 1...passes {
            window.layoutIfNeeded()
            if condition() { return (true, pass) }
            guard await laneTurn(before: deadline) else {
                Issue.record("LaneWait: the lane gave no turn within \(String(format: "%g", ceiling)) s — stopped at pass \(pass) of \(passes)")
                window.layoutIfNeeded()
                return (condition(), pass)
            }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
        return (condition(), passes + 1)
    }

    /// One turn in the lane, or false once `deadline` passes first. The turn is not cancellable, so
    /// it is left queued; whichever answers first resumes, and the timer is stopped when the turn wins.
    private static func laneTurn(before deadline: Date) async -> Bool {
        await withCheckedContinuation { (answer: CheckedContinuation<Bool, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { got in
                if resumed.withLock({ done in defer { done = true }; return !done }) { answer.resume(returning: got) }
            }
            let timer = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000))
                finish(false)
            }
            Task.detached {
                await PDFKitSerialAccess.perform {}
                finish(true)
                timer.cancel()
            }
        }
    }
}
