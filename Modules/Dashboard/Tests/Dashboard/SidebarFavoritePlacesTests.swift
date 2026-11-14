import Testing
import Foundation
@testable import Dashboard

/// Which places sit in Favorites, a stored list the user can change.
@Suite struct SidebarFavoritePlacesTests {

    /// The arrangement a first run gets, in order: home, then the three folders you file into.
    /// Pinned as a whole list, since `contains` checks would pass the shuffle a later edit to
    /// `favoriteShortcuts` would produce. Leaving the startup disk out draws it in Locations' device
    /// band; every entry is absolute, or `resolved` would match it against the working directory.
    @Test func theDefaultFavoritesAreHomeAndTheThreeFolders() {
        #expect(SidebarFavoritePlaces.standard == [
            NSHomeDirectory(),
            NSHomeDirectory() + "/Desktop",
            NSHomeDirectory() + "/Documents",
            NSHomeDirectory() + "/Downloads",
        ])
        #expect(!SidebarFavoritePlaces.standard.contains(SidebarSourceModel.startupDiskPath),
                "the startup disk is back in the default Favorites — it belongs in Locations' device band, above any card and the Trash")
        #expect(!SidebarFavoritePlaces.isMissingStandard(SidebarFavoritePlaces.standard),
                "Restore Standard Places would be offered forever on an untouched install")
        #expect(SidebarFavoritePlaces.standard.allSatisfy { $0.hasPrefix("/") })
        #expect(Set(SidebarFavoritePlaces.standard).count == SidebarFavoritePlaces.standard.count,
                "a duplicate default would draw one row and leave a dead entry behind it")
    }

    /// Why the encoding is JSON, not a joined string: an untouched key and an emptied list differ.
    @Test func anUntouchedKeyIsNotAnEmptyList() {
        #expect(SidebarFavoritePlaces.places(from: "") == SidebarFavoritePlaces.standard,
                "a first run has to get the standard places")
        #expect(SidebarFavoritePlaces.places(from: "[]").isEmpty,
                "someone who removed every one must not be handed them back on the next launch")
    }

    /// A path containing the separator any plain join would pick. Rare, and cheap to be safe from.
    @Test func aPathHoldingASeparatorSurvivesARoundTrip() {
        let odd = ["/Volumes/Backup, 2026", "/Users/x/Notes\nDrafts"]
        #expect(SidebarFavoritePlaces.places(from: SidebarFavoritePlaces.encoded(odd)) == odd)
    }

    @Test func togglingAddsAtTheEndAndRemovesInPlace() {
        let list = ["/a", "/b"]
        #expect(SidebarFavoritePlaces.toggling("/c", in: list) == ["/a", "/b", "/c"],
                "a new favorite joining at the top would push the row under the pointer elsewhere")
        #expect(SidebarFavoritePlaces.toggling("/a", in: list) == ["/b"])
    }

    /// Restore puts the standard places back as a block, in standard order. Prepending only the
    /// missing ones would leave a kept one out of place. Checked for each kept position, since
    /// keeping the first would let a prepend pass by accident.
    @Test func theStandardPlacesComeBackInTheirStandardOrder() {
        for kept in SidebarFavoritePlaces.standard {
            #expect(SidebarFavoritePlaces.restoring([kept]) == SidebarFavoritePlaces.standard,
                    "restoring around a kept \(kept) did not reproduce the standard order")
        }
    }

    /// And they come back above what the user added, which is where they started.
    @Test func whatTheUserAddedStaysBelowThem() {
        let mixed = ["/Volumes/Work", SidebarFavoritePlaces.standard[2], "/Volumes/Archive"]
        #expect(SidebarFavoritePlaces.restoring(mixed)
                == SidebarFavoritePlaces.standard + ["/Volumes/Work", "/Volumes/Archive"])
    }

    @Test func restoringIsOfferedOnlyWhenSomethingIsMissing() {
        #expect(!SidebarFavoritePlaces.isMissingStandard(SidebarFavoritePlaces.standard))
        #expect(SidebarFavoritePlaces.isMissingStandard(Array(SidebarFavoritePlaces.standard.dropLast())))
        #expect(SidebarFavoritePlaces.isMissingStandard([]))
    }

    private func row(_ path: String, band: SidebarSourceRow.Band,
                     state: SidebarSourceRow.State = .configured) -> SidebarSourceRow {
        SidebarSourceRow(id: path, name: (path as NSString).lastPathComponent, detail: nil,
                         symbol: "folder", absolutePath: path, band: band, state: state,
                         isAvailable: true)
    }

    /// The Trash is the one row with no answer — a Favorites row for it could not do what every
    /// other row in that section does.
    @Test func theTrashIsNeverOfferedAFavoritesVerb() {
        #expect(SidebarSourceModel.favoriteVerb(for: row("/t", band: .trash, state: .revealOnly)) == nil)
        #expect(SidebarSourceModel.favoriteVerb(for: row("/d", band: .device)) == "Add to Favorites")
        #expect(SidebarSourceModel.favoriteVerb(for: row("/s", band: .shortcut)) == "Remove from Favorites")
    }

    /// Favoriting moves a place. Two rows for one place, one under each heading, is worse than
    /// either, and leaves the user asking which one to remove.
    @Test func changingBandKeepsEverythingElseAboutTheRow() {
        let original = row("/Dropbox", band: .cloud)
        let moved = original.inBand(.shortcut)
        #expect(moved.band == .shortcut)
        #expect(moved.id == original.id && moved.name == original.name
                && moved.absolutePath == original.absolutePath && moved.state == original.state
                && moved.symbol == original.symbol && moved.isAvailable == original.isAvailable)
    }
}

