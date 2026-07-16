import Testing
@testable import Sync

/// Pins the plain-words rendering the remembered-rule surfaces use (Settings ▸ Filing and the
/// Tidy ▸ Automations lens) so a learned rule reads as something a person can understand instead
/// of a raw token dump.
@Suite struct FilingRulePhrasingTests {

    @Test func singleTokenReadsNaturally() {
        #expect(FilingRulePhrasing.trigger(["tesla"]) == "Files with \"tesla\"")
    }

    @Test func twoTokensJoinWithAnd() {
        #expect(FilingRulePhrasing.trigger(["invoice", "acme"]) == "Files with \"invoice\" and \"acme\"")
    }

    @Test func threeOrMoreUseSerialComma() {
        #expect(FilingRulePhrasing.trigger(["a", "b", "c"]) == "Files with \"a\", \"b\", and \"c\"")
    }

    @Test func emptyTokensFallBack() {
        #expect(FilingRulePhrasing.trigger([]) == "Any file")
    }

    // A destination outside the home directory is left verbatim (nothing to abbreviate).
    @Test func nonHomeDestinationUnchanged() {
        #expect(FilingRulePhrasing.destination("/Providers/Cars") == "/Providers/Cars")
    }
}
