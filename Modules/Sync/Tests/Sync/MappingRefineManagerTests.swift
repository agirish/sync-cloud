import Foundation
import Testing
@testable import Sync

/// §5.6's manager gate: the route is a HARD gate (naming has no on-device fallback, and the
/// transport reads the Keychain directly — it must never be reached around the router), the
/// estimate is shown before anything is sent, and declined is its own outcome.
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
        manager.filingContentDefaults = UserDefaults(
            suiteName: "MappingRefineManagerTests-\(UUID().uuidString)")!
        manager.mappingRefiner = { _ in
            calls.refined += 1
            return [MappingRefineProposal(source: "Petition",
                                          verdict: .propose(target: "Application"), why: "w")]
        }
        return manager
    }

    /// Cloud off (or no usable key) means the pass does not run AT ALL — a stored key must not
    /// be billed around the router, and there is no on-device model to fall back to.
    @Test func aNonCloudRouteIsAHardGateAndSendsNothing() async {
        let calls = Calls()
        let manager = makeManager(route: "device:apple-fm", calls: calls)
        manager.filingCloudSpendConfirmer = { _ in
            Issue.record("the estimate was shown for a pass the router refused")
            return true
        }
        let outcome = await manager.refineMapping(Self.request)
        #expect(outcome == .unavailable)
        #expect(calls.refined == 0, "the transport was reached around the router")
    }

    /// The estimate comes first, named honestly — folder names, not files — and Cancel is its
    /// own outcome, never conflated with a failure.
    @Test func decliningTheEstimateSendsNothingAndSaysSo() async {
        let calls = Calls()
        let manager = makeManager(route: "cloud:claude", calls: calls)
        var seen: FilingSpendPreflight?
        manager.filingCloudSpendConfirmer = { preflight in
            seen = preflight
            return false
        }
        let outcome = await manager.refineMapping(Self.request)
        #expect(outcome == .declined)
        #expect(calls.refined == 0)
        #expect(seen?.unit == "folder name", "the prompt must name the payload it quotes")
        #expect(seen?.fileCount == 1)
        #expect((seen?.estCostUSD ?? 0) > 0)
    }

    /// A confirmed estimate reaches the transport, and its proposals come back whole.
    @Test func aConfirmedEstimateRunsTheTransport() async {
        let calls = Calls()
        let manager = makeManager(route: "cloud:claude", calls: calls)
        manager.filingCloudSpendConfirmer = { _ in true }
        let outcome = await manager.refineMapping(Self.request)
        #expect(calls.refined == 1)
        #expect(outcome == .proposals([
            MappingRefineProposal(source: "Petition",
                                  verdict: .propose(target: "Application"), why: "w"),
        ]))
    }
}
