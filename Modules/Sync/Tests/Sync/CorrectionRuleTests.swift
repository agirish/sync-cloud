import Foundation
import Testing
@testable import Sync

/// TE286: a correction in Ask Claude's chat becomes a free rule on the Mac. Decisions HF (any
/// correction, generalized), HG (one updatable rule, any of the words), HH (a sibling for another
/// folder), HI (the month is the first travel date on page 1).
@MainActor
@Suite struct CorrectionRuleTests {

    /// Page 1 of a JAL e-ticket receipt, as the reader returns it.
    static let jalPage = """
        JAPAN AIRLINES  e-Ticket Itinerary / Receipt
        Passenger: GIRISH/ABHISHEK MR   Date of birth: 12MAR1985
        Date of Issue: 15JUL26   Ticket Number: 131 2345678901
        JL 0754  23SEP  Tokyo Narita (NRT) - Bengaluru (BLR)
        JL 0753  14OCT  Bengaluru (BLR) - Tokyo Narita (NRT)
        """

    static let airlines = ["JAL", "Japan Airlines", "Air India", "United", "e-ticket"]

    private func correction(_ fileName: String = "JAL eTicket.pdf", into dest: String = "Travel/Trips/IN-US/2026/Sep",
                            name: String = "Airline tickets", phrases: [String] = airlines, also: [String] = [],
                            page: String? = jalPage, rules: [AutomationRule] = [])
        -> Result<AutomationRuleProposer.Correction, AutomationRuleProposer.CorrectionRefusal> {
        AutomationRuleProposer.correction(fileName: fileName, destinationRelativePath: dest, name: name,
                                          phrases: phrases, also: also, pageSample: page,
                                          modificationDate: nil, existingRules: rules)
    }

    // MARK: The travel date (HI)

    @Test func theFirstTravelDateSkipsTheIssueDateAndTheBirthday() {
        #expect(AutomationTravelDate.first(in: Self.jalPage) == .init(year: 2026, month: 9, day: 23))
    }

    @Test func aDateWithNoYearAfterADecemberIssueIsNextYear() {
        let page = "Issued 20 Dec 2026\nFlight AI 173 05JAN SFO-BLR"
        #expect(AutomationTravelDate.first(in: page) == .init(year: 2027, month: 1, day: 5))
    }

    @Test func spelledOutAndNumericDatesAreRead() {
        #expect(AutomationTravelDate.first(in: "Departure: September 3, 2026") == .init(year: 2026, month: 9, day: 3))
        #expect(AutomationTravelDate.first(in: "Travel date 2026-04-11") == .init(year: 2026, month: 4, day: 11))
        #expect(AutomationTravelDate.first(in: "Check-in 23/09/2026") == .init(year: 2026, month: 9, day: 23))
        // Either way round is a real date: no guess.
        #expect(AutomationTravelDate.first(in: "Check-in 04/09/2026") == nil)
        #expect(AutomationTravelDate.first(in: "No dates at all") == nil)
    }

    @Test func aMonthFolderIsUsedInTheSpellingAlreadyThere() {
        let children = ["Travel/Trips/IN-US/2026": ["April", "Sep"]]
        let april = AutomationTravelDate.adoptingExistingMonth(
            "Travel/Trips/IN-US/2026/Apr", template: "Travel/Trips/IN-US/{travel-year}/{travel-month}") { children[$0] ?? [] }
        #expect(april == "Travel/Trips/IN-US/2026/April")
        let october = AutomationTravelDate.adoptingExistingMonth(
            "Travel/Trips/IN-US/2026/Oct", template: "Travel/Trips/IN-US/{travel-year}/{travel-month}") { children[$0] ?? [] }
        #expect(october == "Travel/Trips/IN-US/2026/Oct")
    }

