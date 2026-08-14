import SwiftUI
import AppKit
import Design
import Events
import FileExplorer
import Settings
import Sync

/// Browse tabs: the host's half.
///
/// `FileSyncManager+PaneTabs` owns the model and the capture/apply rule. Three things it cannot
/// own live here, and each is the reason this file exists rather than that one growing:
///
/// - **The provider id is `@AppStorage` on this view.** A tab switch that changes source has to
///   write it *and* suppress the `onChange` that would otherwise call `resetNavigation()` over the
///   navigation the switch has just restored — the same suppression `swapPanesAction` uses, on its
///   own counter so the two can never consume each other's.
/// - **The search field is this view's `@State`.** The manager reads it back through
///   `paneSearchSnapshot` when it parks a tab; applying it is done here, off the tab each verb
///   returns.
/// - **Persistence and the launch seed** need the provider list, the roots on disk, and
///   `UserDefaults` — none of which `Sync` reaches into.
///
/// Everything in here routes through `tabAction`, so there is exactly one place that knows the
/// order these have to happen in.
extension ContentView {

    // MARK: - What the strip renders

    /// This pane's chips, through `PaneTabChips` — the rule is over there so it can be tested;
    /// this half is only the lookup of who each tab's provider is.
    func paneTabItems(isLeft: Bool) -> [PaneTabStrip.Item] {
        PaneTabChips.items(
            syncManager.paneTabs(isLeft: isLeft),
            liveProviderId: isLeft ? leftProviderId : rightProviderId,
            livePath: syncManager.combinedRelativePath(isLeft: isLeft),
            source: { id in
                guard let provider = settings.availableProviders.first(where: { $0.id == id }) else { return nil }
                return PaneTabChips.Source(displayName: provider.displayName,
                                           markImageName: provider.imageName,
                                           root: provider.path)
            })
    }

    /// Whether this pane draws a strip at all: more than one tab, or the Tab Bar switch is on.
    ///
    /// Ticked-and-disabled past one tab is enforced by `shortcutTabBar`, so this can be the plain
    /// disjunction it looks like.
    func paneShowsTabStrip(isLeft: Bool) -> Bool {
        syncManager.paneTabs(isLeft: isLeft).showsStrip || tabBarVisible
    }

    /// Track the tab strip gives up to the seam controls, which are drawn OVER this row.
    func seamInset(isLeft: Bool, leading: Bool) -> CGFloat {
        PaneTabSeam.inset(isCompare: layoutMode == .compare, isLeft: isLeft, leading: leading)
    }

    // MARK: - The one door

    /// Runs a tab verb and settles everything that follows from it: the provider id, the search
    /// field, the reload, and the saved strip.
    ///
    /// `verb` returns the tab the pane arrived at, or `nil` when the pane did not move (closing a
    /// parked tab, selecting the tab already live). `nil` still saves — the strip changed even when
    /// the pane did not — and still costs no reload, which is the point of the distinction.
    private func tabAction(isLeft: Bool, _ verb: () -> PaneTab?) {
        // The bootstrap window is interactive, and a provider `onChange` bails on its own guard
        // there without decrementing the suppression counter — which would strand it and silently
        // swallow the user's next real source switch. `swapPanesAction` refuses for the same reason.
        guard !isBootstrappingProviders else { return }

        guard let arrived = verb() else {
            saveBrowseTabs(isLeft: isLeft)
            return
        }

        // The search field travels with the tab. Cleared to the incoming tab's own state, which for
        // a new tab is an empty, closed field.
        paneSearchState(isLeft: isLeft).wrappedValue = PaneSearchFieldState(
            query: arrived.searchQuery, isExpanded: arrived.searchIsExpanded)

        switch PaneTabProviderSwitch.decide(
            arrived: arrived.providerId,
            current: isLeft ? leftProviderId : rightProviderId,
            isAvailable: { id in settings.availableProviders.contains { $0.id == id } }) {
        case .keep:
            break
        case .adopt(let id):
            // One suppressed change, then this method drives the single reload — exactly the shape
            // `swapPanesAction` uses, and on its OWN counter: two features sharing one would have a
            // swap eat a tab switch's suppression and reset the navigation it just restored.
            pendingTabProviderChanges += 1
            if isLeft { leftProviderId = id } else { rightProviderId = id }
        case .unavailable(let id):
            // The tab names a source that has since been removed. The pane stays on the source it
            // is showing rather than silently rendering this tab's folder under someone else's
            // root — and it says so, because a tab that quietly means something different from
            // what its chip claims is worse than one that fails loudly.
            Logger.shared.warning("Tab points at source “\(id)”, which is no longer available — the pane stayed on its current source")
        }
        saveBrowseTabs(isLeft: isLeft)
        refreshForTabSwitch()
    }

