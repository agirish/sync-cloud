import Foundation
import Sync

/// Pure logic behind the Differences table's row context menu: which per-side items to offer
/// (only sides that exist on disk) and how the ignore toggle resolves.
public enum DifferenceRowMenu {
    /// One side of a difference that actually exists on disk, ready for per-side
    /// menu items (Reveal in Finder, Quick Look, Copy Path).
    public struct Side: Equatable, Sendable {
        /// The pane's provider display name, already disambiguated by `PaneProviderNames` when
        /// both panes show the same provider, so it is safe as a ForEach id.
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

    /// The sides that exist, each with the scan's answer to "is it a folder", in one walk so the
    /// editor's filter can't pair a side with the other side's fact.
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
    /// exist, narrowed to files the Edit workspace opens (text, writable; PDFs, read-only).
    ///
    /// Asks `EditableText.opensInEdit(path:)`, the gate the pane row menu, the Info inspector and
    /// File ▸ Open in Edit apply, so this list matches what the editor accepts.
    ///
    /// A folder side offers nothing, whatever it is called: the gate can't tell a folder from a
    /// file (a directory named `notes.md` answers true). Each side is checked by the scan's own
    /// `leftIsDirectory` / `rightIsDirectory`, so an empty folder named like text is refused and a
    /// folder-versus-file row still offers its file side.
    public static func editableSides(for difference: FileDifference, paneNames: PaneProviderNames) -> [Side] {
        existing(for: difference, paneNames: paneNames)
            .filter { !$0.isDirectory && EditableText.opensInEdit(path: $0.side.path) }
            .map(\.side)
    }

    /// The directions a row's own Copy to … items offer, right first as the bulk menu orders them:
    /// each direction whose source side exists. Offered on every row, held or not, since these are
    /// where a held row's "choose which to keep" is made, and any row is the user's to copy either
    /// way.
    ///
    /// A row held as `.sourceIsSymbolicLink` offers neither: copying from the link would write the
    /// link, and copying the other way would replace a link with a file, which this menu doesn't
    /// decide. The engine checks only the suggested source, so the item re-checks the side the
    /// user picked when it fires (`row(_:copiedTo:isSymbolicLink:)`).
    public static func copyDirections(for difference: FileDifference) -> [FileDifference.SyncAction] {
        guard difference.heldBack != .sourceIsSymbolicLink else { return [] }
        var directions: [FileDifference.SyncAction] = []
        if difference.type != .missingOnLeft { directions.append(.copyToRight) }
        if difference.type != .missingOnRight { directions.append(.copyToLeft) }
        return directions
    }

    /// Why a Copy to … item that fired has nothing to do (the banner's words), or nil when it can
    /// go ahead. Resolved when it fires, against the live row: a rescan since the menu opened can
    /// have settled the pair or found a link on the source side, and a click must never do nothing
    /// silently.
    public static func copyRefusal(for live: FileDifference?, direction: FileDifference.SyncAction) -> String? {
        guard let live else { return "Nothing was copied — that row is no longer in the list" }
        guard copyDirections(for: live).contains(direction) else {
            return "Nothing was copied — “\(live.fileName)” can no longer be copied that way"
        }
        return nil
    }

    /// The note a Copy to … item hands `syncFile` for its prompts when the user picked the way
    /// against the engine's suggestion, or nil.
    ///
    /// An unheld row of two files differing by date always suggests newer over older (ties,
    /// missing dates and folders are held, `FileDifference.heldBack`), so the other way overwrites
    /// the newer file, and the prompts must say so. The sentence is the Review card's
    /// (`ReviewCardModel.newerDestinationSentence`).
    static func newerDestinationNote(for live: FileDifference, copiedTo direction: FileDifference.SyncAction,
                                     paneNames: PaneProviderNames) -> String? {
        guard direction != live.action, live.heldBack == nil, live.type == .differentDates,
              !live.leftIsDirectory, !live.rightIsDirectory else { return nil }
        return ReviewCardModel.newerDestinationSentence(
            destinationName: direction == .copyToRight ? paneNames.right : paneNames.left, isMove: false)
    }

    /// The row a Copy to … item hands `syncFile`: `live` redirected the chosen way
    /// (`FileDifference.redirected(to:)`), and held as `.sourceIsSymbolicLink` when its new source
    /// is a link, so `syncFile` refuses it rather than writing the link over the real file.
    /// `isSymbolicLink` is asked of that side's path and must not follow a final link.
    public static func row(_ live: FileDifference, copiedTo direction: FileDifference.SyncAction,
                           isSymbolicLink: (String) -> Bool) -> FileDifference {
        let row = live.redirected(to: direction)
        let source = direction == .copyToRight ? row.leftItemPath : row.rightItemPath
        guard row.heldBack != .sourceIsSymbolicLink, isSymbolicLink(source) else { return row }
        return FileDifference(
            id: row.id, relativePath: row.relativePath, leftItemPath: row.leftItemPath,
            rightItemPath: row.rightItemPath, type: row.type, action: row.action,
            description: row.description, isSyncing: row.isSyncing,
            leftFileSize: row.leftFileSize, leftModified: row.leftModified,
            rightFileSize: row.rightFileSize, rightModified: row.rightModified,
            enclosedItemCount: row.enclosedItemCount, leftIsDirectory: row.leftIsDirectory,
            rightIsDirectory: row.rightIsDirectory, heldBack: .sourceIsSymbolicLink)
    }

    /// Whether this difference is hidden by the current ignore set. Uses the same
    /// predicate the differences filter applies (`FileSyncManager.isIgnoredPath` over
    /// `relativePath`), so the menu label always agrees with list membership.
    public static func isIgnored(_ difference: FileDifference, ignoredPaths: Set<String>) -> Bool {
        FileSyncManager.isIgnoredPath(difference.relativePath, ignored: ignoredPaths)
    }

    /// Toggles the difference's ignore entry, keyed on `relativePath`: the value
    /// `FileSyncManager.applyFilters()` matches and the form the tree panes' ignore produces, so
    /// ignoring here removes the row from the list and strikes it through in both trees.
    ///
    /// Decides with the same predicate as `isIgnored(_:ignoredPaths:)`, which drives the label, so
    /// a row covered by an ancestor entry un-ignores. Un-ignoring removes every covering entry,
    /// the path and any ancestor, so the row really reappears.
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
