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
/// **A menu item, never `.onKeyPress`:** that modifier is strictly focus-scoped, and the palette is
/// wanted precisely when focus is in a file table, which is where it always is (the same argument
/// `FindInPaneCommand` makes for ⌘F). It also puts the chord in the menu bar, where someone looks
/// for a shortcut they half-remember.
struct CommandPaletteCommand: View {
    @FocusedValue(\.commandPalette) private var palette

    var body: some View {
        // "Go to…", what the control is called: the field's accessibility label is "Go to"
        // (`GoToFieldBar`), so one surface has one name. The type names stay `CommandPalette*`.
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

// MARK: - The toolbar field's query

/// What is typed in the toolbar's Go-to field, in an object of its own.
///
/// So that typing redraws the field and nothing else, the reason `EditorBuffer` is split from
/// `EditorDocument`: as `@State` on `ContentView`, every keystroke would invalidate the window's
/// body. `ContentView` holds this without observing it; `GoToFieldHost` observes it and forwards
/// each change.
@MainActor
final class GoToQuery: ObservableObject {
    @Published var text = ""
}

/// `GoToFieldBar`, bound to the query object and forwarding every keystroke to the list that is
/// answering it.
struct GoToFieldHost: View {
    @ObservedObject var query: GoToQuery
    let onQuery: (String) -> Void
    let mode: GoToFieldBar.Mode
    let chord: String
    let focusToken: Int
    let accent: Color
    let onOpen: () -> Void
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        GoToFieldBar(mode: mode, query: $query.text, chord: chord, focusToken: focusToken,
                     accent: accent, onOpen: onOpen, onMove: onMove, onSubmit: onSubmit,
                     onCancel: onCancel)
            .onChange(of: query.text) { _, typed in onQuery(typed) }
    }
}

// MARK: - ContentView's half

extension ContentView {

    /// ⌘K opens, and on an already-open field selects rather than closing; Escape is the close.
    /// Every open starts from an empty query, which keeps the empty-query landing (recents, then
    /// places) reachable after the first use.
    ///
    /// It raises a panel rather than flipping an overlay flag, for the reasons at the top of
    /// `CommandPalettePanel.swift`: an in-window overlay's clicks and keystrokes go through to the
    /// AppKit file panes underneath it.
    func toggleCommandPalette() {
        if palettePanel.isPresented {
            // ⌘K on an already-open field selects what is in it, as every other search field on
            // the Mac does: the fastest way to ask a different question is to type over the old.
            goToFocusToken += 1
            return
        }
        // The suspension is on the act, not on one publication. Nilling
        // `effectiveCommandPalette` reaches only the menu item; the toolbar pill
        // (`ContentView+Toolbar.swift`) and `paletteOnLaunchArmed` call this directly. Over a
        // pending destination pick, ↩ on a workspace row would switch workspace mid-pick.
        guard pendingDestination == nil else {
            // `.info`, not `.debug`: the only refusal a user can trigger, recording a control that
            // appeared to do nothing, and `.debug` is dropped at Settings ▸ Advanced ▸ Info.
            Logger.shared.info("⌘K ignored: the destination picker owns the keyboard")
            return
        }
        guard let host = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible)
        else {
            // No window to hang it on. Logged, because ⌘K appearing dead has no other trace.
            Logger.shared.warning("⌘K pressed with no window to present the command palette over")
            return
        }
        // Who holds the caret now, captured before the field exists: the field is in this
        // window's toolbar, so opening it takes first responder from whatever the user was using,
        // and closing it must give that back. Otherwise the window itself is left as first
        // responder and the pane ignores arrow keys and type-select until clicked.
        let caretWasWith = Self.caretHolder(in: host)
        let index = paletteIndex
        let state = CommandPaletteState(index: index, pathProbe: Self.pathKind)
        // The field is what the user types into now, so it opens first and the list follows it.
        goToQuery.text = ""
        showCommandPalette = true
        goToFocusToken += 1
        palettePanel.present(
            over: host, state: state, accent: glassHue.accentColor, glassLevel: glassLevel,
            // Asked lazily, and again on every window move: the list hangs off the field's frame,
            // and SwiftUI may not have mounted that toolbar item yet. `refreshAnchor` retries.
            anchor: { Self.goToFieldScreenFrame(in: host) },
            onRun: { [self] route in runPaletteRoute(route) },
            onDismiss: {
                showCommandPalette = false
                // Cleared on close: the next open starts from an empty query.
                goToQuery.text = ""
                // Here, not in the field's own teardown: by the time SwiftUI removes the
                // field, AppKit has dropped the field editor and the rule rightly restores nothing.
                // This fires while the caret is still in the field.
                Self.restoreCaret(to: caretWasWith, in: host)
            })
        // **The flag is raised before `present`, and must be:** the panel anchors to the toolbar
        // field, which does not exist until the flag opens the toolbar item. A previous
        // presentation can't be retired here, since the toggle above returns early when one is up.
        // Logged because nothing short of assistive access can drive this surface from a script,
        // so the log is where a run is checked afterwards; the counts say the index was built.
        Logger.shared.info("Command palette opened — \(state.rows.count) rows from "
            + "\(index.folders.count) folders, \(index.people.count) people, "
            // Counted like the other three: they cross a package wall as injected data, so
            // without a count an empty list and a full one write the same line.
            + "\(index.providers.count) sources, \(index.settingsTabs.count) settings tabs")
    }

