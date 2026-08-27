import SwiftUI
import Dashboard
import Events
import Settings
import Sync
import Design

/// **The folder sidebar** — the host half. The column itself is `Dashboard.FolderSidebarView`;
/// what lives here is where its rows come from and what a click does.
///
/// Held and unreachable from 2026-08-20 until v4.4, so that the column could arrive Finder-shaped
/// rather than as two ungrouped lists under one source. Live since item #13 landed.
extension ContentView {

    // MARK: - Which pane a row acts on

    /// **The pane a sidebar row acts on**, written as a question rather than as `true`.
    ///
    /// In a single-source workspace this is always the left pane, which is the only one there is.
    /// Compare is the case that decides the shape: two panes and two sources, where a row has to
    /// act on the one the user is working in. Hardcoding `isLeft: true` here — which is what the
    /// v4.2 draft did throughout — is precisely the surgery reaching those workspaces would have
    /// had to undo, and it did not have to be undone.
    var folderSidebarTargetIsLeft: Bool {
        // **The pane the user is working in — the same answer the action bar and the lens scans
        // get, and the one the accent border draws.**
        //
        // Two earlier rules died here. It followed `PaneLogic.activePane` — which pane holds a
        // SELECTION — and that was reported unusable in the one workspace where it mattered: with
        // nothing selected the answer is always the left pane, so aiming the right pane at a folder
        // meant first selecting a file in it, which nothing tells you and which a click on that
        // pane's background undoes. A pair of capsules in the sidebar header replaced it and fixed
        // that, at the cost of a control that could disagree with everything else on screen.
        //
        // `focusedPane` is neither. It survives a deselect by construction (see
        // `PaneLogic.focusedSideAfterSelectionWrite`), which is exactly what the selection rule
        // could not do, and it is set by working in a pane rather than by a control beside it.
        guard selectedWorkspace == .compare else { return true }
        return focusedPane == .left
    }

    var folderSidebarProviderId: String {
        folderSidebarTargetIsLeft ? leftProviderId : rightProviderId
    }

    /// Whether the column is on screen — the one rule, so `browseLayout`'s `if` and the refresh's
    /// guard cannot come to disagree about it.
    var folderSidebarIsShowing: Bool {
        FolderSidebarModel.isShowing(
            workspaceSupportsSidebar: selectedWorkspace.supportsFolderSidebar,
            panesCollapsed: panesHiddenForCurrentTab,
            preference: browseSidebarVisible)
    }

    /// The provider root the target pane is on, expanded.
    ///
    /// Expanded, matching `FolderJumpStore.key(forRoot:)`, which expands before keying: a folder
    /// source is stored with its `~` intact and the two spellings never met, which is the defect
    /// that comment records.
    var folderSidebarRoot: String {
        (settings.path(for: folderSidebarProviderId) as NSString).expandingTildeInPath
    }

    /// **Enabled sources, not merely available ones.**
    ///
    /// This was the last open question on the design page, and the two surfaces genuinely
    /// disagreed: ⌘K builds its rows from `settings.enabledProviders` while the v4.2 refresh read
    /// `settings.availableProviders`, so a source switched off in Settings would have appeared in
    /// one and not the other. Enabled wins, because it is what the pane header's own dropdown
    /// offers — a sidebar row that switched the pane to a source the header will not list would be
    /// a way into a state the rest of the app says you cannot reach.
    var folderSidebarProviders: [CloudProvider] { settings.enabledProviders }

    // MARK: - Rows

    /// Re-reads every source's lists and checks them against the disk.
    ///
    /// Called from the places the answer can change rather than from `body` — a `stat` does not
    /// belong in a render.
    ///
    /// **Only where there is a sidebar to fill.** The refresh `stat`s every provider root, and its
    /// triggers fire on every workspace: sitting in Compare with the column switched off would
    /// otherwise pay for a walk of eleven roots on every pane move.
    func refreshFolderSidebarRows() {
        guard folderSidebarIsShowing else { return }
        let providers = folderSidebarProviders
        // One `reachable` call per source. Each `stat`s that root once for both of its lists — under
        // an unreachable network mount every one of those can block, which is why the store answers
        // both lists in a single pass rather than being asked twice.
        let sources: [FolderSidebarModel.Source] = providers.compactMap { provider in
            let root = (provider.path as NSString).expandingTildeInPath
            guard !root.isEmpty else { return nil }
            let remembered = Self.reachableFolders(
                recents: FolderJumpStore.shared.recentPaths(forRoot: root),
                pinned: FolderJumpStore.shared.pinnedPaths(forRoot: root), under: root)
            return FolderSidebarModel.Source(root: FolderJumpStore.key(forRoot: root),
                                             name: provider.displayName,
                                             favorites: remembered.pinned,
                                             isAvailable: remembered.rootIsAvailable)
        }
        folderSidebarRows = FolderSidebarModel.rows(
            sources: sources,
            recents: FolderJumpStore.shared.recentVisitsAcrossRoots(),
            favoriteOrder: FolderJumpStore.shared.favoriteOrder)
        let places = splitFolderSidebarPlaceRows(providers)
        folderSidebarLocationRows = places.locations
        folderSidebarShortcutRows = places.shortcuts
    }

    /// One canonical place, before it is known whether SyncCloud has it as a source.
    struct KnownPlace {
        let name: String
        let symbol: String
        let path: String
        let band: SidebarSourceRow.Band
    }

