import SwiftUI
import AppKit
import Sync
import Design
import FileExplorer

/// One row of the folder sidebar: a remembered folder, under the heading that remembered it.
public struct FolderSidebarRow: Identifiable, Equatable, Sendable {

    /// Why this folder is listed. The two lists are `FolderJumpStore`'s: favorites are curated,
    /// recents are the last places visited.
    ///
    /// The heading reads "Favorites", and its verbs say "Add to Favorites" / "Remove from
    /// Favorites", because "pin" belongs to tabs: a pinned tab (`PaneTab.isPinned`) is an unrelated
    /// feature on the strip directly above this column, and one word for two things on adjacent
    /// surfaces is worse than two words.
    ///
    /// The case is still `pinned` and the store still `folderJumpPinnedByRoot`: only the displayed
    /// word differs, and nothing persisted is keyed on it.
    public enum Group: String, Sendable, CaseIterable {
        case pinned = "Favorites"
        case recents = "Recents"
    }

    public let group: Group
    /// The provider root this folder is under, normalised through `FolderJumpStore.key(forRoot:)`.
    /// Both sections span every source, so a click needs the row to say which source to act on.
    public let root: String
    /// The source's display name, for the badge: `iCloud`, `Dropbox`, `Drive · emp`.
    ///
    /// Always set on a recent: Recents, Revisited and Frequent draw different subsets of the same
    /// folders, and a badge that came and went with the mode would make one folder look different
    /// in each. On a favorite, `nil` when only one source contributes rows, where the same word
    /// down the whole column says nothing.
    public let sourceName: String?
    /// The path relative to ``root``, which the pane is navigated to.
    public let relativePath: String
    /// The folder's own name, which is what the row reads.
    public let name: String
    /// The folders above it, shown only on a favorite, and only when another row on screen has the
    /// same name.
    ///
    /// Two `Legal` folders under different clients is the case that matters: listed as "Legal"
    /// twice, the rows are indistinguishable and one goes to the wrong place. Always showing the
    /// parent would fill a 180pt column with two-line rows whose second line is mostly redundant.
    ///
    /// Always `nil` on a recent: its parent is often a top-level folder whose line just repeats the
    /// source badge on the same row, and a recent is a place you were minutes ago and recognise. A
    /// favorite is a place you chose once and may not. The whole path is in the tooltip on both.
    public let detail: String?
    /// False when the root did not answer: the list is then everything remembered, unchecked
    /// (`FolderJumpStore.reachable`), a sleeping drive rather than a folder that has gone.
    public let isAvailable: Bool

    /// The root is part of the identity. Two sources often hold the same relative path (a `Health`
    /// under iCloud and under Dropbox), and a `ForEach` over colliding ids would drop one.
    public var id: String { "\(group.rawValue)/\(root)/\(relativePath)" }

    public init(group: Group, root: String, sourceName: String?, relativePath: String,
                name: String, detail: String?, isAvailable: Bool) {
        self.group = group
        self.root = root
        self.sourceName = sourceName
        self.relativePath = relativePath
        self.name = name
        self.detail = detail
        self.isAvailable = isAvailable
    }
}

/// The sidebar's rules, separate from its view so both can be asserted without mounting anything.
public enum FolderSidebarModel {

    /// What one source contributes to the folder sections: its favorites, and whether it answered.
    ///
    /// Recents are not here: they arrive as one ordered global list
    /// (`FolderJumpStore.mostRecentAcrossRoots`), because ordering them needs every root and a
    /// clock. Favorites are per source because their order is the user's own and nothing re-sorts it.
    public struct Source: Equatable, Sendable {
        public let root: String
        /// The provider's display name: the badge, and the qualifier a top-level folder borrows.
        public let name: String
        /// Relative paths in the user's curated order, already checked against disk by
        /// `FolderJumpStore.reachable`.
        public let favorites: [String]
        /// False when the root did not answer. Its rows stay listed and refuse.
        public let isAvailable: Bool

        public init(root: String, name: String, favorites: [String], isAvailable: Bool) {
            self.root = root
            self.name = name
            self.favorites = favorites
            self.isAvailable = isAvailable
        }
    }

    /// Every folder row the column draws: favorites across all sources, then one global recents list.
    ///
    /// One builder, so a single place decides what a row says. Qualification can't be computed per
    /// source: whether `Legal` needs telling apart depends on what else is on screen, and half the
    /// screen may belong to another account.
    ///
    /// Two disambiguators, answering different questions:
    ///
    /// - The badge (``FolderSidebarRow/sourceName``) says which source: on every recent, and on a
    ///   favorite whenever more than one source contributes rows.
    /// - The detail (``FolderSidebarRow/detail``) says which folder: on a favorite only, when its
    ///   leaf name collides with another row's. It is the parent path, or the source's name for a
    ///   top-level folder, the convention `StorageLensView.displayFolder` uses.
    ///
    /// A favorite can need both: a `Clients/Legal` on Drive beside a top-level `Legal` on iCloud.
    ///
    /// - Parameter recents: already ordered by the store (`FolderJumpStore.mostRecentAcrossRoots`)
    ///   and not yet capped (see `recentsLimit`). Rows for a root not in `sources` are dropped, not
    ///   drawn unavailable: a removed source is not a sleeping drive.
    /// - Parameter favoriteOrder: the user's dragged sequence, as `FolderJumpStore.favoriteKey`
    ///   keys. **It must be applied here, or a drag writes an order nothing draws.**
    ///   `Source.favorites` says which folders are in the section; the sequence is cross-source,
    ///   which per-root arrays can't express. It goes through `FolderJumpStore.orderedFavorites`,
    ///   the same rule the reorder handler applies.
    /// - Parameter listedElsewhere: per root, the relative paths the column already offers under
    ///   another heading: Favorites places and Locations rows, expressed against this root.
    ///   Subtracted from Recents, since a second route to a row a few lines up wastes one of eight
    ///   rows. With `~/Desktop`, `~/Documents` and `~/Downloads` in Favorites and a folder source
    ///   over the home folder, opening those three would fill three rows with duplicates.
    ///
    ///   Subtracted here, not by the store, because only the column knows what it lists; the
    ///   places and mounted volumes are not `FolderJumpStore`'s. Keyed by
    ///   `FolderJumpStore.key(forRoot:)` and holding relative paths, so the check is string
    ///   arithmetic, not a trip to the disk. A root the map doesn't name subtracts nothing.
    /// - Parameter recentsLimit: how many recents survive to become rows.
    ///
    ///   Applied after both filters, so only drawn rows count toward it; capping first would leave
    ///   the section a row short for every recent filtered out. `mostRecentAcrossRoots` states the
    ///   same rule for its own filters.
    public static func rows(sources: [Source], recents: [RememberedVisit],
                            favoriteOrder: [String] = [],
                            listedElsewhere: [String: Set<String>] = [:],
                            recentsLimit: Int = FolderJumpStore.maxRecents) -> [FolderSidebarRow] {
        // First-wins on a duplicate root, not `uniqueKeysWithValues:`, which traps.
        // `SettingsManager.existingSource` keeps two providers off one root, but a hand-edited plist
        // or a new entry point would turn a gap there into a crash on every sidebar refresh.
        let byRoot = Dictionary(sources.map { ($0.root, $0) }, uniquingKeysWith: { a, _ in a })
        struct Draft { let group: FolderSidebarRow.Group, root: String, path: String, name: String }
        var drafts: [Draft] = []
        // The sequence is applied on top of the caller's source order (Settings', as Locations
        // uses), so a favorite added since the last drag sits beside its own account. Only what
        // the sequence names moves.
        let claimed = sources.flatMap { source in
            source.favorites.map {
                RememberedVisit(root: source.root, relativePath: $0,
                                name: leaf(of: $0), visitedAt: nil)
            }
        }
        for favorite in FolderJumpStore.orderedFavorites(claimed, order: favoriteOrder) {
            drafts.append(Draft(group: .pinned, root: favorite.root,
                                path: favorite.relativePath, name: favorite.name))
        }
        var recentsDrawn = 0
        for visit in recents where byRoot[visit.root] != nil {
            guard recentsDrawn < recentsLimit else { break }
            // Already on the column under Favorites or Locations (see `listedElsewhere`).
            guard listedElsewhere[visit.root]?.contains(visit.relativePath) != true else { continue }
            drafts.append(Draft(group: .recents, root: visit.root, path: visit.relativePath,
                                name: leaf(of: visit.relativePath)))
            recentsDrawn += 1
        }

        // Only sources that contribute a row count toward "multi-source": a second account with
        // nothing remembered shouldn't put a badge on every row. Read off the drafts, so it counts
        // rows actually drawn after Recents' filters and cap, not the inputs.
        let showsBadge = Set(drafts.map(\.root)).count > 1

        // Counted across both groups and every source, because the reader sees one column.
        var leafCounts: [String: Int] = [:]
        for draft in drafts { leafCounts[draft.name, default: 0] += 1 }

        return drafts.map { draft in
            let source = byRoot[draft.root]
            let parent = (draft.path as NSString).deletingLastPathComponent
            let qualifier = parent.isEmpty ? (source?.name ?? "") : parent
            let collides = (leafCounts[draft.name] ?? 0) > 1
            // Only a favorite carries a second line (`FolderSidebarRow.detail`). Recents still count
            // toward the collision on purpose: a favorite `Legal` above a recent `Legal` is exactly
            // the pair where the favorite must say which one it is.
            let showsDetail = draft.group == .pinned && collides && !qualifier.isEmpty
            return FolderSidebarRow(
                group: draft.group,
                root: draft.root,
                sourceName: draft.group == .recents || showsBadge ? source?.name : nil,
                relativePath: draft.path,
                name: draft.name,
                detail: showsDetail ? qualifier : nil,
                isAvailable: source?.isAvailable ?? false)
        }
    }

