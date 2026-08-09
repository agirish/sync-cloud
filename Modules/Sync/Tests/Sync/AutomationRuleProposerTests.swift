import Testing
import Foundation
@testable import Sync

/// The learn-by-example proposer that turns "user filed THIS into THAT" into an ``AutomationRule``.
///
/// Two halves, and they are pinned separately. Without a ``FilingMemory`` the proposer is the
/// name/kind heuristic it always was — the state of every install that has never had its tree
/// surveyed. With one, it keys on what the destination has actually *received*, which is the signal
/// ``FilingRouter`` measured at 58.2% top-1 against the filename's 12.6%.
@Suite struct AutomationRuleProposerTests {

    private func propose(_ name: String, into dest: String,
                         evidence: AutomationRuleProposer.Evidence = .init()) -> AutomationRuleProposer.Proposal? {
        AutomationRuleProposer.propose(fileName: name, destinationRelativePath: dest, evidence: evidence)
    }

    // MARK: No profile loaded — the heuristic, unchanged

    @Test func testSharedTokenBecomesTheKey() {
        // "Mobile" appears in both the file name and the destination folder — the strongest signal
        // available with no memory to consult.
        let p = propose("T-Mobile-bill-Mar.pdf", into: "Home/Utilities/T-Mobile")
        #expect(p?.defaultVariant.conditions == [.mentionsAll(["mobile"])])
        #expect(p?.rule.conditions == [.mentionsAll(["mobile"])])
        #expect(p?.destinationTemplate == "Home/Utilities/T-Mobile")
    }

    /// **An incidental word may not be conjoined.** "Mar" is a real token of this filename and the
    /// second-best key on offer, but nothing in the tree vouches for it — pairing it would learn
    /// "T-Mobile bills, in March", which files eleven months of bills nowhere. Two words is the
    /// default only when the tree supports both (see ``AutomationRuleProposer/supportFloor``).
    @Test func anUnsupportedSecondWordIsNotConjoined() throws {
        let p = try #require(propose("T-Mobile-bill-Mar.pdf", into: "Home/Utilities/T-Mobile"))
        for variant in p.variants {
            #expect(!variant.summary.contains("mar"), "offered \(variant.summary)")
        }
    }

    @Test func testSharedTokenWinsRegardlessOfCase() {
        // "acme" (name, lowercase) names the "Acme" destination folder — the shared anchor must
        // fire across the case difference, or the fallback picks the longest token ("march") and
        // proposes a rule that files every March-named file into Vendors/Acme.
        let p = propose("acme-invoice-march.pdf", into: "Vendors/Acme")
        #expect(p?.defaultVariant.conditions == [.mentionsAll(["acme"])])
    }

    @Test func testDestinationIsProviderRelativeAndTrimmed() {
        let p = propose("Kaiser-EOB.pdf", into: "/Medical/Kaiser/")
        #expect(p?.destinationTemplate == "Medical/Kaiser")
        #expect(p?.rule.destinationTemplate == "Medical/Kaiser")
    }

    @Test func testLongestTokenWhenNothingIsShared() {
        // No overlap with "Medical" → the longest non-stop name token ("kaiser") carries the rule.
        let p = propose("Kaiser-EOB-statement.pdf", into: "Medical")
        #expect(p?.defaultVariant.conditions == [.mentionsAll(["kaiser"])])
    }

    @Test func testFallsBackToKindWhenNameHasNoDistinctiveToken() {
        // Only stop-words ("invoice") + a year → no useful name token, so match by file kind.
        let p = propose("invoice-2025.pdf", into: "Finance")
        #expect(p?.defaultVariant.conditions == [.kindIs(.pdf)])
    }

    @Test func testDeclinesWhenNoDistinctiveTokenAndNoExtension() {
        // A token-less, extension-less example (only a year, no kind to anchor on) would otherwise
        // fall back to `name matches *` — a match-EVERYTHING rule. Decline instead of proposing it.
        #expect(propose("2024", into: "Archive") == nil)
        #expect(propose("ab", into: "Archive") == nil)
    }

    @Test func testEmptyDestinationYieldsNoProposal() {
        #expect(propose("anything.pdf", into: "") == nil)
        #expect(propose("anything.pdf", into: "  /  ") == nil)
    }

