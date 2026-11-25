import Foundation
import Testing
@testable import Sync

/// The Vault's lock session as a plain value (VT7 a): what each end of access does to the lock
/// and its epoch, and when the numbers go. No model, store or clock.
@Suite struct VaultSessionTests {
    static let t0 = VaultRig.t0

    /// A session whose Vault was opened by a proof at `t0`, under `settings`.
    static func open(_ settings: VaultLockSettings = VaultLockSettings()) -> VaultSession {
        var session = VaultSession(lock: VaultLock(settings: settings))
        session.lock.proved(at: t0)
        return session
    }

    @Test func everyEndOfAccessSpendsTheProofsAskedForBeforeIt() {
        var session = Self.open()
        let asked = session.epoch
        #expect(session.stands(asked))
        session.lockAll()
        #expect(!session.stands(asked), "an answer given after Lock Now opens nothing")
        #expect(!session.lock.isOpen(at: Self.t0))
        let again = session.epoch
        session.panelOpened()
        #expect(session.stands(again), "the panel coming up is not an end of access")
        session.panelClosed()
        #expect(!session.stands(again), "closing is")
    }

    @Test func closingLocksOnlyWhereItsSettingSaysSo() {
        var closes = Self.open(VaultLockSettings(relock: .whenClosed))
        closes.panelOpened()
        closes.panelClosed()
        #expect(!closes.panelUp)
        #expect(!closes.lock.isOpen(at: Self.t0))
        var stays = Self.open(VaultLockSettings(relock: .afterTenMinutes))
        stays.panelClosed()
        #expect(stays.lock.isOpen(at: Self.t0), "“even if closed” stays open until its ten minutes pass")
    }

    @Test func theNumbersGoOnceLockedOrWhenAReadEnds() {
        var session = Self.open()
        let r201 = session.releasesNow(reading: false, at: Self.t0)
        #expect(!r201, "open: nothing goes")
        session.lockAll()
        let r202 = session.releasesNow(reading: false, at: Self.t0)
        #expect(r202)
        // A read going on keeps them to seal what it read, and lets them go as it ends.
        let r203 = session.releasesNow(reading: true, at: Self.t0)
        #expect(!r203)
        #expect(session.releaseAfterReading)
        let r204 = session.releasesAfterRead(sealed: false, at: Self.t0)
        #expect(r204)
        #expect(!session.releaseAfterReading)
        let r205 = session.releasesAfterRead(sealed: false, at: Self.t0)
        #expect(!r205, "once")
    }

    @Test func aPanelOpenedAgainHoldsWhatAReadKeptPastTheClose() {
        var session = Self.open()
        session.lockAll()
        _ = session.releasesNow(reading: true, at: Self.t0)
        session.panelOpened()
        #expect(!session.releaseAfterReading)
        // Opened again, the panel shows only its lock: what was read into goes as the read ends
        // when something is sealed behind it.
        let r206 = session.releasesAfterRead(sealed: false, at: Self.t0)
        #expect(!r206)
        let r207 = session.releasesAfterRead(sealed: true, at: Self.t0)
        #expect(r207)
        session.lock.proved(at: Self.t0)
        let r208 = session.releasesAfterRead(sealed: true, at: Self.t0)
        #expect(!r208, "not while it is open")
    }

    @Test func aReadEndingWithThePanelDownLetsGoOnlyWhatALockKeptForIt() {
        var session = Self.open()
        session.lockAll()
        let down = session.releasesAfterRead(sealed: true, at: Self.t0)
        #expect(!down, "nothing was drawn for it to let go")
    }

    @Test func aStoppedReadLeavesNothingWaiting() {
        var session = Self.open()
        session.lockAll()
        _ = session.releasesNow(reading: true, at: Self.t0)
        session.readStopped()
        #expect(!session.releaseAfterReading)
    }

    @Test func useOfThePanelIsTakenAtMostOnceASecond() {
        var session = Self.open()
        let r210 = session.panelActivity(at: Self.t0)
        #expect(r210)
        let r1 = session.panelActivity(at: Self.t0.addingTimeInterval(0.5))
        #expect(!r1)
        let r2 = session.panelActivity(at: Self.t0.addingTimeInterval(0.99))
        #expect(!r2)
        let r3 = session.panelActivity(at: Self.t0.addingTimeInterval(1))
        #expect(r3)
        let r4 = session.panelActivity(at: Self.t0.addingTimeInterval(1.5))
        #expect(!r4, "counted from the last one taken")
    }
}
