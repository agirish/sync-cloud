import Events
import Foundation

/// Conservative cleanup of orphaned working files left behind by a crash or force-quit
/// mid-operation.
///
/// `safeCopyItem` / `safeMoveItem` stage content in `.tmp_<UUID>` siblings of the
/// destination and remove them on every normal exit path (`defer`), so a surviving
/// `.tmp_` artifact is almost always garbage: a partial duplicate of a source that still
/// exists. ALMOST — one path deliberately preserves a temp that is the only copy of a
/// consumed source (`replaceDestinationByMoving`'s double failure), which is why the sweep
/// only ever Trashes (recoverable), never unlinks. Two gates keep the sweep from touching
/// live data:
/// - the name must be exactly `.tmp_` followed by a parseable UUID — a user file that
///   merely starts with ".tmp_" never matches, and
/// - the artifact must be older than `minimumAge`, so an in-flight operation's staging
///   file is never reaped.
///
/// `.rollback_<UUID>` replacement backups are explicitly NOT swept: on Trash-less volumes
/// they are the undo stack's restorable handle and may be the only copy of a replaced
/// file. The scan only counts them so the caller can log their presence.
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

    /// Trashes the given artifacts — Trash ONLY, no `removeItem` fallback: a `.tmp_` can be
    /// the preserved only copy of a consumed source (`replaceDestinationByMoving`'s double
    /// failure), so the sweep must stay recoverable. On a Trash-less volume the artifact
    /// simply survives to the next sweep. Re-checks the name pattern as defense in depth:
    /// only exact `.tmp_<UUID>` names are ever touched, whatever the caller passed.
    /// - Returns: The number of artifacts actually removed.
    @discardableResult
    public static func removeTempArtifacts(atPaths paths: [String], fileManager: FileManaging) -> Int {
        var removed = 0
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard isTempArtifactName(url.lastPathComponent), fileManager.fileExists(atPath: path) else { continue }
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                removed += 1
            } catch {
                Task { @MainActor in
                    // "Left in place", not "left for the next sweep": on a Trash-less volume — the
                    // very condition this sweep is Trash-only to protect — no future sweep can
                    // succeed either, so promising a retry described a loop that never terminates.
                    Logger.shared.debug("Orphan sweep: couldn't trash \(path) (\(error.localizedDescription)) — left in place")
                }
            }
        }
        return removed
    }
}
