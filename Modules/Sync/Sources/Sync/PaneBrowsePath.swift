import Foundation

/// Where a pane is *browsing* inside its loaded tree, as a path relative to that tree's root.
///
/// This is deliberately **not** `leftRelativePath`/`rightRelativePath`. Those are the pane's
/// comparison *scope*: assigning one runs through `focusOn` → `syncPathsFromHistory` →
/// `refreshSubject`, which reloads the tree and re-runs the scan for that subfolder. That is the
/// right behaviour for "Compare only this folder" and the wrong behaviour for walking through
/// columns — browsing must leave the scan scope, and therefore every difference badge, untouched.
///
/// So a pane has two positions and they mean different things:
///
///   - `relativePath` — what is being compared. Changed by `focusOn`; owns the back/forward history.
///   - `PaneBrowsePath` — where you are looking inside it. Changed by clicking a column row; costs
///     no reload, no rescan, and no history entry of its own.
///
/// The header's path line renders the two joined, so the user sees one location rather than this
/// distinction. `‹` pops this path first and only falls through to the focus history once it is
/// empty, which is what makes one Back button serve both (see `FileSyncManager.canGoBack`).
///
/// Empty is the resting state: one column, the tree root's own children, which is exactly the pane
/// that exists today.
public struct PaneBrowsePath: Equatable, Sendable {
    /// Folder names from the tree root down, outermost first. Never contains an empty component.
    public private(set) var components: [String]

    /// Components `popLast` has stepped out of, deepest FIRST — `popLast` appends as it unwinds, so
    /// the shallowest folder is the last one in and the first one `advance` walks back into.
    ///
    /// Decision 10 named only `‹`, but the two arrows are one control in the user's head: drilling
    /// three columns, pressing Back twice and then Forward has to return you to where you were. If
    /// only Back understood columns, Forward would either sit dead or — worse — fire the pane's
    /// *focus* history and jump the comparison somewhere unrelated. Any move that branches
    /// (`drill`, `truncate`) discards this, exactly as a browser drops its forward stack.
    private var forwardComponents: [String]

    public init() {
        components = []
        forwardComponents = []
    }

    public init(components: [String]) {
        self.components = components.filter { !$0.isEmpty }
        forwardComponents = []
    }

    /// Parses a `"Documents/Invoices"`-style relative path; tolerates surrounding and doubled
    /// separators so a caller can hand over a joined path without pre-cleaning it.
    public init(relativePath: String) {
        components = relativePath.split(separator: "/").map(String.init)
        forwardComponents = []
    }

    public var isEmpty: Bool { components.isEmpty }

    /// Number of folders drilled into. The column count is this plus one — the root column is
    /// always present, which is why an empty path still renders a (full-width) column.
    public var depth: Int { components.count }

    /// The browse position as a relative path; `""` at rest.
    public var relativePath: String { components.joined(separator: "/") }

    // MARK: - Navigation

    /// Whether `›` has a column to walk back into. False once you branch.
    public var canAdvance: Bool { !forwardComponents.isEmpty }

    /// Opens `name` from the column at `depth`, discarding any columns beyond it — clicking a
    /// folder in column 1 while three are open closes columns 2 and 3, like Finder.
    public mutating func drill(into name: String, atDepth depth: Int) {
        guard !name.isEmpty else { return }
        components = Array(components.prefix(clamped(depth))) + [name]
        forwardComponents = []
    }

    /// Truncates to `depth` without opening anything — selecting a *file* in a column closes the
    /// columns to its right but adds none of its own.
    public mutating func truncate(toDepth depth: Int) {
        components = Array(components.prefix(clamped(depth)))
        forwardComponents = []
    }

    /// Steps out one level. Returns false when already at the root, which is the signal for `‹`
    /// to fall through to the pane's focus history rather than doing nothing.
    @discardableResult
    public mutating func popLast() -> Bool {
        guard let last = components.popLast() else { return false }
        forwardComponents.append(last)
        return true
    }

