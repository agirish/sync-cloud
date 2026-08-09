import Foundation
import Testing
@testable import Sync

/// The `personIs` condition, the `{person}` destination token, and the persistence tolerance that
/// had to come with them.
@Suite struct PersonRuleTests {

    static let now = Date(timeIntervalSince1970: 1_786_000_000)

    static let household = PersonRegistry(people: [
        Person(id: "abhishek", displayName: "Abhishek", fullNames: ["Abhishek Girish"]),
        Person(id: "aditi", displayName: "Aditi", fullNames: ["Aditi Abhishek"]),
        Person(id: "divit", displayName: "Divit", fullNames: ["Divit Abhishek"]),
        Person(id: "muktha", displayName: "Muktha", fullNames: ["Muktha Girish"], aliases: ["Mom"]),
    ])

    static func facts(_ name: String, snippet: String? = nil,
                      registry: PersonRegistry? = household) -> AutomationFileFacts {
        AutomationFileFacts(path: "/root/TODO/\(name)", name: name, parentFolderName: "TODO",
                            parentPath: "/root/TODO", sizeBytes: 1_000, modificationDate: now,
                            isDirectory: false, snippet: snippet?.lowercased(),
                            contentTokens: snippet.map { FilingEngine.nameTokens($0) } ?? [])
            .attributing(registry)
    }

    // MARK: - Matching

    /// The rule keys on the id, and the id is reached through the registry — so a document naming
    /// her by her **full name** matches a rule that says "is Aditi's document".
    @Test func aPersonRuleMatchesEveryNameFormThatPersonHas() {
        let rule = AutomationRule(name: "Aditi", conditions: [.personIs("aditi")],
                                  destinationTemplate: "School/Aditi")
        #expect(AutomationEvaluator.matches(rule, Self.facts("Aditi Abhishek - Report.pdf"), now: Self.now))
        #expect(AutomationEvaluator.matches(rule, Self.facts("Aditi - Report.pdf"), now: Self.now))
        #expect(!AutomationEvaluator.matches(rule, Self.facts("Divit Abhishek - Report.pdf"), now: Self.now))
    }

    /// An alias is the same person, so `Mom - passport.pdf` matches a rule about Muktha — the thing
    /// a word-keyed rule could only do by listing every spelling and would still get wrong.
    @Test func anAliasMatchesThePersonItNames() {
        let rule = AutomationRule(name: "Mum", conditions: [.personIs("muktha")],
                                  destinationTemplate: "Family/Muktha")
        #expect(AutomationEvaluator.matches(rule, Self.facts("Mom - passport.pdf"), now: Self.now))
    }

    /// **The filename outranks the page, here as everywhere.** `attribute` is the one precedence
    /// rule, shared with the cross-person veto: a file the user labelled Divit is Divit's, whatever
    /// a sibling's name on the page says.
    @Test func theFilenameOutranksThePageForRulesToo() {
        let aditi = AutomationRule(name: "Aditi", conditions: [.personIs("aditi")],
                                   destinationTemplate: "School/Aditi")
        let facts = Self.facts("Divit - Report Card.pdf",
                               snippet: "Sibling of Aditi Abhishek, same school")
        #expect(!AutomationEvaluator.matches(aditi, facts, now: Self.now),
                "a mention of Aditi on the page pulled Divit's report card into her rule")