    /// **Every place row, built place-first** — and that order is the whole fix.
    ///
    /// The first cut built these provider-first: every `CloudProvider` became a row in the cloud
    /// band, and the canonical places were appended afterwards with anything already a source
    /// filtered out. That is backwards, and it produced two bugs the moment a place *became* a
    /// source, which is exactly what clicking one does:
    ///
    /// - **A promoted volume jumped bands and lost its name.** Clicking `Macintosh HD` added `/` as
    ///   a folder source, whose `defaultDisplayName` for a volume root is the path itself — so the
    ///   row moved up among the cloud accounts and started reading `/`.
    /// - **Desktop and Downloads never reached Favorites** for anyone who already had them as
    ///   folder sources: they matched a provider, so the shortcut rows filtered them out and the
    ///   provider rows drew them in Locations.
    ///
    /// Building places first inverts it: a place decides its own name, symbol and band, and a
    /// provider whose root is that folder merely lends it an id and makes it `.configured`. Adding
    /// a place as a source can then change what clicking it does, and nothing else.
    func buildFolderSidebarPlaceRows(_ providers: [CloudProvider]) -> [SidebarSourceRow] {
        let roots = folderSidebarRoots(providers)
        var claimed = Set<String>()

        var places: [KnownPlace] = SidebarSourceModel.favoriteShortcuts.map {
            KnownPlace(name: $0.name, symbol: $0.symbol, path: $0.path, band: .shortcut)
        }
        places += Self.deviceEntries().map {
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
                ? SidebarSourceModel.owningSource(of: place.path, among: roots, resolve: Self.resolved)
                : nil
            return SidebarSourceRow(
                id: owner?.id ?? place.path,
                // **The place's name, not the source's.** A folder source over `/` is named `/`,
                // and over `~` is named for the account's short name; neither is what the row
                // should read once the place has a name of its own.
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
            let root = (provider.path as NSString).expandingTildeInPath
            return SidebarSourceRow(
                id: provider.id, name: provider.displayName, detail: detail,
                // **The provider's own mark**, which is what the tab strip and the pane header
                // already wear — `ProviderLogo` resolves it to a bundled brand asset or an SF
                // Symbol, so a cloud account gets its own silhouette and a folder source keeps
                // `folder.fill`. It replaced a uniform `cloud` for every account, which left five
                // Google/OneDrive rows distinguishable only by the account qualifier beside them.
                symbol: provider.imageName,
                absolutePath: root, band: .cloud, state: .configured,
                isAvailable: Self.isMountedFolder(root))
        }
        return applyFolderSidebarFavoritePlaces(to: rows)
    }

    /// The places the user has in Favorites, decoded.
    var folderSidebarFavoritePlaces: [String] {
        SidebarFavoritePlaces.places(from: browseSidebarFavoritePlacesRaw)
    }

    /// **Every write to the Favorites places goes through here**, so bytes this build could not
    /// read are salvaged rather than overwritten.
    ///
    /// `SidebarFavoritePlaces.places(from:)` answers the standard set for an unreadable value as
    /// well as an absent one, which is the right thing to SHOW. It is the wrong thing to then write
    /// back: the next Add, Remove or drag would encode that set over a key that still held the
    /// user's real list, and the loss would happen on the write rather than on the read that caused
    /// it — the shape six stores were carrying when v4.3 went looking for it.
    ///
    /// One funnel rather than a guard at each of the three call sites, because a fourth verb added
    /// later would be written without it; and the salvage runs before the write rather than at
    /// launch so it cannot fire for a value nothing was about to destroy.
    func writeFolderSidebarFavoritePlaces(_ places: [String]) {
        if SidebarFavoritePlaces.isUnreadable(browseSidebarFavoritePlacesRaw) {
            UserDefaults.standard.set(browseSidebarFavoritePlacesRaw,
                                      forKey: SidebarFavoritePlaces.salvageKey)
            Logger.shared.warning("Sidebar: the stored Favorites places could not be read — kept under “\(SidebarFavoritePlaces.salvageKey)” rather than overwritten")
        }
        browseSidebarFavoritePlacesRaw = SidebarFavoritePlaces.encoded(places)
    }

    /// **Re-bands every place row against the user's Favorites list**, which is the one thing that
    /// decides which of the two sections a place is drawn in.
    ///
    /// Applied after the rows are built rather than while enumerating them, because a row's band is
    /// only half its identity: the builder has already worked out the name, the symbol, whether a
    /// source claims the folder and whether it is mounted, and none of that changes by being
    /// favorited. Enumerating from the favorites list instead would mean re-deriving all of it for
    /// a place that has no `KnownPlace` entry — which is every cloud account.
    ///
    /// A standard folder the user has removed is dropped rather than moved: `.shortcut` is the only
    /// band Desktop has, so there is no Locations row for it to fall back to. That is Finder's
    /// behaviour too, and `SidebarFavoritePlaces.restoring` is the way back.
    ///
    /// **Home and the startup disk are the other case**, and they are in Favorites by default:
    /// each is built as a `.device` row and re-banded UP into Favorites here, so taking either out
    /// moves it back to Locations rather than off the column. Nothing special-cases them — the
    /// asymmetry falls out of which band the builder gave the row.
    func applyFolderSidebarFavoritePlaces(to rows: [SidebarSourceRow]) -> [SidebarSourceRow] {
        let wanted = Set(folderSidebarFavoritePlaces.map(Self.resolved))
        return rows.compactMap { row in
            // The Trash is never in Favorites and never offers to be — see `favoriteVerb`.
            guard row.state != .revealOnly else { return row }
            let isWanted = wanted.contains(Self.resolved(row.absolutePath))
            if row.isFavoriteShortcut { return isWanted ? row : nil }
            return isWanted ? row.inBand(.shortcut) : row
        }
    }

    /// Splits one pass of ``buildFolderSidebarPlaceRows(_:)`` into the two sections.
    ///
    /// **One pass, and a partition rather than a sort.** Two calls would enumerate the mounted
    /// volumes twice per refresh; and `sorted(by:)` on the band is not a stable sort in Swift, so
    /// the cloud accounts — which all share a band — would have been free to shuffle between
    /// renders. Walking the bands in order and appending keeps every row's relative position
    /// exactly as the builder produced it.
    func splitFolderSidebarPlaceRows(_ providers: [CloudProvider])
        -> (locations: [SidebarSourceRow], shortcuts: [SidebarSourceRow]) {
        let all = buildFolderSidebarPlaceRows(providers)
        var locations: [SidebarSourceRow] = []
        for band in [SidebarSourceRow.Band.cloud, .device, .trash] {
            locations += all.filter { $0.band == band }
        }
        // **Favorites are drawn in the order the list holds them**, not in the order the builder
        // happened to produce them. The builder's order is bands — standards, then devices, then
        // clouds — which would silently re-sort the section every time a place was added, and would
        // undo a reorder the moment a disk was mounted.
        let favorites = Dictionary(all.filter(\.isFavoriteShortcut).map { (Self.resolved($0.absolutePath), $0) },
                                   uniquingKeysWith: { first, _ in first })
        return (locations, folderSidebarFavoritePlaces.compactMap { favorites[Self.resolved($0)] })
    }

    func folderSidebarRoots(_ providers: [CloudProvider]) -> [(id: String, name: String, path: String)] {
        providers.map { (id: $0.id, name: $0.displayName,
                         path: ($0.path as NSString).expandingTildeInPath) }
    }

    /// Home, then the mounted volumes — the startup disk first, then everything else by name.
    ///
    /// Both home and the startup disk are in `SidebarFavoritePlaces.standard`, so on an untouched
    /// install `applyFolderSidebarFavoritePlaces` lifts them into Favorites and what is left of
    /// this band in Locations is the external disks. They are still built HERE, which is what lets
    /// them fall back rather than disappear when they are removed from Favorites.
    ///
    /// **Sorted rather than left in mount order**, which is arrival order and therefore differs
    /// between boots; a sidebar whose disks rearranged themselves would look broken. Same reason
    /// the favorites and source orders are partitioned rather than sorted by an optional rank.
    static func deviceEntries() -> [(name: String, symbol: String, path: String)] {
        let home = SidebarSourceModel.homeEntry
        return [home] + SidebarSourceModel.orderedVolumes(mountedVolumes())
            .map { (name: $0.name, symbol: $0.symbol, path: $0.path) }
    }

    /// The volumes macOS says are mounted and browsable.
    ///
    /// `skipHiddenVolumes` keeps out the things Finder also hides — the preboot and recovery
    /// partitions, and the read-only system volume that a modern macOS mounts beside the data one.
    /// Anything that fails to answer its resource values is dropped rather than drawn under a
    /// guessed name.
    static func mountedVolumes() -> [SidebarSourceModel.Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                      .volumeIsInternalKey, .volumeIsBrowsableKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable == true,
                  let name = values.volumeName else { return nil }
            return SidebarSourceModel.Volume(
                name: name, path: url.path,
                isRemovable: (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false),
                // `volumeIsInternal` is optional on some volume types; absent is not internal,
                // which is the safe direction — a wrong glyph on an unusual disk beats promoting
                // an external one to the top of the list.
                isInternal: values.volumeIsInternal ?? false)
        }
    }

