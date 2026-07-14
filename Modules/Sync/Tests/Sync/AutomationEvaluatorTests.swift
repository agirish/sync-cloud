import Foundation
import Testing
@testable import Sync

@Suite struct AutomationEvaluatorTests {

    // Mid-2024, mid-day UTC — year 2024 / month 07 in every timezone.
    private let now = Date(timeIntervalSince1970: 1_720_000_000)

    private func facts(
        _ name: String,
        parent: String = "Downloads",
        size: Int = 1_000,
        modified: Date? = nil,
        snippet: String? = nil
    ) -> AutomationFileFacts {
        AutomationFileFacts(
            path: "/root/\(parent)/\(name)", name: name,
            parentFolderName: parent, parentPath: "/root/\(parent)",
            sizeBytes: size, modificationDate: modified, isDirectory: false,
            snippet: snippet?.lowercased()
        )
    }

    // MARK: Individual conditions

    @Test func folderNamedIsCaseInsensitive() {
        #expect(AutomationEvaluator.matches(.folderNamed("downloads"), facts("a.txt", parent: "Downloads"), now: now))
        #expect(!AutomationEvaluator.matches(.folderNamed("Desktop"), facts("a.txt", parent: "Downloads"), now: now))
    }

    @Test func nameGlobMatches() {
        #expect(AutomationEvaluator.matches(.nameMatches("*.pdf"), facts("Report.PDF"), now: now))
        #expect(AutomationEvaluator.matches(.nameMatches("IMG_*"), facts("IMG_2024.jpg"), now: now))
        #expect(!AutomationEvaluator.matches(.nameMatches("*.pdf"), facts("Report.docx"), now: now))
    }

    @Test func kindMatchesByExtension() {
        #expect(AutomationEvaluator.matches(.kindIs(.pdf), facts("a.pdf"), now: now))
        #expect(AutomationEvaluator.matches(.kindIs(.image), facts("a.jpg"), now: now))
        #expect(AutomationEvaluator.matches(.kindIs(.archive), facts("a.zip"), now: now))
        #expect(!AutomationEvaluator.matches(.kindIs(.image), facts("a.pdf"), now: now))
        // A PDF resolves to .pdf, never the broad .document kind.
        #expect(FileKind.of(fileName: "a.pdf") == .pdf)
        #expect(FileKind.of(fileName: "notes.txt") == .document)
        #expect(FileKind.of(fileName: "noext") == nil)
    }

    @Test func sizeThresholdIsStrictGreaterAndDecimalMB() {
        #expect(AutomationEvaluator.matches(.largerThanMB(100), facts("big", size: 150_000_000), now: now))
        #expect(!AutomationEvaluator.matches(.largerThanMB(100), facts("exact", size: 100_000_000), now: now))
        #expect(!AutomationEvaluator.matches(.largerThanMB(100), facts("small", size: 50_000_000), now: now))
    }

    @Test func untouchedForDaysUsesModificationDate() {
        let old = now.addingTimeInterval(-400 * 86_400)
        let fresh = now.addingTimeInterval(-10 * 86_400)
        #expect(AutomationEvaluator.matches(.untouchedForDays(365), facts("old", modified: old), now: now))
        #expect(!AutomationEvaluator.matches(.untouchedForDays(365), facts("fresh", modified: fresh), now: now))
        // No modification date → can't be "untouched", so no match.
        #expect(!AutomationEvaluator.matches(.untouchedForDays(365), facts("undated", modified: nil), now: now))
    }