        // And a file whose NAME names nobody falls through to the page — the nameless-scan case.
        let scan = Self.facts("Scan 2026-08-02.pdf", snippet: "Report card for Aditi Abhishek")
        #expect(AutomationEvaluator.matches(aditi, scan, now: Self.now))
    }

    /// With no roster loaded a person rule matches nothing — it must not match *everything*, which
    /// is what an empty-set containment test would do if it were inverted.
    @Test func withNoRosterAPersonRuleIsInert() {
        let rule = AutomationRule(name: "Aditi", conditions: [.personIs("aditi")],
                                  destinationTemplate: "School/Aditi")
        #expect(!AutomationEvaluator.matches(rule, Self.facts("Aditi - Report.pdf", registry: nil),
                                             now: Self.now))
    }

    /// A rule pointing at a person who has since been removed is incomplete-by-value, not a crash
    /// and not a match-all.
    @Test func aRuleNamingNobodyMatchesNothing() {
        let rule = AutomationRule(name: "Ghost", conditions: [.personIs("ravi")],
                                  destinationTemplate: "Family/Ravi")
        #expect(!AutomationEvaluator.matches(rule, Self.facts("Aditi - Report.pdf"), now: Self.now))
        #expect(AutomationCondition.personIs("").isComplete == false)
        #expect(AutomationCondition.personIs("aditi").isComplete)
    }

    // MARK: - {person}

    /// **One rule, everyone.** The token resolves to the folder name of whoever the document names,
    /// so a single rule files each person's card into their own folder.
    @Test func thePersonTokenResolvesToTheirFolder() {
        for (file, folder) in [("Aditi Abhishek - OCI.pdf", "Aditi"),
                               ("Divit Abhishek - OCI.pdf", "Divit"),
                               ("Mom - OCI.pdf", "Muktha")] {
            let resolved = AutomationEvaluator.resolveDestination("Immigration/OCI/{person}",
                                                                  for: Self.facts(file),
                                                                  providerName: nil, now: Self.now)
            #expect(resolved == .resolved("Immigration/OCI/\(folder)"), "\(file) resolved wrong")
        }
    }

    /// **Unresolved, never guessed** — the same contract every other token has. A document naming
    /// nobody, or naming two people, has no single folder to go to, and the dry run reports that
    /// rather than filing it somewhere plausible.
    @Test func thePersonTokenRefusesToGuess() {
        let nobody = AutomationEvaluator.resolveDestination("Immigration/OCI/{person}",
                                                            for: Self.facts("Scan 2026-08-02.pdf"),
                                                            providerName: nil, now: Self.now)
        #expect(nobody == .unresolved(token: "{person}"))

        let both = AutomationEvaluator.resolveDestination(
            "Immigration/OCI/{person}",
            for: Self.facts("Abhishek Girish and Muktha Girish - Deed.pdf"),
            providerName: nil, now: Self.now)
        #expect(both == .unresolved(token: "{person}"),
                "a document naming two people was filed into one of their folders")
    }

    // MARK: - Persistence that survives a version it does not know

    /// The wire shape is **exactly** what the synthesized Codable wrote, so a rule saved by an
    /// older build still decodes. Pinned as literal JSON rather than a round-trip, because a
    /// round-trip cannot notice that both sides changed together.
    @Test func theWireShapeIsUnchanged() throws {
        let json = #"[{"kindIs":{"_0":"pdf"}},{"mentionsAll":{"_0":["invoice","acme"]}},"#
            + #"{"personIs":{"_0":"aditi"}}]"#
        let decoded = try JSONDecoder().decode([AutomationCondition].self, from: Data(json.utf8))
        #expect(decoded == [.kindIs(.pdf), .mentionsAll(["invoice", "acme"]), .personIs("aditi")])

        let reencoded = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode([AutomationCondition].self, from: reencoded)
        #expect(again == decoded)
    }

    /// **The failure this whole tolerance exists to stop.** Rules persist as ONE blob, so an
    /// unknown case name used to throw for the entire array: every rule vanished from the UI, and
    /// the next edit wrote the empty set back over them. Now the unknown condition survives as
    /// itself and its neighbours are untouched.
    @Test func aConditionFromANewerBuildDoesNotDestroyTheOthers() throws {
        let json = #"[{"kindIs":{"_0":"pdf"}},{"vibeIs":{"_0":{"mood":"calm","level":3}}},"#
            + #"{"personIs":{"_0":"aditi"}}]"#
        let decoded = try JSONDecoder().decode([AutomationCondition].self, from: Data(json.utf8))
        #expect(decoded.count == 3, "the unknown condition took its neighbours with it")
        #expect(decoded[0] == .kindIs(.pdf))
        #expect(decoded[2] == .personIs("aditi"))
        guard case .unrecognized(let name, _) = decoded[1] else {
            Issue.record("the unknown condition was not preserved: \(decoded[1])")
            return
        }
        #expect(name == "vibeIs")
        // It can never match, so a rule carrying it cannot file anything on a partial reading.
        #expect(!decoded[1].isComplete)
        #expect(!AutomationEvaluator.matches(decoded[1], Self.facts("anything.pdf"), now: Self.now))
    }

    /// And it round-trips **verbatim**, so passing a newer build's rule through this one does not
    /// quietly rewrite it.
    @Test func anUnknownConditionRoundTripsUnchanged() throws {
        let json = #"[{"vibeIs":{"_0":{"level":3,"mood":"calm"}}}]"#
        let decoded = try JSONDecoder().decode([AutomationCondition].self, from: Data(json.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let out = String(decoding: try encoder.encode(decoded), as: UTF8.self)
        #expect(out == json)
    }

    /// A rule carrying an unknown condition is not runnable, so it is visible and editable but
    /// never fires on the half of it this build understands.
    @Test func aRuleWithAnUnknownConditionIsNotRunnable() {
        let rule = AutomationRule(name: "From the future", matchMode: .all,
                                  conditions: [.kindIs(.pdf),
                                               .unrecognized(name: "vibeIs", payload: Data("{}".utf8))],
                                  destinationTemplate: "Documents")
        #expect(!rule.isRunnable)
    }

    // MARK: - The summary a person reads

    @Test func theSummaryUsesTheNameNotTheSlug() {
        let condition = AutomationCondition.personIs("aditi")
        #expect(condition.summary(resolvingPeople: Self.household) == "is Aditi's document")
        // A rule pointing at a removed person says so rather than rendering blank.
        #expect(AutomationCondition.personIs("ravi").summary(resolvingPeople: Self.household)
                == "is ravi's document (not on your People list)")
    }
}
