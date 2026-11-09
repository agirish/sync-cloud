import SwiftUI
import Dashboard
import Events
import FileExplorer
import Settings
import Sync
import Design

/// The folder sidebar, host half. The column itself is `Dashboard.FolderSidebarView`; this file
/// holds where its rows come from and what a click does.
extension ContentView {

    // MARK: - Which pane a row acts on

    /// The pane a sidebar row acts on, written as a question rather than as `true`. In a
    /// single-source workspace it is the left pane, the only one there is; in Compare a row acts on
    /// the pane the user is working in.
    var folderSidebarTargetIsLeft: Bool {
        // The pane the user is working in: the same answer the action bar and the lens scans get,
        // and the one the accent border draws. Not `PaneLogic.activePane`, which follows the
        // selection and answers the left pane whenever nothing is selected. `focusedPane` survives
        // a deselect (`PaneLogic.focusedSideAfterSelectionWrite`) and is set by working in a pane.
        guard selectedWorkspace == .compare else { return true }
        return focusedPane == .left
    }

    var folderSidebarProviderId: String {
        folderSidebarTargetIsLeft ? leftProviderId : rightProviderId
    }

    /// Whether the column is on screen: the one rule, so `browseLayout`'s `if` and the refresh's
    /// guard cannot disagree. In Edit, Expand can override the preference: while
    /// `EditorExpand.hidesSidebar` holds it off the column is down, and the preference is never
    /// written for it, since hiding it in Edit must not hide it in Compare.
    var folderSidebarIsShowing: Bool {
        // While the pin holds Organize's folder pane folded the sidebar is away with it, and comes
        // back alone only when asked (`askClaudePinSidebarShown`). Never the stored preference's
        // doing: hiding it here must not hide it in Compare.
        if folderSidebarHeldByPinFold {
            return FolderSidebarModel.isShowing(
                workspaceSupportsSidebar: selectedWorkspace.supportsFolderSidebar,
                panesCollapsed: panesHiddenForCurrentTab, outlivesCollapse: true,
                preference: askClaudePinSidebarShown)
        }
        return FolderSidebarModel.isShowing(
            workspaceSupportsSidebar: selectedWorkspace.supportsFolderSidebar,
            panesCollapsed: panesHiddenForCurrentTab,
            outlivesCollapse: selectedWorkspace.folderSidebarOutlivesPaneCollapse,
            preference: folderSidebarPreference(for: selectedWorkspace) && !folderSidebarHeldByExpand)
    }

    /// Whether the docked Ask Claude column is holding Organize's folder pane folded, and the
    /// sidebar with it: Organize only, since Edit's sidebar already outlives a collapse.
    var folderSidebarHeldByPinFold: Bool {
        selectedWorkspace == .filing && askClaudePinFoldActive
    }

    /// Whether the sidebar outlives the pane's collapse here: Edit's always, and Organize's while
    /// the pin holds the fold, so the sidebar button can bring it back on its own.
    var folderSidebarOutlivesCollapse: Bool {
        selectedWorkspace.folderSidebarOutlivesPaneCollapse || folderSidebarHeldByPinFold
    }

    /// Which switch a workspace's sidebar reads: Edit its own, off until shown; every other
    /// workspace the one they share. ⌃⌘S writes the same one it reads (`setFolderSidebarVisible`),
    /// so showing it in Edit leaves the others as they were.
    func folderSidebarPreference(for workspace: Workspace) -> Bool {
        workspace == .editor ? editorSidebarVisible : browseSidebarVisible
    }

    /// Whether Expand is holding the sidebar off on the workspace on screen — Edit only.
    var folderSidebarHeldByExpand: Bool {
        selectedWorkspace == .editor && editorExpand.hidesSidebar
    }

    /// Whether Edit's sidebar is drawn, whichever workspace is on screen: what Expand records as
    /// put away when it starts from a launch that may land before the window is on Edit. In Edit
    /// the column survives a collapsed pane, so only the preference and Expand decide it.
    var editorSidebarIsShowing: Bool {
        FolderSidebarModel.isShowing(
            workspaceSupportsSidebar: Workspace.editor.supportsFolderSidebar,
            panesCollapsed: editorPaneIsFolded,
            outlivesCollapse: Workspace.editor.folderSidebarOutlivesPaneCollapse,
            preference: editorSidebarVisible && !editorExpand.hidesSidebar)
    }

    /// Whether the sidebar can be switched on here at all. The toolbar button and View ▸ Sidebar
    /// both ask this, so neither can offer a column the other refuses.
    var folderSidebarIsAvailable: Bool {
        FolderSidebarModel.appliesTo(
            workspaceSupportsSidebar: selectedWorkspace.supportsFolderSidebar,
            panesCollapsed: panesHiddenForCurrentTab,
            outlivesCollapse: folderSidebarOutlivesCollapse)
    }

    /// ⌃⌘S's act, from the toolbar and View ▸ Sidebar alike. Showing it while Expand holds it off
    /// lifts the hold (`EditorExpand.sidebarShownByHand`); otherwise the press would flip a
    /// preference that is already on and nothing would appear.
    func setFolderSidebarVisible(_ visible: Bool) {
        // While the pin holds the folder pane folded, the answer is this session's, not a
        // preference: showing it here must not show it in Browse and Compare as well.
        if folderSidebarHeldByPinFold {
            askClaudePinSidebarShown = visible
            return
        }
        if visible && folderSidebarHeldByExpand {
            var expand = editorExpand
            expand.sidebarShownByHand()
            editorExpand = expand
        }
        if selectedWorkspace == .editor { editorSidebarVisible = visible } else { browseSidebarVisible = visible }
    }

    /// The provider root the target pane is on, expanded to match `FolderJumpStore.key(forRoot:)`,
    /// which expands before keying. A folder source is stored with its `~` intact, and the two
    /// spellings would never match.
    var folderSidebarRoot: String {
        (settings.rootPath(for: folderSidebarProviderId) as NSString).expandingTildeInPath
    }

    /// Enabled sources, not merely available ones, as ⌘K and the pane header's dropdown list them.
    /// A row for a source switched off in Settings would switch the pane to a source the header
    /// will not list.
    var folderSidebarProviders: [CloudProvider] { settings.enabledProviders }

    // MARK: - Rows

