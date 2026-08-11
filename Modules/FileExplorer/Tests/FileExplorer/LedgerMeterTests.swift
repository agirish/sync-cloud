import Testing
@testable import FileExplorer

/// The ledger's reporting/clean split and the meter caption built from it. The derivation rule
/// that could go wrong: `checksReporting` must count only `.findings` among the counted lenses —
/// `clean` is a completed check (it fills a quiet segment), never a reporting one.
@Suite struct LedgerMeterTests {

    private func section(_ lens: OrganizeLens, _ state: OrganizeOverviewState) -> OrganizeOverviewSection {
        OrganizeOverviewSection(lens: lens, blurb: "", state: state, isScanning: false)
    }

    @Test func reportingCountsOnlyFindings() {
        let ledger = OrganizeOverview.Ledger.derived(
            from: [section(.duplicates, .findings(count: 943, headline: "943 groups", examples: [])),
                   section(.renames, .findings(count: 132, headline: "132 folders", examples: [])),
                   section(.toFile, .clean),
                   section(.names, .clean),
                   section(.restructure, .findings(count: 1, headline: "1 finding", examples: []))],
            runnablePasses: Set(OrganizePass.allCases),
            reclaimable: nil, scopeFolders: nil)
        #expect(ledger.checksRun == 5)
        #expect(ledger.checksReporting == 3)
        #expect(ledger.checksClean == 2)
    }

    @Test func aCleanLensIsRunButNotReporting() {
        let ledger = OrganizeOverview.Ledger.derived(
            from: [section(.duplicates, .clean)],
            runnablePasses: Set(OrganizePass.allCases),
            reclaimable: nil, scopeFolders: nil)
        #expect(ledger.checksRun == 1)
        #expect(ledger.checksReporting == 0)
        #expect(ledger.checksClean == 1)
    }

    @Test func captionComposesAbsentPartsRule() {
        // Nothing run: the plain gloss — never "0 reporting".
        #expect(OrganizeOverview.Ledger.meterCaption(run: 0, reporting: 0, clean: 0) == "checks have run")
        // The split, both parts present.
        #expect(OrganizeOverview.Ledger.meterCaption(run: 5, reporting: 2, clean: 3) == "2 reporting · 3 clean")
        // One-sided runs drop the zero side.
        #expect(OrganizeOverview.Ledger.meterCaption(run: 3, reporting: 0, clean: 3) == "3 clean")
        #expect(OrganizeOverview.Ledger.meterCaption(run: 2, reporting: 2, clean: 0) == "2 reporting")
    }
}
