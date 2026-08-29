import Foundation
import Testing
import Sync
@testable import Dashboard

/// **What the app knew about a volume while it was mounted**, which is the only way to answer the
/// question an unmount asks after the answer has gone.
///
/// The rule this guards is asymmetric on purpose. Failing to remove a source leaves a dimmed row
/// the user can remove by hand; removing one wrongly destroys a name override, a landing folder and
/// an enabled flag that nothing can hand back. So `false` is the answer for anything unproven, and
/// these tests pin that direction rather than only the happy path.
@Suite @MainActor struct MountedVolumeMemoryTests {

    private func memory() -> MountedVolumeMemory { MountedVolumeMemory() }

    private static let card = MountedVolumeMemory.Facts(isRemovable: true, isLocal: true)
    private static let share = MountedVolumeMemory.Facts(isRemovable: true, isLocal: false)
    private static let bootDisk = MountedVolumeMemory.Facts(isRemovable: false, isLocal: true)

    @Test func aLocalRemovableVolumeIsDetachable() {
        let m = memory()
        m.record(Self.card, forVolume: "/Volumes/CARD")
        #expect(m.isDetachable(volume: "/Volumes/CARD"))
    }

    /// **The guard that earns the whole type.** A network share is *ejectable* — Finder draws it an
    /// eject arrow — so a removable-or-ejectable test alone reads a Wi-Fi drop as a card being
    /// pulled. A share comes back; the sources on it must still be there when it does.
    @Test func aNetworkShareIsNotDetachableEvenThoughItEjects() {
        let m = memory()
        m.record(Self.share, forVolume: "/Volumes/Archive")
        #expect(!m.isDetachable(volume: "/Volumes/Archive"))
    }

    @Test func anInternalDiskIsNotDetachable() {
        let m = memory()
        m.record(Self.bootDisk, forVolume: "/")
        #expect(!m.isDetachable(volume: "/"))
    }

    /// **Unknown means leave it alone.** A volume that unmounted having never been seen mounted —
    /// the app launched after it was already gone, or a path arrived that nothing recorded — is a
    /// question this could not answer, and answering `true` would delete sources on a guess.
    @Test func aVolumeNeverSeenIsNotDetachable() {
        let m = memory()
        #expect(m.count == 0)
        #expect(!m.isDetachable(volume: "/Volumes/CARD"))
    }

    /// **A volume it knew about but has since forgotten is unknown again**, which matters because
    /// `forget` runs on every unmount: a second unmount notification for the same path (macOS does
    /// repeat them) must not act on a stale record naming a card that is long gone.
    @Test func forgettingAVolumeMakesItUnknownAgain() {
        let m = memory()
        m.record(Self.card, forVolume: "/Volumes/CARD")
        m.forget(volume: "/Volumes/CARD")
        #expect(m.count == 0)
        #expect(!m.isDetachable(volume: "/Volumes/CARD"))
    }

    /// Trailing slashes and case are the two ways the same mount point arrives spelled differently
    /// — the walk that records it and the notification that reads it back are different sources.
    @Test func aVolumeIsFoundWhicheverWayItsPathIsSpelled() {
        let m = memory()
        m.record(Self.card, forVolume: "/Volumes/CARD/")
        #expect(m.isDetachable(volume: "/Volumes/CARD"))
        #expect(m.count == 1, "the trailing slash made a second entry")
    }

    /// Re-recording replaces rather than accumulating: the walk runs on every sidebar refresh, and
    /// a map that grew per refresh would be a leak the size of the session.
    @Test func recordingTheSameVolumeTwiceKeepsOneEntry() {
        let m = memory()
        m.record(Self.card, forVolume: "/Volumes/CARD")
        m.record(Self.share, forVolume: "/Volumes/CARD")
        #expect(m.count == 1)
        #expect(!m.isDetachable(volume: "/Volumes/CARD"), "the later record did not win")
    }

    @Test func awalkIsRecordedWhole() {
        let m = memory()
        m.record([(path: "/Volumes/CARD", facts: Self.card),
                  (path: "/Volumes/Archive", facts: Self.share)])
        #expect(m.count == 2)
        #expect(m.isDetachable(volume: "/Volumes/CARD"))
        #expect(!m.isDetachable(volume: "/Volumes/Archive"))
    }

    /// The sidebar's `Volume` is what the walk produces and what feeds this, so its new flag has to
    /// carry the two facts through. `isLocal` defaults to `true` — the safe direction, since
    /// removability still has to agree — and a fixture that says nothing must therefore look like a
    /// card rather than silently exempting itself.
    @Test func theSidebarVolumeCarriesLocality() {
        let card = SidebarSourceModel.Volume(name: "CARD", path: "/Volumes/CARD",
                                             isRemovable: true, isInternal: false)
        #expect(card.isLocal, "the default must be the direction that does NOT exempt a fixture")
        let share = SidebarSourceModel.Volume(name: "Archive", path: "/Volumes/Archive",
                                              isRemovable: true, isInternal: false, isLocal: false)
        #expect(!share.isLocal)
    }
}