    /// The reload a tab switch asks for.
    ///
    /// `applyTab` has already rung `refreshSubject`, which this view turns into a refresh — but a
    /// provider change writes `@AppStorage` a beat later, so the refresh that ran may have read the
    /// old source. Asking again is free when nothing moved: `refreshTreesAndScan` dedupes an
    /// identical in-flight target rather than restarting it.
    private func refreshForTabSwitch() {
        guard let left = settings.enabledProviders.first(where: { $0.id == leftProviderId }),
              let right = settings.enabledProviders.first(where: { $0.id == rightProviderId }) else { return }
        Task { await syncManager.refreshTreesAndScan(left: left, right: right) }
    }

    // MARK: - The verbs, as the UI names them

    /// ⌘T, the ＋, and a double-click on the strip's empty stretch.
    ///
    /// **Opens the CURRENT folder**, and the control says so ("New tab here"). The result is two
    /// tabs with the same name and the strip's arrival is the only feedback — but opening at the
    /// provider root instead would throw away the folder you pressed ⌘T from, which is worse for
    /// being tidier.
    func openNewTabHere(isLeft: Bool) {
        let providerId = isLeft ? leftProviderId : rightProviderId
        let here = syncManager.combinedRelativePath(isLeft: isLeft)
        tabAction(isLeft: isLeft) {
            // Logged from inside, so a refused action (the bootstrap guard) leaves no line claiming
            // it happened — he audits this log.
            Logger.shared.info("User opened a new tab at “\(here.isEmpty ? "the source root" : here)”")
            return syncManager.openTab(PaneTab(providerId: providerId, relativePath: here),
                                       isLeft: isLeft, currentProviderId: providerId)
        }
    }

    /// Right-click a folder ▸ Open in New Tab, and ⌘-double-click on a folder row — the discovery
    /// route, and the only entry point that opens the new tab somewhere *different*.
    func openInNewTab(absolutePath: String, isLeft: Bool) {
        let providerId = isLeft ? leftProviderId : rightProviderId
        // **Expanded.** A source's stored path may be written with a tilde, while a row's id is
        // always absolute — `relativize` compares them as strings, so an unexpanded root matches
        // nothing and this whole entry point becomes a silent no-op. `PaneLogic.fullPath` and
        // `PaneLogic.paneFocusRestores` each expand for the same reason.
        let root = (settings.path(for: providerId) as NSString).expandingTildeInPath
        guard let relative = PathBoundary.relativize(absolutePath, under: root) else {
            // A folder outside this pane's root has no tab to be opened as: the strip is a list of
            // locations under one source, and inventing one here would name a path the pane could
            // not navigate to.
            Logger.shared.warning("Ignored Open in New Tab for a path outside the pane's source: \(absolutePath)")
            return
        }
        tabAction(isLeft: isLeft) {
            Logger.shared.info("User opened “\(relative)” in a new tab")
            return syncManager.openTab(PaneTab(providerId: providerId, relativePath: relative),
                                       isLeft: isLeft, currentProviderId: providerId)
        }
    }

