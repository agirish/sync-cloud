import SwiftUI
import AppKit
import Sync
import Design

/// One row of the folder sidebar: a remembered folder, under the heading that remembered it.
public struct FolderSidebarRow: Identifiable, Equatable, Sendable {

    /// Why this folder is listed. The two lists are `FolderJumpStore`'s, unchanged — favorites are
    /// curated, recents are the last eight places visited under this root.
    ///
    /// **The heading reads "Favorites", and the verbs that manage it say "Add to Favorites" /
    /// "Remove from Favorites" — "pin" belongs to tabs.** Decided 2026-08-24. A pinned *tab* is a
    /// shipped, unrelated feature (`PaneTab.isPinned`: it sits at the front, keeps its place when
    /// the strip runs out of room, and survives Close Other Tabs), and this column is drawn
    /// directly beneath that strip. One word for two unrelated things, on two adjacent surfaces,
    /// is worse than two words for two things.
    ///
    /// The case is still `pinned` and the store is still `folderJumpPinnedByRoot`: only the
    /// *displayed* word changed, and nothing persisted is keyed on it. Renaming the case as well
    /// would have been a rename of `FolderJumpStore`'s whole vocabulary for no user-visible gain.
    public enum Group: String, Sendable, CaseIterable {
        case pinned = "Favorites"
        case recents = "Recents"
    }

    public let group: Group
    /// **The provider root this folder is under**, normalised through
    /// `FolderJumpStore.key(forRoot:)`. Both sections span every source since v4.4, so the row can
    /// no longer inherit its root from the column — a click has to know which source to act on.
    public let root: String
    /// The source's display name, for the badge — `iCloud`, `Dropbox`, `Drive · hpe`.
    ///
    /// `nil` when only one source contributes rows, which is the first-run case and the case for
    /// anyone with a single account: a badge repeating the same word down the whole column is noise
    /// that says nothing.
    public let sourceName: String?
    /// The path relative to ``root`` — what the pane is navigated to.
    public let relativePath: String
    /// The folder's own name, which is what the row reads.
    public let name: String
    /// The folders above it, shown **only on a Favorite, and only when another row on screen has
    /// the same name**.
    ///
    /// Two `Legal` folders under different clients is the case that matters, and it is the one the
    /// ⌘K palette had to be rebuilt twice to be able to see: a sidebar that lists them both as
    /// "Legal" offers two rows that are indistinguishable and one of them goes to the wrong place.
    /// Always showing the parent would be the other failure — a 180pt column of two-line rows where
    /// almost every second line is redundant.
    ///
    /// **Always `nil` on a recent, since 2026-08-27.** Recents is the section where the second line
    /// was redundant in practice rather than in theory: a recent's qualifier is its parent, and its
    /// parent is a top-level folder often enough that the line came out reading the same word as
    /// the source badge already on the row's other end — `Documents` over `OneDrive (HPE)` with
    /// `OneDrive (HPE)` beside it, four times down one column. A recent is a place you were minutes
    /// ago and recognise; a favorite is a place you chose once and may not. The whole path is still
    /// in the tooltip, on both.
    public let detail: String?
    /// False when the root did not answer — the whole list is then "everything remembered,
    /// unchecked" (`FolderJumpStore.reachable`), which is a sleeping drive rather than a folder
    /// that has gone.
    public let isAvailable: Bool

    /// **The root is part of the identity.** Two sources can hold the same relative path — a
    /// `Health` under iCloud and a `Health` under Dropbox is the ordinary case, not a corner one —
    /// and a `ForEach` over rows that collided would draw one and drop the other.
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

    /// **What one source contributes to the folder sections** — its favorites, and whether it
    /// answered.
    ///
    /// Recents do not appear here: they arrive as one already-ordered global list
    /// (`FolderJumpStore.mostRecentAcrossRoots`), because ordering them needs every root's entries
    /// at once and a clock. Favorites are per source because their order is the user's own, per
    /// source, and nothing may re-sort it.
    public struct Source: Equatable, Sendable {
        public let root: String
        /// The provider's display name — the badge, and the qualifier a top-level folder borrows.
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

    /// **Every folder row the column draws** — favorites across all sources, then one global
    /// recents list.
    ///
    /// One builder rather than a per-source one plus a merger, so there is a single place that
    /// decides what a row says. That matters most for qualification, which cannot be computed per
    /// source: whether `Legal` needs telling apart depends on what else is *on screen*, and half
    /// the screen belongs to another account.
    ///
    /// Two disambiguators, and they answer different questions:
    ///
    /// - **The badge (``FolderSidebarRow/sourceName``) says which source**, on every row, whenever
    ///   more than one source contributes. With a single source it is `nil` — a badge repeating one
    ///   word down the whole column says nothing.
    /// - **The detail (``FolderSidebarRow/detail``) says which folder**, on a FAVORITE, and only
    ///   when a leaf name collides with another row's. It is the parent path, or the source's name
    ///   for a folder at the top level, which is the convention `StorageLensView.displayFolder`
    ///   already uses. A recent never carries one — the badge is the whole answer there, and the
    ///   second line was reading the badge's own words back at it.
    ///
    /// A favorite can carry both, and the case that needs both is real: a `Clients/Legal` on Drive
    /// beside a top-level `Legal` on iCloud is two rows reading `Legal` from two accounts, where
    /// neither the badge nor the parent alone tells them apart.
    ///
    /// - Parameter recents: already ordered and already capped by the store. Rows for a root that
    ///   is not in `sources` are dropped rather than drawn unavailable — an entry whose whole
    ///   source has been removed is not a sleeping drive, it is a folder the app can no longer say
    ///   anything about.
    /// - Parameter favoriteOrder: the user's dragged sequence, as `FolderJumpStore.favoriteKey`
    ///   keys. **Applied here, or the drag writes an order nothing draws.**
    ///
    ///   `Source.favorites` is per-root and says which folders are *in* the section; the sequence
    ///   is cross-source and says what order they come in, which per-root arrays cannot express at
    ///   all — a drag putting a Dropbox favorite above an iCloud one has no representation there.
    ///   `FolderJumpStore.orderedFavorites` was written for exactly this, thoroughly tested, and
    ///   then read by nobody on the path that builds rows: this builder concatenated the per-root
    ///   lists in source order and stopped. Every folder-favorite drag persisted a sequence, logged
    ///   that it had, and the rows came back in the old order on the next refresh. It is the same
    ///   rule the reorder handler applies, called from the one place that draws.
    public static func rows(sources: [Source], recents: [RememberedVisit],
                            favoriteOrder: [String] = []) -> [FolderSidebarRow] {
        // First-wins on a duplicate root, not `uniqueKeysWithValues:` — that spelling TRAPS, and
        // while `SettingsManager.existingSource` keeps two enabled providers off one root today,
        // a hand-edited plist or a future entry point would turn that guard's gap into a crash on
        // every sidebar refresh. Same spelling as this file's other builders.
        let byRoot = Dictionary(sources.map { ($0.root, $0) }, uniquingKeysWith: { a, _ in a })
        // Only sources that actually contribute a row count toward "is this multi-source" — a
        // second account with nothing remembered in it should not put a badge on every row.
        var contributing = Set(sources.filter { !$0.favorites.isEmpty }.map(\.root))
        contributing.formUnion(recents.compactMap { byRoot[$0.root] != nil ? $0.root : nil })
        let showsBadge = contributing.count > 1

        struct Draft { let group: FolderSidebarRow.Group, root: String, path: String, name: String }
        var drafts: [Draft] = []
        // The base the sequence is applied ON TOP of is the caller's source order — which is the
        // Settings order, the same one Locations uses — so a favorite the sequence has never named
        // (one added since the last drag) sits beside its own account rather than somewhere
        // alphabetical. Only what the sequence names is moved.
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
        for visit in recents where byRoot[visit.root] != nil {
            drafts.append(Draft(group: .recents, root: visit.root, path: visit.relativePath,
                                name: leaf(of: visit.relativePath)))
        }

        // Counted across BOTH groups and every source, because the reader is looking at one column.
        var leafCounts: [String: Int] = [:]
        for draft in drafts { leafCounts[draft.name, default: 0] += 1 }

        return drafts.map { draft in
            let source = byRoot[draft.root]
            let parent = (draft.path as NSString).deletingLastPathComponent
            let qualifier = parent.isEmpty ? (source?.name ?? "") : parent
            let collides = (leafCounts[draft.name] ?? 0) > 1
            // **Only a favorite carries a second line** — see `FolderSidebarRow.detail`. Recents
            // still COUNT toward the collision, and that is deliberate rather than an oversight:
            // the reader is looking at one column, so a favorite `Legal` sitting above a recent
            // `Legal` is exactly the pair that needs the favorite to say which one it is.
            let showsDetail = draft.group == .pinned && collides && !qualifier.isEmpty
            return FolderSidebarRow(
                group: draft.group,
                root: draft.root,
                sourceName: showsBadge ? source?.name : nil,
                relativePath: draft.path,
                name: draft.name,
                detail: showsDetail ? qualifier : nil,
                isAvailable: source?.isAvailable ?? false)
        }
    }