    @Test func theTravelTokensResolveFromPageOne() {
        let facts = AutomationRuleProposer.correctionFacts(fileName: "JAL eTicket.pdf", destination: "Downloads",
                                                           pageSample: Self.jalPage, modificationDate: nil)
        let resolved = AutomationEvaluator.resolveDestination("Travel/Trips/IN-US/{travel-year}/{travel-month}",
                                                              for: facts, providerName: nil, now: Date())
        #expect(resolved == .resolved("Travel/Trips/IN-US/2026/Sep"))
        var unread = facts
        unread.snippet = nil
        #expect(AutomationEvaluator.resolveDestination("Trips/{travel-month}", for: unread, providerName: nil, now: Date())
                == .unresolved(token: "{travel-month}"))
    }

    // MARK: The offer (HF, HG)

    @Test func aCorrectionBecomesOneRuleForEveryAirline() throws {
        let offer = try correction().get()
        #expect(offer.kind == .new)
        #expect(offer.rule.name == "Airline tickets")
        #expect(offer.rule.conditions == [.mentionsAny(["jal", "japan airlines", "air india", "united", "ticket"])])
        #expect(offer.rule.destinationTemplate == "Travel/Trips/IN-US/{travel-year}/{travel-month}")
        #expect(offer.checkedDate)
        // It files an Air India ticket for another month there too.
        let other = AutomationRuleProposer.correctionFacts(fileName: "AI ticket.pdf", destination: "Downloads",
                                                           pageSample: "Air India e-ticket. Issued 1 Feb 2027. AI 173 03MAR SFO-BLR",
                                                           modificationDate: nil)
        #expect(AutomationEvaluator.matches(offer.rule, other, now: Date()))
        #expect(AutomationEvaluator.resolveDestination(offer.rule.destinationTemplate, for: other, providerName: nil, now: Date())
                == .resolved("Travel/Trips/IN-US/2027/Mar"))
    }

    @Test func wordsTheFileDoesntHaveAreRefused() {
        #expect(correction(phrases: ["Lufthansa", "Emirates"]) == .failure(.notInFile))
        #expect(correction(phrases: ["the", "a"]) == .failure(.noWords))
    }

    /// The month folder he named isn't the ticket's: the folder stays as he said it, never a token
    /// that would file this very ticket somewhere else.
    @Test func aMonthThePageDoesntBearOutStaysLiteral() throws {
        let offer = try correction(into: "Travel/Trips/IN-US/2026/Oct").get()
        #expect(offer.rule.destinationTemplate == "Travel/Trips/IN-US/2026/Oct")
    }

    /// Page 1 unread (a ticket only in the cloud): the year and month are taken as the trip's, and
    /// the card says they weren't checked.
    @Test func anUnreadPageIsGeneralizedButNotChecked() throws {
        let offer = try correction(page: nil).get()
        #expect(offer.rule.destinationTemplate == "Travel/Trips/IN-US/{travel-year}/{travel-month}")
        #expect(!offer.checkedDate)
    }

    // MARK: Updating the closest rule (HG, HH)

    @Test func aRuleThatAlreadyFilesItIsNotOfferedAgain() throws {
        let saved = try correction().get().rule
        #expect(correction(phrases: ["JAL"], rules: [saved]) == .failure(.covered(ruleName: "Airline tickets")))
    }

    @Test func newWordsJoinTheClosestRuleWhenItsFolderFits() throws {
        let saved = try correction(phrases: ["JAL", "Japan Airlines"]).get().rule
        let page = "Singapore Airlines e-ticket. Date of issue 01AUG26. SQ 502 20SEP SIN-BLR"
        let offer = try correction("SQ ticket.pdf", phrases: ["Singapore Airlines", "JAL"], page: page, rules: [saved]).get()
        #expect(offer.kind == .addWords(added: ["singapore airlines"]))
        #expect(offer.rule.id == saved.id)
        #expect(offer.rule.conditions == [.mentionsAny(["jal", "japan airlines", "singapore airlines"])])
    }

    @Test func anotherFolderGetsASiblingThatNeedsWordsOfItsOwn() throws {
        let saved = try correction().get().rule
        let page = "Japan Airlines e-ticket. Date of issue 01MAR26. JL 711 10APR NRT-SIN"
        #expect(correction("JL Singapore.pdf", into: "Travel/Trips/Singapore/Flights", phrases: ["JAL", "Japan Airlines"], page: page, rules: [saved])
                == .failure(.needsAlso(ruleName: "Airline tickets", folder: saved.destinationTemplate)))
        let offer = try correction("JL Singapore.pdf", into: "Travel/Trips/Singapore/Flights", phrases: ["JAL", "Japan Airlines"],
                                   also: ["SIN"], page: page, rules: [saved]).get()
        #expect(offer.kind == .sibling(of: saved.id, ruleName: "Airline tickets"))
        #expect(offer.rule.name == "Airline tickets – Singapore")
        #expect(offer.rule.conditions == [.mentionsAny(["jal", "japan airlines", "air india", "united", "ticket"]),
                                          .mentionsAll(["sin"])])
        #expect(offer.rule.destinationTemplate == "Travel/Trips/Singapore/Flights")
    }

    @Test func aSiblingIsSavedBeforeTheRuleItStandsBeside() throws {
        let m = FileSyncManager()
        m.filingRuleDefaults = ScratchDefaults("CorrectionSibling")
        let first = try correction().get()
        m.saveCorrectionRule(first)
        let page = "Japan Airlines e-ticket. Date of issue 01MAR26. JL 711 10APR NRT-SIN"
        let sibling = try correction("JL Singapore.pdf", into: "Travel/Trips/Singapore/Flights", phrases: ["JAL", "Japan Airlines"],
                                     also: ["SIN"], page: page, rules: m.automationRules).get()
        m.saveCorrectionRule(sibling)
        #expect(m.automationRules.map(\.name) == ["Airline tickets – Singapore", "Airline tickets"])
        // And the order is what a scan sees first.
        let facts = AutomationRuleProposer.correctionFacts(fileName: "JL Singapore.pdf", destination: "Downloads",
                                                           pageSample: page, modificationDate: nil)
        #expect(AutomationRuleSet.eligible(m.automationRules).firstMatch(for: facts, now: Date())?.id == sibling.rule.id)
    }

    // MARK: The condition

    @Test func mentionsAnyRoundTripsAndMatchesWholePhrases() throws {
        let condition = AutomationCondition.mentionsAny(["japan airlines", "jal"])
        let data = try JSONEncoder().encode([condition])
        #expect(String(decoding: data, as: UTF8.self) == #"[{"mentionsAny":{"_0":["japan airlines","jal"]}}]"#)
        #expect(try JSONDecoder().decode([AutomationCondition].self, from: data) == [condition])
        let rule = AutomationRule(name: "r", conditions: [condition], destinationTemplate: "T")
        func facts(_ name: String) -> AutomationFileFacts {
            AutomationFileFacts(path: "/x/" + name, name: name, parentFolderName: "x", parentPath: "/x",
                                sizeBytes: 0, modificationDate: nil, isDirectory: false)
        }
        #expect(AutomationEvaluator.matches(rule, facts("Japan Airlines receipt.pdf"), now: Date()))
        #expect(AutomationEvaluator.matches(rule, facts("JAL.pdf"), now: Date()))
        #expect(!AutomationEvaluator.matches(rule, facts("Japan trip notes.pdf"), now: Date()))
        #expect(condition.summary == "mentions any of “japan airlines”, “jal”")
    }

    /// A rule whose folder comes from page 1 needs it read even when the name already matches.
    @Test func aRuleNamingItsFolderFromPageOneAsksForTheText() {
        let rule = AutomationRule(name: "r", conditions: [.nameMatches("*jal*")],
                                  destinationTemplate: "Trips/{travel-year}")
        #expect(rule.requiresContent)
        let facts = AutomationFileFacts(path: "/x/JAL.pdf", name: "JAL.pdf", parentFolderName: "x", parentPath: "/x",
                                        sizeBytes: 0, modificationDate: nil, isDirectory: false)
        #expect(AutomationRuleSet.eligible([rule]).contentCouldStillDecide(facts, now: Date()))
        let plain = AutomationRule(name: "p", conditions: [.nameMatches("*jal*")], destinationTemplate: "Trips")
        #expect(!AutomationRuleSet.eligible([plain]).contentCouldStillDecide(facts, now: Date()))
    }

    // MARK: Filing help follows saved rules

    @Test func filingHelpAnswersFromASavedRuleFirst() async throws {
        let root = "/never-on-disk-correction/Documents"
        let m = FileSyncManager()
        m.filingRuleDefaults = ScratchDefaults("CorrectionFilingHelp")
        let folders = ["Purchases/2026", "Travel/Trips/IN-US/2026/Sep", "Travel/Trips/IN-US/2026/April"]
        m.filingFolderProfile = FolderProfile(
            profileId: "correction", root: root,
            folders: Dictionary(uniqueKeysWithValues: folders.map {
                ($0, FolderProfileEntry(path: $0, role: .destination, naming: nil, anchors: [], acceptsNewFiles: nil,
                                        fileCount: 2, subfolderCount: 0, axes: [:]))
            }), personTokens: [])
        m.filingMemory = FilingMemory(profileId: "correction", salt: "s", folders: [
            "Purchases/2026": FilingMemoryEntry(docs: 4, anchors: [FilingMemoryToken(token: "receipt", weight: 4)], idHashes: []),
        ])
        m.saveCorrectionRule(try correction().get())
        let answer = await m.whereToFile("/Users/someone/Downloads/JAL eTicket.pdf", snippet: Self.jalPage,
                                         isHidden: { _ in false })
        guard case .suggested(let s) = answer.outcome else {
            Issue.record("no suggestion: \(answer), rules \(m.automationRules.map(\.summary))"); return
        }
        #expect(s.map(\.relativePath) == ["Travel/Trips/IN-US/2026/Sep"])
        #expect(s.first?.confidence == .high)
        #expect(s.first?.reason == "Your rule “Airline tickets” files this here")
        // An April trip takes the April folder already there; page 1 unread, the trip's folder.
        let april = await m.whereToFile("/Users/someone/Downloads/JAL eTicket.pdf",
                                        snippet: "Japan Airlines. Date of issue 01MAR26. JL 1 11APR NRT-BLR", isHidden: { _ in false })
        guard case .suggested(let a) = april.outcome else { Issue.record("no suggestion: \(april)"); return }
        #expect(a.first?.relativePath == "Travel/Trips/IN-US/2026/April")
        let unread = await m.whereToFile("/Users/someone/Downloads/JAL eTicket.pdf", snippet: nil, isHidden: { _ in false })
        guard case .suggested(let u) = unread.outcome else { Issue.record("no suggestion: \(unread)"); return }
        #expect(u.first?.relativePath == "Travel/Trips/IN-US")
        #expect(u.first?.confidence == .medium)
        let undated = await m.whereToFile("/Users/someone/Downloads/JAL eTicket.pdf", snippet: "Japan Airlines e-ticket receipt",
                                          isHidden: { _ in false })
        guard case .suggested(let d) = undated.outcome else { Issue.record("no suggestion: \(undated)"); return }
        #expect(d.first?.relativePath == "Travel/Trips/IN-US" && d.first?.confidence == .medium)
        #expect(d.first?.reason.contains("page 1 names no date") == true)
                // A hidden folder is never named, by a rule either.
        let hidden = await m.whereToFile("/Users/someone/Downloads/JAL eTicket.pdf", snippet: Self.jalPage,
                                         isHidden: { $0.hasPrefix(root + "/Travel") })
        if case .suggested(let h) = hidden.outcome { #expect(!h.contains { $0.relativePath.hasPrefix("Travel") }) }
    }

    /// A rule taught in Ask Claude is relative to the survey it was taught in, so it carries that
    /// survey's root and files nothing in another source's scan — a Dropbox scan must not get a
    /// High card into Dropbox/Travel/… from a rule taught for iCloud's Travel.
    @Test func aTaughtRuleActsOnlyInItsSurveysTree() throws {
        let root = "/never-on-disk-correction-scope/Documents"
        let m = FileSyncManager()
        m.filingRuleDefaults = ScratchDefaults("CorrectionScope")
        let folders = ["Travel/Trips/IN-US/2026/Sep"]
        m.filingFolderProfile = FolderProfile(
            profileId: "scope", root: root,
            folders: Dictionary(uniqueKeysWithValues: folders.map {
                ($0, FolderProfileEntry(path: $0, role: .destination, naming: nil, anchors: [], acceptsNewFiles: nil,
                                        fileCount: 2, subfolderCount: 0, axes: [:]))
            }), personTokens: [])
        let offer = try #require(m.ruleFromCorrection("/Users/someone/Downloads/JAL eTicket.pdf",
                                                      into: root + "/Travel/Trips/IN-US/2026/Sep", name: "Airline tickets",
                                                      phrases: Self.airlines, also: [], pageSample: Self.jalPage)).get()
        #expect(offer.rule.surveyRoot == root)

        let ticket = FileNode(id: "/Users/someone/Downloads/JAL eTicket.pdf", name: "JAL eTicket.pdf", isDirectory: false,
                              fileSize: 5000)
        func home(in providerRoot: String, _ rule: AutomationRule) -> FilingDestination? {
            FilingEngine.suggest(looseFiles: [ticket], taxonomy: [], providerRoot: providerRoot, automations: [rule],
                                 automationSnippets: [ticket.id: Self.jalPage]).first?.candidates.first { $0.remembered }
        }
        #expect(home(in: root, offer.rule)?.path == root + "/Travel/Trips/IN-US/2026/Sep")
        #expect(home(in: "/never-on-disk-correction-scope/Dropbox", offer.rule) == nil, "it filed into another source's tree")

        // A rule saved before it carried a root still loads, and acts in every tree as it did.
        var old = offer.rule
        old.surveyRoot = nil
        let data = try JSONEncoder().encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("surveyRoot"))
        let loaded = try JSONDecoder().decode(AutomationRule.self, from: data)
        #expect(loaded.surveyRoot == nil && loaded.isRunnable)
        #expect(home(in: "/never-on-disk-correction-scope/Dropbox", loaded) != nil)
        // And the root round-trips.
        #expect(try JSONDecoder().decode(AutomationRule.self, from: JSONEncoder().encode(offer.rule)) == offer.rule)
    }

    /// To File's path: the scan's walked folders give the month's spelling, and a ticket not yet
    /// read files into the trip's folder at Medium.
    @Test func theScanFilesByTheRuleIntoTheMonthFolderThere() throws {
        let rule = try correction().get().rule
        let root = "/r/Documents"
        let existing: Set<String> = [root, root + "/Travel", root + "/Travel/Trips", root + "/Travel/Trips/IN-US",
                                     root + "/Travel/Trips/IN-US/2026", root + "/Travel/Trips/IN-US/2026/April"]
        let page = "Japan Airlines. Date of issue 01MAR26. JL 1 11APR NRT-BLR"
        let facts = AutomationRuleProposer.correctionFacts(fileName: "JAL.pdf", destination: "/x", pageSample: page, modificationDate: nil)
        let children = { FilingEngine.childNames(of: $0, providerRoot: root, existingPaths: existing) }
        let placed = try #require(FilingEngine.ruleDestination(rule, facts: facts, providerRoot: root, providerName: nil,
                                                               now: Date(), children: children))
        #expect(placed.path == root + "/Travel/Trips/IN-US/2026/April" && !placed.needsPage)
        var unread = facts
        unread.snippet = nil
        let start = try #require(FilingEngine.ruleDestination(rule, facts: unread, providerRoot: root, providerName: nil,
                                                              now: Date(), children: children))
        #expect(start.path == root + "/Travel/Trips/IN-US" && start.needsPage)
    }
}