    /// A provider's account, for the qualifier slot — the part of its id that distinguishes two
    /// accounts of the same service. Nil when there is nothing to add.
    static func accountQualifier(for provider: CloudProvider) -> String? {
        // A folder source's qualifier is where it lives, since two folder sources can share a leaf
        // name as easily as two Drive accounts can share a service name.
        if provider.isLocalFolder {
            let parent = ((provider.path as NSString).expandingTildeInPath as NSString)
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
        // `agirish.hpe@gmail.com` reads as `agirish.hpe` — the local part is what tells three Drive
        // accounts apart, and the domain is the same on all three.
        return String(id[id.startIndex..<at])
    }

    /// Symlinks resolved on both sides, which is the whole point of the containment check: under
    /// macOS's Desktop & Documents syncing `~/Desktop` is a link into `com~apple~CloudDocs`, and a
    /// plain string comparison says it has nothing to do with iCloud Drive.
    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().path
    }

    /// **Which pane a sidebar click will act on, said out loud** — and only where that is a real
    /// question.
    ///
    /// `nil` outside Compare: with one pane there is nothing to disambiguate, and a caption saying
    /// "opens in the pane" is noise on a 180pt column.
    ///
    /// The side comes from the one rule (`folderSidebarTargetIsLeft` →
    /// `PaneLogic.focusedPaneIsLeft`), so this line, the accent border, the action bar, the
    /// pane-scoped chords and the Compare lens menus cannot come to different answers.
    var folderSidebarTarget: SidebarTarget? {
        guard selectedWorkspace == .compare else { return nil }
        // The SIDE and nothing else. It carried the target pane's provider name too, which read as
        // a scoping claim the column does not make: these rows come from every enabled source.
        return SidebarTarget(targetsRight: !folderSidebarTargetIsLeft)
    }

