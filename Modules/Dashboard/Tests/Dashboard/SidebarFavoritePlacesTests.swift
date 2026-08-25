import Testing
import Foundation
@testable import Dashboard

/// **Which places sit in Favorites** — the list that replaced a constant.
@Suite struct SidebarFavoritePlacesTests {

    /// The whole reason the encoding is JSON and not a joined string: three states, not two.
    @Test func anUntouchedKeyIsNotAnEmptyList() {
        #expect(SidebarFavoritePlaces.places(from: "") == SidebarFavoritePlaces.standard,
                "a first run has to get the three standard folders")
        #expect(SidebarFavoritePlaces.places(from: "[]").isEmpty,
                "someone who removed all three must not be handed them back on the next launch")
    }

    /// A path containing the separator any plain join would pick. Not hypothetical enough to matter
    /// often, and cheap enough to be safe from.
    @Test func aPathHoldingASeparatorSurvivesARoundTrip() {
        let odd = ["/Volumes/Backup, 2026", "/Users/x/Notes\nDrafts"]
        #expect(SidebarFavoritePlaces.places(from: SidebarFavoritePlaces.encoded(odd)) == odd)
    }

    /// Unreadable falls back to the standard three — the same answer a first run gets, which is a
    /// state the user recognises. A column that has silently lost its Favorites is worse.
    @Test func anUnreadableValueFallsBackRatherThanEmptying() {
        #expect(SidebarFavoritePlaces.places(from: "{not json") == SidebarFavoritePlaces.standard)
        #expect(SidebarFavoritePlaces.places(from: "[1,2,3]") == SidebarFavoritePlaces.standard)
    }

    @Test func togglingAddsAtTheEndAndRemovesInPlace() {
        let list = ["/a", "/b"]
        #expect(SidebarFavoritePlaces.toggling("/c", in: list) == ["/a", "/b", "/c"],
                "a new favorite joining at the top would push the row under the pointer elsewhere")
        #expect(SidebarFavoritePlaces.toggling("/a", in: list) == ["/b"])
    }

    /// Restore is additive: it must not disturb what the user put there.
    @Test func restoringKeepsWhatIsAlreadyThere() {
        let kept = ["/Volumes/Work"]
        let restored = SidebarFavoritePlaces.restoring(kept)
        #expect(restored.suffix(1) == kept[...])
        #expect(Set(restored).isSuperset(of: SidebarFavoritePlaces.standard))
        #expect(restored.count == SidebarFavoritePlaces.standard.count + 1,
                "a standard folder already present must not be added twice")
    }

    /// **Restoring only the missing ones is not restoring the standard order.** With Documents kept
    /// and the other two removed, prepending the missing pair produced Desktop, Downloads,
    /// Documents — the three standard folders back, in an order the item's own name does not
    /// promise. They are placed as a block for that reason.
    @Test func theStandardThreeComeBackInTheirStandardOrder() {
        let kept = [SidebarFavoritePlaces.standard[1]]
        #expect(SidebarFavoritePlaces.restoring(kept) == SidebarFavoritePlaces.standard)
    }

    /// And they come back ABOVE what the user added, which is where they started.
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

    /// Favoriting MOVES a place. Two rows for one place, one under each heading, is worse than
    /// either — and it would make "which one do I remove?" a question.
    @Test func changingBandKeepsEverythingElseAboutTheRow() {
        let original = row("/Dropbox", band: .cloud)
        let moved = original.inBand(.shortcut)
        #expect(moved.band == .shortcut)
        #expect(moved.id == original.id && moved.name == original.name
                && moved.absolutePath == original.absolutePath && moved.state == original.state
                && moved.symbol == original.symbol && moved.isAvailable == original.isAvailable)
    }
}

/// **Favorites is two lists drawn as one**, and the drag index spans both. This is the arithmetic
/// that was missing — see `SidebarReorder.favoritesMove` for what it cost.
@Suite struct FavoritesCombinedIndexTests {

    /// The exact shape of the shipped defect: three standard folders present, and the FIRST
    /// remembered folder is at combined index 3.
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

    /// With no place rows the combined space IS the folder list, which is the state the old
    /// arithmetic was right for — and the only one.
    @Test func withNoPlacesTheIndexIsUnchanged() {
        let move = SidebarReorder.favoritesMove(from: 2, to: 5, places: 0)
        #expect(!move.isPlace && move.from == 2 && move.to == 5)
    }
}

/// **What a folded Favorites heading says is behind it.**
@Suite struct FavoritesRowCountTests {

