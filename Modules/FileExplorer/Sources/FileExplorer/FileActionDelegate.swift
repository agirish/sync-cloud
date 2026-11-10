import SwiftUI
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
    /// Opens the destination picker for `nodes`: "put this in the folder I pick", unlike
    /// `handleMove`/`handleCopy`, which put each item at its counterpart in the other pane.
    func handleChooseDestination(_ nodes: [FileNode], isMove: Bool)

    /// Hands `path` to the Editor workspace: switches there, points its rail at the file's folder,
    /// and opens the file. A requirement, not a defaulted extension member, so no conformer can
    /// inherit a menu item that silently does nothing. A hand-off, not an in-place edit, because
    /// dirty state, undo and saving live only in the one editor workspace.
    func handleOpenInEditor(_ path: String)
    /// Whether either clipboard (the app's own list or the system pasteboard, via
    /// `ClipboardSource`) holds files to paste. Enables the "Paste here" menu items.
    var clipboardHasItems: Bool { get }

    /// Whether `other` would do the same thing as `self` for every call the pane can make.
    /// `FileTreeView` is `Equatable` so SwiftUI can skip re-rendering a pane, and a delegate holds
    /// closures, which aren't comparable, so the pane needs this answer from the conformer.
    ///
    /// Answer `true` only when the *value* inputs match. Closures may be ignored only if they read
    /// live state through reference types or property wrappers; a captured snapshot would go stale
    /// behind a `true`.
    func isEquivalent(to other: FileActionDelegate) -> Bool

    // MARK: - Cloud-hostile names
    //
    // **Every member here must be a requirement, not only an extension member.** Callers reach
    // this protocol through an existential (`FileContextMenu.delegate`, `FileTreeView.delegate`),
    // and an extension-only method has no witness: the call binds to the extension's default at
    // compile time and the conformer's override is never reached. Nothing flags it, because an
    // absent menu item looks just like a correctly withheld one. The defaults below still serve
    // conformers that want them.

    /// What is wrong with this node's name for its provider, or nil. Asked only when the menu is
    /// built. The raw verdict, ignoring kept names, so "Fix name" stays on offer for a name the
    /// user once kept; the badge goes through `riskyNameReason` instead.
    func riskyName(for node: FileNode) -> RiskyName?
    /// Applies that fix, through the same undoable path the batch uses.
    func handleFixName(_ node: FileNode)

    /// Why this name will give the provider trouble, or nil when it won't or the user has kept it
    /// (`KeptNamesStore`). Called per visible row on every render, so it takes a name and answers a
    /// `String`: that pair is all the badge needs, lets `RiskyNameBadgeCache` memoize it, and keeps
    /// a folder's subtree out of reach of a per-row call.
    func riskyNameReason(forName name: String, isDirectory: Bool) -> String?

    /// Why the Editor workspace would refuse this row, in the row tooltip's words, or `nil` when it
    /// would open it or this delegate doesn't serve the Editor. Per-row like `riskyNameReason`, so
    /// only the two cheap refusals: kind (path math) and size (already on the row). Cloud-only is
    /// left to the editor, which says "Not downloaded" on the click.
    func editorRefusal(forPath path: String, isDirectory: Bool, size: Int) -> String?


    /// Whether the user has said they meant this name. `riskyNameReason` returning nil can't tell
    /// "fine" from "kept", and the row menu offers a kept name its way back.
    func isKeptName(_ name: String) -> Bool

    /// Records "I meant that name", durably, so neither the badge nor Organize's list reports it
    /// again. Reversed by `handleStopKeepingName`.
    func handleKeepName(_ node: FileNode)
    /// Withdraws a keep — the badge returns immediately.
    func handleStopKeepingName(_ node: FileNode)

    /// Whether this host can open the Duplicates lens on a file. Gates the row menu item, so a
    /// conformer with no workspace behind it (every test stub) draws nothing rather than a no-op.
    var canFindDuplicates: Bool { get }

    /// Opens Duplicates on this file's source and reveals the group holding it — starting a scan
    /// first when there is no current one. Files only: a folder overlap group is a different unit.
    func handleFindDuplicates(_ node: FileNode)

    /// Whether this host can point Organize at a folder. Gates the row menu item, as
    /// `canFindDuplicates` does.
    var canOrganizeFolder: Bool { get }

    /// Opens Organize scoped to this folder and scans it. Folders only: a single file already has
    /// a home.
    func handleOrganizeFolder(_ node: FileNode)

    /// Opens the Restructure lens scoped to this folder, to ask the shape question from the row
    /// you are on. Folders only, gated by `canOrganizeFolder` (same workspace behind both).
    func handleCheckFolderShape(_ node: FileNode)

    /// Whether this host can open the shared file-pair viewer. Gates both Compare items in the row
    /// menu, as `canFindDuplicates` gates its own.
    var canCompareFilePair: Bool { get }

    /// Opens the file-pair viewer (Compare Copies, with the Differences host's Done-only bar) on
    /// two files picked in the panes. Files only: this viewer can't render a folder pair, as
    /// `DifferencesPairCompare.pair(for:paneNames:)` also rules.
    ///
    /// `first` is the right-clicked row; `secondIsInOtherPane` says where `second` came from. A
    /// same-pane pair needs its own subtitle (not "iCloud vs iCloud"), and a cross-pane pair is
    /// reordered so the viewer's columns match the panes on screen. A same-pane pair puts `first`
    /// on the left.
    func handleCompareFilePair(_ first: FileNode, with second: FileNode, secondIsInOtherPane: Bool)

    /// Arms `node` for comparison and puts the window into pick mode: the next file clicked, in
    /// either pane, becomes its counterpart. Offered on every file row, unlike the two items
    /// above, so the menu always has a Compare door; see ``PaneComparePairMenu``.
    func handleArmComparePick(_ node: FileNode)

    /// The path armed for comparison, or nil when no pick is live; a row asks it to decide whether
    /// it wears the marker. A path, not a per-row flag, so the marker survives the selection moving
    /// panes, a scroll, and navigating away and back. Answered from the host's one `ComparePick`.
    var armedComparePath: String? { get }

    /// Whether this host can open a folder in a new tab. Gated like the doors above: a conformer
    /// with no pane strip behind it draws nothing rather than a no-op.
    var canOpenInNewTab: Bool { get }

    /// Opens this folder in a new tab of the row's pane: the discovery route for tabs, and the only
    /// one that opens the tab somewhere other than where you are. Folders only: a tab is a place.
    func handleOpenInNewTab(_ node: FileNode)

    /// Whether this host keeps a Favorites list at all. Gated like the doors above: with no
    /// sidebar behind it, the verb would change nothing anybody can see.
    var canFavoriteFolder: Bool { get }

    /// Whether this folder is already in Favorites, so the menu can say which way it goes. Read
    /// when the row renders, not on the click, so the item acts on what its label said
    /// (`FileContextMenu.favoriteLabelStillHolds`) rather than toggling whatever is true by then.
    func isFolderFavorite(_ node: FileNode) -> Bool

    /// Adds this folder to Favorites, or takes it out. Folders only: Favorites lists places a pane
    /// can be pointed at.
    func handleToggleFolderFavorite(_ node: FileNode)

    /// A new tab on the folder the pane shows, the background menu's ⌘T. The only right-click route
    /// to a second tab at one tab: the row item needs a folder under the pointer, and the strip's
    /// menu needs a strip, which appears only at two tabs.
    func handleNewTab(at path: String)

    /// Whether this pane has a tab to close. False at one tab, where "Close Tab" would close the
    /// window.
    var canCloseTab: Bool { get }

    /// Closes the pane's active tab.
    func handleCloseTab()

    /// Whether this host can run the PDF tools on a row's files. Gated like the doors above: a
    /// conformer with no window behind it draws no PDF Tools submenu.
    var canRunPDFTools: Bool { get }

    /// Runs one of Edit's whole-file PDF tools from a row's menu, on one PDF (or several for Rotate
    /// All Pages, Compress and Clean Metadata). Each tool writes a new copy beside the original and
    /// never touches it. The window re-reads each file in the PDFKit lane before running; the menu
    /// only says what it offered.
    func handlePDFTool(_ request: PDFToolRequest, paths: [String])

    /// Whether this host can save a row's files as PDF. Gated like PDF Tools: a conformer with no
    /// window behind it draws no Save as PDF item rather than one that does nothing.
    var canSaveAsPDF: Bool { get }

    /// Saves each file as a PDF beside it — Word, Excel, PowerPoint, rich text, Markdown or text
    /// (``SaveAsPDFKind``). The original is only read; the PDF is a new file, under the original's
    /// name or the next free one.
    func handleSaveAsPDF(paths: [String])

    // MARK: - Ask Claude (TE263)

    /// Whether this host has Ask Claude behind it. Gated like the doors above: a conformer with no
    /// window behind it draws no Ask Claude items rather than ones that do nothing.
    var canAskClaude: Bool { get }

    /// Why Ask Claude can't take these rows now — one is hidden from Claude — in the words the
    /// item's tooltip shows, or nil when it can. Asked when the menu is built and again on the
    /// click.
    func askClaudeRefusal(_ nodes: [FileNode]) -> String?

    /// Opens Ask Claude with these rows attached above its text box.
    func handleAskClaude(_ nodes: [FileNode])

    /// File with Claude: Ask Claude opens and asks to file these rows, with them attached.
    /// Refused by ``askClaudeRefusal(_:)`` as Ask Claude About This is.
    func handleFileWithClaude(_ nodes: [FileNode])

    /// Whether this row is on the Hidden from Claude list, itself or through a folder above it.
    /// Read when the menu is built, so the label can be a render old; the item acts on what its
    /// label said (`FileContextMenu.favoriteLabelStillHolds`), as Favorites does.
    func isHiddenFromClaude(_ node: FileNode) -> Bool

    /// The folder that hides this row when its entry is a folder above it, by name, or nil:
    /// Show to Claude takes that whole folder off the list, so the item says so.
    func hiddenFromClaudeCover(_ node: FileNode) -> String?

    /// Puts this row on the Hidden from Claude list, or takes it off.
    func handleSetHiddenFromClaude(_ node: FileNode, hidden: Bool)
}

