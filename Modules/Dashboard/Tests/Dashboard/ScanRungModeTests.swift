import Testing
import Design
@testable import Dashboard

/// The scan rung's two-actions-one-control table. Everything that differs between Scan and Stop is
/// asserted together, because the way this breaks is one of them being updated and the others not.
@Suite struct ScanRungModeTests {

    // MARK: Which mode

    @Test func testIdleIsAlwaysScan() {
        #expect(ScanRungMode.resolve(isRefreshing: false, canCancel: true) == .scan)
        #expect(ScanRungMode.resolve(isRefreshing: false, canCancel: false) == .scan)
    }

    /// The regression guard for every caller outside the app. `PaneHeader` gained `onCancelScan`
    /// with a `nil` default, and a header that was not given one must keep the disabled spinner it
    /// has always had — otherwise adding the parameter silently changed everyone else's rung.
    @Test func testAHostThatOffersNoCancelKeepsTheOldDisabledSpinner() {
        let mode = ScanRungMode.resolve(isRefreshing: true, canCancel: false)
        #expect(mode == .busy)
        #expect(!mode.isEnabled)
        #expect(mode.spins)
        #expect(mode.symbol == "arrow.clockwise")
    }

    @Test func testAHostThatOffersCancelGetsALiveStop() {
        let mode = ScanRungMode.resolve(isRefreshing: true, canCancel: true)
        #expect(mode == .stop)
        #expect(mode.isEnabled, "a Stop nobody can press is the bug this replaces")
    }

    // MARK: What each mode presents

    /// Scan and Stop are two different actions on one control, so every fact the user reads has to
    /// distinguish them — a rung showing a stop sign while its tooltip offers ⌘R is the mismatch
    /// this type exists to prevent. They agree on the two facts that are about *availability*
    /// rather than identity: both are live, and neither spins (only `.busy` does).
    @Test func testScanAndStopDifferInEveryFactTheUserReads() {
        let scan = ScanRungMode.scan
        let stop = ScanRungMode.stop
        #expect(scan.symbol != stop.symbol)
        #expect(scan.label != stop.label)
        #expect(scan.help != stop.help)
        #expect(scan.keycap != stop.keycap)
        #expect(scan.isEnabled && stop.isEnabled)
        #expect(!scan.spins && !stop.spins)
    }

    /// ⌘R starts a scan; it does not stop one. A badge on the Stop rung would advertise a chord
    /// that does something else — and `shortcutKeycap` withholds the VoiceOver hint with it.
    @Test func testOnlyTheScanFormCarriesTheRescanChord() {
        #expect(ScanRungMode.scan.keycap == AppChord.rescan.display)
        #expect(ScanRungMode.busy.keycap == AppChord.rescan.display)
        #expect(ScanRungMode.stop.keycap == nil)
        // ...and the tooltip agrees with the badge, which is the pair that used to be hand-copied.
        #expect(ScanRungMode.scan.help.contains(AppChord.rescan.display))
        #expect(!ScanRungMode.stop.help.contains(AppChord.rescan.display))
    }

    /// The glyph and the animation have to agree: a spinning stop sign is not a thing, and a
    /// static arrow during a scan says nothing is happening.
    @Test func testOnlyTheSpinningModeIsTheArrow() {
        #expect(ScanRungMode.busy.spins)
        #expect(!ScanRungMode.stop.spins)
        #expect(!ScanRungMode.scan.spins, "an idle rung must not spin")
        #expect(ScanRungMode.stop.symbol == "stop.circle")
    }

    /// The spoken label never says "Scan" on a control that cancels. VoiceOver has no glyph to
    /// disambiguate it, so this is the only carrier of the difference for that user.
    @Test func testTheSpokenLabelNamesWhatThePressWillDo() {
        #expect(ScanRungMode.stop.label == "Stop scanning")
        #expect(ScanRungMode.scan.label == "Scan for changes")
        #expect(ScanRungMode.busy.label == "Scan for changes")
    }
}
