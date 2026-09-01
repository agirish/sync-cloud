import Foundation
import FileExplorer

/// The one top-level selection: which workspace the window is showing.
///
/// Four segments, and they are four different *kinds of place* rather than four tasks:
/// **Browse** shows one tree and proposes nothing, **Compare** holds two trees side by side,
/// **Organize** is everything the app concludes about one tree, and **Editor** changes what is
/// *inside* one file. Everything the app has to say about a single tree is a lens inside Organize
/// (see ``OrganizeLens``) — duplicates, automations and now storage included, which is what took
/// the bar from five segments to four.
///
/// **Storage was the fifth, and the boundary that kept it out was the wrong one.** The rule used to
/// read "Storage reads one tree and changes nothing, Organize changes one tree", which made
/// *acting* the test for being a lens. Rules had already broken it — configuration, no badge, in no
/// pass, and a lens all the same — and Storage is the same shape one step further along: a
/// conclusion about one tree that the app reports rather than acts on. Most lenses act on their
/// conclusion; Rules writes the standing instructions; **Storage only reports — it never moves,
/// deletes, or evicts a file.**
///
/// **Editor is the fifth kind because it is the first surface that writes a file's contents.**
/// Every other workspace moves, copies, trashes or accounts for whole files and never opens one to
/// change it; the editor never moves a file and only ever rewrites the bytes of the one that is
/// open. That is a different verb, not a mode of Browse — which is why it is a segment and not a
/// pane inside one. It is also the app's only *writable* text surface on purpose: dirty state, the
/// undo stack and the save circuit exist in exactly one place, and every other workspace that
/// wants to edit a file hands off to here (see `openInEditor`).
///
/// Browse is a kind of its own rather than a mode inside Organize, and the distinction is the whole
/// reason it exists: it is where you go when you do not want a lens's opinion — move this file, by
/// hand, now. A mode inside Organize could not be that, because it would still be Organize.
///
/// The layout rule underneath is unchanged and is why the fold is cheap: **the left side is always
/// a file browser; the right side is either the other cloud (Compare) or a lens (everything
/// else).** Browse is that rule with the right side taken away, which is why it costs a layout arm
/// and no new pane. Folding two workspaces in moved nothing across that line.
///
/// The raw values are deliberately inherited from the enums this has collapsed over time, so a
/// persisted selection survives: `Differences` and `Tidy` came from `ContentView.BottomTab`, and
/// `Duplicates` / `Rename` / `Filing` / `Automations` / `Storage` from `WorkspaceLensKind`. They are a
/// stable persistence format — see `WorkspaceTests`. As with the enums before it, `title` is
/// separate from `rawValue` precisely so a display name can change without stranding anyone
/// (`Differences` shows as "Compare", `Filing` as "Organize").
enum Workspace: String, CaseIterable, Identifiable {
    /// One tree, full width, no lens. The plain file browser.
    ///
    /// Declared FIRST, which is load-bearing twice over: `allCases` is the bar's order, and it is
    /// also where the workspace chords come from (`WorkspaceCommands` and `workspaceSegment` both number the
    /// segments by position). The raw value is new, so no stored selection can name it — which is
    /// what makes it safe to be the default.
    case browse = "Browse"
    /// The two provider panes over the Differences workspace. Shown as "Compare".
    case compare = "Differences"
    /// Everything that changes one tree. Shown as "Organize"; the raw value is still `Filing`
    /// because that is what is on disk in every install.
    case filing = "Filing"
    /// One text file, open and writable. The app's only editing surface.
    ///
    /// **The raw value is `Editor` and must never be reworded**, for the same reason `Filing` is
    /// still `Filing` on disk: it is a persistence format the moment the first person clicks it.
    /// It no longer matches the title, which is the ordinary state of affairs here — `Filing` has
    /// read "Organize" in the bar for as long as it has existed, and `Differences` reads "Compare".
    /// `WorkspaceTests` pins the raw values separately from the titles so a rename of one cannot
    /// quietly take the other with it.
    ///
    /// Declared LAST, which is what hands it **⌘4**: `allCases` is the bar's order and the chords
    /// are positional (`AppChord.workspace(_:)`, bounded at nine). It was ⌘5 until Storage folded
    /// into Organize and left the bar — nothing here changed to move it, which is the property
    /// being relied on: the bar badge and the View menu both count `allCases`, so they cannot
    /// disagree about the number.
    case editor = "Editor"