    /// **On since v4.4.** The column, its chord, its menu item, its toolbar button and its ⌘/ row
    /// all exist again.
    ///
    /// Held out of v4.2 on 2026-08-20 and carried past v4.3, because what had been built was two
    /// ungrouped lists of folders under one source, and what `Sidebar` and `⌃⌘S` promise on this
    /// platform is a *place*. Shipping the first as the answer to the second spends the chord on
    /// it, and a later release that then reorganised the column would be changing what a keystroke
    /// means one version after teaching it. So the hold outlasted two releases deliberately, and
    /// what arrives here is the whole thing rather than the half.
    ///
    /// **Kept as a constant rather than deleted**, because `appliesTo` is still the one choke point
    /// every other question runs through, and a future hold — or a future workspace gate — belongs
    /// there rather than in a condition written at a call site. `FolderSidebarVisibilityTests`
    /// still passes `enabled:` explicitly for the same reason it always did: a test that could only
    /// ask the shipped question would be asserting `true && x`, and the Browse-only rule would go
    /// unasserted the day this flips again.
    public static let isEnabled = true

    /// **Where the sidebar can exist at all** — a workspace that carries one, with its panes
    /// showing, and not while ``isEnabled`` is false.
    ///
    /// This is what the View item, the toolbar button and the column are each gated on, so all
    /// three appear and disappear together and none can disagree about where a sidebar is possible.
    ///
    /// Gated on the workspace rather than on `layoutMode`, and `Workspace` is not visible from this
    /// module, so the caller supplies the verdict rather than the value. The point of the rule
    /// living here is that the two questions below are written once.
    ///
    /// **Browse-only until 2026-08-24**, on the reasoning that "the lens workspaces are
    /// single-source too, and their pane is the 220pt-clamped rail, which has no room for a 180pt
    /// column beside it". The premise was right and the conclusion did not follow: the window floor
    /// is 810 and the rail and lens panel together claim 560, so there is exactly 250pt for a
    /// sidebar whose default is 180. What the lens workspaces need is a clamp, not an exclusion —
    /// `PaneLogic.lensSidebarWidth` is it.
    ///
    /// **Not while the panes are collapsed.** Collapsing is a request for maximum workspace room,
    /// and a 180pt column beside a 34pt spine takes 185 of it straight back. This is folded in here
    /// rather than checked at the view for the same reason everything else is: the refresh guard
    /// and the drawn column must not be able to disagree about whether a sidebar exists.
    ///
    /// - Parameter enabled: defaults to ``isEnabled``, which is what every caller in the app uses.
    ///   Injectable for the same reason `opensInNewTab(_:)` takes its modifiers: a test that could
    ///   only ask the shipped question would be asking `true && x` — and was asking `false && x`
    ///   for the two releases this was held — so the rule would go unasserted in whichever state
    ///   the switch happens to be in.
    public static func appliesTo(workspaceSupportsSidebar: Bool, panesCollapsed: Bool = false,
                                 enabled: Bool = FolderSidebarModel.isEnabled) -> Bool {
        enabled && workspaceSupportsSidebar && !panesCollapsed
    }

    /// **Why the toggle is greyed out**, when it is.
    ///
    /// Someone reaching for a disabled switch is asking one question, and the answer has now been
    /// wrong twice — for the same reason both times. It read "The sidebar is available in Browse",
    /// which went stale when Organize and Storage got one; then "…in Browse, Organize and Storage",
    /// which went stale the same day when Compare did. **A sentence that enumerates the supported
    /// workspaces has to be edited every time the set changes, and nothing makes it fail when it
    /// is not.** This one names no workspace at all.
    ///
    /// Two ways to be unavailable, with different remedies, so one sentence cannot serve both.
    /// Returns `nil` when the sidebar IS available, so a caller cannot render a reason that does
    /// not apply.
    public static func unavailableReason(workspaceSupportsSidebar: Bool, panesCollapsed: Bool,
                                         enabled: Bool = FolderSidebarModel.isEnabled) -> String? {
        guard !appliesTo(workspaceSupportsSidebar: workspaceSupportsSidebar,
                         panesCollapsed: panesCollapsed, enabled: enabled) else { return nil }
        // Order matters where both apply: only one of the two is something the user can act on by
        // expanding a pane, and sending them to do work that changes nothing is worse than saying
        // less. Every shipping workspace supports the sidebar as of 2026-08-24, so in practice the
        // collapse branch is the live one — the first is kept because `supportsFolderSidebar` is a
        // real switch a future workspace can turn off.
        if !workspaceSupportsSidebar || !enabled {
            return "The sidebar is not available here"
        }
        return "Show the panes to use the sidebar"
    }

    /// **Whether the column is on screen**, which is a different question from the one above and
    /// the one that decides whether resolving its rows is worth a `stat` of the provider root.
    ///
    /// Both callers must agree or the sidebar draws rows nobody refreshed — or refreshes rows
    /// nobody draws. Written once for that reason.
    public static func isShowing(workspaceSupportsSidebar: Bool, panesCollapsed: Bool = false,
                                 preference: Bool,
                                 enabled: Bool = FolderSidebarModel.isEnabled) -> Bool {
        appliesTo(workspaceSupportsSidebar: workspaceSupportsSidebar,
                  panesCollapsed: panesCollapsed, enabled: enabled) && preference
    }

    /// The rows of one group, in order — the view's `ForEach` and the tests read the same list.
    public static func rows(_ rows: [FolderSidebarRow], in group: FolderSidebarRow.Group) -> [FolderSidebarRow] {
        rows.filter { $0.group == group }
    }

    /// **How many rows Favorites draws** — its remembered folders AND its places, which is the one
    /// thing about that section a reader keeps forgetting is two lists.
    ///
    /// The collapsed heading's badge and its VoiceOver label counted only the folders, so the
    /// first-run column — three standard places, no remembered folder yet — folded to a heading
    /// reading `0` above three rows, and said "0 items" out loud. Every other member that touches
    /// this section already knows it is two lists (`clampedDrop`, `SidebarReorder.favoritesMove`,
    /// the two `ForEach`es that draw it); this is the rule those readers can share.
    public static func favoritesCount(folderRows: [FolderSidebarRow], places: Int) -> Int {
        rows(folderRows, in: .pinned).count + places
    }

    /// What a click on a row means: **⌘ opens a new tab, a plain click switches this pane.**
    ///
    /// Injectable rather than reading `NSEvent.modifierFlags` at the call site, for the reason
    /// `DashboardViews` gives for the same trick: the flags are the state of the machine's
    /// keyboard, so a test can only pin this by being handed them.
    public static func opensInNewTab(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.command)
    }

