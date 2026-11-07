import Testing
import Foundation
@testable import FileExplorer

/// Pins the pane's download watch, the sequence as well as its parts. Every
/// `CloudOnlyBadgeCache.forget` bumps the memo's generation and invalidates every in-flight badge
/// stat in both panes, so a download must forget exactly once.
///
/// `.serialized` because the memo is process-wide static state and these tests write it. Fixtures
/// live under `/iCloud`, which no other suite touches; a reset here must never wipe the whole
/// table, or it would reach into a suite running in parallel.
@Suite(.serialized) struct CloudDownloadWatchTests {

    private static let path = "/iCloud/big.mov"

    /// Arming a watch drops the memo's pre-download answer synchronously, with no await between
    /// `begin` returning and the entry being gone. `begin` publishes `requests`, re-keying the
    /// row's badge task; a forget left to the watch task would rest on main-actor job order, and a
    /// row re-reading in between would get "cloud-only" back from cache. No `await` in the test,
    /// since a suspension would concede the property.
    @MainActor
    @Test func arrivingAtAWatchForgetsThePathSynchronously() {
        CloudOnlyBadgeCache.clear(underRoot: "/iCloud")
        CloudOnlyBadgeCache.record(Self.path, isCloudOnly: true)
        // The watch puts the entry straight back, so a `nil` below means `begin` cleared the memo
        // before the task ran, and a forget done by the task would fail.
        let watch = PaneDownloadWatch { request, _ in
            CloudOnlyBadgeCache.record(request.path, isCloudOnly: true)
            return false
        }

        watch.begin(CloudDownloadRequest(path: Self.path, paneToken: .left))

        #expect(CloudOnlyBadgeCache.cached(Self.path) == nil)
    }

    /// One forget per download: `begin` does it and nothing after it does it again. Asserted per
    /// path, not off the global invalidation counter, which parallel pane suites bump on republish.
    /// The injected watch writes the entry back (a row recycling mid-download), so a second forget
    /// anywhere leaves it missing at the end.
    @MainActor
    @Test func nothingAfterTheArmingForgetsThePathAgain() async {
        CloudOnlyBadgeCache.clear(underRoot: "/iCloud")
        let armed = Marker()
        let watch = PaneDownloadWatch { request, _ in
            CloudOnlyBadgeCache.record(request.path, isCloudOnly: true)
            armed.fired = true
            return false
        }

        watch.begin(CloudDownloadRequest(path: Self.path, paneToken: .left))
        let ran = await hold(upTo: 30) { armed.fired }
        #expect(ran, "the injected watch never ran — the assertion below would prove nothing")

        #expect(CloudOnlyBadgeCache.cached(Self.path) == true)
    }

    /// The real watch forgets nothing itself; the arming already did, and a second forget would
    /// invalidate every in-flight badge stat in both panes again. Driven straight at
    /// `CloudDownloadPoll.watch` so the split is pinned from both sides.
    @MainActor
    @Test func thePollingWatchItselfForgetsNothing() async {
        CloudOnlyBadgeCache.clear(underRoot: "/iCloud")
        CloudOnlyBadgeCache.record(Self.path, isCloudOnly: true)
        let request = CloudDownloadRequest(path: Self.path, paneToken: .left)

        // Exhausting rather than landing, so the watch's own `record` cannot mask the difference.
        _ = await CloudDownloadPoll.watch(request, attempts: 1, interval: .zero,
                                          isCloudOnly: { _ in true }, latch: { request })

        #expect(CloudOnlyBadgeCache.cached(Self.path) == true)
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

    /// Download, attempts run out, and Download on the same file again before this watch finishes:
    /// the latch now holds a fresh request for the same path. A guard comparing paths would let the
    /// finishing watch clear the new one's latch.
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

    /// It stops at the first probe that says the content is local; one that kept polling would
    /// hold the latch (and the "Downloading…" caption) for the rest of its budget.
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

    /// A path that can't be statted is not a landing. `lstat` fails the same way for "not dataless"
    /// and "not there", so the probe answers nil and the poll keeps going; otherwise a file deleted
    /// mid-download would count as materialized.
    @Test func aProbeThatCannotAnswerIsNotALanding() async {
        let probes = Probes()
        let landed = await CloudDownloadPoll.run(path: Self.path, attempts: 3, interval: .zero,
                                                 isCloudOnly: { _ in _ = await probes.record(); return nil })

        #expect(!landed, "an unstattable path was reported as materialized")
        #expect(await probes.count == 3, "the poll gave up instead of trying again")
    }

    /// The real probe answers nil for a missing path: the production default, since that mapping is
    /// what's under test. Nothing is seeded, as the arming forget lives in `PaneDownloadWatch.begin`
    /// and this drives `watch` directly; a poll that read "can't stat" as landed would
    /// `record(false)`.
    @MainActor
    @Test func aVanishedPathLeavesNothingInTheMemo() async {
        let gone = "/iCloud/vanished-\(UUID().uuidString).mov"
        let request = CloudDownloadRequest(path: gone, paneToken: .left)

        // Default `isCloudOnly`, so this runs `MaterializationStatus.isCloudOnlyIfKnown` for real.
        _ = await CloudDownloadPoll.watch(request, attempts: 2, interval: .milliseconds(5),
                                          latch: { request })

        #expect(CloudOnlyBadgeCache.cached(gone) == nil,
                "the watch recorded an answer about a path with no file behind it")
    }

