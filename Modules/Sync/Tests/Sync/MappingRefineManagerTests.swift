import Foundation
import Testing
@testable import Sync

/// The mapping refine's manager gate: the route is a hard gate (naming has no on-device fallback,
/// and the transport reads the Keychain directly, so it must never be reached around the router),
/// the price is shown beside the button before anything is sent, and over the limit is its own outcome.
@MainActor
@Suite struct MappingRefineManagerTests {

    private final class Calls: @unchecked Sendable {
        var refined = 0
    }

    private static let request = MappingRefineRequest(
        family: "F", members: ["2016"],
        rows: [.init(source: "Petition", target: nil)],
        candidateVocabularies: [["application"]])

    private func makeManager(route: String, calls: Calls) -> FileSyncManager {
        let manager = FileSyncManager()
        manager.filingBackendIdentity = { _ in route }
        manager.filingContentDefaults = ScratchDefaults("MappingRefineManagerTests")
        manager.mappingRefiner = { _ in
            calls.refined += 1
            return [MappingRefineProposal(source: "Petition",
                                          verdict: .propose(target: "Application"), why: "w")]
        }
        return manager
    }

    /// Cloud off (or no usable key) means the pass doesn't run at all: a stored key must not be
    /// billed around the router, and there's no on-device model to fall back to.
    @Test func aNonCloudRouteIsAHardGateAndSendsNothing() async {
        let calls = Calls()
        let manager = makeManager(route: "device:apple-fm", calls: calls)
        let outcome = await manager.refineMapping(Self.request)
        #expect(outcome == .unavailable)
        #expect(calls.refined == 0, "the transport was reached around the router")
        #expect(manager.mappingRefineQuote(for: Self.request) == nil, "and there is no price to show")
    }

    /// There is no dialog: the sheet shows the quote beside its button and the click is the consent,
    /// so a pass under the limit runs, and its proposals come back whole.
    @Test func aPassUnderTheLimitRunsTheTransportWithNoDialog() async {
        let calls = Calls()
        let manager = makeManager(route: "cloud:claude", calls: calls)
        manager.filingCloudRefineConfigured = { true }
        manager.filingCloudSpendConfirmer = { _ in
            Issue.record("the old dialog was asked")
            return false
        }
        let outcome = await manager.refineMapping(Self.request)
        #expect(calls.refined == 1)
        #expect(outcome == .proposals([
            MappingRefineProposal(source: "Petition",
                                  verdict: .propose(target: "Application"), why: "w"),
        ]))
    }

    /// The quote counts folder names on the chat's model, against Ask Claude's one limit and this
    /// month's total, the chat's spend included.
    @Test func theQuoteIsThePriceBesideTheButton() {
        let manager = makeManager(route: "cloud:claude", calls: Calls())
        manager.filingCloudRefineConfigured = { true }
        manager.filingContentDefaults.set(10.0, forKey: AskClaudeSpend.limitDefaultsKey)
        AskClaudeSpend.record(3.0, in: manager.filingContentDefaults)
        let quote = manager.mappingRefineQuote(for: Self.request)
        #expect(quote?.costUSD ?? 0 > 0 && quote?.spentUSD == 3.0 && quote?.limitUSD == 10.0)
        #expect(quote?.exceedsLimit == false)
        #expect(quote?.modelName == manager.filingRefineModelName)
    }

    /// Over the limit is the budget saying no: nothing is sent, and it is its own outcome, so the
    /// sheet can say the limit rather than "check your key".
    @Test func aPassOverTheLimitSendsNothingAndSaysTheLimit() async {
        let calls = Calls()
        let manager = makeManager(route: "cloud:claude", calls: calls)
        manager.filingCloudRefineConfigured = { true }
        manager.filingContentDefaults.set(0.000_000_1, forKey: AskClaudeSpend.limitDefaultsKey)
        #expect(manager.mappingRefineQuote(for: Self.request)?.exceedsLimit == true, "the fixture must actually be over")
        let outcome = await manager.refineMapping(Self.request)
        #expect(outcome == .overLimit)
        #expect(calls.refined == 0)
    }

    /// The receipt is what the request added to Organize's share, which the transport records
    /// whether or not it finished.
    @Test func eachRequestIsReportedWithWhatItCost() async {
        let calls = Calls()
        let manager = makeManager(route: "cloud:claude", calls: calls)
        manager.filingCloudRefineConfigured = { true }
        nonisolated(unsafe) let defaults = manager.filingContentDefaults
        manager.mappingRefiner = { _ in
            AskClaudeSpend.recordOrganize(0.012, in: defaults)
            return nil   // a request that failed after it started still cost something
        }
        var reports: [FileSyncManager.MappingRefineReport] = []
        manager.filingMappingRefineReports = { reports.append($0) }
        let outcome = await manager.refineMapping(Self.request)
        #expect(outcome == .unavailable)
        #expect(reports.count == 1 && reports.first?.answered == false)
        #expect(abs((reports.first?.costUSD ?? 0) - 0.012) < 1e-9)
        #expect(reports.first?.folderNames == 1 && reports.first?.fileNames == 0)
    }

    /// Staleness is a coverage question, not an emptiness one: a clean scan of the surveyed root
    /// covers it with zero groups, and a scan of another root covers nothing however many groups it
    /// left. `duplicateGroups.isEmpty` gets both wrong.
    @Test func scanCoverageIsAboutTheRootNotTheGroupCount() {
        let manager = FileSyncManager()
        manager.filingFolderProfile = FolderProfile(profileId: "p", root: "/tree",
                                                    folders: [:], personTokens: [])
        #expect(!manager.duplicateScanCoversSurvey, "no scan has run")

        manager.duplicateScanRoot = "/tree"
        #expect(manager.duplicateScanCoversSurvey,
                "a finished scan of the surveyed root covers it — zero groups included")

        manager.duplicateScanRoot = "/elsewhere"
        #expect(!manager.duplicateScanCoversSurvey,
                "groups from an unrelated root say nothing about the survey's tree")

        // A rescan doesn't flicker the answer off: the lifecycle publishes the root with results,
        // so a non-nil root always labels what is on screen, mid-rescan included.
        manager.duplicateScanRoot = "/tree"
        manager.isFindingDuplicates = true
        #expect(manager.duplicateScanCoversSurvey,
                "the previous results stay covered while their replacement runs")
    }
}