    /// Whether a row can be opened at all. An unavailable row stays listed — deleting a favorite
    /// because a drive is asleep would cost the user their favorites — but it refuses, the same way
    /// the ⌘K palette's unavailable rows do.
    public static func canOpen(_ row: FolderSidebarRow) -> Bool { row.isAvailable }

    /// **The folder a row lives in, as a row of its own** — or nil where there is not one to show.
    ///
    /// Nil in two cases, and they are different: a row already AT its source's root has no
    /// enclosing folder inside that source (its parent is somewhere the pane cannot be pointed),
    /// and an unavailable row has no answer at all because its whole root is not answering.
    ///
    /// The parent keeps the child's `group`, which is not a claim that the parent is itself a
    /// favorite — nothing reads `group` on the way to opening one, and inventing a third case for
    /// "a row that exists only to be navigated to" would be a case every switch over `Group` then
    /// has to handle. The name is re-derived from the parent path so the row reads as that folder
    /// rather than as the one it was made from.
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

/// **The folder sidebar** — Favorites, Locations and Recents, in that order.
///
/// The favorites and recents `FolderJumpStore` holds were reachable only through the pane header's
/// jump menu and the ⌘K field; a column down the left keeps all three answers on screen at once.
/// Since v4.4 the favorites and recents span every source, and Locations is here too. Drawn on
/// every workspace that answers `Workspace.supportsFolderSidebar` — which is all four — with the
/// lens workspaces and Compare taking a clamped width rather than an exclusion
/// (`PaneLogic.lensSidebarWidth`, `PaneLogic.compareSidebarWidth`).
///
/// **The Sources section reverses a deliberate removal, and the reversal is scoped.** The Left/Right
/// provider sidebar went when the provider became a header dropdown, and this file used to say the
/// column "must not quietly bring it back". It brings it back loudly: the header capsule *stays* and
/// keeps its job — the at-rest answer to which source a pane is on, and the only such answer in
/// Compare, which has two panes and no sidebar. This section is how you *change* it. Decided
/// 2026-08-24; the alternative, letting the sidebar own source switching outright, would have made
/// ⌃⌘S non-optional, because closing the column would remove the only way to switch source.
/// **Something the sidebar just did that can still be taken back**, shown at the foot of the column.
///
/// The inline alternative to ⌘Z, decided 2026-08-24. The window's `UndoManager` holds *file*
/// operations — `FileSyncManager` registers sync runs on it and checks the top is still that run
/// before reversing — so putting a configuration change there means someone who moved forty files,
/// clicked a shortcut and pressed ⌘Z gets a source removed instead of their move back. Correct undo
/// semantics, wrong answer.
///
/// It sits in the column rather than in the pane's status bar because that bar is item #11 and is
/// not built; here it is also next to the row the user just clicked, which is where they are looking.
public struct SidebarNotice: Equatable, Sendable {
    public let message: String
    /// **Always present, and "Dismiss" is a real one.** A notice about a card that has been ejected
    /// has nothing to undo — the volume is gone — but it still needs a way off the column, because
    /// nothing else clears one and an actionless line would sit at the bottom of the sidebar for
    /// the rest of the session. The host decides the word; see `FolderSidebarNotice.actionTitle`.
    public let actionTitle: String

    public init(message: String, actionTitle: String) {
        self.message = message
        self.actionTitle = actionTitle
    }
}

/// **Which pane a click will act on**, for a workspace where that is a real question.
///
/// `nil` everywhere with one pane, because there is nothing to disambiguate and a caption saying
/// "opens in the pane" would be noise. Compare is the only surface that sets it.
///
/// **It no longer carries a control, and that is the point.** The side is set by clicking the pane
/// itself — any click, anywhere in it — and shown by the accent border that pane wears. Two
/// capsules here were a second way to set one value, and once the value governs the action bar and
/// the lens scans as well as this column, setting it from inside the sidebar is a far bigger claim
/// than a sidebar header should make.
///
/// What survives is the half the border cannot say. The border names a SIDE; the rows below are a
/// source's folders, and "these are Dropbox's, not iCloud's" is stated only here.
public struct SidebarTarget: Equatable, Sendable {
    /// Whether the RIGHT pane is the one a click acts on.
    public let targetsRight: Bool
    public init(targetsRight: Bool) {
        self.targetsRight = targetsRight
    }

    /// **What the header says: the SIDE.**
    ///
    /// It named the source for one build — "Opens in Google Drive (Preserve)" — on the reasoning
    /// that the border already carries the side, so repeating it would say nothing new. Reported
    /// from the running app as meaningless, and it was worse than that: it was **misleading**. The
    /// rows below are not that source's. `refreshFolderSidebarRows` builds Favorites, Locations and
    /// Recents from EVERY enabled source at once, so naming one implies a scoping the column does
    /// not have — a reader would take "Opens in Google Drive" as saying these are Google Drive's
    /// folders.
    ///
    /// The side is the one thing that is true of every row here, which is what a header describing
    /// all of them has to be.
    public var openingDescription: String {
        "Opens on \(Self.label(targetsRight: targetsRight))"
    }

    /// Points at a pane. `arrow.left`/`arrow.right` would both be wrong — both panes are to the
    /// RIGHT of this column, so an arrow points the same way for either.
    public static func symbol(targetsRight: Bool) -> String {
        targetsRight ? "rectangle.righthalf.filled" : "rectangle.lefthalf.filled"
    }

    public static func label(targetsRight: Bool) -> String {
        targetsRight ? "Right" : "Left"
    }
}

public struct FolderSidebarView: View {

    /// The column's width, which the user drags. **Resizable since v4.4**, where it was fixed at
    /// 180 on the reasoning that "the pane beside it is the resizable one".
    ///
    /// What changed that reasoning is the qualifier. With eleven sources listed, several needing an
    /// account to tell them apart, a 180pt column leaves about 136pt for a name plus its account
    /// once the row's margins, padding, glyph and gap are taken out — enough for
    /// `OneDrive · personal` and not for a spelled-out organisation name. Rather than legislate an
    /// abbreviation, the width is the user's own answer to how much name they want to pay for.
    ///
    /// Snapshots and the render tests use ``defaultWidth``, so the suite measures one width no
    /// matter what any particular user has dragged theirs to.
    /// The one coordinate space every drag measurement is taken in. Named rather than `.global`:
    /// the window moves, and a midpoint recorded in screen coordinates would be compared against a
    /// pointer position taken after it moved.
    static let dragSpace = "sidebarDrag"

    /// **A row's minimum height, and the column's rhythm.** Set as a floor rather than as vertical
    /// padding so a row that grows a second line — a favorite carrying its parent — gets taller
    /// instead of being clipped.
    ///
    /// 26 first, reasoned from Finder drawing 24pt rows at its small icon size and 28 at medium.
    /// That reasoning was sound and the answer was still wrong, because it guessed which icon size
    /// Finder was actually on. Measured against a side-by-side screenshot of the two sidebars
    /// (2026-08-24), calibrated on a reference visible in both — the traffic lights, 12pt, at
    /// ~14px — Finder's row PITCH is ~32pt against this column's 28 (a 26 floor plus the 2pt
    /// between rows), so it reads about 15% tighter than the thing it was copying.
    ///
    /// 30 puts the pitch at exactly 32. The floor is the only number that moves: the 2pt between
    /// rows and the 14pt between sections both stay, because what was tight was the rows.
    static let rowHeight: CGFloat = 30

    /// A place row's mark, at the ambient text scale.
    ///
    /// Routed through `ScaledFont.pointSize(scale:)` rather than multiplied, because the app's text
    /// scaling is knee-shaped — full boost at small sizes, halved above — and a mark scaled linearly
    /// would drift away from the 13pt label it sits beside at exactly the sizes someone changes the
    /// setting for.
    nonisolated static func markSize(scale: CGFloat) -> CGFloat {
        ScaledFont.system(size: 16).pointSize(scale: scale)
    }

    public static let defaultWidth: CGFloat = 180
    public static let minWidth: CGFloat = 150
    public static let maxWidth: CGFloat = 280