    /// Re-reads every source's lists and checks them against the disk. Called from the places the
    /// answer can change, not from `body`: a `stat` does not belong in a render.
    ///
    /// Only while the column is showing, since the refresh `stat`s every provider root and its
    /// triggers fire in every workspace. Several triggers fire together on one workspace switch, and
    /// a pass is a hundred-odd `stat` chains, any of which can block for as long as a sleeping drive
    /// or a dead network mount takes to answer. So:
    ///
    /// - One per turn: a ticket is taken here and checked after the hop, so triggers that fire in
    ///   one main-actor turn produce one walk, the last one's. It is checked again after the walk,
    ///   so an answer overtaken while it was out is dropped rather than drawn over a newer one.
    /// - Off the main actor: the disk work runs in a detached task, as `refreshEditorRail` in
    ///   `ContentView+Editor.swift` does. `@AppStorage` and `FolderJumpStore` (`@MainActor`) are
    ///   read BEFORE the hop, so the walk is handed values.
    ///
    /// The on-screen guard comes first, and every input to it has a trigger of its own
    /// (`SidebarRefreshTriggerTests`): the guard drops whatever fires while the column is hidden,
    /// and nothing re-runs it on the way back.
    func refreshFolderSidebarRows() {
        guard folderSidebarIsShowing else { return }

        sidebarRefresh.ticket &+= 1
        let ticket = sidebarRefresh.ticket

        // Everything the main actor owns, read on it now. `FolderJumpStore` is `@MainActor` and
        // `browseSidebarFavoritePlacesRaw` is this view's `@AppStorage`; neither may be touched
        // from the walk. These are memory reads, so taking them per call costs nothing.
        let providers = folderSidebarProviders
        let inputs = FolderSidebarWalkInputs(
            providers: providers,
            remembered: providers.compactMap { provider in
                let root = (provider.rootPath as NSString).expandingTildeInPath
                guard !root.isEmpty else { return nil }
                return RememberedSource(root: root, name: provider.displayName,
                                        recents: FolderJumpStore.shared.recentPaths(forRoot: root),
                                        pinned: FolderJumpStore.shared.pinnedPaths(forRoot: root))
            },
            // Uncapped: two filters run after the walk (a root that is no longer a source, and
            // folders already under Favorites or Locations), and capping first would leave the
            // section short. `FolderSidebarModel.rows` applies `recentsLimit` last. Whichever mode
            // the heading shows gets the same subtractions and cap.
            recents: FolderJumpStore.shared.visitsAcrossRoots(
                folderSidebarRecentsMode, landings: Self.folderSidebarLandings(providers), limit: .max),
            favoriteOrder: FolderJumpStore.shared.favoriteOrder,
            favoritePlaces: folderSidebarFavoritePlaces)
        // The volume walk only when something can have changed it (`knownMountedVolumes`). Nil
        // means "walk it", inside the detached task below.
        let known = Self.knownMountedVolumes

        Task { @MainActor in
            // A newer request was taken in this same turn. It will do the work, from newer inputs.
            guard ticket == sidebarRefresh.ticket else { return }
            let resolved = await Task.detached(priority: .userInitiated) {
                Self.resolveFolderSidebarRows(inputs, volumes: known ?? Self.mountedVolumes())
            }.value
            // The walk can be overtaken while it is out (a mount, a pin, another switch); a late
            // answer must not be drawn over a newer one.
            guard ticket == sidebarRefresh.ticket else { return }

            Self.knownMountedVolumes = resolved.volumes
            Self.rememberMountedVolumes(resolved.volumes)
            folderSidebarRows = resolved.rows
            folderSidebarLocationRows = resolved.locations
            folderSidebarShortcutRows = resolved.shortcuts
            // Every mounted volume you could eject in Finder, source or not, keyed by mount point.
            // The internal check is a second guard keeping the startup disk out.
            folderSidebarEjectablePaths = Set(resolved.volumes.filter { $0.isRemovable && !$0.isInternal }
                                                  .map { FolderSidebarView.mountKey($0.path) })
            // A narrower set. Eject is offered on a network share too, but a share is not
            // `isLocal`, so unmounting it does NOT forget its sources
            // (`MountedVolumeMemory.Facts.isDetachable`); a confirmation saying the source will go
            // would be false.
            folderSidebarDetachablePaths = Set(resolved.volumes.filter(\.losesItsSourcesOnUnmount)
                                                  .map { FolderSidebarView.mountKey($0.path) })
        }
    }

    /// One source's remembered lists as the store holds them: read on the main actor, checked
    /// against the disk off it.
    struct RememberedSource: Sendable {
        let root: String
        let name: String
        let recents: [String]
        let pinned: [String]
    }

    /// Everything a refresh needs that only the main actor can answer, gathered into one value so
    /// the walk below takes arguments rather than reaching back into the view.
    struct FolderSidebarWalkInputs: Sendable {
        let providers: [CloudProvider]
        let remembered: [RememberedSource]
        let recents: [RememberedVisit]
        let favoriteOrder: [String]
        let favoritePlaces: [String]
    }

    /// Everything one refresh resolves, plus the volume walk it used: the unmount record needs the
    /// same list the rows were built from, without walking again.
    struct FolderSidebarResolution: Sendable {
        let rows: [FolderSidebarRow]
        let locations: [SidebarSourceRow]
        let shortcuts: [SidebarSourceRow]
        let volumes: [SidebarSourceModel.Volume]
    }

    /// The disk-touching half of a refresh, off the main actor. `nonisolated` is the point: every
    /// `stat` in a refresh is in here or what it calls, and each can block for seconds on a
    /// sleeping disk or a dead network mount.
    /// - Parameter links: the folders a source root links in from outside; the machine's table by
    ///   default. Passed to both halves, so the place rows and the Recents subtraction agree about
    ///   where `Documents` really is.
    nonisolated static func resolveFolderSidebarRows(
        _ inputs: FolderSidebarWalkInputs,
        volumes: [SidebarSourceModel.Volume],
        links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders
    ) -> FolderSidebarResolution {
        // One `reachable` call per source, which `stat`s the root once for both lists: under an
        // unreachable network mount every `stat` can block.
        let sources: [FolderSidebarModel.Source] = inputs.remembered.map { source in
            let remembered = Self.reachableFolders(recents: source.recents, pinned: source.pinned,
                                                   under: source.root)
            return FolderSidebarModel.Source(root: FolderJumpStore.key(forRoot: source.root),
                                             name: source.name,
                                             favorites: remembered.pinned,
                                             isAvailable: remembered.rootIsAvailable)
        }
        let places = Self.splitFolderSidebarPlaceRows(inputs.providers, volumes: volumes,
                                                      favoritePlaces: inputs.favoritePlaces,
                                                      links: links)
        return FolderSidebarResolution(
            rows: FolderSidebarModel.rows(
                sources: sources, recents: inputs.recents, favoriteOrder: inputs.favoriteOrder,
                // From the rows this pass built, not a second enumeration: the places depend on
                // Favorites, mounts and source claims, and a copy of that reasoning would drift.
                listedElsewhere: Self.folderSidebarListedElsewhere(
                    places.locations + places.shortcuts, roots: sources.map(\.root), links: links)),
            locations: places.locations,
            shortcuts: places.shortcuts,
            volumes: volumes)
    }

    // MARK: - The mounted volumes, walked once per mount event

    /// The last volume walk, kept until something can have changed it. The walk can block under an
    /// unreachable network mount, and the mounted set changes only when macOS says so
    /// (`didMount`, `willUnmount`, `didUnmount`, `didRenameVolume`), so it belongs to those events,
    /// not to every pane move.
    ///
    /// `nil` means "not walked yet": the launch walk in `onAppear` fills it, and each of the four
    /// handlers empties it. They invalidate rather than re-walk because `willUnmount` fires while
    /// the volume is going away, when a synchronous walk is most likely to block.
    @MainActor static var knownMountedVolumes: [SidebarSourceModel.Volume]?

    /// Forgets the cached walk. Called from every notification that can change what is mounted.
    @MainActor static func forgetMountedVolumes() { knownMountedVolumes = nil }

    /// The mounted volumes as last seen, walking only if nothing has been seen yet. For the
    /// recorders, which must never block: `willUnmount` arrives while the volume is torn down, and
    /// wants the answer taken while it was healthy.
    @MainActor static func mountedVolumesAsLastSeen() -> [SidebarSourceModel.Volume] {
        if let known = knownMountedVolumes { return known }
        let walked = mountedVolumes()
        knownMountedVolumes = walked
        return walked
    }

    /// Each source's landing folder, keyed the way the recents are: what Recents subtracts, so
    /// visiting a source does not add a row for a place Locations already lists.
    ///
    /// The provider's own `openAt`, not `SettingsManager.openAtIfReachable`: that falls back to the
    /// root, which is never a recent anyway, so the plain value agrees and costs no `stat`.
    /// `static` and taking its providers so a test can reach the keying, which fails silently: a
    /// raw `~/Dropbox` matches no root the store holds.
    nonisolated static func folderSidebarLandings(_ providers: [CloudProvider]) -> [String: String] {
        // Keyed as the store writes its recents: `key(forRoot:)` expands the `~` a folder source
        // keeps in its stored path. An empty `openAt` is carried, not skipped: it means the source
        // lands on its root, which no recent can name.
        var landings: [String: String] = [:]
        for provider in providers {
            landings[FolderJumpStore.key(forRoot: provider.rootPath)] = provider.openAt
        }
        return landings
    }

