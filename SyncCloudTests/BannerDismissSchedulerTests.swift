import Testing
import AppKit
import Foundation
import Sync
@testable import SyncCloud

/// Regression coverage for the operation banner's auto-dismiss timer. The old implementation
/// spawned one detached sleep per banner change and compared by string value, so a replacement
/// banner with identical text was dismissed early by the first banner's leftover timer.
/// Now also pins the per-severity rules: warnings outlive successes, errors are sticky, and
/// hovering pauses the timer (hover exit restarts the full window, not the remainder).
@Suite struct BannerDismissSchedulerTests {

    /// Short windows so the suite stays fast: success 200ms, warning 500ms.
    private static let testDelays = BannerDismissScheduler.Delays(
        successNanoseconds: 200_000_000,
        warningNanoseconds: 500_000_000
    )

    @MainActor
    @Test func testReplacementBannerWithSameTextRestartsTheDismissWindow() async throws {
        let scheduler = BannerDismissScheduler(delays: BannerDismissScheduler.Delays(
            successNanoseconds: 500_000_000, warningNanoseconds: 1_000_000_000))
        var dismissCount = 0

        // A banner appears with a 500ms window…
        scheduler.bannerChanged(to: .success("Deleted 3 items")) { dismissCount += 1 }
        // …and 250ms in, a second operation posts the exact same message.
        try await Task.sleep(nanoseconds: 250_000_000)
        scheduler.bannerChanged(to: .success("Deleted 3 items")) { dismissCount += 1 }

        // 350ms later the FIRST timer's deadline has long passed; the restarted window must still be open.
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(dismissCount == 0)

        // Once the replacement banner's full window elapses, exactly one dismissal fires.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(dismissCount == 1)
    }

    @MainActor
    @Test func testClearingTheBannerCancelsThePendingDismiss() async throws {
        let scheduler = BannerDismissScheduler(delays: Self.testDelays)
        var dismissCount = 0

        scheduler.bannerChanged(to: .success("Copied 2 files")) { dismissCount += 1 }
        scheduler.bannerChanged(to: nil) { dismissCount += 1 }

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(dismissCount == 0)
    }

    @MainActor
    @Test func testWarningGetsALongerWindowThanSuccess() async throws {
        let scheduler = BannerDismissScheduler(delays: Self.testDelays)
        var dismissCount = 0

        scheduler.bannerChanged(to: .warning("3 copied; 2 failed")) { dismissCount += 1 }

        // Past the success window but inside the warning window: still showing.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(dismissCount == 0)

        // Past the warning window: dismissed.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(dismissCount == 1)
    }

    @MainActor
    @Test func testErrorBannerIsStickyUntilManuallyClosed() async throws {
        let scheduler = BannerDismissScheduler(delays: Self.testDelays)
        var dismissCount = 0

        scheduler.bannerChanged(to: .error("Copy failed")) { dismissCount += 1 }

        // Well past both auto-dismiss windows, the error must still be up.
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(dismissCount == 0)

        // Manual close clears it (the view sets the banner to nil); no stray dismiss later.
        scheduler.bannerChanged(to: nil) { dismissCount += 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(dismissCount == 0)
    }

    @MainActor
    @Test func testHoverPausesTheTimerAndExitRestartsTheFullWindow() async throws {
        let scheduler = BannerDismissScheduler(delays: Self.testDelays)
        var dismissCount = 0

        scheduler.bannerChanged(to: .success("Copied 2 files")) { dismissCount += 1 }

        // Hover 100ms in; the deadline would hit at 200ms, but hover holds it open.
        try await Task.sleep(nanoseconds: 100_000_000)
        scheduler.hoverChanged(isHovering: true)
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(dismissCount == 0)

        // Exit restarts the FULL 200ms window: still open at +100ms, dismissed after +350ms.
        scheduler.hoverChanged(isHovering: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(dismissCount == 0)
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(dismissCount == 1)
    }

    @MainActor
    @Test func testBannerPostedWhileHoveringStaysUntilHoverExit() async throws {
        let scheduler = BannerDismissScheduler(delays: Self.testDelays)
        var dismissCount = 0

        // Pointer is already over the banner area when a replacement banner arrives.
        scheduler.bannerChanged(to: .success("First")) { dismissCount += 1 }
        scheduler.hoverChanged(isHovering: true)
        scheduler.bannerChanged(to: .success("Second")) { dismissCount += 1 }

        // No timer runs while hovering.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(dismissCount == 0)

        // The window only starts on hover exit.
        scheduler.hoverChanged(isHovering: false)
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(dismissCount == 1)
    }

    @MainActor
    @Test func testManualCloseWhileHoveredDoesNotStrandTheNextBannersTimer() async throws {
        let scheduler = BannerDismissScheduler(delays: Self.testDelays)
        var dismissCount = 0

        // Every ✕ click happens while the pointer hovers the banner, and SwiftUI never delivers
        // onHover(false) for the removed view — so the hover state must reset on clear, or the
        // next banner starts "paused" and never auto-dismisses.
        scheduler.bannerChanged(to: .success("First")) { dismissCount += 1 }
        scheduler.hoverChanged(isHovering: true)
        scheduler.bannerChanged(to: nil) { dismissCount += 1 }

        scheduler.bannerChanged(to: .success("Second")) { dismissCount += 1 }
        try await Task.sleep(nanoseconds: 350_000_000)
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
}
