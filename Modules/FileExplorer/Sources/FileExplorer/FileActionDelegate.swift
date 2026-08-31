import Sync

@MainActor
public protocol FileActionDelegate: Sendable {
    func handleRefresh()
    func handleFocus(_ node: FileNode)
    func handleCopy(_ nodes: [FileNode])
    func handleMove(_ nodes: [FileNode])
    func handleDelete(_ nodes: [FileNode])
    func handleCopyToClipboard(_ nodes: [FileNode], isCut: Bool)
    func handlePaste(_ targetDir: FileNode)
    func handlePasteExplicit(_ targetDir: FileNode, nodes: [FileNode])
    func handlePasteToPath(_ path: String)
    func handleRename(_ node: FileNode)
    func handleCreateFolder(at path: String)
    func handleGetInfo(for path: String)
    func handleSort(_ option: SortOption)
    func handleIgnore(_ nodes: [FileNode])
    func isNodeIgnored(_ node: FileNode, currentPath: String) -> Bool
    /// Opens the destination picker for `nodes` — the absolute "put this in the folder I pick"
    /// verb, as distinct from `handleMove`/`handleCopy`, which put each item where its counterpart
    /// belongs in the opposite pane. `isMove` chooses the verb throughout.
    func handleChooseDestination(_ nodes: [FileNode], isMove: Bool)

    /// Hands `path` to the Editor workspace: switches there, points its rail at the file's folder,
    /// and opens the file.
    ///
    /// **A requirement rather than an extension member with a default**, which is the rule this
    /// protocol states for its cloud-hostile-name members a few lines down and the reason is the
    /// same: a default doing nothing would let a conformer inherit a menu item that silently is not
    /// wired, and the failure has no symptom short of a user clicking it and watching nothing
    /// happen.
    ///
    /// **Editing always HAPPENS in the one editor workspace**, which is why this is a hand-off
    /// rather than an in-place edit: dirty state, the undo stack and the save circuit exist in
    /// exactly one place, and a second writable surface would need its own copy of all three.
    func handleOpenInEditor(_ path: String)
    /// Whether either clipboard holds files to paste — the app's own list or the system
    /// pasteboard, resolved by `ClipboardSource`. Drives the enablement
    /// of the "Paste here" menu items (pasting from an empty clipboard is a silent no-op).
    var clipboardHasItems: Bool { get }

    /// Whether `other` would do the same thing as `self` for every call the pane can make.
    ///
    /// This exists for one reason: `FileTreeView` is `Equatable` so SwiftUI can skip re-evaluating
    /// a pane (and therefore every visible row of it) when nothing it renders from has changed —
    /// and a delegate is one of the things it renders from. SwiftUI cannot answer the question
    /// itself: a delegate is an existential holding closures, and closures are not comparable, so
    /// the default memberwise comparison declares every pane different from its predecessor and
    /// the optimization never engages.
    ///
    /// A conformer answers `true` only when its own *value* inputs match. It may ignore its
    /// closures, but only if they dispatch through reference types or property wrappers that read
    /// live state — a closure that captured a plain snapshot would go stale behind a `true`.
    func isEquivalent(to other: FileActionDelegate) -> Bool

    // MARK: - Cloud-hostile names
    //
    // **These are requirements, not extension members, and that distinction is load-bearing.**
    // Every caller reaches this protocol through an existential (`FileContextMenu.delegate`,
    // `FileTreeView.delegate`), and a method that exists ONLY in a protocol extension is dispatched
    // statically: the existential has no witness for it, so the call binds to the extension's
    // default at compile time and the conformer's override is never reached.
    //
    // This is not hypothetical. `riskyName(for:)` and `handleFixName(_:)` were introduced as
    // extension members, so `if let risky = delegate.riskyName(for: singleNode)` in
    // `FileContextMenu` bound to the `nil` default for every delegate in the app — "Fix name…" was
    // unreachable from the moment it was written, and nothing caught it: the app built, the tests
    // exercised `PaneActionDelegate`'s method directly (where dispatch IS static and correct), and
    // a menu item that is merely absent looks exactly like a menu item that is correctly withheld.
    // Declaring them here puts them in the witness table, which is what makes an override an
    // override. The defaults below are unchanged and still serve conformers that want them.

