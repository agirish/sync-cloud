import AppKit
import os
import Sync
import Testing

/// The wait for a mounted view whose condition rests on work queued in `PDFKitSerialAccess`'s
/// lane (a `PDFPairView`'s two opens, a PDF find's page turns), paced by the lane rather than by
/// seconds or main-actor turns.
///
/// In a full package run every PDF suite shares the lane and some hold it on purpose (`LaneHold`),
/// so a queued turn can wait past 30 s; a `LayoutPumpWait.pump` would spend its deadline and floor
/// while the work is still queued, and fail with nothing wrong.
///
/// Each pass lays the window out, checks, then takes a lane turn of its own. The lane is serial and
/// first come, first served, so that turn ends only after everything queued ahead of it, and the
/// sleep after gives the main actor the turn the answer hops back on: `pumpFloor` passes clear both.
///
/// `ceiling` is twice `LaneHold.patience`, since a turn can wait behind holds that each take up to
/// that. Past it the wait records an issue naming the pass, rather than hanging until CI's timeout.
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