    var id: String { rawValue }

    /// **Whether the folder sidebar can appear here.** One place, because three surfaces ask —
    /// the View menu item, the toolbar button and the column itself — and the whole point of
    /// `FolderSidebarModel.appliesTo` is that they cannot come to different answers.
    ///
    /// Every workspace, since 2026-08-24 — which is worth stating as a rule rather than as a list,
    /// because the list is now "all of them" and a future case should have to argue its way OUT.
    ///
    /// Browse re-roots its full-width pane; the lens workspaces re-root the rail, which Organize's
    /// scope and Storage's root both already follow (`lensScanRootExpanded` reads the targeted
    /// pane's current directory). Compare re-roots whichever pane you are working in
    /// (`PaneLogic.lensTargetsRightPane`) and **says which that is** — the caption the other three
    /// do not need and Compare cannot do without, see `SidebarTarget`.
    ///
    /// Still `switch`ed with no `default:`. A workspace added later should be a decision here, not
    /// an inheritance.
    /// Editor answers **true** and needs it more than any of them: the sidebar's selected folder is
    /// the only thing that says which folder's text files the rail lists, so without it the editor
    /// has no way to reach a second folder.
    var supportsFolderSidebar: Bool {
        switch self {
        case .browse, .filing, .compare, .editor: return true
        }
    }

    /// The label in the workspace bar. Separate from `rawValue` so these can be reworded without
    /// breaking a stored selection.
    var title: String {
        switch self {
        case .browse: return "Browse"
        case .compare: return "Compare"
        case .filing: return "Organize"
        // **"Edit", and the menu-bar collision is the known cost.** The app has a top-level Edit
        // menu holding the clipboard, so `View ▸ Edit` names a workspace a few pixels from an
        // `Edit` that means something else entirely. That is a real ambiguity and it was the
        // argument for "Editor" — overruled deliberately: the bar is a row of verbs a person
        // picks, "Edit" is the one that matches the other four, and no other workspace pays a
        // syllable to disambiguate itself from a menu. `HelpBookTests` still separates the two,
        // because it matches on the `Edit ▸ ` PATH rather than on the bare word.
        case .editor: return "Edit"
        }
    }

    /// The bar's glyph. It carries the whole label at narrow widths (see ``WorkspaceBarMetrics``),
    /// so each has to be legible on its own rather than decorative.
    var symbol: String {
        switch self {
        // The plain folder, which is what Browse is: your files, with nothing done to them. It is
        // deliberately the UNBADGED form of Organize's glyph — the gear badge is the whole
        // difference between the two places, and at icon-only widths (where every segment sheds
        // its word at once) that badge is the only thing distinguishing them. That is a real
        // legibility cost, and it is the honest one: any glyph distinct enough to be unmistakable
        // there would have stopped saying "files".
        case .browse: return "folder"
        case .compare: return "arrow.left.arrow.right"
        case .filing: return "folder.badge.gearshape"
        // A sheet with a pencil on it: the one glyph in the bar that is about a file's CONTENTS
        // rather than about files. 15×15 at 12pt medium, so it sits inside `glyphSide` (17) with a
        // point to spare on both axes — checked, because a symbol wider than the frame is clipped
        // rather than scaled and nothing but `theBarDrawsEverySegmentAtOneHeight` would notice.
        case .editor: return "square.and.pencil"
        }
    }