    /// Whether the sidebar is switched on: the column, its chord, its menu item, its toolbar button
    /// and its ⌘/ row.
    ///
    /// Kept as a constant because `appliesTo` is the one choke point every other question runs
    /// through, and a future hold or workspace gate belongs there, not at a call site.
    /// `FolderSidebarVisibilityTests` passes `enabled:` explicitly so the Browse-only rule stays
    /// asserted whichever way this is set.
    public static let isEnabled = true

    /// Where the sidebar can exist at all: a workspace that carries one, with its panes showing, and
    /// not while ``isEnabled`` is false.
    ///
    /// The View item, the toolbar button and the column are each gated on this, so all three
    /// appear and disappear together. `Workspace` isn't visible from this module, so the caller
    /// supplies the verdict; the point is that the rule is written once.
    ///
    /// The lens workspaces get one too: the window floor is 760 and the rail and lens panel claim
    /// 560, leaving 200pt for a sidebar whose default is 180, so they need a clamp
    /// (`PaneLogic.lensSidebarWidth`), not an exclusion.
    ///
    /// Not while the panes are collapsed, unless the workspace's sidebar outlives the collapse.
    /// Collapsing asks for maximum room, a 180pt column beside a 34pt spine takes it back, and in a
    /// lens nothing would answer a click, since the pane it re-roots is folded away. Edit is the
    /// exception (`outlivesCollapse`): its Text Files list reads the pane's folder, so a sidebar
    /// click re-points the list with the pane still folded. Folded in here so the refresh guard and
    /// the drawn column can't disagree about whether a sidebar exists.
    ///
    /// - Parameter outlivesCollapse: the workspace keeps its sidebar beside a collapsed pane.
    ///
    /// - Parameter enabled: defaults to ``isEnabled``, which every caller in the app uses.
    ///   Injectable, like `opensInNewTab(_:)`'s modifiers, so a test isn't only asking `true && x`
    ///   and the rule is asserted whichever state the switch is in.
    public static func appliesTo(workspaceSupportsSidebar: Bool, panesCollapsed: Bool = false,
                                 outlivesCollapse: Bool = false,
                                 enabled: Bool = FolderSidebarModel.isEnabled) -> Bool {
        enabled && workspaceSupportsSidebar && (outlivesCollapse || !panesCollapsed)
    }

    /// Why the toggle is greyed out, when it is.
    ///
    /// Names no workspace: a sentence listing the supported workspaces goes stale every time the set
    /// changes, and nothing fails when it does.
    ///
    /// Two ways to be unavailable, with different remedies, so one sentence can't serve both.
    /// Returns `nil` when the sidebar is available, so a caller can't render a reason that doesn't
    /// apply.
    public static func unavailableReason(workspaceSupportsSidebar: Bool, panesCollapsed: Bool,
                                         outlivesCollapse: Bool = false,
                                         enabled: Bool = FolderSidebarModel.isEnabled) -> String? {
        guard !appliesTo(workspaceSupportsSidebar: workspaceSupportsSidebar,
                         panesCollapsed: panesCollapsed, outlivesCollapse: outlivesCollapse,
                         enabled: enabled) else { return nil }
        // Order matters where both apply: only the collapse is something the user can fix by
        // expanding a pane, and sending them to do work that changes nothing is worse than saying
        // less. Every workspace supports the sidebar today, so the collapse branch is the live one;
        // the first stays because `supportsFolderSidebar` is a real switch a workspace can turn off.
        if !workspaceSupportsSidebar || !enabled {
            return "The sidebar is not available here"
        }
        return "Show the panes to use the sidebar"
    }

    /// Whether the column is on screen: a different question from the one above, and the one that
    /// decides whether resolving its rows is worth a `stat` of the provider root. Written once so
    /// the sidebar can't draw rows nobody refreshed, or refresh rows nobody draws.
    public static func isShowing(workspaceSupportsSidebar: Bool, panesCollapsed: Bool = false,
                                 outlivesCollapse: Bool = false, preference: Bool,
                                 enabled: Bool = FolderSidebarModel.isEnabled) -> Bool {
        appliesTo(workspaceSupportsSidebar: workspaceSupportsSidebar, panesCollapsed: panesCollapsed,
                  outlivesCollapse: outlivesCollapse, enabled: enabled) && preference
    }

    /// The rows of one group, in order; the view's `ForEach` and the tests read the same list.
    public static func rows(_ rows: [FolderSidebarRow], in group: FolderSidebarRow.Group) -> [FolderSidebarRow] {
        rows.filter { $0.group == group }
    }

    /// How many rows Favorites draws: its remembered folders and its places. The section is two
    /// lists, so a count of the folders alone would fold the first-run column (three standard
    /// places, no folder yet) to a heading reading `0` and say "0 items" aloud. The rule the
    /// collapsed badge, its VoiceOver label and the section's other readers share.
    public static func favoritesCount(folderRows: [FolderSidebarRow], places: Int) -> Int {
        rows(folderRows, in: .pinned).count + places
    }

