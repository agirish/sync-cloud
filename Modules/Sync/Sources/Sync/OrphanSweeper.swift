import Events
import Foundation

/// Conservative cleanup of orphaned working files left behind by a crash or force-quit
/// mid-operation.
///
/// `safeCopyItem` / `safeMoveItem` stage content in `.tmp_<UUID>` siblings of the
/// destination and remove them on every normal exit (`defer`), so a surviving `.tmp_` is
/// almost always a partial duplicate of a source that still exists. Almost: one path keeps a
/// temp that is the only copy of a consumed source (`replaceDestinationByMoving`'s double
/// failure), so the sweep only ever Trashes (recoverable), never unlinks. Two gates keep it off
/// live data:
/// - the name must be exactly `.tmp_` plus a parseable UUID, so a user file that merely starts
///   with ".tmp_" never matches, and
/// - the artifact must be older than `minimumAge`, so an in-flight operation's staging file is
///   never reaped.
///
/// `.rollback_<UUID>` replacement backups are never swept: on Trash-less volumes they are the
/// undo stack's restorable handle and may be the only copy of a replaced file. The scan only
/// counts them for the log.
public enum OrphanSweeper {

    /// Minimum age before a `.tmp_` artifact counts as orphaned rather than in-flight.
    public static let minimumAge: TimeInterval = 60 * 60

    private static let tempPrefix = ".tmp_"
    private static let rollbackPrefix = ".rollback_"

    /// True when `name` is exactly the staging pattern `safeCopyItem`/`safeMoveItem`
    /// produce: ".tmp_" + UUID.
    public static func isTempArtifactName(_ name: String) -> Bool {
        hasUUIDSuffix(name, prefix: tempPrefix)
    }

    /// True when `name` matches the `.rollback_<UUID>` replacement-backup pattern.
    public static func isRollbackBackupName(_ name: String) -> Bool {
        hasUUIDSuffix(name, prefix: rollbackPrefix)
    }

    private static func hasUUIDSuffix(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    public struct ArtifactScan: Equatable, Sendable {
        /// Absolute paths of `.tmp_<UUID>` artifacts old enough to reap.
        public var tempPaths: [String] = []
        /// Number of `.rollback_<UUID>` backups seen. Never deleted; for logging only.
        public var rollbackCount = 0

        public init(tempPaths: [String] = [], rollbackCount: Int = 0) {
            self.tempPaths = tempPaths
            self.rollbackCount = rollbackCount
        }
    }

    /// Collects sweepable artifacts from already-built pane trees — pure, no disk I/O.
    /// A `.tmp_` node qualifies only when its modification date is known and earlier than
    /// `cutoff`; an unknown date keeps the node (deletion is the action that needs proof).
    /// Matching nodes are not descended into: their children live inside the artifact and
    /// go with it.
    public static func findArtifacts(inTrees trees: [[FileNode]], olderThan cutoff: Date) -> ArtifactScan {
        var scan = ArtifactScan()
        var seen = Set<String>()
        for tree in trees {
            collect(from: tree, cutoff: cutoff, into: &scan, seen: &seen)
        }
        return scan
    }

    private static func collect(from nodes: [FileNode], cutoff: Date, into scan: inout ArtifactScan, seen: inout Set<String>) {
        for node in nodes {
            if isTempArtifactName(node.name) {
                if let modified = node.modificationDate, modified < cutoff, seen.insert(node.id).inserted {
                    scan.tempPaths.append(node.id)
                }
                continue
            }
            if isRollbackBackupName(node.name) {
                if seen.insert(node.id).inserted {
                    scan.rollbackCount += 1
                }
                continue
            }
            if let children = node.children {
                collect(from: children, cutoff: cutoff, into: &scan, seen: &seen)
            }
        }
    }

    /// The paths whose failed removal has been reported at WARN this launch.
    static let unremovableReported = OncePerLaunch()

    /// Trashes the given artifacts, with no `removeItem` fallback: a `.tmp_` can be the only
    /// copy of a consumed source (`replaceDestinationByMoving`'s double failure), so the sweep
    /// must stay recoverable. On a Trash-less volume the artifact stays where it is. Re-checks the
    /// name as defense in depth: only exact `.tmp_<UUID>` names are touched, whatever is passed.
    /// - Returns: The number of artifacts actually removed.
    @discardableResult
    public static func removeTempArtifacts(atPaths paths: [String], fileManager: FileManaging) -> Int {
        var removed = 0
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard isTempArtifactName(url.lastPathComponent), fileManager.fileExists(atPath: path) else { continue }
            do {
                do {
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                } catch where FileSyncManager.isLocked(url, fileManager: fileManager) {
                    // A locked staging copy is unlocked, then Trashed: the Trash refuses a locked
                    // item (EPERM), so it would survive every sweep. This touches no user item: a
                    // `.tmp_` that is a user's original (the double failure above) got there by a
                    // rename, and the kernel refuses to rename a locked item, so a locked one is
                    // always a copy.
                    try fileManager.setAttributes([.immutable: false, .appendOnly: false], ofItemAtPath: path)
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                }
                removed += 1
            } catch {
                // "Left in place", not "left for the next sweep": on a Trash-less volume no later
                // sweep can succeed either. WARN once per path per launch, since every scan retries
                // it; Debug after that. Logged here, not hopped to the main actor: the Logger is
                // nonisolated, and the hop let a capture's flush marker finish before the line.
                let logLine = "Orphan sweep: couldn't trash \(path) (\(error.localizedDescription)) — left in place"
                if unremovableReported.isFirst(path) {
                    Logger.shared.warning(logLine)
                } else {
                    Logger.shared.debug(logLine)
                }
            }
        }
        return removed
    }
}
