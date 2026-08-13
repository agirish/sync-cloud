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
        let root = lensProviderRootExpanded
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
            aimProvider(id)
        case .folder(let path):
            revealInSourcePane(path)
        case .action(let action):
            runPaletteAction(action)
        }
    }

    /// The provider whose tree the palette is describing — the focused pane's in Compare, the
    /// left rail's otherwise. The same rule `lensProviderRootExpanded` follows, named once so the
    /// index's rows and its "current source" mark cannot disagree about which pane they mean; the
    /// writes go through `aimProvider(_:)`, which reads this.
    var paletteProviderId: String { aimedAtRight ? rightProviderId : leftProviderId }

    /// Which pane the palette is aimed at, as a value that can be captured before a route changes
    /// the workspace out from under it.
    var aimedAtRight: Bool { lensTargetIsRight }

    /// Points the aimed pane at `id` — the write half of `paletteProviderId`.
    ///
    /// Its own member because the rule was restated at each write, which is the drift this session
    /// removed in three other places by delegating instead of repeating: `paletteProviderId` could
    /// say "the index's rows and its provider writes cannot disagree" only because someone had
    /// typed the same ternary three times.
    func aimProvider(_ id: String) {
        if aimedAtRight { rightProviderId = id } else { leftProviderId = id }
    }

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
    /// The scope is written to the defaults key `LensWorkspaceView` reads, because that is where the scope
    /// lives — a view-local copy here would be a second source of truth for the one thing the whole
    /// Organize feature is anchored on. The pane follows the scope, so the source rail is showing
    /// the folder the lenses are answering about rather than wherever it happened to be parked.
    private func aimOrganize(lens: OrganizeLens?, scope: String?) {
        // **The aim is read BEFORE the workspace moves, because moving it changes the aim.**
        // `lensProviderRootExpanded` follows the focused pane, and only Compare has two — so
        // switching to Organize makes it the left pane's root unconditionally. The scope string in
        // hand came from an index built against the *aimed* pane when the palette opened, so
        // resolving it afterwards measured it against a different provider: `OrganizeScope` failed
        // and the scope key was written `""`, silently clearing the scope instead of setting
        // it. The object of "organize legal" was discarded, which is the one thing the verb rows
        // exist to prevent.
        //
        // **Both halves of the aim are captured here, for the one reason.** Which pane, not just
        // which root: `aimedAtRight` is computed, and it reads `layoutMode == .compare && activePane
        // == .right`. The line below leaves Compare, so re-reading it afterwards answers `false`
        // however the palette was aimed — and a right-pane scope was being revealed into the LEFT
        // pane, relativized against the RIGHT provider's root. That is precisely the "path from one
        // provider's tree handed to the other's" failure `revealInSourcePane`'s own doc describes
        // as fixed; the fix had reached `root` and stopped there. A value that follows the
        // workspace has to be read on this side of the move or not read at all.
        let root = lensProviderRootExpanded
        var revealIntoLeft = !aimedAtRight
        // **Organize shows ONE provider, and it is the left pane's.** Capturing the aim above fixed
        // where the reveal lands; it cannot fix which tree Organize is looking at. `organizeScope`
        // re-resolves the stored path against the LIVE `lensProviderRootExpanded` — deliberately,
        // so a scope belonging to a tree that is no longer showing degrades to the global view —
        // and outside Compare that root is always the left pane's. So "organize Legal" aimed at the
        // right pane wrote a good scope and then had it resolve to nil on the very next read: no
        // chip, no filter, the folder silently discarded.
        //
        // Rather than move the workspace under the user or drop the request, ask. The rule itself
        // is `PaneLogic.organizeAimNeedsPaneSwap`, decided with `OrganizeScope` so it and the
        // resolver cannot disagree; it is nil-scoped here so "a swap is needed" cannot be
        // representable without the folder that needs it.
        let swapScope: String? = PaneLogic.organizeAimNeedsPaneSwap(
            scope: scope, aimedAtRight: aimedAtRight,
            leftRoot: providerRootExpanded(leftProviderId),
            rightRoot: providerRootExpanded(rightProviderId)) ? scope : nil
        if let swapScope {
            // **Cancel means nothing happens at all** — this returns above every write below, so
            // there is no scope write to undo, no rail move and no workspace change. A dialog that
            // left half the route applied would be worse than the silent degrade it replaces.
            guard confirmOrganizePaneSwap(folder: swapScope) else {
                Logger.shared.info("Command palette: pane swap declined — Organize route abandoned")
                return
            }
        }
        // Through `setOrganizeScope(_:)` — **the one write of Organize's scope**, where pointing at
        // the provider root CLEARS the scope rather than storing it as one — and BEFORE the
        // workspace moves, for the reason above: the owner resolves against the live
        // `lensProviderRootExpanded`, which still names the aimed pane's root on this line. This
        // used to be a second inline spelling of that normalization, sitting under a comment
        // asserting there is exactly one. A scope-less route touches nothing — nil here means
        // "don't re-aim", not "clear".
        if let scope { setOrganizeScope(scope) }
        // **The swap goes here: after the scope is written, before the workspace moves.**
        //
        // After the write, because `setOrganizeScope` resolves against the live
        // `lensProviderRootExpanded` — which on the line above provably names the aimed pane's root
        // and after the swap would name the other provider, so a scope written on that side would
        // be measured against the tree it is NOT in and stored as `""`: the same silent clear, by
        // the fix's own hand. The stored path is absolute and nothing clears it on a provider
        // change, so it survives the swap and is re-resolved afterwards against the named
        // provider — now the left pane's — which is what brings the chip and the filter back.
        //
        // Before the move, because a swap is a Compare-shaped act: `swapPanesAction` can refuse it
        // (provider bootstrap, or file operations in flight), and refusing after the workspace had
        // already moved would land the user in Organize on the wrong provider — the outcome this
        // whole dialog exists to prevent — with the panes still un-swapped behind it.
        if swapScope != nil {
            // Not hand-rolled: `swapPanesAction` is the atomic swap — the manager's paired focus,
            // selections and histories, the review dispatch, and the `ProviderPinPlan` that keeps
            // the per-pane onChange resets from firing. Two of the three would be missed by
            // exchanging the two ids here.
            let aimedProviderId = paletteProviderId
            swapPanesAction()
            // **Asked, not assumed.** A refused swap leaves the named provider on the RIGHT, and
            // revealing into the left pane a path relativized against the right root is exactly the
            // "path from one provider's tree handed to the other's" defect `revealInSourcePane`
            // guards. So the reveal follows where the provider actually ended up.
            revealIntoLeft = leftProviderId == aimedProviderId
            if !revealIntoLeft {
                Logger.shared.warning("Command palette: the pane swap was refused — Organize will "
                    + "open on the other source")
            }
        }
        // Through the bar's own binding, so entering Organize does everything entering Organize
        // does — the review teardown and the rail presentation. (The person-scope clear moved to
        // `onChange(of: selectedWorkspace)`, so it now happens for this route either way.)
        workspaceSelection.wrappedValue = .filing
        // Through `@AppStorage`, never `UserDefaults.standard.set` — see `paletteRailLens` for the
        // write this app has already watched go missing.
        paletteRailLens = lens?.resolvedForPresentation
        guard let scope else { return }
        revealInSourcePane(scope, root: root, isLeft: revealIntoLeft)
    }

    /// One provider's root, tilde-expanded — the same shape `lensProviderRootExpanded` computes for
    /// whichever pane the lenses target, asked here about a named pane instead. Both roots are
    /// needed to decide the swap, and only one of them is ever the lens target.
    private func providerRootExpanded(_ id: String) -> String {
        (settings.path(for: id) as NSString).expandingTildeInPath
    }

    /// Asks whether to swap the panes so Organize can open on the source the route named.
    ///
    /// `NativeAlerts.confirmChange`, never `confirmDestructive`: nothing is deleted and doing it
    /// again puts the panes back, so the caution icon and the destructive default button would be
    /// spending a signal this app needs to keep meaning "files are going to the Trash".
    private func confirmOrganizePaneSwap(folder: String) -> Bool {
        let names = paneNames
        let prompt = Self.organizePaneSwapPrompt(folder: folder,
                                                 aimedProvider: names.right,
                                                 shownProvider: names.left)
        Logger.shared.info("Command palette: \(prompt.informativeText)")
        return NativeAlerts.confirmChange(messageText: prompt.messageText,
                                          informativeText: prompt.informativeText,
                                          // A verb, and the thing it does: "OK" on a dialog
                                          // explaining two states is a coin toss.
                                          confirmTitle: "Swap Panes")
    }

    /// The dialog's words, as a pure function of the three things it is about — so a test can hold
    /// them to naming the folder and BOTH sources. The failure this route had was losing the object
    /// of the request; a prompt that says "a folder" and "the other source" would be the same loss
    /// spelled politely.
    ///
    /// `static` for the same reason `isMountedFolder` is: nothing on a `ContentView` instance is
    /// reachable from a test.
    static func organizePaneSwapPrompt(folder: String, aimedProvider: String, shownProvider: String)
    -> (messageText: String, informativeText: String) {
        let name = (folder as NSString).lastPathComponent
        return (
            messageText: "Organize shows one source at a time.",
            informativeText:
                "“\(name)” is in \(aimedProvider), and Organize opens on the source in the left "
                + "pane — \(shownProvider). Swapping the panes puts \(aimedProvider) on the left, "
                + "so Organize opens there with “\(name)” still in scope. Compare keeps both "
                + "sources: its two sides trade places."
        )
    }

    /// Points the source pane at an absolute folder inside the current provider.
    ///
    /// Silently does nothing for a path outside the root — a relative path computed against the
    /// wrong root would focus the pane on a folder that does not exist, which looks exactly like a
    /// broken palette rather than like a stale index.
    ///
    /// **The pane it points at is the one the index was built from**, which is not always the left
    /// one. `lensProviderRootExpanded` follows the focused pane in Compare, so every folder row in
    /// the palette is relative to the *right* provider's tree when the right pane has focus. This
    /// revealed into the left pane regardless: the guard passed (the path really is under that
    /// root), a relative path from one provider's tree was handed to the other's, and the pane
    /// jumped to a folder that most likely does not exist there — the exact "looks like a broken
    /// palette" outcome the guard above was written to avoid, reached by a different route.
    /// - Parameters:
    ///   - root: the provider root the path is relative to, and `isLeft` the pane that owns it.
    ///     Passed in rather than re-read, because a caller may already have changed the workspace
    ///     — and both values follow it. See `aimOrganize`.
    private func revealInSourcePane(_ absolutePath: String,
                                    root: String? = nil, isLeft: Bool? = nil) {
        let root = root ?? lensProviderRootExpanded
        guard !root.isEmpty,
              let relative = PathBoundary.relativize(absolutePath, under: root) else { return }
        syncManager.focusOn(relativePath: relative, isLeft: isLeft ?? !aimedAtRight)
    }

    private func runPaletteAction(_ action: PaletteAction) {
        switch action {
        case .rescan: shortcutRescan?()
        case .newFolder: shortcutNewFolder?()
        // The aimed pane, like every other provider write here — see `paletteProviderId`. Adding
        // a source from ⌘K while the right pane is focused pointed the LEFT one at it, which also
        // fires that pane's provider-switch teardown on the side the user was not working in.
        case .chooseFolder:
            chooseFolderSource { id in aimProvider(id) }
        case .findInPane: beginPaneSearch()
        case .settings: showSettings = true
        case .shortcuts: openWindow(id: "keyboard-shortcuts")
        case .activityLog: openWindow(id: "activity-log")
        }
    }
}
