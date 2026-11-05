import Foundation
import Testing
import Sync
@testable import Dashboard

/// What the app knew about a volume while it was mounted, the only way to answer what an unmount
/// asks once the volume is gone. The rule is asymmetric on purpose: a source wrongly kept is a
/// dimmed row the user can remove, but one wrongly removed loses a name override, a landing folder
/// and an enabled flag for good. So anything unproven answers `false`, and these tests pin that
/// direction as well as the happy path.
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

    /// A network share ejects (Finder gives it an eject arrow), so a removable-or-ejectable test
    /// alone would read a Wi-Fi drop as a pulled card. A share comes back, and its sources must
    /// still be there when it does.
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

    /// Unknown means leave it alone. A volume never seen mounted (the app launched after it went, or
    /// a path nothing recorded) can't be answered, and `true` would delete sources on a guess.
    @Test func aVolumeNeverSeenIsNotDetachable() {
        let m = memory()
        #expect(m.count == 0)
        #expect(!m.isDetachable(volume: "/Volumes/CARD"))
    }

    /// A forgotten volume is unknown again. `forget` runs on every unmount, and macOS can repeat the
    /// notification for the same path, which must not act on a stale record of a card long gone.
    @Test func forgettingAVolumeMakesItUnknownAgain() {
        let m = memory()
        m.record(Self.card, forVolume: "/Volumes/CARD")
        m.forget(volume: "/Volumes/CARD")
        #expect(m.count == 0)
        #expect(!m.isDetachable(volume: "/Volumes/CARD"))
    }

    /// The walk that records a mount point and the notification that reads it back can spell it
    /// differently, by a trailing slash or by case.
    @Test func aVolumeIsFoundWhicheverWayItsPathIsSpelled() {
        let m = memory()
        m.record(Self.card, forVolume: "/Volumes/CARD/")
        #expect(m.isDetachable(volume: "/Volumes/CARD"))
        #expect(m.count == 1, "the trailing slash made a second entry")
    }

    /// Re-recording replaces rather than accumulates: the walk runs on every sidebar refresh, so a
    /// growing map would leak for the whole session.
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

    /// The sidebar's `Volume` feeds this, so it must carry locality through. `isLocal` defaults to
    /// `true`, the safe direction since removability must still agree, so a fixture that says
    /// nothing looks like a card instead of silently exempting itself.
    @Test func theSidebarVolumeCarriesLocality() {
        let card = SidebarSourceModel.Volume(name: "CARD", path: "/Volumes/CARD",
                                             isRemovable: true, isInternal: false)
        #expect(card.isLocal, "the default must be the direction that does NOT exempt a fixture")
        let share = SidebarSourceModel.Volume(name: "Archive", path: "/Volumes/Archive",
                                              isRemovable: true, isInternal: false, isLocal: false)
        #expect(!share.isLocal)
    }
}
