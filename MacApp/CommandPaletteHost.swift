import SwiftUI
import AppKit
import Design
import FileExplorer
import Sync
import Dashboard
import Events

// MARK: - The menu item

/// Go ▸ Command Palette, ⌘K.
///
/// **A menu item, never `.onKeyPress`** — that modifier is strictly focus-scoped, and the palette is
/// wanted precisely when focus is sitting in a file table, which is where it always is. The same
/// argument `FindInPaneCommand` records for ⌘F, and ROADMAP 14 calls it out as the one
/// implementation trap of the item. It also puts the chord in the menu bar, which is where someone
/// looks for a shortcut they half-remember.
struct CommandPaletteCommand: View {
    @FocusedValue(\.commandPalette) private var palette

    var body: some View {
        // Ellipsis: it opens a field, it does not do anything yet.
        Button("Command Palette…") { palette?() }
            .keyboardShortcut(AppChord.commandPalette.key, modifiers: AppChord.commandPalette.modifiers)
            .disabled(palette == nil)
    }
}

private struct CommandPaletteKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    /// Opens (or closes) the ⌘K palette. Published by `ContentView`; read by the menu item, which
    /// lives in the App scope and can see none of the window's state.
    var commandPalette: (() -> Void)? {
        get { self[CommandPaletteKey.self] }
        set { self[CommandPaletteKey.self] = newValue }
    }
}

// MARK: - ContentView's half

extension ContentView {

