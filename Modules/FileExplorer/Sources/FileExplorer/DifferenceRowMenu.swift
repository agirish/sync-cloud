import Foundation
import Sync

/// Pure logic behind the Differences table's row context menu: which per-side items to offer
/// (only sides that exist on disk) and how the ignore toggle resolves.
public enum DifferenceRowMenu {
    /// One side of a difference that actually exists on disk, ready for per-side
    /// menu items (Reveal in Finder, Quick Look, Copy Path).
    public struct Side: Equatable, Sendable {
        /// Pane's provider display name, already disambiguated by `PaneProviderNames`
        /// when both panes show the same provider — safe to use as a ForEach id.
        public let paneName: String
        /// Absolute filesystem path of the item on this side.
        public let path: String

        public init(paneName: String, path: String) {
            self.paneName = paneName
            self.path = path
        }
    }

    /// The sides of a difference that exist on disk, left first. A "missing on X"
    /// difference has no item on X, so only the opposite side is returned.
    public static func existingSides(for difference: FileDifference, paneNames: PaneProviderNames) -> [Side] {
        existing(for: difference, paneNames: paneNames).map(\.side)
    }

    /// The sides that exist, each with the scan's answer to "is it a folder" — one walk, so the
    /// editor's filter below cannot pair a side with the other side's fact.
    private static func existing(for difference: FileDifference,
                                 paneNames: PaneProviderNames) -> [(side: Side, isDirectory: Bool)] {
        var sides: [(side: Side, isDirectory: Bool)] = []
        if difference.type != .missingOnLeft {
            sides.append((Side(paneName: paneNames.left, path: difference.leftItemPath),
                          difference.leftIsDirectory))
        }
        if difference.type != .missingOnRight {
            sides.append((Side(paneName: paneNames.right, path: difference.rightItemPath),
                          difference.rightIsDirectory))
        }
        return sides
    }

    /// The sides of a difference that "Open in Edit" is offered for, left first: the sides that
    /// exist, narrowed to files the Edit workspace opens — text, writable, and PDFs, read-only.
    ///
    /// **The same predicate every other door asks** — `EditableText.opensInEdit(path:)`, the gate
    /// the pane row menu, the Info inspector and File ▸ Open in Edit apply — so this list cannot
    /// offer a file the editor would then refuse, nor withhold a `.md` or a PDF the rail would list.
    ///
    /// **A folder side offers nothing, whatever it is called.** The gate cannot tell a folder from a
    /// file (it has no disk to ask; a directory named `notes.md` answers true), and its own doc
    /// leaves that test to every caller that can have a directory in hand. The row carries the
    /// scan's answer for each side (`leftIsDirectory` / `rightIsDirectory`), so each side is asked
    /// on its own: a folder named like text is refused whether or not it is empty, and a
    /// folder-versus-file row still offers its FILE side. It asked `enclosedItemCount` until
    /// 2026-09-25, which is `nil` for an empty folder and set on both sides of a mismatch — so an
    /// empty folder called `notes.md` was offered, and the real text file opposite a non-empty
    /// folder was withheld.
    public static func editableSides(for difference: FileDifference, paneNames: PaneProviderNames) -> [Side] {
        existing(for: difference, paneNames: paneNames)
            .filter { !$0.isDirectory && EditableText.opensInEdit(path: $0.side.path) }
            .map(\.side)
    }

    /// The directions a row's own Copy to … items offer, right first as the bulk menu orders them:
    /// each direction whose source side exists.
    ///
    /// **Every row, not only a held one** (owner decision 2026-10-25). These began as the one place
    /// a HELD row's "choose which to keep" is made — every bulk run leaves it out, and ⌘← / ⌘→ and
    /// the Review card copy only the way its guess points — and a row with a clear direction is as
    /// much the user's to copy either way. So: both directions for a pair that exists on both sides
    /// (two files, a folder against a file, a name conflict), only the existing side for a row
    /// missing on one side.
    ///
    /// **A row copying FROM a link offers neither** (`.sourceIsSymbolicLink`): a copy would be a
    /// link too, whichever way the user wanted it, so `syncFile` refuses it and its note says why.
    /// The engine checks the link only for the side its suggestion copies from, so the item
    /// re-checks the side the user picked when it fires (`row(_:copiedTo:isSymbolicLink:)`).
    public static func copyDirections(for difference: FileDifference) -> [FileDifference.SyncAction] {
        guard difference.heldBack != .sourceIsSymbolicLink else { return [] }
        var directions: [FileDifference.SyncAction] = []
        if difference.type != .missingOnLeft { directions.append(.copyToRight) }
        if difference.type != .missingOnRight { directions.append(.copyToLeft) }
        return directions
    }

    /// The row a Copy to … item hands `syncFile`: `live` redirected the chosen way
    /// (`FileDifference.redirected(to:)`), and held as `.sourceIsSymbolicLink` when the side it now
    /// copies FROM is a link — so `syncFile` refuses it with the reason it gives every link row,
    /// rather than writing the link over the real file. `isSymbolicLink` is asked of that side's
    /// path and must not follow a final link.
    public static func row(_ live: FileDifference, copiedTo direction: FileDifference.SyncAction,
                           isSymbolicLink: (String) -> Bool) -> FileDifference {
        let row = live.redirected(to: direction)
        let source = direction == .copyToRight ? row.leftItemPath : row.rightItemPath
        guard row.heldBack != .sourceIsSymbolicLink, isSymbolicLink(source) else { return row }
        return FileDifference(
            id: row.id, relativePath: row.relativePath, leftItemPath: row.leftItemPath,
            rightItemPath: row.rightItemPath, type: row.type, action: row.action,
            description: row.description, isSyncing: row.isSyncing,
            leftFileSize: row.leftFileSize, rightFileSize: row.rightFileSize,
            enclosedItemCount: row.enclosedItemCount, leftIsDirectory: row.leftIsDirectory,
            rightIsDirectory: row.rightIsDirectory, heldBack: .sourceIsSymbolicLink)
    }

    /// Whether this difference is hidden by the current ignore set. Uses the same
    /// predicate the differences filter applies (`FileSyncManager.isIgnoredPath` over
    /// `relativePath`), so the menu label always agrees with list membership.
    public static func isIgnored(_ difference: FileDifference, ignoredPaths: Set<String>) -> Bool {
        FileSyncManager.isIgnoredPath(difference.relativePath, ignored: ignoredPaths)
    }

    /// Toggles the difference's ignore entry. The target is `relativePath` — the exact
    /// value `FileSyncManager.applyFilters()` matches differences against, and the same
    /// focal-point-relative form the tree panes' ignore produces — so ignoring here
    /// removes the row from the list and strikes it through in both trees.
    ///
    /// The ignored/not decision uses the same effective predicate as `isIgnored(_:ignoredPaths:)`
    /// (which drives the Ignore/Include label), so a row covered only by an ancestor folder
    /// entry un-ignores instead of pointlessly inserting its own path. Un-ignoring removes
    /// every covering entry — the exact path and any ancestor — so the row actually
    /// reappears in comparisons.
    public static func toggledIgnoredPaths(for difference: FileDifference, ignoredPaths: Set<String>) -> Set<String> {
        let path = difference.relativePath
        if FileSyncManager.isIgnoredPath(path, ignored: ignoredPaths) {
            return ignoredPaths.filter { entry in
                !(path == entry || path.hasPrefix(entry + "/"))
            }
        } else {
            var updated = ignoredPaths
            updated.insert(path)
            return updated
        }
    }
}
