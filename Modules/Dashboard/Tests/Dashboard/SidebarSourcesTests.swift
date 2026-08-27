import Testing
import Foundation
@testable import Dashboard

/// **Naming the rows of Locations and of Favorites' standard folders**, and deciding what a
/// click on each one means.
@Suite struct SidebarSourceModelTests {

    // MARK: - Qualification

    /// **The case the whole section is shaped around.** Three Google Drive accounts render one
    /// word; without a qualifier they are three identical rows and two of them go somewhere the
    /// user did not mean.
    @Test func rowsSharingANameAreQualifiedByTheirAccount() {
        let out = SidebarSourceModel.qualifiers(
            names: ["iCloud Drive", "Dropbox", "Drive", "Drive", "Drive"],
            qualifiers: [nil, nil, "personal", "preserve", "hpe"])
        #expect(out == [nil, nil, "personal", "preserve", "hpe"])
    }

    /// And the other direction, which is what keeps the column from growing a second line on every
    /// row: a name nothing else shares is left alone even when a qualifier is available.
    @Test func aNameNothingSharesIsNotQualified() {
        let out = SidebarSourceModel.qualifiers(names: ["Dropbox", "iCloud Drive"],
                                                qualifiers: ["personal", "abhishek"])
        #expect(out == [nil, nil])
    }

    /// Two OneDrives and two Drives collide independently — qualification is per name, not a
    /// property of the whole list.
    @Test func collisionsAreCountedPerNameNotAcrossTheList() {
        let out = SidebarSourceModel.qualifiers(
            names: ["Drive", "Drive", "OneDrive", "Dropbox"],
            qualifiers: ["hpe", "personal", "work", "main"])
        #expect(out == ["hpe", "personal", nil, nil])
    }

    /// A collision with nothing to say about it stays unqualified rather than drawing an empty
    /// detail — the same rule `FolderSidebarModel.rows` applies when a top-level folder has no
    /// parent path.
    @Test func aCollisionWithNoQualifierAvailableIsLeftAlone() {
        let out = SidebarSourceModel.qualifiers(names: ["Drive", "Drive"], qualifiers: [nil, ""])
        #expect(out == [nil, nil])
    }

    // MARK: - Containment, and the gap it closes

    /// **The reason this rule exists.** Under macOS's Desktop & Documents syncing, `~/Desktop` is a
    /// link into `com~apple~CloudDocs` — so a plain path comparison says it has nothing to do with
    /// iCloud Drive, and promoting it would mint a second source over a tree iCloud already scans.
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

    /// **The longest root wins**, so a folder source nested inside a cloud account resolves to the
    /// more specific one rather than to whichever was listed first.
    @Test func theMostSpecificContainingSourceWins() {
        let roots = [(id: "icloud", name: "iCloud Drive", path: "/Users/u/iCloud"),
                     (id: "proj", name: "Projects", path: "/Users/u/iCloud/Projects")]
        #expect(SidebarSourceModel.owningSource(of: "/Users/u/iCloud/Projects/App", among: roots) { $0 }?.id == "proj")
    }

    /// A path that *is* a source's root is owned by it — the case
    /// `SettingsManager.addFolderSource` already handles by returning the existing id, and this
    /// must agree with it rather than promoting alongside it.
    @Test func aPathThatIsASourceRootIsOwnedByThatSource() {
        let roots = [(id: "dl", name: "Downloads", path: "/Users/u/Downloads")]
        #expect(SidebarSourceModel.owningSource(of: "/Users/u/Downloads", among: roots) { $0 }?.id == "dl")
    }

    /// **A sibling whose name merely starts the same way is not inside.** `hasPrefix` alone reports
    /// `/Users/u/Downloads2` as contained, which would silently route a click into the wrong
    /// source and quietly suppress a promotion the user asked for.
    @Test func aSiblingSharingAPrefixIsNotContained() {
        let roots = [(id: "dl", name: "Downloads", path: "/Users/u/Downloads")]
        #expect(SidebarSourceModel.owningSource(of: "/Users/u/Downloads2", among: roots) { $0 } == nil)
        #expect(!SidebarSourceModel.contains("/Users/u/Downloads2", under: "/Users/u/Downloads"))
        #expect(SidebarSourceModel.contains("/Users/u/Downloads/A", under: "/Users/u/Downloads"))
    }