    /// The three headings, in the order they are drawn. `CaseIterable` so the view and the tests
    /// walk one list.
    public enum Section: String, CaseIterable, Sendable, Hashable {
        case favorites = "Favorites"
        /// **Finder's word, since 2026-08-24** — it was `Sources`, which was ours. The raw value is
        /// what the collapse preference stores, so an install that had folded `Sources` finds
        /// `Locations` expanded: `folderSidebarCollapsedSections` ignores a value it cannot map to
        /// a case, which is the tolerance that makes a rename cost one fold rather than a crash.
        case locations = "Locations"
        case recents = "Recents"
    }

    private let folderRows: [FolderSidebarRow]
    /// Locations' rows — clouds, devices, Trash.
    private let locationRows: [SidebarSourceRow]
    /// Favorites' place rows — home, Desktop, Documents, Downloads and the startup disk by
    /// default, plus anything else the user has put there.
    ///
    /// Named for the `.shortcut` band they carry, which is what puts them in this section; the band
    /// is applied from the user's Favorites list, so a cloud account or a mounted disk can be one
    /// of these too.
    private let shortcutRows: [SidebarSourceRow]
    private let currentRoot: String
    private let currentRelativePath: String
    private let currentSourceId: String
    private let width: CGFloat
    private let collapsed: Set<Section>
    private let notice: SidebarNotice?
    /// Which pane a click acts on — `nil` where there is only one and the question does not arise.
    /// See `SidebarTarget`.
    private let target: SidebarTarget?
    /// Sets which pane a click acts on. Only Compare supplies a `target`, so only Compare calls it.
    /// Opens a folder row in a NAMED pane, whatever the current target is — the context menu's
    /// verb. A one-off, so it deliberately does not move the target: picking "Open in Right Pane"
    /// for one folder is not a statement about the next one.
    private let onOpenRowOnSide: (FolderSidebarRow, Bool) -> Void
    /// The same for a Locations row.
    private let onOpenSourceOnSide: (SidebarSourceRow, Bool) -> Void
    private let accent: Color
    private let onOpen: (FolderSidebarRow, Bool) -> Void
    private let onToggleFavorite: (FolderSidebarRow) -> Void
    private let onOpenSource: (SidebarSourceRow, Bool) -> Void
    private let onToggleSection: (Section) -> Void
    private let onNoticeAction: () -> Void
    /// Add a place to Favorites, or take it out — the source-row counterpart to
    /// `onToggleFavorite`, which answers the same question for a remembered folder.
    /// Point the target pane at the folder a row lives in, rather than at the row.
    private let onShowEnclosingFolder: (FolderSidebarRow) -> Void
    private let onToggleSourceFavorite: (SidebarSourceRow) -> Void
    /// Take a folder source out of the app — the verb this column had no way to reach.
    ///
    /// **The row it exists for is the one that can never come back.** A source rooted on a volume
    /// that was renamed while SyncCloud was quit names a mount point that will not return; it draws
    /// dimmed forever, and dimmed is the app's word for "asleep", so nothing about the row says it
    /// is dead or offers a way out. Until this, the only route was Settings ▸ Sources, which is not
    /// where the user is when they see the problem.
    private let onRemoveSource: (SidebarSourceRow) -> Void
    /// Eject the volume a row sits on — Finder's own verb, on the rows Finder offers it for.
    ///
    /// **Ejecting is what makes the row go away now**, since an unmount removes the sources on a
    /// detachable volume (`SettingsManager.removeFolderSources(onVolume:)`). Before that landed,
    /// an in-app Eject would have left the same dead row this column already had too many of; it
    /// is offered here because the two halves arrived together.
    private let onEjectSource: (SidebarSourceRow) -> Void
    /// **Which rows can be ejected, by mount point**, decided by the caller because only it has
    /// walked the mounted volumes.
    ///
    /// Keyed by PATH rather than by source id, unlike `removableSourceIds`: a card that is not a
    /// source yet still draws a row, and refusing to eject it because SyncCloud has not been given
    /// it would be an odd rule for a verb that is about the hardware.
    private let ejectablePaths: Set<String>
    /// **Where an unmount actually forgets the sources**, which is narrower than `ejectablePaths`
    /// and is the difference between a confirmation that is true and one that is not.
    ///
    /// Eject is offered on anything Finder would eject, a network share included. A share is not
    /// local, so unmounting it leaves its sources alone — and a dialog that told the user their
    /// source was about to go would be promising something that will not happen. Supplied by the
    /// caller for the same reason `ejectablePaths` is: only it has walked the volumes.
    private let detachablePaths: Set<String>
    /// **Which rows Remove is offered on, decided by the caller because it owns the list.**
    /// Only a folder source can be removed: a discovered account is discovered, so removing it
    /// would name an act that cannot happen — `SettingsManager.removeFolderSource` ignores the id
    /// and the row would still be there. Same reason `canRestoreStandardFavorites` is a parameter.
    private let removableSourceIds: Set<String>
    /// Put `SidebarFavoritePlaces.standard` back. Offered only when one of them is missing.
    private let onRestoreStandardFavorites: () -> Void
    /// Whether Restore has anything to do, decided by the caller because it owns the stored list.
    private let canRestoreStandardFavorites: Bool
    private let onMoveFavorite: (Int, Int) -> Void
    private let onMoveSource: (Int, Int) -> Void
    private let onFavoriteRecent: (FolderSidebarRow, Int) -> Void

    /// Which row is under the pointer mid-drag, and where it would land.
    ///
    /// **`@State` rather than `@GestureState`**, because it has to survive the gesture ending: the
    /// drop is handled in `onEnded`, and a `@GestureState` has already reset by then.
    @State private var drag: DragInFlight?
    /// Each section's measured row midpoints, by row index, collected through `RowMidpoints`.
    @State private var midpoints: [Section: [Int: CGFloat]] = [:]
    /// Each section's own top edge, in the same space. Needed only for a section with no rows to
    /// average against — an **empty Favorites**, which is the first-run state and the one place a
    /// drag has to be answerable with no midpoints to answer from.
    @State private var sectionTops: [Section: CGFloat] = [:]
    /// Which heading the pointer is over, so its chevron can be revealed the way Finder reveals
    /// Show/Hide rather than keeping a glyph on screen at all times.
    @State private var hoveredHeader: Section?
    /// The row action waiting on a confirmation, if any.
    ///
    /// **Both of this menu's consequential verbs are confirmed, and neither can be undone from
    /// here** — which is the opposite of what promoting a shortcut does one file over, and the
    /// difference is that promotion is exactly reversible while these are not. A removed source
    /// loses its id, and with it the name the user gave it, the folder it opened at and whether it
    /// was switched off; re-adding the same path mints a new source with none of those. An "Undo"
    /// that quietly hands back less than it took is worse than a question asked first.
    ///
    /// **One state and one dialog rather than two of each.** Two `confirmationDialog` modifiers on
    /// one view is a shape SwiftUI presents unreliably when both could be armed, and the two can be
    /// armed at once here — a right-click on a second row while the first dialog is up. One
    /// presented value cannot be in two states.
    @State private var pendingRowAction: PendingRowAction?
    /// **The dialog's title, latched.** It is a plain parameter rather than part of the
    /// `presenting:` mechanism, so it is re-read from this body on every render — including the
    /// ones during the dismissal animation, when the action has already gone back to nil and a
    /// title derived from it would read as an empty heading on the way out. `arm(_:)` sets both,
    /// so the two cannot come apart.
    @State private var pendingRowTitle = ""

