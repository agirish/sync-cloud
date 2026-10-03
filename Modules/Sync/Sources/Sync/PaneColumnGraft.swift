import Events
import Foundation

/// **Filling in one directory the budgeted walk did not read**, so a column can open it.
///
/// `FileSyncManager.paneNodeBudget` stops the pane's deep walk once a tree turns out to be one of
/// the pathological ones — the home folder is 196,726 directories — and everything past the budget
/// comes back marked `isUnexplored`. That is the right answer for a *display*: nothing claims those
/// folders are empty, and nothing downstream mistakes them for empty either. It is not an answer
/// for *navigation*, which is what a Columns pane is for: without this, a column opened on a
/// budgeted-out folder would show nothing for as long as the pane stayed on that root.
///
/// So the walk is deferred rather than skipped. A column that opens an unexplored directory asks
/// for it, one directory listing lands, and the node is replaced in place. This is Finder's model,
/// and it is the model the budget makes necessary — the alternative, re-walking from the root with
/// a bigger budget, re-pays for the whole tree to answer a question about one folder.
extension FileSyncManager {

    /// Replaces the node at `path` with the same node carrying `children`, and clears its
    /// unexplored mark.
    ///
    /// Returns `nil` when the path is not in this tree at all — which is not an error but the
    /// normal outcome of a race: the graft is asked for on the main actor, the listing happens off
    /// it, and by the time it lands the pane may have re-rooted or reloaded. A `nil` says "this
    /// answer is about a tree that is no longer here", and the caller drops it.
    ///
    /// **Found by the names down from `root`, the folder the tree was walked at** — `path` is a
    /// column's, composed from that root and the names clicked, and the walk spells a node otherwise
    /// two levels below a folder symlink and under a root reached through one (`TreeShape`). Matched
    /// by id prefix alone, a budget-unexplored folder there was never found, so its column stayed
    /// blank however often it asked. The id prefix is still the fallback, for the outline, which
    /// asks with a row's id (`TreeShape.position`).
    ///
    /// **The descent enters one branch per level**, so this costs the depth of one path rather than
    /// a walk of the tree. That matters precisely here: the trees this runs against are the ones
    /// large enough to have been budgeted, and a full search of a 200,000-node tree per column open
    /// is the shape (`PaneChildrenIndex`'s own note records it) that once put 16.9 s of node
    /// comparison on the main thread. Only the nodes on the path are rebuilt; a sibling keeps its
    /// subtree's storage, which is what `theDescentSkipsSiblingsSharingANamePrefix` measures, by
    /// buffer identity.
    ///
    /// `isUnexplored` is set to `nil` rather than `false` on the grafted node — the field's own
    /// documentation defines nil as "walked", and it is what a node built by the walk carries.
    /// Writing `false` would be a second spelling of the same fact.
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

    /// Whether the tree, walked at `root`, holds `path` as a directory it did not read — found as
    /// `grafting` finds it.
    ///
    /// The guard for the graft request, and it answers on the RAW tree rather than on the pane's
    /// published one: the published tree is filtered (hidden files, search), so a directory can be
    /// absent from it while being present and unexplored underneath — and a request dropped for
    /// that reason would leave a column permanently blank with no way to retry.
    nonisolated public static func isUnexplored(atPath path: String, under root: String, in tree: [FileNode],
                                                links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders)
    -> Bool {
        guard let position = TreeShape.position(of: path, under: root, in: tree, links: links) else { return false }
        return TreeShape.node(at: position, in: tree)?.isUnexplored == true
    }
}

// MARK: - Requesting one

extension FileSyncManager {

    /// **Which directories have a listing in flight right now.**
    ///
    /// Published because a column cannot otherwise tell the two silent states apart. An unexplored
    /// directory with a request outstanding is *being read*; one whose request has come back and
    /// left the mark in place could not be read at all. Both look identical in the tree — empty
    /// children plus `isUnexplored` — and the column was calling both of them "Can't be read",
    /// which is a claim about the second that is simply false about the first.
    public func columnGraftsInFlightPaths(isLeft: Bool) -> Set<String> {
        Set(columnGraftsInFlight.filter { $0.isLeft == isLeft }.map(\.path))
    }