    /// What is wrong with this node's name for the provider it lives on, or nil when nothing is.
    /// Asked while the menu is being built — i.e. on open — so it costs nothing per row.
    ///
    /// The RAW verdict: it does not consult the kept-names store, because "Fix name…" stays a
    /// sensible offer for a name you previously decided to live with and have now changed your mind
    /// about. The badge, which must stay silent on a kept name, goes through `riskyNameReason`.
    func riskyName(for node: FileNode) -> RiskyName?
    /// Applies that fix, through the same undoable path the batch uses.
    func handleFixName(_ node: FileNode)

    /// Why this NAME will give the provider trouble, or nil when it won't — nil also when the user
    /// has kept it (see `KeptNamesStore`), because a badge is exactly what keeping silences.
    ///
    /// Takes the name rather than the node, and answers a `String` rather than a `RiskyName`, for
    /// one reason: unlike everything else on this protocol it is called **eagerly, per visible row,
    /// per render pass**. A name and a `Bool`-ish answer is all the badge renders from, so nothing
    /// larger needs building — and the pair (name, provider) is precisely what the answer is a
    /// function of, which is what lets `RiskyNameBadgeCache` memoize it. Handing a `FileNode` here
    /// would also put a folder's whole subtree back within reach of a per-row call.
    func riskyNameReason(forName name: String, isDirectory: Bool) -> String?

    /// Whether the user has said they meant this name.
    ///
    /// Separate from `riskyNameReason` returning nil, which conflates "fine" with "kept". The row
    /// menu needs to tell them apart: a fine name is offered nothing, a kept one is offered its way
    /// back.
    func isKeptName(_ name: String) -> Bool

    /// Records "I meant that name", durably, so neither the badge nor Organize's list reports it
    /// again. Reversed by `handleStopKeepingName`.
    func handleKeepName(_ node: FileNode)
    /// Withdraws a keep — the badge returns immediately.
    func handleStopKeepingName(_ node: FileNode)

    // MARK: - Where the file lives
    //
    // Requirements, not extension members, for the reason spelled out above the risky-name block:
    // an extension-only member is dispatched statically through the existential, so the
    // conformer's answer would never be reached and a badge that is merely absent looks exactly
    // like a badge that is correctly withheld.

    /// Whether this row's file sits inside no cloud provider's folder — the `⌂ on this Mac only`
    /// badge's whole question.
    ///
    /// Takes the path and answers a `Bool` for the reason `riskyNameReason` takes a name: unlike
    /// almost everything else here it is called **eagerly, per visible row, per render pass**, so
    /// it must not put a `FileNode`'s whole subtree back within reach of a per-row call, and its
    /// answer must be a function of exactly what a memo can key on (see `HomeOnlyBadgeCache`).
    ///
    /// **False is also the answer for "the question is not live here", and that is deliberate.**
    /// Inside a cloud source's own pane every row is covered by definition, so the badge would be
    /// a mark on everything — the conformer answers false there rather than the pane learning a
    /// second rule about when to ask. See `PaneActionDelegate.isOnThisMacOnly(forPath:)`.
    func isOnThisMacOnly(forPath path: String) -> Bool

    /// Whether this host can open the Duplicates lens on a file. Gates the row menu item, so
    /// a conformer with no workspace behind it (every test stub, any pane that isn't a real
    /// provider view) draws nothing rather than a door that opens onto a no-op.
    var canFindDuplicates: Bool { get }

    /// Opens Duplicates on this file's source and reveals the group holding it — starting a scan
    /// first when there is no current one. Files only: a folder overlap group is a different unit.
    func handleFindDuplicates(_ node: FileNode)

    /// Whether this host can point Organize at a folder. Gates the row menu item for the same
    /// reason `canFindDuplicates` does: a conformer with no workspace behind it draws nothing
    /// rather than a door that opens onto a no-op.
    var canOrganizeFolder: Bool { get }