    /// Cancellation reports no landing rather than a false one. The interval is a minute, so the
    /// test finishes only if cancellation works.
    @Test func aCancelledPollReportsNoLanding() async {
        let task = Task {
            await CloudDownloadPoll.run(path: Self.path, attempts: 10, interval: .seconds(60),
                                        isCloudOnly: { _ in false })
        }
        task.cancel()

        #expect(await task.value == false)
    }

    // MARK: - The row's badge, one layer above the memo

    /// A badge resolution superseded while its stat was out hands the row nothing to write. As in
    /// the app: the arming re-stat is out with the pre-download `true`, the watch concludes,
    /// `.task(id:)` cancels this resolution, and the stat resumes anyway, because
    /// `Task.detached { … }.value` neither inherits cancellation nor throws. Without the guard the
    /// stale `true` could land after the replacement's `false`, badging a local file as cloud-only.
    ///
    /// A continuation, not a sleep: `Task.sleep` throws on cancel and unwinds before the write, so
    /// the test would pass without the guard. The memo itself ends up `true` here, correctly, since
    /// nothing invalidated it; the assertion is on what the row is handed.
    @MainActor
    @Test func aSupersededBadgeResolutionIsNotWritten() async {
        let path = "/iCloud/superseded-\(UUID().uuidString).mov"
        let gate = StatGate()

        let resolution = Task { @MainActor in
            await FileRowView.resolveBadge(path: path, isDirectory: false, stat: { _ in
                await gate.wait()
                return true
            })
        }

        #expect(await hold(upTo: 5) { gate.isWaiting },
                "the resolution never reached its stat — there is nothing here to supersede")

        resolution.cancel()
        gate.release()

        #expect(await resolution.value == nil,
                "a superseded badge resolution handed back an answer for the row to write")
    }

    /// The guard declines only a superseded answer: a live resolution still follows the memo,
    /// including the `false` a concluding watch just recorded, without a stat. Without this, a
    /// resolution that never writes (`guard false`) would pass the test above.
    @MainActor
    @Test func aLiveBadgeResolutionFollowsTheMemo() async {
        let path = "/iCloud/landed-\(UUID().uuidString).mov"
        let statted = Marker()
        // What a watch records the moment the content arrives.
        CloudOnlyBadgeCache.record(path, isCloudOnly: false)

        let answer = await FileRowView.resolveBadge(path: path, isDirectory: false, stat: { _ in
            statted.fired = true
            return true
        })

        #expect(answer == false, "the badge did not follow the memo's landed answer")
        #expect(!statted.fired, "a memoized answer was re-statted")
    }

    /// A directory resolves `false` without statting, so folders never pay for an `lstat`.
    @MainActor
    @Test func aDirectoryResolvesUnbadgedWithoutStatting() async {
        let statted = Marker()

        let answer = await FileRowView.resolveBadge(path: "/iCloud/folder", isDirectory: true,
                                                    stat: { _ in
            statted.fired = true
            return true
        })

        #expect(answer == false, "a directory row was handed a cloud badge")
        #expect(!statted.fired, "a directory row paid for an lstat")
    }

    /// A one-shot flag the injected watch can set — main-actor isolated, like the watch itself.
    @MainActor private final class Marker {
        var fired = false
    }

    /// A stat suspension the test controls, which a cancelled task still resumes from. That matches
    /// the real stat, `Task.detached { lstat }.value`, which ignores the caller's cancellation and
    /// can't throw; `Task.sleep` would not.
    @MainActor private final class StatGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                isWaiting = true
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// Yields until `condition` holds or the deadline passes, and returns whether it held. What
    /// carries it under load is `LayoutPumpWait.poll`'s floor, not the deadline: it gives up only
    /// after the deadline and `pumpFloor` polls (`docs/flaky-tests.md`, "Fixed pumps and fixed
    /// sleeps").
    @MainActor
    private func hold(upTo seconds: Double, until condition: () -> Bool) async -> Bool {
        await LayoutPumpWait.poll(upTo: seconds, until: condition).held
    }

    /// Counts probes across the poll's `@Sendable` closure without a data race.
    private actor Probes {
        private(set) var count = 0
        /// Returns the count INCLUDING this probe, so a caller can branch on which one it is.
        func record() -> Int { count += 1; return count }
    }
}
