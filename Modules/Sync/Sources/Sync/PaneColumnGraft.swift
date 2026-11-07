import Events
import Foundation

/// Filling in one directory the budgeted walk did not read, so a column can open it.
///
/// `FileSyncManager.paneNodeBudget` stops the pane's deep walk on a huge tree (a home folder can
/// hold ~200,000 directories), and everything past the budget comes back marked `isUnexplored`.
/// Right for display, since nothing claims those folders are empty, but not for navigation: a
/// column opened on one would stay blank. So the walk is deferred, not skipped: a column that
/// opens an unexplored directory asks for it, one listing lands, and the node is replaced in
/// place. Finder's model; re-walking from the root with a bigger budget would re-pay for the
/// whole tree to answer about one folder.
extension FileSyncManager {

    /// Replaces the node at `path` with the same node carrying `children`, and clears its
    /// unexplored mark.
    ///
    /// Returns `nil` when the path is not in this tree, the normal outcome of a race: the graft is
    /// asked for on the main actor, the listing runs off it, and by the time it lands the pane may
    /// have re-rooted or reloaded. The caller drops the answer.
    ///
    /// Found by the names down from `root`, the folder the tree was walked at: `path` is a
    /// column's, composed from that root and the names clicked, and below a folder symlink, or
    /// under a root reached through one, the walk spells a node otherwise (`TreeShape`), so an id
    /// prefix wouldn't find it. The id prefix remains the fallback for the outline, which asks with
    /// a row's id (`TreeShape.position`).
    ///
    /// The descent enters one branch per level, so it costs one path's depth, not a walk of the
    /// tree: these are the trees big enough to be budgeted, and a full search per column open would
    /// stall the main thread. Only nodes on the path are rebuilt; a sibling keeps its subtree's
    /// storage (`theDescentSkipsSiblingsSharingANamePrefix` checks buffer identity).
    ///
    /// `isUnexplored` is set to `nil`, not `false`: nil means "walked", as on a node the walk
    /// built, and `false` would be a second spelling of it.
    nonisolated public static func grafting(children: [FileNode], atPath path: String, under root: String,
                                            into tree: [FileNode],
                                            links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders)
    -> [FileNode]? {
        guard let position = TreeShape.position(of: path, under: root, in: tree, links: links) else { return nil }

        func rebuild(_ nodes: [FileNode], at position: ArraySlice<Int>) -> [FileNode] {
            var nodes = nodes
            let index = position[position.startIndex]
            if position.count == 1 {
                nodes[index].children = children
                nodes[index].isUnexplored = nil
            } else {
                nodes[index].children = rebuild(nodes[index].children ?? [], at: position.dropFirst())
            }
            return nodes
        }
        return rebuild(tree, at: position[...])
    }

    /// Whether the tree, walked at `root`, holds `path` as a directory it did not read, found as
    /// `grafting` finds it.
    ///
    /// The graft request's guard. It reads the raw tree, not the published one: that is filtered
    /// (hidden files, search), so a directory can be missing there yet unexplored underneath, and
    /// dropping the request would leave its column blank for good.
    nonisolated public static func isUnexplored(atPath path: String, under root: String, in tree: [FileNode],
                                                links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders)
    -> Bool {
        guard let position = TreeShape.position(of: path, under: root, in: tree, links: links) else { return false }
        return TreeShape.node(at: position, in: tree)?.isUnexplored == true
    }
}

// MARK: - Requesting one

extension FileSyncManager {

    /// Which directories have a listing in flight right now.
    ///
    /// Published so a column can tell two states that look identical in the tree (empty children
    /// plus `isUnexplored`): one with a request outstanding is being read; one whose request came
    /// back and left the mark could not be read, and only that one says "Can't be read".
    public func columnGraftsInFlightPaths(isLeft: Bool) -> Set<String> {
        Set(columnGraftsInFlight.filter { $0.isLeft == isLeft }.map(\.path))
    }