    /// Everything the column already offers under another heading, per source root: what Recents
    /// subtracts so one folder is not drawn twice. Each place row this refresh built (Favorites'
    /// places, every Locations row) is re-expressed relative to each source root, so `~/Documents`
    /// and a home-rooted source's recent `Documents` count as one folder.
    ///
    /// `PathBoundary.relativize`, not string prefixes: iCloud Drive's `Desktop` and `Documents` are
    /// links into the container, two spellings no prefix comparison relates
    /// (`PathBoundary.LinkedFolders`). The table is passed in so a test can supply its own.
    /// Lexical, with no `stat`: this runs once per source per row.
    ///
    /// An empty relative path (the row is the root) is dropped, since a root is never a recent
    /// (`FolderJumpStore.recordVisit` refuses one). Roots arrive normalised through
    /// `FolderJumpStore.key(forRoot:)`, so the keys meet the ones the recents are stored under.
    nonisolated static func folderSidebarListedElsewhere(
        _ rows: [SidebarSourceRow], roots: [String],
        links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> [String: Set<String>] {
        guard !rows.isEmpty, !roots.isEmpty else { return [:] }
        let paths = rows.map { ($0.absolutePath as NSString).expandingTildeInPath }
        var listed: [String: Set<String>] = [:]
        for root in roots {
            let relatives = Set(paths.compactMap { path -> String? in
                guard let relative = PathBoundary.relativize(path, under: root, links: links),
                      !relative.isEmpty else { return nil }
                return relative
            })
            if !relatives.isEmpty { listed[root] = relatives }
        }
        return listed
    }

    /// One canonical place, before it is known whether SyncCloud has it as a source.
    struct KnownPlace {
        let name: String
        let symbol: String
        let path: String
        let band: SidebarSourceRow.Band
    }

    /// Every place row, built place-first. A place decides its own name, symbol and band; a
    /// provider whose root is that folder only lends it an id and makes it `.configured`. So adding
    /// a place as a source (which clicking one does) changes what clicking it does, and nothing
    /// else. Built provider-first, `Macintosh HD` would turn into a cloud-band row named `/`, and
    /// Desktop or Downloads kept as folder sources would land in Locations, not Favorites.
    ///
    /// `nonisolated static`, taking the Favorites list rather than reading `@AppStorage`, because
    /// every `stat` here runs off the main actor. `refreshFolderSidebarRows` reads the list and
    /// hands it down, as it does `volumes`.
    /// - Parameter links: the folders a source root links in from outside: iCloud Drive's
    ///   `Desktop` and `Documents` (`PathBoundary.LinkedFolders`). The machine's table by default;
    ///   a test passes its own. It widens what a source CONTAINS (so `~/Documents` reads "in
    ///   iCloud" and clicking it navigates there) without widening what a source IS: only a root
    ///   proper claims a place as `.configured`, which keeps the iCloud row in Locations.
    nonisolated static func buildFolderSidebarPlaceRows(_ providers: [CloudProvider],
                                                        volumes: [SidebarSourceModel.Volume],
                                                        favoritePlaces: [String],
                                                        links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> [SidebarSourceRow] {
        let roots = Self.folderSidebarRoots(providers)
        let claims = Self.folderSidebarClaims(providers, links: links)
        var claimed = Set<String>()

        var places: [KnownPlace] = SidebarSourceModel.favoriteShortcuts.map {
            KnownPlace(name: $0.name, symbol: $0.symbol, path: $0.path, band: .shortcut)
        }
        places += Self.deviceEntries(volumes).map {
            KnownPlace(name: $0.name, symbol: $0.symbol, path: $0.path, band: .device)
        }
        let trash = SidebarSourceModel.trashEntry
        if Self.isMountedFolder(trash.path) {
            places.append(KnownPlace(name: trash.name, symbol: trash.symbol,
                                     path: trash.path, band: .trash))
        }

        var rows: [SidebarSourceRow] = places.compactMap { place in
            let resolvedPath = Self.resolved(place.path)
            // Does a source already name this exact folder? Then this row *is* that source.
            let owner = roots.first { SidebarSourceModel.isSameFolder(Self.resolved($0.path), resolvedPath) }
            if let owner { claimed.insert(owner.id) }
            // The Trash is never a source and never becomes one, whatever else is true of it.
            if place.band == .trash {
                return SidebarSourceRow(id: place.path, name: place.name, detail: nil,
                                        symbol: place.symbol, absolutePath: place.path,
                                        band: .trash, state: .revealOnly, isAvailable: true)
            }
            let container = owner == nil
                ? SidebarSourceModel.owningSource(of: place.path, among: claims, resolve: Self.resolved)
                : nil
            return SidebarSourceRow(
                id: owner?.id ?? place.path,
                // The place's name, not the source's: a folder source over `/` is named `/`, and
                // over `~` for the account's short name.
                name: place.name,
                detail: container.map { "in \($0.name)" },
                symbol: place.symbol, absolutePath: place.path, band: place.band,
                state: owner != nil ? .configured
                     : container.map { .inside(sourceId: $0.id, sourceName: $0.name) } ?? .unknown,
                isAvailable: Self.isMountedFolder(place.path))
        }

        // Everything left: the cloud accounts, and folder sources that are not one of the places
        // above. Qualified only where two would read the same word.
        let rest = providers.filter { !claimed.contains($0.id) }
        let details = SidebarSourceModel.qualifiers(
            names: rest.map(\.displayName), qualifiers: rest.map { Self.accountQualifier(for: $0) })
        rows += zip(rest, details).map { provider, detail in
            let root = (provider.rootPath as NSString).expandingTildeInPath
            return SidebarSourceRow(
                id: provider.id, name: provider.displayName, detail: detail,
                // The provider's own mark, as the tab strip and pane header wear it: `ProviderLogo`
                // resolves it to a bundled brand asset or an SF Symbol, so a cloud account gets its
                // own silhouette and a folder source keeps `folder.fill`.
                symbol: provider.imageName,
                absolutePath: root, band: .cloud, state: .configured,
                isAvailable: Self.isMountedFolder(root))
        }
        return Self.applyFolderSidebarFavoritePlaces(to: rows, favoritePlaces: favoritePlaces)
    }

    /// The places the user has in Favorites, decoded.
    var folderSidebarFavoritePlaces: [String] {
        SidebarFavoritePlaces.places(from: browseSidebarFavoritePlacesRaw)
    }

    /// Every write to the Favorites places goes through here, so bytes this build could not read
    /// are salvaged rather than overwritten. `SidebarFavoritePlaces.places(from:)` answers the
    /// standard set for an unreadable value, which is right to SHOW but would destroy the user's
    /// real list if the next Add, Remove or drag wrote it back.
    ///
    /// One funnel, so a new verb cannot skip the guard; the salvage runs at the write, not at
    /// launch, so it fires only for a value about to be overwritten.
    func writeFolderSidebarFavoritePlaces(_ places: [String]) {
        if SidebarFavoritePlaces.isUnreadable(browseSidebarFavoritePlacesRaw) {
            UserDefaults.standard.set(browseSidebarFavoritePlacesRaw,
                                      forKey: SidebarFavoritePlaces.salvageKey)
            Logger.shared.warning("Sidebar: the stored Favorites places could not be read — kept under “\(SidebarFavoritePlaces.salvageKey)” rather than overwritten")
        }
        browseSidebarFavoritePlacesRaw = SidebarFavoritePlaces.encoded(places)
    }

    /// Re-bands every place row against the user's Favorites list, which alone decides which
    /// section a place is drawn in. Applied after the rows are built, since favoriting changes
    /// nothing else the builder worked out, and a cloud account has no `KnownPlace` to rebuild from.
    ///
    /// A standard folder the user removed is dropped, not moved: `.shortcut` is Desktop's only band,
    /// so there is no Locations row to fall back to. Finder does the same, and
    /// `SidebarFavoritePlaces.restoring` is the way back. Home and the startup disk are built as
    /// `.device` rows and re-banded up into Favorites, so removing either moves it back to
    /// Locations rather than off the column.
    nonisolated static func applyFolderSidebarFavoritePlaces(
        to rows: [SidebarSourceRow], favoritePlaces: [String]) -> [SidebarSourceRow] {
        let wanted = Set(favoritePlaces.map(Self.resolved))
        return rows.compactMap { row in
            // The Trash is never in Favorites and never offers to be — see `favoriteVerb`.
            guard row.state != .revealOnly else { return row }
            let isWanted = wanted.contains(Self.resolved(row.absolutePath))
            if row.isFavoriteShortcut { return isWanted ? row : nil }
            return isWanted ? row.inBand(.shortcut) : row
        }
    }

    /// Splits one pass of ``buildFolderSidebarPlaceRows(_:)`` into the two sections. A partition,
    /// not a sort: `sorted(by:)` is not stable in Swift, so the cloud accounts, which share a band,
    /// could shuffle between renders.
    nonisolated static func splitFolderSidebarPlaceRows(
        _ providers: [CloudProvider], volumes: [SidebarSourceModel.Volume],
        favoritePlaces: [String],
        links: PathBoundary.LinkedFolders = PathBoundary.discoveredLinkedFolders) -> (locations: [SidebarSourceRow], shortcuts: [SidebarSourceRow]) {
        let all = Self.buildFolderSidebarPlaceRows(providers, volumes: volumes,
                                                   favoritePlaces: favoritePlaces, links: links)
        var locations: [SidebarSourceRow] = []
        for band in [SidebarSourceRow.Band.cloud, .device, .trash] {
            locations += all.filter { $0.band == band }
        }
        // Favorites in the list's order, not the builder's band order, which would re-sort the
        // section when a place is added and undo a reorder when a disk mounts.
        let favorites = Dictionary(all.filter(\.isFavoriteShortcut).map { (Self.resolved($0.absolutePath), $0) },
                                   uniquingKeysWith: { first, _ in first })
        return (locations, favoritePlaces.compactMap { favorites[Self.resolved($0)] })
    }

    nonisolated static func folderSidebarRoots(_ providers: [CloudProvider]) -> [(id: String, name: String, path: String)] {
        providers.map { (id: $0.id, name: $0.displayName,
                         path: ($0.rootPath as NSString).expandingTildeInPath) }
    }

    /// Every folder a source CONTAINS, for the "in <source>" test: its root, plus each folder the
    /// root links in from outside, under that source's id and name. `~/Documents` is inside iCloud
    /// through the container's `Documents` link; resolving symlinks can't show it, because the link
    /// points from the container out to the real folder.
    nonisolated static func folderSidebarClaims(_ providers: [CloudProvider],
                                                links: PathBoundary.LinkedFolders) -> [(id: String, name: String, path: String)] {
        providers.flatMap { provider -> [(id: String, name: String, path: String)] in
            let root = (provider.rootPath as NSString).expandingTildeInPath
            let linked = PathBoundary.linkedFolders(atRoot: root, in: links).values.sorted()
            return ([root] + linked).map { (id: provider.id, name: provider.displayName, path: $0) }
        }
    }

    /// Home, then the mounted volumes: the startup disk first, then the rest by name, since mount
    /// order differs between boots. Home and the startup disk are in
    /// `SidebarFavoritePlaces.standard`, so `applyFolderSidebarFavoritePlaces` lifts them into
    /// Favorites; building them here lets them fall back to Locations when removed. Takes the walk
    /// rather than making one, so a refresh pays for `mountedVolumeURLs` once.
    nonisolated static func deviceEntries(_ volumes: [SidebarSourceModel.Volume])
        -> [(name: String, symbol: String, path: String)] {
        let home = SidebarSourceModel.homeEntry
        return [home] + SidebarSourceModel.orderedVolumes(volumes)
            .map { (name: $0.name, symbol: $0.symbol, path: $0.path) }
    }

    /// The volumes macOS says are mounted and browsable. `skipHiddenVolumes` keeps out what Finder
    /// hides (preboot, recovery, the read-only system volume). A volume that fails to answer its
    /// resource values is dropped rather than drawn under a guessed name.
    nonisolated static func mountedVolumes() -> [SidebarSourceModel.Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                      .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true,
                  let name = values.volumeName else { return nil }
            return SidebarSourceModel.Volume(
                name: name, path: url.path,
                isRemovable: (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false),
                // Optional on some volume types. Absent is not internal, the safe direction: a
                // wrong glyph on an unusual disk beats promoting an external one to the top.
                isInternal: values.volumeIsInternal ?? false,
                // Absent reads as local, which a card that doesn't answer the key is. Needed
                // because a network share is ejectable too, and only a local volume's unmount means
                // its sources are gone. Removability must still agree before anything is removed.
                isLocal: values.volumeIsLocal ?? true)
        }
    }

    /// A provider's account, for the qualifier slot — the part of its id that distinguishes two
    /// accounts of the same service. Nil when there is nothing to add.
    nonisolated static func accountQualifier(for provider: CloudProvider) -> String? {
        // A folder source's qualifier is where it lives, since two folder sources can share a leaf
        // name as easily as two Drive accounts can share a service name.
        if provider.isLocalFolder {
            let parent = ((provider.rootPath as NSString).expandingTildeInPath as NSString)
                .deletingLastPathComponent
            return (parent as NSString).lastPathComponent
        }
        // Cloud accounts: the id carries the account, the display name carries the service.
        let id = provider.id
        guard let at = id.firstIndex(of: "@") else {
            let trimmed = id.replacingOccurrences(of: provider.displayName, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
            return trimmed.isEmpty ? nil : trimmed
        }
        // `someone.work@gmail.com` reads as `someone.work`: the local part tells Drive accounts
        // apart; the domain is the same on all of them.
        return String(id[id.startIndex..<at])
    }

    /// Symlinks resolved on both sides, for the containment check: under Desktop & Documents
    /// syncing `~/Desktop` is a link into `com~apple~CloudDocs`, which a plain string comparison
    /// would not relate to iCloud Drive.
    nonisolated static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().path
    }

    /// Which pane a sidebar click will act on, said out loud. `nil` outside Compare, where there is
    /// one pane. The side comes from `folderSidebarTargetIsLeft`, so this line, the accent border,
    /// the action bar, the pane-scoped chords and the Compare lens menus all agree.
    var folderSidebarTarget: SidebarTarget? {
        guard selectedWorkspace == .compare else { return nil }
        // The side only. A provider name would read as a scoping claim the column does not make:
        // these rows come from every enabled source.
        return SidebarTarget(targetsRight: !folderSidebarTargetIsLeft)
    }

    /// Whether this pane is the one the user is working in, and so wears the accent border.
    /// Compare only: elsewhere there is one pane. Not gated on the sidebar showing: the mark names
    /// the focused pane (where ⌘F opens, what Copy, Move and a lens scan act on), which has no
    /// other resting indicator.
    func paneIsFocusedPane(isLeft: Bool) -> Bool {
        guard selectedWorkspace == .compare else { return false }
        return isLeft == folderSidebarTargetIsLeft
    }

    /// The accent this pane's cards border themselves with, or nil when it is not the destination.
    /// Resolved once here so the column's three `paneCardIfNeeded` calls cannot disagree about
    /// whether the pane is marked.
    func paneCardAccent(isLeft: Bool) -> Color? {
        ActivePaneMark.cardAccent(
            isFocused: paneIsFocusedPane(isLeft: isLeft),
            accent: glassHue.accentColor,
            surfaceStyle: surfaceStyle)
    }

    // MARK: - The column

    /// A card, framed exactly as the Info inspector is: the same `bottomSectionCard` call with the
    /// same four arguments, so the two panels flanking the pane are one decision. The window is a
    /// floating card over glass, so a flat Finder-style column would leave nothing matching on the
    /// pane's left. The card supplies its own half-gutter (`cardInset`), so the seam beside it is
    /// a clear strip (`folderSidebarResizeHandle`).
    /// - Parameter width: the width the column should DRAW at, not always `browseSidebarWidth`. A
    ///   lens workspace shares its row with a rail and a panel that have hard minimums, so it
    ///   passes a clamped value (`PaneLogic.lensSidebarWidth`), which needs the row's width that
    ///   only the layout has.
    func folderSidebar(width: CGFloat) -> some View {
        FolderSidebarView(
            folderRows: folderSidebarRows,
            locationRows: folderSidebarLocationRows,
            shortcutRows: folderSidebarShortcutRows,
            currentRoot: FolderJumpStore.key(forRoot: folderSidebarRoot),
            currentRelativePath: syncManager.paneLocation(
                isLeft: folderSidebarTargetIsLeft,
                drawsColumns: resolvedViewMode(isLeft: folderSidebarTargetIsLeft) == .columns),
            currentSourceId: folderSidebarProviderId,
            width: width,
            collapsed: folderSidebarCollapsedSections,
            recentsMode: folderSidebarRecentsMode,
            onCycleRecentsMode: { browseSidebarRecentsMode = folderSidebarRecentsMode.next.rawValue },
            notice: folderSidebarNotice.map {
                SidebarNotice(message: $0.message, actionTitle: $0.actionTitle)
            },
            target: folderSidebarTarget,
            onOpenRowOnSide: { row, isLeft in
                openFolderSidebarRow(row, inNewTab: false, side: isLeft)
            },
            onOpenSourceOnSide: { source, isLeft in
                openFolderSidebarSource(source, inNewTab: false, side: isLeft)
            },
            accent: glassHue.accentColor,
            onOpen: { row, inNewTab in openFolderSidebarRow(row, inNewTab: inNewTab) },
            onToggleFavorite: { row in toggleFolderSidebarFavorite(row) },
            onOpenSource: { source, inNewTab in openFolderSidebarSource(source, inNewTab: inNewTab) },
            onToggleSection: { section in toggleFolderSidebarSection(section) },
            onNoticeAction: {
                if let notice = folderSidebarNotice { actOnFolderSidebarNotice(notice) }
            },
            onShowEnclosingFolder: { row in showFolderSidebarRowEnclosingFolder(row) },
            onToggleSourceFavorite: { source in toggleFolderSidebarPlaceFavorite(source) },
            onRemoveSource: { source in removeFolderSidebarSource(source) },
            // Folder sources only, from the settings list, not the row: `.configured` doesn't say
            // which kind of source, and `removeFolderSource` ignores a discovered account's id, so
            // offering Remove on one would silently do nothing.
            removableSourceIds: Set(settings.folderSources.map(\.id)),
            onEjectSource: { source in ejectFolderSidebarVolume(source) },
            ejectablePaths: folderSidebarEjectablePaths,
            detachablePaths: folderSidebarDetachablePaths,
            providerSettingsTitles: folderSidebarProviderSettingsTitles,
            onOpenProviderSettings: { source in openFolderSidebarProviderSettings(source) },
            onRestoreStandardFavorites: { restoreStandardFolderSidebarFavorites() },
            canRestoreStandardFavorites: SidebarFavoritePlaces.isMissingStandard(folderSidebarFavoritePlaces),
            onMoveFavorite: { from, to in moveFolderSidebarFavorite(from: from, to: to) },
            onMoveSource: { from, to in moveFolderSidebarSource(from: from, to: to) },
            onFavoriteRecent: { row, to in favoriteRecentByDrag(row, to: to) },
            onForgetRecent: { row in forgetFolderSidebarRecent(row) },
            // One-way sync's Syncs: Compare's sidebar only.
            syncs: selectedWorkspace == .compare ? AnyView(OneWaySyncSidebarSection(onSetUp: { openOneWaySyncSetup() })) : nil)
        .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
    }

    /// Which rows have a door to their vendor's own settings, and what the menu item says. Built
    /// from the enabled providers, not the rows: a row that is not a configured source carries a
    /// path for an id. A door whose app is not installed is left out (absent, not disabled); the
    /// title differs per vendor (`CloudProvider.settingsDoorTitle`).
    var folderSidebarProviderSettingsTitles: [String: String] {
        folderSidebarProviders.reduce(into: [:]) { titles, provider in
            guard let door = provider.settingsDoor, let title = provider.settingsDoorTitle,
                  ProviderSettingsOpener.canOpen(door) else { return }
            titles[provider.id] = title
        }
    }

    /// The context menu's provider-settings verb: resolve the row back to its provider and open
    /// that provider's door. By id against the same list the titles were built from, so the menu
    /// cannot offer a door this cannot find.
    func openFolderSidebarProviderSettings(_ source: SidebarSourceRow) {
        guard let provider = folderSidebarProviders.first(where: { $0.id == source.id }),
              let door = provider.settingsDoor else { return }
        ProviderSettingsOpener.open(door)
    }

    /// The stored width, clamped on read as well as on write: a later build, a different range or
    /// a hand-edited plist can put the `@AppStorage` double out of bounds, leaving a column too
    /// narrow to grab its divider.
    var browseSidebarWidth: CGFloat {
        min(max(CGFloat(browseSidebarWidthRaw), FolderSidebarView.minWidth), FolderSidebarView.maxWidth)
    }

    /// Which sections are folded, decoded from one comma-joined string rather than a key per
    /// section. An unrecognised value is ignored, so a string written by a later build cannot fold
    /// something this one cannot draw.
    var folderSidebarCollapsedSections: Set<FolderSidebarView.Section> {
        Set(browseSidebarCollapsed.split(separator: ",")
            .compactMap { FolderSidebarView.Section(rawValue: String($0)) })
    }

    /// The stored mode, decoded. A value this build does not know reads as plain Recents.
    var folderSidebarRecentsMode: RecentsMode {
        RecentsMode(rawValue: browseSidebarRecentsMode) ?? .recents
    }

    /// A pane moved to a folder: the Revisited and Frequent half of a visit. The store settles the
    /// folder the pane left, and a check after the stay threshold counts this one while the pane is
    /// still there, so a folder joins Revisited without the user having to move on first.
    func noteFolderArrival(pane: String, root: String, relativePath: String) {
        FolderJumpStore.shared.noteArrival(pane: pane, root: root, relativePath: relativePath,
                                           name: (relativePath as NSString).lastPathComponent)
        Task { @MainActor in
            try? await Task.sleep(for: FolderJumpStore.settleDelay)
            FolderJumpStore.shared.settleStays()
        }
    }

    func toggleFolderSidebarSection(_ section: FolderSidebarView.Section) {
        var folded = folderSidebarCollapsedSections
        if folded.contains(section) { folded.remove(section) } else { folded.insert(section) }
        // Sorted so the same set always stores the same string.
        browseSidebarCollapsed = folded.map(\.rawValue).sorted().joined(separator: ",")
    }

    // MARK: - What a click does

    /// A plain click re-scopes the pane; ⌘ opens the folder in a new tab. `focusOn`, not a column
    /// drill, as the ⌘K palette does (`revealInSourcePane`): a jump changes where the pane is, and
    /// a drill would leave the breadcrumb showing a route the user never took.
    /// - Parameter side: an explicit pane, from the row's context menu; `nil` means wherever the
    ///   sidebar is pointed. Passed so the menu can open one folder on the other side WITHOUT
    ///   moving the target.
    func openFolderSidebarRow(_ row: FolderSidebarRow, inNewTab: Bool, side: Bool? = nil) {
        guard FolderSidebarModel.canOpen(row) else { return }
        let isLeft = side ?? folderSidebarTargetIsLeft
        let absolute = (row.root as NSString).appendingPathComponent(row.relativePath)
        if inNewTab {
            openInNewTab(absolutePath: absolute, isLeft: isLeft)
            return
        }
        // A row from another source switches the source first: `focusOn` takes a path relative to
        // the pane's current root, and would otherwise land somewhere real and wrong in the wrong
        // account. Asked of the pane the row is OPENING ON (`isLeft`), not of `folderSidebarRoot`,
        // which describes the target and is wrong exactly when `side` is set.
        let paneRoot = (settings.rootPath(for: isLeft ? leftProviderId : rightProviderId) as NSString)
            .expandingTildeInPath
        if FolderJumpStore.key(forRoot: paneRoot) != row.root {
            guard let provider = folderSidebarProviders.first(where: {
                FolderJumpStore.key(forRoot: ($0.rootPath as NSString).expandingTildeInPath) == row.root
            }) else {
                Logger.shared.warning("Sidebar: no enabled source owns \(row.root) — cannot open \(row.relativePath)")
                return
            }
            setFolderSidebarProvider(provider.id, isLeft: isLeft)
        }
        syncManager.focusOn(relativePath: row.relativePath, isLeft: isLeft)
    }

    /// Opens the folder a row LIVES IN, on the pane the sidebar is pointed at: Finder's verb, for
    /// when a name is not enough (two `Legal` folders, a recent you no longer recognise). Routed
    /// through `openFolderSidebarRow`, so a row from another account still switches the source
    /// first.
    func showFolderSidebarRowEnclosingFolder(_ row: FolderSidebarRow, side: Bool? = nil) {
        guard let parent = FolderSidebarModel.enclosingFolder(of: row) else { return }
        Logger.shared.info("Sidebar: showing “\(row.name)” in its enclosing folder (\(parent.relativePath.isEmpty ? "the source root" : parent.relativePath))")
        openFolderSidebarRow(parent, inNewTab: false, side: side)
    }

    /// Adds an unfavourited row, removes a favourited one: the same store call as the pane
    /// header's jump menu and the breadcrumb, so the three cannot disagree. Keyed by the row's own
    /// root, not the pane's, so a favorite in another account is removable without visiting it.
    func toggleFolderSidebarFavorite(_ row: FolderSidebarRow) {
        let wasFavorite = row.group == .pinned
        FolderJumpStore.shared.togglePin(root: row.root, relativePath: row.relativePath, name: row.name)
        Logger.shared.info("Sidebar: \(wasFavorite ? "removed" : "added") favorite “\(row.name)” (\(row.relativePath.isEmpty ? "root" : row.relativePath))")
        refreshFolderSidebarRows()
    }

    /// Takes one row out of Recents. Keyed by the row's own root, like the favorite toggle, so a
    /// recent in an account the panes are not showing is removable without visiting it. No
    /// confirmation or undo: the entry records a visit, and going back writes it again
    /// (`FolderJumpStore.forgetRecent`).
    func forgetFolderSidebarRecent(_ row: FolderSidebarRow) {
        guard row.group == .recents else { return }
        FolderJumpStore.shared.forgetRecent(root: row.root, relativePath: row.relativePath)
        Logger.shared.info("Sidebar: removed “\(row.name)” (\(row.relativePath)) from Recents")
        refreshFolderSidebarRows()
    }

    /// Puts a place in Favorites, or takes it out: the place-row counterpart to
    /// `toggleFolderSidebarFavorite`. Two lists, because a remembered folder is a path inside a
    /// source, while a place may belong to no source at all (an unplugged disk, `~/Downloads` never
    /// added), and `FolderJumpStore` would need a root invented for it.
    func toggleFolderSidebarPlaceFavorite(_ source: SidebarSourceRow) {
        guard SidebarSourceModel.favoriteVerb(for: source) != nil else { return }
        let places = folderSidebarFavoritePlaces
        // Toggled on the STORED spelling where there is one, so a row whose path resolves through
        // a symlink does not add a second entry for the same folder.
        let stored = places.first { Self.resolved($0) == Self.resolved(source.absolutePath) }
        let next = SidebarFavoritePlaces.toggling(stored ?? source.absolutePath, in: places)
        writeFolderSidebarFavoritePlaces(next)
        Logger.shared.info("Sidebar: \(stored == nil ? "added" : "removed") favorite place “\(source.name)” (\(source.absolutePath))")
        refreshFolderSidebarRows()
    }

    /// Adds a folder in a PANE to Favorites, or takes it out: the route for a folder you are
    /// looking at in a pane, which the sidebar rows and the header's jump menu don't cover. Keyed
    /// to the row's pane, not the focused one: a context menu does not move focus, and a
    /// right-click in the other pane would be filed against the wrong account, often silently.
    func toggleFavorite(forPaneFolder node: FileNode, isLeft: Bool) {
        // The same rule the menu's `isFolderFavorite` asked, not a second copy, so the label and
        // the click cannot disagree about Add and Remove.
        guard let place = PaneActionDelegate.favoritePlace(
            nodePath: node.id, isDirectory: node.isDirectory,
            paneRoot: settings.rootPath(for: isLeft ? leftProviderId : rightProviderId)) else {
            Logger.shared.warning("Pane: cannot favorite \(node.id) — it is not a folder inside this pane's source")
            return
        }
        let (key, relative) = (place.root, place.relativePath)
        let wasFavorite = FolderJumpStore.shared.pinnedPaths(forRoot: key).contains(relative)
        FolderJumpStore.shared.togglePin(root: key, relativePath: relative, name: node.name)
        Logger.shared.info("Pane: \(wasFavorite ? "removed" : "added") favorite “\(node.name)” (\(relative))")
        refreshFolderSidebarRows()
    }

    /// Puts `SidebarFavoritePlaces.standard` back, leaving everything else where it is.
    func restoreStandardFolderSidebarFavorites() {
        writeFolderSidebarFavoritePlaces(
            SidebarFavoritePlaces.restoring(folderSidebarFavoritePlaces))
        Logger.shared.info("Sidebar: restored the standard Favorites places")
        refreshFolderSidebarRows()
    }

    /// A click on a source row. Three states, three meanings — see `SidebarSourceRow.State`.
    /// - Parameter side: as `openFolderSidebarRow(_:inNewTab:side:)`.
    func openFolderSidebarSource(_ source: SidebarSourceRow, inNewTab: Bool, side: Bool? = nil) {
        guard source.isAvailable else { return }
        let isLeft = side ?? folderSidebarTargetIsLeft
        switch source.state {
        case .configured:
            // A new tab lands at the source's root, not its last folder: a row points at one
            // place whether you click it, ⌘-click it or drop on it.
            if inNewTab {
                openInNewTab(absolutePath: source.absolutePath, isLeft: isLeft)
            } else {
                setFolderSidebarProvider(source.id, isLeft: isLeft)
            }
        case .inside(let ownerId, let owner):
            openFolderSidebarShortcutInsideItsOwner(source, ownerId: ownerId, owner: owner,
                                                    inNewTab: inNewTab, isLeft: isLeft)
        case .unknown:
            promoteFolderSidebarShortcut(source, isLeft: isLeft, inNewTab: inNewTab)
        case .revealOnly:
            // The Trash, and only the Trash: worth a row, not a scan, so it opens in Finder.
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: source.absolutePath)
        }
    }

