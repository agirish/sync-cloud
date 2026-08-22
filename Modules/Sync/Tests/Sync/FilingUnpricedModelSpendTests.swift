import Testing
import Foundation
@testable import Sync

/// The spend guardrail's behaviour when the price table has no rate for the configured model.
///
/// `CloudFilingProtocol.currentModel(for:)` deliberately honours a model id outside the three
/// offered families — "it can only have been set by hand, so honor it rather than overriding a
/// deliberate choice" — and `pricing(for:)` answers nil for exactly those ids. `estimatedCostUSD`
/// propagates that nil, documented as "so the caller shows 'estimate unavailable' rather than a
/// wrong number", and `FilingSpendEntry.costUnpriced` says in prose that "the pre-flight path
/// already handled the identical nil honestly".
///
/// It did not. `cloudSpendAllows` coerced it with `?? 0`, which is not a cost estimate — it is the
/// one value that is *below* every real one, so it disarms both cap comparisons (each adds the
/// estimate to recorded spend before testing it) while the confirmation dialog quotes "$0.0000"
/// for a call whose price nothing in the build knows.
@Suite @MainActor struct FilingUnpricedModelSpendTests {

    /// Records every preflight the guardrail hands the confirmer, and answers with a fixed verdict.
    /// A class rather than a captured local so the recording survives the escaping closure the
    /// manager stores.
    private final class Confirmer {
        private(set) var quoted: [FilingSpendPreflight] = []
        private let answer: (FilingSpendPreflight) -> Bool
        init(_ answer: @escaping (FilingSpendPreflight) -> Bool) { self.answer = answer }
        func record(_ p: FilingSpendPreflight) -> Bool { quoted.append(p); return answer(p) }
    }

    /// A real Anthropic id that the price table has no rate for. `pricing(for:)` matches on the
    /// `claude-<family>` prefix, so a dated pre-alias id like this one falls outside all four
    /// arms — and `currentModel(for:)` passes it through untouched, because it shares no
    /// `claude-<family>-` prefix with any selectable model. Both facts are asserted below rather
    /// than assumed, so a future pricing or alias change fails there instead of silently making
    /// these tests vacuous.
    private static let unpricedModel = "claude-3-5-sonnet-20241022"

    private func candidates(_ n: Int) -> [FilingCandidateFile] {
        (0..<n).map {
            FilingCandidateFile(filePath: "/tmp/scan-\($0).pdf", fileName: "scan-\($0).pdf",
                                ext: "pdf", year: "2026", contentSnippet: nil)
        }
    }

    private let taxonomy = ["Documents/Vehicles", "Documents/Family", "Documents/Taxes"]

    /// Cloud ON, no app-supplied router, so `filingRoutesToCloud(.refine)` resolves through
    /// `configuredFilingBackendIdentity` to `"cloud:<model>"` — the state in which the guardrail
    /// actually prices something.
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

    /// $4.99 against the shipped $5 lifetime cap — close enough that a priced call of any size
    /// breaches it, so what separates "allowed" from "refused" is only whether the estimate is real.
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

    /// **The dialog must not quote a price nothing knows.** With no rate for the model the
    /// estimate is unavailable, and the only honest preflight is no preflight: a "$0.0000" the
    /// user reads as free, and then approves, is worse than not asking.
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

    /// **The $5 lifetime backstop must not be disarmed by the model id.** Both cap predicates read
    /// `monthlySpentUSD + estCostUSD` / `totalSpentUSD + estCostUSD`, so an estimate of 0 makes
    /// "would this call push me past the cap?" answer no for every call, forever — the shipped
    /// default cap included.
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

    /// The other direction, so the two tests above are not passing on "the guardrail refuses
    /// everything": a **priced** model at the same seam is still asked about, and the preflight it
    /// is asked with carries a real, non-zero estimate.
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

    /// And the same control for the cap dimension: with the *priced* default model, $4.99 of
    /// lifetime spend against the $5 cap is refused too — which is what makes the unpriced
    /// refusal above a fix rather than a coincidence of the seeded state.
    @Test func aPricedModelAlsoRefusesAtTheLifetimeBackstop() throws {
        let (m, _) = manager(model: CloudFilingProtocol.defaultModel, suite: "pricedBackstop",
                             seed: seedNearLifetimeCap)
        // The over-cap dialog's only button is "Use On-Device Instead", so a confirmer that says
        // yes only when the caps allow is the honest stand-in for a user who cannot say yes.
        let confirmer = Confirmer { !$0.wouldExceedCap }
        m.filingCloudSpendConfirmer = { confirmer.record($0) }

        #expect(!m.cloudSpendAllows(files: candidates(200), taxonomyFolders: taxonomy))
        try #require(confirmer.quoted.count == 1)
        #expect(confirmer.quoted[0].wouldExceedTotalCap,
                "the priced preflight did not even register the breach")
    }
}
