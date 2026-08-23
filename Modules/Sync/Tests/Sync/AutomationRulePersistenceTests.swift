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

    /// Decodes a two-rule array and re-encodes it, returning each rule beside the object it was
    /// written back as.
    ///
    /// **`#require`, not `#expect`, on the counts.** `#expect` records and CONTINUES, so a wrong
    /// count is followed by a subscript on a short array — which traps the whole test host, turns a
    /// clean failure into `signal code 5`, and loses every test after it in the run. That is not
    /// hypothetical here: it is exactly how the first version of these tests reported the bug they
    /// were written to catch.
    private static func decodeAPair(_ json: String) throws
        -> (first: (rule: AutomationRule, written: [String: Any]),
            second: (rule: AutomationRule, written: [String: Any])) {
        let rules = try decode(json)
        try #require(rules.count == 2)
        let written = try reencode(rules)
        try #require(written.count == 2)
        return ((rules[0], written[0]), (rules[1], written[1]))
    }

    // MARK: Forward tolerance — a file written by a build that knows more than this one

    @Test func aFieldThisBuildDoesNotKnowSurvivesARoundTrip() throws {
        let json = "[\(Self.ruleJSON(extra: #","priority":7,"note":{"by":"v5"}"#))]"
        let rules = try Self.decode(json)
        #expect(rules.count == 1)
        let rule = try #require(rules.first)
        #expect(rule.name == "Invoices")

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
        // Before: `MatchMode(rawValue:)` threw here and took BOTH rules with it.
        let (known, future) = try Self.decodeAPair(json)
        #expect(known.rule.name == "Known")
        #expect(known.rule.isRunnable)

        // The rule that arrived with a mode this build cannot evaluate is visible and editable but
        // INERT — guessing `all` or `any` would file the user's files by a rule they never wrote.
        #expect(future.rule.name == "FromTheFuture")
        #expect(!future.rule.isRunnable)

        // And the mode is written back exactly as it came, so the build that understands it still
        // finds its own rule intact.
        #expect(known.written["matchMode"] as? String == "all")
        #expect(future.written["matchMode"] as? String == "exactlyOne")
    }

    @Test func aConditionThisBuildCannotReadIsCarriedBackToDiskUntouched() throws {
        // The trap that a tolerant decoder walks straight into: swallowing the error and taking the
        // default leaves the rule looking like "any file -> Docs", and the NEXT SAVE writes that
        // empty condition list over the real one. Failing loudly at least kept the bytes (the
        // undecodable payload is preserved under a sibling key); failing quietly does not, because
        // the decode succeeded and nothing was set aside.
        //
        // A condition name no build knows, so this reads the same on every line — whether the
        // degradation happens per condition or per rule, the outcome has to be the same.
        let json = """
        [\(Self.ruleJSON(name: "Known")),
         {"id":"5C6F0B8E-0000-4000-8000-00000000000D","name":"FutureCondition","enabled":true,
          "matchMode":"all","conditions":[{"phaseOfTheMoon":{"_0":"waxing"}}],
          "destinationTemplate":"Docs"}]
        """
        let (known, future) = try Self.decodeAPair(json)
        #expect(known.rule.isRunnable)

        // Inert: a rule this build cannot fully read must not claim files.
        #expect(!future.rule.isRunnable)

        // And — the point — the condition goes back to disk exactly as it came.
        let condition = try #require((future.written["conditions"] as? [[String: Any]])?.first)
        #expect((future.written["conditions"] as? [[String: Any]])?.count == 1)
        #expect((condition["phaseOfTheMoon"] as? [String: Any])?["_0"] as? String == "waxing")
    }

    @Test func anUnknownFileKindIsCarriedBackToDiskUntouched() throws {
        // `FileKind` is a raw-value enum decoded strictly, so a kind a newer build added is the
        // most likely way for a condition to become unreadable in practice.
        let json = """
        [\(Self.ruleJSON(name: "Known")),
         {"id":"5C6F0B8E-0000-4000-8000-00000000000C","name":"FutureKind","enabled":true,
          "matchMode":"all","conditions":[{"kindIs":{"_0":"spreadsheetOfTheFuture"}}],
          "destinationTemplate":"Docs"}]
        """
        let (known, future) = try Self.decodeAPair(json)
        #expect(known.rule.isRunnable)
        #expect(!future.rule.isRunnable)

        let condition = try #require((future.written["conditions"] as? [[String: Any]])?.first)
        #expect((condition["kindIs"] as? [String: Any])?["_0"] as? String == "spreadsheetOfTheFuture")
    }

    /// The narrower half, which only this line can do: a condition whose payload is unreadable
    /// costs THAT CONDITION, not the whole `conditions` array, so the rule's other conditions keep
    /// their meaning. `v2.x` and `v3.x` have no ``AutomationCondition/unrecognized`` case to put it
    /// in, and degrade the rule instead — safe, but blunter.
    @Test func anUnreadableConditionDoesNotCostTheRuleItsOtherConditions() throws {
        let json = """
        [{"id":"5C6F0B8E-0000-4000-8000-00000000000E","name":"Mixed","enabled":true,
          "matchMode":"all",
          "conditions":[{"kindIs":{"_0":"spreadsheetOfTheFuture"}},
                        {"folderNamed":{"_0":"Downloads"}}],
          "destinationTemplate":"Docs"}]
        """
        let rules = try Self.decode(json)
        let rule = try #require(rules.first)
        #expect(rule.conditions.count == 2)
        // The one it could read is a real condition, not a blob.
        #expect(rule.conditions.contains(.folderNamed("Downloads")))
        // The one it could not is carried under its own name and is never complete, so an ALL-OF
        // rule holding it can never match — which is the whole point.
        let carried = try #require(rule.conditions.first { if case .unrecognized = $0 { return true } else { return false } })
        if case .unrecognized(let name, _) = carried { #expect(name == "kindIs") }
        #expect(!carried.isComplete)
        #expect(!rule.isRunnable)
    }

    /// **The same narrowing, for a condition whose payload is not an object at all.**
    ///
    /// The test above degrades one condition because its payload IS the `{"_0": …}` object this
    /// build expects and only the value inside is unknown. A newer build that flattens the wire
    /// shape — `{"kindIs":"pdf"}` — hits `nestedContainer(keyedBy:forKey:)`, which threw out of the
    /// condition's initializer before the recovery below could run. The whole `conditions` array
    /// then read as unreadable, and the rule lost every other condition's meaning: exactly the
    /// failure the narrowing exists to prevent, reachable by the same kind of future build.
    ///
    /// `RawPayload` can carry any JSON value, so the recovery was already able to hold it — it was
    /// only being reached too late.
    @Test func aConditionPayloadThatIsNotAnObjectCostsOneConditionToo() throws {
        let json = """
        [{"id":"5C6F0B8E-0000-4000-8000-00000000000F","name":"Flat","enabled":true,
          "matchMode":"all",
          "conditions":[{"kindIs":"pdf"},
                        {"folderNamed":{"_0":"Downloads"}}],
          "destinationTemplate":"Docs"}]
        """
        let rules = try Self.decode(json)
        let rule = try #require(rules.first)
        #expect(rule.conditions.count == 2, "the whole array was carried as one unreadable field")
        #expect(rule.conditions.contains(.folderNamed("Downloads")))
        let carried = try #require(rule.conditions.first { if case .unrecognized = $0 { return true } else { return false } })
        if case .unrecognized(let name, _) = carried { #expect(name == "kindIs") }
        #expect(!rule.isRunnable)
        // And the flattened payload goes back to disk as it arrived, not as an object.
        let written = try Self.reencode(rules)
        let conditions = try #require(written.first?["conditions"] as? [[String: Any]])
        #expect(conditions.contains { $0["kindIs"] as? String == "pdf" },
                "the payload was rewritten on the way out; got \(conditions)")
    }

    /// A carried field has to come back the SAME VALUE, not merely the same shape.
    ///
    /// Holding every JSON number as a `Double` looks harmless — `7` still writes as `7`, not
    /// `7.0` — right up to 2^53, past which the value is silently rewritten. Nineteen-digit
    /// nanosecond timestamps live there. A bag whose whole contract is "carry this back untouched"
    /// must not be what alters it.
    @Test func aCarriedFieldKeepsItsExactValueWhateverItsType() throws {
        let extra = #","priority":7,"ratio":0.25,"createdAtNanos":1755112233123456789,"on":true,"tag":null,"list":[1,"a"]"#
        let rules = try Self.decode("[\(Self.ruleJSON(extra: extra))]")
        let written = try #require(try Self.reencode(rules).first)

        #expect(written["priority"] as? Int == 7)
        #expect(written["ratio"] as? Double == 0.25)
        #expect(written["on"] as? Bool == true, "a bool must not come back as the number 1")
        #expect(written["tag"] is NSNull)
        #expect((written["list"] as? [Any])?.count == 2)
        // The one that was wrong: 1755112233123456789 came back as 1755112233123456768.
        #expect(written["createdAtNanos"] as? Int == 1_755_112_233_123_456_789)

        // And the bytes a NEWER build reads must still decode as the types it wrote them as —
        // a Double where an Int was written throws on the way back in.
        struct Probe: Decodable { let priority: Int; let createdAtNanos: Int; let on: Bool }
        let data = try JSONSerialization.data(withJSONObject: written)
        let probe = try JSONDecoder().decode(Probe.self, from: data)
        #expect(probe.priority == 7)
        #expect(probe.createdAtNanos == 1_755_112_233_123_456_789)
        #expect(probe.on)
    }

    /// **The same rewrite, one range further out.** `integer` before `number` fixed everything up
    /// to `Int64.max`; a value above it — a 20-digit id, a `UInt64` hash — still failed
    /// `decode(Int.self)`, fell through to `Double`, and came back altered:
    /// `18446744073709551615` was written as `18446744073709552000`.
    ///
    /// The residual is stated rather than papered over: past `UInt64.max` this degrades to `Double`
    /// as before, because carrying arbitrary precision would mean keeping the source token, which
    /// `Codable` does not hand us. The test says where the guarantee ends.
    @Test func aCarriedIntegerAboveInt64MaxIsStillCarriedExactly() throws {
        let extra = #","hugeId":18446744073709551615,"atInt64Max":9223372036854775807"#
        let rules = try Self.decode("[\(Self.ruleJSON(extra: extra))]")
        let written = try #require(try Self.reencode(rules).first)

        // Read back through JSON rather than as `Int`: the value does not fit one, which is the
        // whole point, and `as? Int` would report nil for a correctly carried value.
        let data = try JSONSerialization.data(withJSONObject: written)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("18446744073709551615"),
                "a UInt64-range id was rewritten on the way out; got \(text)")
        #expect(!text.contains("18446744073709552000"),
                "the value came back as the Double approximation")

        // The boundary itself still round-trips through the Int path, unchanged.
        #expect(written["atInt64Max"] as? Int == 9_223_372_036_854_775_807)
    }

    // MARK: Backward tolerance — a file missing something this build expects

    @Test func aMissingFieldCostsItsDefaultNotTheWholeSet() throws {
        // A future build that renames or drops a field, or a hand-edited plist. Only `conditions`
        // and `name` are given; everything else has to fall back.
        let json = #"[{"name":"Sparse","conditions":[]}]"#
        let rules = try Self.decode(json)
        #expect(rules.count == 1)
        let rule = try #require(rules.first)
        #expect(rule.name == "Sparse")
        #expect(rule.enabled)                           // the initializer's own default
        #expect(rule.matchMode == .all)
        #expect(rule.destinationTemplate.isEmpty)
        #expect(!rule.isRunnable)                       // no destination — correctly inert
    }

    @Test func aRuleWithNoIdGetsOneRatherThanTakingTheSetDown() throws {
        let json = #"[{"name":"NoId","conditions":[],"destinationTemplate":"X"}]"#
        let rules = try Self.decode(json)
        #expect(rules.count == 1)
        let rule = try #require(rules.first)
        // A fresh id is stable from here on: it is written on the next save.
        let written = try #require(try Self.reencode(rules).first)
        #expect(written["id"] as? String == rule.id.uuidString)
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
        #expect(Set(try #require(conditions.first).keys) == ["kindIs"])
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