    /// What the router is allowed to read, assembled from live state.
    ///
    /// Folders come from the survey's folder profile, not from a disk walk: the profile is already
    /// in memory and knows every folder under the root. Read once, when the palette opens
    /// (`CommandPaletteState` holds the result for that session), so it is off the keystroke path.
    var paletteIndex: PaletteIndex {
        let root = lensProviderRootExpanded
        let profile = syncManager.filingFolderProfile
        // The rule is `PaletteIndex.folders`, not spelled out here (it includes a tilde
        // expansion). `root` is the pane's source root, and everything in the index is relative to
        // it. The profile is surveyed over the source's anchor, inside that root, so
        // `PaletteIndex.folders` re-bases its keys onto `root`.
        let folders = PaletteIndex.folders(profileRoot: profile?.root, providerRoot: root,
                                           keys: Array(profile?.folders.keys ?? [:].keys))
        // The same re-base, as the segment: the ranker subtracts it so a folder is scored on the
        // part of its path that distinguishes it, not on the `Documents` every key shares.
        let folderPrefix = PaletteIndex.folderPrefix(profileRoot: profile?.root,
                                                     providerRoot: root) ?? ""
        // Both remembered lists in one pass, so the root is `stat`ed once: under an unreachable
        // network mount each `stat` can block.
        let remembered = Self.reachableFolders(
            recents: FolderJumpStore.shared.recentPaths(forRoot: root),
            pinned: FolderJumpStore.shared.pinnedPaths(forRoot: root), under: root)
        return PaletteIndex(
            providers: settings.enabledProviders.map { provider in
                PaletteProvider(id: provider.id, name: provider.displayName,
                                // An unmounted source is dimmed, not dropped: the folder is just
                                // not there right now (an unplugged SSD, a signed-out account).
                                // Tilde-expanded and a directory, as Settings validates it, since
                                // Settings stores a hand-typed `~/…` verbatim.
                                isMounted: Self.isMountedFolder(provider.rootPath),
                                // The current source is the pane the palette is aimed at (the
                                // focused one in Compare), the pane the folder rows come from.
                                isCurrent: provider.id == paletteProviderId,
                                // Expanded, as for `isMounted`: Go to Folder compares this
                                // against a path it has already expanded.
                                root: (provider.rootPath as NSString).expandingTildeInPath)
            },
            providerRoot: root.isEmpty ? nil : root,
            folders: folders,
            folderPrefix: folderPrefix,
            // The one recents list: `FolderJumpStore` is fed by every pane focus change (see
            // ContentView's `onChange(of: leftRelativePath)`) and carries the pins too.
            //
            // Filtered here, where the list is drawn, never pruned from the store: recents persist
            // across launches and outlive folders that are renamed, deleted, or on a drive that is
            // asleep. A row that can't deliver is not offered; an entry whose drive is asleep is not
            // destroyed. `reachable` stops at the root, so an unreachable mount costs one stalled
            // `stat` rather than a dozen.
            recentFolders: remembered.recents,
            pinnedFolders: remembered.pinned,
            // Nil while the root answers. When it does not, every folder row is marked with this
            // rather than dropped, in the wording an unmounted provider uses. Every row, not just
            // the remembered ones: the survey's folders answer a typed query from memory whether or
            // not the disk is awake.
            foldersUnavailable: remembered.rootIsAvailable ? nil : "Not available",
            people: syncManager.filingPersonRegistry?.people ?? [],
            registry: syncManager.filingPersonRegistry,
            isScanning: isScanning || syncManager.isSuggestingFiles,
            // The same pair the person gather needs. The roster can outlive the survey, so the
            // palette says a person can't be gathered before ↩ rather than after.
            hasSurvey: syncManager.filingFolderProfile != nil
                && syncManager.filingProfilesDirectory != nil,
            // **`SettingsTab.digests` whole, never a hand-picked list or a literal built here:** a
            // subset in `MacApp` would compile and silently make tabs unreachable from ⌘K. The
            // derivation lives in `Settings`, and `theHostOffersEverySettingsTab` holds this line
            // to passing all of it through.
            settingsTabs: SettingsView.SettingsTab.digests.map {
                PaletteSettingsTab(id: $0.id, name: $0.name, detail: $0.detail,
                                   symbol: $0.symbol, vocabulary: $0.vocabulary, pages: $0.pages,
                                   pageOrder: $0.pageOrder)
            })
    }