    /// A local shortcut whose folder lives inside a source the app already has: switch to that
    /// source and navigate to the folder, adding nothing. Desktop & Documents syncing creates this
    /// case, and is why `SidebarSourceModel.owningSource` resolves symlinks: promoting `~/Desktop`
    /// would put a second source over a tree iCloud already scans, and Storage would count the
    /// bytes twice.
    /// - Parameter isLeft: the pane resolved by the caller (the context menu's side, or the
    ///   target). Passed, never re-read from `folderSidebarTargetIsLeft`, so "Open in Right Pane"
    ///   works here as in the other `.state` branches.
    func openFolderSidebarShortcutInsideItsOwner(_ source: SidebarSourceRow, ownerId: String,
                                                 owner: String, inNewTab: Bool, isLeft: Bool) {
        let resolved = Self.resolved(source.absolutePath)
        // By id, never by display name, so two same-named sources cannot pick the wrong root.
        guard let provider = folderSidebarProviders.first(where: { $0.id == ownerId }) else {
            Logger.shared.warning("Sidebar: \(source.name) claims to be in \(owner), which is not an enabled source")
            return
        }
        let root = Self.resolved((provider.rootPath as NSString).expandingTildeInPath)
        // `focusOn` takes a path relative to the owning root. Containment is re-checked, since a
        // source path edited after the row was built would make a blind strip produce garbage.
        // `PathBoundary`, so `~/Documents` under iCloud Drive relativizes through the link's name.
        guard let relative = PathBoundary.relativize(resolved, under: root) else {
            Logger.shared.warning("Sidebar: \(source.name) is no longer inside \(owner) — its source has moved")
            return
        }
        if inNewTab {
            openInNewTab(absolutePath: resolved, isLeft: isLeft)
            return
        }
        // Compared against the pane being opened on, matching the provider write below.
        let alreadyOnIt = provider.id == (isLeft ? leftProviderId : rightProviderId)
        // The place IS the source's root, so the ordinary provider switch lands where this click
        // means. Nothing to arm.
        guard !relative.isEmpty else {
            if !alreadyOnIt { setFolderSidebarProvider(provider.id, isLeft: isLeft) }
            return
        }
        // Already on the owning source: a plain navigation, no switch to survive.
        guard !alreadyOnIt else {
            syncManager.focusOn(relativePath: relative, isLeft: isLeft)
            return
        }
        // **A bare provider write would throw this navigation away:** `onChange(of: leftProviderId)`
        // fires on the next update and `retargetPane()` re-homes the pane at the source's landing
        // folder, dropping the folder the user clicked. Same three statements, in the same order,
        // as `CommandPaletteHost.switchSourceAndReveal`: `focusOn` first, so both writes land in
        // one turn and the visit is recorded against the NEW root; the ARMED provider write second,
        // so its handler finds the navigation done; the reload last, resolving both providers by
        // the ids as they now are.
        syncManager.focusOn(relativePath: relative, isLeft: isLeft)
        adoptProviderForTab(provider.id, isLeft: isLeft,
                            log: "Sidebar: \(source.name) opened inside \(owner) on the "
                                + "\(PaneSideChoice.name(isLeft)) pane at \(relative)")
        refreshForTabSwitch(movedPane: isLeft)
    }

