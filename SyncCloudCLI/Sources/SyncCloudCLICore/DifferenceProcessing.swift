import Foundation
import Sync

/// Direction filter for scan/sync: all differences, or only one copy direction.
public enum Direction: String, CaseIterable, Sendable {
    case auto
    case toRight = "to-right"
    case toLeft = "to-left"
}

/// Pure orchestration logic behind the `scan` and `sync` commands, extracted from the
/// command bodies so it can be unit-tested without spawning processes or touching disk.
public enum DifferenceProcessing {

    /// Applies the CLI's hidden/ignore/direction filters to a scan result, plus the app's
    /// Google Drive date-noise filter when its Settings toggle is on.
    /// Mirrors the app's semantics: hidden means any dot-prefixed path component; ignored
    /// means an exact match or prefix directory match from `--ignore`.
    ///
    /// The Drive filter replicates `FileSyncManager.applyFilters`/`computeFilteredState`
    /// (`dropDriveDateNoise`) — the source of truth, not reachable from here as a callable
    /// predicate: only when the setting is on AND the right side is Google Drive, drop
    /// differences that are exactly "right is newer, same size" (`.differentDates`,
    /// `sizesMatch`, action `.copyToLeft`) — Drive rewrites file dates, so these are noise.
    public static func filterDifferences(
        _ diffs: [FileDifference],
        direction: Direction,
        showHidden: Bool,
        ignore: [String],
        ignoreGoogleDriveNewerDateOnly: Bool = false,
        rightProviderType: CloudProvider.ProviderType? = nil
    ) -> [FileDifference] {
        let ignoredSet = Set(ignore)
        let dropDriveDateNoise = ignoreGoogleDriveNewerDateOnly && rightProviderType == .googleDrive
        return diffs.filter { diff in
            if !showHidden && FileSyncManager.isHiddenPath(diff.relativePath) {
                return false
            }
            if !ignoredSet.isEmpty && FileSyncManager.isIgnoredPath(diff.relativePath, ignored: ignoredSet) {
                return false
            }
            if dropDriveDateNoise,
               diff.type == .differentDates, diff.sizesMatch, diff.action == .copyToLeft {
                return false
            }
            switch direction {
            case .auto:
                return true
            case .toRight:
                return diff.action == .copyToRight
            case .toLeft:
                return diff.action == .copyToLeft
            }
        }
    }

    /// Splits differences for `--verify`: date-only differences whose contents verify as
    /// identical are dropped; everything else (including verification failures or skips,
    /// where the verifier returns false/nil) is kept, in the original order.
    ///
    /// - Parameter verifier: Content comparison for one difference; `true` means both sides
    ///   are byte-identical, `false` means they differ, `nil` means verification wasn't
    ///   possible. Only called for `.differentDates` items whose sizes match.
    /// - Returns: The differences still requiring a sync, and how many verified identical.
    public static func partitionByVerification(
        _ diffs: [FileDifference],
        verifier: (FileDifference) async -> Bool?
    ) async -> (kept: [FileDifference], verifiedIdenticalCount: Int) {
        var kept: [FileDifference] = []
        var verifiedIdenticalCount = 0
        for diff in diffs {
            if diff.type == .differentDates && diff.sizesMatch,
               await verifier(diff) == true {
                verifiedIdenticalCount += 1
            } else {
                kept.append(diff)
            }
        }
        return (kept, verifiedIdenticalCount)
    }

    /// The copy endpoints implied by a difference's action (left→right or right→left).
    public static func sourceAndTarget(for diff: FileDifference) -> (source: String, target: String) {
        switch diff.action {
        case .copyToRight:
            return (diff.leftItemPath, diff.rightItemPath)
        case .copyToLeft:
            return (diff.rightItemPath, diff.leftItemPath)
        }
    }

    /// Stable machine-readable name for a difference type (used in text and JSON output).
    public static func typeString(_ type: FileDifference.DifferenceType) -> String {
        switch type {
        case .missingOnRight: return "missing-on-right"
        case .missingOnLeft: return "missing-on-left"
        case .differentDates: return "different"
        case .nameConflict: return "name-conflict"
        }
    }

    /// Stable machine-readable name for a sync action (used in text and JSON output).
    public static func actionString(_ action: FileDifference.SyncAction) -> String {
        switch action {
        case .copyToRight: return "copy-to-right"
        case .copyToLeft: return "copy-to-left"
        }
    }
}
