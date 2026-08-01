import Foundation
import FileExplorer

/// The one top-level selection: which workspace the window is showing.
///
/// This replaces the two-level `Compare | Tidy` tab picker plus the Tidy lens tabs. Duplicates
/// used to live two clicks deep behind a container word that named no task; now every workspace
/// is one click, and the layout rule underneath is fixed — **the left side is always a file
/// browser; the right side is either the other cloud (Compare) or a lens (everything else)**.
///
/// The raw values are deliberately inherited from the two enums this collapses, so the persisted
/// selection survives the change: `Differences` and `Tidy` came from `ContentView.BottomTab`, and
/// `Duplicates` / `Rename` / `Filing` / `Automations` / `Storage` from `TidyLens`. They are a
/// stable persistence format — see `WorkspaceTests`. As with the enums before it, `title` is
/// separate from `rawValue` precisely so a display name can change without stranding anyone
/// (`Differences` shows as "Compare", `Filing` as "Organize").
enum Workspace: String, CaseIterable, Identifiable {
    /// The two provider panes over the Differences workspace. Shown as "Compare".
    case compare = "Differences"
    /// Loose files and where they belong. Shown as "Organize".
    case filing = "Filing"
    /// Identical content under different names or folders.
    case duplicates = "Duplicates"
    /// The rules that file things without asking.
    case automations = "Automations"
    /// Read-only: what is using the space.
    case storage = "Storage"

    var id: String { rawValue }

    /// The label in the workspace bar. Separate from `rawValue` so these can be reworded without
    /// breaking a stored selection.
    var title: String {
        switch self {
        case .compare: return "Compare"
        case .filing: return "Organize"
        case .duplicates: return "Duplicates"
        case .automations: return "Automations"
        case .storage: return "Storage"
        }
    }

    /// The bar's glyph. It carries the whole label at narrow widths (see ``WorkspaceBarMetrics``),
    /// so each has to be legible on its own rather than decorative.
    var symbol: String {
        switch self {
        case .compare: return "arrow.left.arrow.right"
        case .filing: return "folder.badge.gearshape"
        case .duplicates: return "doc.on.doc"
        case .automations: return "wand.and.stars"
        case .storage: return "chart.pie"
        }
    }

    /// The lens this workspace shows in the right-hand slot, or `nil` for Compare — which shows
    /// the second provider there instead. This is the single place the flat bar maps back onto
    /// the lens machinery inside `TidyView`, which still needs `TidyLens` for its per-lens search
    /// grammars and scroll state.
    var lens: TidyLens? {
        switch self {
        case .compare: return nil
        case .filing: return .filing
        case .duplicates: return .duplicates
        case .automations: return .automations
        case .storage: return .storage
        }
    }

    /// Every workspace that shows a lens, in bar order.
    static var lensWorkspaces: [Workspace] {
        allCases.filter { $0.lens != nil }
    }

    /// The workspace a lens is shown in, for the programmatic scan actions ("Find Duplicates"
    /// from a Compare row) that name a lens rather than a workspace.
    ///
    /// Not a strict inverse of `lens`, and cannot be: `.rename` has no workspace of its own any
    /// more. Risky names are a *finding* of Organize's scan rather than a place — the chip only
    /// exists when the scan turned some up — so a caller naming that lens is asking for Organize.
    init(_ lens: TidyLens) {
        switch lens {
        case .duplicates: self = .duplicates
        case .rename, .filing: self = .filing
        case .automations: self = .automations
        case .storage: self = .storage
        }
    }
}

// MARK: - Migration off the two-level selection

extension Workspace {

    /// The defaults key holding the flat selection.
    static let defaultsKey = "selectedWorkspace"
    /// The raw value `Rename` persisted under, as both a Tidy lens and (briefly) a workspace of
    /// its own. Kept as a constant because the migration has to keep answering for it long after
    /// the case is gone — a retired raw value is exactly the kind of thing that stops being
    /// handled once nothing in the enum names it any more.
    static let retiredRenameRawValue = "Rename"
    /// The two keys it replaces, read once by ``migrateSelection(in:)`` and then left alone.
    static let legacyTabKey = "selectedBottomTab"
    static let legacyLensKey = "selectedTidyLens"

    /// Where a session that ended on the old two-level selection resumes.
    ///
    /// Folding two keys into one deletes destinations, and a stored value that no longer resolves
    /// does not fail loudly — `@AppStorage` silently falls back to its default, which would drop
    /// anyone who was mid-task in a lens onto Compare with no explanation. So every old pair is
    /// mapped explicitly, including the ones whose raw values are gone.
    ///
    /// Anything unrecognised resolves to `.compare`, which is also the default: an unreadable
    /// stored value and no stored value at all should land in the same place.
    ///
    /// This reads the LEGACY pair only. `selectedBottomTab` never held anything but `Differences`
    /// or `Tidy`, so there is deliberately no `Rename` arm on the tab here — a retired *workspace*
    /// value lives in the new key and is handled by ``migratedWorkspace(_:)``. An arm for a value
    /// the key never carried would read like coverage of the path that actually stranded people.
    static func migrated(tab: String?, lens: String?) -> Workspace {
        guard tab == "Tidy" else { return .compare }
        // On Tidy the lens decided what you were looking at, so it — not the tab — is the
        // workspace. A missing or unrecognised lens takes Tidy's own former default.
        if lens == retiredRenameRawValue { return .filing }
        guard let lens, let workspace = Workspace(rawValue: lens), workspace != .compare else {
            return .duplicates
        }
        return workspace
    }

    /// Where a stored `selectedWorkspace` that no longer resolves should land.
    ///
    /// The flat bar has already retired one of its own cases, and will retire more. A value it
    /// wrote itself is the easiest kind to forget: the legacy *pair* is obviously someone else's
    /// format and gets migrated, while `selectedWorkspace` reads like it must already be valid.
    /// It isn't — `Rename` was a workspace for exactly one commit — and an unresolvable value
    /// fails silently, so this is the one function that has to keep answering for them.
    static func migratedWorkspace(_ raw: String) -> Workspace {
        raw == retiredRenameRawValue ? .filing : .compare
    }

    /// Runs the migration once, at launch, before any view reads the selection.
    ///
    /// Returns the resolved workspace so a test can assert what a given stored state migrates to
    /// without reaching back into defaults; nil when there was nothing to do.
    @discardableResult
    static func migrateSelection(in defaults: UserDefaults) -> Workspace? {
        if let stored = defaults.string(forKey: defaultsKey) {
            // A stored value that still resolves is the truth — re-running over it would replace
            // a deliberate choice with a stale legacy pair.
            guard Workspace(rawValue: stored) == nil else { return nil }
            // One that does NOT resolve is the dangerous case, and the quiet one: @AppStorage
            // takes its default, so a retired value is indistinguishable from a preference for
            // Compare. Remap before anything reads the key.
            let resolved = migratedWorkspace(stored)
            defaults.set(resolved.rawValue, forKey: defaultsKey)
            return resolved
        }
        // Nothing stored at all is a first run, not an upgrade — leave the key unset so
        // @AppStorage uses its own default rather than baking one in here.
        guard defaults.string(forKey: legacyTabKey) != nil
                || defaults.string(forKey: legacyLensKey) != nil else { return nil }

        let resolved = migrated(
            tab: defaults.string(forKey: legacyTabKey),
            lens: defaults.string(forKey: legacyLensKey)
        )
        defaults.set(resolved.rawValue, forKey: defaultsKey)
        return resolved
    }
}
