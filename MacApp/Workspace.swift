import Foundation
import FileExplorer

/// The one top-level selection: which workspace the window is showing.
///
/// Three segments, and they are three different *kinds of place* rather than three tasks:
/// **Compare** holds two trees side by side, **Storage** reads one tree and changes nothing, and
/// **Organize** changes one tree. Everything that moves a file inside a single tree is a lens
/// inside Organize (see ``OrganizeLens``) — duplicates and automations included, which is what
/// took the bar from five segments to three.
///
/// The layout rule underneath is unchanged and is why the fold is cheap: **the left side is always
/// a file browser; the right side is either the other cloud (Compare) or a lens (everything
/// else).** Folding two workspaces in moved nothing across that line.
///
/// The raw values are deliberately inherited from the enums this has collapsed over time, so a
/// persisted selection survives: `Differences` and `Tidy` came from `ContentView.BottomTab`, and
/// `Duplicates` / `Rename` / `Filing` / `Automations` / `Storage` from `TidyLens`. They are a
/// stable persistence format — see `WorkspaceTests`. As with the enums before it, `title` is
/// separate from `rawValue` precisely so a display name can change without stranding anyone
/// (`Differences` shows as "Compare", `Filing` as "Organize").
enum Workspace: String, CaseIterable, Identifiable {
    /// The two provider panes over the Differences workspace. Shown as "Compare".
    case compare = "Differences"
    /// Everything that changes one tree. Shown as "Organize"; the raw value is still `Filing`
    /// because that is what is on disk in every install.
    case filing = "Filing"
    /// Read-only: what is using the space.
    case storage = "Storage"

    var id: String { rawValue }

    /// The label in the workspace bar. Separate from `rawValue` so these can be reworded without
    /// breaking a stored selection.
    var title: String {
        switch self {
        case .compare: return "Compare"
        case .filing: return "Organize"
        case .storage: return "Storage"
        }
    }

    /// The bar's glyph. It carries the whole label at narrow widths (see ``WorkspaceBarMetrics``),
    /// so each has to be legible on its own rather than decorative.
    var symbol: String {
        switch self {
        case .compare: return "arrow.left.arrow.right"
        case .filing: return "folder.badge.gearshape"
        case .storage: return "chart.pie"
        }
    }

    /// The lens this workspace shows in the right-hand slot, or `nil` for Compare — which shows
    /// the second provider there instead.
    ///
    /// Organize answers `.filing` as its *default* apparatus; which lens is actually on screen is
    /// the rail's business (``OrganizeLens/searchLens``), not the workspace's. This is the single
    /// place the flat bar maps back onto the lens machinery inside `TidyView`, which still needs
    /// `TidyLens` for its per-lens search grammars and scroll state.
    var lens: TidyLens? {
        switch self {
        case .compare: return nil
        case .filing: return .filing
        case .storage: return .storage
        }
    }

    /// Every workspace that shows a lens, in bar order.
    static var lensWorkspaces: [Workspace] {
        allCases.filter { $0.lens != nil }
    }

    /// Where a programmatic caller naming a lens should land — the workspace **and**, inside
    /// Organize, which rail item to select.
    ///
    /// Two outputs rather than one, because the fold made the workspace insufficient on its own:
    /// "Find duplicates of this" from a Compare row used to name a workspace that *was* the
    /// answer, and now names one of six lenses inside Organize. A caller that set only the
    /// workspace would land on the overview and quietly lose the request.
    static func destination(for lens: TidyLens) -> WorkspaceSelection {
        guard let organizeLens = OrganizeLens(lens) else {
            // `.storage` is the only lens that is still a workspace of its own.
            return WorkspaceSelection(workspace: .storage, organizeLens: nil)
        }
        return WorkspaceSelection(workspace: .filing, organizeLens: organizeLens)
    }
}

/// A complete place to be: the workspace, and — inside Organize — which lens.
///
/// `nil` for `organizeLens` means Organize's **overview**, which is the rail's unselected state
/// rather than a seventh rail item.
struct WorkspaceSelection: Equatable {
    var workspace: Workspace
    var organizeLens: OrganizeLens?

    static let `default` = WorkspaceSelection(workspace: .compare, organizeLens: nil)
}

// MARK: - Migration off the selections this replaces

extension Workspace {

