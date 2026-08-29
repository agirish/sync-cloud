import Foundation
import Testing
@testable import Sync

/// **A card renamed in Finder takes its sources with it.**
///
/// Renaming a volume moves its mount point, so a source rooted at `/Volumes/NO NAME` is left naming
/// a path that will never come back. It does not merely go dim — dim is the sidebar's word for "not
/// answering", and a card that is asleep wakes up — so what shipped was a permanently dead row with
/// no verb on it, beside a *second* source for the same card as soon as the user clicked it. Both
/// happened on 2026-08-29, and `~/sync-cloud.log` has the whole sequence six minutes apart.
///
/// Fixture paths are volumes that do not exist on any machine this runs on. That matters:
/// `FolderSource.abbreviated` resolves symlinks, so naming a volume that is really mounted would
/// make the expected value depend on what is plugged into the machine running the suite.
@Suite struct VolumeRenameTests {

    private static let old = "/Volumes/OLD CARD"
    private static let new = "/Volumes/NEW CARD"

    private func source(_ path: String, id: String = UUID().uuidString) -> FolderSource {
        FolderSource(id: FolderSource.idPrefix + id, path: path)
    }

    // MARK: The path rule

    @Test func aSourceAtTheMountPointItselfMoves() {
        #expect(FolderSource.repathed(Self.old, whenVolumeMovedFrom: Self.old, to: Self.new)
                == Self.new)
    }

    /// The interesting half: the mount point is replaced and everything below it is carried over.
    @Test func aSourceInsideTheVolumeKeepsItsSuffix() {
        #expect(FolderSource.repathed("\(Self.old)/DCIM/100MSDCF",
                                      whenVolumeMovedFrom: Self.old, to: Self.new)
                == "\(Self.new)/DCIM/100MSDCF")
    }

    /// **The suffix keeps its own spelling.** `/Volumes` is on the boot volume, which is
    /// case-insensitive, so the mount point is matched case-folded — but the folders below it may
    /// be on a case-sensitive filesystem, where `DCIM` and `dcim` are two directories.
    @Test func theMountPointIsCaseFoldedAndTheSuffixIsNot() {
        #expect(FolderSource.repathed("/volumes/old card/DCIM",
                                      whenVolumeMovedFrom: Self.old, to: Self.new)
                == "\(Self.new)/DCIM")
    }

    /// Prefix matching on a component boundary, not `hasPrefix` — `/Volumes/OLD CARD 2` is a
    /// different volume that happens to start with the same letters, and moving it would repoint a
    /// source at a card nobody renamed.
    @Test func aVolumeWhoseNameMerelyStartsTheSameIsNotMoved() {
        #expect(FolderSource.repathed("/Volumes/OLD CARD 2/DCIM",
                                      whenVolumeMovedFrom: Self.old, to: Self.new) == nil)
    }

    @Test func aSourceSomewhereElseEntirelyIsNotMoved() {
        #expect(FolderSource.repathed("~/Downloads",
                                      whenVolumeMovedFrom: Self.old, to: Self.new) == nil)
    }

    /// The startup disk keeps its mount point through a rename, so a rewrite rooted at `/` would
    /// repoint **every** source on the machine at a `/Volumes/…` path.
    @Test func theStartupDiskIsNeverTreatedAsARenamedVolume() {
        #expect(FolderSource.repathed("~/Downloads", whenVolumeMovedFrom: "/", to: Self.new) == nil)
        #expect(FolderSource.repathed("/", whenVolumeMovedFrom: "/", to: Self.new) == nil)
    }

    /// AppKit posts this notification for a name change **and/or** a mount-path change, so a rename
    /// that left the path alone arrives here with both sides equal and must move nothing.
    @Test func aRenameThatDidNotMoveThePathMovesNothing() {
        #expect(FolderSource.repathed("\(Self.old)/DCIM",
                                      whenVolumeMovedFrom: Self.old, to: Self.old) == nil)
        #expect(FolderSource.repathed("\(Self.old)/DCIM",
                                      whenVolumeMovedFrom: Self.old, to: "\(Self.old)/") == nil)
    }

    // MARK: The list

    @Test func onlyTheSourcesOnTheRenamedVolumeMove() {
        let onCard = source("\(Self.old)/DCIM", id: "card")
        let elsewhere = source("~/Downloads", id: "downloads")
        let plan = FolderSource.following(volumeRenameFrom: Self.old, to: Self.new,
                                          in: [elsewhere, onCard])
        #expect(plan.moved == [onCard.id])
        #expect(plan.absorbed.isEmpty)
        #expect(plan.sources.map(\.path) == ["~/Downloads", "\(Self.new)/DCIM"])
    }

    /// **Two sources on one card both move, and neither eats the other.** The rewrite is a prefix
    /// substitution, so it cannot map two folders onto one — the collision check must not fire
    /// here, or renaming a card with a root source and a nested one would silently drop one of them.
    @Test func twoSourcesOnTheSameVolumeBothSurvive() {
        let root = source(Self.old, id: "root")
        let nested = source("\(Self.old)/DCIM", id: "nested")
        let plan = FolderSource.following(volumeRenameFrom: Self.old, to: Self.new,
                                          in: [root, nested])
        #expect(plan.absorbed.isEmpty)
        #expect(plan.moved.count == 2)
        #expect(plan.sources.map(\.path) == [Self.new, "\(Self.new)/DCIM"])
    }

    /// **The reported case.** The card was renamed while the stale source was still listed, the
    /// user clicked the card's new row, and the app added a second source for it — so following the
    /// rename now would put two rows on one folder, which is the invariant `addFolderSource`
    /// exists to keep. The stale one goes; the one the user just added is the row they are looking
    /// at, and it carries whatever they have done to it since.
    @Test func aStaleSourceIsDroppedWhenItsFolderIsAlreadyAnotherSource() {
        let stale = source(Self.old, id: "stale")
        let readded = source(Self.new, id: "readded")
        let plan = FolderSource.following(volumeRenameFrom: Self.old, to: Self.new,
                                          in: [stale, readded])
        #expect(plan.absorbed == [stale.id])
        #expect(plan.moved.isEmpty)
        #expect(plan.sources.map(\.id) == [readded.id])
    }

    /// The same, with the re-added source listed FIRST — the order sources are actually added in,
    /// and the one an implementation that only looked at what it had built so far would get wrong.
    @Test func theStaleSourceIsDroppedWhicheverOrderTheTwoAreIn() {
        let readded = source(Self.new, id: "readded")
        let stale = source(Self.old, id: "stale")
        let plan = FolderSource.following(volumeRenameFrom: Self.old, to: Self.new,
                                          in: [readded, stale])
        #expect(plan.absorbed == [stale.id])
        #expect(plan.sources.map(\.id) == [readded.id])
    }

    @Test func aRenameWithNothingOnTheVolumeChangesNothing() {
        let sources = [source("~/Downloads", id: "a"), source("~/Desktop", id: "b")]
        let plan = FolderSource.following(volumeRenameFrom: Self.old, to: Self.new, in: sources)
        #expect(plan.moved.isEmpty)
        #expect(plan.absorbed.isEmpty)
        #expect(plan.sources == sources)
    }
}