    /// A local folder SyncCloud has not been given: add it as a folder source, open it, and say so.
    /// Taken back from the notice, not with ⌘Z: the window's `UndoManager` holds file operations,
    /// and a source change on it would make ⌘Z after a move remove the source instead of undoing
    /// the move.
    func promoteFolderSidebarShortcut(_ source: SidebarSourceRow, isLeft: Bool, inNewTab: Bool) {
        // `addFolderSource` returns an existing source's id rather than minting a duplicate, even
        // for a discovered provider's own root, so a missed containment case only switches to the
        // source already there. Whether it MINTED one is decided by membership taken BEFORE the
        // call: the row can name a disabled source the enabled-only builder cannot see, and an
        // after-the-fact test would say "Added" and offer a Remove that deletes the user's source.
        let knownBefore = Set(settings.folderSources.map(\.id) + settings.availableProviders.map(\.id))
        let id = settings.addFolderSource(path: source.absolutePath)
        let wasAdded = !knownBefore.contains(id)
        // A pre-existing source reached from a "not added yet" row can only be a disabled one
        // (enabled ones draw as `.configured`). The click means "use this folder", so switch it on;
        // a pane on a disabled provider is a state the header's menu cannot reach.
        if !wasAdded && !settings.isEnabled(id) {
            settings.setEnabled(true, for: id)
            Logger.shared.info("Sidebar: re-enabled \(source.name) (\(id)) — promoted while disabled")
        }
        // No rename here: `FolderSource.defaultDisplayName` names a volume root after the volume.
        // An override would mark the source user-renamed in Settings, and would replace the home
        // folder's deliberate "Home folder" with the account's short name.
        if inNewTab {
            openInNewTab(absolutePath: source.absolutePath, isLeft: isLeft)
        } else {
            setFolderSidebarProvider(id, isLeft: isLeft)
        }
        if wasAdded {
            folderSidebarNotice = FolderSidebarNotice(
                message: "Added \(source.name) as a source", action: .undoPromotion(sourceId: id))
        }
        refreshFolderSidebarRows()
    }

