import Testing
import Foundation
@testable import SyncCloud

/// Regression coverage for the operation banner's auto-dismiss timer. The old implementation
/// spawned one detached sleep per banner change and compared by string value, so a replacement
/// banner with identical text was dismissed early by the first banner's leftover timer.
@Suite struct BannerDismissSchedulerTests {

    @MainActor
    @Test func testReplacementBannerWithSameTextRestartsTheDismissWindow() async throws {
        let scheduler = BannerDismissScheduler()
        var dismissCount = 0

        // A banner appears with a 500ms window…
        scheduler.bannerChanged(to: "Deleted 3 items", delayNanoseconds: 500_000_000) { dismissCount += 1 }
        // …and 250ms in, a second operation posts the exact same message.
        try await Task.sleep(nanoseconds: 250_000_000)
        scheduler.bannerChanged(to: "Deleted 3 items", delayNanoseconds: 500_000_000) { dismissCount += 1 }

        // 350ms later the FIRST timer's deadline has long passed; the restarted window must still be open.
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(dismissCount == 0)

        // Once the replacement banner's full window elapses, exactly one dismissal fires.
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(dismissCount == 1)
    }

    @MainActor
    @Test func testClearingTheBannerCancelsThePendingDismiss() async throws {
        let scheduler = BannerDismissScheduler()
        var dismissCount = 0

        scheduler.bannerChanged(to: "Copied 2 files", delayNanoseconds: 100_000_000) { dismissCount += 1 }
        scheduler.bannerChanged(to: nil, delayNanoseconds: 100_000_000) { dismissCount += 1 }

        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(dismissCount == 0)
    }
}