    /// **A consequential verb the user has asked for but not yet confirmed.**
    ///
    /// Carries the row rather than an id, because the dialog names the place and the row is what
    /// knows its name — and re-resolving it by id at confirm time would be a second lookup that
    /// could disagree with what the menu was opened on.
    enum PendingRowAction: Equatable {
        case removeSource(SidebarSourceRow)
        /// Whether SyncCloud holds this volume as a source travels with the action, because it
        /// changes what the dialog can honestly promise: ejecting a card that is not a source
        /// costs nothing but the mount.
        /// Whether confirming this will ALSO cost the source — true only when SyncCloud holds the
        /// volume as one *and* unmounting it is the kind that forgets. Named for the consequence
        /// rather than for the row's status, because those two came apart: a network share can be
        /// a source and keep being one through an eject.
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

        /// **What the dialog says, and the eject wording is the point of it existing.**
        ///
        /// Ejecting reaches past SyncCloud: the volume is unmounted from macOS, so it leaves
        /// Finder and every other app at the same moment. A confirmation that only mentioned the
        /// source would be describing the smaller half of what the click does.
        var message: String {
            switch self {
            case .removeSource(let row):
                return "\(row.name) is removed from SyncCloud. The folder itself is not deleted, and you can add it again — but the name you gave the source, where it opens, and whether it was switched off are not kept."
            case .eject(let row, let losesItsSource):
                let system = "\(row.name) is unmounted from macOS, not just from SyncCloud — it leaves Finder and every other app until you plug it in again. Nothing on it is changed."
                guard losesItsSource else { return system }
                return system + " SyncCloud also stops holding it as a source, so the name you gave it and where it opens are not kept."
            }
        }

        /// The confirming button's word — the verb the user reached for, restated.
        var verb: String {
            switch self {
            case .removeSource(let row): return "Remove \(row.name)"
            case .eject: return "Eject"
            }
        }

        /// **Red only where something cannot be got back.** Removing a source loses the name, the
        /// landing folder and the enabled flag; so does ejecting a card that is one. Ejecting a
        /// card that is NOT a source costs only the mount, which plugging it back in returns — and
        /// dressing that as destructive would teach the colour to mean nothing.
        var isDestructive: Bool {
            switch self {
            case .removeSource: return true
            case .eject(_, let losesItsSource): return losesItsSource
            }
        }
    }
    /// The ambient text scale, so a mark can be sized by the same curve as the label beside it.
    @Environment(\.appFontScale) private var fontScale

    /// One row's measured midpoint, collected per section so the insertion index is computed
    /// against real geometry rather than an assumed row height — the rows are not uniform, since a
    /// favorite carrying a parent qualifier draws a second line.
    /// **Keyed by the row's own index, not appended in the order the rows are collected.**
    ///
    /// A `PreferenceKey` reduces in child order, and `zIndex` — which the lifted row sets so it
    /// draws over its neighbours — changes that order. The ladder came back as
    /// `[175, 207, 239, 163]` with the dragged row's entry last, so both the insertion index and
    /// the line drawn from it were reading a scrambled list. Appending was never safe here; it
    /// only looked safe while nothing reordered the children.
    private struct RowMidpoints: PreferenceKey {
        static var defaultValue: [Section: [Int: CGFloat]] { [:] }
        static func reduce(value: inout [Section: [Int: CGFloat]],
                           nextValue: () -> [Section: [Int: CGFloat]]) {
            for (section, mids) in nextValue() { value[section, default: [:]].merge(mids) { a, _ in a } }
        }
    }

    /// Where each section's rows begin, in `dragSpace`. Reported by `reorderable` rather than by a
    /// row, because the case it exists for is the section that HAS no rows.
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
        /// Whether releasing now commits. Always true for a within-section reorder — those have
        /// `isNoOp` for the do-nothing case — but a *recents* drag becomes a favorite, a persisted
        /// membership change, and it only arms once the pointer has actually reached the Favorites
        /// band. Without this, any ≥5pt slip on a recent — a sloppy trackpad click — favorited the
        /// row irrevocably: the insertion index was computed against Favorites' midpoints and
        /// clamped into its band, so every release, including one back on the row it came from,
        /// still committed. Releasing anywhere below Favorites is a cancel, matching what the
        /// hidden insertion line promises.
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
                onRestoreStandardFavorites: @escaping () -> Void = {},
                canRestoreStandardFavorites: Bool = false,
                onMoveFavorite: @escaping (Int, Int) -> Void = { _, _ in },
                onMoveSource: @escaping (Int, Int) -> Void = { _, _ in },
                onFavoriteRecent: @escaping (FolderSidebarRow, Int) -> Void = { _, _ in }) {
        self.folderRows = folderRows
        self.locationRows = locationRows
        self.shortcutRows = shortcutRows
        self.currentRoot = currentRoot
        self.currentRelativePath = currentRelativePath
        self.currentSourceId = currentSourceId
        self.width = width
        self.collapsed = collapsed
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
        self.onRestoreStandardFavorites = onRestoreStandardFavorites
        self.canRestoreStandardFavorites = canRestoreStandardFavorites
        self.onMoveFavorite = onMoveFavorite
        self.onMoveSource = onMoveSource
        self.onFavoriteRecent = onFavoriteRecent
    }

