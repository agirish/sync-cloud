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
    /// exist, narrowed to files the Edit workspace opens.
    ///
    /// **The same predicate every other door asks** — `EditableText.isText(path:)`, the gate the
    /// pane row menu, the Info inspector and File ▸ Open in Edit apply — so this list cannot offer
    /// a PDF the editor would then refuse, nor withhold a `.md` the rail would list.
    ///
    /// **A folder side offers nothing, whatever it is called.** `isText` cannot tell a folder from a
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
            .filter { !$0.isDirectory && EditableText.isText(path: $0.side.path) }
            .map(\.side)
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
