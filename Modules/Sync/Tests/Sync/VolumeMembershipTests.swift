import Foundation
import Testing
@testable import Sync

/// **Which sources live on a volume** — the one rule behind both "follow the rename" and "forget it
/// on eject", extracted because the two got the same three details wrong independently.
///
/// `VolumeRenameTests` covers the rewriting; this covers membership, which is what decides what an
/// unmount takes with it. The stakes are not symmetric and that is why the boundary cases have
/// tests of their own: a missed source leaves a dimmed row the user can remove by hand, while a
/// wrongly-claimed one silently destroys a name override, a landing folder and an enabled flag.
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

    /// **The case an eject would otherwise get catastrophically wrong.** Two cards in two readers
    /// named `CARD` and `CARD 2`: ejecting the first must not take the second's sources with it.
    @Test func aVolumeWhoseNameMerelyStartsTheSameIsNotOnIt() {
        #expect(!FolderSource.isOnVolume("/Volumes/CARD 2/DCIM", volume: Self.card))
        #expect(!FolderSource.isOnVolume("/Volumes/CARDBOARD", volume: Self.card))
    }

    @Test func aFolderElsewhereIsNotOnTheVolume() {
        #expect(!FolderSource.isOnVolume("~/Downloads", volume: Self.card))
    }

    /// **`/` is refused, and this is the assertion that keeps an unmount from emptying the app.**
    /// Every path is under `/`, so a volume argument that slipped through as the root would claim
    /// every source on the machine — including `~/Downloads` and the home folder.
    @Test func theRootIsNeverAVolumeForThisPurpose() {
        #expect(!FolderSource.isOnVolume("~/Downloads", volume: "/"))
        #expect(!FolderSource.isOnVolume("/", volume: "/"))
        #expect(!FolderSource.isOnVolume("/Volumes/CARD", volume: "/"))
    }

    /// An empty volume string is the other way that could happen — a notification that arrived
    /// without a path, or a caller reading a field that was not there.
    @Test func anEmptyVolumeClaimsNothing() {
        #expect(!FolderSource.isOnVolume("~/Downloads", volume: ""))
        #expect(!FolderSource.isOnVolume("/Volumes/CARD", volume: ""))
    }

    /// `/Volumes` is on the boot volume, which is case-insensitive by default, so the two spellings
    /// name one mount point — and a card whose row was built from one spelling must not survive an
    /// eject reported in the other.
    @Test func theMountPointIsCaseFolded() {
        #expect(FolderSource.isOnVolume("/volumes/card/DCIM", volume: Self.card))
    }

    /// A trailing slash on either side is the same volume. Both spellings really do occur: a
    /// provider Location is user-settable and arrives spelled however it was typed.
    @Test func aTrailingSlashOnEitherSideIsTheSameVolume() {
        #expect(FolderSource.isOnVolume("\(Self.card)/", volume: Self.card))
        #expect(FolderSource.isOnVolume(Self.card, volume: "\(Self.card)/"))
    }

    /// **A volume whose name case-folds to a different byte length still cuts in the right place.**
    ///
    /// `repathed` matches on lowercased forms and then drops `mount.count` Characters off the
    /// ORIGINAL, which is only safe if lowercasing preserves the Character count — and `İ` is the
    /// standard counterexample at the *scalar* level (`/Volumes/İST` goes 12 scalars to 13). It is
    /// not one at the Character level, because `String.count` counts grapheme clusters and case
    /// mapping stays inside one: a scan of U+0000…U+2FFFF found no scalar whose lowercase form has
    /// a different Character count. This pins the conclusion so the next reader does not have to
    /// re-derive it from the same wrong intuition.
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
