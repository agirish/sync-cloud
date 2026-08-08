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
        var folders: [String: [String: Double]] = ["Finance/US/Chase": ["chase": 4.0, "statement": 9.0]]
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

    // MARK: Fixtures

    /// A router index over a memory given as folder → anchor → weight (and optionally folder →
    /// identifier → weight). Destinations default to the memory's own folders.
    private static func index(memory: [String: [String: Double]],
                              ids: [String: [String: Double]] = [:],
                              destinations: [String]? = nil) -> FilingRouter.Index {
        let salt = "test-salt"
        var entries: [String: FilingMemoryEntry] = [:]
        for (folder, anchors) in memory {
            entries[folder] = FilingMemoryEntry(
                docs: 4,
                anchors: anchors.map { FilingMemoryToken(token: $0.key, weight: $0.value) },
                idHashes: (ids[folder] ?? [:]).map {
                    FilingMemoryToken(token: FilingMemory.hash($0.key, salt: salt), weight: $0.value)
                })
        }
        for (folder, identifiers) in ids where entries[folder] == nil {
            entries[folder] = FilingMemoryEntry(
                docs: 4, anchors: [],
                idHashes: identifiers.map {
                    FilingMemoryToken(token: FilingMemory.hash($0.key, salt: salt), weight: $0.value)
                })
        }
        return FilingRouter.makeIndex(
            destinations: destinations ?? Array(entries.keys),
            profile: nil,
            memory: FilingMemory(profileId: "test", salt: salt, folders: entries))
    }
}
