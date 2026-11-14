import Foundation
import FileExplorer

/// The one top-level selection: which workspace the window is showing.
///
/// Four segments, four kinds of place rather than four tasks: Browse shows one tree and proposes
/// nothing, Compare holds two trees side by side, Organize is everything the app concludes about
/// one tree, and Edit changes what is inside one file. Everything the app says about a single tree
/// is a lens inside Organize (see ``OrganizeLens``), Storage included, even though Storage only
/// reports and never moves, deletes or evicts a file.
///
/// Edit is a kind of its own because it is the one surface that writes a file's contents. It is
/// the app's only writable text surface on purpose: dirty state, the undo stack and the save
/// circuit live in one place, and every other workspace hands off to it (see `openInEditor`).
/// Browse is its own kind because it is where you go when you want no lens's opinion.
///
/// The layout rule underneath: the left side is always a file browser; the right side is the
/// other cloud (Compare) or a lens. Browse is that rule with the right side taken away.
///
/// The raw values come from the enums this replaced, so a persisted selection survives; they are a
/// stable format pinned by `WorkspaceTests`. `title` is separate from `rawValue` so a display name
/// can change without stranding anyone (`Differences` shows as "Compare", `Filing` as "Organize").
enum Workspace: String, CaseIterable, Identifiable {
    /// One tree, full width, no lens. The plain file browser.
    ///
    /// Declared first, which matters: `allCases` is the bar's order and the workspace chords are
    /// positional (`WorkspaceCommands` and `workspaceSegment` number segments by position).
    case browse = "Browse"
    /// The two provider panes over the Differences workspace. Shown as "Compare".
    case compare = "Differences"
    /// Everything that changes one tree. Shown as "Organize"; the raw value is still `Filing`
    /// because that is what is on disk in every install.
    case filing = "Filing"
    /// One text file, open and writable. The app's only editing surface.
    ///
    /// The raw value `Editor` must never be reworded: it is a persistence format, like `Filing`.
    /// `WorkspaceTests` pins raw values separately from titles so renaming one cannot take the
    /// other with it.
    ///
    /// Declared last, which gives it ⌘4: the chords are positional (`AppChord.workspace(_:)`,
    /// bounded at nine), and the bar badge and the View menu both count `allCases`, so they cannot
    /// disagree about the number.
    case editor = "Editor"

    var id: String { rawValue }

    /// Whether the folder sidebar can appear here. One place, because the View menu item, the
    /// toolbar button and the column all ask, and `FolderSidebarModel.appliesTo` keeps them in step.
    ///
    /// Every workspace. Browse re-roots its full-width pane; Organize re-roots the rail
    /// (`lensScanRootExpanded` reads the targeted pane's directory). Compare re-roots the pane you
    /// are working in (`PaneLogic.lensTargetsRightPane`) and says which, see `SidebarTarget`. Edit
    /// needs it most: the sidebar's folder is what the rail lists, its only way to a second folder.
    ///
    /// No `default:`, so a workspace added later has to be a decision here.
    var supportsFolderSidebar: Bool {
        switch self {
        case .browse, .filing, .compare, .editor: return true
        }
    }

    /// Whether the sidebar stays beside a collapsed pane: `FolderSidebarModel.appliesTo`'s
    /// `outlivesCollapse`. Edit only, where the pane is folded by default and the sidebar still
    /// re-points the Text Files list. Elsewhere a collapse takes the sidebar with it, since a click
    /// would re-root a pane nobody can see. No `default:`, like the property above.
    var folderSidebarOutlivesPaneCollapse: Bool {
        switch self {
        case .editor: return true
        case .browse, .filing, .compare: return false
        }
    }

    /// The label in the workspace bar. Separate from `rawValue` so these can be reworded without
    /// breaking a stored selection.
    var title: String {
        switch self {
        case .browse: return "Browse"
        case .compare: return "Compare"
        case .filing: return "Organize"
        // "Edit", accepting the clash with the Edit menu: the bar is a row of verbs, and "Edit"
        // matches the others. `HelpBookTests` still tells the two apart, because it matches the
        // `Edit ▸ ` path rather than the bare word.
        case .editor: return "Edit"
        }
    }

    /// The bar's glyph. It carries the whole label at narrow widths (see ``WorkspaceBarMetrics``),
    /// so each has to be legible on its own rather than decorative.
    var symbol: String {
        switch self {
        // The plain folder: your files, with nothing done to them. The unbadged form of Organize's
        // glyph, so at icon-only widths the gear badge is all that tells them apart; a glyph more
        // distinct would stop saying "files".
        case .browse: return "folder"
        case .compare: return "arrow.left.arrow.right"
        case .filing: return "folder.badge.gearshape"
        // A sheet with a pencil, the one glyph about a file's contents. 15×15 at 12pt medium, inside
        // `glyphSide` (17): a symbol wider than the frame is clipped, not scaled, and only
        // `theBarDrawsEverySegmentAtOneHeight` would notice.
        case .editor: return "square.and.pencil"
        }
    }

    /// The lens this workspace shows in the right-hand slot, or `nil` for Compare — which shows
    /// the second provider there instead.
    ///
    /// Organize answers `.filing` as its default; which lens is on screen is the rail's business
    /// (``OrganizeLens/searchLens``). The one place the bar maps onto `LensWorkspaceView`'s lens
    /// machinery, which still needs `WorkspaceLensKind` for search grammars and scroll state.
    var lens: WorkspaceLensKind? {
        switch self {
        // Edit shows one open file and has no right-hand slot, so it cannot ride the lens mounting
        // path: `presentLensRail` and `bottomPaneView` answer nothing for a lens-less workspace.
        // See `ContentLayout.editorExpanded` / `.editorCollapsed`.
        case .browse, .compare, .editor: return nil
        case .filing: return .filing
        }
    }

    /// Where a programmatic caller naming a lens should land: the workspace and, inside Organize,
    /// which rail item to select. A caller that set only the workspace would land on the overview
    /// and lose the request, such as "Find duplicates of this" from a Compare row.
    static func destination(for lens: WorkspaceLensKind) -> WorkspaceSelection {
        guard let organizeLens = OrganizeLens(lens) else {
            // Unreachable today: every `WorkspaceLensKind` bridges to a rail item, but
            // `OrganizeLens.init(_:)` stays failable for one added without. Organize's overview is
            // the answer for a lens the rail cannot name. Never Browse, which would drop a pointed
            // request.
            return WorkspaceSelection(workspace: .filing, organizeLens: nil)
        }
        // Every case `OrganizeLens.init(_:)` can answer is a rail item — pinned by
        // `OrganizeLensFoldTests.theRailDrawsEveryLens` — so a destination minted here is
        // always something the rail can select.
        return WorkspaceSelection(workspace: .filing, organizeLens: organizeLens)
    }
}

/// A complete place to be: the workspace, and — inside Organize — which lens.
///
/// `nil` for `organizeLens` means Organize's overview, the rail's unselected state rather than
/// a rail item of its own.
struct WorkspaceSelection: Equatable {
    var workspace: Workspace
    var organizeLens: OrganizeLens?
}

// MARK: - Storage

extension Workspace {

    /// The defaults key holding the flat selection.
    static let defaultsKey = "selectedWorkspace"
}