    /// Applies a route: the only place in the app that turns a `PaletteRoute` into state, so the
    /// routing table's tests and the behaviour cannot come apart. The panel has already dismissed
    /// itself (the `onRun` wrapper in `CommandPalettePanelController.present`), so a route that
    /// changes workspace lands on a window that is key again.
    func runPaletteRoute(_ route: PaletteRoute) {
        Logger.shared.info("Command palette → \(route)")
        switch route {
        case .browse:
            workspaceSelection.wrappedValue = .browse
        case .compare:
            workspaceSelection.wrappedValue = .compare
        case .editor:
            workspaceSelection.wrappedValue = .editor
        case .organize(let lens, let scope):
            aimOrganize(lens: lens, scope: scope)
        case .person(let id):
            guard let person = syncManager.filingPersonRegistry?.people.first(where: { $0.id == id })
            else {
                // The index is a snapshot from when the palette opened, so a row can name somebody
                // the registry has since dropped. Logged, because ↩ that visibly does nothing must
                // leave a trace.
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
        case .folderInSource(let providerId, let path):
            switchSourceAndReveal(providerId: providerId, path: path)
        case .action(let action):
            runPaletteAction(action)
        case .settings(let raw):
            // `tab` or `tab/page`: the page a word was found on, when the row matched through one.
            guard let place = SettingsPlace(paletteRoute: raw) else {
                // The raw value crosses the package wall as a string, so a tab renamed on one
                // side lands here. Logged rather than opening Settings on whatever was last
                // selected: delivering the wrong tab is worse than visibly doing nothing.
                Logger.shared.warning("Command palette: \(raw) is not a settings tab — "
                    + "the row was built from a digest this app no longer recognises")
                return
            }
            openSettings(on: place)
        }
    }

    /// The provider whose tree the palette is describing: the focused pane's in Compare, the left
    /// rail's otherwise. The rule `lensProviderRootExpanded` follows, named once so the index's rows
    /// and its "current source" mark agree on the pane; writes go through `aimProvider(_:)`.
    var paletteProviderId: String { aimedAtRight ? rightProviderId : leftProviderId }

    /// Which pane the palette is aimed at, as a value that can be captured before a route changes
    /// the workspace out from under it.
    var aimedAtRight: Bool { lensTargetIsRight }

    /// Points the aimed pane at `id`: the write half of `paletteProviderId`, so every write uses
    /// one rule rather than restating the ternary.
    func aimProvider(_ id: String) {
        if aimedAtRight { rightProviderId = id } else { leftProviderId = id }
    }

    /// Points one named pane at a source, a folder, or both: ⌘K's own routes, aimed at a side
    /// rather than at the pane the palette is aimed at. Ask Claude sets Compare's two sides with
    /// it, and its Browse moves pass `isLeft` true, so a focused right pane in Compare can't take a
    /// move meant for the left.
    func movePane(isLeft: Bool, providerId: String?, absolutePath: String?) {
        let current = isLeft ? leftProviderId : rightProviderId
        if let providerId, providerId != current {
            if let absolutePath {
                switchSourceAndReveal(providerId: providerId, path: absolutePath, isLeft: isLeft)
            } else if isLeft {
                leftProviderId = providerId
            } else {
                rightProviderId = providerId
            }
        } else if let absolutePath {
            let root = (settings.rootPath(for: current) as NSString).expandingTildeInPath
            revealInSourcePane(absolutePath, root: root, isLeft: isLeft)
        }
    }

    /// The store's rule, wired to the real disk. Separate from `FolderJumpStore.reachable` so the
    /// rule stays testable without one, and `static` for the reason `isMountedFolder` is.
    /// `nonisolated`, so the sidebar refresh's detached walk can call it as well as ⌘K: it touches
    /// only the filesystem, and the main-actor isolation was only inferred from `View`.
    nonisolated static func reachableFolders(recents: [String], pinned: [String],
                                             under root: String) -> RememberedFolders {
        FolderJumpStore.reachable(recents: recents, pinned: pinned, underRoot: root,
                                  isDirectory: isMountedFolder)
    }

    /// Where the Go-to field is on screen, or `nil` if the toolbar is not showing one.
    ///
    /// Found as the one editable text field in the toolbar, not by item index: the identifier is a
    /// UUID SwiftUI mints per build, and an index would silently measure another item once one is
    /// added before it. Returns the whole item's view, not the text field: the list aligns to the
    /// control's capsule, magnifier and key included.
    static func goToFieldScreenFrame(in host: NSWindow) -> CGRect? {
        guard let view = goToFieldItemView(in: host) else { return nil }
        return host.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// The toolbar item's view that holds the Go-to field, or `nil` when the row is showing the
    /// closed pill.
    ///
    /// `view.window === host` is a precondition. `NSToolbar.items` includes items folded
    /// behind the overflow chevron, whose views are out of the window's hierarchy;
    /// `convert(_:to: nil)` on one answers the window's bottom-left corner at a plausible width, an
    /// anchor the caller can't tell from a real one. Refused here, so the caller's retry (and then
    /// its warning) does its job.
    ///
    /// **Don't loosen it to `view.window != nil`:** that hands back confident wrong anchors for an
    /// off-screen host. If AppKit hosts a full-screen window's toolbar in a separate window, this
    /// refuses it; running out of retries then hides the list rather than closing the palette.
    /// Check by pressing ⌘K in a full-screen window and reading the `[palette] placed under
    /// field=` line in `~/sync-cloud.log`. It is Debug: set Settings ▸ Advanced ▸ Log level to Debug
    /// first, since the shipped level is Info.
    static func goToFieldItemView(in host: NSWindow) -> NSView? {
        guard let toolbar = host.toolbar else { return nil }
        for item in toolbar.items {
            guard let view = item.view, view.window === host, containsEditableField(view)
            else { continue }
            return view
        }
        return nil
    }

    /// Who to hand the caret back to, resolved from whoever holds it at ⌘K time.
    ///
    /// Not `host.firstResponder` itself: a window has one field editor, shared by every
    /// `NSTextField` in it. While the user types in a pane's Find field the first responder is that
    /// `NSTextView`, and by the time ⌘K closes it has been re-bound to the Go-to field. The
    /// editor's `delegate`, the control being edited, is what survives the handover. Any other
    /// responder (a file pane's table) is returned unchanged.
    static func caretHolder(in host: NSWindow) -> NSResponder? {
        guard let editor = host.firstResponder as? NSTextView, editor.isFieldEditor else {
            return host.firstResponder
        }
        return editor.delegate as? NSResponder ?? editor
    }

    /// Puts the caret back where ⌘K found it, if ⌘K is still holding it.
    ///
    /// - Only if the caret is in the Go-to field. Every close path runs this, including a
    ///   click into a pane, which has already said where focus goes.
    /// - Only to a view still in this window. A torn-down view would take the caret somewhere
    ///   invisible.
    static func restoreCaret(to previous: NSResponder?, in host: NSWindow) {
        restoreCaret(to: previous, in: host, caretIsInField: caretIsInTheGoToField(host))
    }

    /// The rule itself, with the one fact that needs a laid-out toolbar passed in: an
    /// `NSToolbarItem`'s view is in a window only once AppKit has displayed the toolbar, which no
    /// test host does.
    static func restoreCaret(to previous: NSResponder?, in host: NSWindow, caretIsInField: Bool) {
        guard caretIsInField, let previous else { return }
        if let view = previous as? NSView, view.window !== host { return }
        host.makeFirstResponder(previous)
    }

    /// Whether the window's first responder is the editor of the toolbar's Go-to field.
    ///
    /// Asked of the field editor, not the field: an `NSTextField` being typed into is never itself
    /// the first responder; the window's shared `NSTextView` is, with the field as its delegate.
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

    /// What is at a typed path: Go to Folder's one disk question, wired to the real disk.
    ///
    /// No tilde expansion: `PalettePath.absolute` has already done it against the index's `home`.
    /// `PalettePath` never calls this outside a source or under one that is not mounted, which is
    /// what makes a `stat` acceptable on the keystroke path.
    static func pathKind(_ path: String) -> PathKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        else { return .missing }
        return isDirectory.boolValue ? .directory : .file
    }

    /// Whether a source's folder is there right now. Expanded first, and required to be a
    /// directory: the app's own validity rule (`SettingsManager`), asked the same way.
    nonisolated static func isMountedFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let expanded = (path as NSString).expandingTildeInPath
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Organize, at a rail item, optionally re-aimed.
    ///
    /// The scope is written to the defaults key `LensWorkspaceView` reads, where it lives; a local
    /// copy would be a second source of truth. The pane follows the scope, so the source rail shows
    /// the folder the lenses answer about. Internal: View ▸ Organize's sections route through this
    /// too, so the menu and ⌘K aim Organize the same way (see `shortcutOrganizeLens`).
    func aimOrganize(lens: OrganizeLens?, scope: String?) {
        // **The aim is read before the workspace moves, because moving it changes the aim.**
        // `lensProviderRootExpanded` follows the focused pane, and only Compare has two, so in
        // Organize it is always the left pane's root. The scope came from an index built against
        // the aimed pane; resolved afterwards against another provider, `OrganizeScope` would fail
        // and the scope would be silently cleared.
        //
        // Both halves of the aim, root and pane: `aimedAtRight` reads `layoutMode == .compare &&
        // activePane == .right`, so after leaving Compare it answers `false`, and a right-pane
        // scope would be revealed into the left pane against the right provider's root. Anything
        // that follows the workspace must be read on this side of the move.
        let root = lensProviderRootExpanded
        var revealIntoLeft = !aimedAtRight
        // Organize shows one provider, the left pane's. `organizeScope` re-resolves the stored
        // path against the live `lensProviderRootExpanded` (so a scope for a tree no longer
        // showing degrades to the global view), and outside Compare that is the left pane's root.
        // A scope aimed at the right pane would resolve to nil on the next read: no chip, no
        // filter, the folder silently dropped.
        //
        // So ask, rather than move the workspace under the user or drop the request. The rule is
        // `PaneLogic.organizeAimNeedsPaneSwap`, decided with `OrganizeScope` so the two agree;
        // nil-scoped so "a swap is needed" can't exist without the folder that needs it.
        let swapScope: String? = PaneLogic.organizeAimNeedsPaneSwap(
            scope: scope, aimedAtRight: aimedAtRight,
            leftRoot: providerRootExpanded(leftProviderId),
            rightRoot: providerRootExpanded(rightProviderId)) ? scope : nil
        if let swapScope {
            // Cancel means nothing happens at all: this returns above every write below, so
            // no half-applied route is left behind.
            guard confirmOrganizePaneSwap(folder: swapScope) else {
                Logger.shared.info("Command palette: pane swap declined — Organize route abandoned")
                return
            }
        }
        // Through `setOrganizeScope(_:providerRoot:)`, the one write of Organize's scope (the
        // provider root clears the scope rather than storing it), and before the workspace moves,
        // while `lensProviderRootExpanded` still names the aimed pane's root. Nil means "don't
        // re-aim", not "clear".
        //
        // The aimed pane's root is the right one here, unlike for the row menus that share this
        // method: the folder index and recents were built from it. Named, not defaulted, so that
        // stays a statement.
        if let scope { setOrganizeScope(scope, providerRoot: lensProviderRootExpanded) }
        // **The swap goes here: after the scope is written, before the workspace moves.**
        //
        // After the write, because `setOrganizeScope` resolves against the live
        // `lensProviderRootExpanded`, which after the swap names the other provider; written then,
        // the scope would be stored as `""`. The stored path is absolute and survives the swap, and
        // is re-resolved against the named provider, now the left pane's.
        //
        // Before the move, because `swapPanesAction` can refuse (provider bootstrap, file
        // operations in flight), and refusing after the move would land the user in Organize on
        // the wrong provider.
        if swapScope != nil {
            // Not hand-rolled: `swapPanesAction` is the atomic swap (the manager's paired focus,
            // selections and histories, the review dispatch, and the `ProviderPinPlan` that keeps
            // the per-pane onChange resets from firing). Exchanging the two ids would miss most.
            let aimedProviderId = paletteProviderId
            swapPanesAction()
            // Asked, not assumed: a refused swap leaves the named provider on the right, so the
            // reveal follows where the provider actually ended up.
            revealIntoLeft = leftProviderId == aimedProviderId
            if !revealIntoLeft {
                Logger.shared.warning("Command palette: the pane swap was refused — Organize will "
                    + "open on the other source")
            }
        }
        // Through the bar's own binding, so entering Organize does everything entering Organize
        // does: the review teardown and the rail presentation. The person-scope clear happens in
        // `onChange(of: selectedWorkspace)`.
        workspaceSelection.wrappedValue = .filing
        // Through `@AppStorage`, never `UserDefaults.standard.set` — see `paletteRailLens` for the
        // write this app has already watched go missing.
        paletteRailLens = lens
        guard let scope else { return }
        revealInSourcePane(scope, root: root, isLeft: revealIntoLeft)
    }

    /// One provider's root, tilde-expanded: what `lensProviderRootExpanded` computes for the lens
    /// target, asked about a named pane. The swap decision needs both roots.
    private func providerRootExpanded(_ id: String) -> String {
        (settings.rootPath(for: id) as NSString).expandingTildeInPath
    }

    /// Asks whether to swap the panes so Organize can open on the source the route named.
    ///
    /// `NativeAlerts.confirmChange`, never `confirmDestructive`: nothing is deleted and doing it
    /// again puts the panes back. The destructive style must keep meaning "files are going to the
    /// Trash".
    private func confirmOrganizePaneSwap(folder: String) -> Bool {
        let names = paneNames
        let prompt = Self.organizePaneSwapPrompt(folder: folder,
                                                 aimedProvider: names.right,
                                                 shownProvider: names.left)
        Logger.shared.info("Command palette: \(prompt.informativeText)")
        return NativeAlerts.confirmChange(messageText: prompt.messageText,
                                          informativeText: prompt.informativeText,
                                          // A verb naming what it does, not "OK".
                                          confirmTitle: "Swap Panes")
    }

    /// The dialog's words, as a pure function of the three things it is about, so a test can hold
    /// them to naming the folder and both sources. `static`, like `isMountedFolder`: nothing on a
    /// `ContentView` instance is reachable from a test.
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
    /// Extracted so a test can reach the two refusals: the caller is a method on a SwiftUI `View`
    /// with `@State`, which nothing can construct, and each refusal is an accepted route
    /// delivering nothing.
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

    /// Points the source pane at an absolute folder inside the current provider, or says why it
    /// could not. Neither refusal should be reachable (folder rows come from the survey under this
    /// root, and Go to Folder refuses a path outside `PaletteIndex.providerRoot`), but the index is
    /// a snapshot and the root read here is live, so a provider changed under an open palette
    /// lands here; the log line records it.
    ///
    /// It points the pane the index was built from, not always the left one:
    /// `lensProviderRootExpanded` follows the focused pane in Compare. Revealing into the other
    /// pane would hand a path from one provider's tree to the other's.
    ///
    /// - Parameters:
    ///   - root: the provider root the path is relative to, and `isLeft` the pane that owns it.
    ///     Passed in rather than re-read, because a caller may already have changed the workspace,
    ///     and both values follow it. See `aimOrganize`.
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

    // MARK: Go to Folder, across sources — RD7

    /// Where a cross-source Go to Folder route lands, or why it cannot. Extracted for the reason
    /// ``RevealOutcome`` is: three of these four answers are an accepted route delivering nothing.
    /// The ordering of the one that delivers is the caller's; this is only the decision.
    enum SourceSwitchOutcome: Equatable {
        /// Point the aimed pane at the named source and focus it here, root-relative.
        case switchAndFocus(relativePath: String)
        /// The route named a source this app no longer has, or one with no path configured.
        case noSuchSource
        /// The source is there and the typed path is not inside it.
        case outsideNamedSource(root: String)
        /// The source is there and contains the path, and there is nothing at it.
        case nothingAtThatPath
    }

    /// - Parameters:
    ///   - path: the absolute path the user typed, already standardized by `PalettePath`.
    ///   - namedRoot: the root of the source the route named, tilde-expanded, never the pane's
    ///     current one. Optional because settings can have dropped the id since the palette
    ///     opened. An empty root answers as a missing one: an empty base prefixes every absolute
    ///     path, so a source with no path must claim nothing rather than everything.
    ///   - kind: what is at `path`; `@autoclosure` so the disk is not asked at all when the source
    ///     is gone or does not contain the path. The same stall guard `PalettePath` keeps on the
    ///     keystroke path: the source may have gone to sleep since the palette opened.
    static func sourceSwitchOutcome(path: String, namedRoot: String?,
                                    kind: @autoclosure () -> PathKind) -> SourceSwitchOutcome {
        guard let namedRoot, !namedRoot.isEmpty else { return .noSuchSource }
        guard let relative = PathBoundary.relativize(path, under: namedRoot) else {
            return .outsideNamedSource(root: namedRoot)
        }
        switch kind() {
        case .missing:
            // Refused rather than delivered half: switching source and landing somewhere else
            // would silently drop the folder. The router could not probe this path (it is outside
            // the aimed source), so ↩ is the first moment anything can.
            return .nothingAtThatPath
        case .directory:
            return .switchAndFocus(relativePath: relative)
        case .file:
            // A pasted path is usually a file's, so the enclosing folder is the destination, as in
            // `PaletteRouter.pathRow` and ⇧⌘G. Taken off the relative path, so a file at the source
            // root gives `""`, which is "the pane's own top" to `focusOn`.
            return .switchAndFocus(relativePath: (relative as NSString).deletingLastPathComponent)
        }
    }

    /// Switches the aimed pane to another source and lands it on the typed folder. The ordering
    /// is the whole of it.
    ///
    /// A provider change runs its own navigation reset: `onChange(of: leftProviderId)` fires on
    /// the next view update and calls `retargetPane()`, which re-homes the pane at the new source's
    /// landing folder, so `aimProvider` then `focusOn` would silently drop the typed folder. The
    /// write goes through `adoptProviderForTab` instead: it arms `pendingTabProviderChanges`, the
    /// handler consumes it instead of resetting, and the rest the handler owes (the ignored-items
    /// re-key on the new pair, the lens clear, the review dispatch) still happens.
    /// `refreshForTabSwitch` then reloads the moved pane only.
    ///
    /// Three statements, each position load-bearing:
    ///
    /// 1. `focusOn` first, as in `tabAction`. Both writes land in the same synchronous turn, so
    ///    when SwiftUI runs either `onChange` the pane already names the folder and the source,
    ///    and `onChange(of: leftRelativePath)` records the visit against the new root.
    /// 2. the armed provider write second, because its handler must find the navigation done.
    /// 3. the reload last, because it resolves both providers out of `enabledProviders` by the
    ///    ids as they now are.
    ///
    /// Only the aimed pane moves; `PaneLinkPreference.isLinked` does not apply. A linked follow
    /// would hand a path relative to the named source's root to a sibling still showing another
    /// source (what `FileActionHandler.focusFolder`'s `suppressLinkedNavigation` exists for). The
    /// workspace is left alone, as `.folder` leaves it: this is a navigation, not a change of place.
    private func switchSourceAndReveal(providerId: String, path: String, isLeft paneIsLeft: Bool? = nil) {
        // Which pane, read once and used for every write below: `aimedAtRight` is computed over
        // the layout, which the writes can change. A caller that names its pane (Ask Claude,
        // setting one side of Compare) is taken at its word.
        let isLeft = paneIsLeft ?? !aimedAtRight
        // The pane's own list, not the discovered one (`paneCanShowSource`'s reading): a source
        // switched off in Settings is one no refresh will walk.
        let named = settings.enabledProviders.first { $0.id == providerId }
        // Expanded, as the index expands it: Settings stores a hand-typed `~/…` verbatim, and
        // `PalettePath` has already expanded the path in hand.
        let namedRoot = named.map { ($0.rootPath as NSString).expandingTildeInPath }
        switch Self.sourceSwitchOutcome(path: path, namedRoot: namedRoot,
                                        kind: Self.pathKind(path)) {
        case .switchAndFocus(let relative):
            syncManager.focusOn(relativePath: relative, isLeft: isLeft)
            adoptProviderForTab(providerId, isLeft: isLeft,
                                log: "Go to Folder moved the \(PaneSideChoice.name(isLeft)) pane "
                                    + "to \(providerId) and landed it on \(path)")
            refreshForTabSwitch(movedPane: isLeft)
        case .noSuchSource:
            // Reachable like the `.person` route's missing id: the index is a snapshot and the
            // sources are live. Logged, because ↩ that visibly does nothing must leave a trace.
            Logger.shared.warning("Command palette: \(providerId) is no longer an enabled source — "
                + "the row offering \(path) was listed from an index taken when the palette opened")
        case .outsideNamedSource(let root):
            Logger.shared.warning("Command palette: \(path) is not inside \(root) — "
                + "the source it was offered against has been re-pointed since the palette opened")
        case .nothingAtThatPath:
            // The one refusal that could not be made before ↩: the router must not `stat` a path
            // outside the aimed source.
            Logger.shared.warning("Command palette: nothing at \(path) — the pane stays where it "
                + "is rather than switching source and landing somewhere else")
        }
    }

    private func runPaletteAction(_ action: PaletteAction) {
        switch action {
        case .rescan: shortcutRescan?()
        case .newFolder: shortcutNewFolder?()
        // The aimed pane, like every other provider write here (see `paletteProviderId`), so the
        // provider-switch teardown fires on the side the user is working in.
        case .chooseFolder:
            chooseFolderSource { id in aimProvider(id) }
        case .findInPane: beginPaneSearch()
        case .restructureThisFolder: restructureCurrentFolder()
        case .settings: showSettings = true
        case .shortcuts: openWindow(id: "keyboard-shortcuts")
        // The log is Activity's Log tab.
        case .activityLog:
            ActivityCenter.shared.tab = .log
            openWindow(id: ActivityCenter.windowID)
        }
    }
}
