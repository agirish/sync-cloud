import Testing
@testable import FileExplorer

/// TE287: a scope To File never read says so, rather than "Nothing in “Downloads”" or "Nothing
/// loose to file" over a folder nobody looked at. Seen on his Mac: scoped to iCloud ▸ Downloads,
/// twenty loose files, after a scan of Documents ▸ Finance.
@Suite struct FilingNotScannedHereTests {

    private func state(rows: Int = 0, suggestions: Int, scoped: Bool = true, scanned: Bool) -> LensWorkspaceView.FilingContentState {
        LensWorkspaceView.filingContentState(isScanning: false, showsSetup: false, rowsShown: rows,
                                             suggestions: suggestions, scopeIsSet: scoped,
                                             scopeWasScanned: scanned)
    }

    /// The screenshot's case: Finance's one card, none under Downloads.
    @Test func aScopeTheLastScanDidNotReadSaysItWasNotScanned() {
        #expect(state(suggestions: 1, scanned: false) == .notScannedHere)
    }

    /// …and with nothing at all from the last scan, which would otherwise read "Nothing loose".
    @Test func evenWhenTheLastScanFoundNothing() {
        #expect(state(suggestions: 0, scanned: false) == .notScannedHere)
    }

    /// The controls: the same scope, scanned, keeps the answers it had.
    @Test func aScannedScopeKeepsItsOwnAnswers() {
        #expect(state(suggestions: 0, scanned: true) == .clean)
        #expect(state(suggestions: 3, scanned: true) == .hidden)
        #expect(state(rows: 2, suggestions: 3, scanned: true) == .list)
        #expect(state(suggestions: 3, scoped: false, scanned: true) == .hidden)
    }

    /// Rows on screen win: a scope that holds results is showing them, whatever coverage says.
    @Test func rowsOnScreenAreShown() {
        #expect(state(rows: 1, suggestions: 1, scanned: false) == .list)
    }

    @Test func scanningAndSetupComeFirst() {
        #expect(LensWorkspaceView.filingContentState(isScanning: true, showsSetup: true, rowsShown: 0, suggestions: 0,
                                                     scopeIsSet: true, scopeWasScanned: false) == .scanning)
        #expect(LensWorkspaceView.filingContentState(isScanning: false, showsSetup: true, rowsShown: 0, suggestions: 0,
                                                     scopeIsSet: true, scopeWasScanned: false) == .setup)
    }
}
