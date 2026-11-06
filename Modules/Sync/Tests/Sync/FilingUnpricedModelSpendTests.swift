import Testing
import Foundation
@testable import Sync

/// The spend guardrail when the price table has no rate for the configured model.
///
/// `CloudFilingProtocol.currentModel(for:)` honours a hand-set id outside the offered families,
/// and `pricing(for:)` and `estimatedCostUSD` answer nil for it. `cloudSpendAllows` must not treat
/// that nil as 0: zero is below every real cost, so it would disarm both cap checks (each adds the
/// estimate to recorded spend) and the dialog would quote "$0.0000" for a call nobody can price.
@Suite @MainActor struct FilingUnpricedModelSpendTests {

    /// Records every preflight the guardrail hands the confirmer and answers with a fixed verdict.
    /// A class so the recording survives the escaping closure the manager stores.
    private final class Confirmer {
        private(set) var quoted: [FilingSpendPreflight] = []
        private let answer: (FilingSpendPreflight) -> Bool
        init(_ answer: @escaping (FilingSpendPreflight) -> Bool) { self.answer = answer }
        func record(_ p: FilingSpendPreflight) -> Bool { quoted.append(p); return answer(p) }
    }

    /// A real Anthropic id with no rate in the price table: a dated pre-alias id matches no
    /// `claude-<family>` arm of `pricing(for:)`, and `currentModel(for:)` passes it through. Both
    /// facts are asserted below, so a pricing or alias change fails there instead of making these
    /// tests vacuous.
    private static let unpricedModel = "claude-3-5-sonnet-20241022"

    private func candidates(_ n: Int) -> [FilingCandidateFile] {
        (0..<n).map {
            FilingCandidateFile(filePath: "/tmp/scan-\($0).pdf", fileName: "scan-\($0).pdf",
                                ext: "pdf", year: "2026", contentSnippet: nil)
        }
    }

    private let taxonomy = ["Documents/Vehicles", "Documents/Family", "Documents/Taxes"]

    /// Cloud on and no app-supplied router, so `filingRoutesToCloud(.refine)` resolves through
    /// `configuredFilingBackendIdentity` to `"cloud:<model>"`: the state where the guardrail prices.
    private func manager(model: String, suite: String,
                         seed: (ScratchDefaults) -> Void = { _ in }) -> (FileSyncManager, ScratchDefaults) {
        let defaults = ScratchDefaults(suite)
        defaults.set(true, forKey: FileSyncManager.usesCloudDefaultsKey)
        defaults.set(model, forKey: FileSyncManager.cloudModelDefaultsKey)
        seed(defaults)
        let m = FileSyncManager()
        m.filingContentDefaults = defaults
        return (m, defaults)
    }

    /// $4.99 against the shipped $5 lifetime cap, so any priced call breaches it and only whether
    /// the estimate is real separates allowed from refused.
    private func seedNearLifetimeCap(_ d: ScratchDefaults) {
        FilingSpendStore.record(
            FilingSpendEntry(timestamp: Date(), model: CloudFilingProtocol.defaultModel,
                             fileCount: 40, placedCount: 40,
                             inputTokens: 1_000_000, outputTokens: 40_000,
                             cacheReadTokens: 0, cacheCreationTokens: 0,
                             estimatedCostUSD: FileSyncManager.defaultTotalBudgetCapUSD - 0.01),
            defaults: d)
    }

