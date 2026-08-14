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

    /// This pane's chips. Resolved per render off the manager's list plus the settings' providers —
    /// the strip itself never sees either.
    func paneTabItems(isLeft: Bool) -> [PaneTabStrip.Item] {
        let list = syncManager.paneTabs(isLeft: isLeft)
        let liveProviderId = isLeft ? leftProviderId : rightProviderId
        return list.tabs.enumerated().map { index, tab in
            let isActive = index == list.selectedIndex
            // **The active chip reads the LIVE pane, not its own stored copy.** The active entry is
            // a snapshot from when the tab was last parked (see `PaneTab`), so a chip drawn from it
            // would keep naming the folder you arrived in while the pane walked on.
            let providerId = isActive ? liveProviderId : tab.providerId
            let provider = settings.availableProviders.first { $0.id == providerId }
            let path = isActive ? syncManager.combinedRelativePath(isLeft: isLeft)
                                : tab.combinedRelativePath
            let name = path.isEmpty ? (provider?.displayName ?? providerId)
                                    : (path as NSString).lastPathComponent
            let root = settings.path(for: providerId)
            return PaneTabStrip.Item(
                id: tab.id,
                title: name,
                markImageName: provider?.imageName ?? "folder.fill",
                isActive: isActive,
                fullPath: path.isEmpty ? root : root + "/" + path)
        }
    }

    /// Whether this pane draws a strip at all: more than one tab, or the Tab Bar switch is on.
    ///
    /// Ticked-and-disabled past one tab is enforced by `shortcutTabBar`, so this can be the plain
    /// disjunction it looks like.
    func paneShowsTabStrip(isLeft: Bool) -> Bool {
        syncManager.paneTabs(isLeft: isLeft).showsStrip || tabBarVisible
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

        let currentProviderId = isLeft ? leftProviderId : rightProviderId
        if arrived.providerId != currentProviderId,
           settings.availableProviders.contains(where: { $0.id == arrived.providerId }) {
            // One suppressed change, then this method drives the single reload — exactly the shape
            // `swapPanesAction` uses, and on its OWN counter: two features sharing one would have a
            // swap eat a tab switch's suppression and reset the navigation it just restored.
            pendingTabProviderChanges += 1
            if isLeft { leftProviderId = arrived.providerId } else { rightProviderId = arrived.providerId }
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
        Logger.shared.info("User opened a new tab at “\(here.isEmpty ? "the source root" : here)”")
        tabAction(isLeft: isLeft) {
            syncManager.openTab(PaneTab(providerId: providerId, relativePath: here),
                                isLeft: isLeft, currentProviderId: providerId)
        }
    }

    /// Right-click a folder ▸ Open in New Tab, and ⌘-double-click on a folder row — the discovery
    /// route, and the only entry point that opens the new tab somewhere *different*.
    func openInNewTab(absolutePath: String, isLeft: Bool) {
        let providerId = isLeft ? leftProviderId : rightProviderId
        let root = settings.path(for: providerId)
        guard let relative = PathBoundary.relativize(absolutePath, under: root) else {
            // A folder outside this pane's root has no tab to be opened as: the strip is a list of
            // locations under one source, and inventing one here would name a path the pane could
            // not navigate to.
            Logger.shared.warning("Ignored Open in New Tab for a path outside the pane's source: \(absolutePath)")
            return
        }
        Logger.shared.info("User opened “\(relative)” in a new tab")
        tabAction(isLeft: isLeft) {
            syncManager.openTab(PaneTab(providerId: providerId, relativePath: relative),
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
            relativePath: syncManager.combinedRelativePath(isLeft: true))
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
                let root = settings.path(for: providerId)
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: (root as NSString).appendingPathComponent(relativePath),
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
            pendingTabProviderChanges += 1
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
