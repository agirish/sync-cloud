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

    /// Arming a watch drops the memo's pre-download answer, and does it SYNCHRONOUSLY — no await
    /// between `begin` returning and the entry being gone.
    ///
    /// That is the whole of the ordering guarantee. The forget used to be the first line of the
    /// watch task, which made "the memo is clear by the time anyone reads it again" rest on the
    /// main actor draining equal-priority jobs in FIFO order — true in practice, guaranteed
    /// nowhere — while `begin` had already published `requests`, re-keying the badge task of the
    /// row showing that file. A row that re-read the memo in that window got the pre-download
    /// "cloud-only" answer straight back out of cache. Asserted with no `await` at all, because a
    /// suspension point here would be the test admitting the property it is checking.
    @MainActor
    @Test func arrivingAtAWatchForgetsThePathSynchronously() {
        CloudOnlyBadgeCache.clear(underRoot: "/iCloud")
        CloudOnlyBadgeCache.record(Self.path, isCloudOnly: true)
        // The watch puts the entry straight back, so the assertion below fails if the forget was
        // the task's doing rather than `begin`'s — a `nil` here means the memo was cleared before
        // the task had run at all, which is the claim.
        let watch = PaneDownloadWatch { request, _ in
            CloudOnlyBadgeCache.record(request.path, isCloudOnly: true)
            return false
        }

        watch.begin(CloudDownloadRequest(path: Self.path, paneToken: .left))

        #expect(CloudOnlyBadgeCache.cached(Self.path) == nil)
    }

    /// ONE forget per download: `begin` does it, and nothing after it does it again.
    ///
    /// Asserted per path rather than off a global invalidation counter, which cannot be read
    /// reliably: the memo is process-wide and every mounted pane suite running in parallel bumps
    /// it on republish. The injected watch writes the entry back — the row recycling mid-download —
    /// so a second forget anywhere in the sequence leaves the entry missing at the end.
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

    /// The real watch forgets nothing itself — the arming already did, and a second forget is two
    /// generation bumps for one download, which invalidates every in-flight badge stat in both
    /// panes. Driven straight at `CloudDownloadPoll.watch` so the split is pinned on both sides.
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

    /// A path that cannot be statted is not a landing.
    ///
    /// `lstat` reports "not dataless" and "not there" through the same failure, and the poll used to
    /// read a bare `false` as YES — so a file deleted mid-download counted as materialized, and the
    /// watch recorded local content for a path with no file behind it. The probe answers nil for
    /// that now, the poll keeps going, and a run of nothing but nils ends having observed nothing.
    @Test func aProbeThatCannotAnswerIsNotALanding() async {
        let probes = Probes()
        let landed = await CloudDownloadPoll.run(path: Self.path, attempts: 3, interval: .zero,
                                                 isCloudOnly: { _ in _ = await probes.record(); return nil })

        #expect(!landed, "an unstattable path was reported as materialized")
        #expect(await probes.count == 3, "the poll gave up instead of trying again")
    }

    /// And the real probe answers nil for a path that is not there — the production default, not an
    /// injected stand-in, because that mapping is the whole of this fix.
    ///
    /// Nothing is seeded into the memo first: the arming forget that used to clear a seed lives in
    /// `PaneDownloadWatch.begin` now, and this drives `watch` directly. The assertion is unchanged
    /// in force — a poll that read "cannot stat" as a landing would `record(false)` here, which is
    /// not `nil`.
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

    // MARK: - The row's badge, one layer above the memo

    /// A badge resolution superseded while its stat was out hands the row NOTHING to write.
    ///
    /// The memo grew two guards for this race and the row sat above both of them, assigning
    /// whatever came back. Staged exactly as the app reaches it: the arming re-stat is out carrying
    /// the pre-download `true`, the watch concludes, `.task(id:)` re-keys and cancels this
    /// resolution — and the stat resumes anyway, because `Task.detached { … }.value` neither
    /// inherits cancellation nor throws. The replacement task writes the memo's `false`; which of
    /// the two lands last is unconstrained, so the badge could go on claiming cloud-only for a file
    /// that had already arrived.
    ///
    /// The suspension is a continuation rather than a sleep for that same reason: a `Task.sleep`
    /// throws the instant the task is cancelled and unwinds BEFORE the write, which would stage the
    /// opposite of the defect and pass without the guard.
    ///
    /// The memo does end up holding `true` for this path, and that is correct — nothing invalidated
    /// it here, so the memo's own guards have no reason to decline. The staleness this test is
    /// about is the row's, which is why the assertion is on what the row is handed.
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

    /// The guard declines a superseded answer and NOTHING else — a live resolution still follows
    /// the memo, including the `false` a concluding watch has just recorded.
    ///
    /// Without this, a resolution that never writes at all (`guard false`) passes the test above.
    /// The stat must also not be consulted: a memo hit is what makes the post-download re-read
    /// cheap, and it is the answer the badge is meant to follow.
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

    /// A directory resolves `false` without statting — the branch the row used to run inline, kept
    /// so the extraction cannot have quietly started charging folders for an `lstat`.
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

    /// A stat suspension the test controls, and one a CANCELLED task still resumes from.
    ///
    /// That last part is the whole fixture. The real stat is `Task.detached { lstat }.value`, which
    /// does not inherit its caller's cancellation and cannot throw, so it comes back and carries on
    /// into the write. A continuation resumed from outside is the same shape; `Task.sleep` is not.
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

    /// Yields until `condition` holds or the deadline passes. Returns whether it held, so the
    /// caller asserts on the answer rather than assuming it.
    ///
    /// Generous, because it waits for something to HAPPEN rather than bounding an absence: the
    /// watch task is main-actor isolated and in a full parallel run this repo has measured deferred
    /// main-actor work landing 13 s late. A short deadline would report starvation as a defect.
    @MainActor
    private func hold(upTo seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// Counts probes across the poll's `@Sendable` closure without a data race.
    private actor Probes {
        private(set) var count = 0
        /// Returns the count INCLUDING this probe, so a caller can branch on which one it is.
        func record() -> Int { count += 1; return count }
    }
}
