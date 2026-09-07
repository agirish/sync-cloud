import Foundation
import Sync

/// Counts the cloud-only placeholders in a whole pane tree, off the main actor and cancellably.
///
/// **This is a walk, not a read, and the status bar says so.** `SF_DATALESS` is not in
/// `resourceValues`, so the tree walk that built the pane cannot carry the flag — the same fact
/// that made ``CloudOnlyBadgeCache`` resolve the ☁ badge lazily, one `lstat` per row realized,
/// rather than folding a second syscall per node into the load path. Nothing about that changes
/// here. What changes is the *question*: a badge asks about one row, and a census asks about
/// forty thousand, so there is no lazy answer to give — every file has to be statted before the
/// number is true.
///
/// So it is paid where a person is not waiting for it. The census runs after the tree is on
/// screen, at utility priority, and the bar reads `—` until it lands (``PaneStatusFacts``'s
/// `cloudOnlyCount`). It is cancelled and restarted whenever the pane republishes, because a
/// count of a tree that is gone is not a stale number — it is a number about something else.
///
/// **It does not write the badge memo.** The memo's invalidation is a generation counter plus a
/// per-entry re-check, tuned around one writer per row and a download watch racing it; adding a
/// bulk writer that lands forty thousand entries at once would trip its capacity wipe (8,192) and
/// throw away exactly the answers the visible rows are serving from. The census keeps its own
/// total and touches nothing.
enum CloudOnlyCensus {

    /// How many nodes are statted between cooperative yields.
    ///
    /// `lstat` on a materialized file is sub-microsecond, but against a provider's synthetic
    /// filesystem it is a round trip to a daemon — and the census is the lowest-priority thing the
    /// app is doing. A few hundred keeps the loop's own overhead invisible while leaving the
    /// cancellation check (and the pool) a chance to run several hundred times across a 40k tree.
    static let batchSize = 256

    /// The census result for `nodes`, or **nil when the walk was cancelled** — which is a
    /// different answer from zero and must not be published as one. A superseded census returns
    /// nil so the bar keeps reading `—` until the census for the tree now on screen finishes.
    ///
    /// `stat` is injectable for the reason `MaterializationStatus` documents at length — the flag
    /// is provider-set and `chflags` refuses it to anyone but root, so a test has no other way to
    /// say "this file's content lives on the provider". A path that cannot be statted at all
    /// (nil) is not counted: "no answer" is not "in the cloud".
    static func count(
        in nodes: [FileNode],
        stat: MaterializationStatus.StatFlags = MaterializationStatus.realStatFlags
    ) async -> Int? {
        var total = 0
        var sinceYield = 0
        var stack: [[FileNode]] = [nodes]
        while let batch = stack.popLast() {
            for node in batch {
                if let children = node.children, !children.isEmpty { stack.append(children) }
                // Directories are skipped without a syscall — `SF_DATALESS` is a content flag and
                // a folder is never a placeholder for content — but they still count towards the
                // yield, so a deeply nested tree of mostly-empty folders cannot walk a long way
                // without ever checking for cancellation.
                if !node.isDirectory,
                   MaterializationStatus.isCloudOnlyIfKnown(atPath: node.id, statFlags: stat) == true {
                    total += 1
                }
                sinceYield += 1
                if sinceYield >= batchSize {
                    sinceYield = 0
                    if Task.isCancelled { return nil }
                    await Task.yield()
                }
            }
        }
        return Task.isCancelled ? nil : total
    }

    /// Runs ``count(in:stat:)`` off the main actor, forwarding the caller's cancellation into it.
    ///
    /// The detached task is unstructured, so a `.task(id:)` being torn down by a republish does
    /// **not** reach it on its own — the handler is what turns "the view moved on" into "stop
    /// statting". Same shape, and the same reason, as `FileSyncManager.loadTree`'s.
    @MainActor
    static func run(
        over nodes: [FileNode],
        stat: @escaping MaterializationStatus.StatFlags = MaterializationStatus.realStatFlags
    ) async -> Int? {
        let work = Task.detached(priority: .utility) { await count(in: nodes, stat: stat) }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