extension FileActionDelegate {
    /// Conservative default: hosts that don't expose their clipboard keep "Paste here"
    /// enabled rather than permanently disabled.
    public var clipboardHasItems: Bool { true }

    /// No-op default so test doubles needn't implement it. Its menu item is drawn only by the
    /// single-source rail (`isSingleSource`), whose host implements it.
    public func handleChooseDestination(_ nodes: [FileNode], isMove: Bool) {}

    /// Assume nothing: a conformer that hasn't opted in is never equivalent, so the pane
    /// re-renders. `false` because a wrong `true` is invisible (the pane keeps calling a stale
    /// delegate and acts on the previous provider), while a wrong `false` costs only a re-render.
    public func isEquivalent(to other: FileActionDelegate) -> Bool { false }
}

// MARK: - Fixing one cloud-hostile name in place

/// Fixing one file's name from its row: Organize's queue is for a batch, this is for the file
/// you are looking at.
extension FileActionDelegate {
    /// Only the defaults live here; the members are requirements above (see that MARK). A conformer
    /// with no provider context, such as a test stub, answers "not risky, not kept" and is offered
    /// nothing.
    public func riskyName(for node: FileNode) -> RiskyName? { nil }
    public func handleFixName(_ node: FileNode) {}
    public func riskyNameReason(forName name: String, isDirectory: Bool) -> String? { nil }
    public func editorRefusal(forPath path: String, isDirectory: Bool, size: Int) -> String? { nil }
    public func isKeptName(_ name: String) -> Bool { false }
    public func handleKeepName(_ node: FileNode) {}
    public func handleStopKeepingName(_ node: FileNode) {}

