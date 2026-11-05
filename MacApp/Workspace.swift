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

    /// Every workspace that shows a lens, in bar order.
    static var lensWorkspaces: [Workspace] {
        allCases.filter { $0.lens != nil }
    }

    /// Where a programmatic caller naming a lens should land: the workspace and, inside Organize,
    /// which rail item to select. A caller that set only the workspace would land on the overview
    /// and lose the request, such as "Find duplicates of this" from a Compare row.
    static func destination(for lens: WorkspaceLensKind) -> WorkspaceSelection {
        guard let organizeLens = OrganizeLens(lens) else {
            // Unreachable today: every `WorkspaceLensKind` bridges to a rail item, but
            // `OrganizeLens.init(_:)` stays failable for one added without. Organize's overview is
            // the answer for a lens the rail cannot name. Never `.default`, which would drop a
            // pointed request into Browse.
            return WorkspaceSelection(workspace: .filing, organizeLens: nil)
        }
        // Every case `OrganizeLens.init(_:)` can answer is a rail item — pinned by
        // `OrganizeLensFoldTests.theBridgeAnswersOnlyRailItems` — so a destination minted here is
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

    /// Where a window with nothing it can use opens: Browse, and a file browser is a better place
    /// to land than a comparison of two clouds nothing has scanned yet.
    ///
    /// "Nothing stored" and "unreadable" must agree, and that takes two constants. This one serves
    /// a stored selection that no longer resolves (``migratedWorkspace(_:)``,
    /// ``migrated(tab:lens:)``). A first run never reaches it: `migrateSelection(in:)` leaves the
    /// keys unset, and `ContentView.selectedWorkspace`'s `@AppStorage` default answers.
    /// `theFirstRunDefaultAgreesWithTheFallback` reads both from source, since no test can mount
    /// `ContentView`.
    static let `default` = WorkspaceSelection(workspace: .browse, organizeLens: nil)
}

// MARK: - Migration off the selections this replaces

extension Workspace {

    /// The defaults key holding the flat selection.
    static let defaultsKey = "selectedWorkspace"
    /// The defaults key holding the rail selection inside Organize. Absent means the overview.
    /// Owned by ``OrganizeLens`` because `LensWorkspaceView` reads it directly; aliased here for
    /// the migration below.
    static let organizeLensKey = OrganizeLens.defaultsKey
    /// The two keys the flat bar replaced, read once by ``migrateSelection(in:)``.
    static let legacyTabKey = "selectedBottomTab"
    static let legacyLensKey = "selectedTidyLens"

    /// Raw values that were once a workspace and no longer resolve, and the rail lens each became.
    /// A stored value that does not resolve fails silently (`@AppStorage` takes its default), so
    /// without this someone in Duplicates would reopen on the default workspace with no
    /// explanation.
    ///
    /// Each lands on its own rail item, not just Organize; `Rename` lands on Renames, which hosts
    /// the risky-name findings. A stored rail value of "Names" is a different key and table; see
    /// ``retiredOrganizeLensRawValues``.
    static let retiredWorkspaceRawValues: [String: OrganizeLens] = [
        "Rename": .renames,
        "Duplicates": .duplicates,
        "Automations": .rules,
        // `OrganizeLens.storage` is also `"Storage"`, so someone who quit on the Storage tab
        // reopens on Organize with the Storage rail item selected.
        "Storage": .storage,
    ]

    /// The raw value `Rename` persisted under, as both a Tidy lens and (briefly) a workspace.
    ///
    /// The migration does not read this; `Rename` resolves through ``retiredWorkspaceRawValues``.
    /// Kept for `TopPaneVisibilityTests`, which asserts the retired key does not survive a
    /// fanned-out override map without spelling the legacy string itself.
    static let retiredRenameRawValue = "Rename"