    /// **Whether this pane is the one the user is working in**, and therefore whether it wears the
    /// accent border.
    ///
    /// Compare only: everywhere else there is one pane, and marking it would answer a question
    /// nobody asked.
    ///
    /// **It used to require the sidebar to be on screen, and that gate is gone deliberately.** The
    /// mark named a sidebar destination then. It names the focused pane now — the pane ⌘F opens on,
    /// the pane Copy and Move act on, and the pane a lens scan reads — none of which care whether
    /// the folder column is showing. Keeping the gate would have hidden the answer in exactly the
    /// state that has no other way to reach it, which is what `focusedPaneSide`'s own comment means
    /// by having no resting indicator.
    func paneIsFocusedPane(isLeft: Bool) -> Bool {
        guard selectedWorkspace == .compare else { return false }
        return isLeft == folderSidebarTargetIsLeft
    }

    /// **The accent this pane's cards border themselves with**, or nil when it is not the
    /// destination — resolved once here so the column's three `paneCardIfNeeded` calls cannot come
    /// to disagree about whether the pane is marked, which is the one way a stack of cards can
    /// contradict itself.
    func paneCardAccent(isLeft: Bool) -> Color? {
        ActivePaneMark.cardAccent(
            isFocused: paneIsFocusedPane(isLeft: isLeft),
            accent: glassHue.accentColor,
            surfaceStyle: surfaceStyle)
    }

    // MARK: - The column

