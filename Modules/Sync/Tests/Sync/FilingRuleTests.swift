import Foundation
import Testing
@testable import Sync

/// Pins the `FilingRule` value type, in particular the `enabled` flag.
@Suite struct FilingRuleTests {

    @Test func newRuleDefaultsToEnabled() {
        let rule = FilingRule(tokens: ["tesla"], destinationPath: "/p/Vehicles/Tesla")
        #expect(rule.enabled)
    }

    @Test func encodeDecodeRoundTripPreservesEnabled() throws {
        let disabled = FilingRule(tokens: ["invoice", "acme"], destinationPath: "/p/Docs/Invoices", enabled: false)
        let data = try JSONEncoder().encode(disabled)
        let decoded = try JSONDecoder().decode(FilingRule.self, from: data)
        #expect(decoded == disabled)   // synthesized Equatable: enabled, tokens and path included
    }

    // The stable id must not shift when a rule is disabled: forget and replace match on id.
    @Test func idIsIndependentOfEnabled() {
        let on = FilingRule(tokens: ["tesla"], destinationPath: "/p/T", enabled: true)
        let off = FilingRule(tokens: ["tesla"], destinationPath: "/p/T", enabled: false)
        #expect(on.id == off.id)
    }
}
