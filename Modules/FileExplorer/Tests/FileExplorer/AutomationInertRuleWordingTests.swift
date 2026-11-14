import Foundation
import Testing
@testable import FileExplorer
import Sync

/// How the Automations lens explains a rule that will not run. "Incomplete" is advice: finish the
/// rule and it works. A rule from a newer build already has its condition and destination; this
/// build can't read part of it and won't act on it. "Give the rule a condition" would send the user
/// looking for nothing, and an edit would discard the newer build's data, so the tooltip warns.
@Suite struct AutomationInertRuleWordingTests {

    /// The only way to build a rule carrying a value this build cannot read: decode one.
    private static func ruleFromANewerBuild() throws -> AutomationRule {
        let json = """
        [{"id":"5C6F0B8E-0000-4000-8000-0000000000F1","name":"FromTheFuture","enabled":true,
          "matchMode":"exactlyOne","conditions":[{"kindIs":{"_0":"pdf"}}],
          "destinationTemplate":"Docs"}]
        """
        let rules = try JSONDecoder().decode([AutomationRule].self, from: Data(json.utf8))
        let rule = try #require(rules.first)
        // The suite's premise: were the rule readable, these assertions would pass vacuously
        // against the "incomplete" wording.
        try #require(rule.hasUnreadableValues)
        try #require(!rule.isRunnable)
        return rule
    }

    private static let complete = AutomationRule(name: "PDFs", conditions: [.kindIs(.pdf)],
                                                 destinationTemplate: "Docs")
    private static let halfBuilt = AutomationRule(name: "Half", conditions: [], destinationTemplate: "")

    @Test func theThreeKindsOfRuleGetThreeDifferentPills() throws {
        #expect(AutomationsLens.inertPillLabel(for: Self.complete) == nil)
        #expect(AutomationsLens.inertPillLabel(for: Self.halfBuilt) == "incomplete")
        #expect(AutomationsLens.inertPillLabel(for: try Self.ruleFromANewerBuild()) == "newer version")
    }

    @Test func thePreviewTooltipNamesTheRealBlocker() throws {
        #expect(AutomationsLens.previewHelp(for: Self.halfBuilt, hasDestinationRoot: true)
                .contains("condition and destination"))
        // A complete rule with nothing focused: the folder is the blocker, not the rule.
        #expect(AutomationsLens.previewHelp(for: Self.complete, hasDestinationRoot: false)
                .contains("Focus a provider folder"))
        #expect(AutomationsLens.previewHelp(for: Self.complete, hasDestinationRoot: true)
                == "Preview just this rule over the focused folder")

        // A rule from a newer build: neither of the two above, and it warns about the edit.
        let future = AutomationsLens.previewHelp(for: try Self.ruleFromANewerBuild(), hasDestinationRoot: true)
        #expect(future.contains("newer version of SyncCloud"))
        #expect(future.contains("editing it will rewrite"))
        #expect(!future.contains("condition and destination"))
    }

    /// The call-site half: the view could go back to spelling `!rule.isRunnable ? "incomplete" :
    /// nil` inline and every assertion above would still pass while the app showed that wording.
    @Test func theLensAsksTheseRulesRatherThanSpellingThemInline() throws {
        let source = try Self.lensSource()
        #expect(source.contains("AutomationsLens.inertPillLabel(for: rule)"),
                "The name row no longer asks inertPillLabel — the pill wording above is unused.")
        #expect(source.contains("Self.previewHelp("),
                "The card no longer asks previewHelp — the tooltip wording above is unused.")
        // And the strings live in exactly one place: the literals must not reappear in a view body.
        #expect(source.components(separatedBy: "\"incomplete\"").count - 1 == 1,
                "The \"incomplete\" literal appears more than once — one of them is a second spelling.")
        #expect(source.components(separatedBy: "Give the rule a condition and destination").count - 1 == 1,
                "The half-built tooltip appears more than once — one of them is a second spelling.")
    }

    private static func lensSource() throws -> String { try SourceText.fileExplorer("AutomationsLens.swift") }
}