    /// **A card, framed exactly as the Info inspector is** — the same `bottomSectionCard` call with
    /// the same four arguments, so the two panels flanking the pane are one decision rather than
    /// two that happen to agree today.
    ///
    /// It was flush and undecorated until 2026-08-24, separated from the pane by a plain `Divider`.
    /// That reads as a Finder sidebar, which is where the shape came from — but Finder's window is
    /// one opaque surface with a rule down it, and this one is a floating card over glass. A flat
    /// column against a card is not the same idiom drawn smaller; it is the absence of the idiom,
    /// and it left the window with a card on the right of the pane and nothing on its left.
    ///
    /// The card supplies its own half-gutter (`cardInset`), which is why the seam beside it is a
    /// clear strip — see `folderSidebarResizeHandle`.
    /// - Parameter width: the width the column should DRAW at, which is not always
    ///   `browseSidebarWidth`. Browse can afford whatever the user stored; a lens workspace shares
    ///   its row with a rail and a panel that have hard minimums, so it passes a clamped value
    ///   (`PaneLogic.lensSidebarWidth`). Passed in rather than resolved here because the clamp
    ///   needs the row's width, which only the layout has.
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
            notice: folderSidebarNotice.map {
                SidebarNotice(message: $0.message, actionTitle: "Remove")
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
                if let notice = folderSidebarNotice { removeFolderSidebarPromotion(notice) }
            },
            onShowEnclosingFolder: { row in showFolderSidebarRowEnclosingFolder(row) },
            onToggleSourceFavorite: { source in toggleFolderSidebarPlaceFavorite(source) },
            onRestoreStandardFavorites: { restoreStandardFolderSidebarFavorites() },
            canRestoreStandardFavorites: SidebarFavoritePlaces.isMissingStandard(folderSidebarFavoritePlaces),
            onMoveFavorite: { from, to in moveFolderSidebarFavorite(from: from, to: to) },
            onMoveSource: { from, to in moveFolderSidebarSource(from: from, to: to) },
            onFavoriteRecent: { row, to in favoriteRecentByDrag(row, to: to) })
        .bottomSectionCard(surfaceStyle, level: glassLevel, hue: glassHue, tint: surfaceTint)
    }

    /// The stored width, **clamped on read**.
    ///
    /// Clamped here rather than only on write, because the stored value is a plain `@AppStorage`
    /// double that a later build, a different range, or a hand-edited plist can put outside the
    /// bounds — and an unclamped read is how a column ends up 4pt wide with no way to grab its
    /// divider. Writing is clamped too; this is the half that cannot be bypassed.
    var browseSidebarWidth: CGFloat {
        min(max(CGFloat(browseSidebarWidthRaw), FolderSidebarView.minWidth), FolderSidebarView.maxWidth)
    }

    /// Which sections are folded, decoded from the one persisted string.
    ///
    /// Stored as comma-joined raw values rather than as a `Set` in its own key per section: three
    /// keys for one answer is three things to keep in step, and a section added later would need a
    /// fourth. An unrecognised value is ignored rather than treated as a section, so a string
    /// written by a later build cannot fold something this one cannot draw.
    var folderSidebarCollapsedSections: Set<FolderSidebarView.Section> {
        Set(browseSidebarCollapsed.split(separator: ",")
            .compactMap { FolderSidebarView.Section(rawValue: String($0)) })
    }

    func toggleFolderSidebarSection(_ section: FolderSidebarView.Section) {
        var folded = folderSidebarCollapsedSections
        if folded.contains(section) { folded.remove(section) } else { folded.insert(section) }
        // Sorted so the stored string is the same for the same set — an unordered join would
        // rewrite the key on every toggle with no change of meaning.
        browseSidebarCollapsed = folded.map(\.rawValue).sorted().joined(separator: ",")
    }

    // MARK: - What a click does

    /// A plain click re-scopes the pane; ⌘ opens the folder in a new tab.
    ///
    /// **`focusOn` and not a column drill**, which is the same choice the ⌘K palette makes
    /// (`revealInSourcePane`): a jump from a remembered list is a change of *where the pane is*,
    /// not a step through the stack the breadcrumb is walking. Sending it through the stack would
    /// leave the breadcrumb describing a route the user never took.
    /// - Parameter side: an explicit pane, from the row's context menu. `nil` means "wherever the
    ///   sidebar is pointed", which is the click path. Passed rather than read so the context menu
    ///   can open one folder on the other side WITHOUT moving the target — picking a side for one
    ///   folder is not a statement about the next one.
    func openFolderSidebarRow(_ row: FolderSidebarRow, inNewTab: Bool, side: Bool? = nil) {
        guard FolderSidebarModel.canOpen(row) else { return }
        let isLeft = side ?? folderSidebarTargetIsLeft
        let absolute = (row.root as NSString).appendingPathComponent(row.relativePath)
        if inNewTab {
            openInNewTab(absolutePath: absolute, isLeft: isLeft)
            return
        }
        // **A row from another source switches the source first.** Both sections span every account
        // now, so the pane's current provider and the row's root are routinely different — and
        // `focusOn` takes a path relative to whatever root the pane is already on, so without this
        // the pane would resolve `Health` against the wrong account and land somewhere real and
        // wrong, which is worse than landing nowhere.
        //
        // Asked of the pane the row is OPENING ON — `isLeft`, which the context menu can point at
        // the non-target pane — not of `folderSidebarRoot`, which always describes the target.
        // Asking the target answers for the wrong pane exactly when `side` is doing its job.
        let paneRoot = (settings.path(for: isLeft ? leftProviderId : rightProviderId) as NSString)
            .expandingTildeInPath
        if FolderJumpStore.key(forRoot: paneRoot) != row.root {
            guard let provider = folderSidebarProviders.first(where: {
                FolderJumpStore.key(forRoot: ($0.path as NSString).expandingTildeInPath) == row.root
            }) else {
                Logger.shared.warning("Sidebar: no enabled source owns \(row.root) — cannot open \(row.relativePath)")
                return
            }
            setFolderSidebarProvider(provider.id, isLeft: isLeft)
        }
        syncManager.focusOn(relativePath: row.relativePath, isLeft: isLeft)
    }

    /// **Opens the folder a row LIVES IN, on the pane the sidebar is pointed at.**
    ///
    /// The row itself answers "take me there"; this answers "show me where that is", which is a
    /// different question and the one you ask when a favorite's name has stopped being enough —
    /// two `Legal` folders in one account, or a recent you no longer recognise. Finder's own verb,
    /// and the same wording, because it is the same idea.
    ///
    /// Routed through `openFolderSidebarRow` rather than reimplementing the jump: a row from
    /// another account still has to switch the source first, and that rule is subtle enough
    /// (`focusOn` resolves against whatever root the pane is on) that a second copy of it would be
    /// a second place for it to go wrong.
    func showFolderSidebarRowEnclosingFolder(_ row: FolderSidebarRow, side: Bool? = nil) {
        guard let parent = FolderSidebarModel.enclosingFolder(of: row) else { return }
        Logger.shared.info("Sidebar: showing “\(row.name)” in its enclosing folder (\(parent.relativePath.isEmpty ? "the source root" : parent.relativePath))")
        openFolderSidebarRow(parent, inNewTab: false, side: side)
    }

    /// Adds an unfavourited row, removes a favourited one — the same toggle the pane header's jump
    /// menu and the breadcrumb offer, through the same store call, so the three cannot disagree.
    ///
    /// **Keyed by the row's own root**, not the pane's: a favorite in another account is removable
    /// from here without visiting it first, which is the point of the section spanning sources.
    func toggleFolderSidebarFavorite(_ row: FolderSidebarRow) {
        let wasFavorite = row.group == .pinned
        FolderJumpStore.shared.togglePin(root: row.root, relativePath: row.relativePath, name: row.name)
        Logger.shared.info("Sidebar: \(wasFavorite ? "removed" : "added") favorite “\(row.name)” (\(row.relativePath.isEmpty ? "root" : row.relativePath))")
        refreshFolderSidebarRows()
    }

    /// **Puts a place in Favorites, or takes it out.** The place-row counterpart to
    /// `toggleFolderSidebarFavorite`, which answers the same question for a remembered folder.
    ///
    /// Two lists, deliberately, rather than one: a remembered folder is a path *inside* a source
    /// and is stored against that source's root, while a place is a root in its own right and may
    /// not belong to any source at all — an unplugged disk, or `~/Downloads` on a machine that has
    /// never added it. Forcing a place into `FolderJumpStore` would mean inventing a root for it.
    func toggleFolderSidebarPlaceFavorite(_ source: SidebarSourceRow) {
        guard SidebarSourceModel.favoriteVerb(for: source) != nil else { return }
        let places = folderSidebarFavoritePlaces
        // Toggled on the STORED spelling where there is one, so a row whose path resolves through a
        // symlink does not add a second entry naming the same folder.
        let stored = places.first { Self.resolved($0) == Self.resolved(source.absolutePath) }
        let next = SidebarFavoritePlaces.toggling(stored ?? source.absolutePath, in: places)
        writeFolderSidebarFavoritePlaces(next)
        Logger.shared.info("Sidebar: \(stored == nil ? "added" : "removed") favorite place “\(source.name)” (\(source.absolutePath))")
        refreshFolderSidebarRows()
    }

    /// **Adds a folder in a PANE to Favorites, or takes it out.**
    ///
    /// The third route to the same list, and the one that was missing. The sidebar's own rows can
    /// only manage folders that are already listed — favorites you have, and recents you have been
    /// to — and the pane header's jump menu acts on the folder the pane is SHOWING. Neither is
    /// where you are standing when you decide a folder is worth keeping, which is looking at it in
    /// a pane.
    ///
    /// Keyed to the pane the row belongs to rather than to the focused pane: a context menu does
    /// not move focus, so a right-click in the other pane would otherwise be filed against the
    /// wrong account — and usually still succeed, because the same relative path exists on both
    /// sides often enough for that to be the ordinary case rather than the corner one.
    func toggleFavorite(forPaneFolder node: FileNode, isLeft: Bool) {
        // **The same rule the MENU asked**, not a second copy of it. `isFolderFavorite` decides
        // whether the item reads "Add" or "Remove" and this decides what the click does; deriving
        // the root and the relative path twice is how those two come to disagree, and the disagreement
        // is invisible — the label would offer to remove a folder the toggle then adds.
        guard let place = PaneActionDelegate.favoritePlace(
            nodePath: node.id, isDirectory: node.isDirectory,
            paneRoot: settings.path(for: isLeft ? leftProviderId : rightProviderId)) else {
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
            // **A new tab lands at the source's root**, not at whatever folder it was last showing.
            // A source row points at one place whether you click it, ⌘-click it or drop on it;
            // resolving to a last-visited folder would make one row mean two destinations depending
            // on the gesture, and the destination is one the row does not show you beforehand.
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
            // The Trash, and only the Trash. It is a place worth having a row for and not a place
            // worth scanning, so the row hands it to the one app whose job it is.
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: source.absolutePath)
        }
    }

    /// A local shortcut whose folder lives inside a source the app already has: switch to that
    /// source and navigate to the folder, adding nothing.
    ///
    /// This is the case macOS's Desktop & Documents syncing creates, and the reason
    /// `SidebarSourceModel.owningSource` resolves symlinks: promoting `~/Desktop` would put a
    /// second source over a tree iCloud already scans — double work, and Storage counting the same
    /// bytes twice.
    /// - Parameter isLeft: the pane resolved by the caller — the context menu's explicit side, or
    ///   the target. **Passed rather than re-read**, which is the point: this branch read
    ///   `folderSidebarTargetIsLeft` itself, so "Open in Right Pane" on a shortcut that lives
    ///   inside another source would silently have opened it on the target side instead. One of
    ///   three `.state` branches behaving differently from the other two is precisely the kind of
    ///   thing nobody would think to try.
    func openFolderSidebarShortcutInsideItsOwner(_ source: SidebarSourceRow, ownerId: String,
                                                 owner: String, inNewTab: Bool, isLeft: Bool) {
        let resolved = Self.resolved(source.absolutePath)
        // By ID, never by display name: `.inside` carries the id `owningSource` resolved precisely
        // so that two same-named sources — the collision this section's qualifiers exist for —
        // cannot make this pick the wrong one and count-strip against the wrong root.
        guard let provider = folderSidebarProviders.first(where: { $0.id == ownerId }) else {
            Logger.shared.warning("Sidebar: \(source.name) claims to be in \(owner), which is not an enabled source")
            return
        }
        let root = Self.resolved((provider.path as NSString).expandingTildeInPath)
        // The path relative to the owning source's root — `focusOn` takes a relative path, and the
        // shortcut only knows its absolute one. Containment re-checked rather than assumed: the
        // row was built earlier, and a source path edited since would make a blind count-strip
        // produce a garbage relative path against the new root.
        guard SidebarSourceModel.contains(resolved, under: root) || SidebarSourceModel.isSameFolder(resolved, root) else {
            Logger.shared.warning("Sidebar: \(source.name) is no longer inside \(owner) — its source has moved")
            return
        }
        let relative = resolved.count > root.count
            ? String(resolved.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : ""
        if inNewTab {
            openInNewTab(absolutePath: resolved, isLeft: isLeft)
            return
        }
        // Compared against the pane being opened on, matching the `setFolderSidebarProvider` call
        // beside it — comparing the target pane's provider here while setting the `isLeft` pane's
        // was the missed half of the fix this function's own doc describes.
        if provider.id != (isLeft ? leftProviderId : rightProviderId) {
            setFolderSidebarProvider(provider.id, isLeft: isLeft)
        }
        if !relative.isEmpty { syncManager.focusOn(relativePath: relative, isLeft: isLeft) }
    }

    /// A local folder SyncCloud has not been given: add it as a folder source, open it, and say so.
    ///
    /// **Never silent, and taken back inline rather than with ⌘Z.** The undo stack is the window's
    /// `UndoManager` and it holds *file* operations — `FileSyncManager` registers sync runs on it
    /// and verifies the top is still that run before reversing. Putting a configuration change on
    /// the same stack means someone who moved forty files, clicked a shortcut, then pressed ⌘Z
    /// gets a source removed instead of their move back: correct undo semantics, wrong answer.
    func promoteFolderSidebarShortcut(_ source: SidebarSourceRow, isLeft: Bool, inNewTab: Bool) {
        // `addFolderSource` answers an existing source by *returning its id* rather than minting a
        // duplicate — including when the path is a discovered provider's own root, because that
        // account "knows things about that folder that a folder source would throw away". So this
        // is safe even if the containment check above missed a case: the worst outcome is a switch
        // to the source that was already there.
        // Whether the call MINTED a source, decided by membership taken BEFORE the call — taken
        // after, it cannot tell "just added" from "already existed". The row can name a folder
        // that is already a source, merely a *disabled* one the enabled-only builder cannot see;
        // on that path the after-the-fact test answered true, put "Added" on screen, and offered
        // a Remove that would have deleted a source the user configured long ago.
        let knownBefore = Set(settings.folderSources.map(\.id) + settings.availableProviders.map(\.id))
        let id = settings.addFolderSource(path: source.absolutePath)
        let wasAdded = !knownBefore.contains(id)
        // A pre-existing source reached from a "not added yet" row can only be a disabled one —
        // enabled sources draw as `.configured`. The click means "use this folder", so switch it
        // back on; pointing the pane at a disabled provider would land in a state the pane
        // header's own menu cannot reach.
        if !wasAdded && !settings.isEnabled(id) {
            settings.setEnabled(true, for: id)
            Logger.shared.info("Sidebar: re-enabled \(source.name) (\(id)) — promoted while disabled")
        }
        // **No rename here, deliberately.** A promoted volume root used to be called `/`, and this
        // wrote the sidebar's own word over it — until `FolderSource.defaultDisplayName` learned to
        // ask the volume for its name, which fixes it at the source for every way a source can be
        // added, not just this one. Writing an override on top would now be worse than redundant:
        // it marks the source as user-renamed in Settings, and for the home folder it would replace
        // the deliberate "Home folder" with the account's short name — the exact reading-as-a-person
        // problem that special case exists to avoid.
        if inNewTab {
            openInNewTab(absolutePath: source.absolutePath, isLeft: isLeft)
        } else {
            setFolderSidebarProvider(id, isLeft: isLeft)
        }
        if wasAdded {
            folderSidebarNotice = FolderSidebarNotice(
                message: "Added \(source.name) as a source", sourceId: id)
        }
        refreshFolderSidebarRows()
    }

    /// Undoes a promotion the user did not mean. Removes only what this added, and only while the
    /// notice offering it is still on screen.
    func removeFolderSidebarPromotion(_ notice: FolderSidebarNotice) {
        settings.removeFolderSource(id: notice.sourceId)
        folderSidebarNotice = nil
        refreshFolderSidebarRows()
    }

    // MARK: - Reordering

    /// Moves a favorite within the section, and records the whole resulting sequence.
    ///
    /// **The order is stored separately from membership** (`FolderJumpStore.favoriteOrder`), because
    /// Favorites spans every source: the section is a concatenation of per-root lists, and a drag
    /// that moves a Dropbox favorite above an iCloud one has no representation in per-root arrays.
    /// The section is one flat list with badges and no visible boundary inside it, so an order that
    /// stopped at a source would be a constraint the user cannot see — the row would snap back for
    /// no reason.
    /// **Favorites holds two lists, and the drag index spans both of them.**
    ///
    /// The section draws the place rows first and the remembered folders after, in one index space
    /// — so index 0 is a place and index `places` is the first folder. This member used to hand
    /// that combined index straight to the folder-favorites list, which is the same defect
    /// `moveFolderSidebarSource` documents one screen down: with the standard places present (three
    /// of them at the time), dragging the FIRST remembered folder asked to move item 3 of a list
    /// that had two, and
    /// `SidebarReorder.moved` returned it unchanged, so remembered folders could not be reordered
    /// at all; dragging a place row reordered a remembered folder instead. Neither wrote anything
    /// visible, which is why it survived.
    ///
    /// The two lists live in different stores and mean different things, so a row moves within its
    /// own half — `clampedDrop` in the view is what stops the insertion line promising otherwise.
    func moveFolderSidebarFavorite(from: Int, to: Int) {
        let move = SidebarReorder.favoritesMove(from: from, to: to,
                                                places: folderSidebarShortcutRows.count)
        if move.isPlace {
            moveFolderSidebarFavoritePlace(from: move.from, to: move.to)
        } else {
            moveFolderSidebarFavoriteFolder(from: move.from, to: move.to)
        }
    }

    /// Reorders the Favorites place rows — Desktop, and anything else put there.
    func moveFolderSidebarFavoritePlace(from: Int, to: Int) {
        // Indexed against the DRAWN rows, then mapped back to stored paths: the stored list can
        // name a place that is not on screen (an unplugged disk), and indexing the stored list with
        // a drawn index is exactly the mismatch this file has been bitten by twice.
        let drawn = folderSidebarShortcutRows.map { Self.resolved($0.absolutePath) }
        guard drawn.indices.contains(from) else { return }
        let moved = SidebarReorder.moved(drawn, from: from, to: to)
        guard moved != drawn else { return }
        let stored = folderSidebarFavoritePlaces
        let byResolved = Dictionary(stored.map { (Self.resolved($0), $0) },
                                    uniquingKeysWith: { first, _ in first })
        // **A place that is not on screen keeps its slot.** The stored list outlives the drawn one
        // — an unplugged volume keeps its entry and draws no row — and writing the reordered
        // visible rows followed by the leftovers moved every one of those to the end, so dragging
        // Desktop up sent an unplugged disk to the bottom of a list nothing on screen mentioned.
        let next = SidebarReorder.resplicing(stored.map(Self.resolved), visibleInNewOrder: moved)
        writeFolderSidebarFavoritePlaces(next.compactMap { byResolved[$0] })
        Logger.shared.info("Sidebar: moved favorite place “\(folderSidebarShortcutRows[from].name)” to position \(min(to, moved.count))")
        refreshFolderSidebarRows()
    }

    /// **Indexed against the DRAWN favorites, then written back into the stored ones**, which are
    /// not the same list: `reachable` drops a favorite whose folder has been deleted and the
    /// builder drops one whose whole source is gone, so the column can be showing four of six.
    /// Indexing the stored list with a drawn index moves a row the user cannot see — the same
    /// mismatch `moveFolderSidebarSource` and `moveFolderSidebarFavoritePlace` each document, and
    /// the third place it had to be fixed.
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
        // **Reorders are logged, and that is not decoration.** A drag rewrites a persisted
        // preference with no visible confirmation beyond the rows settling, so when one of these
        // moved the WRONG entry there was nothing anywhere to say what it had done — which is
        // exactly how the Locations drag reordered the wrong source for as long as it did. Naming
        // what moved makes the next such bug one log line away instead of a bisect.
        // Named off the DRAWN list, which is the one `from` and `to` are indices into. Reading the
        // stored list with them printed whichever favorite happened to sit at that position in a
        // list the user was not looking at.
        Logger.shared.info("Sidebar: moved favorite “\(drawn[from].name)” to position \(min(to, keys.count))")
        refreshFolderSidebarRows()
    }

    /// Moves a source, and records the order **in Settings** rather than in the sidebar.
    ///
    /// One order, read by everything: a sidebar and a pane-header dropdown showing the same eleven
    /// accounts in two different sequences is the drift that makes a user distrust both. The stored
    /// list is provider ids, so a source that disappears leaves no hole and a newly connected one
    /// appends rather than jumping to the front.
    ///
    /// **Indexed against `folderSidebarLocationRows` — the exact list the drag measured.**
    ///
    /// It indexed `folderSidebarProviders` until this was reviewed, and the two are not the same
    /// list: a provider whose folder is a canonical place is CLAIMED by that place and drawn in
    /// Favorites (`buildFolderSidebarPlaceRows`), so it is absent from Locations. With `~/Desktop`
    /// and `~/Downloads` as folder sources — an ordinary setup, and the one on this machine — the
    /// cloud band is the provider list minus two, and every index past the first claimed one
    /// addressed the wrong source. Dragging one cloud row reordered a different one, and dragging
    /// a device row indexed past the end and silently did nothing.
    ///
    /// **Rows that are not sources contribute nothing**, and sources not drawn here keep their
    /// existing positions — see `SidebarReorder.reordering`. Writing the visible ones out followed
    /// by the rest would shove every untouched source to the end of the dropdown as a side effect
    /// of a drag in a different section.
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

    /// **A recent dragged into Favorites**, landing where it was dropped.
    ///
    /// Two writes, in this order: the folder becomes a favorite, then the section's order is
    /// rewritten with it at the drop index. Doing it the other way round would set an order naming a
    /// key that is not a favorite yet, which `orderedFavorites` would ignore — so the row would be
    /// added and then appear at the bottom, one place from where it was aimed.
    func favoriteRecentByDrag(_ row: FolderSidebarRow, to: Int) {
        // **`to` arrives in the section's combined index space** — place rows first, remembered
        // folders after — and this reorders the remembered folders alone, so the places have to
        // come off it. `clampedDrop` has already stopped it landing in the first half.
        let target = max(0, to - folderSidebarShortcutRows.count)
        // The drop index is a position among the folders ON SCREEN, so the sequence it lands in is
        // built from those and then respliced into the stored list — which holds every favorite,
        // including ones no source can currently reach. Same rule as `moveFolderSidebarFavoriteFolder`.
        let added = FolderJumpStore.favoriteKey(root: row.root, relativePath: row.relativePath)
        var visible = FolderSidebarModel.rows(folderSidebarRows, in: .pinned)
            .map { FolderJumpStore.favoriteKey(root: $0.root, relativePath: $0.relativePath) }
        visible.insert(added, at: min(max(target, 0), visible.count))

        FolderJumpStore.shared.togglePin(root: row.root, relativePath: row.relativePath, name: row.name)
        let favorites = FolderJumpStore.shared.favoriteVisitsAcrossRoots()
        let allKeys = favorites.map { FolderJumpStore.favoriteKey(root: $0.root, relativePath: $0.relativePath) }
        // `togglePin` toggles: a recent that was somehow already a favorite has just been REMOVED,
        // and there is no row left to place. Refresh and stop rather than writing an order naming
        // a key that is not a favorite, which `orderedFavorites` would silently drop.
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

/// A promotion that can still be taken back — the inline alternative to ⌘Z.
struct FolderSidebarNotice: Equatable, Identifiable {
    let message: String
    /// The source `addFolderSource` created, so Remove takes back exactly what was added.
    let sourceId: String
    var id: String { sourceId }
}
