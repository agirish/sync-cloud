import Testing
import Foundation
@testable import Dashboard

/// Naming the rows of Locations and of Favorites' standard folders, and deciding what a click on
/// each one means.
@Suite struct SidebarSourceModelTests {

    // MARK: - Qualification

    /// Rows sharing a name are qualified by their account (three Google Drive accounts render one
    /// word); a name nothing else shares is left alone even with a qualifier available, so rows
    /// don't grow a second line. Counted per name, and a collision with no qualifier stays
    /// unqualified rather than drawing an empty detail, as `FolderSidebarModel.rows` does.
    @Test(arguments: [
        (["iCloud Drive", "Dropbox", "Drive", "Drive", "Drive"], [nil, nil, "personal", "preserve", "emp"],
         [nil, nil, "personal", "preserve", "emp"]),
        (["Dropbox", "iCloud Drive"], ["personal", "father"], [nil, nil]),
        (["Drive", "Drive", "OneDrive", "Dropbox"], ["emp", "personal", "work", "main"], ["emp", "personal", nil, nil]),
        (["Drive", "Drive"], [nil, ""], [nil, nil]),
    ] as [([String], [String?], [String?])])
    func onlyNamesThatCollideAreQualified(names: [String], qualifiers: [String?], expected: [String?]) {
        #expect(SidebarSourceModel.qualifiers(names: names, qualifiers: qualifiers) == expected)
    }

    // MARK: - Containment, and the gap it closes

