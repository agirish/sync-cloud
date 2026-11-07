import Testing
import Foundation
@testable import Dashboard

/// Which places sit in Favorites, a stored list the user can change.
@Suite struct SidebarFavoritePlacesTests {

    /// The arrangement a first run gets, in order: home first, where a path starts, then the three
    /// folders you file into. Pinned as a whole list, because `contains` checks would pass on any
    /// shuffle, and a shuffle is what a later edit to `favoriteShortcuts` would produce.
    ///
    /// The startup disk is not among them: a place's section is membership of this list, so
    /// leaving the disk out is what draws it in Locations' device band. Every entry is absolute,
    /// since the list is matched against a row's `absolutePath` through `resolved`, and a relative
    /// one would resolve against the working directory and match nothing.
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

    /// Restore is additive: it must not disturb what the user put there.
    @Test func restoringKeepsWhatIsAlreadyThere() {
        let kept = ["/Volumes/Work"]
        let restored = SidebarFavoritePlaces.restoring(kept)
        #expect(restored.suffix(1) == kept[...])
        #expect(Set(restored).isSuperset(of: SidebarFavoritePlaces.standard))
        #expect(restored.count == SidebarFavoritePlaces.standard.count + 1,
                "a standard folder already present must not be added twice")
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

    private func favorite(_ path: String) -> FolderSidebarRow {
        FolderSidebarRow(group: .pinned, root: "/r", sourceName: "R", relativePath: path,
                         name: (path as NSString).lastPathComponent, detail: nil, isAvailable: true)
    }

    /// The first-run state: standard places and no remembered folder yet. The place rows must be
    /// counted, or the badge and VoiceOver say "0 items" over visible rows.
    @Test func placesAloneAreStillRows() {
        #expect(FolderSidebarModel.favoritesCount(folderRows: [], places: 3) == 3)
    }

    @Test func bothListsAreCounted() {
        let rows = [favorite("A"), favorite("B")]
        #expect(FolderSidebarModel.favoritesCount(folderRows: rows, places: 3) == 5)
    }

    /// Recents share the array and must not be counted into Favorites.
    @Test func aRecentIsNotAFavorite() {
        let recent = FolderSidebarRow(group: .recents, root: "/r", sourceName: "R",
                                      relativePath: "C", name: "C", detail: nil, isAvailable: true)
        #expect(FolderSidebarModel.favoritesCount(folderRows: [favorite("A"), recent], places: 0) == 1)
    }

    /// An empty section draws its invitation, so zero must be reachable, or the invitation would
    /// never show.
    @Test func anEmptySectionCountsZero() {
        #expect(FolderSidebarModel.favoritesCount(folderRows: [], places: 0) == 0)
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

/// Bringing a stored Favorites list forward: `SidebarFavoritePlaces.migrate(defaults:)`.
///
/// `standard` is consulted only when the key has no value, and every install that has drawn the
/// sidebar has one, so a change to the default reaches only first runs unless the migration carries
/// it. Each test is one way a stored list can arrive.
@Suite struct SidebarFavoritePlacesMigrationTests {

    private static let disk = SidebarSourceModel.startupDiskPath

    /// The common case: the old default, which listed the startup disk, stored verbatim.
    @Test func theStartupDiskIsTakenOutOfAStoredList() {
        let defaults = ScratchDefaults("SidebarFavoritePlacesMigration-stored")
        let old = [NSHomeDirectory(), NSHomeDirectory() + "/Desktop", NSHomeDirectory() + "/Documents",
                   NSHomeDirectory() + "/Downloads", Self.disk]
        defaults.set(SidebarFavoritePlaces.encoded(old), forKey: SidebarFavoritePlaces.storageKey)

        #expect(SidebarFavoritePlaces.migrate(defaults: defaults) == .rewritten(removed: [Self.disk]))
        let after = SidebarFavoritePlaces.places(
            from: defaults.string(forKey: SidebarFavoritePlaces.storageKey) ?? "")
        #expect(after == SidebarFavoritePlaces.standard,
                "the stored list did not come forward to the new default")
        #expect(defaults.integer(forKey: SidebarFavoritePlaces.migrationKey)
                == SidebarFavoritePlaces.currentVersion)
    }