    func selectTab(id: UUID, isLeft: Bool) {
        tabAction(isLeft: isLeft) {
            syncManager.switchTab(to: id, isLeft: isLeft,
                                  currentProviderId: isLeft ? leftProviderId : rightProviderId)
        }
    }

    func cycleTab(forward: Bool, isLeft: Bool) {
        tabAction(isLeft: isLeft) {
            syncManager.cycleTab(forward: forward, isLeft: isLeft,
                                 currentProviderId: isLeft ? leftProviderId : rightProviderId)
        }
    }

    /// Closing the last tab closes the WINDOW, as Finder does — which is also what keeps ⌘W
    /// meaning "get rid of this" instead of acquiring an exception nobody would remember.
    func closeTab(id: UUID, isLeft: Bool) {
        guard syncManager.paneTabs(isLeft: isLeft).count > 1 else {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        tabAction(isLeft: isLeft) {
            syncManager.closeTab(id: id, isLeft: isLeft,
                                 currentProviderId: isLeft ? leftProviderId : rightProviderId)
        }
    }

    func closeOtherTabs(keeping id: UUID, isLeft: Bool) {
        tabAction(isLeft: isLeft) {
            syncManager.closeOtherTabs(keeping: id, isLeft: isLeft,
                                       currentProviderId: isLeft ? leftProviderId : rightProviderId)
        }
    }

    func duplicateTab(id: UUID, isLeft: Bool) {
        tabAction(isLeft: isLeft) {
            syncManager.duplicateTab(id: id, isLeft: isLeft,
                                     currentProviderId: isLeft ? leftProviderId : rightProviderId)
        }
    }

    /// Drag-to-reorder. **Not through `tabAction`**: the pane does not move, so there is no
    /// provider to write, no search field to swap and no reload to drive — only the strip and what
    /// is saved of it change.
    /// Pin / unpin, from a tab's context menu. Like `moveTab`, the pane does not move — only the
    /// strip's order and that chip's own state — so this does not go through `tabAction`.
    func setTabPinned(_ pinned: Bool, id: UUID, isLeft: Bool) {
        guard !isBootstrappingProviders else { return }
        Logger.shared.info("User \(pinned ? "pinned" : "unpinned") a browse tab")
        syncManager.setTabPinned(pinned, id: id, isLeft: isLeft)
        saveBrowseTabs(isLeft: isLeft)
    }

    func moveTab(id: UUID, to index: Int, isLeft: Bool) {
        guard !isBootstrappingProviders else { return }
        syncManager.moveTab(id: id, to: index, isLeft: isLeft)
        saveBrowseTabs(isLeft: isLeft)
    }

    func reopenClosedTab(isLeft: Bool) {
        tabAction(isLeft: isLeft) {
            syncManager.reopenClosedTab(isLeft: isLeft,
                                        currentProviderId: isLeft ? leftProviderId : rightProviderId)
        }
    }

    /// Copy Path, from a tab's context menu — the absolute path, which is what is useful in a
    /// Terminal or a Finder ⇧⌘G, rather than the relative one the chip is named for.
    func copyTabPath(id: UUID, isLeft: Bool) {
        guard let item = paneTabItems(isLeft: isLeft).first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.fullPath, forType: .string)
        Logger.shared.info("User copied a tab's path: \(item.fullPath)")
    }

    // MARK: - Persistence and the launch seed

    /// Saves the left pane's strip. **The left one only** — see `PaneTabsStore` for why Compare's
    /// right-hand location is not something a Browse feature should start restoring.
    func saveBrowseTabs(isLeft: Bool) {
        guard isLeft else { return }
        let list = syncManager.leftPaneTabs
        // The ACTIVE entry is a stale snapshot by construction, so it is written from the live pane
        // rather than from the list — otherwise quitting saves the folder the tab was parked at
        // rather than the one on screen.
        var tabs = list.tabs
        tabs[list.selectedIndex] = PaneTab(
            id: list.active.id,
            providerId: leftProviderId,
            relativePath: syncManager.combinedRelativePath(isLeft: true),
            // Carried over: this entry is rebuilt from the LIVE pane, which knows nothing about
            // pinning, so reading it from anywhere but the list would unpin the active tab on the
            // next thing that saves.
            isPinned: list.active.isPinned)
        PaneTabsStore.save(tabs: tabs, selected: list.selectedIndex)
    }