    /// ⌘K toggles. Every open starts from an empty query — a palette that reopened holding the last
    /// thing you typed would answer a question you have already had answered, and the reset is what
    /// keeps the empty-query landing (recents, then places) reachable after the first use.
    ///
    /// **It raises a panel rather than flipping an overlay flag**, for the reasons recorded at the
    /// top of `CommandPalettePanel.swift`: as an in-window overlay its clicks and keystrokes went
    /// through to the AppKit file panes underneath it.
    func toggleCommandPalette() {
        if palettePanel.isPresented {
            palettePanel.dismiss()
            return
        }
        // **The suspension has to be on the act, not on one publication.** `a1c96082` suspended ⌘K
        // by nilling `effectiveCommandPalette`, which reaches the menu item — and nothing else. The
        // toolbar pill calls this directly (`ContentView+Toolbar.swift`), and so does
        // `paletteOnLaunchArmed`, so two of the three ways in walked straight past it and could
        // raise the palette over a pending destination pick: ↩ on a workspace row then switches
        // workspace mid-pick, which is the defect that commit set out to stop.
        guard pendingDestination == nil else {
            // `.info`, not `.debug`: this is the only refusal a user can actually trigger, and it
            // records a control that appeared to do nothing. `.debug` is dropped entirely at
            // Settings ▸ Advanced ▸ Info, which is where "⌘K did nothing and the log is silent"
            // comes from — the sibling refusal below is `.warning` for exactly this reason.
            Logger.shared.info("⌘K ignored: the destination picker owns the keyboard")
            return
        }
        guard let host = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible)
        else {
            // No window to hang it on. Said out loud rather than silently doing nothing: ⌘K
            // appearing to be dead is exactly the kind of report that has no other trace.
            Logger.shared.warning("⌘K pressed with no window to present the command palette over")
            return
        }
        let index = paletteIndex
        let state = CommandPaletteState(index: index)
        palettePanel.present(
            over: host, state: state, accent: glassHue.accentColor, glassLevel: glassLevel,
            onRun: { [self] route in runPaletteRoute(route) },
            onDismiss: { showCommandPalette = false })
        // **After `present`, not before.** `present` retires whatever it replaces, which fires that
        // presentation's `onDismiss` — so a flag raised first could be lowered by the outgoing
        // palette a line later, leaving every menu chord suspended with nothing on screen. Nothing
        // reaches that path today (the toggle above returns early when one is up), which is exactly
        // why the ordering is worth making unable to matter.
        showCommandPalette = true
        // Logged for the same reason the person gather logs its accept: this surface is
        // keyboard-only, its chord is a menu key equivalent, and nothing short of assistive access
        // can drive it from a script — so the log is the only place a run that is not a human's can
        // be checked afterwards. The counts are what say the index was BUILT, not merely that
        // something appeared over an empty one.
        Logger.shared.info("Command palette opened — \(state.rows.count) rows from "
            + "\(index.folders.count) folders, \(index.people.count) people, "
            + "\(index.providers.count) sources")
    }

    /// What the router is allowed to read, assembled from live state.
    ///
    /// **Folders come from the survey's folder profile, not from a disk walk.** The profile is
    /// already in memory and already knows every folder under the root; walking the disk to answer
    /// "what folders are there" would be the header-touches-the-filesystem mistake one surface over.
    ///
    /// Read once, when the palette opens — `CommandPaletteState` holds the result for the life of
    /// that session — so this is not on the keystroke path at all.
    var paletteIndex: PaletteIndex {
        let root = tidyProviderRootExpanded
        let profile = syncManager.filingFolderProfile
        // The rule is `PaletteIndex.folders` and not spelled out here — it has a tilde-expansion in
        // it that this call site got wrong, and the installed app was the only thing that noticed.
        let folders = PaletteIndex.folders(profileRoot: profile?.root, providerRoot: root,
                                           keys: Array(profile?.folders.keys ?? [:].keys))
        return PaletteIndex(
            providers: settings.enabledProviders.map { provider in
                PaletteProvider(id: provider.id, name: provider.displayName,
                                // The reason an unmounted source is DIMMED rather than dropped: the
                                // folder is simply not there right now (an unplugged SSD, an iCloud
                                // account signed out), which is a fact worth showing.
                                // Tilde-expanded, and a directory: the Settings field accepts a
                                // hand-typed `~/…` verbatim and validates it expanded, so without
                                // this a Location showed green in Settings and dimmed "Not
                                // mounted" here — about the same folder.
                                isMounted: Self.isMountedFolder(provider.path),
                                // "The current source" means the pane this palette is aimed at —
                                // the focused one in Compare — for the same reason the folder rows
                                // are indexed from its root. Asking `leftProviderId` had a
                                // right-root index calling the left provider current.
                                isCurrent: provider.id == paletteProviderId)
            },
            providerRoot: root.isEmpty ? nil : root,
            folders: folders,
            // The one recents list — `FolderJumpStore` is already fed by every pane focus change
            // (see ContentView's `onChange(of: leftRelativePath)`), and it carries the pins too.
            recentFolders: FolderJumpStore.shared.recentPaths(forRoot: root),
            pinnedFolders: FolderJumpStore.shared.pinnedPaths(forRoot: root),
            people: syncManager.filingPersonRegistry?.people ?? [],
            registry: syncManager.filingPersonRegistry,
            isScanning: isScanning || syncManager.isSuggestingFiles,
            // The same pair the person gather itself needs. The roster can outlive the survey, and
            // an offer whose accept does nothing is what `acceptPersonScope`'s failure path exists
            // to say out loud; the palette says it before you press ↩ instead.
            hasSurvey: syncManager.filingFolderProfile != nil
                && syncManager.filingProfilesDirectory != nil)
    }

    /// Applies a route. **The only place in the app that turns a `PaletteRoute` into state**, so the
    /// routing table's tests and the behaviour cannot come apart anywhere else.
    ///
    /// The panel has already dismissed itself by the time this runs — see the `onRun` wrapper in
    /// `CommandPalettePanelController.present` — so a route that changes workspace lands on a
    /// window that is key again.
    func runPaletteRoute(_ route: PaletteRoute) {
        Logger.shared.info("Command palette → \(route)")
        switch route {
        case .browse:
            workspaceSelection.wrappedValue = .browse
        case .compare:
            workspaceSelection.wrappedValue = .compare
        case .storage:
            workspaceSelection.wrappedValue = .storage
        case .organize(let lens, let scope):
            aimOrganize(lens: lens, scope: scope)
        case .person(let id):
            guard let person = syncManager.filingPersonRegistry?.people.first(where: { $0.id == id })
            else { return }
            acceptPersonScope(person)
        case .provider(let id):
            // Switched on the pane the palette is aimed at, so choosing a source from ⌘K changes
            // the one whose folders it was just listing.
            if tidyTargetIsRight { rightProviderId = id } else { leftProviderId = id }
        case .folder(let path):
            revealInSourcePane(path)
        case .action(let action):
            runPaletteAction(action)
        }
    }

    /// The provider whose tree the palette is describing — the focused pane's in Compare, the
    /// left rail's otherwise. The same rule `tidyProviderRootExpanded` follows, named once so the
    /// index's rows, its "current source" mark and both of its provider writes cannot disagree
    /// about which pane they mean.
    var paletteProviderId: String { tidyTargetIsRight ? rightProviderId : leftProviderId }

    /// Whether a source's folder is there right now. Expanded first, and required to be a
    /// directory — the app's own validity rule (`SettingsManager`), asked the same way.
    static func isMountedFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let expanded = (path as NSString).expandingTildeInPath
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Organize, at a rail item, optionally re-aimed.
    ///
    /// The scope is written to the defaults key `TidyView` reads, because that is where the scope
    /// lives — a view-local copy here would be a second source of truth for the one thing the whole
    /// Organize feature is anchored on. The pane follows the scope, so the source rail is showing
    /// the folder the lenses are answering about rather than wherever it happened to be parked.
    private func aimOrganize(lens: OrganizeLens?, scope: String?) {
        // Through the bar's own binding, so entering Organize does everything entering Organize
        // does — the review teardown, the person-scope clear, the rail presentation.
        workspaceSelection.wrappedValue = .filing
        // Through `@AppStorage`, never `UserDefaults.standard.set` — see `paletteRailLens` for the
        // write this app has already watched go missing.
        paletteRailLens = lens?.resolvedForPresentation
        guard let scope else { return }
        let root = tidyProviderRootExpanded
        // Normalized through `OrganizeScope`, which is the one writer's rule: pointing at the
        // provider root CLEARS the scope rather than storing the root as one, so ⌘K cannot mint the
        // second encoding of the global view that the type is failable to prevent.
        paletteScopePath = OrganizeScope(path: scope, providerRoot: root)?.path ?? ""
        revealInSourcePane(scope)
    }

    /// Points the source pane at an absolute folder inside the current provider.
    ///
    /// Silently does nothing for a path outside the root — a relative path computed against the
    /// wrong root would focus the pane on a folder that does not exist, which looks exactly like a
    /// broken palette rather than like a stale index.
    ///
    /// **The pane it points at is the one the index was built from**, which is not always the left
    /// one. `tidyProviderRootExpanded` follows the focused pane in Compare, so every folder row in
    /// the palette is relative to the *right* provider's tree when the right pane has focus. This
    /// revealed into the left pane regardless: the guard passed (the path really is under that
    /// root), a relative path from one provider's tree was handed to the other's, and the pane
    /// jumped to a folder that most likely does not exist there — the exact "looks like a broken
    /// palette" outcome the guard above was written to avoid, reached by a different route.
    private func revealInSourcePane(_ absolutePath: String) {
        let root = tidyProviderRootExpanded
        guard !root.isEmpty,
              let relative = PathBoundary.relativize(absolutePath, under: root) else { return }
        syncManager.focusOn(relativePath: relative, isLeft: !tidyTargetIsRight)
    }

    private func runPaletteAction(_ action: PaletteAction) {
        switch action {
        case .rescan: shortcutRescan?()
        case .newFolder: shortcutNewFolder?()
        // The aimed pane, like every other provider write here — see `paletteProviderId`. Adding
        // a source from ⌘K while the right pane is focused pointed the LEFT one at it, which also
        // fires that pane's provider-switch teardown on the side the user was not working in.
        case .chooseFolder:
            chooseFolderSource { id in
                if tidyTargetIsRight { rightProviderId = id } else { leftProviderId = id }
            }
        case .findInPane: beginPaneSearch()
        case .settings: showSettings = true
        case .shortcuts: openWindow(id: "keyboard-shortcuts")
        case .activityLog: openWindow(id: "activity-log")
        }
    }
}
