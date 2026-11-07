@testable import SyncCloud
import Dashboard
import Sync
import Testing
import Foundation

/// Where a place row goes, and what it is called, once it is also a source. Rows are built
/// place-first, so a place that becomes a folder source keeps its name and band: `Macintosh HD`
/// added as `/` stays `Macintosh HD` among the devices, and Desktop as a source stays in Favorites.
///
/// Asserted against `ContentView`'s own source, as `FolderSidebarWiringTests` is: `ContentView` is
/// a `View` with `@State` and can't be instantiated here, and a copy of the logic could agree with
/// itself while disagreeing with the app.
@Suite struct SidebarPlaceRowTests {

    static func source() throws -> String { sourceCodeOnly(try macAppFile("ContentView+FolderSidebar.swift")) }

    /// Places are built before providers: the claimed-by-a-provider check runs against a place,
    /// which needs the places to exist first.
    @Test func aPlaceKeepsItsOwnNameWhenASourceClaimsIt() throws {
        let code = try Self.source()
        #expect(code.contains("name: place.name"),
                "the row takes its name from the provider again — a folder source over \"/\" is named \"/\", and over \"~\" is named for the account's short name")
        #expect(code.contains("band: place.band"),
                "the row takes its band from somewhere other than the place, so promoting a volume moves it out of the device band")
    }

    /// A place that a source claims becomes `.configured` (reachable) rather than being dropped from
    /// the place list and redrawn as a provider.
    @Test func aClaimedPlaceBecomesConfiguredRatherThanDisappearing() throws {
        let code = try Self.source()
        #expect(code.contains("owner != nil ? .configured"),
                "a place claimed by a source no longer resolves to .configured")
        #expect(code.contains("claimed.insert(owner.id)"),
                "nothing records which providers a place claimed, so the same folder draws twice")
    }

    /// Only the providers no place claimed become cloud rows, or Desktop as a folder source would
    /// be drawn in both Favorites and Locations.
    @Test func onlyUnclaimedProvidersBecomeCloudRows() throws {
        #expect(try Self.source().contains("providers.filter { !claimed.contains($0.id) }"),
                "every provider becomes a cloud row again, so a place that is also a source draws twice")
    }

    /// The Trash is never a source, even where somebody has added `~/.Trash` as a folder source by
    /// hand.
    @Test func theTrashIsAlwaysRevealOnly() throws {
        let code = try Self.source()
        #expect(code.contains("if place.band == .trash"),
                "the Trash no longer short-circuits, so a source over it would make it browsable")
        #expect(code.contains("state: .revealOnly"))
    }

    /// Promotion does not rename the source. `FolderSource.defaultDisplayName` asks the volume for
    /// its name, for every way a source is added. An override would mark the source user-renamed
    /// in Settings, and replace the home folder's "Home folder" with the account's short name.
    /// `FolderSourceVolumeNameTests` owns the rule.
    @Test func promotingAPlaceDoesNotWriteANameOverride() throws {
        #expect(!(try Self.source().contains("setCustomName")),
                "promotion writes a name override again — the name belongs to FolderSource.defaultDisplayName, which every other entry point goes through")
    }

    /// Bands are partitioned, not sorted: `sorted(by:)` is not stable in Swift, and every cloud
    /// account shares a band, so a sort would let them shuffle between renders.
    @Test func theBandsArePartitionedRatherThanSorted() throws {
        let code = try Self.source()
        #expect(!code.contains("sorted { $0.band < $1.band }"),
                "the bands are ordered with an unstable sort, so same-band rows can shuffle between renders")
        #expect(code.contains("for band in [SidebarSourceRow.Band.cloud, .device, .trash]"),
                "the band order is no longer an explicit walk, so it cannot be read off the code")
    }

    /// The Locations drag is indexed against the rows it dragged, not the provider list. A provider
    /// whose folder is a canonical place is claimed by it and drawn in Favorites, so it's absent
    /// from Locations; indexing the providers would reorder a different source than the one
    /// dragged, or index past the end. Invisible without a claimed provider, which
    /// `SidebarReorder`'s own tests don't have.
    @Test func theSourceDragIndexesTheRowsItDragged() throws {
        let code = try Self.source()
        #expect(code.contains("let shown = folderSidebarLocationRows"),
                "moveFolderSidebarSource indexes something other than the rows the drag measured")
        #expect(!code.contains("let shown = folderSidebarProviders"),
                "moveFolderSidebarSource indexes the provider list again — a claimed provider is not drawn in Locations, so the indices do not line up")
    }

    /// Sources not drawn in Locations keep their positions (see `SidebarReorder.reordering`).
    /// Writing the visible ones then the rest would move untouched sources to the end of the pane
    /// header's dropdown.
    @Test func theSourceDragLeavesUndrawnSourcesWhereTheyAre() throws {
        let code = try Self.source()
        #expect(code.contains("SidebarReorder.reordering(all, subsetInNewOrder: subset)"),
                "the new order is not built as a subset reorder")
        #expect(!code.contains("moved.map(\\.id) + hidden"),
                "the order is written as the visible list plus the rest, which relocates every source nobody dragged")
    }

    /// One pass per refresh; two would build every place row twice for one column. The volume walk
    /// is handed down (see the next test, and `EjectWiringTests.theRefreshWalksTheVolumesOnce`).
    ///
    /// Matched on the call's opening rather than a whole argument list, so adding an argument
    /// doesn't silently take the count to zero.
    @Test func theRowsAreBuiltOncePerRefresh() throws {
        let code = try Self.source()
        let calls = code.components(separatedBy: "buildFolderSidebarPlaceRows(providers").count - 1
        #expect(calls == 1, "buildFolderSidebarPlaceRows runs \(calls) times per refresh")
    }

    /// The walk is handed down, not repeated. `deviceEntries` making its own would add a second
    /// `mountedVolumeURLs` and a resource read per volume to every refresh, and under an
    /// unreachable network mount each read can block.
    @Test func thePlaceRowsTakeTheVolumeWalkRatherThanMakingOne() throws {
        let code = try Self.source()
        #expect(code.contains("Self.deviceEntries(volumes)"),
                "the place-row build enumerates the mounted volumes itself again")
        #expect(!code.contains("Self.deviceEntries()"),
                "a caller still asks deviceEntries to make its own walk")
    }
}

