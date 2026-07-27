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

    /// Components `popLast` has stepped out of, deepest last, so `›` can walk back in.
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
    public func pruned(against index: PaneChildrenIndex, treeRoot: String) -> PaneBrowsePath {
        var kept: [String] = []
        var directory = Self.normalized(treeRoot)
        for component in components {
            let candidate = directory + "/" + component
            guard index.isDirectory(atPath: candidate) else { break }
            kept.append(component)
            directory = candidate
        }
        // Returning self when nothing was dropped keeps the common case free of an allocation and
        // lets callers compare cheaply to decide whether anything moved.
        return kept.count == components.count ? self : PaneBrowsePath(components: kept)
    }

    private func clamped(_ depth: Int) -> Int {
        max(0, min(depth, components.count))
    }

    /// Root with trailing slashes stripped, so joining with "/" never doubles a separator (a root
    /// of "/" becomes "" and joins back to "/<component>").
    static func normalized(_ path: String) -> String {
        var root = path
        while root.hasSuffix("/") { root.removeLast() }
        return root
    }
}
