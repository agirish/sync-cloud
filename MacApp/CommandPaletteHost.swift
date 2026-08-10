import SwiftUI
import AppKit
import Design
import FileExplorer
import Sync
import Dashboard

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

    /// ⌘K toggles. Opening resets the query, because a palette that reopened holding the last thing
    /// you typed would answer a question you have already had answered — and because the reset is
    /// what makes the empty-query landing (recents, then places) reachable at all after the first use.
    func toggleCommandPalette() {
        if showCommandPalette {
            closeCommandPalette()
        } else {
            paletteQuery = ""
            showCommandPalette = true
            paletteSelection = PaletteSelection.initialIndex(in: paletteRows)
        }
    }

    func closeCommandPalette() {
        showCommandPalette = false
        paletteQuery = ""
        paletteSelection = nil
    }

    /// What the router is allowed to read, assembled from live state.
    ///
    /// **Folders come from the survey's folder profile, not from a disk walk.** This is rebuilt on
    /// every keystroke through `paletteRows`, and a palette that stat'd the tree between a key and
    /// its character would be the header-touches-the-filesystem mistake one surface over. The
    /// profile is already in memory and already knows every folder under the root.
    var paletteIndex: PaletteIndex {
        let root = tidyProviderRootExpanded
        let profile = syncManager.filingFolderProfile
        // The profile keys are relative already, with `.` for the root itself — which is not a
        // destination, so it is dropped rather than offered as a folder called ".".
        let folders = (profile?.root).flatMap { profileRoot -> [String]? in
            guard let profile,
                  PathBoundary.contains(profileRoot, under: root) || profileRoot == root
            else { return nil }
            return profile.folders.keys.filter { $0 != "." && !$0.isEmpty }
        } ?? []
        return PaletteIndex(
            providers: settings.enabledProviders.map { provider in
                PaletteProvider(id: provider.id, name: provider.displayName,
                                // The reason an unmounted source is DIMMED rather than dropped: the
                                // folder is simply not there right now (an unplugged SSD, an iCloud
                                // account signed out), which is a fact worth showing.
                                isMounted: FileManager.default.fileExists(atPath: provider.path),
                                isCurrent: provider.id == leftProviderId)
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
                && syncManager.filingProfilesDirectory != nil,
            canChooseFolder: true)
    }

    var paletteRows: [PaletteRow] {
        PaletteRouter.rows(query: paletteQuery, index: paletteIndex)
    }

    /// Applies a route. **The only place in the app that turns a `PaletteRoute` into state**, so the
    /// routing table's tests and the behaviour cannot come apart anywhere else.
    func runPaletteRoute(_ route: PaletteRoute) {
        closeCommandPalette()
        switch route {
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
            leftProviderId = id
        case .folder(let path):
            revealInSourcePane(path)
        case .action(let action):
            runPaletteAction(action)
        }
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
        if let lens {
            UserDefaults.standard.set(lens.rawValue, forKey: OrganizeLens.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: OrganizeLens.defaultsKey)
        }
        guard let scope else { return }
        let root = tidyProviderRootExpanded
        // Normalized through `OrganizeScope`, which is the one writer's rule: pointing at the
        // provider root CLEARS the scope rather than storing the root as one, so ⌘K cannot mint the
        // second encoding of the global view that the type is failable to prevent.
        let resolved = OrganizeScope(path: scope, providerRoot: root)
        UserDefaults.standard.set(resolved?.path ?? "", forKey: OrganizeScopeDefaults.pathKey)
        revealInSourcePane(scope)
    }

    /// Points the source rail (the left pane) at an absolute folder inside the current provider.
    ///
    /// Silently does nothing for a path outside the root — a relative path computed against the
    /// wrong root would focus the pane on a folder that does not exist, which looks exactly like a
    /// broken palette rather than like a stale index.
    private func revealInSourcePane(_ absolutePath: String) {
        let root = tidyProviderRootExpanded
        guard !root.isEmpty,
              let relative = PathBoundary.relativize(absolutePath, under: root) else { return }
        syncManager.focusOn(relativePath: relative, isLeft: true)
    }

    private func runPaletteAction(_ action: PaletteAction) {
        switch action {
        case .rescan: shortcutRescan?()
        case .newFolder: shortcutNewFolder?()
        case .chooseFolder: chooseFolderSource { leftProviderId = $0 }
        case .findInPane: beginPaneSearch()
        case .settings: showSettings = true
        case .shortcuts: openWindow(id: "keyboard-shortcuts")
        case .activityLog: openWindow(id: "activity-log")
        }
    }

    /// The palette, over the window on its own scrim.
    @ViewBuilder
    var commandPaletteOverlay: some View {
        CommandPaletteView(
            rows: paletteRows,
            query: Binding(get: { paletteQuery },
                           set: { newValue in
                               paletteQuery = newValue
                               // The selection follows the list rather than standing where it was:
                               // an index into the PREVIOUS results names a different row after a
                               // keystroke, so ↩ would run something the user never looked at.
                               paletteSelection = PaletteSelection.initialIndex(
                                   in: PaletteRouter.rows(query: newValue, index: paletteIndex))
                           }),
            selection: $paletteSelection,
            accent: glassHue.accentColor,
            glassLevel: glassLevel,
            onRun: { runPaletteRoute($0) },
            onClose: { closeCommandPalette() })
    }
}
