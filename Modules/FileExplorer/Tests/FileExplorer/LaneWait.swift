import AppKit
import Sync

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
/// clears both. A lane that never comes free hangs the wait rather than failing it; that lane would
/// hang every PDF suite in the run.
enum LaneWait {
    @MainActor
    static func pump(_ window: NSWindow, passes: Int = LayoutPumpWait.pumpFloor,
                     until condition: () -> Bool) async -> (held: Bool, passes: Int) {
        for pass in 1...passes {
            window.layoutIfNeeded()
            if condition() { return (true, pass) }
            await PDFKitSerialAccess.perform {}
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        window.layoutIfNeeded()
        return (condition(), passes + 1)
    }
}
