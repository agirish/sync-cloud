import Foundation

/// Where a walk read through a folder link, so the targeted cache drop and the panes' "which pane
/// holds this file" see a write the walk's root doesn't name.
///
/// Below a followed folder symlink, ids come back resolved: a walk of `R` holding `R/link → T`
/// lists `T/sub/x.txt`, not `R/link/sub/x.txt` (`contentsOfDirectory(at:)` resolves there). A
/// document saved under that id matches no prefix of `R`, so `prepareReread(afterWritingAt:)` would
/// leave the walk cached over a write it lists. Finding links from paths would traverse every cached
/// tree per autosave, so the walk records them and the caller keeps the record beside the entry, as
/// `prefetchedTreeWalkStopped` keeps a budget stop.
extension FileSyncManager {

    /// The resolved targets of the folder links one walk listed outside its root.
    ///
    /// A reference shared by the fan-out's copies of the value-type builder, as `NodeBudget` is: the
    /// branches run concurrently and write one record. `buildTree` notes its root when that resolves
    /// elsewhere, and each folder symlink it lists (`TreeBuilder.noteFollowedLink(_:)`); the caller
    /// reads `targets` after the walk. A walk handed none pays nothing.
    ///
    /// Spelled as `resolvingSymlinksInPath` spells them, as `folder(_:holds:links:linkTargets:)`
    /// spells a written path, so the two meet (`/private/var/…` vs `/var/…` otherwise). The resolver
    /// drops `/private` only for a path that exists, so the written path is asked after the write.
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