/// The standard folders belong to Favorites, whether or not they are folder sources on this
/// machine.
@Suite struct StandardFolderPlacementTests {

    @Test func theStandardFoldersCarryTheShortcutBand() {
        for shortcut in SidebarSourceModel.favoriteShortcuts {
            let row = SidebarSourceRow(id: shortcut.path, name: shortcut.name, detail: nil,
                                       symbol: shortcut.symbol, absolutePath: shortcut.path,
                                       band: .shortcut, state: .configured, isAvailable: true)
            #expect(row.isFavoriteShortcut,
                    "\(shortcut.name) would be drawn in Locations rather than Favorites")
        }
    }

    /// A row's section is decided by its band alone, not its state, so being a source, inside one,
    /// or neither all land in the same place.
    @Test func theSectionDoesNotDependOnWhetherThePlaceIsASource() {
        let states: [SidebarSourceRow.State] = [.configured, .unknown, .inside(sourceId: "icloud", sourceName: "iCloud")]
        for state in states {
            let row = SidebarSourceRow(id: "x", name: "Desktop", detail: nil, symbol: "doc",
                                       absolutePath: "/d", band: .shortcut, state: state,
                                       isAvailable: true)
            #expect(row.isFavoriteShortcut, "Desktop leaves Favorites when its state is \(state)")
        }
    }
}

/// A place that a source links in from outside reads "in" that source, and the source keeps its own
/// row. With iCloud Desktop & Documents on, `~/Documents` is inside iCloud through the container's
/// `Documents` link, which points out to the real folder, so no arithmetic on the paths says so.
///
/// Built against the real `~/Documents` and a container that exists nowhere, with the link table
/// injected, so the test doesn't depend on whether this Mac syncs its Documents folder.
@Suite struct LinkedPlaceRowTests {

    static let container = "/nowhere/com~apple~CloudDocs"
    static let documents = NSHomeDirectory() + "/Documents"
    static let links: PathBoundary.LinkedFolders = [container: ["Documents": documents]]
    static let iCloud = CloudProvider(id: "iCloud", displayName: "iCloud", imageName: "icloud",
                                      rootPath: container, openAt: "Documents", type: .iCloud)

    static func split(links: PathBoundary.LinkedFolders) -> (locations: [SidebarSourceRow], shortcuts: [SidebarSourceRow]) {
        ContentView.splitFolderSidebarPlaceRows([iCloud], volumes: [], favoritePlaces: [documents], links: links)
    }

    @Test func theDocumentsFavoriteIsInsideICloudThroughTheLink() throws {
        let rows = Self.split(links: Self.links)
        let documents = try #require(rows.shortcuts.first { $0.name == "Documents" })
        #expect(documents.state == .inside(sourceId: "iCloud", sourceName: "iCloud"))
        #expect(documents.detail == "in iCloud")
        #expect(documents.id == Self.documents, "the place became the source's row rather than a place inside it")
    }