    /// **Two same-named sources resolve by ID, and the id survives into `.inside`.** Name
    /// collisions are the very case this section's qualifiers exist for — three Google Drive
    /// accounts all render one word — so a handler re-resolving the owner by display name would
    /// pick whichever "Drive" came first and count-strip the path against the wrong root. The id
    /// `owningSource` returns is what `.inside(sourceId:sourceName:)` carries; this pins that a
    /// path inside the SECOND of two same-named roots identifies the second.
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

    /// Case is folded, because the default macOS volume is case-insensitive and the two spellings
    /// name one folder. Claiming is the safe direction: a wrong claim costs a navigation the user
    /// can see, a missed one costs a duplicate source they will not.
    @Test func containmentFoldsCase() {
        #expect(SidebarSourceModel.contains("/Users/u/DOWNLOADS/A", under: "/Users/u/downloads"))
    }

    /// A trailing slash on the root must not change the answer — provider paths are user-settable
    /// and arrive spelled however they were typed.
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

    /// **Desktop, Documents and Downloads are the three places whose ONLY band is Favorites** —
    /// they have no Locations row to fall back to, which is what makes "Restore Standard Places"
    /// necessary. The rest of the default Favorites set is asserted in `SidebarFavoritePlacesTests`.
    @Test func theStandardFoldersAreTheThreeYouFileInto() {
        #expect(SidebarSourceModel.favoriteShortcuts.map(\.name) == ["Desktop", "Documents", "Downloads"])
        #expect(SidebarSourceModel.favoriteShortcuts.allSatisfy { $0.path.hasPrefix("/") },
                "a shortcut path is not absolute — it would resolve against the working directory")
        #expect(SidebarSourceModel.favoriteShortcuts.allSatisfy { !$0.symbol.isEmpty })
    }

    /// **Home is favorited by default and is still built as a Locations row**, which is not a
    /// contradiction — it is the difference the two constants encode.
    ///
    /// `favoriteShortcuts` is "places that exist only in Favorites"; `homeEntry` and the startup
    /// disk are places with a Locations row of their own that the default list happens to lift into
    /// Favorites. A second `favoriteShortcuts` entry for either would build TWO rows for one folder
    /// — the builder walks both lists — which is why the default set names paths instead.
    @Test func homeIsAFavoriteByDefaultAndStillHasItsLocationsRow() {
        #expect(SidebarSourceModel.homeEntry.path == NSHomeDirectory())
        #expect(SidebarFavoritePlaces.standard.contains(NSHomeDirectory()),
                "home is not in the default Favorites — it was the first row of the arrangement asked for")
        #expect(!SidebarSourceModel.favoriteShortcuts.contains { $0.path == NSHomeDirectory() },
                "home is in both lists — the builder would draw two rows for it")
        #expect(!SidebarSourceModel.favoriteShortcuts.contains { $0.path == SidebarSourceModel.startupDiskPath },
                "the startup disk is in both lists — the builder would draw two rows for it")
    }

    /// The startup disk is `/` and nothing else needs to be true of it here: its name and its glyph
    /// come from the mounted-volume walk, so this constant cannot go stale when a disk is renamed.
    @Test func theStartupDiskIsNamedByPathOnly() {
        #expect(SidebarSourceModel.startupDiskPath == "/")
    }

    /// **Home still contains the other three**, which is why `owningSource` takes the longest match
    /// rather than the first. Once Home is a folder source, clicking Desktop or Downloads must
    /// navigate inside it rather than mint two more sources under one root.
    @Test func onceHomeIsASourceTheStandardFoldersAreInsideIt() {
        let roots = [(id: "home", name: "Home", path: SidebarSourceModel.homeEntry.path)]
        for shortcut in SidebarSourceModel.favoriteShortcuts {
            #expect(SidebarSourceModel.owningSource(of: shortcut.path, among: roots) { $0 }?.id == "home",
                    "\(shortcut.name) is not recognised as inside Home — clicking it would add a second source under one root")
        }
    }

    /// The Trash is under Home too, so the same rule applies to it — but it is never promoted
    /// regardless, which is the `revealOnly` state rather than anything about containment.
    @Test func theTrashIsUnderHome() {
        #expect(SidebarSourceModel.trashEntry.path.hasPrefix(NSHomeDirectory()))
        #expect(SidebarSourceModel.trashEntry.name == "Trash")
    }

    // MARK: - Volumes

    private func volume(_ name: String, internal isInternal: Bool = false,
                        removable: Bool = false) -> SidebarSourceModel.Volume {
        .init(name: name, path: "/Volumes/\(name)", isRemovable: removable, isInternal: isInternal)
    }

    /// **The startup disk first, then everything else by name.** Mount order is arrival order and
    /// differs between boots; a sidebar whose disks rearranged themselves would look broken.
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

    /// The ordering is stable across runs — same input, one answer.
    @Test func volumeOrderDoesNotVaryBetweenRuns() {
        let volumes = [volume("B"), volume("A"), volume("HD", internal: true)]
        let answers = Set((0..<40).map { _ in
            SidebarSourceModel.orderedVolumes(volumes).map(\.name).joined(separator: ">")
        })
        #expect(answers == ["HD>A>B"], "volume order varies between runs: \(answers)")
    }

    /// The glyph says what kind of disk it is: built in, pullable, or neither.
    @Test func theGlyphDistinguishesTheThreeKindsOfDisk() {
        #expect(volume("HD", internal: true).symbol == "internaldrive")
        #expect(volume("SD", removable: true).symbol == "sdcard")
        #expect(volume("Backup").symbol == "externaldrive")
    }

    /// A removable volume that also claims to be internal is drawn as internal — the startup disk
    /// on some Macs reports both, and "built in" is the more useful of the two claims.
    @Test func internalWinsOverRemovableForTheGlyph() {
        #expect(volume("HD", internal: true, removable: true).symbol == "internaldrive")
    }

    /// Ordering never adds or drops a disk, whatever it is handed.
    @Test func orderingVolumesIsAPermutation() {
        let volumes = [volume("B"), volume("A", internal: true), volume("C", removable: true)]
        #expect(Set(SidebarSourceModel.orderedVolumes(volumes).map(\.name)) == ["A", "B", "C"])
        #expect(SidebarSourceModel.orderedVolumes([]).isEmpty)
    }

    // MARK: - Bands

    /// The bands are drawn in the order they are declared, which is Finder's: the clouds you signed
    /// into, then the hardware, then the Trash.
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

    /// **A place SyncCloud has not been given yet is NOT dimmed**, and that is the correction this
    /// test records: it used to assert the opposite, and drawing it showed why that was wrong.
    /// Locations' whole device band is un-added on a fresh install — a disk is not a source until
    /// someone makes it one — so dimming `.unknown` greyed out the home folder, the startup disk
    /// and every mounted card at once, which reads as broken rather than as available. Finder does
    /// not dim your disks either.
    @Test func aPlaceThatIsNotASourceYetIsNotDimmed() {
        #expect(!row(.unknown).isDimmed)
    }

    /// **Dimmed means "not answering", and nothing else.** That is the one claim left, and it is
    /// the one a reader can act on: an unplugged drive, a signed-out account.
    @Test func onlyAnUnavailableRowIsDimmed() {
        #expect(row(.configured, available: false).isDimmed)
        #expect(row(.unknown, available: false).isDimmed)
        #expect(row(.revealOnly, available: false).isDimmed)
    }

    /// And every row that can act draws at full strength, whatever clicking it will do.
    @Test func everyReachableRowIsFullStrength() {
        #expect(!row(.configured).isDimmed)
        #expect(!row(.inside(sourceId: "icloud", sourceName: "iCloud Drive")).isDimmed)
        #expect(!row(.revealOnly).isDimmed)
    }
}
