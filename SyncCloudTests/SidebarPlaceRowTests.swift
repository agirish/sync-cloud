@testable import SyncCloud
import Dashboard
import Sync
import Testing
import Foundation

/// **Where a place row goes, and what it is called, once it is also a source.**
///
/// Both bugs this suite pins were reported from the running app on 2026-08-24, and both came from
/// one thing: the rows were built *provider*-first, so a place that became a folder source stopped
/// being drawn as a place. Clicking `Macintosh HD` added `/` as a source, and the row promptly
/// moved up among the cloud accounts and renamed itself `/`. On a machine that already had Desktop
/// and Downloads as folder sources, those two never reached Favorites at all.
///
/// The rules are asserted against `ContentView`'s own source rather than a re-implementation, for
/// the reason `FolderSidebarWiringTests` gives: `ContentView` is a `View` with `@State` and cannot
/// be instantiated here, so the alternative is a copy of the logic that can agree with itself while
/// disagreeing with the app.
@Suite struct SidebarPlaceRowTests {

    static func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+FolderSidebar.swift")
        let raw = try #require(try? String(contentsOf: url, encoding: .utf8),
                               "cannot read ContentView+FolderSidebar.swift — this scan would be vacuous")
        try #require(raw.count > 3000, "the file is implausibly short — the scan is vacuous")
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// The scan reads something: a symbol that is definitely there must be found.
    @Test func theScanCanSeeAKnownSymbol() throws {
        #expect(try Self.source().contains("buildFolderSidebarPlaceRows"))
    }

    /// **Places are built before providers.** The claimed-by-a-provider check has to run against a
    /// place, which is only possible if the places exist first.
    @Test func aPlaceKeepsItsOwnNameWhenASourceClaimsIt() throws {
        let code = try Self.source()
        #expect(code.contains("name: place.name"),
                "the row takes its name from the provider again — a folder source over \"/\" is named \"/\", and over \"~\" is named for the account's short name")
        #expect(code.contains("band: place.band"),
                "the row takes its band from somewhere other than the place, so promoting a volume moves it out of the device band")
    }

    /// A place that a source claims becomes `.configured` — reachable — rather than being dropped
    /// from the place list and redrawn as a provider.
    @Test func aClaimedPlaceBecomesConfiguredRatherThanDisappearing() throws {
        let code = try Self.source()
        #expect(code.contains("owner != nil ? .configured"),
                "a place claimed by a source no longer resolves to .configured")
        #expect(code.contains("claimed.insert(owner.id)"),
                "nothing records which providers a place claimed, so the same folder draws twice")
    }

    /// **Only the providers no place claimed become cloud rows.** Without this, Desktop as a folder
    /// source is drawn once in Favorites and again in Locations.
    @Test func onlyUnclaimedProvidersBecomeCloudRows() throws {
        #expect(try Self.source().contains("providers.filter { !claimed.contains($0.id) }"),
                "every provider becomes a cloud row again, so a place that is also a source draws twice")
    }

    /// **The Trash is never a source**, whatever else is true of it — including on a machine where
    /// somebody has added `~/.Trash` as a folder source by hand.
    @Test func theTrashIsAlwaysRevealOnly() throws {
        let code = try Self.source()
        #expect(code.contains("if place.band == .trash"),
                "the Trash no longer short-circuits, so a source over it would make it browsable")
        #expect(code.contains("state: .revealOnly"))
    }

    /// **Promotion does not rename the source**, and that is the second answer to the same bug.
    ///
    /// It did, briefly — writing the sidebar's own word over a volume root called `/`. Then
    /// `FolderSource.defaultDisplayName` learned to ask the volume for its name, which fixes it for
    /// every way a source can be added rather than only for a sidebar click. An override on top
    /// would mark the source as user-renamed in Settings, and for the home folder would replace the
    /// deliberate "Home folder" with the account's short name — which is exactly what that special
    /// case exists to avoid. `FolderSourceVolumeNameTests` owns the rule now.
    @Test func promotingAPlaceDoesNotWriteANameOverride() throws {
        #expect(!(try Self.source().contains("setCustomName")),
                "promotion writes a name override again — the name belongs to FolderSource.defaultDisplayName, which every other entry point goes through")
    }

    /// **Bands are partitioned, not sorted.** `sorted(by:)` is not a stable sort in Swift, and every
    /// cloud account shares a band — so a sort would leave them free to shuffle between renders.
    @Test func theBandsArePartitionedRatherThanSorted() throws {
        let code = try Self.source()
        #expect(!code.contains("sorted { $0.band < $1.band }"),
                "the bands are ordered with an unstable sort, so same-band rows can shuffle between renders")
        #expect(code.contains("for band in [SidebarSourceRow.Band.cloud, .device, .trash]"),
                "the band order is no longer an explicit walk, so it cannot be read off the code")
    }

    /// **The Locations drag is indexed against the rows it dragged, not the provider list.**
    ///
    /// These are different lists and the difference is not exotic: a provider whose folder is a
    /// canonical place is CLAIMED by that place and drawn in Favorites, so it is absent from
    /// Locations. With `~/Desktop` and `~/Downloads` as folder sources — the setup on this machine
    /// — the cloud band is the provider list minus two, and indexing the providers meant every
    /// position past the first claimed one reordered a DIFFERENT source than the one dragged.
    /// Dragging a device row indexed past the end and silently did nothing.
    ///
    /// The bug is invisible without a claimed provider, which is why it survived the drag work's
    /// own tests: they exercised `SidebarReorder` on a list, and the list was never the wrong one.
    @Test func theSourceDragIndexesTheRowsItDragged() throws {
        let code = try Self.source()
        #expect(code.contains("let shown = folderSidebarLocationRows"),
                "moveFolderSidebarSource indexes something other than the rows the drag measured")
        #expect(!code.contains("let shown = folderSidebarProviders"),
                "moveFolderSidebarSource indexes the provider list again — a claimed provider is not drawn in Locations, so the indices do not line up")
    }

    /// Sources not drawn in Locations keep their positions — see `SidebarReorder.reordering`.
    /// Writing the visible ones out followed by everything else moves untouched sources to the end
    /// of the pane header's dropdown as a side effect of a drag they had nothing to do with.
    @Test func theSourceDragLeavesUndrawnSourcesWhereTheyAre() throws {
        let code = try Self.source()
        #expect(code.contains("SidebarReorder.reordering(all, subsetInNewOrder: subset)"),
                "the new order is not built as a subset reorder")
        #expect(!code.contains("moved.map(\\.id) + hidden"),
                "the order is written as the visible list plus the rest, which relocates every source nobody dragged")
    }

    /// One pass per refresh. Two would build every place row twice for one column.
    ///
    /// **The disk hit this used to be about has moved, and the guard is better for it.** The pass
    /// no longer enumerates the mounted volumes itself — the refresh walks them once and hands the
    /// result down (`deviceEntries(_:)`), because it now has to record what those volumes ARE for
    /// the unmount that cannot ask. So the cost is guarded by the parameter rather than by this
    /// count, and `EjectWiringTests.theRefreshWalksTheVolumesOnce` is where the walk is pinned.
    /// What survives here is the plainer invariant: one build per refresh.
    ///
    /// Matched on the call's opening rather than on a whole argument list, so adding an argument
    /// does not silently take the count to zero — which is what a signature change did to the
    /// exact-match spelling this replaced, and a zero reads as "never called" rather than as a
    /// stale scan.
    @Test func theRowsAreBuiltOncePerRefresh() throws {
        let code = try Self.source()
        let calls = code.components(separatedBy: "buildFolderSidebarPlaceRows(providers").count - 1
        #expect(calls == 1, "buildFolderSidebarPlaceRows runs \(calls) times per refresh")
    }

    /// **The walk is handed down, not repeated.** `deviceEntries` making its own would put a second
    /// `mountedVolumeURLs` plus a resource read per volume into every refresh — and under an
    /// unreachable network mount each of those reads can block, which is the same reason the
    /// refresh's `reachable` call answers both its lists in a single pass.
    @Test func thePlaceRowsTakeTheVolumeWalkRatherThanMakingOne() throws {
        let code = try Self.source()
        #expect(code.contains("Self.deviceEntries(volumes)"),
                "the place-row build enumerates the mounted volumes itself again")
        #expect(!code.contains("Self.deviceEntries()"),
                "a caller still asks deviceEntries to make its own walk")
    }
}

