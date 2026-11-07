import Foundation
import Testing
@testable import Sync
@testable import FileExplorer

/// To File's rule offer rides in the "Filed …" result message, whose "Save as rule…" opens the full
/// offer; ignored, the offer leaves with the message. Inserted above the cards instead, it would
/// slide the next card's "File here" down under the pointer.
@MainActor
@Suite struct RuleOfferRidesInTheMessageTests {

    private static func offer(ridesOn id: UUID?) -> RuleOffer {
        let variant = AutomationRuleProposer.Variant(conditions: [.mentionsAll(["tmobile"])], chipLabel: "“tmobile”")
        let rule = AutomationRule(name: "T-Mobile", matchMode: .all, conditions: variant.conditions,
                                  destinationTemplate: "Home/Utilities")
        return RuleOffer(fileName: "Bill.pdf",
                         proposal: AutomationRuleProposer.Proposal(rule: rule, variants: [variant],
                                                                   destinationTemplate: "Home/Utilities"),
                         ridesOn: id)
    }

    @Test func theOfferRidesOnlyInTheMessageItsMoveRaised() {
        let filed = UUID(), later = UUID()
        let session = LensWorkspaceSession()
        session.pendingRuleOffer = Self.offer(ridesOn: filed)
        #expect(session.offersRule(riding: filed))
        #expect(!session.offersRule(riding: later), "“Save as rule…” rode in a message about something else")
    }

    @Test func theRememberPromptRidesTheSameWay() {
        let filed = UUID()
        let session = LensWorkspaceSession()
        session.pendingRememberPrompt = PendingRememberPrompt(fileName: "Bill.pdf", destinationPath: "/x/Bills",
                                                              ridesOn: filed)
        #expect(session.offersRule(riding: filed))
        session.retireRuleOffer(unlessRiding: nil)
        #expect(session.pendingRememberPrompt == nil, "the prompt outlived its message")
    }

    @Test func ignoredTheOfferLeavesWithItsMessage() {
        let filed = UUID()
        let session = LensWorkspaceSession()
        session.pendingRuleOffer = Self.offer(ridesOn: filed)
        // The same message re-published (a hover, a re-render) keeps it…
        session.retireRuleOffer(unlessRiding: filed)
        #expect(session.pendingRuleOffer != nil)
        // …the next result replacing it, or the message timing out, does not.
        session.retireRuleOffer(unlessRiding: UUID())
        #expect(session.pendingRuleOffer == nil, "the offer outlived the message it rode in")
        session.pendingRuleOffer = Self.offer(ridesOn: filed)
        session.retireRuleOffer(unlessRiding: nil)
        #expect(session.pendingRuleOffer == nil)
    }

    /// The cards never move for it: nothing in the To File list inserts the offer, and it is drawn
    /// only in the panel the message's button opens.
    @Test func theCardsNoLongerHaveTheOfferInsertedAboveThem() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FileExplorer")
        let lens = try String(contentsOf: sources.appendingPathComponent("LensWorkspaceView.swift"), encoding: .utf8)
        #expect(lens.contains("private func filingContent("), "the scan cannot find To File's content — vacuous")
        #expect(!lens.contains("RuleOfferPromptView("), "the offer is drawn in the lens again, above the cards")
        #expect(!lens.contains("RememberOverridePromptView("))
        let panel = try String(contentsOf: sources.appendingPathComponent("RuleOfferPrompt.swift"), encoding: .utf8)
        #expect(panel.contains("public struct FilingRuleOfferPanel: View"))
        // The button observes the session itself: the offer arrives after the message, and the
        // window that draws the message owns the session without observing it.
        let button = try #require(panel.range(of: "public struct FilingRuleOfferButton: View {"))
        #expect(panel[button.upperBound...].prefix(200).contains("@ObservedObject var session: LensWorkspaceSession"),
                "the button no longer observes the session — it would never see the offer arrive")
        // And the offer is tied to the move's message when it is made.
        #expect(lens.contains("RuleOffer(fileName: fileName, proposal: proposal, ridesOn: syncManager.banner?.id)"))
        #expect(lens.contains("ridesOn: syncManager.banner?.id)"))
    }
}
