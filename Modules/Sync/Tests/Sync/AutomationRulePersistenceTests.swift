import Foundation
import Testing
@testable import Sync

/// What happens to a user's automation rules when the persisted shape is not exactly the one this
/// build expects.
///
/// The whole rule set is one JSON blob under one key, so every question here is all-or-nothing: a
/// single value this build cannot read takes the *array* down, every rule vanishes from the UI, and
/// the next rule the user creates writes the empty set back over them. `readPersistedStore` keeps
/// the bytes under a sibling key, which is a floor, not a fix — nothing in the app restores them.
@Suite struct AutomationRulePersistenceTests {

    private static let decoder = JSONDecoder()
    private static let encoder = JSONEncoder()

    /// One rule as a newer build might have written it: every field this build knows, plus one it
    /// does not.
    private static func ruleJSON(id: String = "5C6F0B8E-0000-4000-8000-00000000000A",
                                 name: String = "Invoices",
                                 matchMode: String = "\"all\"",
                                 extra: String = "") -> String {
        """
        {"id":"\(id)","name":"\(name)","enabled":true,"matchMode":\(matchMode),
         "conditions":[{"kindIs":{"_0":"pdf"}}],
         "destinationTemplate":"Documents/Invoices"\(extra)}
        """
    }

    private static func decode(_ json: String) throws -> [AutomationRule] {
        try decoder.decode([AutomationRule].self, from: Data(json.utf8))
    }

    private static func reencode(_ rules: [AutomationRule]) throws -> [[String: Any]] {
        let data = try encoder.encode(rules)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    // MARK: Forward tolerance — a file written by a build that knows more than this one

    @Test func aFieldThisBuildDoesNotKnowSurvivesARoundTrip() throws {
        let json = "[\(Self.ruleJSON(extra: #","priority":7,"note":{"by":"v5"}"#))]"
        let rules = try Self.decode(json)
        #expect(rules.count == 1)
        #expect(rules[0].name == "Invoices")

        // The rule is edited in this build and saved back. The unknown fields must still be there:
        // dropping them is a silent downgrade of the user's data by a build that merely opened it.
        let written = try #require(try Self.reencode(rules).first)
        #expect(written["priority"] as? Int == 7)
        #expect((written["note"] as? [String: Any])?["by"] as? String == "v5")
        // …and the known fields are still written the way they always were.
        #expect(written["name"] as? String == "Invoices")
        #expect(written["destinationTemplate"] as? String == "Documents/Invoices")
    }

    @Test func anUnknownMatchModeCostsOneRuleNotTheWholeSet() throws {
        let json = """
        [\(Self.ruleJSON(name: "Known")),
         \(Self.ruleJSON(id: "5C6F0B8E-0000-4000-8000-00000000000B",
                         name: "FromTheFuture", matchMode: "\"exactlyOne\""))]
        """
        let rules = try Self.decode(json)
        // Before: `MatchMode(rawValue:)` threw here and took BOTH rules with it.
        #expect(rules.count == 2)
        #expect(rules[0].name == "Known")
        #expect(rules[0].isRunnable)

        // The rule that arrived with a mode this build cannot evaluate is visible and editable but
        // INERT — guessing `all` or `any` would file the user's files by a rule they never wrote.
        let future = rules[1]
        #expect(future.name == "FromTheFuture")
        #expect(!future.isRunnable)

        // And the mode is written back exactly as it came, so the build that understands it still
        // finds its own rule intact.
        let written = try Self.reencode(rules)
        #expect(written[0]["matchMode"] as? String == "all")
        #expect(written[1]["matchMode"] as? String == "exactlyOne")
    }

    // MARK: Backward tolerance — a file missing something this build expects

    @Test func aMissingFieldCostsItsDefaultNotTheWholeSet() throws {
        // A future build that renames or drops a field, or a hand-edited plist. Only `conditions`
        // and `name` are given; everything else has to fall back.
        let json = #"[{"name":"Sparse","conditions":[]}]"#
        let rules = try Self.decode(json)
        #expect(rules.count == 1)
        #expect(rules[0].name == "Sparse")
        #expect(rules[0].enabled)                       // the initializer's own default
        #expect(rules[0].matchMode == .all)
        #expect(rules[0].destinationTemplate.isEmpty)
        #expect(!rules[0].isRunnable)                   // no destination — correctly inert
    }

    @Test func aRuleWithNoIdGetsOneRatherThanTakingTheSetDown() throws {
        let json = #"[{"name":"NoId","conditions":[],"destinationTemplate":"X"}]"#
        let rules = try Self.decode(json)
        #expect(rules.count == 1)
        // A fresh id is stable from here on: it is written on the next save.
        let written = try #require(try Self.reencode(rules).first)
        #expect(written["id"] as? String == rules[0].id.uuidString)
    }

    // MARK: The ordinary case still round-trips byte-for-byte in meaning

    /// The wire shape must be **exactly what the synthesized codec wrote**, because every rule
    /// already on disk was written by it. A hand-written encoder is free to invent a shape; this is
    /// what stops it. Six keys, no more (an unknown-field bag that leaked would show up here as a
    /// seventh), spelled and typed as before.
    @Test func theStoredShapeIsStillTheOneEveryExistingRuleWasWrittenIn() throws {
        let rule = AutomationRule(name: "PDFs", enabled: false, matchMode: .any,
                                  conditions: [.kindIs(.pdf)], destinationTemplate: "Docs")
        let written = try #require(try Self.reencode([rule]).first)
        #expect(Set(written.keys) == ["id", "name", "enabled", "matchMode", "conditions", "destinationTemplate"])
        #expect(written["id"] as? String == rule.id.uuidString)
        #expect(written["name"] as? String == "PDFs")
        #expect(written["enabled"] as? Bool == false)
        #expect(written["matchMode"] as? String == "any")
        #expect(written["destinationTemplate"] as? String == "Docs")
        // The condition's own shape is the synthesized one and is not this decoder's business —
        // check only that it is still the single-key object every stored rule carries.
        let conditions = try #require(written["conditions"] as? [[String: Any]])
        #expect(conditions.count == 1)
        #expect(Set(conditions[0].keys) == ["kindIs"])
    }

    @Test func aRuleThisBuildWroteReadsBackUnchanged() throws {
        let original = AutomationRule(name: "PDFs", enabled: false, matchMode: .any,
                                      conditions: [.kindIs(.pdf), .contentContains("invoice")],
                                      destinationTemplate: "Documents/{year}")
        let data = try Self.encoder.encode([original])
        let back = try Self.decoder.decode([AutomationRule].self, from: data)
        #expect(back == [original])
    }
}
