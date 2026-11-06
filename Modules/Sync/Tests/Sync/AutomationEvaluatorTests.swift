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
        #expect(AutomationEvaluator.matches(.kindIs(.video), facts("clip.mp4"), now: now))
        #expect(AutomationEvaluator.matches(.kindIs(.audio), facts("song.mp3"), now: now))
        #expect(!AutomationEvaluator.matches(.kindIs(.image), facts("a.pdf"), now: now))
        // Audio must never match the video kind: `public.audio` conforms to `.audiovisualContent`,
        // so `.video` must not include it.
        #expect(!AutomationEvaluator.matches(.kindIs(.video), facts("song.mp3"), now: now))
        #expect(!AutomationEvaluator.matches(.kindIs(.video), facts("track.m4a"), now: now))
        // `.of` disambiguation: a PDF is never the broad .document; audio resolves to .audio, not .video.
        #expect(FileKind.of(fileName: "a.pdf") == .pdf)
        #expect(FileKind.of(fileName: "notes.txt") == .document)
        #expect(FileKind.of(fileName: "song.mp3") == .audio)
        #expect(FileKind.of(fileName: "track.m4a") == .audio)
        #expect(FileKind.of(fileName: "clip.mp4") == .video)
        #expect(FileKind.of(fileName: "noext") == nil)
    }

    @Test func sizeThresholdIsStrictGreaterAndDecimalMB() {
        #expect(AutomationEvaluator.matches(.largerThanMB(100), facts("big", size: 150_000_000), now: now))
        #expect(!AutomationEvaluator.matches(.largerThanMB(100), facts("exact", size: 100_000_000), now: now))
        #expect(!AutomationEvaluator.matches(.largerThanMB(100), facts("small", size: 50_000_000), now: now))
    }

    @Test func sizeThresholdDoesNotOverflowOnAnAbsurdValue() {
        // A 13+ digit MB value would trap on `mb * bytesPerMB`. It must not crash, and an
        // unreachable threshold matches nothing (no real file is that large).
        #expect(!AutomationEvaluator.matches(.largerThanMB(9_999_999_999_999), facts("big", size: Int.max / 2), now: now))
        #expect(!AutomationEvaluator.matches(.largerThanMB(.max), facts("big", size: Int.max / 2), now: now))
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

    @Test func incompleteConditionsNeverMatchAndNeverBroaden() {
        // A rule with only an incomplete condition matches nothing.
        let empty = AutomationRule(name: "r", conditions: [.nameMatches("   ")], destinationTemplate: "X")
        #expect(!AutomationEvaluator.matches(empty, facts("a.pdf"), now: now))
        // An all-of rule with an incomplete member matches nothing, rather than evaluating the
        // complete remainder, which would broaden "kind is PDF AND text contains <blank>" to every
        // PDF. The half-built rule stays saved, just inert.
        let mixed = AutomationRule(name: "r", matchMode: .all,
                                   conditions: [.kindIs(.pdf), .contentContains("")],
                                   destinationTemplate: "X")
        #expect(!AutomationEvaluator.matches(mixed, facts("a.pdf"), now: now))
    }

    @Test func allOfRuleWithAnIncompleteConditionNeverMatches() {
        // "All of" can't be proven when one condition is unevaluatable: dropping it would broaden
        // the rule to the others, as would a stored `.mentionsAll([])`. So all-of with any
        // incomplete condition matches nothing; any-of ignores incomplete disjuncts (dropping one
        // only narrows).
        let allOf = AutomationRule(name: "r", matchMode: .all,
                                   conditions: [.kindIs(.pdf), .mentionsAll([""])],
                                   destinationTemplate: "X")
        #expect(!AutomationEvaluator.matches(allOf, facts("a.pdf"), now: now))

        let anyOf = AutomationRule(name: "r", matchMode: .any,
                                   conditions: [.kindIs(.pdf), .mentionsAll([""])],
                                   destinationTemplate: "X")
        #expect(AutomationEvaluator.matches(anyOf, facts("a.pdf"), now: now))

        let complete = AutomationRule(name: "r", matchMode: .all,
                                      conditions: [.kindIs(.pdf)],
                                      destinationTemplate: "X")
        #expect(AutomationEvaluator.matches(complete, facts("a.pdf"), now: now))
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

    @Test func yearMonthTokenNeverMixesYearSources() {
        // {yyyy-mm} must take both components from one clock. {year} alone may prefer the
        // filename's year (Taxes/2023 for a 2023 form downloaded in 2024), but the month can only
        // come from the mtime, and mixing them would mint a date from neither source that
        // batch-eligible rules file into blind. A filename year that contradicts the mtime year
        // leaves the composite unresolved (flagged, never blind-filed).
        let contradicting = facts("chase-statement-2023.pdf", modified: now)   // now = 2024
        #expect(AutomationEvaluator.resolveDestination("Docs/{yyyy-mm}", for: contradicting,
                                                       providerName: nil, now: now)
                == .unresolved(token: "{yyyy-mm}"))

        // A filename year AGREEING with the mtime year resolves — from the mtime.
        let agreeing = facts("chase-statement-2024.pdf", modified: now)
        #expect(AutomationEvaluator.resolveDestination("Docs/{yyyy-mm}", for: agreeing,
                                                       providerName: nil, now: now)
                == .resolved("Docs/2024-07"))

        // {year} alone keeps its filename preference.
        #expect(AutomationEvaluator.resolveDestination("Docs/{year}", for: contradicting,
                                                       providerName: nil, now: now)
                == .resolved("Docs/2023"))

        // The composite ban must survive hand-composition: "{year}-{month}" would take {year}
        // from the filename and {month} from the mtime, the neither-source date {yyyy-mm}
        // forbids. So {month} carries the same guard: when the filename names a different year,
        // the month is unknowable and the token goes unresolved.
        #expect(AutomationEvaluator.resolveDestination("Docs/{year}-{month}", for: contradicting,
                                                       providerName: nil, now: now)
                == .unresolved(token: "{month}"))
        #expect(AutomationEvaluator.resolveDestination("Docs/{month}", for: contradicting,
                                                       providerName: nil, now: now)
                == .unresolved(token: "{month}"))
        // Agreeing or absent filename years keep {month} resolving from the mtime.
        #expect(AutomationEvaluator.resolveDestination("Docs/{year}-{month}", for: agreeing,
                                                       providerName: nil, now: now)
                == .resolved("Docs/2024-07"))
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
        // Trailing/duplicate slashes and . / .. segments are dropped.
        #expect(AutomationEvaluator.resolveDestination("Docs//Invoices/", for: f, providerName: nil, now: now)
                == .resolved("Docs/Invoices"))
        #expect(AutomationEvaluator.resolveDestination("Docs/../secret/./x", for: f, providerName: nil, now: now)
                == .resolved("Docs/secret/x"))
        // A leading slash marks an absolute destination (a migrated rule): cleaned, but kept
        // absolute so callers can provider-scope it.
        #expect(AutomationEvaluator.resolveDestination("/Docs//Invoices/", for: f, providerName: nil, now: now)
                == .resolved("/Docs/Invoices"))
    }

    @Test func absoluteDestinationsAreProviderScoped() {
        // Relative destinations anchor at the root; the root itself is the empty template.
        #expect(AutomationEvaluator.absoluteDestination("Docs/X", providerRoot: "/p") == "/p/Docs/X")
        #expect(AutomationEvaluator.absoluteDestination("", providerRoot: "/p") == "/p")
        // Absolute destinations resolve verbatim inside their provider and are inert elsewhere.
        #expect(AutomationEvaluator.absoluteDestination("/p/Docs/X", providerRoot: "/p") == "/p/Docs/X")
        #expect(AutomationEvaluator.absoluteDestination("/q/Docs/X", providerRoot: "/p") == nil)
        // Prefix matching is on a path-component boundary — /pq is not inside /p.
        #expect(AutomationEvaluator.absoluteDestination("/pq/Docs", providerRoot: "/p") == nil)
    }

    @Test func mentionsAllMatchesNameAndContentTokens() {
        // Name-only match — no content needed.
        #expect(AutomationEvaluator.matches(
            AutomationRule(name: "T", conditions: [.mentionsAll(["tesla"])], destinationTemplate: "X"),
            facts("Tesla Policy.pdf", modified: now), now: now))
        // A token missing from the name is satisfied by content tokens.
        var withContent = facts("scan svc.pdf", modified: now)
        withContent.contentTokens = ["tesla", "insurance"]
        #expect(AutomationEvaluator.matches(
            AutomationRule(name: "T", conditions: [.mentionsAll(["tesla"])], destinationTemplate: "X"),
            withContent, now: now))
        // ALL tokens must be present — one hit out of two is no match.
        #expect(!AutomationEvaluator.matches(
            AutomationRule(name: "T", conditions: [.mentionsAll(["tesla", "geico"])], destinationTemplate: "X"),
            withContent, now: now))
        // No tokens anywhere → no match.
        #expect(!AutomationEvaluator.matches(
            AutomationRule(name: "T", conditions: [.mentionsAll(["tesla"])], destinationTemplate: "X"),
            facts("scan svc.pdf", modified: now), now: now))
    }

    /// One semantic on every surface: substring of the raw excerpt. A token-subset fallback would
    /// be a second meaning under the same name ("acme invoice" matching "invoice … acme"), and if
    /// the scan that moves files read it while the preview didn't, the preview would describe a
    /// different rule. A file whose text was never read matches no text condition. A token-subset
    /// fallback must flip the first two expectations.
    @Test func contentContainsNeverMatchesOnTokensAlone() {
        var f = facts("scan.pdf", modified: now)
        f.contentTokens = ["invoice", "acme"]
        // Tokens without text: the text was not read, so a text condition holds nothing — even
        // when every word of the term is among the tokens.
        #expect(!AutomationEvaluator.matches(
            AutomationRule(name: "T", conditions: [.contentContains("acme invoice")], destinationTemplate: "X"),
            f, now: now))
        #expect(!AutomationEvaluator.matches(
            AutomationRule(name: "T", conditions: [.contentContains("invoice")], destinationTemplate: "X"),
            f, now: now),
            "a single-word term matched on tokens alone — the fallback is back, and the scan and the preview disagree again")
        // A raw snippet answers by exact substring: the phrase must appear as written…
        f.snippet = "invoice from acme corp"
        f.contentTokens = []
        #expect(AutomationEvaluator.matches(
            AutomationRule(name: "T", conditions: [.contentContains("acme corp")], destinationTemplate: "X"),
            f, now: now))
        // …so a term whose words are all present but not adjacent does not match; `mentionsAll` is
        // the condition for that meaning.
        #expect(!AutomationEvaluator.matches(
            AutomationRule(name: "T", conditions: [.contentContains("corp invoice")], destinationTemplate: "X"),
            f, now: now))
        #expect(AutomationEvaluator.matches(
            AutomationRule(name: "T", conditions: [.mentionsAll(["corp", "invoice"])], destinationTemplate: "X"),
            { var g = f; g.contentTokens = ["invoice", "acme", "corp"]; return g }(), now: now))
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

    @Test func yearTokenPrefersTheFilenameYearOverMtime() {
        // A 2023 form downloaded in 2024 belongs in Taxes/2023: rule matches are batch-eligible,
        // so a wrong-year {year} would file blind into the wrong folder.
        #expect(AutomationEvaluator.resolveDestination("Taxes/{year}", for: facts("2023-tax-form.pdf", modified: now),
                                                       providerName: nil, now: now) == .resolved("Taxes/2023"))
        // No (single) filename year → mtime decides.
        #expect(AutomationEvaluator.resolveDestination("Taxes/{year}", for: facts("tax-form.pdf", modified: now),
                                                       providerName: nil, now: now) == .resolved("Taxes/2024"))
        // Two plausible years name no single year — mtime decides (same rule as the Organize engine).
        #expect(AutomationEvaluator.resolveDestination("Taxes/{year}", for: facts("2021-2022 report.pdf", modified: now),
                                                       providerName: nil, now: now) == .resolved("Taxes/2024"))
    }

    @Test func absoluteDestinationsAreLiteralPaths() {
        // An absolute destination is a real folder path from a migrated/learned rule — braces in a
        // folder name are literal, never a token to resolve (or trip over).
        #expect(AutomationEvaluator.resolveDestination("/p/Docs/{drafts}", for: facts("a.pdf", modified: now),
                                                       providerName: nil, now: now) == .resolved("/p/Docs/{drafts}"))
        // Relative templates still resolve (and flag) tokens.
        #expect(AutomationEvaluator.resolveDestination("Docs/{drafts}", for: facts("a.pdf", modified: now),
                                                       providerName: nil, now: now) == .unresolved(token: "{drafts}"))
    }

    @Test func ruleCodableRoundTrips() throws {
        let rule = AutomationRule(
            name: "Invoices", enabled: false, matchMode: .any,
            conditions: [.folderNamed("Downloads"), .kindIs(.pdf), .largerThanMB(2),
                         .untouchedForDays(30), .contentContains("invoice"), .nameMatches("*.pdf"),
                         .mentionsAll(["insurance", "tesla"])],
            destinationTemplate: "Documents/Invoices/{year}"
        )
        let data = try JSONEncoder().encode([rule])
        let back = try JSONDecoder().decode([AutomationRule].self, from: data)
        #expect(back == [rule])
    }
}