    /// The rule is named for the folder it files into — what a person calls it — skipping template
    /// tokens, because a rule called "{year}" names nothing.
    @Test func testRuleNameIsTheDestination() {
        #expect(propose("Kaiser-EOB.pdf", into: "Medical/Kaiser")?.rule.name == "Kaiser")
        #expect(propose("invoice-2025.pdf", into: "Finance/Bills")?.rule.name == "Bills")
        let dated = AutomationRuleProposer.propose(fileName: "DetailedBillApr2025.pdf",
                                                   destinationRelativePath: "Home/Utilities/T-Mobile/2025",
                                                   modificationDate: Self.date(2025, 4))
        #expect(dated?.rule.name == "T-Mobile")
    }

    @Test func testProposedRuleIsRunnable() {
        // A proposed rule must be immediately usable (name + a complete condition + destination).
        #expect(propose("Kaiser-EOB.pdf", into: "Medical")?.rule.isRunnable == true)
    }

    /// Narrower / balanced / broader, in that order — and never the same conditions twice.
    @Test func testVariantsAreOrderedAndDistinct() throws {
        let index = Self.index(memory: ["Medical/Kaiser": ["kaiser": 4.0, "eob": 3.0]])
        let p = try #require(propose("Kaiser-EOB.pdf", into: "Medical/Kaiser",
                                     evidence: .init(index: index)))
        #expect(p.variants.map(\.conditions) == [
            [.mentionsAll(["kaiser", "eob"])],
            [.mentionsAll(["kaiser", "eob"]), .kindIs(.pdf)],
            [.mentionsAll(["kaiser"])],
        ])
        #expect(Set(p.variants.map(\.conditions)).count == p.variants.count)
    }

    // MARK: The tree's own memory

    /// **The point of the reform.** Two words the destination is actually known by, strongest
    /// first — not one word shared with the folder's name.
    @Test func twoAnchorsBecomeAConjunction() throws {
        let index = Self.index(memory: ["Home/Utilities/T-Mobile": ["tmobile": 5.0, "autopay": 3.0,
                                                                    "wireless": 1.5]])
        let p = try #require(propose("tmobile autopay statement.pdf", into: "Home/Utilities/T-Mobile",
                                     evidence: .init(index: index)))
        #expect(p.defaultVariant.conditions == [.mentionsAll(["tmobile", "autopay"])])
    }

    /// A word hundreds of folders are known by cannot route anything, however heavily this one
    /// folder weights it. The memory's posting list is the test — not a hand-written stop-list,
    /// which cannot know that "statement" is generic in *this* tree.
    @Test func aWordCarriedByTooManyFoldersIsRefused() throws {
        var folders: [String: [String: Anchor]] = ["Finance/US/Chase": ["chase": 4.0, "statement": 9.0]]
        for i in 0..<30 { folders["Filler/\(i)"] = ["statement": 9.0] }
        let index = Self.index(memory: folders)
        let p = try #require(propose("chase statement.pdf", into: "Finance/US/Chase",
                                     evidence: .init(index: index)))
        // "statement" outweighs "chase" and still loses: 31 folders carry it.
        #expect(p.defaultVariant.conditions == [.mentionsAll(["chase"])])
        for variant in p.variants { #expect(!variant.summary.contains("statement")) }
    }

    /// **A cold folder has no anchors of its own, and it is the folder rules are for.** January's
    /// bill is the first document in `…/T-Mobile/2026`; without inheriting the parent's anchors the
    /// proposal falls back to whatever the filename happens to say.
    @Test func aColdYearBucketInheritsItsParentsAnchors() throws {
        let index = Self.index(memory: ["Home/Utilities/T-Mobile": ["tmobile": 5.0, "autopay": 3.0]],
                               destinations: ["Home/Utilities/T-Mobile", "Home/Utilities/T-Mobile/2026"])
        let p = try #require(AutomationRuleProposer.propose(
            fileName: "DetailedBillJan.pdf",
            destinationRelativePath: "Home/Utilities/T-Mobile/2026",
            evidence: .init(pageSample: "tmobile autopay detailed bill", index: index),
            modificationDate: Self.date(2026, 1)))
        #expect(p.defaultVariant.conditions == [.mentionsAll(["tmobile", "autopay"])])
        #expect(p.destinationTemplate == "Home/Utilities/T-Mobile/{year}")
    }

    /// A file whose name says nothing still seeds a real rule, from the page the scan already read.
    @Test func thePageTheScanReadIsAFirstClassSource() throws {
        let index = Self.index(memory: ["Medical/Kaiser": ["kaiser": 5.0, "permanente": 4.0]])
        let p = try #require(propose("Scan 2026-03-02.pdf", into: "Medical/Kaiser",
                                     evidence: .init(pageSample: "Kaiser Permanente explanation of benefits",
                                                     index: index)))
        #expect(p.defaultVariant.conditions == [.mentionsAll(["kaiser", "permanente"])])
    }

    /// Only the first 400 characters count — the sample the memory's weights were measured under.
    /// A caller handing over a whole document must not silently change what a rule keys on.
    @Test func thePageSampleIsBoundedToWhatTheScorerWasMeasuredOn() throws {
        let index = Self.index(memory: ["Medical/Kaiser": ["kaiser": 5.0, "permanente": 4.0]])
        let padded = String(repeating: "x ", count: 400) + "permanente"
        let p = try #require(propose("kaiser eob.pdf", into: "Medical/Kaiser",
                                     evidence: .init(pageSample: padded, index: index)))
        #expect(p.defaultVariant.conditions == [.mentionsAll(["kaiser"])])
    }

    /// A digit-bearing word is the best key there is when the folder's own documents already carry
    /// it (a receipt or policy number), and the worst when they do not — an invoice number nothing
    /// has seen before makes a rule that matches exactly one file, forever. The memory decides which.
    @Test func aKnownIdentifierIsAKeyAndAnUnknownOneIsNot() throws {
        let index = Self.index(memory: ["Immigration/Petitions": ["uscis": 4.0]],
                               ids: ["Immigration/Petitions": ["wac2190123456": 6.0]])
        let known = try #require(propose("USCIS notice WAC2190123456.pdf", into: "Immigration/Petitions",
                                         evidence: .init(index: index)))
        #expect(known.defaultVariant.conditions == [.mentionsAll(["wac2190123456", "uscis"])])

        let unknown = try #require(propose("USCIS notice WAC9998887777.pdf", into: "Immigration/Petitions",
                                           evidence: .init(index: index)))
        for variant in unknown.variants { #expect(!variant.summary.contains("wac9998887777")) }
    }

    /// **A bare number can never be a key, whatever the memory says about it.** `mentionsAll` is
    /// answered from ``FilingEngine/fileTokens``, which drops pure digits (only years survive, and
    /// those are refused separately) — so an account last-4 the folder genuinely is known by still
    /// cannot be matched on. The verification pass is what keeps that from becoming a saved rule
    /// that never fires; this pins that it stays that way.
    @Test func aPureDigitIdentifierIsNotOfferedEvenWhenTheMemoryKnowsIt() throws {
        let index = Self.index(memory: ["Finance/US/Chase 8829": ["chase": 4.0]],
                               ids: ["Finance/US/Chase 8829": ["8829": 6.0]])
        let p = try #require(propose("chase 8829 statement.pdf", into: "Finance/US/Chase 8829",
                                     evidence: .init(index: index)))
        for variant in p.variants { #expect(!variant.summary.contains("8829")) }
        #expect(p.defaultVariant.conditions == [.mentionsAll(["chase"])])
    }

    /// A year is what `{year}` is for. Keying on one freezes the rule to a single year's documents —
    /// the same defect the destination rewrite exists to prevent, arriving through the condition.
    ///
    /// **The year has to arrive by the route that would let it through.** A year is four digits, so
    /// it is also an *identifier* by ``FilingRouter/isIdentifier`` — and the identifier gate refuses
    /// anything the folder's memory does not already carry, which quietly covers this case for a
    /// year the memory never saw. Mutation testing found the first version of this test passing with
    /// the year guard deleted for exactly that reason. So the fixture records `2025` the way a real
    /// builder would, as a digit-bearing token in the folder's `idHashes`, where nothing else stops
    /// it.
    @Test func aYearIsNeverAKey() throws {
        let index = Self.index(memory: ["Taxes/US": ["irs": 5.0]],
                               ids: ["Taxes/US": ["2025": 9.0]])
        let p = try #require(propose("irs 2025 return.pdf", into: "Taxes/US",
                                     evidence: .init(index: index)))
        for variant in p.variants { #expect(!variant.summary.contains("2025")) }
        #expect(p.defaultVariant.conditions == [.mentionsAll(["irs"])])
    }

    /// **Every offered phrasing has to match the file it was learned from.** The memory's anchors
    /// were tokenized by ``FilingRouter/tokenize`` and `mentionsAll` matches on
    /// ``FilingEngine/nameTokens``, which splits camelCase — so `detailedbill` is a perfectly good
    /// anchor that the evaluator can never produce for this file. Offering it would save, review
    /// and enable a rule that silently never fires.
    @Test func aWordTheEvaluatorCannotProduceIsNeverOffered() throws {
        let index = Self.index(memory: ["Home/Utilities/T-Mobile": ["detailedbill": 9.0, "tmobile": 5.0]])
        let p = try #require(propose("DetailedBillApr.pdf", into: "Home/Utilities/T-Mobile",
                                     evidence: .init(pageSample: "tmobile account", index: index)))
        for variant in p.variants { #expect(!variant.summary.contains("detailedbill")) }
        // And what IS offered really matches the example — the whole point of verifying.
        let facts = AutomationRuleProposer.exampleFacts(fileName: "DetailedBillApr.pdf",
                                                        destination: "Home/Utilities/T-Mobile",
                                                        evidence: .init(pageSample: "tmobile account", index: index),
                                                        modificationDate: nil)
        for variant in p.variants {
            let probe = AutomationRule(name: "probe", matchMode: .all, conditions: variant.conditions,
                                       destinationTemplate: p.destinationTemplate)
            #expect(AutomationEvaluator.matches(probe, facts, now: Date()), "inert: \(variant.summary)")
        }
    }

    /// A saved rule that already matches this file and already files it here has nothing to teach.
    /// Offering it again is how a user ends up with four rules that say the same thing.
    @Test func anOfferAlreadyCoveredByASavedRuleIsNotMade() throws {
        let index = Self.index(memory: ["Medical/Kaiser": ["kaiser": 5.0, "permanente": 4.0]])
        let saved = AutomationRule(name: "Kaiser", matchMode: .all,
                                   conditions: [.mentionsAll(["kaiser"])],
                                   destinationTemplate: "Medical/Kaiser")
        #expect(propose("kaiser permanente eob.pdf", into: "Medical/Kaiser",
                        evidence: .init(index: index, existingRules: [saved])) == nil)
        // A rule pointing somewhere else is not coverage — the user is teaching a different home.
        var elsewhere = saved
        elsewhere.destinationTemplate = "Medical/Other"
        #expect(propose("kaiser permanente eob.pdf", into: "Medical/Kaiser",
                        evidence: .init(index: index, existingRules: [elsewhere])) != nil)
        // Nor is a disabled one: it steers nothing.
        var off = saved
        off.enabled = false
        #expect(propose("kaiser permanente eob.pdf", into: "Medical/Kaiser",
                        evidence: .init(index: index, existingRules: [off])) != nil)
    }

    // MARK: A year in the destination is the axis that varies

    private static func date(_ y: Int, _ m: Int = 6, _ d: Int = 15) -> Date {
        Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// **A literal year freezes the one axis that varies.** A rule learned from a bill filed into
    /// `T-Mobile/2025` files every future bill into 2025, and one learned in December misfiles
    /// everything from January. Seen in the wild as a `DetailedBill` rule pinned to
    /// `Home/Utilities/T-Mobile/2026` that sent an April 2025 statement to an empty 2026 folder.
    @Test func aDestinationEndingInTheExamplesYearBecomesAToken() throws {
        let p = try #require(AutomationRuleProposer.propose(
            fileName: "DetailedBillApr2025.pdf",
            destinationRelativePath: "Home/Utilities/T-Mobile/2025",
            modificationDate: Self.date(2025, 4)))
        #expect(p.destinationTemplate == "Home/Utilities/T-Mobile/{year}")
        #expect(p.rule.destinationTemplate == "Home/Utilities/T-Mobile/{year}")
    }

    /// **Only when the literal is the year this example resolves to.** Filing a 2025 document into
    /// 2026 is a deliberate act, and generalising it would rewrite the user's intent rather than
    /// extend it. Without this half the test above would pass for a rule that simply always
    /// substitutes.
    @Test func aDeliberatelyMismatchedYearIsKeptVerbatim() throws {
        let p = try #require(AutomationRuleProposer.propose(
            fileName: "DetailedBillApr2025.pdf",
            destinationRelativePath: "Home/Utilities/T-Mobile/2026",
            modificationDate: Self.date(2025, 4)))
        #expect(p.destinationTemplate == "Home/Utilities/T-Mobile/2026")
    }

    /// A span is not a `{year}`: the token cannot reproduce one, so there is nothing to generalise
    /// to and the folder is kept as it is.
    @Test func aFiscalSpanIsLeftAlone() throws {
        let p = try #require(AutomationRuleProposer.propose(
            fileName: "H1B Visa - Nov 2026.pdf",
            destinationRelativePath: "Immigration/Visa/US/H-1B Visa/2024-2026",
            modificationDate: Self.date(2026, 11)))
        #expect(p.destinationTemplate == "Immigration/Visa/US/H-1B Visa/2024-2026")
    }

    /// A destination that does not end in a year is untouched — the rule must not fire on the
    /// ordinary case.
    @Test func aNonYearDestinationIsUntouched() throws {
        let p = try #require(AutomationRuleProposer.propose(
            fileName: "policy.pdf", destinationRelativePath: "Home/Insurance/Auto",
            modificationDate: Self.date(2025)))
        #expect(p.destinationTemplate == "Home/Insurance/Auto")
    }

    // MARK: A rule has to fire again — recurrence, not rarity

    /// **The defect this exists to prevent, in the shape it was found in.** These are
    /// `Home/Utilities/T-Mobile/2025`'s real anchors and real document shares. Ranking by weight
    /// picks `appreciation` (7.05, in one bill of three) and `awesome` (5.95, in two of three) —
    /// the two words least likely to be on next month's bill — over `autopay` and `paying`, which
    /// are on every one of them.
    @Test func theRarestWordLosesToTheOneThatComesBack() throws {
        let index = Self.index(memory: ["Home/Utilities/T-Mobile": [
            "appreciation": Anchor(7.05, df: 0.33),
            "awesome": Anchor(5.95, df: 0.67),
            "autopay": Anchor(5.03, df: 1.0),
            "paying": Anchor(4.97, df: 1.0),
        ]])
        let page = "we appreciate you paying with autopay. an awesome plan. our appreciation."
        let p = try #require(propose("DetailedBillApr.pdf", into: "Home/Utilities/T-Mobile",
                                     evidence: .init(pageSample: page, index: index)))
        guard case .mentionsAll(let keys) = p.defaultVariant.conditions.first else {
            Issue.record("expected a mentions rule, got \(p.defaultVariant.summary)"); return
        }
        #expect(Set(keys) == ["autopay", "paying"], "keyed on \(keys)")
        // And the one-in-three word is nowhere in the offer, at any width.
        for variant in p.variants { #expect(!variant.summary.contains("appreciation")) }
    }

    /// The floor is what does it: with the shares removed — an artifact built before the builder
    /// recorded them — the same fixture falls back to the family estimate, which cannot separate
    /// four anchors of one folder, and the rarest words win again. This is the *reason* the
    /// generator changed, stated as a test rather than as a claim.
    @Test func withoutRecordedSharesTheRankingIsRarityAgain() throws {
        let index = Self.index(memory: ["Home/Utilities/T-Mobile": [
            "appreciation": Anchor(7.05), "awesome": Anchor(5.95),
            "autopay": Anchor(5.03), "paying": Anchor(4.97),
        ]])
        let page = "we appreciate you paying with autopay. an awesome plan. our appreciation."
        let p = try #require(propose("DetailedBillApr.pdf", into: "Home/Utilities/T-Mobile",
                                     evidence: .init(pageSample: page, index: index)))
        guard case .mentionsAll(let keys) = p.defaultVariant.conditions.first else {
            Issue.record("expected a mentions rule"); return
        }
        #expect(keys.contains("appreciation"), "the fallback should be rarity-led, got \(keys)")
    }

    /// A word in two thirds of the folder's documents is worth keying on; a word in a third is not.
    @Test func theFloorSitsBetweenTwoThirdsAndOneThird() {
        let index = Self.index(memory: ["Bills/Acme": [
            "acme": Anchor(5.0, df: 1.0), "quarterly": Anchor(5.0, df: 0.67),
            "promotion": Anchor(9.0, df: 0.33),
        ]])
        let p = propose("acme quarterly promotion.pdf", into: "Bills/Acme", evidence: .init(index: index))
        let summaries = (p?.variants ?? []).map(\.summary).joined(separator: " ")
        #expect(summaries.contains("quarterly"))
        #expect(!summaries.contains("promotion"))
    }

    /// **Two words that name the same thing narrow nothing.** `paying` and `autopay` are anchors of
    /// the same folders, so requiring both leaves the rule as broad as either. Given an equally
    /// recurring alternative that shares none of those folders, the pair search must take it.
    @Test func thePairIsChosenForWhatItExcludes() throws {
        var memory: [String: [String: Anchor]] = [
            "Home/Utilities/T-Mobile": ["autopay": Anchor(5.0, df: 1.0),
                                        "paying": Anchor(5.0, df: 1.0),
                                        "myatt": Anchor(4.0, df: 1.0)],
        ]
        // `autopay` and `paying` travel together across twelve other folders; `myatt` appears in
        // none of them, so {autopay, myatt} reaches far less than {autopay, paying}.
        for i in 0..<12 {
            memory["Other/\(i)"] = ["autopay": Anchor(5.0, df: 1.0), "paying": Anchor(5.0, df: 1.0)]
        }
        let index = Self.index(memory: memory)
        let p = try #require(propose("bill.pdf", into: "Home/Utilities/T-Mobile",
                                     evidence: .init(pageSample: "autopay paying myatt", index: index)))
        guard case .mentionsAll(let keys) = p.defaultVariant.conditions.first else {
            Issue.record("expected a mentions rule"); return
        }
        #expect(keys.contains("myatt"), "took the redundant pair: \(keys)")
    }

    /// **Recurrence is compared in half-steps, and the rounding is the decision.** `beta` is in
    /// 90% of the folder's documents and `gamma` in 100%, so a raw comparison always prefers
    /// {alpha, gamma} — even though alpha and gamma travel together through twelve other folders
    /// and requiring both narrows nothing, while {alpha, beta} appears nowhere else. Rounding to
    /// the nearest half makes 1.9 and 2.0 the same answer and lets that difference decide.
    ///
    /// Written because a mutation that replaced the banded compare with a raw one changed nothing
    /// any other test could see, while it moves the shipping numbers from 67.3/54.5 to 71.9/51.7.
    @Test func recurrenceIsComparedInHalfStepsSoOverlapCanDecide() throws {
        var memory: [String: [String: Anchor]] = [
            "Bills/Acme": ["alpha": Anchor(5.0, df: 1.0), "beta": Anchor(5.0, df: 0.9),
                           "gamma": Anchor(5.0, df: 1.0)],
        ]
        for i in 0..<12 {
            memory["Other/\(i)"] = ["alpha": Anchor(5.0, df: 1.0), "gamma": Anchor(5.0, df: 1.0)]
        }
        let index = Self.index(memory: memory)
        let p = try #require(propose("alpha beta gamma.pdf", into: "Bills/Acme",
                                     evidence: .init(index: index)))
        guard case .mentionsAll(let keys) = p.defaultVariant.conditions.first else {
            Issue.record("expected a mentions rule"); return
        }
        #expect(Set(keys) == ["alpha", "beta"], "raw recurrence would have taken gamma: \(keys)")
    }

    /// An identifier is stored hashed on the OTHER list, so the readable share map says nothing
    /// about it — and the recurrence floor would drop the single strongest key a rule can have.
    @Test func aKnownIdentifierClearsTheFloor() throws {
        let index = Self.index(memory: ["Immigration/Petitions": ["uscis": Anchor(4.0, df: 1.0),
                                                                   "notice": Anchor(3.0, df: 1.0)]],
                               ids: ["Immigration/Petitions": ["wac2190123456": Anchor(6.0, df: 1.0)]])
        let p = try #require(propose("USCIS notice WAC2190123456.pdf", into: "Immigration/Petitions",
                                     evidence: .init(index: index)))
        #expect(p.defaultVariant.summary.contains("wac2190123456"), "\(p.defaultVariant.summary)")
    }

    // MARK: The artifact carries the share

    @Test func aThreeElementAnchorDecodesItsShareAndATwoElementOneDoesNot() throws {
        let json = """
        {"profileId":"p","salt":"s","folders":{"F":{"docs":3,
          "anchors":[["autopay",5.03,1.0],["awesome",5.95]],"idHashes":[["abc",2.0,0.5]]}}}
        """
        let memory = try JSONDecoder().decode(FilingMemory.self, from: Data(json.utf8))
        let entry = try #require(memory.folders["F"])
        #expect(entry.anchors.first(where: { $0.token == "autopay" })?.docFrequency == 1.0)
        #expect(entry.anchors.first(where: { $0.token == "awesome" })?.docFrequency == nil)
        #expect(entry.idHashes.first?.docFrequency == 0.5)
    }

    // MARK: Fixtures

    /// One stored anchor: its rarity, and the share of the folder's documents carrying it.
    struct Anchor: ExpressibleByFloatLiteral {
        let weight: Double
        let df: Double?
        init(_ weight: Double, df: Double? = nil) { self.weight = weight; self.df = df }
        init(floatLiteral value: Double) { self.init(value) }
    }

    /// A router index over a memory given as folder → anchor → weight/share (and optionally folder →
    /// identifier → the same). Destinations default to the memory's own folders.
    // MARK: - Rules only a household can express

    /// The roster and a tree where each person has their own OCI folder.
    private static func householdIndex() -> FilingRouter.Index {
        let registry = PersonRegistry(people: [
            Person(id: "abhishek", displayName: "Abhishek", fullNames: ["Abhishek Girish"]),
            Person(id: "aditi", displayName: "Aditi", fullNames: ["Aditi Abhishek"]),
            Person(id: "divit", displayName: "Divit", fullNames: ["Divit Abhishek"]),
        ])
        let folders = ["Immigration/OCI/Aditi", "Immigration/OCI/Divit"]
        var entries: [String: FolderProfileEntry] = [:]
        for f in folders {
            entries[f] = FolderProfileEntry(path: f, role: .personBucket, naming: nil, anchors: [],
                                            acceptsNewFiles: nil, fileCount: 2, subfolderCount: 0,
                                            axes: ["person": (f as NSString).lastPathComponent])
        }
        let profile = FolderProfile(profileId: "t", root: "~", folders: entries,
                                    personTokens: ["aditi", "divit", "abhishek"])
        // Her name is the HEAVIEST anchor of her own folder — every document in it says it. That is
        // what makes the "never key a person rule on their own name" guard reachable: without it
        // the topic word chosen would be "aditi".
        let anchors = ["aditi": 8.0, "oci": 6.0, "overseas": 5.0, "citizen": 4.5]
            .map { FilingMemoryToken(token: $0.key, weight: $0.value, docFrequency: 0.9) }
        let memory = FilingMemory(profileId: "t", salt: "s", folders: [
            "Immigration/OCI/Aditi": FilingMemoryEntry(docs: 4, anchors: anchors, idHashes: []),
            "Immigration/OCI/Divit": FilingMemoryEntry(docs: 4, anchors: anchors, idHashes: []),
        ])
        return FilingRouter.makeIndex(destinations: folders, profile: profile, memory: memory,
                                      registry: registry)
    }

    /// **The rule a word cannot express.** Filing Aditi's OCI card into her own folder offers a
    /// rule keyed on the PERSON, not on the word "aditi" — which would be wrong for most of this
    /// household, since `abhishek` is one person's given name and three others' surname.
    @Test func filingIntoAPersonFolderOffersAPersonRule() throws {
        let p = try #require(propose("Aditi Abhishek - OCI Card.pdf",
                                     into: "Immigration/OCI/Aditi",
                                     evidence: .init(pageSample: "overseas citizen of india, oci",
                                                     index: Self.householdIndex())))
        #expect(p.defaultVariant.conditions.contains(.personIs("aditi")),
                "the leading offer was \(p.defaultVariant.summary)")
        // **A person variant must not ALSO key on their name** — that is the word-keyed rule in
        // disguise, and it re-introduces exactly the ambiguity `personIs` exists to remove. Scoped
        // to the person variants: the ordinary word phrasings below them may legitimately use
        // "aditi", because for them it is just a word this folder's documents share.
        let personVariants = p.variants.filter { variant in
            variant.conditions.contains { if case .personIs = $0 { return true }; return false }
        }
        #expect(!personVariants.isEmpty)
        for variant in personVariants {
            for case .mentionsAll(let words) in variant.conditions {
                #expect(!words.contains("aditi"),
                        "a person rule also keyed on her name: \(variant.summary)")
            }
        }
    }

    /// **One rule, everyone — the point of the whole feature.** A second phrasing drops the person
    /// condition and redirects to `{person}`, so the single rule files each family member's card
    /// into their own folder.
    @Test func aPersonFolderAlsoOffersTheWholeHouseholdInOneRule() throws {
        let p = try #require(propose("Aditi Abhishek - OCI Card.pdf",
                                     into: "Immigration/OCI/Aditi",
                                     evidence: .init(pageSample: "overseas citizen of india, oci",
                                                     index: Self.householdIndex())))
        let fanned = try #require(p.variants.first { $0.destinationTemplate != nil },
                                  "no fan-out offered: \(p.variants.map(\.summary))")
        #expect(fanned.destinationTemplate == "Immigration/OCI/{person}")
        // It must NOT carry the person condition — that would pin the "everyone" rule to one person.
        #expect(!fanned.conditions.contains { if case .personIs = $0 { return true }; return false })
        // Nor may it key on HER name, for the same reason wearing different clothes: a rule that
        // says "mentions aditi → each person's folder" is a rule only Aditi can ever trigger.
        for case .mentionsAll(let words) in fanned.conditions {
            #expect(!words.contains("aditi"), "the household rule only fires for Aditi: \(words)")
        }
    }

    /// A folder that is nobody's in particular gets the ordinary word rule — the person offer is
    /// about person BUCKETS, not about any file that happens to name someone.
    @Test func filingIntoASharedFolderOffersNoPersonRule() throws {
        let index = Self.index(memory: ["Home/Utilities/T-Mobile": ["autopay": Anchor(5.0, df: 0.9)]])
        let p = try #require(propose("Aditi Abhishek - bill.pdf", into: "Home/Utilities/T-Mobile",
                                     evidence: .init(pageSample: "autopay", index: index)))
        for variant in p.variants {
            #expect(!variant.conditions.contains { if case .personIs = $0 { return true }; return false },
                    "offered a person rule for a shared folder: \(variant.summary)")
        }
    }

    private static func index(memory: [String: [String: Anchor]],
                              ids: [String: [String: Anchor]] = [:],
                              destinations: [String]? = nil) -> FilingRouter.Index {
        let salt = "test-salt"
        func tokens(_ m: [String: Anchor], hashed: Bool) -> [FilingMemoryToken] {
            m.map { FilingMemoryToken(token: hashed ? FilingMemory.hash($0.key, salt: salt) : $0.key,
                                      weight: $0.value.weight, docFrequency: $0.value.df) }
        }
        var entries: [String: FilingMemoryEntry] = [:]
        for (folder, anchors) in memory {
            entries[folder] = FilingMemoryEntry(docs: 4, anchors: tokens(anchors, hashed: false),
                                                idHashes: tokens(ids[folder] ?? [:], hashed: true))
        }
        for (folder, identifiers) in ids where entries[folder] == nil {
            entries[folder] = FilingMemoryEntry(docs: 4, anchors: [],
                                                idHashes: tokens(identifiers, hashed: true))
        }
        return FilingRouter.makeIndex(
            destinations: destinations ?? Array(entries.keys),
            profile: nil,
            memory: FilingMemory(profileId: "test", salt: salt, folders: entries))
    }
}
