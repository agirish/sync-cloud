import Foundation
import Testing
@testable import Sync

/// Which sources live on a volume: the one rule behind both "follow the rename" and "forget it on
/// eject", shared so the two can't get the boundary cases wrong separately.
///
/// `VolumeRenameTests` covers the rewriting; this covers membership, which decides what an unmount
/// takes with it. The stakes aren't symmetric, so the boundary cases have tests of their own: a
/// missed source leaves a dimmed row the user can remove by hand, while a wrongly claimed one
/// silently destroys a name override, a landing folder and an enabled flag.
@Suite struct VolumeMembershipTests {

    private static let card = "/Volumes/CARD"

    private func source(_ path: String, id: String = UUID().uuidString) -> FolderSource {
        FolderSource(id: FolderSource.idPrefix + id, path: path)
    }

    @Test func theMountPointItselfIsOnTheVolume() {
        #expect(FolderSource.isOnVolume(Self.card, volume: Self.card))
    }

    @Test func aFolderInsideIsOnTheVolume() {
        #expect(FolderSource.isOnVolume("\(Self.card)/DCIM/100MSDCF", volume: Self.card))
    }

    /// Two cards in two readers named `CARD` and `CARD 2`: ejecting the first must not take the
    /// second's sources with it.
    @Test func aVolumeWhoseNameMerelyStartsTheSameIsNotOnIt() {
        #expect(!FolderSource.isOnVolume("/Volumes/CARD 2/DCIM", volume: Self.card))
        #expect(!FolderSource.isOnVolume("/Volumes/CARDBOARD", volume: Self.card))
    }

    @Test func aFolderElsewhereIsNotOnTheVolume() {
        #expect(!FolderSource.isOnVolume("~/Downloads", volume: Self.card))
    }

    /// `/` is refused, which keeps an unmount from emptying the app: every path is under `/`, so a
    /// root volume argument would claim every source on the machine, `~/Downloads` included.
    @Test func theRootIsNeverAVolumeForThisPurpose() {
        #expect(!FolderSource.isOnVolume("~/Downloads", volume: "/"))
        #expect(!FolderSource.isOnVolume("/", volume: "/"))
        #expect(!FolderSource.isOnVolume("/Volumes/CARD", volume: "/"))
    }

    /// An empty volume string is the other way that could happen: a notification without a path,
    /// or a caller reading a field that wasn't there.
    @Test func anEmptyVolumeClaimsNothing() {
        #expect(!FolderSource.isOnVolume("~/Downloads", volume: ""))
        #expect(!FolderSource.isOnVolume("/Volumes/CARD", volume: ""))
    }

    /// `/Volumes` is on the boot volume, case-insensitive by default, so the two spellings name one
    /// mount point, and a card's row built from one must not survive an eject reported in the other.
    @Test func theMountPointIsCaseFolded() {
        #expect(FolderSource.isOnVolume("/volumes/card/DCIM", volume: Self.card))
    }

    /// A trailing slash on either side is the same volume. Both spellings really do occur: a
    /// provider Location is user-settable and arrives spelled however it was typed.
    @Test func aTrailingSlashOnEitherSideIsTheSameVolume() {
        #expect(FolderSource.isOnVolume("\(Self.card)/", volume: Self.card))
        #expect(FolderSource.isOnVolume(Self.card, volume: "\(Self.card)/"))
    }

    /// A volume whose name case-folds to a different length still cuts in the right place.
    /// `repathed` matches lowercased forms, then drops `mount.count` Characters off the original,
    /// safe only if lowercasing keeps the Character count. `İ` changes the scalar count
    /// (`/Volumes/İST` goes 12 to 13) but not the Character count: case mapping stays inside one
    /// grapheme cluster, and no scalar in U+0000…U+2FFFF lowercases to a different Character count.
    @Test func aVolumeNameThatCaseFoldsToADifferentLengthStillCutsCorrectly() {
        let card = "/Volumes/İST"
        #expect(card.unicodeScalars.count != card.lowercased().unicodeScalars.count,
                "this fixture no longer exercises a length-changing case fold")
        #expect(card.count == card.lowercased().count, "Characters, not scalars — this is why it is safe")
        #expect(FolderSource.repathed("\(card)/DCIM", whenVolumeMovedFrom: card, to: "/Volumes/NEW")
                == "/Volumes/NEW/DCIM")
    }

    // MARK: What an unmount takes

    @Test func onlyTheSourcesOnThatVolumeAreNamed() {
        let sources = [source("~/Downloads", id: "downloads"),
                       source(Self.card, id: "root"),
                       source("\(Self.card)/DCIM", id: "dcim"),
                       source("/Volumes/CARD 2", id: "other-card")]
        #expect(FolderSource.idsOnVolume(Self.card, in: sources)
                == ["folder:root", "folder:dcim"])
    }

    @Test func anUnmountOfSomethingWithNoSourcesNamesNothing() {
        let sources = [source("~/Downloads", id: "downloads"), source("~/Desktop", id: "desktop")]
        #expect(FolderSource.idsOnVolume(Self.card, in: sources).isEmpty)
    }

    /// The guard above, restated where it would actually do the damage.
    @Test func anUnmountReportedAsTheRootTakesNothing() {
        let sources = [source("~/Downloads", id: "downloads"), source(Self.card, id: "card")]
        #expect(FolderSource.idsOnVolume("/", in: sources).isEmpty)
    }
}
