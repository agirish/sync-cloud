import Testing
import Foundation
@testable import FileExplorer

/// Pins the pane's download watch — the sequence, not just its parts.
///
/// The watch used to be run by the ROW (ten one-second probes) and, for a download started from
/// the preview column's button, by the COLUMN as well (twenty at 1.5 s) — for the same request.
/// Each preceded its poll with `CloudOnlyBadgeCache.forget`, and every forget bumps the memo's
/// generation, which invalidates every in-flight badge stat in BOTH panes. That is verbatim the
/// harm the pane-scoped request payload was added to remove, so "exactly one forget per download"
/// is the property worth a test rather than a comment.
///
/// `.serialized` because the memo is process-wide static state and these tests write it. Their
/// fixtures all live under `/iCloud`, which no other suite touches — a reset here must never be a
/// whole-table wipe, or it would reach into a suite running in parallel.
@Suite(.serialized) struct CloudDownloadWatchTests {

    private static let path = "/iCloud/big.mov"

    /// The whole point: ONE forget per download, on the way in and never again.
    ///
    /// Asserted per path rather than off a global invalidation counter, which cannot be read
    /// reliably: the memo is process-wide and every mounted pane suite running in parallel bumps
    /// it on republish. The probe writes the entry back mid-poll, so a second forget after the
    /// poll — the shape two owners produced — leaves the entry missing at the end.
    @MainActor
    @Test func aWatchForgetsOnceOnTheWayInAndNotAgainAfter() async {
        CloudOnlyBadgeCache.clear(underRoot: "/iCloud")
        CloudOnlyBadgeCache.record(Self.path, isCloudOnly: true)
        let request = CloudDownloadRequest(path: Self.path, paneToken: .left)

        // Exhausting rather than landing, so the watch's own `record` cannot mask the difference.
        _ = await CloudDownloadPoll.watch(request, attempts: 1, interval: .zero, isCloudOnly: { path in
            await MainActor.run { CloudOnlyBadgeCache.record(path, isCloudOnly: true) }
            return true
        }, latch: { request })

        #expect(CloudOnlyBadgeCache.cached(Self.path) == true)
    }

    /// The forget happens on the way IN, so a row recycling mid-download cannot read the
    /// pre-download "cloud-only" answer back out of cache and undo the watch's result.
    @MainActor
    @Test func theMemosPreDownloadAnswerIsDroppedBeforeThePollRuns() async {
        CloudOnlyBadgeCache.clear(underRoot: "/iCloud")
        CloudOnlyBadgeCache.record(Self.path, isCloudOnly: true)
        let request = CloudDownloadRequest(path: Self.path, paneToken: .left)

        let memoWasStillHolding = Flag()
        _ = await CloudDownloadPoll.watch(request, attempts: 1, interval: .zero, isCloudOnly: { path in
            if await MainActor.run(body: { CloudOnlyBadgeCache.cached(path) }) != nil {
                await memoWasStillHolding.raise()
            }
            return true
        }, latch: { request })

        #expect(!(await memoWasStillHolding.value))
    }

    /// A watch that saw the content land records it, so the row's badge re-read is a dictionary
    /// hit rather than another syscall.
    @MainActor
    @Test func aLandedDownloadIsRecorded() async {
        CloudOnlyBadgeCache.clear(underRoot: "/iCloud")
        let request = CloudDownloadRequest(path: Self.path, paneToken: .left)

        let dropsLatch = await CloudDownloadPoll.watch(request, attempts: 5, interval: .zero,
                                                       isCloudOnly: { _ in false }, latch: { request })

        #expect(CloudOnlyBadgeCache.cached(Self.path) == false)
        #expect(dropsLatch)
    }

