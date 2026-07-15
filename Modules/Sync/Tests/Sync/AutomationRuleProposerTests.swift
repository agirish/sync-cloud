import Testing
import Foundation
@testable import Sync

/// The learn-by-example proposer that turns "user filed THIS into THAT" into an ``AutomationRule``.
/// This is the deterministic complement to the AI filing backend, so its heuristic — favor a token
/// the file name shares with the destination folder, else the file's kind — is pinned here.
@Suite struct AutomationRuleProposerTests {

    private func propose(_ name: String, into dest: String, snippet: String? = nil) -> AutomationRuleProposer.Proposal? {
        AutomationRuleProposer.propose(fileName: name, destinationRelativePath: dest, contentSnippet: snippet)
    }

    @Test func testSharedTokenBecomesTheNameCondition() {
        // "Mobile" appears in both the file name and the destination folder — the strongest signal.
        let p = propose("T-Mobile-bill-Mar.pdf", into: "Home/Utilities/T-Mobile")
        #expect(p?.defaultCondition == .nameMatches("*Mobile*"))
        #expect(p?.rule.conditions == [.nameMatches("*Mobile*")])
        #expect(p?.destinationTemplate == "Home/Utilities/T-Mobile")
    }

    @Test func testDestinationIsProviderRelativeAndTrimmed() {
        let p = propose("Kaiser-EOB.pdf", into: "/Medical/Kaiser/")
        #expect(p?.destinationTemplate == "Medical/Kaiser")
        #expect(p?.rule.destinationTemplate == "Medical/Kaiser")
    }

    @Test func testDistinctiveTokenWhenNothingIsShared() {
        // No overlap with "Medical" → the longest non-stop name token ("Kaiser") is used.
        let p = propose("Kaiser-EOB-statement.pdf", into: "Medical")
        #expect(p?.defaultCondition == .nameMatches("*Kaiser*"))
    }

    @Test func testFallsBackToKindWhenNameHasNoDistinctiveToken() {
        // Only stop-words ("invoice") + a year → no useful name token, so match by file kind.
        let p = propose("invoice-2025.pdf", into: "Finance")
        #expect(p?.defaultCondition == .kindIs(.pdf))
    }

    @Test func testContentOfferedAsAlternativeWhenSnippetMatches() {
        let p = propose("Kaiser-EOB.pdf", into: "Medical", snippet: "Explanation of benefits from Kaiser Permanente")
        // Default is still the name token; content is a swap-to alternative.
        #expect(p?.defaultCondition == .nameMatches("*Kaiser*"))
        #expect(p?.alternatives.contains(.contentContains("Kaiser")) == true)
        #expect(p?.alternatives.contains(.kindIs(.pdf)) == true)
    }

    @Test func testAlternativesExcludeTheDefault() {
        let p = propose("Kaiser-EOB.pdf", into: "Medical")
        #expect(p?.alternatives.contains(p!.defaultCondition) == false)
    }

    @Test func testEmptyDestinationYieldsNoProposal() {
        #expect(propose("anything.pdf", into: "") == nil)
        #expect(propose("anything.pdf", into: "  /  ") == nil)
    }

    @Test func testRuleNameIsDerived() {
        #expect(propose("Kaiser-EOB.pdf", into: "Medical")?.rule.name == "Kaiser")
        // No distinctive token → name from the destination leaf.
        #expect(propose("invoice-2025.pdf", into: "Finance/Bills")?.rule.name == "Bills")
    }

    @Test func testProposedRuleIsRunnable() {
        // A proposed rule must be immediately usable (name + a complete condition + destination).
        #expect(propose("Kaiser-EOB.pdf", into: "Medical")?.rule.isRunnable == true)
    }

    @Test func testTokenizerSplitsOnAllSeparatorsAndDropsNumbers() {
        #expect(AutomationRuleProposer.tokens(in: "T-Mobile-bill Mar_2025") == ["Mobile", "bill", "Mar"])
    }
}
