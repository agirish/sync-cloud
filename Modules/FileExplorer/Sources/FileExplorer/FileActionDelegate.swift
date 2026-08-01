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
    /// Whether the app's internal clipboard holds items to paste — drives the enablement
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
}

extension FileActionDelegate {
    /// Conservative default: hosts that don't expose their clipboard keep "Paste here"
    /// enabled rather than permanently disabled.
    public var clipboardHasItems: Bool { true }

    /// No-op default so the protocol can grow without every test double having to. The menu item
    /// that reaches this is gated on `isSingleSource` — only the Tidy rail draws it, and its host
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
    /// What is wrong with this node's name for the provider it lives on, or nil when nothing is.
    /// Asked while the menu is being built — i.e. on open — so it costs nothing per row.
    func riskyName(for node: FileNode) -> RiskyName? { nil }
    /// Applies that fix, through the same undoable path the batch uses.
    func handleFixName(_ node: FileNode) {}
}