    /// The defaults key holding the flat selection.
    static let defaultsKey = "selectedWorkspace"
    /// The defaults key holding the rail selection inside Organize. Absent means the overview.
    /// Owned by ``OrganizeLens`` because `TidyView` reads it directly; aliased here so the
    /// migration below reads as one story.
    static let organizeLensKey = OrganizeLens.defaultsKey
    /// The two keys the flat bar replaced, read once by ``migrateSelection(in:)``.
    static let legacyTabKey = "selectedBottomTab"
    static let legacyLensKey = "selectedTidyLens"

    /// Raw values that were once a **workspace** and no longer resolve, and the rail lens each one
    /// became.
    ///
    /// This is the table that keeps a fold from silently dropping people. A stored value that no
    /// longer resolves does not fail loudly — `@AppStorage` takes its default — so someone sitting
    /// in Duplicates would reopen the app on Compare with nothing to explain it.
    ///
    /// **Each retirement gets its destination back, not just the umbrella.** `Rename` had to
    /// resolve to plain Organize when it was folded in, because the risky names were a chip that
    /// might not exist. The rail has a permanent place for all three, so all three land exactly
    /// where they were.
    static let retiredWorkspaceRawValues: [String: OrganizeLens] = [
        "Rename": .names,
        "Duplicates": .duplicates,
        "Automations": .rules,
    ]

    /// The raw value `Rename` persisted under, as both a Tidy lens and (briefly) a workspace.
    /// Kept as a named constant because the migration has to keep answering for it long after the
    /// case is gone.
    static let retiredRenameRawValue = "Rename"

    /// Where a session that ended on the old two-level selection resumes.
    ///
    /// Anything unrecognised resolves to `.compare`, which is also the default: an unreadable
    /// stored value and no stored value at all should land in the same place.
    ///
    /// This reads the LEGACY pair only. `selectedBottomTab` never held anything but `Differences`
    /// or `Tidy`, so there is deliberately no `Rename` arm on the tab here — a retired *workspace*
    /// value lives in the new key and is handled by ``migratedWorkspace(_:)``.
    static func migrated(tab: String?, lens: String?) -> WorkspaceSelection {
        guard tab == "Tidy" else { return .default }
        // On Tidy the lens decided what you were looking at, so it — not the tab — is the
        // destination. A missing or unrecognised lens takes Tidy's own former default.
        guard let lens else { return tidyDefault }
        if let retired = retiredWorkspaceRawValues[lens] {
            return WorkspaceSelection(workspace: .filing, organizeLens: retired)
        }
        // A lens raw value that is still a workspace: `Filing` and `Storage`. `Differences` is a
        // *workspace* raw value and must not be read as a lens — that would let someone on Tidy
        // resolve to Compare through the lens arm.
        guard let workspace = Workspace(rawValue: lens), workspace != .compare else {
            return tidyDefault
        }
        return WorkspaceSelection(workspace: workspace,
                                  organizeLens: workspace == .filing ? .toFile : nil)
    }

    /// Tidy's own former default lens, which was Duplicates — now Organize's duplicates rail item.
    /// Someone whose stored lens no longer reads should land where Tidy used to open, not on
    /// Compare: they were in a lens, so a lens is the nearer answer.
    static let tidyDefault = WorkspaceSelection(workspace: .filing, organizeLens: .duplicates)

    /// Where a stored `selectedWorkspace` that no longer resolves should land.
    ///
    /// The flat bar has retired three of its own cases now. A value it wrote itself is the easiest
    /// kind to forget: the legacy *pair* is obviously someone else's format and gets migrated,
    /// while `selectedWorkspace` reads like it must already be valid.
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
            // A stored value that still resolves is the truth — re-running over it would replace a
            // deliberate choice with a stale legacy pair. The rail selection beside it is left
            // alone for the same reason.
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

    /// Writes both halves of a resolved selection.
    ///
    /// **The lens key is cleared rather than left when there is no lens.** A migration that wrote
    /// only the workspace would leave whatever rail item happened to be stored, so someone
    /// migrating to Compare and then clicking Organize would land on a lens they never picked.
    private static func write(_ selection: WorkspaceSelection, to defaults: UserDefaults) {
        defaults.set(selection.workspace.rawValue, forKey: defaultsKey)
        if let lens = selection.organizeLens {
            defaults.set(lens.rawValue, forKey: organizeLensKey)
        } else {
            defaults.removeObject(forKey: organizeLensKey)
        }
    }
}