    /// Everything the user put there stays, in their order. A migration that reordered the rest
    /// would look like a drag they didn't make.
    @Test func nothingElseInTheListMoves() {
        let defaults = ScratchDefaults("SidebarFavoritePlacesMigration-keeps")
        let stored = ["/Volumes/Work", Self.disk, NSHomeDirectory(), "/Volumes/Archive"]
        defaults.set(SidebarFavoritePlaces.encoded(stored), forKey: SidebarFavoritePlaces.storageKey)

        #expect(SidebarFavoritePlaces.migrate(defaults: defaults) == .rewritten(removed: [Self.disk]))
        #expect(SidebarFavoritePlaces.places(
            from: defaults.string(forKey: SidebarFavoritePlaces.storageKey) ?? "")
                == ["/Volumes/Work", NSHomeDirectory(), "/Volumes/Archive"])
    }

    /// An untouched key is left untouched, not written with `standard`. A first run already gets
    /// the default from `places(from:)`, and writing it here would turn "never decided" into
    /// "decided".
    @Test func aFirstRunIsStampedWithoutBeingWritten() {
        let defaults = ScratchDefaults("SidebarFavoritePlacesMigration-fresh")
        #expect(SidebarFavoritePlaces.migrate(defaults: defaults) == .unchanged)
        #expect(defaults.string(forKey: SidebarFavoritePlaces.storageKey) == nil,
                "nothing to migrate, nothing written")
        #expect(defaults.integer(forKey: SidebarFavoritePlaces.migrationKey)
                == SidebarFavoritePlaces.currentVersion,
                "an unstamped first run would migrate the user's FIRST edit on the next launch")
    }

    /// A list without the disk is a no-op, and must not be reported as a change: the log line would
    /// name a move that didn't happen.
    @Test func aListWithoutTheDiskIsNotRewritten() {
        let defaults = ScratchDefaults("SidebarFavoritePlacesMigration-absent")
        let stored = SidebarFavoritePlaces.encoded([NSHomeDirectory(), "/Volumes/Work"])
        defaults.set(stored, forKey: SidebarFavoritePlaces.storageKey)
        #expect(SidebarFavoritePlaces.migrate(defaults: defaults) == .unchanged)
        #expect(defaults.string(forKey: SidebarFavoritePlaces.storageKey) == stored)
    }

    /// Unreadable bytes are left as they are. `places(from:)` answers `standard` for them, which is
    /// right for a read, but writing that back would encode over the user's real list. Same line
    /// `writeFolderSidebarFavoritePlaces` draws.
    @Test func unreadableBytesAreNotMigratedOver() {
        for raw in ["{not json", "[1,2,3]"] {
            let defaults = ScratchDefaults("SidebarFavoritePlacesMigration-unreadable")
            defaults.set(raw, forKey: SidebarFavoritePlaces.storageKey)
            #expect(SidebarFavoritePlaces.migrate(defaults: defaults) == .unreadable)
            #expect(defaults.string(forKey: SidebarFavoritePlaces.storageKey) == raw,
                    "the migration overwrote bytes it could not read")
        }
    }

    /// It runs once: adding the disk back afterwards must stick, or the user sees their choice
    /// overruled. That is why the version is stamped rather than the list checked.
    @Test func aDiskPutBackAfterwardsStays() {
        let defaults = ScratchDefaults("SidebarFavoritePlacesMigration-putback")
        defaults.set(SidebarFavoritePlaces.encoded(SidebarFavoritePlaces.standard + [Self.disk]),
                     forKey: SidebarFavoritePlaces.storageKey)
        #expect(SidebarFavoritePlaces.migrate(defaults: defaults) == .rewritten(removed: [Self.disk]))

        let putBack = SidebarFavoritePlaces.encoded(SidebarFavoritePlaces.standard + [Self.disk])
        defaults.set(putBack, forKey: SidebarFavoritePlaces.storageKey)
        #expect(SidebarFavoritePlaces.migrate(defaults: defaults) == .unchanged)
        #expect(defaults.string(forKey: SidebarFavoritePlaces.storageKey) == putBack,
                "the migration ran twice and took the disk back out")
    }

    /// Only a rewrite or an unreadable value says anything in the log; a line on every launch would
    /// be noise.
    @Test func onlyARewriteProducesALogLine() {
        #expect(SidebarFavoritePlaces.Outcome.unchanged.logLine == nil)
        #expect(SidebarFavoritePlaces.Outcome.rewritten(removed: ["/"]).logLine?.contains("Locations") == true)
        #expect(SidebarFavoritePlaces.Outcome.unreadable.logLine?.contains("left") == true)
    }
}