    /// Under macOS's Desktop & Documents syncing, `~/Desktop` links into `com~apple~CloudDocs`, so a
    /// plain path comparison misses it, and promoting it would mint a second source over a tree
    /// iCloud already scans.
    @Test func aShortcutThatSymlinksIntoACloudRootIsClaimedByThatSource() {
        let roots = [(id: "icloud", name: "iCloud Drive", path: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs")]
        let owner = SidebarSourceModel.owningSource(of: "/Users/u/Desktop", among: roots) { path in
            path == "/Users/u/Desktop"
                ? "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/Desktop" : path
        }
        #expect(owner?.id == "icloud")
        #expect(owner?.name == "iCloud Drive")
    }

    /// A folder genuinely outside every source is unowned, and is therefore the row that promotes.
    @Test func aShortcutOutsideEverySourceIsUnowned() {
        let roots = [(id: "icloud", name: "iCloud Drive", path: "/Users/u/iCloud")]
        #expect(SidebarSourceModel.owningSource(of: "/Users/u/Downloads", among: roots) { $0 } == nil)
    }

    /// The longest root wins, so a folder source nested inside a cloud account resolves to the
    /// more specific one rather than whichever was listed first.
    @Test func theMostSpecificContainingSourceWins() {
        let roots = [(id: "icloud", name: "iCloud Drive", path: "/Users/u/iCloud"),
                     (id: "proj", name: "Projects", path: "/Users/u/iCloud/Projects")]
        #expect(SidebarSourceModel.owningSource(of: "/Users/u/iCloud/Projects/App", among: roots) { $0 }?.id == "proj")
    }

    /// A path that is a source's root is owned by it, agreeing with
    /// `SettingsManager.addFolderSource`, which returns the existing id.
    @Test func aPathThatIsASourceRootIsOwnedByThatSource() {
        let roots = [(id: "dl", name: "Downloads", path: "/Users/u/Downloads")]
        #expect(SidebarSourceModel.owningSource(of: "/Users/u/Downloads", among: roots) { $0 }?.id == "dl")
    }

    /// A sibling whose name merely starts the same way is not inside. `hasPrefix` alone would call
    /// `/Users/u/Downloads2` contained, routing a click into the wrong source and suppressing a
    /// promotion the user asked for.
    @Test func aSiblingSharingAPrefixIsNotContained() {
        let roots = [(id: "dl", name: "Downloads", path: "/Users/u/Downloads")]
        #expect(SidebarSourceModel.owningSource(of: "/Users/u/Downloads2", among: roots) { $0 } == nil)
        #expect(!SidebarSourceModel.contains("/Users/u/Downloads2", under: "/Users/u/Downloads"))
        #expect(SidebarSourceModel.contains("/Users/u/Downloads/A", under: "/Users/u/Downloads"))
    }

    /// Two same-named sources resolve by id, and the id survives into
    /// `.inside(sourceId:sourceName:)`. Resolving by display name would pick whichever "Drive" came
    /// first and strip the path against the wrong root, so a path inside the second of two
    /// same-named roots must identify the second.
    @Test func aPathInsideTheSecondOfTwoSameNamedSourcesResolvesToTheSecond() throws {
        let roots = [(id: "drive-personal", name: "Drive", path: "/Users/u/Drive"),
                     (id: "drive-work", name: "Drive", path: "/Volumes/Work/Drive")]
        let owner = try #require(SidebarSourceModel.owningSource(
            of: "/Volumes/Work/Drive/Projects", among: roots) { $0 })
        #expect(owner.id == "drive-work",
                "the owner's name is “Drive” either way — only the id says which account, and it named the wrong one")
        #expect(owner.name == "Drive")
        // The state built from that answer carries the id beside the display name, so no handler
        // downstream has to resolve the name again.
        let state = SidebarSourceRow.State.inside(sourceId: owner.id, sourceName: owner.name)
        #expect(state == .inside(sourceId: "drive-work", sourceName: "Drive"))
    }

    /// Case is folded, because the default macOS volume is case-insensitive. Claiming is the safe
    /// direction: a wrong claim costs a navigation the user can see, a missed one a duplicate source
    /// they won't.
    @Test func containmentFoldsCase() {
        #expect(SidebarSourceModel.contains("/Users/u/DOWNLOADS/A", under: "/Users/u/downloads"))
    }

    /// A trailing slash on the root must not change the answer: provider paths are user-settable
    /// and arrive however they were typed.
    @Test func aTrailingSlashOnTheRootChangesNothing() {
        #expect(SidebarSourceModel.contains("/Users/u/Downloads/A", under: "/Users/u/Downloads/"))
        #expect(SidebarSourceModel.contains("/Users/u/Downloads", under: "/Users/u/Downloads/"))
    }

    /// An empty root claims nothing. A source whose Location was never set would otherwise contain
    /// every path on the machine.
    @Test func anEmptyRootClaimsNothing() {
        let roots = [(id: "broken", name: "Unset", path: "")]
        #expect(SidebarSourceModel.owningSource(of: "/Users/u/Downloads", among: roots) { $0 } == nil)
    }

    // MARK: - What lives where

    /// Desktop, Documents and Downloads are the places whose only band is Favorites: with no
    /// Locations row to fall back to, they need "Restore Standard Places". The rest of the default
    /// set is asserted in `SidebarFavoritePlacesTests`.
    @Test func theStandardFoldersAreTheThreeYouFileInto() {
        #expect(SidebarSourceModel.favoriteShortcuts.map(\.name) == ["Desktop", "Documents", "Downloads"])
        #expect(SidebarSourceModel.favoriteShortcuts.allSatisfy { $0.path.hasPrefix("/") },
                "a shortcut path is not absolute — it would resolve against the working directory")
        #expect(SidebarSourceModel.favoriteShortcuts.allSatisfy { !$0.symbol.isEmpty })
    }

    /// Home is favorited by default and still built as a Locations row. `favoriteShortcuts` holds
    /// places that exist only in Favorites; `homeEntry` has a Locations row the default list lifts
    /// into Favorites by path. A `favoriteShortcuts` entry for it would build two rows, since the
    /// builder walks both lists. The startup disk is checked for the same hazard.
    @Test func homeIsAFavoriteByDefaultAndStillHasItsLocationsRow() {
        #expect(SidebarSourceModel.homeEntry.path == NSHomeDirectory())
        #expect(SidebarFavoritePlaces.standard.contains(NSHomeDirectory()),
                "home is not in the default Favorites — it was the first row of the arrangement asked for")
        #expect(!SidebarSourceModel.favoriteShortcuts.contains { $0.path == NSHomeDirectory() },
                "home is in both lists — the builder would draw two rows for it")
        #expect(!SidebarSourceModel.favoriteShortcuts.contains { $0.path == SidebarSourceModel.startupDiskPath },
                "the startup disk is in both lists — the builder would draw two rows for it")
    }

    /// The startup disk is `/`, nothing more: its name and glyph come from the mounted-volume walk,
    /// so this can't go stale when a disk is renamed.
    @Test func theStartupDiskIsNamedByPathOnly() {
        #expect(SidebarSourceModel.startupDiskPath == "/")
    }

    /// Home contains the standard folders. Once Home is a folder source, clicking Desktop or
    /// Downloads must navigate inside it rather than mint more sources under one root.
    @Test func onceHomeIsASourceTheStandardFoldersAreInsideIt() {
        let roots = [(id: "home", name: "Home", path: SidebarSourceModel.homeEntry.path)]
        for shortcut in SidebarSourceModel.favoriteShortcuts {
            #expect(SidebarSourceModel.owningSource(of: shortcut.path, among: roots) { $0 }?.id == "home",
                    "\(shortcut.name) is not recognised as inside Home — clicking it would add a second source under one root")
        }
    }

    /// The Trash is under Home too, but it is never promoted, which is the `revealOnly` state, not
    /// containment.
    @Test func theTrashIsUnderHome() {
        #expect(SidebarSourceModel.trashEntry.path.hasPrefix(NSHomeDirectory()))
        #expect(SidebarSourceModel.trashEntry.name == "Trash")
    }

    // MARK: - Volumes

    private func volume(_ name: String, internal isInternal: Bool = false,
                        removable: Bool = false) -> SidebarSourceModel.Volume {
        .init(name: name, path: "/Volumes/\(name)", isRemovable: removable, isInternal: isInternal)
    }

    /// The startup disk first, then the rest by name. Mount order differs between boots, and disks
    /// that rearranged themselves would look broken.
    @Test func theStartupDiskLeadsAndTheRestSortByName() {
        let out = SidebarSourceModel.orderedVolumes(
            [volume("Backup"), volume("Macintosh HD", internal: true), volume("Archive")])
        #expect(out.map(\.name) == ["Macintosh HD", "Archive", "Backup"])
    }

    /// Sorted the way the file panes sort names, so "Disk 2" and "Disk 10" read in the order a
    /// person expects rather than in ASCII order.
    @Test func volumeNamesSortTheWayNamesSort() {
        let out = SidebarSourceModel.orderedVolumes([volume("Disk 10"), volume("Disk 2")])
        #expect(out.map(\.name) == ["Disk 2", "Disk 10"])
    }

    /// The glyph says what kind of disk it is: built in, pullable, or neither. A volume reporting
    /// both removable and internal (the startup disk on some Macs) is drawn as internal.
    @Test func theGlyphDistinguishesTheThreeKindsOfDisk() {
        #expect(volume("HD", internal: true).symbol == "internaldrive")
        #expect(volume("SD", removable: true).symbol == "sdcard")
        #expect(volume("Backup").symbol == "externaldrive")
        #expect(volume("HD", internal: true, removable: true).symbol == "internaldrive")
    }

    // MARK: - Bands

    /// The bands are drawn in declaration order, which is Finder's: clouds, then hardware, then the
    /// Trash.
    @Test func theBandsOrderCloudsThenDevicesThenTrash() {
        #expect(SidebarSourceRow.Band.cloud < SidebarSourceRow.Band.device)
        #expect(SidebarSourceRow.Band.device < SidebarSourceRow.Band.trash)
    }

    // MARK: - How a row reads

    private func row(_ state: SidebarSourceRow.State, available: Bool = true) -> SidebarSourceRow {
        SidebarSourceRow(id: "x", name: "Downloads", detail: nil, symbol: "folder",
                         absolutePath: "/Users/u/Downloads", band: .shortcut,
                         state: state, isAvailable: available)
    }

    /// Dimmed means "not answering" and nothing else: an unplugged drive, a signed-out account. A
    /// place SyncCloud hasn't been given yet is not dimmed; on a fresh install the whole device band
    /// is un-added, and greying out home, the startup disk and every card at once reads as broken.
    @Test(arguments: [SidebarSourceRow.State.unknown, .configured, .revealOnly,
                      .inside(sourceId: "icloud", sourceName: "iCloud Drive")], [true, false])
    func onlyAnUnavailableRowIsDimmed(state: SidebarSourceRow.State, available: Bool) {
        #expect(row(state, available: available).isDimmed == !available)
    }
}