    /// Ejects the volume a row sits on: Finder's verb, where the user is looking at the card. It
    /// does not remove the source itself; the unmount does, through `didUnmountNotification` →
    /// `forgetFolderSidebarSourcesOnUnmount`, so an eject from here and from Finder end the same.
    /// A refused eject (a file on the card is open, here or elsewhere) is reported, not swallowed.
    func ejectFolderSidebarVolume(_ source: SidebarSourceRow) {
        let url = URL(fileURLWithPath: source.absolutePath)
        let name = source.name
        // Off the main thread: macOS flushes the volume's buffers before it unmounts, which can
        // take seconds, and `unmountAndEjectDevice(at:)` is synchronous, so on the main thread it
        // would freeze the window.
        Task {
            do {
                try await Self.ejectVolume(at: url)
                Logger.shared.info("User ejected \(name) (\(url.path))")
            } catch {
                // The real reason, not a guess: "something is still using it" is common but not
                // the only cause, and naming the wrong one sends the user hunting for an open file.
                Logger.shared.warning("Could not eject \(name): \(error.localizedDescription)")
                folderSidebarNotice = FolderSidebarNotice(
                    message: "Could not eject \(name). \(error.localizedDescription)",
                    action: .dismiss)
            }
        }
    }

    /// The eject itself, on a background thread. **`nonisolated`, so the `await` really leaves the
    /// main actor:** an `async` member of a `@MainActor` type would hop back onto it and block,
    /// silently.
    nonisolated static func ejectVolume(at url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
        }.value
    }

    /// Forgets the sources on a volume that has just been unmounted. Ejecting a card means the
    /// user is done with it, so its source goes rather than dimming, which is what an asleep source
    /// does. Safe silently, like the rename-follow: an unmount is an event the app is told about,
    /// never an inference.
    ///
    /// `MountedVolumeMemory` decides whether the volume counted, since that can't be read once it
    /// has gone: a network share is ejectable too. A volume SyncCloud never saw mounted is left
    /// alone. Pins and recents under the root are kept, keyed by path, so the card comes back whole.
    func forgetFolderSidebarSourcesOnUnmount(_ note: Notification) {
        guard let unmounted = NSWorkspace.DidUnmountVolumeMessage.makeMessage(note) else {
            Logger.shared.warning("A volume was unmounted but the notification did not say which — nothing removed")
            return
        }
        let path = unmounted.volumeURL.path
        defer {
            MountedVolumeMemory.shared.forget(volume: path)
            // Unconditional: the volume's own Locations row comes from the mounted-volume walk,
            // so it is stale the moment this fires, whether or not a source was removed.
            refreshFolderSidebarRows()
        }
        guard MountedVolumeMemory.shared.isDetachable(volume: path) else { return }
        let removed = settings.removeFolderSources(onVolume: path)
        guard !removed.isEmpty else { return }
        // "No longer connected", not "ejected": `didUnmount` fires for a pulled card as for an
        // ejected one, and macOS does not say which.
        folderSidebarNotice = FolderSidebarNotice(
            message: removed.count == 1
                ? "\(removed[0]) is no longer connected — removed it as a source."
                : "\(unmounted.localizedVolumeName) is no longer connected — removed \(removed.count) sources on it.",
            action: .dismiss)
    }

    /// Records what a volume is while it is still mounted, for the unmount that cannot ask. Fed
    /// from the launch walk, `didMountNotification` and the sidebar's refresh; the refresh alone is
    /// NOT enough, since it returns early while the column is hidden.
    static func rememberMountedVolumes(_ volumes: [SidebarSourceModel.Volume]) {
        MountedVolumeMemory.shared.record(volumes.map {
            (path: $0.path,
             facts: MountedVolumeMemory.Facts(isRemovable: $0.isRemovable, isLocal: $0.isLocal))
        })
    }

    /// Takes a folder source out of the app, from the column. For a row that cannot come back,
    /// such as a source on a volume renamed while SyncCloud was quit: it draws dimmed like an asleep
    /// one, and would otherwise need Settings ▸ Sources.
    ///
    /// Not the notice's Remove, which takes back this session's promotion exactly. This one is
    /// confirmed first (`pendingSourceRemoval`, in the view), because the id carries the name
    /// override, landing folder and enabled flag. A notice naming the removed source is cleared, so
    /// its Remove cannot offer to remove something already gone.
    func removeFolderSidebarSource(_ source: SidebarSourceRow) {
        settings.removeFolderSource(id: source.id)
        if folderSidebarNotice?.sourceId == source.id { folderSidebarNotice = nil }
        refreshFolderSidebarRows()
    }

    /// Undoes a promotion the user did not mean. Removes only what this added, and only while the
    /// notice offering it is still on screen.
    func actOnFolderSidebarNotice(_ notice: FolderSidebarNotice) {
        // A `switch`, not an `if`, so a new kind has to say what its link does.
        switch notice.action {
        case .undoPromotion(let sourceId):
            settings.removeFolderSource(id: sourceId)
            refreshFolderSidebarRows()
        case .dismiss:
            break
        }
        folderSidebarNotice = nil
    }

    // MARK: - Reordering

    /// Moves a favorite within the section, and records the whole resulting sequence.
    ///
    /// The order is stored apart from membership (`FolderJumpStore.favoriteOrder`), because
    /// Favorites spans every source: a Dropbox favorite above an iCloud one has no place in
    /// per-root arrays, and an order that stopped at a source boundary the user cannot see would
    /// snap rows back.
    ///
    /// The drag index spans two lists: place rows first, remembered folders after, so index
    /// `places` is the first folder. Each list lives in its own store, so a row moves within its
    /// own half, and `clampedDrop` in the view keeps the insertion line from promising otherwise.
    func moveFolderSidebarFavorite(from: Int, to: Int) {
        let move = SidebarReorder.favoritesMove(from: from, to: to,
                                                places: folderSidebarShortcutRows.count)
        if move.isPlace {
            moveFolderSidebarFavoritePlace(from: move.from, to: move.to)
        } else {
            moveFolderSidebarFavoriteFolder(from: move.from, to: move.to)
        }
    }

    /// Reorders the Favorites place rows: Desktop, and anything else put there.
    func moveFolderSidebarFavoritePlace(from: Int, to: Int) {
        // Indexed against the DRAWN rows, then mapped back to stored paths: the stored list can
        // name a place that is not on screen (an unplugged disk).
        let drawn = folderSidebarShortcutRows.map { Self.resolved($0.absolutePath) }
        guard drawn.indices.contains(from) else { return }
        let moved = SidebarReorder.moved(drawn, from: from, to: to)
        guard moved != drawn else { return }
        let stored = folderSidebarFavoritePlaces
        let byResolved = Dictionary(stored.map { (Self.resolved($0), $0) },
                                    uniquingKeysWith: { first, _ in first })
        // A place that is not on screen keeps its slot. Appending the leftovers instead would send
        // an unplugged disk to the bottom whenever another row is dragged.
        let next = SidebarReorder.resplicing(stored.map(Self.resolved), visibleInNewOrder: moved)
        writeFolderSidebarFavoritePlaces(next.compactMap { byResolved[$0] })
        Logger.shared.info("Sidebar: moved favorite place “\(folderSidebarShortcutRows[from].name)” to position \(min(to, moved.count))")
        refreshFolderSidebarRows()
    }

    /// Indexed against the DRAWN favorites, then written back into the stored ones, which differ:
    /// `reachable` drops a favorite whose folder is deleted and the builder drops one whose source
    /// is gone. A drawn index into the stored list would move a row the user cannot see.
    func moveFolderSidebarFavoriteFolder(from: Int, to: Int) {
        let drawn = FolderSidebarModel.rows(folderSidebarRows, in: .pinned)
        guard drawn.indices.contains(from) else { return }
        let keys = drawn.map { FolderJumpStore.favoriteKey(root: $0.root, relativePath: $0.relativePath) }
        let movedKeys = SidebarReorder.moved(keys, from: from, to: to)
        guard movedKeys != keys else { return }
        let current = FolderJumpStore.shared.favoriteVisitsAcrossRoots()
        let allKeys = current.map { FolderJumpStore.favoriteKey(root: $0.root, relativePath: $0.relativePath) }
        let byKey = Dictionary(zip(allKeys, current), uniquingKeysWith: { first, _ in first })
        let moved = SidebarReorder.resplicing(allKeys, visibleInNewOrder: movedKeys)
            .compactMap { byKey[$0] }
        FolderJumpStore.shared.setFavoriteOrder(moved)
        // Logged because a drag rewrites a persisted preference with no other record, so a drag
        // that moved the wrong entry is one log line away. Named off the DRAWN list, the one
        // `from` and `to` index into.
        Logger.shared.info("Sidebar: moved favorite “\(drawn[from].name)” to position \(min(to, keys.count))")
        refreshFolderSidebarRows()
    }

    /// Moves a source, and records the order in Settings rather than in the sidebar, so the
    /// sidebar and the pane-header dropdown show one order. The stored list is provider ids, so a
    /// source that disappears leaves no hole and a new one appends.
    ///
    /// Indexed against `folderSidebarLocationRows`, the exact list the drag measured, not
    /// `folderSidebarProviders`: a provider whose folder is a canonical place is claimed by it and
    /// drawn in Favorites (`buildFolderSidebarPlaceRows`), so the two lists differ and an index
    /// into the wrong one moves the wrong source. Rows that are not sources contribute nothing,
    /// and sources not drawn here keep their positions (`SidebarReorder.reordering`).
    func moveFolderSidebarSource(from: Int, to: Int) {
        let shown = folderSidebarLocationRows
        guard shown.indices.contains(from) else { return }
        let moved = SidebarReorder.moved(shown, from: from, to: to)
        guard moved.map(\.id) != shown.map(\.id) else { return }
        let all = settings.availableProviders.map(\.id)
        let known = Set(all)
        let subset = moved.map(\.id).filter { known.contains($0) }
        let newOrder = SidebarReorder.reordering(all, subsetInNewOrder: subset)
        guard newOrder != all else { return }
        settings.setSourceOrder(newOrder)
        Logger.shared.info("Sidebar: moved source “\(shown[from].name)” — order is now \(newOrder.joined(separator: ", "))")
        refreshFolderSidebarRows()
    }

    /// A recent dragged into Favorites, landing where it was dropped. Two writes, in this order:
    /// the folder becomes a favorite, then the order is rewritten with it at the drop index. The
    /// other way round, `orderedFavorites` would ignore an order naming a key not yet a favorite,
    /// and the row would land at the bottom.
    func favoriteRecentByDrag(_ row: FolderSidebarRow, to: Int) {
        // `to` is in the section's combined index space (places first, then folders); this
        // reorders the folders alone. `clampedDrop` has already kept it out of the first half.
        let target = max(0, to - folderSidebarShortcutRows.count)
        // The drop index is among the folders ON SCREEN, so the sequence is built from those and
        // respliced into the stored list, as in `moveFolderSidebarFavoriteFolder`.
        let added = FolderJumpStore.favoriteKey(root: row.root, relativePath: row.relativePath)
        var visible = FolderSidebarModel.rows(folderSidebarRows, in: .pinned)
            .map { FolderJumpStore.favoriteKey(root: $0.root, relativePath: $0.relativePath) }
        visible.insert(added, at: min(max(target, 0), visible.count))

        FolderJumpStore.shared.togglePin(root: row.root, relativePath: row.relativePath, name: row.name)
        let favorites = FolderJumpStore.shared.favoriteVisitsAcrossRoots()
        let allKeys = favorites.map { FolderJumpStore.favoriteKey(root: $0.root, relativePath: $0.relativePath) }
        // `togglePin` toggles: a recent that was already a favorite has just been REMOVED. Refresh
        // and stop rather than write an order naming a key that is not a favorite.
        guard allKeys.contains(added) else {
            refreshFolderSidebarRows()
            return
        }
        let byKey = Dictionary(zip(allKeys, favorites), uniquingKeysWith: { first, _ in first })
        FolderJumpStore.shared.setFavoriteOrder(
            SidebarReorder.resplicing(allKeys, visibleInNewOrder: visible).compactMap { byKey[$0] })
        Logger.shared.info("Sidebar: made “\(row.name)” a favorite by dragging it out of Recents, at position \(min(target, visible.count - 1))")
        refreshFolderSidebarRows()
    }

    /// Points the target pane at a source. One member rather than the ternary repeated at each
    /// write, for the reason `CommandPaletteHost.aimProvider` gives.
    func setFolderSidebarProvider(_ id: String, isLeft: Bool) {
        if isLeft { leftProviderId = id } else { rightProviderId = id }
    }
}

