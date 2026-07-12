import Foundation
import Testing
@testable import Sync

/// Pins the `FilingRule` value type — in particular the `enabled` flag added for G1, whose
/// persistence must stay backward-compatible with rules written before the key existed.
@Suite struct FilingRuleTests {

    @Test func newRuleDefaultsToEnabled() {
        let rule = FilingRule(tokens: ["tesla"], destinationPath: "/p/Vehicles/Tesla")
        #expect(rule.enabled)
    }

    @Test func encodeDecodeRoundTripPreservesEnabled() throws {
        let disabled = FilingRule(tokens: ["invoice", "acme"], destinationPath: "/p/Docs/Invoices", enabled: false)
        let data = try JSONEncoder().encode(disabled)
        let decoded = try JSONDecoder().decode(FilingRule.self, from: data)
        #expect(decoded == disabled)
        #expect(decoded.enabled == false)
        #expect(decoded.tokens == ["invoice", "acme"])
        #expect(decoded.destinationPath == "/p/Docs/Invoices")
    }

    // A rule persisted before `enabled` existed has no such key. It must still decode (defaulting to
    // enabled) — otherwise one legacy rule would fail the whole `[FilingRule]` decode and silently
    // drop every rule the user taught.
    @Test func decodesLegacyJSONWithoutEnabledAsEnabled() throws {
        let legacy = #"{"tokens":["tesla"],"destinationPath":"/p/Vehicles/Tesla"}"#
        let rule = try JSONDecoder().decode(FilingRule.self, from: Data(legacy.utf8))
        #expect(rule.enabled)
        #expect(rule.tokens == ["tesla"])
        #expect(rule.destinationPath == "/p/Vehicles/Tesla")
    }

    // The realistic persisted shape is an array; a legacy array (no `enabled` on any element) must
    // decode whole, every rule defaulting to enabled.
    @Test func decodesLegacyArrayJSON() throws {
        let legacy = #"[{"tokens":["a"],"destinationPath":"/x"},{"tokens":["b"],"destinationPath":"/y"}]"#
        let rules = try JSONDecoder().decode([FilingRule].self, from: Data(legacy.utf8))
        #expect(rules.count == 2)
        #expect(rules.allSatisfy { $0.enabled })
    }

    // The stable id must not shift when a rule is disabled — forget/replace match on id.
    @Test func idIsIndependentOfEnabled() {
        let on = FilingRule(tokens: ["tesla"], destinationPath: "/p/T", enabled: true)
        let off = FilingRule(tokens: ["tesla"], destinationPath: "/p/T", enabled: false)
        #expect(on.id == off.id)
    }
}
