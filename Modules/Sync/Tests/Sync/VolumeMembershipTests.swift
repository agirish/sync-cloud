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

    /// (path, volume, whether the path is on it, why).
    static let membership: [(path: String, volume: String, isOn: Bool, why: String)] = [
        (card, card, true, "the mount point itself is on the volume"),
        ("\(card)/DCIM/100MSDCF", card, true, "a folder inside is on the volume"),
        // Two cards in two readers named `CARD` and `CARD 2`: ejecting the first must not take the
        // second's sources with it.
        ("/Volumes/CARD 2/DCIM", card, false, "a volume whose name merely starts the same is not on it"),
        ("/Volumes/CARDBOARD", card, false, "a volume whose name merely starts the same is not on it"),
        ("~/Downloads", card, false, "a folder elsewhere is not on the volume"),
        // `/` is refused, which keeps an unmount from emptying the app: every path is under `/`, so
        // a root volume argument would claim every source on the machine, `~/Downloads` included.
        ("~/Downloads", "/", false, "the root is never a volume for this purpose"),
        ("/", "/", false, "the root is never a volume for this purpose"),
        ("/Volumes/CARD", "/", false, "the root is never a volume for this purpose"),
        // The other way that could happen: a notification without a path, or a caller reading a
        // field that wasn't there.
        ("~/Downloads", "", false, "an empty volume claims nothing"),
        ("/Volumes/CARD", "", false, "an empty volume claims nothing"),
        // `/Volumes` is on the boot volume, case-insensitive by default, so the two spellings name
        // one mount point, and a card's row built from one must not survive an eject reported in
        // the other.
        ("/volumes/card/DCIM", card, true, "the mount point is case-folded"),
        // Both spellings really do occur: a provider Location is user-settable and arrives spelled
        // however it was typed.
        ("\(card)/", card, true, "a trailing slash on the path is the same volume"),
        (card, "\(card)/", true, "a trailing slash on the volume is the same volume"),
    ]

    @Test(arguments: membership)
    func isOnVolume(_ c: (path: String, volume: String, isOn: Bool, why: String)) {
        #expect(FolderSource.isOnVolume(c.path, volume: c.volume) == c.isOn, "\(c.why): \(c.path) on \(c.volume)")
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
}