    /// Opens Organize scoped to this folder and scans it. **Folders only** — the question
    /// "where do the loose files in here belong" has no meaning aimed at a single file, which
    /// already has a home.
    func handleOrganizeFolder(_ node: FileNode)

    /// Opens the Restructure lens scoped to this folder — ROADMAP_V5 §5.10's deliberate route:
    /// the shape question, asked from the row you are standing on. Folders only, gated by
    /// `canOrganizeFolder` like its sibling above (same workspace behind both doors).
    func handleCheckFolderShape(_ node: FileNode)

    /// Whether this host can open the shared file-pair viewer. Gates both Compare items in the row
    /// menu for the reason `canFindDuplicates` gates its own: a conformer with no window behind it
    /// draws nothing rather than a door onto a no-op.
    var canCompareFilePair: Bool { get }

    /// Opens the file-pair viewer — the Compare Copies surface, with the Differences host's
    /// Done-only bar — on two files the reader picked in the panes.
    ///
    /// **Files only, both sides.** A folder pair has nothing this viewer can render, which is the
    /// rule `DifferencesPairCompare.pair(for:paneNames:)` already applies to its own rows; Compare
    /// has a whole workspace for two folders.
    ///
    /// `first` is always the row that was right-clicked; `second` comes either from the OTHER
    /// pane's selection or from this one's, and `secondIsInOtherPane` says which. The host needs
    /// that flag for two reasons: a same-pane pair's subtitle cannot read "iCloud vs iCloud", and
    /// a cross-pane pair is re-ordered so the viewer's two columns match the two panes ON SCREEN
    /// rather than which row happened to be clicked — the subtitle names them left-to-right, and
    /// columns that disagreed with it would be a puzzle. A same-pane pair has no such constraint,
    /// so there `first` does take the left column.
    func handleCompareFilePair(_ first: FileNode, with second: FileNode, secondIsInOtherPane: Bool)

    /// Whether this host can open a folder in a new tab. Gated for the same reason the two above
    /// are: a conformer with no pane strip behind it draws nothing rather than a door onto a no-op.
    var canOpenInNewTab: Bool { get }

    /// Opens this folder in a new tab of the pane the row belongs to — **the discovery route for
    /// tabs**, and the only entry point that opens the new tab somewhere different from the one
    /// you are in. Folders only: a tab is a location.
    func handleOpenInNewTab(_ node: FileNode)

    /// Whether this host keeps a Favorites list at all. Gated like the three above: a conformer
    /// with no sidebar behind it would draw a verb that changes nothing anybody can see.
    var canFavoriteFolder: Bool { get }

    /// Whether this folder is already in Favorites, so the menu can say which way it goes.
    ///
    /// **Read when the menu opens, not held.** A context menu's body runs at open time, which is
    /// what lets this be a live question rather than a snapshot the pane would have to invalidate
    /// itself on — the same reasoning `ignoreStateToken` spells out for the opposite case.
    func isFolderFavorite(_ node: FileNode) -> Bool

    /// Adds this folder to Favorites, or takes it out. **Folders only** — Favorites is a list of
    /// places you go, and a file is not somewhere a pane can be pointed.
    func handleToggleFolderFavorite(_ node: FileNode)

    /// A new tab on the folder the pane is showing — the background menu's version of ⌘T.
    ///
    /// **The only right-click route to a tab that works at ONE tab.** The row menu's "Open in New
    /// Tab" needs a folder under the pointer and the strip's own menu needs a strip, which does not
    /// exist until there are two tabs; without this, the state every install starts in has no mouse
    /// route to a second tab at all.
    func handleNewTab(at path: String)

    /// Whether this pane has a tab to close — false at one tab, where the only thing left to close
    /// is the window, and a menu item reading "Close Tab" that closes the window is a trap.
    var canCloseTab: Bool { get }

    /// Closes the pane's active tab.
    func handleCloseTab()
}