    /// Steps back into the column `popLast` left. Returns false when there is none, the signal for
    /// `›` to fall through to the focus history.
    @discardableResult
    public mutating func advance() -> Bool {
        guard let next = forwardComponents.popLast() else { return false }
        components.append(next)
        return true
    }

    /// Back to the resting single column. Called on re-root and on provider change, where the
    /// tree under this path is about to be replaced by an unrelated one.
    public mutating func reset() {
        components = []
        forwardComponents = []
    }

    // MARK: - Resolution against a tree

    /// Absolute directory each open column lists, root column first. Always non-empty.
    public func columnDirectories(treeRoot: String) -> [String] {
        var directory = Self.normalized(treeRoot)
        var directories = [directory]
        for component in components {
            directory += "/" + component
            directories.append(directory)
        }
        return directories
    }

    /// The deepest open directory: the folder New Folder creates into, the folder a paste or a
    /// background drop lands in, and what the pane reports as its current path.
    public func currentDirectory(treeRoot: String) -> String {
        columnDirectories(treeRoot: treeRoot)[depth]
    }

    /// Drops trailing components that no longer resolve to a directory in `index`.
    ///
    /// Load-bearing after every republish. The components are folder names resolved against a tree
    /// that has just been rebuilt, so a folder deleted here (or externally, or by the user's own
    /// Delete) would otherwise leave columns rendering nothing and — worse —
    /// `currentDirectory(treeRoot:)` pointing at a path that no longer exists, which is what New
    /// Folder and paste would then target. Keeping the surviving prefix means a deleted leaf drops
    /// you into its parent instead of nowhere.
    ///
    /// The forward stack is pruned on the same walk. `‹` out of a folder that is then deleted left
    /// `›` enabled pointing at it, and advancing put `currentDirectory(treeRoot:)` — where New
    /// Folder and paste act — on a path that no longer exists. That is the very hazard the live
    /// stack's prune closes, reached through the other arrow.
    public func pruned(against index: PaneChildrenIndex, treeRoot: String) -> PaneBrowsePath {
        var kept: [String] = []
        var directory = Self.normalized(treeRoot)
        for component in components {
            let candidate = directory + "/" + component
            guard index.isDirectory(atPath: candidate) else { break }
            kept.append(component)
            directory = candidate
        }
        var keptForward = forwardComponents
        if kept.count < components.count {
            // The live stack itself moved, so the columns `‹` stepped out of no longer join onto
            // its end — the same rule any branching move follows (see `drill`/`truncate`).
            keptForward = []
        } else {
            // `forwardComponents` is deepest-first, so `advance` re-enters them from the back.
            // Walk in that order and truncate at the first folder that is gone; surviving the
            // first `survived` of the reversed walk means keeping the last `survived` entries.
            var survived = 0
            var forwardDirectory = directory
            for component in forwardComponents.reversed() {
                let candidate = forwardDirectory + "/" + component
                guard index.isDirectory(atPath: candidate) else { break }
                survived += 1
                forwardDirectory = candidate
            }
            if survived < forwardComponents.count {
                keptForward = Array(forwardComponents.suffix(survived))
            }
        }
        // Returning self when nothing was dropped keeps the common case free of an allocation and
        // lets callers compare cheaply to decide whether anything moved.
        guard kept.count != components.count || keptForward.count != forwardComponents.count else {
            return self
        }
        var result = PaneBrowsePath(components: kept)
        result.forwardComponents = keptForward
        return result
    }

    private func clamped(_ depth: Int) -> Int {
        max(0, min(depth, components.count))
    }

    /// Root with trailing slashes stripped, so joining with "/" never doubles a separator (a root
    /// of "/" becomes "" and joins back to "/<component>").
    ///
    /// Public because everything that compares or joins absolute paths has to agree on this, and a
    /// second copy in another module is how "/root" and "/root/" become two different folders.
    /// `DestinationBrowser` and the destination picker both key on it.
    public static func normalized(_ path: String) -> String {
        var root = path
        while root.hasSuffix("/") { root.removeLast() }
        return root
    }
}