    /// **A drag preset into the view, so the insertion indicator can be rendered at all.**
    ///
    /// `DragGesture` needs a real event stream and there is none in a test process, so the one
    /// thing the indicator exists to do — sit in the gap it names, in the section it names — had no
    /// way to be measured. It shipped a whole section's origin out of place for exactly that
    /// reason. Internal rather than public, and nothing in the app calls it.
    func withDragInFlight(_ inFlight: DragInFlight) -> Self {
        var copy = self
        copy._drag = State(initialValue: inFlight)
        return copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let target { targetHeader(target) }
            ScrollView {
                // 14pt between sections, against 2pt between rows within one. Finder separates its
                // groups by roughly a row's height and its rows by nothing, which is what makes a
                // heading read as a heading without a rule under it.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Section.allCases, id: \.self) { section in
                        // **A section with nothing in it is not drawn at all**, rather than drawn
                        // empty — except Favorites, which draws its invitation instead, because an
                        // empty Favorites is the first-run state and the sentence that helps is the
                        // one saying how it fills. Sources is never empty (a first run has at least
                        // one source, and the local shortcuts are always listed) and Recents simply
                        // is not there until you have been somewhere.
                        if section == .favorites || !isEmpty(section) {
                            sectionView(section)
                        }
                    }
                }
                .padding(.vertical, 10)
                .coordinateSpace(name: Self.dragSpace)
                // **The insertion line is drawn HERE, on the view that NAMES the drag space** —
                // not inside the section it points into, which is where it used to be and is the
                // whole of the bug it shipped with. Every midpoint is measured in `dragSpace`, so
                // `insertionY` returns a `dragSpace` y; offsetting a *section's* overlay by it
                // drew the line that far below the SECTION's top rather than the column's, which
                // is an error of exactly the section's own origin. Favorites, being first, was
                // out by its heading alone and looked merely imprecise; Locations was out by
                // everything above it and put the line several rows down, in one case past the
                // last row in the column. Reported as "the indicator is several rows below the
                // actual move".
                //
                // Drawing it in the space the numbers were taken in is what makes the class of
                // bug unavailable, rather than correcting the offset by a second measurement that
                // can itself drift.
                .overlay(alignment: .top) {
                    // **Nothing is drawn into a folded section.** A recent dragged while Favorites
                    // is collapsed has a real drop — the folder still becomes a favorite — but no
                    // rows and no reported top to aim at, so `insertionY`'s last fallback put the
                    // caret at y = 0, at the very top of the column and pointing at a heading three
                    // sections away from where the row was going.
                    // …and nothing is drawn for an unarmed recents drag: the line is the promise
                    // that releasing commits, and below the Favorites band releasing cancels.
                    if let drag, drag.willDrop, !collapsed.contains(dropTarget(for: drag.section)),
                       let y = insertionY(for: drag, in: dropTarget(for: drag.section)) {
                        insertionIndicator
                            .offset(y: y - Self.insertionIndicatorHeight / 2)
                    }
                }
                // **Assigned, not merged.** `reduce` no longer appends — it merges by row index,
                // so a stale ladder cannot grow — but a section that loses rows still has to lose
                // their entries, and only a wholesale assignment does that.
                .onPreferenceChange(RowMidpoints.self) { midpoints = $0 }
                .onPreferenceChange(SectionTops.self) { sectionTops = $0 }
            }
            .scrollContentBackground(.hidden)
            if let notice { noticeView(notice) }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        // **One dialog for the whole column, not one per row.** `sourceRow` is a function rather
        // than a view of its own, so a per-row presenter would have nowhere to keep its state —
        // and the alternative, a `@State` on a struct rebuilt for every row, is the classic way to
        // get a dialog that presents against a stale row.
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

    /// **Which pane a click lands in, said out loud** — pinned above the scroll area so it cannot
    /// be scrolled away from, because it describes every row below it and not the rows in view.
    ///
    /// **A statement, not a control, and that is a return rather than a revert.** It began as a
    /// caption over a target derived from the pane SELECTION, which was reported unusable: with
    /// nothing selected the target was always the left pane, and a click on a pane's background
    /// undid it. Two capsules replaced it and fixed that. They are gone again now for a different
    /// reason — the side is set by clicking the pane, and shown by that pane's accent border, so a
    /// second setter here would compete with the pane for authority over a value that now governs
    /// the action bar and the lens scans too.
    ///
    /// What it says is the SIDE — "Opens on Left/Right", `SidebarTarget.openingDescription`. It
    /// named the source for one build on the reasoning that the border already carries the side,
    /// and that wording implied the rows below were one source's, which they are not; the whole
    /// story is on `SidebarTarget`.
    private func targetHeader(_ target: SidebarTarget) -> some View {
        HStack(spacing: 4) {
            Image(systemName: SidebarTarget.symbol(targetsRight: target.targetsRight))
                .scaledFont(.system(size: 9))
            Text(target.openingDescription)
                .scaledFont(.system(size: 10))
                // `.tail`, not the default: a head-truncated name reads as a different source,
                // which is the bug the source qualifier hit in `94cab0e0`.
                .truncationMode(.tail)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// **Arms a confirmation.** One door, so the latched title cannot be set without the action it
    /// belongs to — the drift a second `@State` invites, and the only reason it is not derived.
    private func arm(_ action: PendingRowAction) {
        pendingRowTitle = action.title
        pendingRowAction = action
    }

    /// Pinned to the bottom, outside the `ScrollView`, so it cannot be scrolled away from — the
    /// whole point of it is that it is reachable for as long as it is true.
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
    /// that says nothing about its size reads as an empty one.
    ///
    /// **Favorites draws two lists and has to count both.** It counted only the remembered folders
    /// until this was reviewed, so the first-run column — three standard places and no remembered
    /// folder yet — folded to a heading reading `0` over three rows, and told VoiceOver the same.
    /// Every other reader of this section already knows it is two lists (`clampedDrop`,
    /// `SidebarReorder.favoritesMove`, the `ForEach` pair in `sectionView`); this was the one that
    /// did not. `isEmpty` asks the same question, so it goes through here rather than repeating the
    /// omission a second time.
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
                    // **The drop zone is the section, not each row.** An empty Favorites still has
                    // to accept a recent dragged into it, and a per-row target cannot be hit when
                    // there are no rows — which is exactly the first-run case.
                    reorderable(.favorites) {
                        // **The standard places sit above the curated ones.** Finder puts its
                        // defaults at the top of Favourites, and they are the rows a person reaches
                        // for without having chosen them — a curated favorite is something you
                        // decided on, so it reads as the more specific half and goes second.
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
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        // Recents do not reorder — their order is "when you were there", and a
                        // hand-placed one would be a claim the timestamps contradict. A recent can
                        // still be dragged *out*, into Favorites.
                        draggableRow(section: .recents, index: index) { self.row(for: row) }
                    }
                }
            }
        }
    }

    /// The heading, which is also the collapse control — the whole row, not just the chevron, so a
    /// 10pt triangle is not the hit area for a control someone uses to make room.
    private func header(_ section: Section, isCollapsed: Bool) -> some View {
        let hovered = hoveredHeader == section
        return Button { onToggleSection(section) } label: {
            HStack(spacing: 4) {
                Text(section.rawValue)
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // **The chevron appears on hover, and the count when it is folded** — Finder's own
                // arrangement, where a Show/Hide affordance is revealed rather than kept on screen.
                // Two things follow from it: the heading text starts at the same inset as a row's
                // icon instead of being pushed right by a permanent glyph, so the column has one
                // left edge; and a folded section can still say how much is behind it, which is the
                // only thing that stops it reading as empty.
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
            .frame(height: 16)
            .padding(.horizontal, 10)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredHeader = $0 ? section : (hoveredHeader == section ? nil : hoveredHeader) }
        .accessibilityLabel("\(section.rawValue), \(isCollapsed ? "collapsed" : "expanded"), \(count(section)) items")
        // **The way back from removing a standard place**, and the reason Remove is not a
        // one-way door. Desktop taken out of Favorites has nowhere else to appear, so without
        // this the only route back would be adding `~/Desktop` as a folder source — a different
        // thing that happens to look similar. (Home and the startup disk DO fall back to
        // Locations, being device rows in their own right; the three in `favoriteShortcuts` do
        // not, and they are what makes this item necessary.) On the heading rather than on a row,
        // because the rows it restores are precisely the ones that are not there to be
        // right-clicked.
        //
        // Shown only when something is actually missing: an item that would do nothing teaches
        // nothing, and it would sit on the heading of every session forever.
        .contextMenu {
            if section == .favorites, canRestoreStandardFavorites {
                Button("Restore Standard Places") { onRestoreStandardFavorites() }
            }
        }
    }

    /// Not "no folders": an empty Favorites is the *first-run* state, and the sentence that helps is
    /// the one that says how it fills.
    private var emptyFavorites: some View {
        Text("Folders you add to Favorites stay here.")
            .scaledFont(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
    }

    /// Clouds, a hairline, then local folders. **One section with a rule inside it**, rather than
    /// two headings — decided 2026-08-24: the glyphs already say which kind a row is, and a fourth
    /// heading in the column pushes Recents below the fold on a short window.
    /// Locations: the clouds you signed into, a rule, then the hardware and the Trash.
    ///
    /// **One rule, not two.** The clouds are a different kind of thing from the disks — one is an
    /// account, the other is something you can unplug — and that difference is worth a line. The
    /// device band and the Trash are both hardware-side, so a second rule between them would be
    /// separating things that belong together.
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
                // **Indices continue across the rule**, because it is a visual break inside one
                // section rather than a second list — the stored order is one sequence. Device
                // rows do not drag at all, though: their half of the band is drawn home-first
                // then volumes-by-name, never from the stored order, so no device reorder can
                // ever render — see `draggableRow`'s `draggable:`.
                draggableRow(section: .locations, index: clouds.count + index, draggable: false) {
                    sourceRow(for: source)
                }
            }
        }
    }

    /// A section that accepts a drag. It groups the rows and reports where the group starts; the
    /// insertion line itself is drawn by `body`, in the coordinate space the midpoints are measured
    /// in — see the overlay there for why it cannot be drawn from inside here.
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

    /// **Where the row would land, drawn as an insertion point rather than a rule.**
    ///
    /// A plain full-bleed bar is the same shape as the divider Locations already draws between its
    /// clouds and its disks, so the one mark on screen saying "release here and the row goes in
    /// this gap" read as another separator. The ring at the leading end is what makes it an
    /// insertion caret — the shape AppKit's own outline views use — and the 10pt inset lines it up
    /// with where a row's glyph starts, so it sits in the column the rows occupy instead of running
    /// edge to edge like a section break.
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
        // The caret is the drop point, and a drop point is a claim about a *gap*: centre the mark
        // on the gap rather than hanging it below, or the line reads as belonging to the row under
        // it. `body` subtracts half of this from the offset.
        .allowsHitTesting(false)
    }

    /// The caret's diameter, and so the height the indicator is centred by.
    private static let insertionIndicatorHeight: CGFloat = 7

    /// **Keeps a Locations drop inside the band it started in**, and leaves every other section's
    /// drop alone.
    ///
    /// Locations is drawn grouped — clouds, a rule, then the device rows and the Trash — and that
    /// grouping is applied when the rows are BUILT, from each row's band. A row released past the
    /// rule is therefore re-grouped straight back and the move looks like it did nothing, while the
    /// insertion line had promised the landing. Clamping is what makes the line honest: the row
    /// goes as far as its band allows and stops there, which IS what will happen.
    ///
    /// A comment here used to claim "a device dragged above the rule is a legitimate move". It is
    /// not, and never was — the band walk in `splitFolderSidebarPlaceRows` decides the grouping and
    /// nothing in the stored order can override it.
    private func clampedDrop(_ to: Int, section: Section, from: Int) -> Int {
        switch dropTarget(for: section) {
        case .locations:
            guard locationRows.indices.contains(from) else { return to }
            let cloudCount = locationRows.filter { $0.band == .cloud }.count
            return locationRows[from].band == .cloud
                ? SidebarReorder.clampedToBand(to, bandStart: 0, bandEnd: cloudCount)
                : SidebarReorder.clampedToBand(to, bandStart: cloudCount, bandEnd: locationRows.count)
        case .favorites:
            // **Favorites is two lists drawn as one**, places then remembered folders, and they
            // live in different stores — a place is a root, a remembered folder is a path inside
            // one. A row crossing the boundary has nowhere to land, so it stops at the boundary
            // instead of the line promising a move the drop cannot make. Same reasoning as the
            // Locations bands above, and the same clamp.
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

    /// A section's midpoints in **row order**, which is what both the insertion index and the line
    /// are computed against. Read through here rather than off `midpoints` directly: the stored
    /// form is keyed by index precisely because the collection order cannot be trusted.
    private func orderedMidpoints(_ section: Section) -> [CGFloat] {
        (midpoints[section] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
    }

    /// Where the insertion line sits, from the midpoints this section reported — **a `dragSpace` y,
    /// the same space the midpoints were measured in**, which is the space `body` draws it in.
    private func insertionY(for drag: DragInFlight, in section: Section) -> CGFloat? {
        // A section with no rows still has to answer, and its own top is the only honest answer:
        // an empty Favorites accepting its first dragged-in recent. Falling back to zero would put
        // the line at the top of the COLUMN, which after the move to a drag-space overlay is a
        // different place entirely.
        let mids = orderedMidpoints(section)
        guard !mids.isEmpty else { return sectionTops[section] ?? 0 }
        let index = min(max(drag.to, 0), mids.count)
        if index == 0 { return max(mids[0] - rowHalfHeight(mids), 0) }
        if index >= mids.count { return mids[mids.count - 1] + rowHalfHeight(mids) }
        return (mids[index - 1] + mids[index]) / 2
    }

    /// Half a row, from the measured pitch — used only for the line above the first row and below
    /// the last, where there is no neighbouring midpoint to average against.
    private func rowHalfHeight(_ mids: [CGFloat]) -> CGFloat {
        guard mids.count > 1 else { return 11 }
        return (mids[1] - mids[0]) / 2
    }

    /// **Which section a drag would drop into.** A favorite or a source stays in its own section; a
    /// *recent* can leave its own and land in Favorites, which is how a folder is added by drag.
    private func dropTarget(for section: Section) -> Section {
        section == .recents ? .favorites : section
    }

    /// One row, wrapped so it reports its midpoint and can be picked up.
    /// - Parameter draggable: pass false for a row that reports its midpoint but cannot be picked
    ///   up — the device rows, whose band is drawn home-first-then-volumes-by-name and never from
    ///   the stored order, so no device reorder can ever render. Letting them lift anyway drew an
    ///   honest-looking insertion line whose drop always snapped back — and, with two
    ///   provider-backed device rows, silently rewrote the persisted provider order while the
    ///   sidebar showed nothing changed.
    @ViewBuilder
    private func draggableRow<Content: View>(section: Section, index: Int, draggable: Bool = true,
                                             @ViewBuilder content: () -> Content) -> some View {
        let isLifted = drag?.section == section && drag?.from == index
        content()
            // **The lifted row is given a ground of its own, and a shadow.** It follows the pointer
            // across the rows it is passing, and a translucent row drawn straight over another one
            // composites into a single unreadable smear — two names overlapping at half strength,
            // which is what "confusing" meant in the report. Opaque-plus-shadow is what makes it
            // read as one row picked up OVER the column rather than as two rows colliding, and it
            // is why the fade goes entirely: at 0.9 the row beneath still ghosted through — legibly
            // enough to read its name — and 10% of a smear is a smear. The lift carries "this one
            // is moving" on its own.
            .background {
                if isLifted {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.30), radius: 6, y: 2)
                }
            }
            .offset(y: isLifted ? (drag?.translation ?? 0) : 0)

            // **Measured OUTSIDE the offset, so the row reports the slot it came from rather than
            // where the pointer has dragged it to.** Inside, the lifted row's midpoint travelled
            // with the pointer — measured at 163 for a row resting at 143 under a 20pt drag — and a
            // midpoint that moves with the thing being compared against it makes the row's own
            // neighbourhood unstable: the insertion index it produces flickers by one exactly where
            // the user is aiming most carefully.
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: RowMidpoints.self,
                                           value: [section: [index: geo.frame(in: .named(Self.dragSpace)).midY]])
                }
            }
            .zIndex(isLifted ? 1 : 0)
            // **`simultaneousGesture` with a real minimum distance**, so a click still opens the
            // folder. The row is a `Button`; a plain `.gesture` would swallow the tap, and a zero
            // minimum would turn every click into a one-pixel drag.
            .simultaneousGesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.dragSpace))
                    .onChanged { value in
                        let raw = SidebarReorder.insertionIndex(
                            forY: value.location.y,
                            midpoints: orderedMidpoints(dropTarget(for: section)))
                        // A recents drag arms only above the Locations band — i.e. once the
                        // pointer is really over Favorites, the section it would drop into. See
                        // `DragInFlight.willDrop`; Locations always draws (a first run has at
                        // least one source), so its top is the boundary that exists to measure
                        // against. `.infinity` keeps an unmeasured column armed rather than dead.
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
                            // The unarmed release is a cancel, not a no-op variant: the pointer
                            // never reached Favorites, so committing would persist a membership
                            // change the (hidden) insertion line never promised.
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
            onOpenSource(source, FolderSidebarModel.opensInNewTab(NSEvent.modifierFlags))
        } label: {
            HStack(spacing: 6) {
                // **The provider's own mark, in one ink.** A uniform `cloud` said nothing about
                // which of eleven accounts a row was, leaving the whole job to the name — and the
                // names collide, which is what the account qualifier exists to patch. `ProviderLogo`
                // is the one place a mark is drawn, and its monochrome mode keeps each silhouette
                // (Dropbox's folds, Drive's triangle joins, OneDrive's lobe gap are transparent, so
                // a template render keeps them) without putting five brand colours down a column
                // whose every other element is quiet. Finder draws its Locations in one ink too.
                //
                // Sized through the same knee curve as the label rather than at a fixed 16, or the
                // mark would shrink against the text at every size above the default.
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
                        // **Tail, unlike the folder row's detail below.** That one is a parent
                        // *path*, where the deepest component is the informative end and the head
                        // is what to drop. This is a qualifier — an account name, or "in iCloud
                        // Drive" — and cutting its head turns "in iCloud Drive" into
                        // "…iCloud Drive", which reads as a truncated path rather than a phrase.
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: Self.rowHeight)
            .background {
                if isCurrent {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(accent.opacity(0.16))
                }
            }
            .contentShape(Rectangle())
            // Drawn rather than left to `.disabled`, which under `hoverAffordance` dims nothing.
            // A source that is not answering and a local folder that is not a source yet are dimmed
            // the same way on purpose: both mean "this row cannot show you anything right now".
            .opacity(source.isDimmed ? 0.45 : 1)
        }
        .buttonStyle(.hoverAffordance(.row, tint: accent))
        .disabled(!source.isAvailable)
        .help(sourceTooltip(source))
        .accessibilityLabel(sourceAccessibilityLabel(source))
        .contextMenu {
            // **Not for the Trash.** It is `revealOnly` — it opens in Finder and is never a pane's
            // scope — so offering to open it in a pane would name an action that cannot happen.
            if source.state != .revealOnly {
                sideItems(enabled: source.isAvailable) { onOpenSourceOnSide(source, $0) }
                Button("Open in New Tab") { onOpenSource(source, true) }
                    .disabled(!source.isAvailable)
            }
            // **The same verb a remembered folder gets, on the rows that had none.** A place row
            // is the one kind of row in this column that could not be put in Favorites or taken
            // out of it, so Favorites held three folders chosen by the app and nothing chosen by
            // the user. `favoriteVerb` returns nil only for the Trash.
            if let verb = SidebarSourceModel.favoriteVerb(for: source) {
                Divider()
                Button(verb) { onToggleSourceFavorite(source) }
            }
            // **Above Remove, and it is the commoner verb of the two.** Ejecting is something a
            // person does to a card every time they finish with one; removing a source is
            // something they do once, if ever.
            if ejectablePaths.contains(FolderSidebarView.mountKey(source.absolutePath)) {
                Divider()
                Button("Eject \(source.name)…") {
                    // **Both halves, or the dialog lies.** It is not enough that SyncCloud holds
                    // this folder as a source: the unmount has to be one that forgets it, which a
                    // network share's is not.
                    let key = FolderSidebarView.mountKey(source.absolutePath)
                    arm(.eject(source, losesItsSource: removableSourceIds.contains(source.id)
                                                       && detachablePaths.contains(key)))
                }
                .disabled(!source.isAvailable)
            }
            // **Last, and behind its own rule.** It is the one item here that changes what the app
            // holds rather than what it is showing, and the row above it is a toggle a user reaches
            // for often — so it sits where a mis-aimed click is least likely to land on it.
            if removableSourceIds.contains(source.id) {
                Divider()
                Button("Remove Source…") { arm(.removeSource(source)) }
            }
        }
    }

    /// **The one spelling of a mount point**, so `ejectablePaths` and a row's `absolutePath` meet.
    ///
    /// A row carries the path the place was built from and the caller builds the set from what
    /// `FileManager.mountedVolumeURLs` returned; those agree today and would stop agreeing the
    /// first time either side gained a trailing slash. `PathBoundary.normalizedRoot` is the rule
    /// `FolderJumpStore` and `MountedVolumeMemory` already key by, so this is the third reader of
    /// one rule rather than a fourth spelling of it.
    public static func mountKey(_ path: String) -> String { PathBoundary.normalizedRoot(path) }

    /// **The tooltip is where the three states are spelled out**, because the row itself only has
    /// room to be dimmed or not.
    private func sourceTooltip(_ source: SidebarSourceRow) -> String {
        guard source.isAvailable else { return "\(source.name) — not available right now" }
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
        return label
    }

    private func row(for row: FolderSidebarRow) -> some View {
        let isCurrent = row.relativePath == currentRelativePath && row.root == currentRoot
        let canOpen = FolderSidebarModel.canOpen(row)
        return Button {
            onOpen(row, FolderSidebarModel.opensInNewTab(NSEvent.modifierFlags))
        } label: {
            HStack(spacing: 6) {
                // **A folder icon in both groups, and the section says which list it is.** The
                // favorite row drew `pin.fill` while the heading read "Pinned"; with the heading
                // reading "Favorites" a pin glyph would be the last surface still saying the old
                // word, and Finder marks its own Favourites with the folder's icon for the same
                // reason. Nothing is lost by the two groups sharing a glyph: `FolderJumpStore`
                // guarantees the lists cannot overlap (`recentPaths` subtracts the favorites), so
                // one folder is never drawn in both.
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
                // The source badge, trailing — it answers "which account", where the detail beneath
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
            // The `Spacer` above is what makes the row the full width of the column, and that is
            // load-bearing rather than cosmetic: a `hoverAffordance` row is clickable only where it
            // paints, so a row sized to its text would be readable across 180pt and clickable
            // across forty. Measured at 359 of 360 device pixels with it, 143 without —
            // `theCurrentRowFillsTheColumn` is what keeps it that way.
            .background {
                // The pane's current folder, marked the way a Mac sidebar marks it. Weight and a
                // tinted glyph were doing this alone, which is legible next to a neighbour and
                // invisible on its own — and this is also what makes the row's real width
                // measurable, which is why `theCurrentRowFillsTheColumn` can exist at all.
                if isCurrent {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(accent.opacity(0.16))
                }
            }
            .contentShape(Rectangle())
            // Drawn rather than left to `.disabled`, which under `hoverAffordance` dims nothing.
            .opacity(canOpen ? 1 : 0.4)
        }
        .buttonStyle(.hoverAffordance(.row, tint: accent))
        .disabled(!canOpen)
        .help(canOpen ? tooltip(row) : "\(row.relativePath) — not available right now")
        .accessibilityLabel("\(row.group.rawValue): \(row.relativePath)"
                            + (row.sourceName.map { " in \($0)" } ?? "")
                            + (canOpen ? "" : ", not available"))
        .contextMenu {
            sideItems(enabled: canOpen) { onOpenRowOnSide(row, $0) }
            Button("Open in New Tab") { onOpen(row, true) }
                .disabled(!canOpen)
            Button(row.group == .pinned ? "Remove from Favorites" : "Add to Favorites") {
                onToggleFavorite(row)
            }
            // **"Take me there" and "show me where that is" are different questions.** The row
            // itself answers the first; this answers the second, which is the one you ask when a
            // name has stopped being enough — two `Legal` folders in one account, or a recent you
            // no longer recognise. Absent rather than disabled for a row at its source's root:
            // there is no enclosing folder a pane can be pointed at, so the item would name a
            // place that does not exist rather than one that is temporarily out of reach.
            // Unavailability is covered by absence too, not by a second `.disabled`:
            // `enclosingFolder` refuses an unavailable row, so the item is simply not here.
            if FolderSidebarModel.enclosingFolder(of: row) != nil {
                Divider()
                Button("Show in Enclosing Folder") { onShowEnclosingFolder(row) }
            }
        }
    }

    /// **"Open in Left Pane" / "Open in Right Pane", and only where there are two.**
    ///
    /// The per-row companion to the target control above. That control is a mode — it says where
    /// every click lands — and a mode is the wrong shape for "this one folder, over there". Both
    /// exist because they answer different questions, and neither is a substitute: flipping the
    /// mode to open one folder and flipping it back is exactly the friction this removes.
    ///
    /// Deliberately does NOT move the target. Picking a side for one folder is not a statement
    /// about the next one, and silently re-aiming the sidebar from a context menu would be a mode
    /// change the user did not ask for and would not see.
    ///
    /// Empty outside Compare, where `target` is nil: naming a left and a right pane in a workspace
    /// that has one would be offering a choice that does not exist.
    @ViewBuilder
    private func sideItems(enabled: Bool, open: @escaping (Bool) -> Void) -> some View {
        if target != nil {
            Button("Open in Left Pane") { open(true) }.disabled(!enabled)
            Button("Open in Right Pane") { open(false) }.disabled(!enabled)
            Divider()
        }
    }

    /// The whole path, always — the row shows a leaf and sometimes a parent, and the tooltip is
    /// where "which of the two Legals is this" is answered without waiting for a collision.
    private func tooltip(_ row: FolderSidebarRow) -> String {
        row.sourceName.map { "\($0) — \(row.relativePath)" } ?? row.relativePath
    }
}
