import SwiftUI
import AppKit
import Design
import FileExplorer
import Sync
import Dashboard
import Events
import Settings

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
        // **"Go to…", which is what the control is called.** The field's own accessibility label is
        // "Go to" (`GoToFieldBar`), and this item said "Command Palette…" for the whole of v4.1 —
        // one surface with two names, because the field shipped and the naming did not follow it.
        // The TYPE names stay `CommandPalette*`: internally it is still a palette, and renaming a
        // file is not what makes a menu honest.
        //
        // Ellipsis: it opens a field, it does not do anything yet.
        Button("Go to…") { palette?() }
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

    /// ⌘K opens, and on an already-open field **selects** rather than closing — Escape is the close.
    /// (It toggled until 2026-08-18; the body below carries why it stopped.) Every open starts from
    /// an empty query — a palette that reopened holding the last thing you typed would answer a
    /// question you have already had answered, and the reset is what keeps the empty-query landing
    /// (recents, then places) reachable after the first use.
    ///
    /// **It raises a panel rather than flipping an overlay flag**, for the reasons recorded at the
    /// top of `CommandPalettePanel.swift`: as an in-window overlay its clicks and keystrokes went
    /// through to the AppKit file panes underneath it.
    func toggleCommandPalette() {
        if palettePanel.isPresented {
            // **⌘K on an already-open field selects what is in it** rather than closing — decided
            // 2026-08-18, and it retires the shipped behaviour where the chord toggled. Escape is
            // the close, which it already was for everything except this one chord, and selecting
            // is what every other search field on the Mac does: the fastest way to ask a different
            // question is one keystroke over the old one.
            goToFocusToken += 1
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
        // **Who holds the caret right now**, captured before the field exists — the field is in
        // this window's toolbar, so opening it takes first responder away from whatever the user
        // was using, and closing it has to give that back. Measured 2026-08-19: without this the
        // window itself was left as first responder (`<SwiftUI.AppKitWindow>`), and the pane
        // stopped answering arrow keys and type-select until it was clicked. It could not happen
        // before §7, when the field lived in the palette's own panel and never touched this
        // window's responder.
        let caretWasWith = Self.caretHolder(in: host)
        let index = paletteIndex
        let state = CommandPaletteState(index: index, pathProbe: Self.pathKind)
        // The field is what the user types into now, so it opens first and the list follows it.
        goToQuery = ""
        showCommandPalette = true
        goToFocusToken += 1
        palettePanel.present(
            over: host, state: state, accent: glassHue.accentColor, glassLevel: glassLevel,
            // Asked for lazily, and asked again on every window move: the list hangs off the
            // field's own frame, and the field is a toolbar item that SwiftUI has not necessarily
            // mounted yet at this instant. `refreshAnchor` retries rather than measuring once.
            anchor: { Self.goToFieldScreenFrame(in: host) },
            onRun: { [self] route in runPaletteRoute(route) },
            onDismiss: {
                showCommandPalette = false
                // Cleared on close. §7 decided a 30-second memory would replace this line;
                // **that was deferred past v4.2 on 2026-08-19**, so clearing is the shipped rule
                // rather than a placeholder. The argument for the memory, and the ↩ hazard that
                // sets its length, are kept in ROADMAP_V4 §7 for whoever picks it up.
                goToQuery = ""
                // **Here, not in the field's own teardown.** Measured: by the time SwiftUI removes
                // the field from the window, AppKit has already dropped the field editor and the
                // window is its own first responder — a rule asked at that point correctly declines
                // to act on a caret the field no longer holds, and restores nothing. This fires
                // while the caret is still in the field, which is the moment the question can be
                // answered.
                Self.restoreCaret(to: caretWasWith, in: host)
            })
        // **The flag is raised BEFORE `present` now, and it has to be**: the panel anchors itself
        // to the toolbar field, and the field does not exist until this flag says the toolbar item
        // is open. The hazard the old ordering guarded — `present` retiring a previous
        // presentation and its `onDismiss` lowering the flag a line later — cannot reach here,
        // because the toggle above returns early when one is up, so there is nothing to retire.
        // Logged for the same reason the person gather logs its accept: this surface is
        // keyboard-only, its chord is a menu key equivalent, and nothing short of assistive access
        // can drive it from a script — so the log is the only place a run that is not a human's can
        // be checked afterwards. The counts are what say the index was BUILT, not merely that
        // something appeared over an empty one.
        Logger.shared.info("Command palette opened — \(state.rows.count) rows from "
            + "\(index.folders.count) folders, \(index.people.count) people, "
            // The tabs are counted for the same reason the other three are: this line's job is to
            // say the index was BUILT. They cross a package wall as injected data, so the way they
            // go missing is the `map` above quietly handing over fewer — and without a count here
            // an empty list and a full one write exactly the same line.
            + "\(index.providers.count) sources, \(index.settingsTabs.count) settings tabs")
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
        // `root` is the pane's SOURCE ROOT, and everything in the index is relative to it — the
        // recents and pins below, and any path the user types. The folder profile is surveyed over
        // the source's anchor instead, which sits inside that root, so `PaletteIndex.folders`
        // re-bases its keys rather than being handed a second base to measure them against.
        let folders = PaletteIndex.folders(profileRoot: profile?.root, providerRoot: root,
                                           keys: Array(profile?.folders.keys ?? [:].keys))
        // The same re-base, as the segment rather than as the result: the ranker subtracts it so a
        // folder is scored on the part of its path that distinguishes it, not on the `Documents`
        // every key now shares. One rule, called twice — never re-derived here.
        let folderPrefix = PaletteIndex.folderPrefix(profileRoot: profile?.root,
                                                     providerRoot: root) ?? ""
        // **Both remembered lists in one pass**, so the root is `stat`ed once rather than twice —
        // under an unreachable network mount each of those can block.
        let remembered = Self.reachableFolders(
            recents: FolderJumpStore.shared.recentPaths(forRoot: root),
            pinned: FolderJumpStore.shared.pinnedPaths(forRoot: root), under: root)
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
                                isMounted: Self.isMountedFolder(provider.rootPath),
                                // "The current source" means the pane this palette is aimed at —
                                // the focused one in Compare — for the same reason the folder rows
                                // are indexed from its root. Asking `leftProviderId` had a
                                // right-root index calling the left provider current.
                                isCurrent: provider.id == paletteProviderId,
                                // Expanded, for the reason `isMounted` is expanded above: a
                                // hand-typed `~/…` in Settings is stored verbatim, and Go to
                                // Folder compares this against a path it has already expanded.
                                root: (provider.rootPath as NSString).expandingTildeInPath)
            },
            providerRoot: root.isEmpty ? nil : root,
            folders: folders,
            folderPrefix: folderPrefix,
            // The one recents list — `FolderJumpStore` is already fed by every pane focus change
            // (see ContentView's `onChange(of: leftRelativePath)`), and it carries the pins too.
            //
            // **Resolved here, where the list is drawn, and filtered rather than pruned from the
            // store.** Recents persist across launches as of v4.2, so this list now routinely
            // outlives the folders in it — renamed, deleted, or on a drive that is not awake. A row
            // that cannot deliver its destination should not be offered; an entry whose drive is
            // merely asleep should not be destroyed. `reachable` holds both ends, and stops at the
            // root so an unreachable mount costs one stalled `stat` rather than a dozen.
            recentFolders: remembered.recents,
            pinnedFolders: remembered.pinned,
            // Nil while the root answers. When it does not, every folder row is listed marked with
            // this rather than dropped — decided 2026-08-19; the wording is the one an unmounted
            // provider already uses, so the two read as the same kind of fact. **Every folder row,
            // not just the remembered ones**: the survey's folders are held in memory and answer a
            // typed query whether or not the disk is awake, so marking only the landing said "this
            // drive is not there" and then offered the same tree as live the moment anything was
            // typed.
            foldersUnavailable: remembered.rootIsAvailable ? nil : "Not available",
            people: syncManager.filingPersonRegistry?.people ?? [],
            registry: syncManager.filingPersonRegistry,
            isScanning: isScanning || syncManager.isSuggestingFiles,
            // The same pair the person gather itself needs. The roster can outlive the survey, and
            // an offer whose accept does nothing is what `acceptPersonScope`'s failure path exists
            // to say out loud; the palette says it before you press ↩ instead.
            hasSurvey: syncManager.filingFolderProfile != nil
                && syncManager.filingProfilesDirectory != nil,
            // **`SettingsTab.digests` whole, never a hand-picked list**, and never a literal built
            // here. This file is in `MacApp`, which belongs to no SPM package, so a subset written
            // here would compile forever and simply make some tabs unreachable from ⌘K — nothing
            // would fail. The derivation lives in `Settings` where `SettingsTests` compiles it, and
            // `theHostOffersEverySettingsTab` in `SyncCloudTests` is what holds this line to
            // passing all of it through.
            settingsTabs: SettingsView.SettingsTab.digests.map {
                PaletteSettingsTab(id: $0.id, name: $0.name, detail: $0.detail,
                                   symbol: $0.symbol, vocabulary: $0.vocabulary)
            })
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
            else {
                // The index is snapshotted when the palette opens, so a roster that changed
                // underneath it can leave a row naming somebody the registry no longer has. Said
                // out loud rather than returned silently: ↩ on a row that visibly offered a person
                // and then did nothing is exactly the "nothing happened" this surface's whole
                // logging exists for.
                Logger.shared.warning("Command palette: person \(id) is no longer in the registry — "
                    + "the row was listed from an index taken when the palette opened")
                return
            }
            acceptPersonScope(person)
        case .provider(let id):
            // Switched on the pane the palette is aimed at, so choosing a source from ⌘K changes
            // the one whose folders it was just listing.
            aimProvider(id)
        case .folder(let path):
            revealInSourcePane(path)
        case .action(let action):
            runPaletteAction(action)
        case .settings(let raw):
            guard let tab = SettingsView.SettingsTab(rawValue: raw) else {
                // The raw value crosses the package wall as a string, so a tab renamed on one side
                // and not the other lands here. Said out loud rather than opening the sheet on
                // whatever was last selected: ↩ on a row that named Appearance and delivered
                // Advanced is worse than ↩ that visibly did nothing, and this is the surface whose
                // whole logging exists for the "nothing happened" case.
                Logger.shared.warning("Command palette: \(raw) is not a settings tab — "
                    + "the row was built from a digest this app no longer recognises")
                return
            }
            openSettings(on: tab)
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

    /// The store's rule, wired to the real disk. Separate from `FolderJumpStore.reachable` so the
    /// rule stays testable without one, and `static` for the reason `isMountedFolder` is.
    static func reachableFolders(recents: [String], pinned: [String],
                                 under root: String) -> RememberedFolders {
        FolderJumpStore.reachable(recents: recents, pinned: pinned, underRoot: root,
                                  isDirectory: isMountedFolder)
    }

    /// Where the Go-to field is on screen, or `nil` if the toolbar is not showing one.
    ///
    /// Found by looking for the one editable text field in the toolbar rather than by item index:
    /// the item's identifier is a UUID SwiftUI mints per build, and an index would silently start
    /// measuring the Info button the first time an item is added before it.
    ///
    /// The whole ITEM's view is what is returned, not the text field inside it — the list aligns to
    /// the control's capsule, which includes the magnifier and the key beside the text.
    static func goToFieldScreenFrame(in host: NSWindow) -> CGRect? {
        guard let view = goToFieldItemView(in: host) else { return nil }
        return host.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// The toolbar item's view that holds the Go-to field, or `nil` when the row is showing the
    /// closed pill.
    ///
    /// **`view.window === host` is a precondition, not a nicety.** `NSToolbar.items` includes items
    /// macOS has folded behind the overflow chevron, whose views are out of the window's hierarchy
    /// — `convert(_:to: nil)` on one of those answers in its own bounds and the frame that comes
    /// back is the window's bottom-left corner, at a plausible width. That is an anchor the caller
    /// cannot tell from a real one, so it is refused here and the caller's retry (and then its
    /// warning) does its job instead.
    ///
    /// **Loosening this to `view.window != nil` was tried on 2026-08-19 and backed out.** The
    /// argument for it: the conversion is wrong only when the view has no window at all, so the
    /// caller could convert through whatever window the view *is* in, and AppKit is understood to
    /// host a window's titlebar and toolbar in a separate full-screen toolbar window — which the
    /// strict form would refuse, costing a full-screen user the palette now that running out of
    /// anchor retries hides it. Two things stopped it. The loosened form promptly handed back a
    /// confident anchor at `(1272, 444)` for a host parked at `(-9000, -9000)`, which is the exact
    /// class of wrong answer this guard exists to refuse; and **the full-screen premise could not be
    /// verified** — a bare `swiftc` binary cannot enter full screen (`styleMask` never gains
    /// `.fullScreen`, measured), and no test host can either. An unverified premise is not grounds
    /// for widening a guard, so the risk was taken out of the other end instead: exhausting the
    /// retries hides the list rather than closing the palette, which is never worse than what
    /// shipped whichever way the premise falls. Settle it by pressing ⌘K in a full-screen window
    /// and reading the `[palette] placed under field=` line in `~/sync-cloud.log`.
    static func goToFieldItemView(in host: NSWindow) -> NSView? {
        guard let toolbar = host.toolbar else { return nil }
        for item in toolbar.items {
            guard let view = item.view, view.window === host, containsEditableField(view)
            else { continue }
            return view
        }
        return nil
    }

    /// **Who to hand the caret back to**, resolved from whoever is holding it at ⌘K time.
    ///
    /// Not `host.firstResponder` itself, and that is the whole point: **a window has ONE field
    /// editor**, shared by every `NSTextField` in it, so while the user is typing in a pane's Find
    /// field the first responder is that `NSTextView` rather than the field. Remembering the editor
    /// remembers nothing — by the time ⌘K closes, the very same object has been re-bound to the
    /// Go-to field, so `makeFirstResponder` on it puts the caret where it already is and the pane's
    /// field never gets it back. The editor's `delegate` is the control being edited, which is the
    /// thing that survives the handover.
    ///
    /// A responder that is not a field editor is already the thing to restore — a file pane's
    /// table, which is the case this was written for — and is returned unchanged.
    static func caretHolder(in host: NSWindow) -> NSResponder? {
        guard let editor = host.firstResponder as? NSTextView, editor.isFieldEditor else {
            return host.firstResponder
        }
        return editor.delegate as? NSResponder ?? editor
    }

    /// Puts the caret back where ⌘K found it, if ⌘K is still holding it.
    ///
    /// Both refusals carry as much weight as the restore:
    ///
    /// - **Only if the caret is in the Go-to field.** Every close path runs this, including the one
    ///   where the user clicked into a pane — and there they have already said where focus goes.
    /// - **Only to a view still in this window.** A remembered responder whose view has since been
    ///   torn down would move the caret somewhere invisible, which is worse than the window keeping
    ///   it.
    static func restoreCaret(to previous: NSResponder?, in host: NSWindow) {
        restoreCaret(to: previous, in: host, caretIsInField: caretIsInTheGoToField(host))
    }

    /// The rule itself, with the one fact that needs a laid-out toolbar passed in rather than
    /// asked for — an `NSToolbarItem`'s view is only in a window once AppKit has displayed the
    /// toolbar, which no test host does, so asking here would make every assertion below vacuous.
    static func restoreCaret(to previous: NSResponder?, in host: NSWindow, caretIsInField: Bool) {
        guard caretIsInField, let previous else { return }
        if let view = previous as? NSView, view.window !== host { return }
        host.makeFirstResponder(previous)
    }

    /// Whether the window's first responder is the editor of the toolbar's Go-to field.
    ///
    /// Asked of the field editor rather than of the field: an `NSTextField` being typed into is
    /// never itself the first responder — the window's shared `NSTextView` is, with the field as
    /// its delegate.
    static func caretIsInTheGoToField(_ host: NSWindow) -> Bool {
        guard let editor = host.firstResponder as? NSTextView,
              let field = editor.delegate as? NSView,
              let item = goToFieldItemView(in: host) else { return false }
        return field.isDescendant(of: item)
    }

    private static func containsEditableField(_ view: NSView) -> Bool {
        if let field = view as? NSTextField, field.isEditable { return true }
        return view.subviews.contains(where: containsEditableField)
    }

    /// What is at a typed path — **Go to Folder's** one disk question, wired to the real disk.
    ///
    /// No tilde expansion here, deliberately: `PalettePath.absolute` has already done it against
    /// the index's `home`, and a second expansion would be a second rule. `PalettePath` bounds when
    /// this is called at all — never outside a source, never under one that is not mounted — which
    /// is what makes a `stat` acceptable on the keystroke path.
    static func pathKind(_ path: String) -> PathKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        else { return .missing }
        return isDirectory.boolValue ? .directory : .file
    }

    /// Whether a source's folder is there right now. Expanded first, and required to be a
    /// directory — the app's own validity rule (`SettingsManager`), asked the same way. (This doc
    /// spent two commits attached to `reachableFolders` above, which is not what it describes.)
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
    /// Internal rather than private: View ▸ Organize's sections route through this too, so the
    /// menu and ⌘K aim Organize the same way. See `shortcutOrganizeLens`.
    func aimOrganize(lens: OrganizeLens?, scope: String?) {
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
        // Through `setOrganizeScope(_:providerRoot:)` — **the one write of Organize's scope**, where
        // pointing at the provider root CLEARS the scope rather than storing it as one — and BEFORE
        // the workspace moves, for the reason above: `lensProviderRootExpanded` still names the
        // aimed pane's root on this line. This used to be a second inline spelling of that
        // normalization, sitting under a comment asserting there is exactly one. A scope-less route
        // touches nothing — nil here means "don't re-aim", not "clear".
        //
        // **The focused pane IS the right root here**, unlike the row menus that share this method:
        // the palette is aimed at that pane throughout, which is the same rule the folder index and
        // the recents list on this screen were built from. The parameter is named rather than
        // defaulted so that stays a statement instead of an assumption.
        if let scope { setOrganizeScope(scope, providerRoot: lensProviderRootExpanded) }
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
        paletteRailLens = lens
        guard let scope else { return }
        revealInSourcePane(scope, root: root, isLeft: revealIntoLeft)
    }

    /// One provider's root, tilde-expanded — the same shape `lensProviderRootExpanded` computes for
    /// whichever pane the lenses target, asked here about a named pane instead. Both roots are
    /// needed to decide the swap, and only one of them is ever the lens target.
    private func providerRootExpanded(_ id: String) -> String {
        (settings.rootPath(for: id) as NSString).expandingTildeInPath
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

    /// Where a reveal lands, or why it cannot.
    ///
    /// **Extracted because the two refusals are otherwise unreachable from a test** — the caller is
    /// a method on a SwiftUI `View` with `@State`, which nothing can construct — and they are
    /// precisely the branches worth holding: each is an accepted route delivering nothing.
    enum RevealOutcome: Equatable {
        case focus(relativePath: String)
        /// The aimed pane has no source path at all.
        case noSource
        /// The path is real but not inside the root this pane is showing.
        case outsideSource(root: String)
    }

    static func revealOutcome(for absolutePath: String, under root: String) -> RevealOutcome {
        guard !root.isEmpty else { return .noSource }
        guard let relative = PathBoundary.relativize(absolutePath, under: root) else {
            return .outsideSource(root: root)
        }
        return .focus(relativePath: relative)
    }

    /// Points the source pane at an absolute folder inside the current provider, or **says why it
    /// could not** — the two refusals here are the last thing between an accepted route and nothing
    /// at all happening.
    ///
    /// Both were silent `return`s until 2026-08-20. Neither is supposed to be reachable from the
    /// palette: a folder row is built from the survey under this root, and Go to Folder now refuses
    /// a typed path that is not inside `PaletteIndex.providerRoot` before ever offering it. But
    /// "not supposed to be reachable" is exactly the claim a log line is for — the index is a
    /// **snapshot** taken when the palette opened, and the root read here is live, so a provider
    /// that changed underneath an open palette lands here with a row the user watched do nothing.
    ///
    /// **The pane it points at is the one the index was built from**, which is not always the left
    /// one. `lensProviderRootExpanded` follows the focused pane in Compare, so every folder row in
    /// the palette is relative to the *right* provider's tree when the right pane has focus. This
    /// revealed into the left pane regardless: the guard passed (the path really is under that
    /// root), a relative path from one provider's tree was handed to the other's, and the pane
    /// jumped to a folder that most likely does not exist there — the exact "looks like a broken
    /// palette" outcome `revealOutcome` was written to avoid, reached by a different route.
    ///
    /// - Parameters:
    ///   - root: the provider root the path is relative to, and `isLeft` the pane that owns it.
    ///     Passed in rather than re-read, because a caller may already have changed the workspace
    ///     — and both values follow it. See `aimOrganize`.
    private func revealInSourcePane(_ absolutePath: String,
                                    root: String? = nil, isLeft: Bool? = nil) {
        switch Self.revealOutcome(for: absolutePath, under: root ?? lensProviderRootExpanded) {
        case .focus(let relative):
            syncManager.focusOn(relativePath: relative, isLeft: isLeft ?? !aimedAtRight)
        case .noSource:
            Logger.shared.warning("Command palette: nowhere to reveal \(absolutePath) — "
                + "the aimed pane has no source path")
        case .outsideSource(let root):
            Logger.shared.warning("Command palette: \(absolutePath) is not inside \(root) — "
                + "the row was offered against a source the pane is no longer showing")
        }
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
