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
    /// **A row held as `.sourceIsSymbolicLink` offers neither.** The side its suggestion copies
    /// FROM is a link, and a copy from it would write the link, so `syncFile` refuses that way and
    /// its note says why. The other way copies from the side that is not a link — that copy would
    /// be a real one, over the link — and is left out too, by choice: replacing a link with a file
    /// is not a decision this menu makes. The engine checks the link only for the side its
    /// suggestion copies from, so the item re-checks the side the user picked when it fires
    /// (`row(_:copiedTo:isSymbolicLink:)`).
    public static func copyDirections(for difference: FileDifference) -> [FileDifference.SyncAction] {
        guard difference.heldBack != .sourceIsSymbolicLink else { return [] }
        var directions: [FileDifference.SyncAction] = []
        if difference.type != .missingOnLeft { directions.append(.copyToRight) }
        if difference.type != .missingOnRight { directions.append(.copyToLeft) }
        return directions
    }

    /// Why a Copy to … item that fired has nothing to do — the banner's words — or nil when it can
    /// go ahead. The item is resolved when it FIRES, against the live row: a rescan since the menu
    /// opened can have settled the pair (the row is gone) or found a link on the side it would copy
    /// from (the direction is no longer offered). Both returned silently, so a click did nothing
    /// and said nothing (review E10).
    public static func copyRefusal(for live: FileDifference?, direction: FileDifference.SyncAction) -> String? {
        guard let live else { return "Nothing was copied — that row is no longer in the list" }
        guard copyDirections(for: live).contains(direction) else {
            return "Nothing was copied — “\(live.fileName)” can no longer be copied that way"
        }
        return nil
    }

    /// The note a Copy to … item hands `syncFile` for its prompts when the user picked the way
    /// AGAINST the engine's suggestion, or nil (review E4).
    ///
    /// An unheld row of two files that differ by date always suggests copying the newer over the
    /// older — a tie, a missing date or a folder on one side is held (`FileDifference.heldBack`)
    /// — so the other way overwrites the newer file. The confirmation and the collision prompt
    /// read as they do for any replace, which is the one thing this copy is not. Same sentence the
    /// Review card shows for a newer destination (`ReviewCardModel.newerDestinationSentence`).
    static func newerDestinationNote(for live: FileDifference, copiedTo direction: FileDifference.SyncAction,
                                     paneNames: PaneProviderNames) -> String? {
        guard direction != live.action, live.heldBack == nil, live.type == .differentDates,
              !live.leftIsDirectory, !live.rightIsDirectory else { return nil }
        return ReviewCardModel.newerDestinationSentence(
            destinationName: direction == .copyToRight ? paneNames.right : paneNames.left, isMove: false)
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