    /// A watch that ran out of attempts observed nothing new: the memo must stay empty for that
    /// path so the next realization asks the filesystem, and the badge correctly stays.
    @MainActor
    @Test func anExhaustedWatchRecordsNothing() async {
        CloudOnlyBadgeCache.clear(underRoot: "/iCloud")
        let request = CloudDownloadRequest(path: Self.path, paneToken: .left)

        let dropsLatch = await CloudDownloadPoll.watch(request, attempts: 3, interval: .zero,
                                                       isCloudOnly: { _ in true }, latch: { request })

        #expect(CloudOnlyBadgeCache.cached(Self.path) == nil)
        // Exhausted is still concluded — the latch drops either way, which is what stops it
        // sticking for a download that will never land.
        #expect(dropsLatch)
    }

    /// The exhaustion path's missing guard, as a test: the user clicks Download, the attempts run
    /// out, and before this watch finishes they click Download on the SAME file again — which
    /// cancels this task and re-arms the latch with a fresh request for the identical path. A
    /// guard that compared paths would let this finishing watch clear the latch the new one just
    /// took, killing a watch that had barely started.
    @MainActor
    @Test func aSupersededWatchDoesNotDropTheNewRequestsLatch() async {
        CloudOnlyBadgeCache.clear(underRoot: "/iCloud")
        let first = CloudDownloadRequest(path: Self.path, paneToken: .left)
        let second = CloudDownloadRequest(path: Self.path, paneToken: .left)   // same path, new identity

        let dropsLatch = await CloudDownloadPoll.watch(first, attempts: 1, interval: .zero,
                                                       isCloudOnly: { _ in true }, latch: { second })

        #expect(!dropsLatch)
    }

    /// And an empty latch is nobody's to drop.
    @MainActor
    @Test func aWatchWhoseLatchIsAlreadyEmptyDropsNothing() async {
        CloudOnlyBadgeCache.clear(underRoot: "/iCloud")
        let request = CloudDownloadRequest(path: Self.path, paneToken: .left)

        let dropsLatch = await CloudDownloadPoll.watch(request, attempts: 1, interval: .zero,
                                                       isCloudOnly: { _ in true }, latch: { nil })

        #expect(!dropsLatch)
    }

    // MARK: - The poll itself

    /// It stops at the first probe that says the content is local — a watch that kept polling
    /// after the answer arrived would hold the latch (and the "Downloading…" caption) for the rest
    /// of its budget.
    @Test func thePollStopsAtTheFirstLanding() async {
        let probes = Probes()
        let landed = await CloudDownloadPoll.run(path: Self.path, attempts: 10, interval: .zero,
                                                 isCloudOnly: { _ in await probes.record() < 3 })

        #expect(landed)
        #expect(await probes.count == 3)
    }

    /// And it is bounded: a provider that never fetches the file costs exactly `attempts` probes,
    /// not an open-ended poll.
    @Test func thePollIsBoundedByItsAttempts() async {
        let probes = Probes()
        let landed = await CloudDownloadPoll.run(path: Self.path, attempts: 4, interval: .zero,
                                                 isCloudOnly: { _ in _ = await probes.record(); return true })

        #expect(!landed)
        #expect(await probes.count == 4)
    }

    /// Cancellation reports no landing rather than a false one. The interval is a minute: without
    /// the cancellation this test could not finish, which is the assertion behind the assertion.
    @Test func aCancelledPollReportsNoLanding() async {
        let task = Task {
            await CloudDownloadPoll.run(path: Self.path, attempts: 10, interval: .seconds(60),
                                        isCloudOnly: { _ in false })
        }
        task.cancel()

        #expect(await task.value == false)
    }

    /// A one-way observation made from inside the poll's `@Sendable` closure.
    private actor Flag {
        private(set) var value = false
        func raise() { value = true }
    }

    /// Counts probes across the poll's `@Sendable` closure without a data race.
    private actor Probes {
        private(set) var count = 0
        /// Returns the count INCLUDING this probe, so a caller can branch on which one it is.
        func record() -> Int { count += 1; return count }
    }
}