    /// No workspace behind it, so no door. See `canFindDuplicates`.
    public var canFindDuplicates: Bool { false }
    public func handleFindDuplicates(_ node: FileNode) {}

    /// Same default, same reason. These are requirements above too: an extension-only member would
    /// dispatch statically through the existential and never reach the conformer's override.
    public var canOrganizeFolder: Bool { false }
    public func handleOrganizeFolder(_ node: FileNode) {}
    public func handleCheckFolderShape(_ node: FileNode) {}

    /// Same default, same reason, and declared as requirements above for the same one.
    public var canCompareFilePair: Bool { false }
    public func handleCompareFilePair(_ first: FileNode, with second: FileNode,
                                      secondIsInOtherPane: Bool) {}
    public func handleArmComparePick(_ node: FileNode) {}
    public var armedComparePath: String? { nil }

    /// Same default, same reason, and declared as requirements above for the same one.
    public var canOpenInNewTab: Bool { false }
    public func handleOpenInNewTab(_ node: FileNode) {}
    public var canFavoriteFolder: Bool { false }
    public func isFolderFavorite(_ node: FileNode) -> Bool { false }
    public func handleToggleFolderFavorite(_ node: FileNode) {}
    public func handleNewTab(at path: String) {}
    public var canCloseTab: Bool { false }
    public func handleCloseTab() {}