    @Test func contentContainsNeedsSnippet() {
        #expect(AutomationEvaluator.matches(.contentContains("invoice"),
                                            facts("a.pdf", snippet: "This INVOICE is due"), now: now))
        #expect(!AutomationEvaluator.matches(.contentContains("invoice"),
                                             facts("a.pdf", snippet: "a receipt"), now: now))
        // No snippet loaded yet → content condition is false (the manager fetches text first).
        #expect(!AutomationEvaluator.matches(.contentContains("invoice"), facts("a.pdf", snippet: nil), now: now))
    }

    // MARK: Match modes & rule matching

    @Test func allVsAnyMode() {
        let f = facts("Invoice_ACME.pdf", snippet: "invoice total")
        let all = AutomationRule(name: "r", matchMode: .all,
                                 conditions: [.kindIs(.pdf), .contentContains("invoice")],
                                 destinationTemplate: "X")
        let any = AutomationRule(name: "r", matchMode: .any,
                                 conditions: [.kindIs(.image), .contentContains("invoice")],
                                 destinationTemplate: "X")
        #expect(AutomationEvaluator.matches(all, f, now: now))
        #expect(AutomationEvaluator.matches(any, f, now: now))     // image fails, content passes → any
        // .all with a failing member fails.
        let allFail = AutomationRule(name: "r", matchMode: .all,
                                     conditions: [.kindIs(.image), .contentContains("invoice")],
                                     destinationTemplate: "X")
        #expect(!AutomationEvaluator.matches(allFail, f, now: now))
    }

    @Test func incompleteConditionsAreIgnoredAndEmptyRuleNeverMatches() {
        // A rule with only an incomplete condition matches nothing.
        let empty = AutomationRule(name: "r", conditions: [.nameMatches("   ")], destinationTemplate: "X")
        #expect(!AutomationEvaluator.matches(empty, facts("a.pdf"), now: now))
        // A complete condition alongside an incomplete one still evaluates on the complete one.
        let mixed = AutomationRule(name: "r", matchMode: .all,
                                   conditions: [.kindIs(.pdf), .contentContains("")],
                                   destinationTemplate: "X")
        #expect(AutomationEvaluator.matches(mixed, facts("a.pdf"), now: now))
    }

    @Test func couldMatchPendingContentIsOptimisticAboutText() {
        // A PDF whose only *remaining* question is its text should be worth reading.
        let rule = AutomationRule(name: "r", matchMode: .all,
                                  conditions: [.kindIs(.pdf), .contentContains("invoice")],
                                  destinationTemplate: "X")
        #expect(AutomationEvaluator.couldMatchPendingContent(rule, facts("a.pdf", snippet: nil), now: now))
        // But a non-PDF fails a cheap condition, so its text is never worth reading.
        #expect(!AutomationEvaluator.couldMatchPendingContent(rule, facts("a.jpg", snippet: nil), now: now))
    }

    @Test func firstMatchSkipsDisabledAndIncompleteRules() {
        let disabled = AutomationRule(name: "d", enabled: false,
                                      conditions: [.kindIs(.pdf)], destinationTemplate: "A")
        let incomplete = AutomationRule(name: "i", conditions: [.nameMatches("")], destinationTemplate: "")
        let good = AutomationRule(name: "g", conditions: [.kindIs(.pdf)], destinationTemplate: "B")
        let match = AutomationEvaluator.firstMatch(in: [disabled, incomplete, good], for: facts("x.pdf"), now: now)
        #expect(match?.name == "g")
    }

    // MARK: Destination token resolution

    @Test func resolvesDateExtProviderTokens() {
        let f = facts("Report.PDF", modified: now)
        #expect(AutomationEvaluator.resolveDestination("Docs/{year}", for: f, providerName: "iCloud", now: now)
                == .resolved("Docs/2024"))
        #expect(AutomationEvaluator.resolveDestination("Docs/{yyyy-mm}", for: f, providerName: nil, now: now)
                == .resolved("Docs/2024-07"))
        #expect(AutomationEvaluator.resolveDestination("{provider}/{ext}", for: f, providerName: "iCloud", now: now)
                == .resolved("iCloud/pdf"))
        #expect(AutomationEvaluator.resolveDestination("Files/{kind}", for: f, providerName: nil, now: now)
                == .resolved("Files/PDF"))
    }

    @Test func unresolvableTokensAreReported() {
        // No provider → {provider} can't fill.
        #expect(AutomationEvaluator.resolveDestination("{provider}/x", for: facts("a.pdf", modified: now),
                                                       providerName: nil, now: now) == .unresolved(token: "{provider}"))
        // No modification date → {year} can't fill.
        #expect(AutomationEvaluator.resolveDestination("Docs/{year}", for: facts("a.pdf", modified: nil),
                                                       providerName: "iCloud", now: now) == .unresolved(token: "{year}"))
        // Extension-less file → {ext} can't fill.
        #expect(AutomationEvaluator.resolveDestination("{ext}", for: facts("noext", modified: now),
                                                       providerName: nil, now: now) == .unresolved(token: "{ext}"))
        // An unknown token is surfaced, not silently kept.
        #expect(AutomationEvaluator.resolveDestination("Docs/{bogus}", for: facts("a.pdf", modified: now),
                                                       providerName: nil, now: now) == .unresolved(token: "{bogus}"))
    }

    @Test func destinationPathIsCleaned() {
        let f = facts("a.pdf", modified: now)
        // Leading/trailing/duplicate slashes and . / .. segments are dropped.
        #expect(AutomationEvaluator.resolveDestination("/Docs//Invoices/", for: f, providerName: nil, now: now)
                == .resolved("Docs/Invoices"))
        #expect(AutomationEvaluator.resolveDestination("Docs/../secret/./x", for: f, providerName: nil, now: now)
                == .resolved("Docs/secret/x"))
    }

    // MARK: Rule model

    @Test func isRunnableRequiresNameConditionAndDestination() {
        #expect(!AutomationRule(name: "", conditions: [.kindIs(.pdf)], destinationTemplate: "X").isRunnable)
        #expect(!AutomationRule(name: "r", conditions: [], destinationTemplate: "X").isRunnable)
        #expect(!AutomationRule(name: "r", conditions: [.kindIs(.pdf)], destinationTemplate: "").isRunnable)
        #expect(AutomationRule(name: "r", conditions: [.kindIs(.pdf)], destinationTemplate: "X").isRunnable)
    }

    @Test func requiresContentOnlyForCompleteContentConditions() {
        #expect(AutomationRule(name: "r", conditions: [.contentContains("invoice")], destinationTemplate: "X").requiresContent)
        #expect(!AutomationRule(name: "r", conditions: [.contentContains("  ")], destinationTemplate: "X").requiresContent)
        #expect(!AutomationRule(name: "r", conditions: [.kindIs(.pdf)], destinationTemplate: "X").requiresContent)
    }

    @Test func ruleCodableRoundTrips() throws {
        let rule = AutomationRule(
            name: "Invoices", enabled: false, matchMode: .any,
            conditions: [.folderNamed("Downloads"), .kindIs(.pdf), .largerThanMB(2),
                         .untouchedForDays(30), .contentContains("invoice"), .nameMatches("*.pdf")],
            destinationTemplate: "Documents/Invoices/{year}"
        )
        let data = try JSONEncoder().encode([rule])
        let back = try JSONDecoder().decode([AutomationRule].self, from: data)
        #expect(back == [rule])
    }
}