extension FileActionDelegate {
    /// Conservative default: hosts that don't expose their clipboard keep "Paste here"
    /// enabled rather than permanently disabled.
    public var clipboardHasItems: Bool { true }

    /// No-op default so the protocol can grow without every test double having to. The menu item
    /// that reaches this is gated on `isSingleSource` — only the single-source rail draws it, and its host
    /// implements the method — so this arm is never taken from the UI.
    public func handleChooseDestination(_ nodes: [FileNode], isMove: Bool) {}

    /// Assume nothing. A conformer that has not opted in is treated as different from every other
    /// delegate, which is exactly the behaviour every caller had before `isEquivalent` existed:
    /// the pane re-evaluates, as it always did.
    ///
    /// The default is `false` and not `true` deliberately. A wrong `true` is invisible — the pane
    /// silently keeps calling a delegate that should have been replaced, and the symptom surfaces
    /// somewhere else entirely (an action aimed at the previous provider). A wrong `false` costs
    /// only the re-render it was already paying. So the safe answer is the default, and a
    /// conformer opts into the fast path by proving it can.
    public func isEquivalent(to other: FileActionDelegate) -> Bool { false }
}

// MARK: - Fixing one cloud-hostile name in place

/// Rename stopped being a workspace, so the single-file case needs a door of its own: the queue in
/// Organize is for a batch, and this is for the one file you are looking at right now.
///
/// Both are defaulted rather than required. A conformer that has no provider context — every test
/// stub, and any pane that isn't a real provider view — answers "not risky" and never offers the
/// item, which is the correct behaviour for them rather than a stub they are forced to write.
extension FileActionDelegate {
    /// See the requirements above for why these live in the protocol body and only their *defaults*
    /// live here. A conformer with no provider context — every test stub, and any pane that isn't a
    /// real provider view — answers "not risky, not kept" and is offered nothing, which is the
    /// correct behaviour for them rather than a stub they are forced to write.
    public func riskyName(for node: FileNode) -> RiskyName? { nil }
    public func handleFixName(_ node: FileNode) {}
    public func riskyNameReason(forName name: String, isDirectory: Bool) -> String? { nil }
    public func isKeptName(_ name: String) -> Bool { false }
    public func handleKeepName(_ node: FileNode) {}
    public func handleStopKeepingName(_ node: FileNode) {}

    /// No provider context, no badge — the same conservative default the risky-name answers take,
    /// and the one that renders exactly the row every existing caller rendered before ⌂ existed.
    public func isOnThisMacOnly(forPath path: String) -> Bool { false }

    /// No workspace behind it, so no door. See `canFindDuplicates`.
    public var canFindDuplicates: Bool { false }
    public func handleFindDuplicates(_ node: FileNode) {}

    /// Same default, same reason. **Both members are protocol REQUIREMENTS above rather than
    /// extension-only additions**: every caller reaches this through an existential, so a member
    /// that exists only in the extension dispatches statically to the default and a conformer's
    /// override is never reached. That bug shipped once here and made "Fix name…" unreachable
    /// from the day it was written.
    public var canOrganizeFolder: Bool { false }
    public func handleOrganizeFolder(_ node: FileNode) {}
    public func handleCheckFolderShape(_ node: FileNode) {}

    /// Same default, same reason, and declared as requirements above for the same one — an
    /// extension-only member would dispatch statically through the existential and the conformer's
    /// answer would never be reached, which is how "Fix name…" shipped unreachable.
    public var canCompareFilePair: Bool { false }
    public func handleCompareFilePair(_ first: FileNode, with second: FileNode,
                                      secondIsInOtherPane: Bool) {}

    /// Same default, same reason, and declared as requirements above for the same one.
    public var canOpenInNewTab: Bool { false }
    public func handleOpenInNewTab(_ node: FileNode) {}
    public var canFavoriteFolder: Bool { false }
    public func isFolderFavorite(_ node: FileNode) -> Bool { false }
    public func handleToggleFolderFavorite(_ node: FileNode) {}
    public func handleNewTab(at path: String) {}
    public var canCloseTab: Bool { false }
    public func handleCloseTab() {}
}