    /// The premise, pinned: this id really is unpriced and really does survive alias resolution.
    @Test func theFixtureModelIsGenuinelyUnpricedAndSurvivesAliasResolution() {
        #expect(CloudFilingProtocol.currentModel(for: Self.unpricedModel) == Self.unpricedModel,
                "the fixture id no longer survives currentModel, so these tests price a different model")
        #expect(CloudFilingProtocol.pricing(for: Self.unpricedModel) == nil,
                "the fixture id is now priced, so these tests no longer exercise the nil path")
        #expect(CloudFilingProtocol.estimatedCostUSD(model: Self.unpricedModel,
                                                     taxonomyFolders: taxonomy,
                                                     files: candidates(3)) == nil)
    }

    /// The dialog never quotes a price nothing knows. With no rate the call is refused without
    /// asking: a "$0.0000" the user reads as free and approves is worse than not asking.
    @Test func anUnpricedModelIsNeverQuotedAsCostingNothing() {
        let confirmer = Confirmer { _ in true }
        let (m, _) = manager(model: Self.unpricedModel, suite: "unpricedQuote")
        m.filingCloudSpendConfirmer = { confirmer.record($0) }

        let allowed = m.cloudSpendAllows(files: candidates(12), taxonomyFolders: taxonomy)

        #expect(!allowed, "an unpriceable cloud call was allowed to run")
        let shown = confirmer.quoted.map { FilingSpendFormat.cost($0.estCostUSD) }
        #expect(confirmer.quoted.isEmpty,
                "the spend dialog was shown for an unpriceable call, quoting \(shown)")
    }

    /// The $5 lifetime backstop holds whatever the model id. Both cap predicates add `estCostUSD`
    /// to recorded spend, so an estimate of 0 would let every call past every cap.
    @Test func theLifetimeBackstopStillHoldsWhenTheModelIsUnpriced() {
        let (m, defaults) = manager(model: Self.unpricedModel, suite: "unpricedBackstop",
                                    seed: seedNearLifetimeCap)
        // The seed landed, so "refused" below cannot be an artefact of an empty store.
        #expect(abs(FilingSpendStore.totals(defaults: defaults).costUSD
                    - (FileSyncManager.defaultTotalBudgetCapUSD - 0.01)) < 0.0001)
        #expect(FileSyncManager.totalBudgetCap(in: defaults) == FileSyncManager.defaultTotalBudgetCapUSD)

        let confirmer = Confirmer { _ in true }   // the user approves whatever they are shown
        m.filingCloudSpendConfirmer = { confirmer.record($0) }

        #expect(!m.cloudSpendAllows(files: candidates(200), taxonomyFolders: taxonomy),
                "an unpriced batch of 200 files was allowed through with lifetime spend already at the cap")
    }

    /// The control, so the tests above can't pass on a guardrail that refuses everything: a priced
    /// model at the same seam is still asked about, with a real non-zero estimate.
    @Test func aPricedModelIsStillQuotedAndStillAllowed() throws {
        let confirmer = Confirmer { _ in true }
        let (m, _) = manager(model: CloudFilingProtocol.defaultModel, suite: "pricedControl")
        m.filingCloudSpendConfirmer = { confirmer.record($0) }

        let allowed = m.cloudSpendAllows(files: candidates(12), taxonomyFolders: taxonomy)

        #expect(allowed)
        try #require(confirmer.quoted.count == 1, "the priced path stopped asking the confirmer")
        let preflight = confirmer.quoted[0]
        #expect(preflight.estCostUSD > 0,
                "a priced model produced a zero estimate, so the unpriced tests above prove nothing")
        #expect(preflight.model == CloudFilingProtocol.defaultModel)
    }

    /// The same control for the cap: with the priced default model, $4.99 of lifetime spend against
    /// the $5 cap is refused too, so the unpriced refusal is not an accident of the seed.
    @Test func aPricedModelAlsoRefusesAtTheLifetimeBackstop() throws {
        let (m, _) = manager(model: CloudFilingProtocol.defaultModel, suite: "pricedBackstop",
                             seed: seedNearLifetimeCap)
        // The over-cap dialog's only button is "Use On-Device Instead", so this confirmer says yes
        // only when the caps allow, like a user who cannot say yes.
        let confirmer = Confirmer { !$0.wouldExceedCap }
        m.filingCloudSpendConfirmer = { confirmer.record($0) }

        #expect(!m.cloudSpendAllows(files: candidates(200), taxonomyFolders: taxonomy))
        try #require(confirmer.quoted.count == 1)
        #expect(confirmer.quoted[0].wouldExceedTotalCap,
                "the priced preflight did not even register the breach")
    }
}