    /// Same default, same reason, and declared as requirements above for the same one.
    public var canRunPDFTools: Bool { false }
    public func handlePDFTool(_ request: PDFToolRequest, paths: [String]) {}
    public var canSaveAsPDF: Bool { false }
    public func handleSaveAsPDF(paths: [String]) {}

    /// Same default, same reason, and declared as requirements above for the same one.
    public var canAskClaude: Bool { false }
    public func askClaudeRefusal(_ nodes: [FileNode]) -> String? { nil }
    public func handleAskClaude(_ nodes: [FileNode]) {}
    public func handleFileWithClaude(_ nodes: [FileNode]) {}
    public func isHiddenFromClaude(_ node: FileNode) -> Bool { false }
    public func hiddenFromClaudeCover(_ node: FileNode) -> String? { nil }
    public func handleSetHiddenFromClaude(_ node: FileNode, hidden: Bool) {}
}

// MARK: - Ask Claude About This (TE263)

/// The row menu's Ask Claude items: Ask Claude About This (or About These N Items), File with
/// Claude, and for one row Hide from Claude or Show to Claude. Its own view so the pane
/// rows and a test can draw it.
struct AskClaudeMenuItems: View {
    let nodes: [FileNode]
    let delegate: FileActionDelegate

    static func askTitle(_ count: Int) -> String {
        count == 1 ? "Ask Claude About This" : "Ask Claude About These \(count) Items"
    }

    /// One title however many rows: Ask Claude About These N Items, just above, counts them.
    static let fileTitle = "File with Claude"

    static func fileHelp(_ nodes: [FileNode]) -> String {
        let folders = nodes.filter(\.isDirectory).count
        if folders == 0 { return "Asks Claude where \(nodes.count == 1 ? "this goes" : "these go"). Nothing moves until you press Apply." }
        if folders == nodes.count {
            return "Asks Claude to file the loose files in \(folders == 1 ? "this folder" : "these folders"). Nothing moves until you press Apply."
        }
        return "Asks Claude where these go, and to file the loose files in each folder. Nothing moves until you press Apply."
    }

    static func hideTitle(hidden: Bool, cover: String?) -> String {
        guard hidden else { return "Hide from Claude" }
        return cover.map { "Show “\($0)” to Claude" } ?? "Show to Claude"
    }

    var body: some View {
        let refusal = delegate.askClaudeRefusal(nodes)
        Button {
            // Checked again: the menu can be a render old, and the folder hidden since.
            guard delegate.askClaudeRefusal(nodes) == nil else { return }
            delegate.handleAskClaude(nodes)
        } label: {
            Label(Self.askTitle(nodes.count), systemImage: "bubble.left.and.text.bubble.right")
        }
        .disabled(refusal != nil)
        .help(refusal ?? "Opens Ask Claude with \(nodes.count == 1 ? "this" : "these") attached, for your question.")
        // The same rows, with the question asked. After Ask, so the two Claude items sit
        // together with Hide from Claude after them.
        Button {
            guard delegate.askClaudeRefusal(nodes) == nil else { return }
            delegate.handleFileWithClaude(nodes)
        } label: {
            Label(Self.fileTitle, systemImage: "tray.and.arrow.down")
        }
        .disabled(refusal != nil)
        .help(refusal ?? Self.fileHelp(nodes))
        if nodes.count == 1, let node = nodes.first {
            let hidden = delegate.isHiddenFromClaude(node)
            // Hidden by a folder above it: Show takes that folder off the list, and all it holds
            // with it, so the item names it rather than reading as this row alone.
            let cover = hidden ? delegate.hiddenFromClaudeCover(node) : nil
            Button {
                guard FileContextMenu.favoriteLabelStillHolds(labelSaidFavorite: hidden,
                                                              isFavoriteNow: delegate.isHiddenFromClaude(node))
                else { return }
                delegate.handleSetHiddenFromClaude(node, hidden: !hidden)
            } label: {
                Label(Self.hideTitle(hidden: hidden, cover: cover), systemImage: hidden ? "eye" : "eye.slash")
            }
            .help(!hidden ? "Puts it on the Hidden from Claude list: Claude is never told it’s there, or what’s in it."
                  : cover.map { "It’s hidden because \($0) is. This takes \($0) off the Hidden from Claude list, with everything in it." }
                  ?? "Takes it off the Hidden from Claude list.")
        }
    }
}
