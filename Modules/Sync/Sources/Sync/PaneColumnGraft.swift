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
    /// **The descent is pruned by prefix**, so this costs the depth of one path rather than a walk
    /// of the tree. That matters precisely here: the trees this runs against are the ones large
    /// enough to have been budgeted, and a full search of a 200,000-node tree per column open is
    /// the shape (`PaneChildrenIndex`'s own note records it) that once put 16.9 s of node
    /// comparison on the main thread.
    ///
    /// **The trailing separator on that prefix is an optimisation, not a correctness guard**, and
    /// this comment said the opposite until a mutation test disagreed. Dropping it makes `/r/bc`
    /// read as living under `/r/b`, but the graft still lands on the right node: the match is an
    /// exact `id ==`, and a well-formed tree cannot hold `/r/bc` inside `/r/b`, so the wrong branch
    /// is entered and left empty-handed. What it costs is the entry — `visit` rebuilds every node
    /// it walks, so a prefix-sharing sibling gets its whole subtree copied for nothing. That is
    /// what `theDescentSkipsSiblingsSharingANamePrefix` measures, by buffer identity.
    ///
    /// `isUnexplored` is set to `nil` rather than `false` on the grafted node — the field's own
    /// documentation defines nil as "walked", and it is what a node built by the walk carries.
    /// Writing `false` would be a second spelling of the same fact.
    nonisolated public static func grafting(children: [FileNode], atPath path: String,
                                            into tree: [FileNode]) -> [FileNode]? {
        var found = false

        func visit(_ nodes: [FileNode]) -> [FileNode] {
            nodes.map { node -> FileNode in
                guard !found, node.isDirectory else { return node }
                if node.id == path {
                    found = true
                    var replaced = node
                    replaced.children = children
                    replaced.isUnexplored = nil
                    return replaced
                }
                // Only the one branch that can contain `path`. The trailing separator is what makes
                // this a path-component test rather than a string test: without it `/a/bc` reads as
                // living under `/a/b`, and the descent would go down the wrong branch and report
                // not-found for a path that is there.
                guard path.hasPrefix(node.id + "/") else { return node }
                var copy = node
                copy.children = visit(node.children ?? [])
                return copy
            }
        }

        let result = visit(tree)
        return found ? result : nil
    }

    /// Whether the tree holds `path` as a directory it did not read.
    ///
    /// The guard for the graft request, and it answers on the RAW tree rather than on the pane's
    /// published one: the published tree is filtered (hidden files, search), so a directory can be
    /// absent from it while being present and unexplored underneath — and a request dropped for
    /// that reason would leave a column permanently blank with no way to retry.
    nonisolated public static func isUnexplored(atPath path: String, in tree: [FileNode]) -> Bool {
        func visit(_ nodes: [FileNode]) -> Bool? {
            for node in nodes where node.isDirectory {
                if node.id == path { return node.isUnexplored == true }
                if path.hasPrefix(node.id + "/"), let answer = visit(node.children ?? []) { return answer }
            }
            return nil
        }
        return visit(tree) ?? false
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
        guard Self.isUnexplored(atPath: path, in: isLeft ? rawLeftTree : rawRightTree) else { return }
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
            var children = await Self.buildTree(url: URL(fileURLWithPath: path),
                                                sortOption: builtWith,
                                                fileManager: self.fileManager, maxDepth: 1)
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
            // returns nil for exactly that and the answer is dropped.
            let current = isLeft ? self.rawLeftTree : self.rawRightTree
            // **And re-ask the question the graft exists to answer.** The pre-await guard ran
            // against a tree that may have been replaced since: a refresh or the deep walk itself
            // can publish this node FULLY WALKED while the listing runs (the same path is still
            // present, so `grafting` alone would not notice). Grafting then would overwrite a
            // deep subtree with a one-level listing whose child directories are re-marked
            // unexplored — and, through the cache write below, poison the next warm scan. The
            // outline row's open fires this request ungated, so the race is ordinary, not exotic.
            guard Self.isUnexplored(atPath: path, in: current) else { return }
            // A sort change during the listing has already re-sorted the live trees; bring the
            // listing into the same order before it joins them. (The cache write below is safe
            // either way — a sort change clears `prefetchedTrees`, so the `!= nil` guard skips it.)
            if self.sortOption != builtWith {
                children = Self.sort(nodes: children, by: self.sortOption)
            }
            guard let grafted = Self.grafting(children: children, atPath: path, into: current) else { return }
            self.rawTreeGeneration += 1
            if isLeft { self.rawLeftTree = grafted } else { self.rawRightTree = grafted }
            // **The cache gets it too, or the graft is undone by the next navigation.**
            // `loadTree`'s fast path serves `prefetchedTrees[focusPath]` without touching disk, so
            // leaving the ungrafted tree there means walking away and back restores the blank
            // column. It self-heals — the column simply asks again — but only by re-walking the
            // same directory every time, which is exactly the cost this whole mechanism exists to
            // avoid paying twice.
            if let focus = isLeft ? self.lastLoadedLeftFocusPath : self.lastLoadedRightFocusPath,
               self.prefetchedTrees[focus] != nil {
                self.prefetchedTrees[focus] = grafted
            }
            await self.applyFilters()
            Logger.shared.debug("[graft] \(isLeft ? "left" : "right") filled \(children.count) entries at “\(path)”")
        }
    }
}