    /// **Walks one unexplored directory and grafts it into the pane's tree**, so the column that
    /// opened it stops being blank.
    ///
    /// Called from the column that needs it, not from navigation, and safe to call for any
    /// directory at any time: it no-ops unless the path is genuinely a directory this pane's walk
    /// left unread. That matters because the call site is a view's `onAppear`, which fires for
    /// reasons a view cannot see.
    ///
    /// **`maxDepth: 1` — one listing, not a subtree.** A budget here instead would put the same
    /// unbounded walk back, one level down: opening `~/Library` would walk 93,500 directories to
    /// answer a question about its immediate children. One level per column open is Finder's cost,
    /// and each further column pays its own.
    public func loadColumnChildren(atPath path: String, isLeft: Bool) {
        guard !path.isEmpty else { return }
        // A column re-renders for many reasons; without this a slow listing collects a request per
        // render, each walking the same directory.
        let key = ColumnGraftKey(isLeft: isLeft, path: path)
        guard !columnGraftsInFlight.contains(key) else { return }
        // Asked of the tree with the folder it was walked at: a column's `path` is composed from
        // that folder, and the names down from it are what find the node (`TreeShape.position`).
        guard Self.isUnexplored(atPath: path, under: paneTreeFolder(isLeft: isLeft) ?? "",
                                in: isLeft ? rawLeftTree : rawRightTree, links: linkedFolders) else { return }
        columnGraftsInFlight.insert(key)
        // Captured before the await, compared after: a swap in that window moves this path to the
        // other pane, and `key.isLeft` would then name the tree it is NOT about.
        let orientation = paneOrientationGeneration
        // Also captured-and-compared: the sort option. The listing is built in this option's
        // order, and a sort change while it runs re-sorts the live trees before it lands — a
        // graft in the old order would then be the one out-of-order column on screen.
        let builtWith = sortOption

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.columnGraftsInFlight.remove(key) }
            // The one listing can go through a link — the folder opened may be one the walk left
            // unread, or lie below one — so it records what it followed, for the tree it joins.
            let followedLinks = FollowedLinks()
            var children = await Self.buildTree(url: URL(fileURLWithPath: path),
                                                sortOption: builtWith,
                                                fileManager: self.fileManager, maxDepth: 1,
                                                followedLinks: followedLinks)
            guard !Task.isCancelled else { return }
            // **The panes swapped while this ran.** `swapPanes` has already cleared the in-flight
            // set, so the `defer` above removes nothing; what this stops is the graft itself, which
            // would otherwise write a listing taken for one pane into whichever tree `isLeft` now
            // points at. The listing is correct for its absolute path, which is exactly what makes
            // the mistake survivable enough to go unnoticed — two panes on one source would graft
            // it into a tree that really does contain the path, and the wrong pane would fill.
            guard self.paneOrientationGeneration == orientation else { return }
            // An unreadable directory comes back as the ROOT itself marked unexplored, never as a
            // bare `[]` — `buildTree`'s own note explains why. Grafting that would nest the folder
            // inside itself; leaving the node alone keeps its unexplored mark, which is what makes
            // the column say "Can't be read" rather than "Empty". `adoptRawTree` unwraps the same
            // shape for the same reason.
            if children.count == 1, let only = children.first,
               only.isUnexplored == true, only.id == path { return }

            // Re-read the tree AFTER the await: the pane may have re-rooted or reloaded while the
            // listing ran, in which case this answer is about a tree that is gone. `grafting`
            // returns nil for exactly that and the answer is dropped. The folder it was walked at
            // is re-read with it — `adoptRawTree` writes the two together.
            let current = isLeft ? self.rawLeftTree : self.rawRightTree
            let currentRoot = self.paneTreeFolder(isLeft: isLeft) ?? ""
            // **And re-ask the question the graft exists to answer.** The pre-await guard ran
            // against a tree that may have been replaced since: a refresh or the deep walk itself
            // can publish this node FULLY WALKED while the listing runs (the same path is still
            // present, so `grafting` alone would not notice). Grafting then would overwrite a
            // deep subtree with a one-level listing whose child directories are re-marked
            // unexplored — and, through the cache write below, poison the next warm scan. The
            // outline row's open fires this request ungated, so the race is ordinary, not exotic.
            guard Self.isUnexplored(atPath: path, under: currentRoot, in: current, links: self.linkedFolders)
            else { return }
            // A sort change during the listing has already re-sorted the live trees; bring the
            // listing into the same order before it joins them. (The cache write below is safe
            // either way — a sort change clears `prefetchedTrees`, so the `!= nil` guard skips it.)
            if self.sortOption != builtWith {
                children = Self.sort(nodes: children, by: self.sortOption)
            }
            guard let grafted = Self.grafting(children: children, atPath: path, under: currentRoot,
                                              into: current, links: self.linkedFolders) else { return }
            self.rawTreeGeneration += 1
            if isLeft { self.rawLeftTree = grafted } else { self.rawRightTree = grafted }
            // **And what the listing followed joins the walk's record**, for the pane and the entry
            // below alike: a link the budget left unread is listed here for the first time, and a
            // write where it leads must find the tree that now lists it. A target the walk's root
            // already covers is redundant in the record, never wrong.
            let followed = followedLinks.targets
            if isLeft { self.leftTreeLinkTargets.formUnion(followed) } else { self.rightTreeLinkTargets.formUnion(followed) }
            // **The cache gets it too, or the graft is undone by the next navigation.**
            // `loadTree`'s fast path serves `prefetchedTrees[focusPath]` without touching disk, so
            // leaving the ungrafted tree there means walking away and back restores the blank
            // column. It self-heals — the column simply asks again — but only by re-walking the
            // same directory every time, which is exactly the cost this whole mechanism exists to
            // avoid paying twice.
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