    /// Where a session that ended on the old two-level selection resumes.
    ///
    /// A tab that is not `Tidy` resolves to ``WorkspaceSelection/default``, Browse, so an
    /// unreadable stored value and none at all land in the same place.
    ///
    /// The Tidy arms must not follow it there: they resolve to ``tidyDefault``, a lens, because
    /// someone whose session ended in Tidy was in a lens, and a lens is the nearer answer.
    ///
    /// Reads the legacy pair only. `selectedBottomTab` only ever held `Differences` or `Tidy`, so
    /// there is no `Rename` arm here; a retired workspace value is ``migratedWorkspace(_:)``'s job.
    static func migrated(tab: String?, lens: String?) -> WorkspaceSelection {
        guard tab == "Tidy" else { return .default }
        // On Tidy the lens decided what you were looking at, so it is the destination. A missing
        // or unrecognised lens takes Tidy's own former default.
        guard let lens else { return tidyDefault }
        if let retired = retiredWorkspaceRawValues[lens] {
            return WorkspaceSelection(workspace: .filing, organizeLens: retired)
        }
        // One lens raw value is still a workspace: `Filing`. (`Storage` is caught by the
        // ``retiredWorkspaceRawValues`` branch above.)
        //
        // An allow-list, not a deny-list: a deny-list widens with every new case, and would route
        // a stored workspace value such as `"Editor"` into that workspace.
        guard lens == Workspace.filing.rawValue else { return tidyDefault }
        return WorkspaceSelection(workspace: .filing, organizeLens: .toFile)
    }

    /// Tidy's own former default lens, which was Duplicates — now Organize's duplicates rail item.
    /// Someone whose stored lens no longer reads should land where Tidy used to open, not on
    /// Compare: they were in a lens, so a lens is the nearer answer.
    static let tidyDefault = WorkspaceSelection(workspace: .filing, organizeLens: .duplicates)

    /// Where a stored `selectedWorkspace` that no longer resolves should land.
    ///
    /// The bar has retired cases of its own, so `selectedWorkspace` needs migrating as much as the
    /// legacy pair does, though it looks like it must already be valid.
    static func migratedWorkspace(_ raw: String) -> WorkspaceSelection {
        if let retired = retiredWorkspaceRawValues[raw] {
            return WorkspaceSelection(workspace: .filing, organizeLens: retired)
        }
        return .default
    }

    /// Runs the migration once, at launch, before any view reads the selection.
    ///
    /// Returns the resolved selection so a test can assert what a given stored state migrates to
    /// without reaching back into defaults; nil when there was nothing to do.
    @discardableResult
    static func migrateSelection(in defaults: UserDefaults) -> WorkspaceSelection? {
        if let stored = defaults.string(forKey: defaultsKey) {
            // A stored value that still resolves is the truth; re-running would replace a choice
            // with a stale legacy pair. The rail selection beside it is left alone too.
            guard Workspace(rawValue: stored) == nil else { return nil }
            let resolved = migratedWorkspace(stored)
            write(resolved, to: defaults)
            return resolved
        }
        // Nothing stored at all is a first run, not an upgrade — leave the keys unset so
        // @AppStorage uses its own defaults rather than baking one in here.
        guard defaults.string(forKey: legacyTabKey) != nil
                || defaults.string(forKey: legacyLensKey) != nil else { return nil }

        let resolved = migrated(tab: defaults.string(forKey: legacyTabKey),
                                lens: defaults.string(forKey: legacyLensKey))
        write(resolved, to: defaults)
        return resolved
    }

    /// Rail-lens raw values whose case has been retired, and what each one is now.
    ///
    /// Separate from ``retiredWorkspaceRawValues`` because these were never workspaces — they are
    /// values of ``OrganizeLens`` itself, stored under ``organizeLensKey``.
    ///
    /// `Names` was folded into Renames and its case is gone, so nothing can decode a stored
    /// "Names". It is rewritten here once, at launch, into the stored value.
    static let retiredOrganizeLensRawValues: [String: OrganizeLens] = ["Names": .renames]

    /// Rewrites a stored rail selection whose case no longer exists.
    ///
    /// Its own function, called unconditionally: ``migrateSelection(in:)`` returns before reading
    /// the rail key whenever the stored workspace still resolves, which it does for everyone this
    /// helps. Without it, `@AppStorage` would fall back to the overview with no explanation.
    static func migrateOrganizeLens(in defaults: UserDefaults) {
        guard let stored = defaults.string(forKey: organizeLensKey),
              let replacement = retiredOrganizeLensRawValues[stored] else { return }
        defaults.set(replacement.rawValue, forKey: organizeLensKey)
    }

    /// Writes both halves of a resolved selection.
    ///
    /// The lens key is cleared when there is no lens, or a stale rail item would survive and a
    /// later click on Organize would land on a lens nobody picked.
    private static func write(_ selection: WorkspaceSelection, to defaults: UserDefaults) {
        defaults.set(selection.workspace.rawValue, forKey: defaultsKey)
        if let lens = selection.organizeLens {
            defaults.set(lens.rawValue, forKey: organizeLensKey)
        } else {
            defaults.removeObject(forKey: organizeLensKey)
        }
    }
}