/// **The standard folders belong to Favorites**, and that must not depend on whether they happen to
/// be folder sources on this particular machine — which is exactly how the reported bug presented.
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

    /// A row's section is decided by its band alone — not by its state — so being a source, being
    /// inside one, or being neither all land in the same place.
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

/// **A place that a source links in from outside reads "in" that source, and the source keeps its
/// own row.** The case is iCloud Drive with Desktop & Documents syncing on: `~/Documents` is
/// inside iCloud through the container's `Documents` link, and no arithmetic on the two paths —
/// resolved or not — says so, because the link points from the container OUT to the real folder.
///
/// Built against the real `~/Documents` (the standard places are a constant) and a container that
/// exists nowhere, with the link table injected — the machine's own table would make the test
/// depend on whether this Mac syncs its Documents folder.
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

    /// The row the whole change exists for: Locations carries iCloud, with its own mark, because
    /// the Documents favorite no longer claims the provider outright.
    @Test func iCloudKeepsItsLocationsRow() throws {
        let rows = Self.split(links: Self.links)
        let icloud = try #require(rows.locations.first { $0.id == "iCloud" })
        #expect(icloud.band == .cloud)
        #expect(icloud.symbol == "icloud")
        #expect(icloud.state == .configured)
        #expect(icloud.absolutePath == Self.container)
    }

    /// Without the link, `~/Documents` is nothing to iCloud — the row is the one that promotes.
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