    /// Restores the strip at launch, once the providers are known.
    ///
    /// Called from the same place the panes are first pointed at their sources, and it deliberately
    /// does nothing at all when there is one stored tab at the root — that is the state a fresh
    /// install and an upgrading one both start in, and seeding it would replace an identical list
    /// with a new one whose ids nothing else knows about.
    func restoreBrowseTabs() {
        // **Behind the same setting as the folder restore beside it.** Someone who has turned
        // "reopen the last folder" off has said they want the app to start at the root; handing
        // them five tabs' worth of where they were is that answer at five times the volume.
        guard GeneralSettings.shouldRestoreLastFocus() else { return }
        guard let stored = PaneTabsStore.load() else { return }
        let restored = PaneTabsStore.restore(
            entries: stored.entries,
            selected: stored.selected,
            isKnownProvider: { id in settings.availableProviders.contains { $0.id == id } },
            folderExists: { providerId, relativePath in
                guard !relativePath.isEmpty else { return true }
                // Expanded, for the reason `openInNewTab` gives: a tilde root never exists on disk,
                // so every restored tab would fall back to its provider's root and the strip would
                // come back pointing at nothing in particular.
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: PaneLogic.fullPath(root: settings.path(for: providerId),
                                               relativePath: relativePath),
                    isDirectory: &isDirectory)
                return exists && isDirectory.boolValue
            })
        guard let restored, restored.count > 1 || !restored.active.relativePath.isEmpty else { return }
        Logger.shared.info("Restored \(restored.count) browse tab\(restored.count == 1 ? "" : "s")")
        syncManager.setPaneTabs(restored, isLeft: true)
        // The restored ACTIVE tab is the pane's position, so it has to be applied like any other
        // switch — including its provider, which may not be the one the pane was pointed at.
        let active = restored.active
        if active.providerId != leftProviderId,
           settings.availableProviders.contains(where: { $0.id == active.providerId }) {
            // **No suppression counter here, deliberately.** This runs inside the provider
            // bootstrap, where the id's `onChange` bails on `isBootstrappingProviders` *without*
            // decrementing — so arming the counter would strand it at one and silently swallow the
            // user's next real source switch, leaving that switch's navigation un-reset. The
            // bootstrap guard IS the suppression here; `applyProviderSelection` two lines earlier
            // writes both ids the same way. `tabAction` arms the counter because it runs later,
            // when the handler is live.
            leftProviderId = active.providerId
        }
        syncManager.applyTab(active, isLeft: true)
    }
}


/// Keeps the saved strip in step with the live pane.
///
/// **The active tab IS the live pane** (see `PaneTab`), so a strip written only when a tab opens or
/// closes would restore every tab at the folder it was created in. Both halves of "where a tab is"
/// are watched: the comparison scope, and — the half that moves in Columns — the column stack.
///
/// A `ViewModifier` rather than two `onChange`s in `ContentView.body` because that chain is already
/// long enough that adding two more tipped it past the type-checker's budget. One modifier, and its
/// body is type-checked on its own.
struct BrowseTabPersistence: ViewModifier {
    @ObservedObject var syncManager: FileSyncManager
    let save: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: syncManager.leftRelativePath) { _, _ in save() }
            .onChange(of: syncManager.leftBrowsePath) { _, _ in save() }
    }
}


