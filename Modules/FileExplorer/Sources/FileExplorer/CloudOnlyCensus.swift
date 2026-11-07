import Foundation
import Sync

/// Counts the cloud-only placeholders in a whole pane tree, off the main actor and cancellably.
///
/// A walk, not a read, and the status bar says so. `SF_DATALESS` isn't in `resourceValues`, so the
/// tree walk that built the pane can't carry the flag (the reason ``CloudOnlyBadgeCache`` resolves
/// the ☁ badge lazily, per row). But a census asks about forty thousand rows, not one, so there is
/// no lazy answer: every file has to be statted before the number is true.
///
/// So it is paid where nobody is waiting: after the tree is on screen, at utility priority, with
/// the bar reading `—` until it lands (``PaneStatusFacts``'s `cloudOnlyCount`). It is cancelled and
/// restarted whenever the pane republishes, because a count of a tree that is gone is a number
/// about something else.
///
/// It doesn't write the badge memo. The memo's invalidation is tuned around one writer per row and
/// a download watch racing it; a bulk writer landing forty thousand entries would trip its capacity
/// wipe (8,192) and throw away the answers the visible rows serve from.
enum CloudOnlyCensus {

    /// How many nodes are statted between cooperative yields. `lstat` on a materialized file is
    /// sub-microsecond, but against a provider's synthetic filesystem it is a round trip to a
    /// daemon, and the census is the lowest-priority work in the app. A few hundred hides the
    /// loop's overhead while giving cancellation (and the pool) several hundred chances across a
    /// 40k tree.
    static let batchSize = 256

    /// The census result for `nodes`, or nil when the walk was cancelled, which is a different
    /// answer from zero and must not be published as one: the bar keeps reading `—` until the
    /// census for the tree now on screen finishes.
    ///
    /// `stat` is injectable for the reason `MaterializationStatus` documents: the flag is
    /// provider-set and `chflags` refuses it to anyone but root, so a test can't otherwise make a
    /// file cloud-only. A path that can't be statted at all (nil) isn't counted: "no answer" isn't
    /// "in the cloud".
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
                // Directories are skipped without a syscall (`SF_DATALESS` is a content flag, and a
                // folder is never a placeholder for content) but still count towards the yield, so a
                // deep tree of mostly empty folders can't walk far without checking for cancellation.
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
    /// The detached task is unstructured, so a `.task(id:)` torn down by a republish doesn't reach
    /// it on its own; the handler turns "the view moved on" into "stop statting". The same shape,
    /// for the same reason, as `FileSyncManager.loadTree`'s.
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