    /// Walks one unexplored directory and grafts it into the pane's tree, so the column that
    /// opened it stops being blank.
    ///
    /// Called from the column that needs it, and safe for any directory at any time: it no-ops
    /// unless the path is a directory this pane's walk left unread, since the call site is a view's
    /// `onAppear`, which fires for reasons a view can't see.
    ///
    /// `maxDepth: 1`: one listing, not a subtree. A budgeted walk here would put the unbounded walk
    /// back one level down (opening `~/Library` would walk tens of thousands of directories). One
    /// level per column open is Finder's cost, and each further column pays its own.
    ///
    /// - Parameter passive: whether this ask is a tree placeholder's `onAppear`, which fires on
    ///   every scroll past. Only a passive ask honours `columnGraftsUnreadable`. An explicit
    ///   open (a click on the disclosure, a column opening) always retries: an unreadable answer
    ///   can be a slow dataless cloud folder the deadline deferred (`DatalessFolderReads`), and
    ///   opening it again is how a person asks for it once it has downloaded.
    public func loadColumnChildren(atPath path: String, isLeft: Bool, passive: Bool = false) {
        guard !path.isEmpty else { return }
        // A column re-renders for many reasons; without this a slow listing collects a request per
        // render, each walking the same directory.
        let key = ColumnGraftKey(isLeft: isLeft, path: path)
        guard !columnGraftsInFlight.contains(key) else { return }
        // Already tried and unreadable: a scroll past does not ask again until this side is walked
        // afresh. An explicit open does.
        guard !(passive && columnGraftsUnreadable.contains(key)) else { return }
        // Asked of the tree with the folder it was walked at: a column's `path` is composed from
        // that folder, and the names down from it are what find the node (`TreeShape.position`).
        guard Self.isUnexplored(atPath: path, under: paneTreeFolder(isLeft: isLeft) ?? "",
                                in: isLeft ? rawLeftTree : rawRightTree, links: linkedFolders) else { return }
        columnGraftsInFlight.insert(key)
        // Captured before the await, compared after: a swap in that window moves this path to the
        // other pane, and `key.isLeft` would then name the tree it is NOT about.
        let orientation = paneOrientationGeneration
        // Also captured and compared: the sort option. The listing is built in this order, and a
        // sort change while it runs re-sorts the live trees, so a graft in the old order would be
        // the one out-of-order column on screen.
        let builtWith = sortOption
        // And the raw-tree generation, for the unreadable memory alone: a fresh walk (⌘R) while
        // this ran has already cleared that memory, and an answer about the old tree must not
        // re-fill it. Not a guard on the graft, since a sibling graft bumps it too (see
        // `paneOrientationGeneration`).
        let generation = rawTreeGeneration

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.columnGraftsInFlight.remove(key) }
            // The listing can go through a link (the folder opened may be one the walk left unread,
            // or lie below one), so it records what it followed, for the tree it joins.
            let followedLinks = FollowedLinks()
            var children = await Self.buildTree(url: URL(fileURLWithPath: path),
                                                sortOption: builtWith,
                                                fileManager: self.fileManager, maxDepth: 1,
                                                followedLinks: followedLinks,
                                                datalessReads: self.datalessFolderReads)
            guard !Task.isCancelled else { return }
            // The panes swapped while this ran: `swapPanes` has already cleared the in-flight set,
            // and grafting now would write one pane's listing into whichever tree `isLeft` now
            // names. With both panes on one source that tree really holds the path, so the wrong
            // pane would quietly fill.
            guard self.paneOrientationGeneration == orientation else { return }
            // An unreadable directory comes back as the root itself marked unexplored, never as a
            // bare `[]` (see `buildTree`). Grafting that would nest the folder inside itself;
            // leaving the node keeps its unexplored mark, so the column says "Can't be read", not
            // "Empty". `adoptRawTree` unwraps the same shape for the same reason.
            if Self.isUnreadableRootWalk(children, at: path) {
                if self.rawTreeGeneration == generation { self.columnGraftsUnreadable.insert(key) }
                Logger.shared.info("[graft] \(isLeft ? "left" : "right") could not be read at “\(path)”")
                return
            }

            // Re-read the tree AFTER the await: the pane may have re-rooted or reloaded while the
            // listing ran, in which case this answer is about a tree that is gone. `grafting`
            // returns nil for exactly that and the answer is dropped. The folder it was walked at
            // is re-read with it, since `adoptRawTree` writes the two together.
            let current = isLeft ? self.rawLeftTree : self.rawRightTree
            let currentRoot = self.paneTreeFolder(isLeft: isLeft) ?? ""
            // And re-ask whether it is still unexplored: a refresh or the deep walk can publish this
            // node fully walked while the listing runs, at the same path, so `grafting` alone
            // wouldn't notice. Grafting then would replace a deep subtree with a one-level listing
            // whose child folders read unexplored, and the cache write below would carry that into
            // the next warm scan. The outline row fires this request ungated, so the race is common.
            guard Self.isUnexplored(atPath: path, under: currentRoot, in: current, links: self.linkedFolders)
            else { return }
            // A sort change during the listing has already re-sorted the live trees; bring the
            // listing into the same order before it joins them. (The cache write below is safe
            // either way: a sort change clears `prefetchedTrees`, so the `!= nil` guard skips it.)
            if self.sortOption != builtWith {
                children = Self.sort(nodes: children, by: self.sortOption)
            }
            guard let grafted = Self.grafting(children: children, atPath: path, under: currentRoot,
                                              into: current, links: self.linkedFolders) else { return }
            self.rawTreeGeneration += 1
            if isLeft { self.rawLeftTree = grafted } else { self.rawRightTree = grafted }
            // What the listing followed joins the walk's record, for the pane and the cache entry
            // below: a link the budget left unread is listed here for the first time, and a write
            // where it leads must find the tree that now lists it. A target the walk's root already
            // covers is redundant, never wrong.
            let followed = followedLinks.targets
            if isLeft { self.leftTreeLinkTargets.formUnion(followed) } else { self.rightTreeLinkTargets.formUnion(followed) }
            // The graft followed links out of the pane's folder: watch where they lead now, not
            // at the next load.
            if !followed.isEmpty { self.updateFolderWatch() }
            // The cache gets it too, or the next navigation undoes the graft: `loadTree`'s fast
            // path serves `prefetchedTrees[focusPath]` without touching disk, so walking away and
            // back would restore the blank column and re-walk the same directory every time.
            if let focus = isLeft ? self.lastLoadedLeftFocusPath : self.lastLoadedRightFocusPath,
               self.prefetchedTrees[focus] != nil {
                self.prefetchedTrees[focus] = grafted
                if !followed.isEmpty { self.prefetchedTreeLinkTargets[focus, default: []].formUnion(followed) }
            }
            await self.applyFilters()
            Logger.shared.debug("[graft] \(isLeft ? "left" : "right") filled \(children.count) entries at “\(path)”")
        }
    }
}
