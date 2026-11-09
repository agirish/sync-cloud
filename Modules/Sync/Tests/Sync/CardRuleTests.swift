import Foundation
import Testing
@testable import Sync

/// A row sent to a folder of their own choosing on Ask Claude's card teaches a rule at Apply
/// (TE331): the Mac picks the words, picks that make one rule share its card, and the closest
/// saved rule is updated rather than repeated.
@MainActor
@Suite struct CardRuleTests {

    static let root = "/Users/me/Documents"
    static let unitedPage = "UNITED AIRLINES  Itinerary\nDate of Issue: 01AUG26\nUA 0868  05SEP  San Francisco (SFO) - Delhi (DEL)"
    static let emiratesPage = "Emirates e-Ticket Receipt\nIssued 02DEC26\nEK 0226  10JAN27  San Francisco (SFO) - Dubai (DXB)"

    private func pick(_ fileName: String, _ dest: String, page: String? = CorrectionRuleTests.jalPage,
                      root: String = root) throws -> AutomationRuleProposer.CardExample {
        let words = try #require(AutomationRuleProposer.cardWords(fileName: fileName, destinationRelativePath: dest,
                                                                  pageSample: page, index: nil, modificationDate: nil))
        return .init(fileName: fileName, destinationRelativePath: dest, surveyRoot: root, pageSample: page,
                     modificationDate: nil, phrase: words.phrase, ruleName: words.ruleName)
    }

    private var jal: AutomationRuleProposer.CardExample {
        get throws { try pick("JAL eTicket Receipt.pdf", "Travel/Trips/IN-US/2026/Sep") }
    }

    // MARK: The words (JA)

    @Test func theNameWordThatSaysWhoseItIsLeads() throws {
        let words = try #require(AutomationRuleProposer.cardWords(
            fileName: "JAL eTicket Receipt.pdf", destinationRelativePath: "Travel/Trips/IN-US/2026/Sep",
            pageSample: CorrectionRuleTests.jalPage, index: nil, modificationDate: nil))
        #expect(words.phrase == "jal", "not the kind of paper, nor a long word from page 1")
        #expect(words.ruleName == "IN-US", "named by its folder, before the year and month of travel")
        #expect(AutomationRuleProposer.cardNameWord("2026-09 Boarding Pass Sep.pdf") == nil)
        #expect(AutomationRuleProposer.cardNameWord("Chase Statement Oct 2026.pdf") == "chase")
    }

    @Test func aNameWithNoSuchWordOffersNothingWithoutTheSurveysMemory() {
        // Page 1 alone would key on its longest word: a guess, so no rule.
        #expect(AutomationRuleProposer.cardWords(fileName: "Scan 0042.pdf", destinationRelativePath: "Travel/Trips",
                                                 pageSample: CorrectionRuleTests.jalPage, index: nil, modificationDate: nil) == nil)
    }

    // MARK: One card per rule (JD)

    @Test func onePickOffersANewRuleForItsTripFolder() throws {
        let out = AutomationRuleProposer.cardOffers([try jal], existingRules: [])
        let offer = try #require(out.offers.first)
        #expect(out.offers.count == 1 && out.more == 0)
        #expect(offer.correction.kind == .new)
        #expect(offer.correction.rule.conditions == [.mentionsAny(["jal"])])
        #expect(offer.correction.rule.destinationTemplate == "Travel/Trips/IN-US/{travel-year}/{travel-month}")
        #expect(offer.correction.rule.surveyRoot == Self.root, "acts only in the tree it was taught in")
        #expect(offer.fileNames == ["JAL eTicket Receipt.pdf"] && offer.correction.checkedDate)
    }

    @Test func picksThatMakeOneRuleShareItsCard() throws {
        let united = try pick("United Itinerary SFO-DEL.pdf", "Travel/Trips/IN-US/2026/Sep", page: Self.unitedPage)
        // October's ticket: another month folder, the same rule.
        let ana = try pick("ANA Boarding Pass.pdf", "Travel/Trips/IN-US/2026/Oct",
                           page: "ANA boarding pass\nNH 0008  14OCT  Tokyo Narita (NRT) - San Francisco (SFO)")
        let out = AutomationRuleProposer.cardOffers([try jal, united, ana], existingRules: [])
        let offer = try #require(out.offers.first)
        #expect(out.offers.count == 1)
        #expect(offer.correction.kind == .new)
        #expect(offer.correction.rule.conditions == [.mentionsAny(["jal", "united", "ana"])])
        #expect(offer.fileNames == ["JAL eTicket Receipt.pdf", "United Itinerary SFO-DEL.pdf", "ANA Boarding Pass.pdf"])
        #expect(offer.examples == ["Travel/Trips/IN-US/2026/Sep", "Travel/Trips/IN-US/2026/Sep", "Travel/Trips/IN-US/2026/Oct"])
    }

    @Test func atMostThreeCardsAndTheRestAreCounted() throws {
        let picks = try ["Chase", "Amex", "Ally", "Schwab"].map { bank in
            try pick("\(bank) Statement.pdf", "Finance/\(bank)", page: nil)
        }
        let out = AutomationRuleProposer.cardOffers(picks, existingRules: [])
        #expect(out.offers.map(\.correction.rule.destinationTemplate) == ["Finance/Chase", "Finance/Amex", "Finance/Ally"])
        #expect(out.more == 1)
    }

    // MARK: A rule they already have (HG, HH)

    private var airlineRule: AutomationRule {
        AutomationRule(name: "Airline tickets", matchMode: .all, conditions: [.mentionsAny(["united", "air india"])],
                       destinationTemplate: "Travel/Trips/IN-US/{travel-year}/{travel-month}", surveyRoot: Self.root)
    }

    @Test func aPickWhoseFolderFitsAddsItsWordToTheClosestRule() throws {
        let saved = airlineRule
        let out = AutomationRuleProposer.cardOffers([try jal], existingRules: [saved])
        let offer = try #require(out.offers.first)
        #expect(offer.correction.kind == .addWords(added: ["jal"]))
        #expect(offer.correction.rule.id == saved.id && offer.correction.rule.surveyRoot == Self.root)
        #expect(offer.correction.rule.conditions == [.mentionsAny(["united", "air india", "jal"])])
    }

    @Test func twoPicksForOneSavedRuleAddTheirWordsOnOneCard() throws {
        let ana = try pick("ANA Boarding Pass.pdf", "Travel/Trips/IN-US/2026/Oct",
                           page: "ANA boarding pass\nNH 0008  14OCT  Tokyo Narita (NRT) - San Francisco (SFO)")
        let out = AutomationRuleProposer.cardOffers([try jal, ana], existingRules: [airlineRule])
        #expect(out.offers.count == 1)
        #expect(out.offers.first?.correction.kind == .addWords(added: ["jal", "ana"]))
        #expect(out.offers.first?.fileNames.count == 2)
    }

    @Test func aPickASavedRuleAlreadyMakesOffersNothing() throws {
        let united = try pick("United Itinerary SFO-DEL.pdf", "Travel/Trips/IN-US/2026/Sep", page: Self.unitedPage)
        #expect(AutomationRuleProposer.cardOffers([united], existingRules: [airlineRule]).offers.isEmpty)
    }

    @Test func anotherFolderGetsARuleBesideItToldApartByItsFolderWord() throws {
        let saved = AutomationRule(name: "Emirates", matchMode: .all, conditions: [.mentionsAny(["emirates"])],
                                   destinationTemplate: "Travel/Trips/IN-US/{year}", surveyRoot: Self.root)
        let dubai = try pick("Emirates eTicket DXB Dubai.pdf", "Travel/Trips/Dubai/2027", page: Self.emiratesPage)
        let offer = try #require(AutomationRuleProposer.cardOffers([dubai], existingRules: [saved]).offers.first)
        #expect(offer.correction.kind == .sibling(of: saved.id, ruleName: "Emirates"))
        #expect(offer.correction.rule.conditions.contains(.mentionsAll(["dubai"])), "\(offer.correction.rule.conditions)")
    }

    @Test func aRuleTaughtInOneTreeDoesntCoverAPickInAnother() throws {
        let other = try pick("United Itinerary SFO-DEL.pdf", "Travel/Trips/IN-US/2026/Sep", page: Self.unitedPage,
                             root: "/Users/me/Dropbox")
        let out = AutomationRuleProposer.cardOffers([other], existingRules: [airlineRule])
        #expect(out.offers.first?.correction.kind == .new && out.offers.first?.correction.rule.surveyRoot == "/Users/me/Dropbox")
    }

    // MARK: The row and the card

    @Test func aRowTeachesWhenTheyPickAnotherFolderOrDecideAnUnsureOne() {
        var plan = AskClaudePlan(title: "File 3 Loose Files", subtitle: "", rows: [
            .init(id: 0, name: "JAL.pdf", change: .move(from: "/d/JAL.pdf", toFolder: "/docs/Receipts"), ticked: true,
                  confidence: "High", folderLabel: "Receipts"),
            .init(id: 1, name: "Bill.pdf", change: .move(from: "/d/Bill.pdf", toFolder: "/docs/Home"), ticked: false,
                  confidence: AskClaudeFiling.label(.low), folderLabel: "Home",
                  choices: [.init(label: "Home", path: "/docs/Home"), .init(label: "Car", path: "/docs/Car")]),
            .init(id: 2, name: "W2.pdf", change: .move(from: "/d/W2.pdf", toFolder: "/docs/Taxes"), ticked: true,
                  confidence: "High", folderLabel: "Taxes"),
        ])
        plan.choose(.init(label: "Trips", path: "/docs/Trips"), forRow: 0)
        plan.choose(.init(label: "Home", path: "/docs/Home"), forRow: 1)
        plan.choose(.init(label: "Taxes", path: "/docs/Taxes/"), forRow: 2)
        #expect(plan.rows[0].teaches && plan.rows[0].pickedFromLabel == "Receipts" && plan.rows[0].wasUnsure == false)
        #expect(plan.rows[1].teaches, "an unsure row's pick teaches, even its first folder")
        #expect(!plan.rows[2].teaches, "the folder it already had")
        // A second pick keeps the folder the card had.
        plan.choose(.init(label: "Receipts", path: "/docs/Receipts"), forRow: 0)
        #expect(!plan.rows[0].teaches && plan.rows[0].pickedFrom == "/docs/Receipts")
    }

    @Test func theCardSaysWhatTaughtItAndWhereTheFilesWent() throws {
        let offer = try #require(AutomationRuleProposer.cardOffers([try jal], existingRules: []).offers.first)
        var card = AskClaudeRuleCard(fileName: offer.fileNames[0], correction: offer.correction)
        #expect(card.sourceLine == nil && card.exampleLine == "JAL eTicket Receipt.pdf goes to Travel › Trips › IN-US › 2026 › Sep.")
        card.fromCard = "File 6 Loose Files"
        #expect(card.sourceLine == "From your pick on “File 6 Loose Files”.")
        card.others = ["United.pdf"]
        #expect(card.exampleLine == "Checked on all 2 you moved: each goes where you put it.")
        #expect(card.sourceLine == "From your picks on “File 6 Loose Files”.")
        // Saved with the chat: a card from before this build still reads.
        let decoded = try JSONDecoder().decode(AskClaudeRuleCard.self, from: JSONEncoder().encode(card))
        #expect(decoded == card)
    }
}