    /// What a click on a row means: ⌘ opens a new tab, a plain click switches this pane.
    ///
    /// Takes the modifiers rather than reading `NSEvent.modifierFlags`, as `DashboardViews` does:
    /// the flags are the machine's keyboard state, so a test can only pin this by passing them in.
    public static func opensInNewTab(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.command)
    }

    /// Whether a row can be opened at all. An unavailable row stays listed (deleting a favorite
    /// because a drive is asleep would cost the user their favorites) but refuses, like the ⌘K
    /// palette's unavailable rows.
    public static func canOpen(_ row: FolderSidebarRow) -> Bool { row.isAvailable }

    /// The folder a row lives in, as a row of its own, or nil where there isn't one to show.
    ///
    /// Nil in two different cases: a row at its source's root has no enclosing folder inside that
    /// source, and an unavailable row's whole root isn't answering.
    ///
    /// The parent keeps the child's `group`, which doesn't claim the parent is a favorite: nothing
    /// reads `group` on the way to opening one, and a third case would be one every switch over
    /// `Group` must handle. The name is re-derived from the parent path so the row reads as that
    /// folder.
    public static func enclosingFolder(of row: FolderSidebarRow) -> FolderSidebarRow? {
        guard row.isAvailable, !row.relativePath.isEmpty else { return nil }
        let parent = (row.relativePath as NSString).deletingLastPathComponent
        return FolderSidebarRow(group: row.group, root: row.root, sourceName: row.sourceName,
                                relativePath: parent,
                                name: parent.isEmpty ? (row.sourceName ?? leaf(of: row.root))
                                                     : leaf(of: parent),
                                detail: nil, isAvailable: row.isAvailable)
    }

    private static func leaf(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// Something the sidebar just did that can still be taken back, shown at the foot of the column.
///
/// The inline alternative to ⌘Z. The window's `UndoManager` holds file operations
/// (`FileSyncManager` registers sync runs and checks the top is still that run before reversing),
/// so a configuration change there would let someone who moved forty files, clicked a shortcut and
/// pressed ⌘Z get a source removed instead of their move back.
///
/// In the column, not the pane's status bar: a notice belongs next to the row the user just
/// clicked, where they are looking, and Browse's status bar states standing facts about the tree,
/// not transient messages.
public struct SidebarNotice: Equatable, Sendable {
    public let message: String
    /// Always present, and "Dismiss" counts. A notice about an ejected card has nothing to undo,
    /// but still needs a way off the column: nothing else clears one, and it would sit there for
    /// the rest of the session. The host picks the word (`FolderSidebarNotice.actionTitle`).
    public let actionTitle: String

    public init(message: String, actionTitle: String) {
        self.message = message
        self.actionTitle = actionTitle
    }
}

/// Which pane a click will act on, for a workspace where that is a real question.
///
/// `nil` with one pane: nothing to disambiguate, and "opens in the pane" would be noise. Compare is
/// the only surface that sets it.
///
/// It carries no control. The side is set by clicking the pane itself and shown by the accent
/// border it wears; that value also governs the action bar and the lens scans, too much for a
/// sidebar header to set. What remains is the half the border can't say: that these rows open
/// there.
public struct SidebarTarget: Equatable, Sendable {
    /// Whether the RIGHT pane is the one a click acts on.
    public let targetsRight: Bool
    public init(targetsRight: Bool) {
        self.targetsRight = targetsRight
    }

    /// What the line says: the side, never a source. `refreshFolderSidebarRows` builds Favorites,
    /// Locations and Recents from every enabled source at once, so "Opens in Google Drive" would
    /// wrongly suggest the rows are Google Drive's. The side is the one thing true of every row.
    public var openingDescription: String {
        "Opens on \(Self.label(targetsRight: targetsRight))"
    }

    /// Points at a pane. `arrow.left`/`arrow.right` would both be wrong: both panes are right of this
    /// column, so an arrow would point the same way for either.
    public static func symbol(targetsRight: Bool) -> String {
        targetsRight ? "rectangle.righthalf.filled" : "rectangle.lefthalf.filled"
    }

    public static func label(targetsRight: Bool) -> String {
        targetsRight ? "Right" : "Left"
    }
}

/// The folder sidebar: Favorites, Locations and Recents, in that order.
///
/// Keeps on screen the favorites and recents `FolderJumpStore` holds, which are otherwise reached
/// only through the jump menu and ⌘K, across every source, with Locations beside them. Drawn on
/// every workspace whose `Workspace.supportsFolderSidebar` is true; the lens workspaces and Compare
/// take a clamped width (`PaneLogic.lensSidebarWidth`, `PaneLogic.compareSidebarWidth`).
///
/// Locations changes a pane's source; the header capsule still shows it, and is the only answer in
/// Compare. The sidebar must not own source switching outright, or closing it (⌃⌘S) would remove
/// the only way to switch.
public struct FolderSidebarView: View {

    /// The one coordinate space every drag measurement is taken in. Named rather than `.global`:
    /// the window moves, and a midpoint recorded in screen coordinates would be compared against a
    /// pointer position taken after it moved.
    static let dragSpace = "sidebarDrag"

    /// A row's minimum height, and the column's rhythm. A floor, not vertical padding, so a row that
    /// grows a second line (a favorite carrying its parent) gets taller instead of clipping.
    ///
    /// 30 gives a 32pt pitch with the 2pt between rows, matching Finder's sidebar measured side by
    /// side. Tune this floor, not the 2pt between rows or the 14pt between sections.
    static let rowHeight: CGFloat = 30

    /// The current row's wash, named once because the selection lenses wear it too.
    static let currentWash: Double = 0.16
    /// The current place's lens and the current folder's lens; see `SelectionLens`.
    static let sourceLensChannel = SelectionLensChannel("sidebar.sources")
    static let folderLensChannel = SelectionLensChannel("sidebar.folders")

    /// - Parameter dimmed: the opacity the current row is drawn at: a place that stopped answering
    ///   (0.45), a folder that can't be opened (0.4). The wash sits inside the row and dims with it;
    ///   the lens is drawn by the host, outside the row, so it must be told.
    static func lensStyle(_ accent: Color, dimmed: Double = 1) -> SelectionLensStyle {
        SelectionLensStyle(shape: .roundedRect(Radius.chip), color: accent, markerOpacity: currentWash,
                           opacity: dimmed)
    }

    /// The opacity a place that isn't answering is drawn at, and a local folder that isn't a source
    /// yet. Named once: the row draws at it, and so does its lens, outside the row.
    static let dimmedPlaceOpacity: Double = 0.45
    /// The opacity a folder that cannot be opened is drawn at. See `dimmedPlaceOpacity`.
    static let dimmedFolderOpacity: Double = 0.4

    /// The opacity the current place's row is drawn at (`sourceRow`'s). Favorites' places count as
    /// well as Locations': a favourited cloud account or disk dims in Favorites, so its lens must
    /// find it there.
    var currentSourceOpacity: Double {
        (shortcutRows + locationRows).first { $0.id == currentSourceId }?.isDimmed == true
            ? Self.dimmedPlaceOpacity : 1
    }

    /// The opacity the current folder's row is drawn at (`row(for:)`'s).
    var currentFolderOpacity: Double {
        let current = folderRows.first { $0.relativePath == currentRelativePath && $0.root == currentRoot }
        return current.map { FolderSidebarModel.canOpen($0) ? 1 : Self.dimmedFolderOpacity } ?? 1
    }

    /// A folder row's lens identity: the same two fields `row(for:)` compares to decide "current".
    static func folderLensID(root: String, relativePath: String) -> String {
        root + "\u{0}" + relativePath
    }

    /// A place row's mark, at the ambient text scale.
    ///
    /// Routed through `ScaledFont.pointSize(scale:)`, not multiplied: the app's text scaling is
    /// knee-shaped (full boost at small sizes, halved above), so a linearly scaled mark would drift
    /// from the 13pt label beside it at exactly the sizes someone changes the setting for.
    nonisolated static func markSize(scale: CGFloat) -> CGFloat {
        ScaledFont.system(size: 16).pointSize(scale: scale)
    }

    /// The column's width bounds; the user drags the width between them, so they decide how much
    /// of a long name and account they want to pay for. Snapshots and render tests use
    /// ``defaultWidth``, so the suite measures one width whatever a user has dragged.
    public static let defaultWidth: CGFloat = 180
    public static let minWidth: CGFloat = 150
    public static let maxWidth: CGFloat = 280

    /// The three headings, in drawing order. `CaseIterable` so the view and the tests walk one list.
    public enum Section: String, CaseIterable, Sendable, Hashable {
        case favorites = "Favorites"
        /// Finder's word. The raw value is what the collapse preference stores, and
        /// `folderSidebarCollapsedSections` ignores a value it can't map to a case, so a renamed
        /// case costs a stored fold, not a crash.
        case locations = "Locations"
        case recents = "Recents"
    }

    private let folderRows: [FolderSidebarRow]
    /// A section below Favorites, from the host: one-way sync's Syncs, in Compare only.
    private let syncs: AnyView?
    /// Whose cloud app isn't syncing: an amber dot beside the source.
    @ObservedObject private var cloudApps = CloudAppMonitor.shared
    /// Locations' rows: clouds, devices, Trash.
    private let locationRows: [SidebarSourceRow]
    /// Favorites' place rows: home, Desktop, Documents, Downloads and the startup disk by default,
    /// plus anything else the user put there.
    ///
    /// Named for the `.shortcut` band that puts them in this section; the band comes from the
    /// user's Favorites list, so a cloud account or a mounted disk can be one too.
    private let shortcutRows: [SidebarSourceRow]
    private let currentRoot: String
    private let currentRelativePath: String
    private let currentSourceId: String
    /// The part of the list on screen, for the lenses; see `SelectionLensVisibleRegion`.
    @State private var visibleRows = SelectionLensVisibleRegion()
    private let width: CGFloat
    private let collapsed: Set<Section>
    /// Which list the Recents heading shows. The rows arrive already chosen (`folderRows`); this
    /// decides only what the heading says.
    private let recentsMode: RecentsMode
    private let onCycleRecentsMode: () -> Void
    private let notice: SidebarNotice?
    /// Which pane a click acts on; `nil` where there is only one. See `SidebarTarget`.
    private let target: SidebarTarget?
    /// Opens a folder row in a named pane, whatever the current target: the context menu's verb.
    /// A one-off, so it doesn't move the target: "Open in Right Pane" for one folder says nothing
    /// about the next.
    private let onOpenRowOnSide: (FolderSidebarRow, Bool) -> Void
    /// The same for a Locations row.
    private let onOpenSourceOnSide: (SidebarSourceRow, Bool) -> Void
    private let accent: Color
    private let onOpen: (FolderSidebarRow, Bool) -> Void
    private let onToggleFavorite: (FolderSidebarRow) -> Void
    /// Forget one recent, so the row goes. Only Recents rows offer it (see the context menu).
    private let onForgetRecent: (FolderSidebarRow) -> Void
    private let onOpenSource: (SidebarSourceRow, Bool) -> Void
    private let onToggleSection: (Section) -> Void
    private let onNoticeAction: () -> Void
    /// Point the target pane at the folder a row lives in, rather than at the row.
    private let onShowEnclosingFolder: (FolderSidebarRow) -> Void
    /// Add a place to Favorites, or take it out: the source-row counterpart to `onToggleFavorite`,
    /// which does the same for a remembered folder.
    private let onToggleSourceFavorite: (SidebarSourceRow) -> Void
    /// Take a folder source out of the app.
    ///
    /// Needed most by a source on a volume renamed while SyncCloud was quit: it names a mount point
    /// that won't return and draws dimmed forever, and dimmed means "asleep", so nothing else on the
    /// row says it is dead or offers a way out besides Settings ▸ Sources.
    private let onRemoveSource: (SidebarSourceRow) -> Void
    /// Eject the volume a row sits on: Finder's own verb, on the rows Finder offers it for. An
    /// unmount removes the sources on a detachable volume
    /// (`SettingsManager.removeFolderSources(onVolume:)`), so ejecting also takes the row away.
    private let onEjectSource: (SidebarSourceRow) -> Void
    /// Which rows can be ejected, by mount point, decided by the caller because only it has walked
    /// the mounted volumes.
    ///
    /// Keyed by path, not source id like `removableSourceIds`: a card that isn't a source yet still
    /// draws a row, and Eject is about the hardware.
    private let ejectablePaths: Set<String>
    /// Where an unmount actually forgets the sources: narrower than `ejectablePaths`, and the
    /// difference between a true confirmation and a false one.
    ///
    /// Eject is offered on anything Finder would eject, network shares included, but a share isn't
    /// local, so unmounting it leaves its sources alone, and the dialog must not say otherwise.
    /// Supplied by the caller, which has walked the volumes.
    private let detachablePaths: Set<String>
    /// Which rows Remove is offered on, decided by the caller because it owns the list. Only a
    /// folder source can be removed: a discovered account would still be there
    /// (`SettingsManager.removeFolderSource` ignores its id). Same reason
    /// `canRestoreStandardFavorites` is a parameter.
    private let removableSourceIds: Set<String>
    /// The menu title of a row's door to its provider's own settings, by source id, present only
    /// for rows that have one, so the dictionary is also the capability set. Decided by the caller,
    /// which holds the providers, knows each vendor's door (`CloudProvider.settingsDoor`) and can
    /// ask whether the vendor's app is installed. The title travels with it because each vendor's
    /// door is a different surface (System Settings, an app, the web).
    private let providerSettingsTitles: [String: String]
    /// Open the row's provider-settings door. Only called for ids `providerSettingsTitles` names.
    private let onOpenProviderSettings: (SidebarSourceRow) -> Void
    /// Put `SidebarFavoritePlaces.standard` back. Offered only when one of them is missing.
    private let onRestoreStandardFavorites: () -> Void
    /// Whether Restore has anything to do, decided by the caller because it owns the stored list.
    private let canRestoreStandardFavorites: Bool
    private let onMoveFavorite: (Int, Int) -> Void
    private let onMoveSource: (Int, Int) -> Void
    private let onFavoriteRecent: (FolderSidebarRow, Int) -> Void

    /// Which row is under the pointer mid-drag, and where it would land.
    ///
    /// `@State`, not `@GestureState`, because the drop is handled in `onEnded`, and a
    /// `@GestureState` has already reset by then.
    @State private var drag: DragInFlight?
    /// Each section's measured row midpoints, by row index, collected through `RowMidpoints`.
    @State private var midpoints: [Section: [Int: CGFloat]] = [:]
    /// Each section's own top edge, in the same space. Needed only for a section with no rows to
    /// average against: an empty Favorites, the first-run state, where a drag still has to land.
    @State private var sectionTops: [Section: CGFloat] = [:]
    /// Which heading the pointer is over, so its chevron can be revealed on hover as Finder reveals
    /// Show/Hide.
    @State private var hoveredHeader: Section?
    /// The row action waiting on a confirmation, if any.
    ///
    /// Both of this menu's consequential verbs are confirmed, because neither can be undone: a
    /// removed source loses its id, and with it its name, landing folder and enabled flag, which
    /// re-adding the path doesn't restore. An "Undo" that hands back less than it took is worse
    /// than asking first. (Promoting a shortcut, one file over, is exactly reversible, so it isn't.)
    ///
    /// **One state and one dialog, not two of each.** SwiftUI presents two `confirmationDialog`
    /// modifiers on one view unreliably when both are armed, and here both can be: a right-click on
    /// a second row while the first dialog is up.
    @State private var pendingRowAction: PendingRowAction?
    /// The dialog's title, latched. It is a plain parameter, not part of `presenting:`, so it is
    /// re-read on every render, including during the dismissal animation, when the action is
    /// already nil and a derived title would flash an empty heading. `arm(_:)` sets both together.
    @State private var pendingRowTitle = ""

    /// A consequential verb the user asked for but hasn't confirmed.
    ///
    /// Carries the row, not an id: the dialog names the place, and re-resolving by id at confirm
    /// time could disagree with the row the menu was opened on.
    enum PendingRowAction: Equatable {
        case removeSource(SidebarSourceRow)
        /// Whether confirming also costs the source: true only when SyncCloud holds the volume as
        /// one and unmounting it is the kind that forgets. Named for the consequence, not the row's
        /// status, because a network share can be a source and stay one through an eject.
        case eject(SidebarSourceRow, losesItsSource: Bool)

        var row: SidebarSourceRow {
            switch self {
            case .removeSource(let row): return row
            case .eject(let row, _): return row
            }
        }

        var title: String {
            switch self {
            case .removeSource: return "Remove this source?"
            case .eject(let row, _): return "Eject \(row.name)?"
            }
        }

        /// What the dialog says. Ejecting reaches past SyncCloud: the volume is unmounted from
        /// macOS and leaves Finder and every other app at once, so the message must say so, not
        /// just mention the source.
        var message: String {
            switch self {
            case .removeSource(let row):
                return "\(row.name) is removed from SyncCloud. The folder itself is not deleted, and you can add it again — but the name you gave the source, where it opens, whether it was switched off, and what you ignored while comparing it are not kept."
            case .eject(let row, let losesItsSource):
                return FolderSidebarView.ejectMessage(row.name, losesItsSource: losesItsSource)
            }
        }

        /// The confirming button's word: the verb the user reached for, restated.
        var verb: String {
            switch self {
            case .removeSource(let row): return "Remove \(row.name)"
            case .eject: return "Eject"
            }
        }

        /// Red only where something can't be got back. Removing a source loses the name, landing
        /// folder and enabled flag, and so does ejecting a card that is one. Ejecting a card that
        /// isn't costs only the mount, and dressing that as destructive would empty the colour.
        var isDestructive: Bool {
            switch self {
            case .removeSource: return true
            case .eject(_, let losesItsSource): return losesItsSource
            }
        }
    }
    /// The ambient text scale, so a mark is sized by the same curve as the label beside it.
    @Environment(\.appFontScale) private var fontScale

    /// One row's measured midpoint, collected per section so the insertion index uses real geometry,
    /// not an assumed row height: a favorite carrying its parent draws a second line.
    ///
    /// **Keyed by the row's own index, never appended in collection order.** A `PreferenceKey`
    /// reduces in child order, and the `zIndex` the lifted row sets to draw over its neighbours
    /// changes that order, which would scramble an appended list.
    private struct RowMidpoints: PreferenceKey {
        static var defaultValue: [Section: [Int: CGFloat]] { [:] }
        static func reduce(value: inout [Section: [Int: CGFloat]],
                           nextValue: () -> [Section: [Int: CGFloat]]) {
            for (section, mids) in nextValue() { value[section, default: [:]].merge(mids) { a, _ in a } }
        }
    }

    /// Where each section's rows begin, in `dragSpace`. Reported by `reorderable`, not by a row,
    /// because it exists for the section that has no rows.
    private struct SectionTops: PreferenceKey {
        static var defaultValue: [Section: CGFloat] { [:] }
        static func reduce(value: inout [Section: CGFloat], nextValue: () -> [Section: CGFloat]) {
            value.merge(nextValue()) { a, b in min(a, b) }
        }
    }

    /// A drag in progress: which section, which row index, and the insertion index it currently
    /// points at.
    struct DragInFlight: Equatable {
        let section: Section
        let from: Int
        var to: Int
        /// How far the pointer has moved, so the lifted row can follow it.
        var translation: CGFloat
        /// Whether releasing now commits. Always true for a within-section reorder (`isNoOp`
        /// covers doing nothing), but a recent dragged becomes a favorite, a persisted change, so
        /// it arms only once the pointer reaches the Favorites band. Otherwise any ≥5pt slip on a
        /// recent, a sloppy trackpad click, would favorite the row, even released back where it
        /// started. Releasing anywhere below Favorites cancels, as the hidden insertion line says.
        var willDrop: Bool = true
    }

    public init(folderRows: [FolderSidebarRow],
                locationRows: [SidebarSourceRow],
                shortcutRows: [SidebarSourceRow] = [],
                currentRoot: String,
                currentRelativePath: String,
                currentSourceId: String,
                width: CGFloat = FolderSidebarView.defaultWidth,
                collapsed: Set<Section> = [],
                recentsMode: RecentsMode = .recents,
                onCycleRecentsMode: @escaping () -> Void = {},
                notice: SidebarNotice? = nil,
                target: SidebarTarget? = nil,
                onOpenRowOnSide: @escaping (FolderSidebarRow, Bool) -> Void = { _, _ in },
                onOpenSourceOnSide: @escaping (SidebarSourceRow, Bool) -> Void = { _, _ in },
                accent: Color,
                onOpen: @escaping (FolderSidebarRow, Bool) -> Void,
                onToggleFavorite: @escaping (FolderSidebarRow) -> Void,
                onOpenSource: @escaping (SidebarSourceRow, Bool) -> Void,
                onToggleSection: @escaping (Section) -> Void,
                onNoticeAction: @escaping () -> Void = {},
                onShowEnclosingFolder: @escaping (FolderSidebarRow) -> Void = { _ in },
                onToggleSourceFavorite: @escaping (SidebarSourceRow) -> Void = { _ in },
                onRemoveSource: @escaping (SidebarSourceRow) -> Void = { _ in },
                removableSourceIds: Set<String> = [],
                onEjectSource: @escaping (SidebarSourceRow) -> Void = { _ in },
                ejectablePaths: Set<String> = [],
                detachablePaths: Set<String> = [],
                providerSettingsTitles: [String: String] = [:],
                onOpenProviderSettings: @escaping (SidebarSourceRow) -> Void = { _ in },
                onRestoreStandardFavorites: @escaping () -> Void = {},
                canRestoreStandardFavorites: Bool = false,
                onMoveFavorite: @escaping (Int, Int) -> Void = { _, _ in },
                onMoveSource: @escaping (Int, Int) -> Void = { _, _ in },
                onFavoriteRecent: @escaping (FolderSidebarRow, Int) -> Void = { _, _ in },
                onForgetRecent: @escaping (FolderSidebarRow) -> Void = { _ in },
                syncs: AnyView? = nil) {
        self.syncs = syncs
        self.folderRows = folderRows
        self.locationRows = locationRows
        self.shortcutRows = shortcutRows
        self.currentRoot = currentRoot
        self.currentRelativePath = currentRelativePath
        self.currentSourceId = currentSourceId
        self.width = width
        self.collapsed = collapsed
        self.recentsMode = recentsMode
        self.onCycleRecentsMode = onCycleRecentsMode
        self.notice = notice
        self.target = target
        self.onOpenRowOnSide = onOpenRowOnSide
        self.onOpenSourceOnSide = onOpenSourceOnSide
        self.accent = accent
        self.onOpen = onOpen
        self.onToggleFavorite = onToggleFavorite
        self.onOpenSource = onOpenSource
        self.onToggleSection = onToggleSection
        self.onNoticeAction = onNoticeAction
        self.onShowEnclosingFolder = onShowEnclosingFolder
        self.onToggleSourceFavorite = onToggleSourceFavorite
        self.onRemoveSource = onRemoveSource
        self.removableSourceIds = removableSourceIds
        self.onEjectSource = onEjectSource
        self.ejectablePaths = ejectablePaths
        self.detachablePaths = detachablePaths
        self.providerSettingsTitles = providerSettingsTitles
        self.onOpenProviderSettings = onOpenProviderSettings
        self.onRestoreStandardFavorites = onRestoreStandardFavorites
        self.canRestoreStandardFavorites = canRestoreStandardFavorites
        self.onMoveFavorite = onMoveFavorite
        self.onMoveSource = onMoveSource
        self.onFavoriteRecent = onFavoriteRecent
        self.onForgetRecent = onForgetRecent
    }

    /// A drag preset into the view, so the insertion indicator can be rendered in a test.
    ///
    /// `DragGesture` needs a real event stream, which a test process lacks, so without this nothing
    /// could check that the indicator sits in the gap and section it names. Internal, and nothing
    /// in the app calls it.
    func withDragInFlight(_ inFlight: DragInFlight) -> Self {
        var copy = self
        copy._drag = State(initialValue: inFlight)
        return copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                // 14pt between sections, 2pt between rows. Finder separates groups by roughly a
                // row's height and rows by nothing, so a heading reads as one without a rule.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Section.allCases, id: \.self) { section in
                        // A section with nothing in it is not drawn, except Favorites, which draws
                        // its invitation: an empty Favorites is the first-run state, and the help
                        // is saying how it fills. Locations is never empty (there is always a
                        // source, and the local shortcuts are always listed), and Recents is
                        // absent until you have been somewhere, unless it shows Revisited or
                        // Frequent, whose heading is the only way back to the full list.
                        if section == .favorites || (section == .recents && recentsMode != .recents)
                            || !isEmpty(section) {
                            sectionView(section)
                        }
                        // Syncs sits right below Favorites, which is always drawn, so it never
                        // moves with the sections below.
                        if section == .favorites, let syncs { syncs }
                    }
                }
                .padding(.vertical, 10)
                // Frosted and Clear: the current place and the current folder each as a glass lens
                // gliding between rows. Two, because a place and a folder inside it can both be
                // current. Hosted on the padded stack, the scroll view's content, so `visibleRows`
                // is in the lenses' own coordinates.
                .selectionLensHost(Self.sourceLensChannel, selected: currentSourceId,
                                   style: Self.lensStyle(accent, dimmed: currentSourceOpacity),
                                   visibleRegion: visibleRows)
                .selectionLensHost(Self.folderLensChannel,
                                   selected: Self.folderLensID(root: currentRoot, relativePath: currentRelativePath),
                                   style: Self.lensStyle(accent, dimmed: currentFolderOpacity),
                                   visibleRegion: visibleRows)
                .coordinateSpace(name: Self.dragSpace)
                // **The insertion line is drawn here, on the view that names the drag space**, not
                // inside the section it points into. Every midpoint is measured in `dragSpace`, so
                // `insertionY` returns a `dragSpace` y; a section's overlay offset by it would land
                // off by that section's own origin, several rows low for Locations. Drawing in the
                // space the numbers were taken in rules that out, with no second measurement to
                // drift.
                .overlay(alignment: .top) {
                    // Nothing is drawn into a folded section: a recent dragged while Favorites is
                    // collapsed still drops (the folder becomes a favorite), but there are no rows
                    // or top to aim at, and `insertionY`'s last fallback would put the caret at the
                    // top of the column, by the wrong heading.
                    // Nor for an unarmed recents drag: the line promises that releasing commits,
                    // and below the Favorites band releasing cancels.
                    if let drag, drag.willDrop, !collapsed.contains(dropTarget(for: drag.section)),
                       let y = insertionY(for: drag, in: dropTarget(for: drag.section)) {
                        insertionIndicator
                            .offset(y: y - Self.insertionIndicatorHeight / 2)
                    }
                }
                // Assigned, not merged: `reduce` merges by row index so the ladder can't grow, but
                // a section that loses rows must lose their entries too, and only a wholesale
                // assignment does that.
                .onPreferenceChange(RowMidpoints.self) { midpoints = $0 }
                .onPreferenceChange(SectionTops.self) { sectionTops = $0 }
            }
            .scrollContentBackground(.hidden)
            // Written straight into the region, not into `@State`: a state write here would
            // re-render this whole view on every scroll frame, for a value the lenses read once per
            // change of current row.
            .selectionLensTracksVisibleRegion(visibleRows)
            if let notice { noticeView(notice) }
            if let target { targetFooter(target) }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        // One dialog for the whole column, not one per row. `sourceRow` is a function, not a
        // view, so a per-row presenter would have nowhere to keep its state, and a `@State` on a
        // struct rebuilt per row is the classic way to present against a stale row.
        .confirmationDialog(pendingRowTitle,
                            isPresented: Binding(get: { pendingRowAction != nil },
                                                 set: { if !$0 { pendingRowAction = nil } }),
                            presenting: pendingRowAction) { action in
            Button(action.verb, role: action.isDestructive ? .destructive : nil) {
                switch action {
                case .removeSource(let row): onRemoveSource(row)
                case .eject(let row, _): onEjectSource(row)
                }
                pendingRowAction = nil
            }
            Button("Cancel", role: .cancel) { pendingRowAction = nil }
        } message: { action in
            Text(action.message)
        }
    }

    /// Which pane a click lands in, said out loud. Pinned below the scroll area so it can't be
    /// scrolled away, because it describes every row, not the rows in view.
    ///
    /// At the foot, not the head: above the first row it would push Favorites down in Compare
    /// alone, out of line with the other workspaces' sidebars, which start at Favorites.
    ///
    /// A statement, not a control: the side is set by clicking the pane and shown by its accent
    /// border, and a second setter here would compete with the pane for a value that also governs
    /// the action bar and the lens scans. It says the side ("Opens on Left/Right",
    /// `SidebarTarget.openingDescription`), never a source; `SidebarTarget` says why.
    private func targetFooter(_ target: SidebarTarget) -> some View {
        HStack(spacing: 4) {
            Image(systemName: SidebarTarget.symbol(targetsRight: target.targetsRight))
                .scaledFont(.system(size: 9))
            Text(target.openingDescription)
                .scaledFont(.system(size: 10))
                // `.tail`, not the default: a head-truncated name reads as a different source.
                .truncationMode(.tail)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .overlay(alignment: .top) { Divider() }
    }

    /// Arms a confirmation. One door, so the latched title can't be set without the action it
    /// belongs to; that drift is the risk of a second `@State`, and the only reason it isn't derived.
    private func arm(_ action: PendingRowAction) {
        pendingRowTitle = action.title
        pendingRowAction = action
    }

    /// Pinned to the bottom, outside the `ScrollView`, so it can't be scrolled away: it must stay
    /// reachable for as long as it is true.
    private func noticeView(_ notice: SidebarNotice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text(notice.message)
                .scaledFont(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(notice.actionTitle) { onNoticeAction() }
                .buttonStyle(.link)
                .scaledFont(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .padding(.top, 2)
    }

    private func isEmpty(_ section: Section) -> Bool { count(section) == 0 }

    /// How many rows are behind a collapsed heading. Shown only while collapsed: a closed section
    /// that says nothing about its size reads as empty.
    ///
    /// Favorites draws two lists, places and remembered folders, and counts both
    /// (`FolderSidebarModel.favoritesCount`), or the first-run column folds to a `0` over three
    /// rows. `isEmpty` asks through here rather than repeating the rule.
    private func count(_ section: Section) -> Int {
        switch section {
        case .favorites:
            return FolderSidebarModel.favoritesCount(folderRows: folderRows, places: shortcutRows.count)
        case .locations: return locationRows.count
        case .recents: return FolderSidebarModel.rows(folderRows, in: .recents).count
        }
    }

    @ViewBuilder
    private func sectionView(_ section: Section) -> some View {
        let isCollapsed = collapsed.contains(section)
        VStack(alignment: .leading, spacing: 2) {
            header(section, isCollapsed: isCollapsed)
            if !isCollapsed {
                switch section {
                case .favorites:
                    let rows = FolderSidebarModel.rows(folderRows, in: .pinned)
                    // The drop zone is the section, not each row: an empty Favorites, the
                    // first-run case, must still accept a recent dragged into it.
                    reorderable(.favorites) {
                        // The standard places sit above the curated ones, as Finder puts its
                        // defaults first: they are the rows reached for without being chosen, and
                        // a curated favorite is the more specific half.
                        ForEach(Array(shortcutRows.enumerated()), id: \.element.id) { index, source in
                            draggableRow(section: .favorites, index: index) { sourceRow(for: source) }
                        }
                        if rows.isEmpty && shortcutRows.isEmpty { emptyFavorites }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            draggableRow(section: .favorites, index: shortcutRows.count + index) {
                                self.row(for: row)
                            }
                        }
                    }
                case .locations:
                    locationsBody
                case .recents:
                    let rows = FolderSidebarModel.rows(folderRows, in: .recents)
                    if rows.isEmpty, let line = Self.emptyLine(recentsMode) { emptyStayed(line) }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        // Recents don't reorder: their order is "when you were there", and a
                        // hand-placed one would contradict the timestamps. A recent can still be
                        // dragged out, into Favorites.
                        draggableRow(section: .recents, index: index) { self.row(for: row) }
                    }
                }
            }
        }
    }

    /// What a heading says: its section's name, except Recents, which names its mode.
    func title(_ section: Section) -> String {
        section == .recents ? recentsMode.rawValue : section.rawValue
    }

    /// The heading, which is also the collapse control: the whole row, not just the chevron, so a
    /// 10pt triangle isn't the hit area for a control someone uses to make room.
    ///
    /// **The fold is a full-width button under the heading's text, not around it**, because Recents
    /// carries a second control: a button inside another button's label leaves which one a click
    /// reaches to the platform, and VoiceOver reads only the outer one. Side by side, the text and
    /// chevron pass their clicks through to the fold, and the glyph keeps its own.
    private func header(_ section: Section, isCollapsed: Bool) -> some View {
        let hovered = hoveredHeader == section
        return ZStack {
            Button { onToggleSection(section) } label: {
                Color.clear
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title(section)), \(isCollapsed ? "collapsed" : "expanded"), \(count(section) == 1 ? "1 item" : "\(count(section).formatted()) items")")
            .help(isCollapsed ? "Show \(title(section))" : "Hide \(title(section))")
            HStack(spacing: 4) {
                Text(title(section))
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                    .allowsHitTesting(false)
                // Revealed on hover like the chevron, and kept while a filter is on, in the accent,
                // so a remembered mode never passes for plain Recents.
                if section == .recents, hovered || recentsMode != .recents { recentsModeButton }
                // The chevron appears on hover and the count while folded, as Finder reveals
                // Show/Hide rather than keeping it on screen. So the heading text starts at a row
                // icon's inset, giving the column one left edge, and a folded section still says
                // how much is behind it, so it doesn't read as empty.
                Group {
                    if hovered {
                        Image(systemName: "chevron.right")
                            .scaledFont(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .foregroundStyle(.tertiary)
                    } else if isCollapsed {
                        Text("\(count(section))")
                            .scaledFont(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(height: 16)
        .padding(.horizontal, 10)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .onHover { hoveredHeader = $0 ? section : (hoveredHeader == section ? nil : hoveredHeader) }
        // The way back from removing a standard place, so Remove isn't a one-way door. Desktop
        // taken out of Favorites has nowhere else to appear, and adding `~/Desktop` as a folder
        // source is a different thing that only looks similar. (Home and the startup disk fall
        // back to Locations as device rows; the three in `favoriteShortcuts` don't.) On the
        // heading, because the rows it restores aren't there to be right-clicked.
        //
        // Shown only when something is missing: an item that does nothing would sit on the
        // heading forever.
        .contextMenu {
            if section == .favorites, canRestoreStandardFavorites {
                Button("Restore Standard Places") { onRestoreStandardFavorites() }
            }
        }
    }

    /// The icon that cycles Recents → Revisited → Frequent: dim and on hover only in Recents; a
    /// repeat glyph in Revisited and a bars glyph in Frequent, both in the accent and always shown.
    /// VoiceOver hears the mode it is in and the one a click moves to.
    private var recentsModeButton: some View {
        Button { onCycleRecentsMode() } label: {
            Image(systemName: Self.modeSymbol(recentsMode))
                .scaledFont(.system(size: 9, weight: .bold))
                .foregroundStyle(recentsMode == .recents ? AnyShapeStyle(.tertiary) : AnyShapeStyle(accent))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.modeHelp(recentsMode))
        .accessibilityLabel(Self.modeAccessibilityLabel(recentsMode))
    }

    static func modeSymbol(_ mode: RecentsMode) -> String {
        mode == .frequent ? "chart.bar" : "repeat"
    }

    static func modeHelp(_ mode: RecentsMode) -> String {
        switch mode {
        case .recents: return "Show only folders you came back to"
        case .revisited: return "Show the folders you use most"
        case .frequent: return "Show all recents"
        }
    }

    /// The context-menu item that forgets a recent, named for the list the heading shows.
    static func forgetItemTitle(_ mode: RecentsMode) -> String {
        "Remove from \(mode.rawValue)"
    }

    static func modeAccessibilityLabel(_ mode: RecentsMode) -> String {
        "Showing \(mode.rawValue). Switch to \(mode.next.rawValue)"
    }

    /// What an empty Revisited or Frequent says. Both start empty, since folders remembered before
    /// them have no stays, so the line says how each fills, as `emptyFavorites` does. Plain Recents
    /// is simply not drawn when empty.
    static func emptyLine(_ mode: RecentsMode) -> String? {
        switch mode {
        case .recents: return nil
        case .revisited: return "No repeat visits yet. A folder shows here once you’ve opened it on two different days."
        case .frequent: return "Nothing frequent yet. A folder shows here once you’ve spent time in it a few times."
        }
    }

    private func emptyStayed(_ line: String) -> some View {
        Text(line)
            .scaledFont(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
    }

    /// Not "no folders": an empty Favorites is the first-run state, and the sentence that helps says
    /// how it fills.
    private var emptyFavorites: some View {
        Text("Folders you add to Favorites stay here.")
            .scaledFont(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
    }

    /// Locations: the clouds you signed into, a rule, then the hardware and the Trash.
    ///
    /// One section with one rule inside it, not separate headings: the glyphs already say which
    /// kind a row is, and another heading would push Recents below the fold on a short window. The
    /// rule marks the one difference worth a line, an account against something you can unplug;
    /// the devices and the Trash are both hardware-side and stay together.
    @ViewBuilder
    private var locationsBody: some View {
        let clouds = locationRows.filter { $0.band == .cloud }
        let devices = locationRows.filter { $0.band != .cloud }
        reorderable(.locations) {
            ForEach(Array(clouds.enumerated()), id: \.element.id) { index, source in
                draggableRow(section: .locations, index: index) { sourceRow(for: source) }
            }
            if !clouds.isEmpty && !devices.isEmpty {
                Divider()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            ForEach(Array(devices.enumerated()), id: \.element.id) { index, source in
                // Indices continue across the rule, because it is a visual break inside one
                // section and the stored order is one sequence. Device rows don't drag, though:
                // their half is drawn home-first then volumes by name, never from the stored
                // order, so no device reorder could ever render (see `draggableRow`'s `draggable:`).
                draggableRow(section: .locations, index: clouds.count + index, draggable: false) {
                    sourceRow(for: source)
                }
            }
        }
    }

    /// A section that accepts a drag. It groups the rows and reports where the group starts; the
    /// insertion line is drawn by `body`, in the space the midpoints are measured in (see the
    /// overlay there for why not from in here).
    @ViewBuilder
    private func reorderable<Content: View>(_ section: Section,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) { content() }
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: SectionTops.self,
                                           value: [section: geo.frame(in: .named(Self.dragSpace)).minY])
                }
            }
    }

    /// Where the row would land, drawn as an insertion point rather than a rule.
    ///
    /// A full-bleed bar would look like the divider Locations draws between clouds and disks, and
    /// read as another separator. The ring at the leading end makes it an insertion caret, the shape
    /// AppKit's outline views use, and the 10pt inset lines it up with a row's glyph, so it sits in
    /// the rows' column instead of running edge to edge like a section break.
    private var insertionIndicator: some View {
        HStack(spacing: 2) {
            Circle()
                .strokeBorder(accent, lineWidth: 2)
                .frame(width: Self.insertionIndicatorHeight, height: Self.insertionIndicatorHeight)
            Capsule(style: .continuous)
                .fill(accent)
                .frame(height: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        // The caret claims a gap, so centre the mark on the gap rather than hanging it below, or
        // it reads as belonging to the row under it. `body` subtracts half of this from the offset.
        .allowsHitTesting(false)
    }

    /// The caret's diameter, and so the height the indicator is centred by.
    private static let insertionIndicatorHeight: CGFloat = 7

    /// Keeps a Locations drop inside the band it started in, and leaves every other section's drop
    /// alone.
    ///
    /// Locations is grouped (clouds, a rule, then devices and the Trash) when the rows are built,
    /// by each row's band, in `splitFolderSidebarPlaceRows`, and the stored order can't override
    /// it. A row released past the rule would snap back while the insertion line promised the
    /// landing, so the drop is clamped: the row goes as far as its band allows, which is what
    /// happens.
    private func clampedDrop(_ to: Int, section: Section, from: Int) -> Int {
        switch dropTarget(for: section) {
        case .locations:
            guard locationRows.indices.contains(from) else { return to }
            let cloudCount = locationRows.filter { $0.band == .cloud }.count
            return locationRows[from].band == .cloud
                ? SidebarReorder.clampedToBand(to, bandStart: 0, bandEnd: cloudCount)
                : SidebarReorder.clampedToBand(to, bandStart: cloudCount, bandEnd: locationRows.count)
        case .favorites:
            // Favorites is two lists drawn as one, places then remembered folders, kept in
            // different stores: a place is a root, a remembered folder a path inside one. A row
            // crossing the boundary has nowhere to land, so it stops there, like the Locations
            // bands above.
            let places = shortcutRows.count
            let folders = FolderSidebarModel.rows(folderRows, in: .pinned).count
            // A recent dragged OUT of Recents becomes a remembered folder, so it lands in the
            // second half whatever gap the pointer is over.
            guard section == .favorites else {
                return SidebarReorder.clampedToBand(to, bandStart: places, bandEnd: places + folders)
            }
            return from < places
                ? SidebarReorder.clampedToBand(to, bandStart: 0, bandEnd: places)
                : SidebarReorder.clampedToBand(to, bandStart: places, bandEnd: places + folders)
        case .recents:
            return to
        }
    }

    /// A section's midpoints in row order, which the insertion index and the line are computed
    /// against. Read through here, not off `midpoints`: it is keyed by index because the
    /// collection order can't be trusted.
    private func orderedMidpoints(_ section: Section) -> [CGFloat] {
        (midpoints[section] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
    }

    /// Where the insertion line sits, from this section's midpoints: a `dragSpace` y, the space the
    /// midpoints were measured in and `body` draws it in.
    private func insertionY(for drag: DragInFlight, in section: Section) -> CGFloat? {
        // A section with no rows must still answer, and its own top is the honest answer: an empty
        // Favorites taking its first recent. Zero would put the line at the top of the column.
        let mids = orderedMidpoints(section)
        guard !mids.isEmpty else { return sectionTops[section] ?? 0 }
        let index = min(max(drag.to, 0), mids.count)
        if index == 0 { return max(mids[0] - rowHalfHeight(mids), 0) }
        if index >= mids.count { return mids[mids.count - 1] + rowHalfHeight(mids) }
        return (mids[index - 1] + mids[index]) / 2
    }

    /// Half a row, from the measured pitch, for the line above the first row and below the last,
    /// where there is no neighbouring midpoint to average against.
    private func rowHalfHeight(_ mids: [CGFloat]) -> CGFloat {
        guard mids.count > 1 else { return 11 }
        return (mids[1] - mids[0]) / 2
    }

    /// Which section a drag would drop into. A favorite or a source stays in its own section; a
    /// recent can land in Favorites, which is how a folder is added by drag.
    private func dropTarget(for section: Section) -> Section {
        section == .recents ? .favorites : section
    }

    /// One row, wrapped so it reports its midpoint and can be picked up.
    /// - Parameter draggable: pass false for a row that reports its midpoint but can't be picked up:
    ///   the device rows, drawn home-first then volumes by name, never from the stored order. A
    ///   lifted device row would draw an insertion line whose drop always snaps back, and with two
    ///   provider-backed device rows would silently rewrite the persisted provider order.
    @ViewBuilder
    private func draggableRow<Content: View>(section: Section, index: Int, draggable: Bool = true,
                                             @ViewBuilder content: () -> Content) -> some View {
        let isLifted = drag?.section == section && drag?.from == index
        content()
            // The lifted row gets an opaque ground of its own and a shadow. It follows the pointer
            // over the rows it passes, and a translucent row over another composites into two names
            // overlapping, unreadable; opaque with a shadow reads as one row picked up over the
            // column. No fade either: even at 0.9 the row beneath ghosts through.
            .background {
                if isLifted {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.30), radius: 6, y: 2)
                }
            }
            // Under a lens the current row's wash is the lens, drawn behind the column, so under
            // this opaque ground once lifted. A lifted row draws its own (`CurrentRowWash`).
            .environment(\.folderSidebarRowLifted, isLifted)
            .offset(y: isLifted ? (drag?.translation ?? 0) : 0)

            // Measured outside the offset, so the row reports the slot it came from, not where the
            // pointer has dragged it. A midpoint that moved with the pointer would make the
            // insertion index flicker by one exactly where the user aims most carefully.
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: RowMidpoints.self,
                                           value: [section: [index: geo.frame(in: .named(Self.dragSpace)).midY]])
                }
            }
            .zIndex(isLifted ? 1 : 0)
            // `simultaneousGesture` with a real minimum distance, so a click still opens the
            // folder: the row is a `Button`, a plain `.gesture` would swallow the tap, and a zero
            // minimum would turn every click into a one-pixel drag.
            .simultaneousGesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.dragSpace))
                    .onChanged { value in
                        let raw = SidebarReorder.insertionIndex(
                            forY: value.location.y,
                            midpoints: orderedMidpoints(dropTarget(for: section)))
                        // A recents drag arms only above the Locations band, once the pointer is
                        // really over Favorites (`DragInFlight.willDrop`). Locations always draws,
                        // so its top is a boundary that exists. `.infinity` keeps an unmeasured
                        // column armed rather than dead.
                        let willDrop = section != .recents
                            || value.location.y < (sectionTops[.locations] ?? .infinity)
                        drag = DragInFlight(section: section, from: index,
                                            to: clampedDrop(raw, section: section, from: index),
                                            translation: value.translation.height,
                                            willDrop: willDrop)
                    }
                    .onEnded { _ in
                        defer { drag = nil }
                        guard let inFlight = drag else { return }
                        switch inFlight.section {
                        case .favorites:
                            guard !SidebarReorder.isNoOp(from: inFlight.from, to: inFlight.to) else { return }
                            onMoveFavorite(inFlight.from, inFlight.to)
                        case .locations:
                            guard !SidebarReorder.isNoOp(from: inFlight.from, to: inFlight.to) else { return }
                            onMoveSource(inFlight.from, inFlight.to)
                        case .recents:
                            // An unarmed release is a cancel: the pointer never reached Favorites,
                            // so committing would persist a change the hidden insertion line never
                            // promised.
                            guard inFlight.willDrop else { return }
                            let recents = FolderSidebarModel.rows(folderRows, in: .recents)
                            guard recents.indices.contains(inFlight.from) else { return }
                            onFavoriteRecent(recents[inFlight.from], inFlight.to)
                        }
                    },
                    including: draggable ? .all : .subviews)
    }

    // MARK: - Rows

    private func sourceRow(for source: SidebarSourceRow) -> some View {
        let isCurrent = source.id == currentSourceId
        return Button {
            // Opening a source is asking about it, so its cloud app is checked at once.
            cloudApps.checkNow([source.id])
            onOpenSource(source, FolderSidebarModel.opensInNewTab(NSEvent.modifierFlags))
        } label: {
            HStack(spacing: 6) {
                // The provider's own mark, in one ink. A uniform `cloud` would leave the name to say
                // which account a row is, and names collide. `ProviderLogo` is the one place a mark
                // is drawn, and its monochrome mode keeps each silhouette (the transparent details
                // survive a template render) without five brand colours down a quiet column. Finder
                // draws its Locations in one ink too.
                //
                // Sized through the label's knee curve, not a fixed 16, or the mark would shrink
                // against the text at every size above the default.
                ProviderLogo(source.symbol, size: Self.markSize(scale: fontScale), monochrome: true)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                Text(source.name)
                    .scaledFont(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = source.detail {
                    Text(detail)
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        // Tail, unlike the folder row's detail below: that is a parent path, whose
                        // deep end is the informative one. This is a qualifier (an account name,
                        // "in iCloud Drive"), and "…iCloud Drive" would read as a cut path.
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
                if let problem = cloudApps.problems[source.id] {
                    // Below the detail's -1: in a narrow column the status words go before the
                    // account qualifier, and both before the name.
                    CloudAppStatusDot(problem)
                        .layoutPriority(-2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: Self.rowHeight)
            .background {
                if isCurrent { CurrentRowWash(accent: accent) }
            }
            .selectionLensStop(Self.sourceLensChannel, id: source.id)
            .contentShape(Rectangle())
            // Drawn, not left to `.disabled`, which under `hoverAffordance` dims nothing. A source
            // that isn't answering and a local folder that isn't a source yet dim alike on purpose:
            // both mean "this row can't show you anything right now".
            .opacity(source.isDimmed ? Self.dimmedPlaceOpacity : 1)
        }
        .buttonStyle(.hoverAffordance(.row, tint: accent))
        .disabled(!source.isAvailable)
        .help(sourceTooltip(source))
        .accessibilityLabel(sourceAccessibilityLabel(source))
        .contextMenu {
            // Not for the Trash: it is `revealOnly`, opened in Finder and never a pane's scope, so
            // opening it in a pane would name an action that can't happen.
            if source.state != .revealOnly {
                sideItems(enabled: source.isAvailable) { onOpenSourceOnSide(source, $0) }
                Button("Open in New Tab") { onOpenSource(source, true) }
                    .disabled(!source.isAvailable)
            }
            // The same verb a remembered folder gets, so places can be put in Favorites or taken
            // out too. `favoriteVerb` returns nil only for the Trash.
            if let verb = SidebarSourceModel.favoriteVerb(for: source) {
                Divider()
                Button(verb) { onToggleSourceFavorite(source) }
            }
            // The provider's own settings, where it has any. Between the toggles and the
            // consequential verbs: it changes nothing in SyncCloud, so it isn't in the confirmed
            // tail, but it leaves the app, so it isn't with the openers either. Not gated on
            // `isAvailable`: a row dims when its folder isn't answering, and the vendor's settings
            // are where a person goes to find out why.
            if let title = providerSettingsTitles[source.id] {
                Divider()
                Button(title) { onOpenProviderSettings(source) }
            }
            // Above Remove, as the commoner verb: a card is ejected every time someone finishes
            // with it; a source is removed once, if ever.
            if ejectablePaths.contains(FolderSidebarView.mountKey(source.absolutePath)) {
                Divider()
                Button("Eject \(source.name)…") {
                    // Both halves, or the dialog lies: SyncCloud must hold this folder as a source,
                    // and the unmount must be one that forgets it, which a network share's isn't.
                    let key = FolderSidebarView.mountKey(source.absolutePath)
                    arm(.eject(source, losesItsSource: removableSourceIds.contains(source.id)
                                                       && detachablePaths.contains(key)))
                }
                .disabled(!source.isAvailable)
            }
            // Last, behind its own rule: the one item that changes what the app holds rather than
            // what it shows, placed where a mis-aimed click at the toggle above is least likely to
            // land.
            if removableSourceIds.contains(source.id) {
                Divider()
                Button("Remove Source…") { arm(.removeSource(source)) }
            }
        }
    }

    /// What confirming an eject says, here and in Ask Claude's eject, so the two can't disagree
    /// about what an eject costs.
    public static func ejectMessage(_ name: String, losesItsSource: Bool) -> String {
        let system = "\(name) is unmounted from macOS, not just from SyncCloud — it leaves Finder and every other app until you plug it in again. Nothing on it is changed."
        guard losesItsSource else { return system }
        return system + " SyncCloud also stops holding it as a source, so the name you gave it and where it opens are not kept."
    }

    /// The one spelling of a mount point, so `ejectablePaths` and a row's `absolutePath` meet.
    ///
    /// The row carries the path the place was built from, and the caller builds the set from
    /// `FileManager.mountedVolumeURLs`; a trailing slash on either side would part them.
    /// `PathBoundary.normalizedRoot` is the rule `FolderJumpStore` and `MountedVolumeMemory`
    /// already key by, so this reads one rule rather than adding a spelling.
    public static func mountKey(_ path: String) -> String { PathBoundary.normalizedRoot(path) }

    /// The tooltip spells out the row's state, because the row itself only has room to be dimmed or
    /// not.
    private func sourceTooltip(_ source: SidebarSourceRow) -> String {
        guard source.isAvailable else { return "\(source.name) — not available right now" }
        if let problem = cloudApps.problems[source.id] {
            return "\(source.name) — \(problem.shortLabel): \(problem.consequence)"
        }
        switch source.state {
        case .configured: return source.absolutePath
        case .inside(_, let owner): return "\(source.absolutePath) — in \(owner)"
        case .unknown: return "Add \(source.name) as a source and open it"
        case .revealOnly: return "Open \(source.name) in Finder"
        }
    }

    private func sourceAccessibilityLabel(_ source: SidebarSourceRow) -> String {
        var label = "\(source.isFavoriteShortcut ? "Favorite" : "Location"): \(source.name)"
        if let detail = source.detail { label += ", \(detail)" }
        switch source.state {
        case .configured: break
        case .inside(_, let owner): label += ", in \(owner)"
        case .unknown: label += ", not added yet"
        case .revealOnly: label += ", opens in Finder"
        }
        if !source.isAvailable { label += ", not available" }
        if let problem = cloudApps.problems[source.id] { label += ", \(problem.shortLabel): \(problem.consequence)" }
        return label
    }

    private func row(for row: FolderSidebarRow) -> some View {
        let isCurrent = row.relativePath == currentRelativePath && row.root == currentRoot
        let canOpen = FolderSidebarModel.canOpen(row)
        return Button {
            onOpen(row, FolderSidebarModel.opensInNewTab(NSEvent.modifierFlags))
        } label: {
            HStack(spacing: 6) {
                // A folder icon in both groups, and the heading says which list it is. A pin glyph
                // would contradict the "Favorites" heading, and Finder marks its Favourites with the
                // folder icon too. Sharing a glyph loses nothing: `recentPaths` subtracts the
                // favorites, so one folder is never drawn in both.
                Image(systemName: "folder")
                    .scaledFont(.system(size: 13))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name)
                        .scaledFont(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = row.detail {
                        Text(detail)
                            .scaledFont(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
                // The source badge, trailing: it answers "which account", where the detail under
                // the name answers "which folder". A row can need both.
                if let source = row.sourceName {
                    Text(source)
                        .scaledFont(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: Self.rowHeight)
            // The `Spacer` above makes the row the column's full width, and that is load-bearing:
            // a `hoverAffordance` row is clickable only where it paints, so a row sized to its text
            // would be readable across 180pt and clickable across forty.
            // `theCurrentRowFillsTheColumn` keeps it that way.
            .background {
                // The pane's current folder, marked the way a Mac sidebar marks it: weight and a
                // tinted glyph alone are invisible without a neighbour to compare. It also makes the
                // row's real width measurable, which `theCurrentRowFillsTheColumn` relies on.
                if isCurrent { CurrentRowWash(accent: accent) }
            }
            .selectionLensStop(Self.folderLensChannel,
                               id: Self.folderLensID(root: row.root, relativePath: row.relativePath))
            .contentShape(Rectangle())
            // Drawn, not left to `.disabled`, which under `hoverAffordance` dims nothing.
            .opacity(canOpen ? 1 : Self.dimmedFolderOpacity)
        }
        .buttonStyle(.hoverAffordance(.row, tint: accent))
        .disabled(!canOpen)
        .help(canOpen ? tooltip(row) : "\(row.relativePath) — not available right now")
        .accessibilityLabel("\(row.group == .recents ? recentsMode.rawValue : row.group.rawValue): \(row.relativePath)"
                            + (row.sourceName.map { " in \($0)" } ?? "")
                            + (canOpen ? "" : ", not available"))
        .contextMenu {
            sideItems(enabled: canOpen) { onOpenRowOnSide(row, $0) }
            Button("Open in New Tab") { onOpen(row, true) }
                .disabled(!canOpen)
            Button(row.group == .pinned ? "Remove from Favorites" : "Add to Favorites") {
                onToggleFavorite(row)
            }
            // Only on a recent, because only a recent can be forgotten; a favorite's removal is the
            // verb above, and a second would read like a choice that isn't one. Enabled even for an
            // unavailable row, unlike the items above: a source asleep or a folder renamed away is
            // exactly when a stale recent is worth removing.
            // Named for the list the heading shows ("Remove from Frequent"); `forgetRecent` takes
            // the folder off all three lists, so the name is always true.
            if row.group == .recents {
                Button(Self.forgetItemTitle(recentsMode)) { onForgetRecent(row) }
            }
            // "Take me there" and "show me where that is" are different questions: the row answers
            // the first, this the second, asked when a name stops being enough (two `Legal` folders
            // in one account, a recent you no longer recognise). Absent, not disabled, for a row at
            // its source's root, which has no enclosing folder a pane can show, and for an
            // unavailable row, which `enclosingFolder` refuses.
            if FolderSidebarModel.enclosingFolder(of: row) != nil {
                Divider()
                Button("Show in Enclosing Folder") { onShowEnclosingFolder(row) }
            }
        }
    }

    /// "Open in Left Pane" / "Open in Right Pane", and only where there are two.
    ///
    /// The per-row companion to the pane target, which says where every click lands: a mode is
    /// the wrong shape for "this one folder, over there", and flipping it to open one folder and
    /// back is the friction this removes.
    ///
    /// Doesn't move the target: a side for one folder says nothing about the next, and re-aiming
    /// the sidebar from a context menu would be a mode change the user didn't ask for or see.
    ///
    /// Empty outside Compare, where `target` is nil: there is no left or right pane to offer.
    @ViewBuilder
    private func sideItems(enabled: Bool, open: @escaping (Bool) -> Void) -> some View {
        if target != nil {
            Button("Open in Left Pane") { open(true) }.disabled(!enabled)
            Button("Open in Right Pane") { open(false) }.disabled(!enabled)
            Divider()
        }
    }

    /// The whole path, always: the row shows a leaf and sometimes a parent, and the tooltip answers
    /// "which of the two Legals is this" without waiting for a collision.
    private func tooltip(_ row: FolderSidebarRow) -> String {
        row.sourceName.map { "\($0) — \(row.relativePath)" } ?? row.relativePath
    }
}

private struct FolderSidebarRowLiftedKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    /// Whether this row is the one being dragged; see `FolderSidebarView.draggableRow`.
    var folderSidebarRowLifted: Bool {
        get { self[FolderSidebarRowLiftedKey.self] }
        set { self[FolderSidebarRowLiftedKey.self] = newValue }
    }
}

/// The current row's wash: the marker a selection lens carries in Frosted and Clear, except on a
/// lifted row, whose opaque ground hides the lens behind it, so it draws its own, as Solid does.
private struct CurrentRowWash: View {
    let accent: Color
    @Environment(\.folderSidebarRowLifted) private var lifted

    var body: some View {
        if lifted {
            wash
        } else {
            SelectionLensTodayMarker { wash }
        }
    }

    private var wash: some View {
        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
            .fill(accent.opacity(FolderSidebarView.currentWash))
    }
}