/// How much of the tab strip the seam controls take.
///
/// **⇄ and 🔗 are drawn on top of this row.** `SeamPaneControls` is an overlay on the panes region
/// pinned 8pt from its top and straddling the pane boundary — which is exactly where a strip's
/// trailing ＋ (left pane) and leading chip (right pane) sit. Measured on the shipping app: the
/// left pane's ＋ landed about five points from ⇄, near enough to read as one control.
///
/// A named rule rather than a ternary at the call site because it is wrong in two directions and
/// only one of them is visible: too little and the controls overlap, too much and Browse — which
/// has no seam at all — loses track it should keep. `PaneTabWiringTests` pins both.
enum PaneTabSeam {
    /// The seam capsule is two 26pt halves offset 13pt back from the boundary, so it reaches 13pt
    /// into each pane; 26 gives the strip's own gap on top of that.
    static let reserve: CGFloat = 26

    /// The inset for one edge of one pane's strip. Zero everywhere but the two edges that touch a
    /// seam, which exists only in Compare.
    static func inset(isCompare: Bool, isLeft: Bool, leading: Bool) -> CGFloat {
        guard isCompare else { return 0 }
        // The left pane gives up its TRAILING edge, the right pane its LEADING one.
        return leading == isLeft ? 0 : reserve
    }
}


/// What a pane's tab strip renders, as a rule.
///
/// Lifted out of `ContentView` so it can be tested at all, and because it holds the one thing about
/// the strip that is easy to get subtly wrong: **the active chip reads the LIVE pane, and every
/// other chip reads its own parked snapshot.** The active entry in the list is a snapshot from when
/// that tab was last parked (see `PaneTab`), so a chip drawn from it keeps naming the folder you
/// arrived in while the pane walks on — a strip that is correct on arrival and wrong a click later,
/// which is exactly the kind of thing a screenshot taken at the wrong moment makes look fine.
enum PaneTabChips {
    /// What the host knows about one source. `nil` for a source that is no longer available.
    struct Source: Equatable {
        let displayName: String
        let markImageName: String
        /// As stored — possibly with a tilde. Expanded here, never at the call site.
        let root: String
    }

    static func items(_ list: PaneTabList,
                      liveProviderId: String,
                      livePath: String,
                      source: (String) -> Source?) -> [PaneTabStrip.Item] {
        list.tabs.enumerated().map { index, tab in
            let isActive = index == list.selectedIndex
            let providerId = isActive ? liveProviderId : tab.providerId
            let path = isActive ? livePath : tab.combinedRelativePath
            let resolved = source(providerId)
            // A tab at a source root has no folder to name, so it wears the source's name — and
            // the raw id if even that is gone, which at least says which source it meant.
            let name = path.isEmpty ? (resolved?.displayName ?? providerId)
                                    : (path as NSString).lastPathComponent
            return PaneTabStrip.Item(
                id: tab.id,
                title: name,
                // A source with no bundled mark wears a folder, which is what `ProviderLogo` draws
                // for a folder source anyway.
                markImageName: resolved?.markImageName ?? "folder.fill",
                isActive: isActive,
                fullPath: PaneLogic.fullPath(root: resolved?.root ?? "", relativePath: path),
                isPinned: tab.isPinned)
        }
    }
}

/// Whether a tab switch also changes the pane's source.
///
/// A rule rather than an `if` at the call site because the middle case is invisible: a tab whose
/// source has been removed since it was opened must NOT have its folder rendered under whatever
/// source the pane happens to be showing, and there is nothing on screen to tell you that happened.
enum PaneTabProviderSwitch: Equatable {
    /// The pane is already on this tab's source.
    case keep
    /// Write the id — and suppress the reset its `onChange` would otherwise run.
    case adopt(String)
    /// The tab names a source that is gone. Stay put, and say so.
    case unavailable(String)

    static func decide(arrived: String, current: String, isAvailable: (String) -> Bool) -> PaneTabProviderSwitch {
        guard arrived != current else { return .keep }
        return isAvailable(arrived) ? .adopt(arrived) : .unavailable(arrived)
    }
}
