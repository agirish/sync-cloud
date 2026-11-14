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

    /// Guards callers outside the app: `onCancelScan` defaults to `nil`, and a header not given one
    /// keeps the disabled spinner, so callers that never opt in see no change.
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

    /// Scan and Stop are two actions on one control, so every fact the user reads must tell them
    /// apart; a stop sign whose tooltip offers ⌘R is the mismatch to prevent. They agree only on
    /// availability: both are live, and neither spins (only `.busy` does): a spinning stop sign is
    /// not a thing.
    @Test func testScanAndStopDifferInEveryFactTheUserReads() {
        let scan = ScanRungMode.scan
        let stop = ScanRungMode.stop
        #expect(scan.symbol != stop.symbol)
        #expect(scan.isEnabled && stop.isEnabled)
        #expect(!scan.spins && !stop.spins)
        #expect(stop.symbol == "stop.circle")
    }

    /// ⌘R starts a scan; it does not stop one. A badge on the Stop rung would advertise a chord
    /// that does something else — and `shortcutKeycap` withholds the VoiceOver hint with it.
    @Test func testOnlyTheScanFormCarriesTheRescanChord() {
        #expect(ScanRungMode.scan.keycap == AppChord.rescan.display)
        #expect(ScanRungMode.busy.keycap == AppChord.rescan.display)
        #expect(ScanRungMode.stop.keycap == nil)
        // ...and the tooltip agrees with the badge.
        #expect(ScanRungMode.scan.help.contains(AppChord.rescan.display))
        #expect(!ScanRungMode.stop.help.contains(AppChord.rescan.display))
    }

    /// The spoken label never says "Scan" on a control that cancels. VoiceOver has no glyph to
    /// disambiguate it, so this is the only carrier of the difference for that user.
    @Test func testTheSpokenLabelNamesWhatThePressWillDo() {
        #expect(ScanRungMode.stop.label == "Stop scanning")
        #expect(ScanRungMode.scan.label == "Scan for changes")
        #expect(ScanRungMode.busy.label == "Scan for changes")
    }
}