    /// The lens this workspace shows in the right-hand slot, or `nil` for Compare — which shows
    /// the second provider there instead.
    ///
    /// Organize answers `.filing` as its *default* apparatus; which lens is actually on screen is
    /// the rail's business (``OrganizeLens/searchLens``), not the workspace's. This is the single
    /// place the flat bar maps back onto the lens machinery inside `LensWorkspaceView`, which still needs
    /// `WorkspaceLensKind` for its per-lens search grammars and scroll state.
    var lens: WorkspaceLensKind? {
        switch self {
        // Editor joins Browse and Compare here: it shows one open file, and a lens is a *proposal*
        // about a tree. It has no right-hand slot at all, which is why it cannot ride the lens
        // mounting path — `presentLensRail` and `bottomPaneView` both answer nothing for a
        // lens-less workspace. See `ContentLayout.editorExpanded` / `.editorCollapsed`.
        case .browse, .compare, .editor: return nil
        case .filing: return .filing
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
    static func destination(for lens: WorkspaceLensKind) -> WorkspaceSelection {
        guard let organizeLens = OrganizeLens(lens) else {
            // **Unreachable today, and kept anyway.** Every `WorkspaceLensKind` bridges to a rail
            // item since Storage folded in — `.storage` was the last one that did not, and it
            // landed on a workspace of its own here. `OrganizeLens.init(_:)` stays failable for the
            // next apparatus added without a rail item, so this needs an answer: Organize's
            // overview, which is the honest place for "a lens inside Organize that the rail cannot
            // name". Never `.default` — that would drop a pointed request into Browse.
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
/// `nil` for `organizeLens` means Organize's **overview**, which is the rail's unselected state
/// rather than a seventh rail item.
struct WorkspaceSelection: Equatable {
    var workspace: Workspace
    var organizeLens: OrganizeLens?

    /// Where a window with nothing it can use opens: Browse, and a file browser is a better place
    /// to land than a comparison of two clouds nothing has scanned yet.
    ///
    /// **"Nothing stored" and "unreadable" agree, and that takes two constants, not one.** They are
    /// genuinely different paths: this value serves a *stored* selection that no longer resolves,
    /// through ``migratedWorkspace(_:)`` and ``migrated(tab:lens:)``, while a *first run* never
    /// reaches it at all — `migrateSelection(in:)` returns `nil` when nothing is stored, on purpose,
    /// so the keys stay unset and `@AppStorage` supplies its own default. The one that answers a
    /// first run is `ContentView.selectedWorkspace`.
    ///
    /// They were `.browse` and `.compare` respectively, so the agreement this comment claimed was
    /// false in the one direction nobody looks: a fresh install opened on Compare, a corrupted one
    /// on Browse. `theFirstRunDefaultAgreesWithTheFallback` reads both out of the source and fails
    /// if they part again, because nothing else can — no test can mount `ContentView`, and the two
    /// declarations sit in different files.
    ///
    /// Existing installs are untouched: they carry a stored selection that still resolves, and
    /// neither default is consulted for them.
    static let `default` = WorkspaceSelection(workspace: .browse, organizeLens: nil)
}

// MARK: - Migration off the selections this replaces

extension Workspace {

    /// The defaults key holding the flat selection.
    static let defaultsKey = "selectedWorkspace"
    /// The defaults key holding the rail selection inside Organize. Absent means the overview.
    /// Owned by ``OrganizeLens`` because `LensWorkspaceView` reads it directly; aliased here so the
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
    /// in Duplicates would reopen the app on the default workspace with nothing to explain it.
    ///
    /// **Each retirement gets its destination back, not just the umbrella.** `Rename` had to
    /// resolve to plain Organize when it was folded in, because the risky names were a chip that
    /// might not exist. The rail has a permanent place for each: `Duplicates` and `Automations`
    /// land exactly where they were, and `Rename` lands on Renames — the rail item that hosts the
    /// risky-name findings since the Names fold (P10). A stored *rail* value of "Names" is a
    /// different key and a different table; see ``retiredOrganizeLensRawValues``.
    static let retiredWorkspaceRawValues: [String: OrganizeLens] = [
        "Rename": .renames,
        "Duplicates": .duplicates,
        "Automations": .rules,
        // Storage kept its raw value on the way in: `OrganizeLens.storage` is also `"Storage"`, so
        // someone who quit on the Storage tab reopens on Organize with the Storage rail item
        // selected — the same place, reached the new way, with no explaining to do.
        "Storage": .storage,
    ]

    /// The raw value `Rename` persisted under, as both a Tidy lens and (briefly) a workspace.
    ///
    /// **Nothing in the migration reads this any more** — the `Rename` arm resolves through
    /// ``retiredWorkspaceRawValues``. Its one reader is `TopPaneVisibilityTests`, which asserts
    /// the retired key does *not* survive a fanned-out override map; the constant is what keeps
    /// that assertion from spelling the legacy string itself. Kept for that, not for the
    /// migration.
    static let retiredRenameRawValue = "Rename"

    /// Where a session that ended on the old two-level selection resumes.
    ///
    /// A tab that is not `Tidy` resolves to ``WorkspaceSelection/default`` — Browse — because an
    /// unreadable stored value and no stored value at all should land in the same place.
    ///
    /// **The two Tidy arms do NOT follow it there, and must not be "fixed" to.** They resolve to
    /// ``tidyDefault``, a lens: someone whose session ended inside Tidy was in a lens, so a lens is
    /// the nearer answer than a file browser. The default moving to Browse changes where the
    /// unrecognised *workspace* lands; it does not change where an unrecognised *lens* lands.
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
        // **One lens raw value is still a workspace: `Filing`.** `Storage` used to be the other,
        // and it resolved through here to the Storage tab; it is in ``retiredWorkspaceRawValues``
        // now, so the branch above catches it first and this arm never sees it. That inversion is
        // the whole of the fold's migration story for the legacy pair.
        //
        // **Named explicitly rather than excluding `.compare`.** The old guard was a deny-list of
        // one, which quietly widened every time a case was added: `Differences` was excluded
        // because reading a *workspace* raw value as a lens would put someone on Tidy into Compare
        // — but by the same logic a stored `"Editor"` would have routed to the Editor workspace,
        // which nothing on Tidy could ever have written. Unreachable in practice, and an allow-list
        // costs nothing to state.
        guard lens == Workspace.filing.rawValue else { return tidyDefault }
        return WorkspaceSelection(workspace: .filing, organizeLens: .toFile)
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

    /// Rail-lens raw values whose case has been retired, and what each one is now.
    ///
    /// Separate from ``retiredWorkspaceRawValues`` because these were never workspaces — they are
    /// values of ``OrganizeLens`` itself, stored under ``organizeLensKey``.
    ///
    /// `Names` is here because the case is gone. It was a rail item of its own until the v4.0
    /// polish folded it into Renames (P10), after which the case survived precisely so a stored
    /// "Names" would still decode and `resolvedForPresentation` could fold it at the point of use.
    /// With the case deleted there is nothing left to decode it, so the fold moves here — once, at
    /// launch, into the stored value — instead of being re-applied on every read forever.
    static let retiredOrganizeLensRawValues: [String: OrganizeLens] = ["Names": .renames]

    /// Rewrites a stored rail selection whose case no longer exists.
    ///
    /// **Its own function, called unconditionally, because ``migrateSelection(in:)`` cannot do
    /// it.** That one returns early — before it ever looks at the rail key — whenever the stored
    /// *workspace* still resolves, which is the ordinary case for everybody it would need to help
    /// here: someone sitting in Organize ▸ Names has a perfectly valid "Organize" stored beside
    /// it. Folding this into that function would produce a migration that runs only for people
    /// who also happen to be mid-upgrade on the other key.
    ///
    /// Silent failure is the thing being prevented: `@AppStorage` takes its default when a raw
    /// value does not resolve, and this key's default is *absent* — meaning the overview — so
    /// without this someone who left the app in the rename backlog reopens it on the overview with
    /// nothing to explain the move.
    static func migrateOrganizeLens(in defaults: UserDefaults) {
        guard let stored = defaults.string(forKey: organizeLensKey),
              let replacement = retiredOrganizeLensRawValues[stored] else { return }
        defaults.set(replacement.rawValue, forKey: organizeLensKey)
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