/// Favorites is two lists drawn as one, and the drag index spans both;
/// `SidebarReorder.favoritesMove` maps a combined index into the right list.
@Suite struct FavoritesCombinedIndexTests {

    /// With three place rows above, the first remembered folder is at combined index 3 and must
    /// map to index 0 of the folder list.
    @Test func theFirstRememberedFolderIsIndexZeroInItsOwnList() {
        let move = SidebarReorder.favoritesMove(from: 3, to: 4, places: 3)
        #expect(!move.isPlace)
        #expect(move.from == 0, "the combined index went straight to a list that had two entries")
        #expect(move.to == 1)
    }

    @Test func aPlaceRowStaysInThePlaceList() {
        let move = SidebarReorder.favoritesMove(from: 0, to: 2, places: 3)
        #expect(move.isPlace)
        #expect((move.from, move.to) == (0, 2))
    }

    /// Neither half may be addressed past its own boundary — the clamp the insertion line draws to.
    @Test func neitherHalfReachesPastItsBoundary() {
        #expect(SidebarReorder.favoritesMove(from: 0, to: 9, places: 3).to == 3)
        #expect(SidebarReorder.favoritesMove(from: 4, to: 0, places: 3).to == 0)
    }

    /// With no place rows the combined space is the folder list, so the index passes through.
    @Test func withNoPlacesTheIndexIsUnchanged() {
        let move = SidebarReorder.favoritesMove(from: 2, to: 5, places: 0)
        #expect(!move.isPlace && move.from == 2 && move.to == 5)
    }
}

/// What a folded Favorites heading says is behind it.
@Suite struct FavoritesRowCountTests {

    private static func row(_ path: String, _ group: FolderSidebarRow.Group = .pinned) -> FolderSidebarRow {
        FolderSidebarRow(group: group, root: "/r", sourceName: "R", relativePath: path,
                         name: (path as NSString).lastPathComponent, detail: nil, isAvailable: true)
    }

    /// Both lists count; places alone too (the first run: otherwise "0 items" over visible rows).
    /// Recents share the array and don't count, and an empty section reaches zero, or its
    /// invitation would never show.
    @Test(arguments: [
        ([], 3, 3),
        ([row("A"), row("B")], 3, 5),
        ([row("A"), row("C", .recents)], 0, 1),
        ([], 0, 0),
    ] as [([FolderSidebarRow], Int, Int)])
    func theCountIsFavoritesAndPlaces(rows: [FolderSidebarRow], places: Int, expected: Int) {
        #expect(FolderSidebarModel.favoritesCount(folderRows: rows, places: places) == expected)
    }
}

/// A reorder of what was on screen, written back into a list that holds more.
@Suite struct FavoritePlaceResplicingTests {

    /// A hidden entry, such as an unplugged volume, keeps its slot. Appending it after the visible
    /// rows would move it to the end of a list nothing on screen describes.
    @Test func anInvisibleEntryKeepsItsSlot() {
        let stored = ["/Volumes/Off", "/Desktop", "/Documents"]
        let moved = ["/Documents", "/Desktop"]
        #expect(SidebarReorder.resplicing(stored, visibleInNewOrder: moved)
                == ["/Volumes/Off", "/Documents", "/Desktop"])
    }

    /// An invisible entry between two visible ones, which an append can't even approximate.
    @Test func anInvisibleEntryInTheMiddleStaysInTheMiddle() {
        let stored = ["/Desktop", "/Volumes/Off", "/Documents"]
        #expect(SidebarReorder.resplicing(stored, visibleInNewOrder: ["/Documents", "/Desktop"])
                == ["/Documents", "/Volumes/Off", "/Desktop"])
    }

    @Test func withNothingHiddenItIsJustTheNewOrder() {
        #expect(SidebarReorder.resplicing(["/a", "/b", "/c"], visibleInNewOrder: ["/c", "/a", "/b"])
                == ["/c", "/a", "/b"])
    }

    /// A stored list naming nothing that is drawn is left exactly as it is, rather than emptied.
    @Test func nothingVisibleChangesNothing() {
        #expect(SidebarReorder.resplicing(["/a", "/b"], visibleInNewOrder: []) == ["/a", "/b"])
    }

    // MARK: - Absent, empty and unreadable are three states

    /// The two states that are not unreadable, which a salvage must never fire for.
    @Test func absentAndEmptyAreBothReadable() {
        #expect(!SidebarFavoritePlaces.isUnreadable(""), "an untouched key has nothing to salvage")
        #expect(!SidebarFavoritePlaces.isUnreadable("[]"),
                "removing every favorite is a decision, and a decision is readable")
        #expect(!SidebarFavoritePlaces.isUnreadable(SidebarFavoritePlaces.encoded(["/Desktop"])))
    }

    /// Everything `isUnreadable` flags is a value `places(from:)` answers `standard` for, the
    /// overlap that makes writing back dangerous: the standard places are right to show, but
    /// encoding them back over the key would lose the user's bytes.
    @Test func everyUnreadableValueReadsAsTheStandardThree() {
        for raw in ["{not json", "[1, 2, 3]", "\"/Desktop\""] {
            #expect(SidebarFavoritePlaces.isUnreadable(raw))
            #expect(SidebarFavoritePlaces.places(from: raw) == SidebarFavoritePlaces.standard,
                    "“\(raw)” reads as something other than the first-run answer")
        }
    }
}