    /// Locations carries iCloud, with its own mark, because the Documents favorite doesn't claim
    /// the provider outright.
    @Test func iCloudKeepsItsLocationsRow() throws {
        let rows = Self.split(links: Self.links)
        let icloud = try #require(rows.locations.first { $0.id == "iCloud" })
        #expect(icloud.band == .cloud)
        #expect(icloud.symbol == "icloud")
        #expect(icloud.state == .configured)
        #expect(icloud.absolutePath == Self.container)
    }

    /// Without the link, `~/Documents` is nothing to iCloud: the row is the one that promotes.
    @Test func withoutTheLinkTheFavoriteIsUnowned() throws {
        let rows = Self.split(links: [:])
        let documents = try #require(rows.shortcuts.first { $0.name == "Documents" })
        #expect(documents.state == .unknown)
        #expect(rows.locations.contains { $0.id == "iCloud" })
    }

    /// The claims list is the roots plus each linked folder under the same id and name, and a
    /// provider with no links contributes exactly its root.
    @Test func theClaimsAreTheRootsPlusTheLinkedFolders() {
        let dropbox = CloudProvider(id: "Dropbox", displayName: "Dropbox", imageName: "dropbox",
                                    rootPath: "/d", type: .dropBox)
        let claims = ContentView.folderSidebarClaims([Self.iCloud, dropbox], links: Self.links)
        #expect(claims.map(\.path) == [Self.container, Self.documents, "/d"])
        #expect(claims.map(\.id) == ["iCloud", "iCloud", "Dropbox"])
    }
}

/// The tail of Locations, in the order it is drawn: the startup disk, then any card, then the
/// Trash.
///
/// Asserted end to end because three mechanisms must agree: `SidebarFavoritePlaces.standard`
/// leaving the disk out (so it stays a `.device` row), `SidebarSourceModel.orderedVolumes` putting
/// the internal disk ahead of the removable one, and `splitFolderSidebarPlaceRows`' band walk
/// putting `.trash` last. A test of any one passes while the column is wrong.
///
/// The Trash row depends on `~/.Trash` existing, which `isMountedFolder` checks; the assertions
/// name it, so a machine without one fails loudly instead of measuring a shorter list.
@Suite struct LocationsDeviceBandOrderTests {

    static let card = SidebarSourceModel.Volume(name: "Untitled", path: "/Volumes/Untitled",
                                                isRemovable: true, isInternal: false)
    static let disk = SidebarSourceModel.Volume(name: "Macintosh HD", path: "/",
                                                isRemovable: false, isInternal: true)

    static func locations(_ volumes: [SidebarSourceModel.Volume]) -> [SidebarSourceRow] {
        ContentView.splitFolderSidebarPlaceRows(
            [], volumes: volumes, favoritePlaces: SidebarFavoritePlaces.standard, links: [:]).locations
    }

    /// With nothing plugged in: the disk, then the Trash. Home is a default favorite, so the device
    /// band starts at the volumes and the disk is the first row under the rule.
    @Test func theStartupDiskSitsAboveTheTrash() throws {
        let rows = Self.locations([Self.disk])
        #expect(rows.map(\.name) == ["Macintosh HD", "Trash"],
                "Locations reads \(rows.map(\.name)) — the disk is not between the rule and the Trash")
        #expect(rows.first?.band == .device)
        #expect(rows.last?.state == .revealOnly)
    }

    /// A card plugged in lands below the disk and above the Trash, put there by `orderedVolumes`
    /// rather than anything in the sidebar.
    @Test func aCardLandsBetweenTheDiskAndTheTrash() throws {
        let rows = Self.locations([Self.card, Self.disk])
        #expect(rows.map(\.name) == ["Macintosh HD", "Untitled", "Trash"],
                "Locations reads \(rows.map(\.name))")
        #expect(rows.first { $0.name == "Untitled" }?.symbol == "sdcard")
    }

    /// The Trash is last whatever else is mounted, including a volume whose name sorts after it: a
    /// `Zip` disk exposes an ordering that sorted the band by name instead of walking the bands.
    @Test func theTrashStaysLastWhateverIsMounted() throws {
        let extras = [SidebarSourceModel.Volume(name: "Zip", path: "/Volumes/Zip",
                                               isRemovable: true, isInternal: false),
                      SidebarSourceModel.Volume(name: "Archive", path: "/Volumes/Archive",
                                                isRemovable: false, isInternal: false)]
        let rows = Self.locations([Self.card] + extras + [Self.disk])
        #expect(rows.map(\.name) == ["Macintosh HD", "Archive", "Untitled", "Zip", "Trash"],
                "Locations reads \(rows.map(\.name))")
    }

    /// And the disk is only there because the default list leaves it out: favoriting it takes it
    /// back out of Locations, so this suite passes for the reason it claims.
    @Test func favoritingTheDiskTakesItBackOutOfLocations() throws {
        let split = ContentView.splitFolderSidebarPlaceRows(
            [], volumes: [Self.disk],
            favoritePlaces: SidebarFavoritePlaces.standard + [SidebarSourceModel.startupDiskPath],
            links: [:])
        #expect(split.locations.map(\.name) == ["Trash"])
        #expect(split.shortcuts.last?.name == "Macintosh HD")
    }
}