/// **The tail of Locations, in the order it is drawn: the startup disk, then any card, then the
/// Trash.**
///
/// Asked for directly on 2026-09-07, and asserted end to end because no single rule produces it.
/// Three separate mechanisms have to agree: `SidebarFavoritePlaces.standard` leaving the disk out
/// (so it stays a `.device` row rather than being lifted into Favorites),
/// `SidebarSourceModel.orderedVolumes` putting the internal disk ahead of the removable one, and
/// `splitFolderSidebarPlaceRows`' band walk putting `.trash` last. A unit test on any one of them
/// passes while the column is wrong.
///
/// **The Trash row depends on `~/.Trash` existing**, which `isMountedFolder` checks — it does on a
/// real Mac and the assertions below say so rather than assuming it, so a machine without one fails
/// loudly instead of silently measuring a two-row list.
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
    /// band starts at the volumes — which is what makes the disk the first row under the rule.
    @Test func theStartupDiskSitsAboveTheTrash() throws {
        let rows = Self.locations([Self.disk])
        #expect(rows.map(\.name) == ["Macintosh HD", "Trash"],
                "Locations reads \(rows.map(\.name)) — the disk is not between the rule and the Trash")
        #expect(rows.first?.band == .device)
        #expect(rows.last?.state == .revealOnly)
    }

    /// A card plugged in lands **below the disk and above the Trash** — the only gap it can take,
    /// and it is `orderedVolumes` that puts it there rather than anything in the sidebar.
    @Test func aCardLandsBetweenTheDiskAndTheTrash() throws {
        let rows = Self.locations([Self.card, Self.disk])
        #expect(rows.map(\.name) == ["Macintosh HD", "Untitled", "Trash"],
                "Locations reads \(rows.map(\.name))")
        #expect(rows.first { $0.name == "Untitled" }?.symbol == "sdcard")
    }

    /// **The Trash is last whatever else is mounted**, including a volume whose name sorts after
    /// it. Names are the trap here: the volumes sort among themselves, and a `Zip` disk beside a
    /// row called `Trash` is exactly the fixture that would expose an ordering that sorted the
    /// whole band by name instead of walking the bands.
    @Test func theTrashStaysLastWhateverIsMounted() throws {
        let extras = [SidebarSourceModel.Volume(name: "Zip", path: "/Volumes/Zip",
                                               isRemovable: true, isInternal: false),
                      SidebarSourceModel.Volume(name: "Archive", path: "/Volumes/Archive",
                                                isRemovable: false, isInternal: false)]
        let rows = Self.locations([Self.card] + extras + [Self.disk])
        #expect(rows.map(\.name) == ["Macintosh HD", "Archive", "Untitled", "Zip", "Trash"],
                "Locations reads \(rows.map(\.name))")
    }

    /// **And the disk is only there because the default list leaves it out.** Favoriting it takes
    /// it back out of Locations — the fallback both directions rest on — which is what stops this
    /// suite from passing for a reason other than the one it claims.
    @Test func favoritingTheDiskTakesItBackOutOfLocations() throws {
        let split = ContentView.splitFolderSidebarPlaceRows(
            [], volumes: [Self.disk],
            favoritePlaces: SidebarFavoritePlaces.standard + [SidebarSourceModel.startupDiskPath],
            links: [:])
        #expect(split.locations.map(\.name) == ["Trash"])
        #expect(split.shortcuts.last?.name == "Macintosh HD")
    }
}

/// **The Favorites defaults key is spelled twice, and this is what binds the two.**
///
/// `SidebarFavoritePlaces.storageKey` is what the launch migration reads; `ContentView`'s
/// `@AppStorage` is what the column reads, and it needs the literal at the property. Nothing fails
/// when they drift — the migration rewrites a key nothing draws from, silently, which is the shape
/// of every defaults-key bug in this app's history.
@Suite struct FavoritePlacesKeyTests {

    @Test func favoritePlacesKeyMatchesTheAppStorageProperty() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let code = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read ContentView.swift — this scan would be vacuous")
        try #require(code.contains("@AppStorage("), "the file holds no @AppStorage — the scan is vacuous")
        #expect(code.contains("@AppStorage(\"\(SidebarFavoritePlaces.storageKey)\")"),
                "ContentView reads a different key from the one SidebarFavoritePlaces.migrate writes")
    }

    /// The salvage key is derived, so it cannot be left behind by a rename — asserted rather than
    /// assumed, because it was a separate literal until 2026-09-07.
    @Test func theSalvageKeyFollowsTheStorageKey() {
        #expect(SidebarFavoritePlaces.salvageKey == SidebarFavoritePlaces.storageKey + ".unreadable")
    }
}