/// A notice at the foot of the column: a promotion that can still be taken back (the inline
/// alternative to ⌘Z), or a fact to dismiss.
struct FolderSidebarNotice: Equatable, Identifiable {

    /// What the notice's link does. A promotion is an act this column performed and can undo
    /// exactly. An eject-removal follows hardware that is gone, with no folder left to re-add a
    /// source at, so that notice states the fact.
    enum Action: Equatable {
        /// Take back the promotion this session made: the source `addFolderSource` created.
        case undoPromotion(sourceId: String)
        /// Just clear the line. Nothing else in this file clears a notice, so without it a notice
        /// about a gone volume would stay for the rest of the session.
        case dismiss
    }

    /// The link's word, which is the action's own name for itself.
    var actionTitle: String {
        switch action {
        case .undoPromotion: return "Remove"
        case .dismiss: return "Dismiss"
        }
    }

    let message: String
    let action: Action

    /// Keyed by the message, since not every notice has a source. The column shows one at a time,
    /// so distinct messages are enough.
    var id: String { message }

    /// The source a promotion notice is about, where there is one. `nil` for every other kind, so
    /// a caller clearing "the notice about this source" cannot match an eject notice by accident.
    var sourceId: String? {
        if case .undoPromotion(let id) = action { return id }
        return nil
    }
}