/// The Favorites defaults key is spelled twice, and this binds the two.
/// `SidebarFavoritePlaces.storageKey` is what Reset All Settings keeps and the salvage key derives
/// from; `ContentView`'s `@AppStorage` needs the literal at the property. If they drift, Reset All
/// resets the real list.
@Suite struct FavoritePlacesKeyTests {

    @Test func favoritePlacesKeyMatchesTheAppStorageProperty() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let code = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read ContentView.swift — this scan would be vacuous")
        try #require(code.contains("@AppStorage("), "the file holds no @AppStorage — the scan is vacuous")
        #expect(code.contains("@AppStorage(\"\(SidebarFavoritePlaces.storageKey)\")"),
                "ContentView reads a different key from SidebarFavoritePlaces.storageKey")
    }

    /// The salvage key is derived from the storage key, so a rename can't leave it behind.
    @Test func theSalvageKeyFollowsTheStorageKey() {
        #expect(SidebarFavoritePlaces.salvageKey == SidebarFavoritePlaces.storageKey + ".unreadable")
    }
}

/// Clicking a place that lives inside another source lands on that place, not at the owning
/// source's root (with `~` a source, clicking Downloads must open Downloads).
///
/// A bare provider write makes `onChange(of: leftProviderId)` fire on the next view update and call
/// `retargetPane()`, which re-homes the pane and throws away a `focusOn` issued in the same turn. So
/// the switch arms `pendingTabProviderChanges` through `adoptProviderForTab`, as
/// `CommandPaletteHost.switchSourceAndReveal` does for ⌘K, and drives the one reload itself.
///
/// Asserted against `ContentView`'s own source, for the reason `SidebarPlaceRowTests` gives.
@Suite struct SidebarInsideOwnerNavigationTests {

    static func source() throws -> String { try SidebarPlaceRowTests.source() }

    /// The switch goes through the armed door, so the navigation survives the provider change.
    @Test func openingInsideAnOwnerArmsTheProviderChange() throws {
        let code = try Self.source()
        #expect(code.contains("adoptProviderForTab(provider.id, isLeft: isLeft"),
                "the sidebar switches source with a bare write again — retargetPane will re-home the pane and drop the folder the user clicked")
        #expect(code.contains("refreshForTabSwitch(movedPane: isLeft)"),
                "nothing drives the reload after the armed switch, so the moved pane keeps the old source's tree")
    }

    /// Order is the other half of the contract: `focusOn` must precede the armed write, so both
    /// land in one synchronous turn and the handler finds the navigation done. Asserted as
    /// positions, since merely reordering these three lines would break it with every symbol intact.
    @Test func theNavigationIsAppliedBeforeTheProviderIsAdopted() throws {
        let code = CodeText(try Self.source())
        let focus = try #require(code.range(of: "syncManager.focusOn(relativePath: relative, isLeft: isLeft)\n adoptProviderForTab"),
                                 "focusOn no longer immediately precedes adoptProviderForTab — the handler will not find the navigation done")
        let adopt = try #require(code.range(of: "adoptProviderForTab(provider.id"))
        let reload = try #require(code.range(of: "refreshForTabSwitch(movedPane: isLeft)"))
        #expect(focus.lowerBound < adopt.lowerBound)
        #expect(adopt.lowerBound < reload.lowerBound,
                "the reload runs before the provider is adopted, so it resolves the OLD ids")
    }

    /// The pane already on the owning source must not arm anything: there is no switch to survive,
    /// and a stray armed counter would swallow the next real provider change's reset.
    @Test func aPaneAlreadyOnTheOwnerJustNavigates() throws {
        let code = try Self.source()
        #expect(code.contains("guard !alreadyOnIt else {"),
                "the already-on-it case no longer short-circuits, so it arms a counter nothing will balance")
    }
}
