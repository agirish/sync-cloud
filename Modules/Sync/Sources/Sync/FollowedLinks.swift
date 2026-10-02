import Foundation

/// **Where a walk read through a folder link** — the provenance that lets the targeted cache drop
/// and the panes' "which pane holds this file" see a write the walk's root does not name.
///
/// The walk follows a folder symlink and lists what it leads to, and from two levels below the
/// link its ids come back resolved: a walk of `R` holding `R/link → T` lists `T/sub/x.txt`, not
/// `R/link/sub/x.txt` (`contentsOfDirectory(at:)` hands back resolved URLs there). A pane row names
/// that id, a document opened from it saves under it, and no prefix of `R` matches — so
/// `prepareReread(afterWritingAt:)` used to leave the walk cached over a write it lists. Which
/// walks hold such a link is a fact about their trees, and finding it from the paths would mean
/// traversing every cached tree on every autosave. The walk is the one place that knows, so it
/// writes it down, and the caller keeps it beside the entry, as `prefetchedTreeWalkStopped` keeps
/// a budget stop.
extension FileSyncManager {

    /// **The resolved targets of the folder links one walk listed outside its root.**
    ///
    /// A shared reference across the fan-out's branch copies of the (value-type) builder, for
    /// `NodeBudget`'s reason: the branches run concurrently and write one record. `buildTree` fills
    /// it — its root, when the root itself resolves elsewhere, and each folder symlink below it that
    /// it went on to list (see `TreeBuilder.noteFollowedLink(_:)`) — and the caller reads `targets`
    /// once the walk is done. A walk handed none records nothing and pays nothing.
    ///
    /// Spelled as `resolvingSymlinksInPath` spells them, which is how `folder(_:holds:links:linkTargets:)`
    /// asks a written path too: the two must meet in one spelling, and a temp root's ids
    /// (`/private/var/…`) and that resolver (`/var/…`) do not share one by default. The resolver
    /// takes `/private` off only a path that exists, so the written path is asked after the write,
    /// as every caller asks it; under `/Users` the two spellings are one and none of this arises.
    final class FollowedLinks: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: Set<String> = []

        init() {}

        func note(_ target: String) {
            lock.lock(); recorded.insert(target); lock.unlock()
        }

        var targets: Set<String> {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
    }
}
