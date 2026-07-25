import Testing
import AppKit
import Foundation
import Sync
import Design
import SwiftUI
@testable import SyncCloud

/// Deterministic stand-in for the scheduler's wait. Every started timer parks here until the test
/// releases it, so "hasn't fired yet" and "has fired now" are exact.
///
/// The suite used to run the real clock on shortened windows and assert around it — sleep 300ms of
/// a 500ms window, expect no dismissal. That fails a perfectly correct scheduler whenever a loaded
/// runner stretches the 300ms past 500ms, which is the flake class 13cfb93 removed from the Sync
/// suites after reproducing it 2 times in 4. Releasing the wait explicitly takes the clock out of
/// the assertions entirely: what a timer WAITS FOR is now checked directly, and what it does when
/// that elapses is triggered on demand.
private final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var requested: [UInt64] = []

    /// The closure handed to the scheduler in place of `Task.sleep`.
    var sleep: @Sendable (UInt64) async -> Void {
        { [self] delay in
            await withCheckedContinuation { continuation in
                lock.lock()
                requested.append(delay)
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// The delays the scheduler has asked to wait out, in order — one entry per started timer.
    var requestedDelays: [UInt64] {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }

    /// Lets every parked wait finish. A timer cancelled meanwhile resumes and then exits through
    /// the scheduler's own `Task.isCancelled` check without dismissing — exactly the behaviour
    /// several of these tests are about.
    func releaseAll() {
        lock.lock()
        let all = waiters
        waiters = []
        lock.unlock()
        for continuation in all { continuation.resume() }
    }
}

/// Regression coverage for the operation banner's auto-dismiss timer. The old implementation
/// spawned one detached sleep per banner change and compared by string value, so a replacement
/// banner with identical text was dismissed early by the first banner's leftover timer.
/// Now also pins the per-severity rules: warnings outlive successes, errors are sticky, and
/// hovering pauses the timer (hover exit restarts the full window, not the remainder).
@Suite struct BannerDismissSchedulerTests {

    private static let successDelay: UInt64 = 200_000_000
    private static let warningDelay: UInt64 = 500_000_000
    private static let testDelays = BannerDismissScheduler.Delays(
        successNanoseconds: successDelay,
        warningNanoseconds: warningDelay
    )

    @MainActor
    @Test func testReplacementBannerWithSameTextRestartsTheDismissWindow() async {
        let clock = ManualSleeper()
        let scheduler = BannerDismissScheduler(delays: Self.testDelays, sleep: clock.sleep)
        var dismissCount = 0

        scheduler.bannerChanged(to: .success("Deleted 3 items")) { dismissCount += 1 }
        await waitUntil("the first timer starts") { clock.pendingCount == 1 }
        // A second operation posts the exact same message before the first window elapses.
        scheduler.bannerChanged(to: .success("Deleted 3 items")) { dismissCount += 1 }
        await waitUntil("the replacement starts its own timer") { clock.pendingCount == 2 }

        // Two FULL windows were requested — the replacement did not inherit a remainder.
        #expect(clock.requestedDelays == [Self.successDelay, Self.successDelay])

        // Releasing both: the superseded first timer is cancelled and must not dismiss, so exactly
        // one dismissal fires. (Under the original bug the leftover timer fired too.)
        clock.releaseAll()
        await waitUntil("exactly one dismissal fires") { dismissCount == 1 }
        #expect(dismissCount == 1)
    }

    @MainActor
    @Test func testClearingTheBannerCancelsThePendingDismiss() async {
        let clock = ManualSleeper()
        let scheduler = BannerDismissScheduler(delays: Self.testDelays, sleep: clock.sleep)
        var dismissCount = 0

        scheduler.bannerChanged(to: .success("Copied 2 files")) { dismissCount += 1 }
        await waitUntil("the timer starts") { clock.pendingCount == 1 }
        scheduler.bannerChanged(to: nil) { dismissCount += 1 }

        clock.releaseAll()
        await waitUntil("the cancelled timer runs to completion") { clock.pendingCount == 0 }
        #expect(dismissCount == 0)
    }

    @MainActor
    @Test func testWarningGetsALongerWindowThanSuccess() async {
        let clock = ManualSleeper()
        let scheduler = BannerDismissScheduler(delays: Self.testDelays, sleep: clock.sleep)
        var dismissCount = 0

        scheduler.bannerChanged(to: .warning("3 copied; 2 failed")) { dismissCount += 1 }
        await waitUntil("the warning timer starts") { clock.pendingCount == 1 }

        // Asserted directly rather than inferred from elapsed time: the window asked for is the
        // warning one, and it is longer than a success window.
        #expect(clock.requestedDelays == [Self.warningDelay])
        #expect(Self.warningDelay > Self.successDelay)
        #expect(dismissCount == 0)

        clock.releaseAll()
        await waitUntil("the warning dismisses when its window elapses") { dismissCount == 1 }
    }

    @MainActor
    @Test func testErrorBannerIsStickyUntilManuallyClosed() async {
        let clock = ManualSleeper()
        let scheduler = BannerDismissScheduler(delays: Self.testDelays, sleep: clock.sleep)
        var dismissCount = 0

        scheduler.bannerChanged(to: .error("Copy failed")) { dismissCount += 1 }

        // Sticky means no timer is started AT ALL — a stronger statement than "nothing had fired
        // by the time we looked", which is all an elapsed-time version could ever show.
        #expect(clock.requestedDelays.isEmpty)
        #expect(dismissCount == 0)

        // Manual close clears it (the view sets the banner to nil); still no timer, no dismissal.
        scheduler.bannerChanged(to: nil) { dismissCount += 1 }
        #expect(clock.requestedDelays.isEmpty)
        #expect(dismissCount == 0)
    }

    @MainActor
    @Test func testHoverPausesTheTimerAndExitRestartsTheFullWindow() async {
        let clock = ManualSleeper()
        let scheduler = BannerDismissScheduler(delays: Self.testDelays, sleep: clock.sleep)
        var dismissCount = 0

        scheduler.bannerChanged(to: .success("Copied 2 files")) { dismissCount += 1 }
        await waitUntil("the timer starts") { clock.pendingCount == 1 }

        scheduler.hoverChanged(isHovering: true)
        // Hover cancels the running timer; releasing it proves the cancelled one cannot dismiss.
        clock.releaseAll()
        await waitUntil("the cancelled timer finishes") { clock.pendingCount == 0 }
        #expect(dismissCount == 0)

        // Exit restarts the FULL window rather than the remainder.
        scheduler.hoverChanged(isHovering: false)
        await waitUntil("hover exit starts a new timer") { clock.pendingCount == 1 }
        #expect(clock.requestedDelays == [Self.successDelay, Self.successDelay])

        clock.releaseAll()
        await waitUntil("the restarted window dismisses") { dismissCount == 1 }
    }

    @MainActor
    @Test func testBannerPostedWhileHoveringStaysUntilHoverExit() async {
        let clock = ManualSleeper()
        let scheduler = BannerDismissScheduler(delays: Self.testDelays, sleep: clock.sleep)
        var dismissCount = 0

        scheduler.bannerChanged(to: .success("First")) { dismissCount += 1 }
        await waitUntil("the first timer starts") { clock.pendingCount == 1 }
        scheduler.hoverChanged(isHovering: true)
        clock.releaseAll()
        await waitUntil("the cancelled first timer finishes") { clock.pendingCount == 0 }

        // A replacement arriving while hovered must not start a timer at all.
        scheduler.bannerChanged(to: .success("Second")) { dismissCount += 1 }
        #expect(clock.pendingCount == 0)
        #expect(dismissCount == 0)

        // The window only starts on hover exit.
        scheduler.hoverChanged(isHovering: false)
        await waitUntil("hover exit starts the replacement's timer") { clock.pendingCount == 1 }
        clock.releaseAll()
        await waitUntil("the replacement dismisses") { dismissCount == 1 }
    }

    @MainActor
    @Test func testManualCloseWhileHoveredDoesNotStrandTheNextBannersTimer() async {
        let clock = ManualSleeper()
        let scheduler = BannerDismissScheduler(delays: Self.testDelays, sleep: clock.sleep)
        var dismissCount = 0

        // Every ✕ click happens while the pointer hovers the banner, and SwiftUI never delivers
        // onHover(false) for the removed view — so the hover state must reset on clear, or the
        // next banner starts "paused" and never auto-dismisses.
        scheduler.bannerChanged(to: .success("First")) { dismissCount += 1 }
        await waitUntil("the first timer starts") { clock.pendingCount == 1 }
        scheduler.hoverChanged(isHovering: true)
        scheduler.bannerChanged(to: nil) { dismissCount += 1 }

        scheduler.bannerChanged(to: .success("Second")) { dismissCount += 1 }
        // The load-bearing assertion: the next banner DID start a timer despite the stale hover.
        // Counted on `requestedDelays`, which only grows when a timer actually starts — the first
        // banner's CANCELLED timer is still parked in the sleeper, so `pendingCount` alone would
        // be satisfied by that stale waiter and release it before the new timer had registered.
        await waitUntil("the next banner's timer starts") { clock.requestedDelays.count == 2 }
        clock.releaseAll()
        await waitUntil("it dismisses exactly once") { dismissCount == 1 }
        #expect(dismissCount == 1)
    }

    @Test func testBannerSymbolNamesExistInSFSymbols() {
        // A typo'd symbol name renders as a blank icon at runtime; pin that every name resolves.
        for severity in [OperationBanner.Severity.success, .warning, .error] {
            let name = OperationBannerStyle.iconName(for: severity)
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "missing SF Symbol \(name)")
        }
    }

    @Test func testBannerTintsComeFromTheSemanticColorTable() {
        // The banner is a severity surface, so its tints must stay pinned to Design's one
        // semantic table — a drift back to ad-hoc greens/oranges/reds would let the same
        // meaning wear different colors in different corners of the app (the C3 rule).
        #expect(OperationBannerStyle.tint(for: .success) == SemanticColor.success)
        #expect(OperationBannerStyle.tint(for: .warning) == SemanticColor.warning)
        #expect(OperationBannerStyle.tint(for: .error) == SemanticColor.error)
    }
}