    private func favorite(_ path: String) -> FolderSidebarRow {
        FolderSidebarRow(group: .pinned, root: "/r", sourceName: "R", relativePath: path,
                         name: (path as NSString).lastPathComponent, detail: nil, isAvailable: true)
    }

    /// **The first-run state, which is the whole finding.** Three standard places and no remembered
    /// folder yet: the badge read `0` over three rows, and VoiceOver said "0 items".
    @Test func placesAloneAreStillRows() {
        #expect(FolderSidebarModel.favoritesCount(folderRows: [], places: 3) == 3)
    }

    @Test func bothListsAreCounted() {
        let rows = [favorite("A"), favorite("B")]
        #expect(FolderSidebarModel.favoritesCount(folderRows: rows, places: 3) == 5)
    }

    /// Recents share the array and must not be counted into Favorites — the filter is load-bearing.
    @Test func aRecentIsNotAFavorite() {
        let recent = FolderSidebarRow(group: .recents, root: "/r", sourceName: "R",
                                      relativePath: "C", name: "C", detail: nil, isAvailable: true)
        #expect(FolderSidebarModel.favoritesCount(folderRows: [favorite("A"), recent], places: 0) == 1)
    }

    /// The empty section is the one that draws its invitation instead of nothing, so zero has to be
    /// reachable — a count that could never be zero would hide the first-run copy.
    @Test func anEmptySectionCountsZero() {
        #expect(FolderSidebarModel.favoritesCount(folderRows: [], places: 0) == 0)
    }
}

/// **A reorder of what was on screen, written back into a list that holds more.**
@Suite struct FavoritePlaceResplicingTests {

    /// The defect: an unplugged volume favorited first was appended after the visible rows, so a
    /// drag among the visible ones sent it to the end of a list nothing on screen described.
    @Test func anInvisibleEntryKeepsItsSlot() {
        let stored = ["/Volumes/Off", "/Desktop", "/Documents"]
        let moved = ["/Documents", "/Desktop"]
        #expect(SidebarReorder.resplicing(stored, visibleInNewOrder: moved)
                == ["/Volumes/Off", "/Documents", "/Desktop"])
    }

    /// An invisible entry BETWEEN two visible ones is the case an append cannot even approximate.
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

    /// **The state `places(from:)` cannot express, and the write that destroys it.**
    ///
    /// An unreadable value reads as the standard three, which is the right thing to SHOW. What must
    /// not follow is encoding those three back over the key — the loss happens on the write, not on
    /// the read, which is what let the same shape sit in six stores until v4.3 went looking.
    @Test func unreadableBytesAreNotMistakenForAnUntouchedKey() {
        #expect(SidebarFavoritePlaces.isUnreadable("{not json"))
        #expect(SidebarFavoritePlaces.isUnreadable("[1, 2, 3]"),
                "valid JSON of the wrong shape is still bytes this build cannot use")
        #expect(SidebarFavoritePlaces.isUnreadable("\"/Desktop\""),
                "a bare string is not the list this key holds")
    }

    /// The two states that are NOT unreadable, and the ones a salvage must never fire for.
    @Test func absentAndEmptyAreBothReadable() {
        #expect(!SidebarFavoritePlaces.isUnreadable(""), "an untouched key has nothing to salvage")
        #expect(!SidebarFavoritePlaces.isUnreadable("[]"),
                "removing every favorite is a decision, and a decision is readable")
        #expect(!SidebarFavoritePlaces.isUnreadable(SidebarFavoritePlaces.encoded(["/Desktop"])))
    }

    /// `isUnreadable` and `places(from:)` must agree about which values they are each talking
    /// about: everything the first calls unreadable is a value the second answers `standard` for,
    /// which is precisely the overlap that makes the write dangerous.
    @Test func everyUnreadableValueReadsAsTheStandardThree() {
        for raw in ["{not json", "[1, 2, 3]", "\"/Desktop\""] {
            #expect(SidebarFavoritePlaces.isUnreadable(raw))
            #expect(SidebarFavoritePlaces.places(from: raw) == SidebarFavoritePlaces.standard,
                    "“\(raw)” reads as something other than the first-run answer")
        }
    }

    /// Round-tripping is what makes the salvage recoverable rather than merely preserved.
    @Test func anEncodedListDecodesBackToItself() {
        let places = ["/Users/x/Desktop", "/Volumes/Off/Notes"]
        #expect(SidebarFavoritePlaces.places(from: SidebarFavoritePlaces.encoded(places)) == places)
    }
}
