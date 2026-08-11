import Testing
import Foundation
@testable import FileExplorer

/// **The call sites.** `OrganizeScopeFilter` and `ScopeChipLabel` are both extracted for
/// testability, and a rule extracted for testability is one revert away from being unused — a
/// perfectly green predicate suite proves nothing if the view stopped calling it.
///
/// These are source-level assertions, which is a blunt instrument with a known blind spot: a source
/// scan is not a behavioural test and has passed before with the bug present. Two habits keep it
/// honest here — each check **names the file it reads and fails if that file cannot be found**
/// (so a rename cannot silently empty the haystack), and each asserts a string whose absence is
/// exactly the regression it is guarding against, not merely that some related word appears.
@Suite struct OrganizeScopeCallSiteTests {

    /// The module's own source directory, located from this test file rather than from a working
    /// directory — `swift test` does not promise one.
    static let sourceDir: URL = {
        URL(fileURLWithPath: #filePath)                     // …/Tests/FileExplorer/<this>.swift
            .deletingLastPathComponent()                    // …/Tests/FileExplorer
            .deletingLastPathComponent()                    // …/Tests
            .deletingLastPathComponent()                    // …/FileExplorer (package)
            .appendingPathComponent("Sources/FileExplorer")
    }()

    static func source(_ name: String) throws -> String {
        let url = sourceDir.appendingPathComponent(name)
        // The non-vacuity guard: a missing file must FAIL, never yield an empty haystack in which
        // every `contains` check quietly answers false and every `!contains` quietly answers true.
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — the scan below would be vacuous")
        // `#require`, not `#expect`: a file that exists but is truncated (a bad merge, a half-written
        // checkout) records one issue and then hands the short string on, after which every
        // `contains` here answers false and every `!contains` answers true. One quiet issue against
        // thirty green tests is the wrong signal — stop instead.
        try #require(text.count > 500, "\(name) is implausibly short — the scans below would be near-vacuous")
        return text
    }

    /// One declaration's body, bounded by its **closing brace** rather than a character count.
    ///
    /// A fixed-width window is a known way for a source scan to answer about the wrong text: a
    /// sibling of this helper in `SyncCloudTests` took 400 characters after a declaration, ran past
    /// a four-line body into the *next* member's doc comment, and failed a correct implementation.
    /// Fails loudly when the declaration is gone, so a rename cannot silently empty the haystack.
    static func body(of declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration),
                                 "\(declaration) is gone — the scan below would be vacuous")
        // **Uniqueness, because `range(of:)` silently takes the FIRST match.** Measured: adding a
        // second `public var body: some View {` above `CommandPaletteView`'s — an onboarding variant,
        // say — made the hit-shape scan read the decoy and pass with BOTH of its defects present.
        //
        // **Counted over `codeOnly`, not the raw text.** The first version counted the whole file and
        // so counted *prose*: one doc comment mentioning a member by name failed a correct
        // implementation — including a test another session landed the same day. That is the hazard
        // this file already documents twice, reintroduced by the guard against a different one.
        //
        // `#require`, because the case worth catching is a decoy *above* the real declaration: there
        // the slice is the decoy's body and every downstream check fires with a message blaming
        // production code that is fine. One true failure beats four false ones.
        let occurrences = Self.codeOnly(source).components(separatedBy: declaration).count - 1
        try #require(occurrences == 1,
                     "\(declaration) occurs \(occurrences)× in code — range(of:) would silently read the first")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for \(declaration)")
        return String(rest[..<end.lowerBound])
    }

    /// The same text with whole-line `//` comments removed.
    ///
    /// **Only for the NEGATIVE checks.** A scan asserting that something is *absent* is the one that
    /// a doc comment explaining the absence will falsify — the failure this file has already had
    /// once, where a source scan matched the comment describing a removed control. Positive checks
    /// keep the raw text: matching a call that is genuinely there is not confused by prose.
    ///
    /// Whole-line only, deliberately. A trailing `// …` after real code is rare here and stripping
    /// it would need a parser that understands string literals containing `//` — a stripper that got
    /// that wrong would silently shrink the haystack, which is worse than leaving those lines whole.
    static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: The predicate is actually called

    @Test func tidyViewFiltersEveryLensThroughTheScopePredicate() throws {
        let tidy = try Self.source("TidyView.swift")
        // One call per filterable set. Losing any one of these is a lens that silently stops
        // narrowing while the other five keep doing so — the exact inconsistency this feature
        // exists to remove.
        let calls = tidy.components(separatedBy: "OrganizeScopeFilter.").count - 1
        #expect(calls >= 10,
                "only \(calls) OrganizeScopeFilter call(s) in TidyView — a lens has stopped scoping")
    }

    @Test func restructureRoutesThroughFilteredRowsRatherThanTheManager() throws {
        let tidy = try Self.source("TidyView.swift")
        // The specific bug: `restructureContent()` read `syncManager.structureFindings` directly,
        // which is why no filter could reach it. It takes `rows` now.
        #expect(tidy.contains("restructureContent(rows:"))
        #expect(tidy.contains("RestructureLens(findings: rows.structure"))
        #expect(tidy.contains("aboutAncestor: rows.structureAboutAncestor"))
    }

    @Test func theScopeChipIsDrawnFromLensSummaryNotFromOneArm() throws {
        let tidy = try Self.source("TidyView.swift")
        // The rail already made this mistake: drawn inside `organizeSummary`, it reached only the
        // filing apparatus, so two of the six lenses rendered without it. The chip must be hoisted
        // above the switch in `lensSummary`.
        let summary = try #require(tidy.range(of: "private func lensSummary(rows: FilteredRows,"),
                                   "lensSummary is gone — this scan would be vacuous")
        let organizeSummary = try #require(tidy.range(of: "private func organizeSummary(rows:"))
        let chipDraw = try #require(tidy.range(of: "if lens != .storage { scopeChip("),
                                    "the scope chip is no longer drawn from lensSummary")
        #expect(chipDraw.lowerBound > summary.lowerBound)
        #expect(chipDraw.lowerBound < organizeSummary.lowerBound,
                "the scope chip has drifted into organizeSummary, which two lenses never reach")
    }

    @Test func theChipViewIsTheOneTheTestsRender() throws {
        let tidy = try Self.source("TidyView.swift")
        // `OrganizeScopeChipTests` renders `ScopeChipLabel`. If TidyView ever inlines its own chip
        // again, those pixel assertions would be measuring a view nothing shows.
        #expect(tidy.contains("ScopeChipLabel("))
    }

    // MARK: The badges and the overview are scoped too

    @Test func railCountsAreScoped() throws {
        let tidy = try Self.source("TidyView.swift")
        let start = try #require(tidy.range(of: "private var railCounts: RailCounts {"),
                                 "railCounts is gone — this scan would be vacuous")
        let rest = tidy[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for railCounts")
        let body = String(rest[..<end.lowerBound])

        // **Each of the six, by name.** A bare `body.contains("OrganizeScopeFilter.matches")` was
        // the first version and it let a real mutation through: dropping the scope from `renames`
        // alone leaves the other five calls in place, so the check still passed while the Renames
        // badge went back to reporting 126 beside a list of three. One lens quietly un-scoping is
        // exactly the inconsistency this whole feature exists to remove, so every lens is asserted
        // separately.
        //
        // **Each asks `appliedScope(for:)` with its OWN lens, and that is load-bearing.** The
        // selected lens's `scope` used to be read once at the top of this body, which was right
        // while every lens applied it. Rules does not (``OrganizeLens/isScoped``), so a single
        // `let scope = scope` here would go nil the instant Rules was selected and lift the scope
        // off the five badges beside it — Duplicates jumping 27 → 620 because a sixth item does not
        // use the scope. Per-lens is the only form that cannot do that.
        let scoped: [(String, String)] = [
            ("toFile", "syncManager.filingSuggestions.count {\n                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .toFile)) }"),
            ("duplicates", "syncManager.duplicateGroups.count {\n                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .duplicates)) }"),
            ("names", "syncManager.riskyNames.count {\n                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .names)) }"),
            ("renames", "syncManager.renamePlans.count {\n                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .renames)) }"),
        ]
        for (lens, call) in scoped {
            #expect(body.contains(call),
                    "the \(lens) badge is counting the global list again — a number beside a list it does not describe")
        }
        // Restructure counts through `relation` rather than `matches`, and `.inside` ONLY: an
        // ancestor finding is shown in the lens but is not work in this subtree, so a badge that
        // counted it would promise something here that is not here.
        #expect(body.contains("OrganizeScopeFilter.relation(of: $0, profileRoot: profileRoot,\n                                             scope: appliedScope(for: .restructure)) == .inside"),
                "the restructure badge is unscoped, or counting ancestor findings as work in the scope")
        #expect(!body.contains("case .restructure: return 0"),
                "the restructure badge is hard-wired to 0 again")
        // **Rules counts the whole list, and must not grow a scope test.** Not an omission — see
        // `OrganizeLens.isScoped`: `appliedScope(for: .rules)` is always nil, so a call written here
        // would read like a live narrowing and be one that can never fire.
        #expect(body.contains("rules: syncManager.automationRules.count,"),
                "the rules badge is no longer the plain count of the one global list")
        // **Over the CODE, not the prose.** The line above this one in `railCounts` is a comment
        // saying *why* there is no `appliedScope(for: .rules)` call, and the first cut of this check
        // matched that comment and failed a correct implementation — the standing hazard of every
        // scan in this file. Stripped, plus a positive check that the stripping left something, so a
        // stripper that ate the whole body cannot make this pass vacuously.
        let code = Self.codeOnly(body)
        #expect(code.contains("rules: syncManager.automationRules.count,"),
                "stripping comments emptied the body — this check would be vacuous")
        #expect(!code.contains("appliedScope(for: .rules)"),
                "an inert scope call has been added to the rules badge")
    }

    /// The counts are resolved ONCE and handed to both consumers — the same property `FilteredRows`
    /// exists for, and the reason this stopped being twelve scoped passes per render.
    @Test func theRailCountsAreResolvedOncePerRender() throws {
        let tidy = try Self.source("TidyView.swift")
        #expect(tidy.contains("let counts = railCounts"))
        #expect(tidy.contains("state: counts.state"),
                "the width arithmetic is recomputing the rail's states instead of reading the resolved counts")
        // **And the RENDER reads the same accessor as the model.** Both said the same thing by
        // restating the rule — `counts.badge(_:)` in the arithmetic, the rule spelled out again at
        // the rail item — which agrees only for as long as nobody changes one of them. A rule that
        // suppressed a badge past four digits would move the model and not the label, and the
        // arithmetic would start sizing a rail that is not drawn: exactly the divergence
        // `OrganizeRailMetrics` exists to stop.
        //
        // Both halves match the **assignment**, not the bare call. A scan for the restated form
        // anywhere in the file trips on the comment at the call site that explains why it is
        // wrong — a source scan that cannot tell code from the prose describing it, which is this
        // suite's standing hazard.
        // The accessor is `state(_:)` now rather than `badge(_:)`: a rail item's dress is three
        // states, not a number or its absence, and the width model charges a different width for
        // each — a badge, a 4pt dot, or nothing. Both sides read the same one.
        #expect(tidy.contains("state: counts.state(item)"),
                "the rail item is restating the state rule instead of calling the accessor the width model uses")
        #expect(!tidy.contains("let badge = item.badge("),
                "the rail item is back to deriving its badge independently of the width model")
        #expect(!tidy.contains("private var railBadgeCount"),
                "railBadgeCount is back — that is the second independent pass over all six lists")
        // And the per-render profile walk behind the chip's folder count is resolved with them.
        #expect(tidy.contains("let scopeFolders = scopeFolderCount"))
    }

    /// The pure count rule is actually *called* with the rail's selection.
    ///
    /// **A rule extracted for testability is one revert away from being unused.**
    /// `StorageSection.counts(in:section:matching:)` is asserted directly by
    /// `theOfMCountsFollowTheRail`, and every one of those assertions stays green if the view hands
    /// it `nil` — the numbers would go back to describing all three lists and only the call site
    /// would show it.
    @Test func theStorageCountsAreAskedAboutTheSelectedSection() throws {
        let tidy = try Self.source("TidyView.swift")
        let body = try Self.body(of: "private var storageCounts: (filtered: Int, total: Int) {", in: tidy)
        #expect(body.contains("section: storageSection"),
                "storageCounts is not passing the rail's selection, so \"N of M\" describes lists the page is not showing")
        #expect(body.contains("StorageSection.counts(in: report"),
                "storageCounts has stopped using the shared rule and is summing lists itself again")
    }

    @Test func theOverviewNamesTheScopeAndNotTheLastScannedFolder() throws {
        let tidy = try Self.source("TidyView.swift")
        #expect(tidy.contains("scopeLabel: scope?.name"))
        // The thing it must NOT go back to: the root one lens happened to walk.
        #expect(!tidy.contains(
            "scopeLabel: syncManager.filingScanFolder.map { ($0 as NSString).lastPathComponent }"))
    }

    // MARK: The two defects the installed build turned up

    @Test func theReaimButtonSaysItCLEARSTheScopeAtTheProviderRoot() throws {
        // Found by installing and looking: scoped to Legal with the pane at the provider root, the
        // button read `Organize "Documents"` and promised "Every lens narrows to it" — while
        // clicking it widens to the whole tree. The action was always right; only the words lied,
        // which is the shape of defect a green suite is least likely to catch.
        let tidy = try Self.source("TidyView.swift")
        #expect(tidy.contains("private var reaimClearsScope: Bool"))
        #expect(tidy.contains("reaimClearsScope ? \"Organize everything\""))
        // And the promise must be swapped with the label, not left behind on it. (`movedTitle`
        // short-circuits both — see the Storage test below — so the swap is gated on its absence.)
        #expect(tidy.contains(".help(movedTitle == nil && reaimClearsScope"))
    }

    @Test func storagesMovedButtonSaysAnalyzeNotOrganize() throws {
        // Same words-lie shape, third instance: Storage shares `rescanButton` but none of the
        // scope semantics — its `reaim` is a plain re-analyze. The shared wording had its moved
        // button promising `Organize "X"`, or "clears the scope" at the provider root, for a
        // click that touches no scope at all. The browse-aware scan target surfaces the moved
        // state on every column click, so the words must match the verb.
        let tidy = try Self.source("TidyView.swift")
        let storage = try Self.body(of: "private var reanalyzeStorageButton: some View {",
                                    in: tidy)
        #expect(storage.contains("movedTitle: \"Analyze"),
                "Storage's moved button is back on the shared Organize wording")
        // And the override must actually win in the shared button — label and help both, since
        // an ignored movedTitle would leave the call site looking fixed while the render lies.
        let button = try Self.body(of: "private func rescanButton(", in: tidy)
        #expect(button.contains("if let movedTitle {"))
        #expect(button.contains(".help(movedTitle == nil && reaimClearsScope"))
    }

    @Test func theHeaderAsksOrganizeAimWhereOrganizeIsPointed() throws {
        // `OrganizeAim` is extracted for testability and is therefore one revert from being unused:
        // its 13 green tests say nothing if `targetMoved` goes back to spelling the precedence
        // itself. `OrganizeAimTests` owns the rule; this owns the fact that the header asks it.
        let tidy = try Self.source("TidyView.swift")
        let moved = try Self.body(of: "private func targetMoved(", in: tidy)
        #expect(moved.contains("OrganizeAim.paneMovedAway("),
                "targetMoved has stopped delegating — the precedence is back inside the view, where no test reaches it")
        #expect(!moved.contains("?? scannedRoot"),
                "targetMoved is spelling the subject chain again beside the one it delegates to")

        // **Who passes the provider-root rung is the whole cross-workspace rule.** Organize's two
        // re-aim buttons do, because unscoped Organize answers about the whole tree; Storage does
        // not, because it owns no scope and its button re-analyzes rather than re-aims. Storage
        // picking the fallback up is how its "Analyze X" starts firing on a condition that is about
        // somebody else's subject.
        #expect(try Self.body(of: "private var filingTargetMoved: Bool {", in: tidy)
            .contains("rootFallback: providerRoot"),
                "Organize's filing button no longer treats an unscoped, unscanned workspace as aimed at the whole tree")
        #expect(!(try Self.body(of: "private var reanalyzeStorageButton: some View {", in: tidy))
            .contains("rootFallback"),
                "Storage's re-analyze button took Organize's root fallback — it owns no scope to be moved off")
    }

    @Test func theTwoFilingGatesReadOneMember() throws {
        // `lensActions` draws the control and `hasRowTwoActions` decides whether row 2 gets its
        // hairline; a `@ViewBuilder` cannot be asked whether it drew anything, so the second is a
        // hand-copy of the first's conditions. **They must read the same member, not two copies of
        // one expression** — this started as a duplicated `hasSuggestedFiling || filingTargetMoved`
        // in both places, which is a divider beside a missing control waiting to happen.
        // Asserted at each call site's own body rather than by counting mentions — the first cut
        // counted 6 where it expected 3, because the doc comments reference the member by name too.
        // A count over a whole file cannot tell a call from a mention of one.
        let tidy = try Self.source("TidyView.swift")
        let actions = try Self.body(of: "private func lensActions(rows: FilteredRows)", in: tidy)
        let rowTwo = try Self.body(of: "private var hasRowTwoActions: Bool {", in: tidy)
        #expect(actions.contains("if showsFilingControl {"),
                "lensActions no longer reads showsFilingControl — it has inlined the gate again")
        #expect(rowTwo.contains("if showsFilingControl { return true }"),
                "hasRowTwoActions no longer reads showsFilingControl — the divider gate is a hand-copy again")
        for (name, body) in [("lensActions", actions), ("hasRowTwoActions", rowTwo)] {
            #expect(!body.contains("hasSuggestedFiling"),
                    "\(name) spells the scan flag out again instead of reading showsFilingControl")
        }
    }

    @Test func theStandDownMatchesTheStateItStandsDownFor() throws {
        // `filingIntroOwnsInvitation` is a claim about what `filingContent` renders, made from
        // outside it. The render tests assert the header band is empty on To File before a scan —
        // but an empty band is also what you get if the intro card stopped being there, so those
        // tests cannot tell "stood down because something else is asking" from "stood down for
        // nothing". This is the half they cannot see: the two conditions must stay the same
        // condition.
        let tidy = try Self.source("TidyView.swift")

        let content = try Self.body(of: "private func filingContent(", in: tidy)
        #expect(content.contains("else if !syncManager.hasSuggestedFiling {"),
                "filingContent's intro gate is no longer `!hasSuggestedFiling` — filingIntroOwnsInvitation is now describing a state that does not exist")
        #expect(content.contains("filingIntroState"),
                "filingContent no longer renders the setup card the stand-down defers to")

        let owns = try Self.body(of: "private var filingIntroOwnsInvitation: Bool {", in: tidy)
        #expect(owns.contains("organizeLens == .toFile"),
                "the stand-down is no longer keyed on To File — the lens whose intro it defers to")
        #expect(owns.contains("!syncManager.hasSuggestedFiling"),
                "the stand-down no longer tracks filingContent's own pre-scan condition")

        // And the routing that makes "To File" the right key: `contentCard` sends only that rail
        // item to `filingContent`. If another item started reaching it, a second lens would grow an
        // intro card the stand-down does not know about.
        let card = try Self.body(of: "private func contentCard(rows: FilteredRows,", in: tidy)
        #expect(card.contains("if showingOverview {"))
        #expect(card.contains("} else if organizeLens == .restructure {"))
        #expect(card.contains("filingContent(filing: rows.filing, counts: counts)"),
                "contentCard no longer routes the remaining .filing item to filingContent — re-derive which lens owns an intro")
    }

    @Test func anEmptyScopedListBlamesTheScopeAndNotTheSearch() throws {
        // The other one: the Rules lens under a scope offered "The current search hides all 1 rule.
        // Clear it to see the results again" with a Clear Search button, while no search was
        // running. Wrong cause, and an action that could not fix it.
        let tidy = try Self.source("TidyView.swift")
        #expect(tidy.contains("private func scopeHidesAllState"))
        #expect(tidy.contains("private func searchHidesAllState"))
        // The chooser: a live query owns the emptiness, otherwise the scope does.
        #expect(tidy.contains("if query.isEmpty, let scope {"))
        // And the scoped state must state the outside total and offer the clearing action —
        // "0 here" reading as "0 anywhere" is the whole complaint.
        #expect(tidy.contains("elsewhere in the tree"))
        #expect(tidy.contains("\"Organize Everything\""))
    }

    // MARK: Every number beside a scoped list describes THAT list

    /// The three places that still quoted a global total next to a scoped list.
    ///
    /// Each is the same defect the badges had, in a different readout: a number the user can see,
    /// about a list they cannot. Under a scope of `Legal` (27 of 722 duplicate groups) they read
    /// "3 of **722**", offered "Identical (**620**)" in the filter menu, and said the search was
    /// hiding "all **722** duplicate groups".
    @Test func theNofMDenominatorIsTheScopedList() throws {
        let tidy = try Self.source("TidyView.swift")
        let body = try Self.body(of: "private func lensTrailing(rows: FilteredRows, counts: RailCounts) -> some View {",
                                 in: tidy)
        for global in ["syncManager.duplicateGroups.count", "syncManager.riskyNames.count",
                       "syncManager.renamePlans.count", "syncManager.filingSuggestions.count",
                       "syncManager.automationRules.count"] {
            #expect(!body.contains(global),
                    "the N-of-M readout is quoting the global \(global) beside a scoped list")
        }
        // Non-vacuity: it must actually be reading the resolved scoped tally.
        #expect(body.contains("counts.duplicates"))
        #expect(body.contains("counts.toFile"))
    }

    @Test func theDuplicateFilterMenuCountsWithinTheScope() throws {
        let tidy = try Self.source("TidyView.swift")
        #expect(tidy.contains("Self.filterCounts(syncManager.duplicateGroups, scope: scope)"),
                "the filter menu is counting the whole tree beside a scoped lens")
        let body = try Self.body(
            of: "private static func filterCounts(_ groups: [DuplicateGroup],", in: tidy)
        #expect(body.contains("where OrganizeScopeFilter.matches(group, scope: scope)"))
        // The search must still NOT narrow these — a badge reading zero for a filter that would
        // reveal rows is the reason this counts the unsearched list.
        #expect(!body.contains("q.matches"))
    }

    @Test func theEmptyStatesQuoteTheScopedTotal() throws {
        let tidy = try Self.source("TidyView.swift")
        // No call site may pass a bare global count as the searched-over denominator.
        #expect(!tidy.contains("noMatchesState(total:"),
                "a caller still passes one undifferentiated total")
        for scoped in ["scopedTotal: counts.duplicates", "scopedTotal: counts.names",
                       "scopedTotal: counts.renames", "scopedTotal: counts.toFile",
                       "scopedTotal: counts.rules"] {
            #expect(tidy.contains(scoped), "missing \(scoped) — that lens still quotes the tree")
        }
        // And the scope's own message counts what is ELSEWHERE, which is the global total minus
        // what is here — not the global total itself.
        #expect(tidy.contains("scopeHidesAllState(total: globalTotal - scopedTotal"))
    }

    // MARK: A count is claimed only where it can be supported

    @Test func theScopeFolderCountTreatsZeroAsUnknown() throws {
        let tidy = try Self.source("TidyView.swift")
        let body = try Self.body(of: "private var scopeFolderCount: Int? {", in: tidy)
        // A scope the profile knows about always counts at least itself, so zero can only mean
        // "not in the survey" — and rendering that as "Legal · 0 folders" reads as *empty*.
        #expect(body.contains("return inside > 0 ? inside : nil"),
                "an unsurveyed scope renders as a zero folder count again")
    }

    @Test func theInboxCountIsGatedOnTheScanHavingCoveredIt() throws {
        let tidy = try Self.source("TidyView.swift")
        let body = try Self.body(of: "private var inboxShortcut: OrganizeOverview.InboxShortcut? {",
                                 in: tidy)
        #expect(body.contains("PathBoundary.contains(inbox, under: $0)"),
                "the inbox offer counts a queue that may never have looked at the inbox")
        #expect(body.contains("let loose = covered"),
                "the count is not gated on the scan having covered the inbox")
    }

    @Test func restructuresCleanStateGetsTheScopedFolderCount() throws {
        let tidy = try Self.source("TidyView.swift")
        #expect(tidy.contains("folderCount: scope == nil"),
                "restructure's clean state is quoting the whole survey under a scope")
        #expect(tidy.contains("isScoped: scope != nil"))
    }

    // MARK: The overview pays for nothing it does not read

    @Test func theOverviewDoesNotResolveRowsItNeverReads() throws {
        let tidy = try Self.source("TidyView.swift")
        let body = try Self.body(of: "private var filteredRows: FilteredRows {", in: tidy)
        #expect(body.contains("guard !(showingOverview && effectiveLens == .filing) else { return rows }"),
                "the overview is parsing a query and scoping the filing queue for a value nothing reads")
        // **Not `showingOverview` alone.** That means "no rail item selected", which is not the
        // same as "the overview renders" — the overview is drawn only from contentCard's `.filing`
        // arm. Guarding on it alone starved the Duplicates apparatus of its rows and took
        // DuplicateRevealLandingTests from painting a revealed group to painting nothing.
        #expect(!body.contains("guard !showingOverview else"),
                "the guard is back to the condition that emptied the duplicates list")
    }

    // MARK: No apply-all button may render a zero

    /// **Every apply-all button gates on having something to apply.**
    ///
    /// Their callers gate on the GLOBAL list (`!syncManager.renamePlans.isEmpty`) while the rows
    /// they are handed are the narrowed ones, so the two disagree whenever a narrowing empties a
    /// lens the tree still has entries for. With a search that was a corner — the content card says
    /// "nothing matches" right beside it — but a scope makes it ordinary, and `renameAllButton` was
    /// the one of the four with no guard: it rendered a prominent, enabled **"Rename 0 files"**.
    ///
    /// A source scan, because these are private `@ViewBuilder`s on a view SwiftUI will not let a
    /// test drive. It is bounded by each declaration's own closing brace rather than a character
    /// count, and it fails if a declaration cannot be found at all — a scan that quietly matches
    /// nothing passes just as green as one that proves something.
    @Test func everyApplyAllButtonGuardsAgainstAnEmptyList() throws {
        let tidy = try Self.source("TidyView.swift")
        let expected: [(decl: String, guardText: String)] = [
            ("private func fixAllButton(_ risky: [RiskyName]) -> some View {", "if !risky.isEmpty {"),
            ("private func fileAllButton(_ filing: [FilingSuggestion]) -> some View {", "if !batch.isEmpty {"),
            ("private func applyAllButton(_ groups: [DuplicateGroup]) -> some View {", "if !batch.isEmpty {"),
            // Counts FILES, not plans: a plan whose steps are all applied is still a plan, so
            // `!plans.isEmpty` would leave the same zero-labelled button standing.
            ("private func renameAllButton(_ plans: [RenamePlan]) -> some View {", "if files > 0 {"),
        ]
        for (decl, guardText) in expected {
            let start = try #require(tidy.range(of: decl), "\(decl) is gone — this scan is vacuous")
            let rest = tidy[start.upperBound...]
            let end = try #require(rest.range(of: "\n    }"), "no closing brace for \(decl)")
            let body = String(rest[..<end.lowerBound])
            #expect(body.contains(guardText),
                    "\(decl) has no empty-list guard — it can render an apply button labelled 0")
        }
    }

    // MARK: A pointed question is not answered through somebody else's scope

    @Test func theDuplicateRevealClearsAScopeThatWouldHideIt() throws {
        let tidy = try Self.source("TidyView.swift")
        // The outcome is resolved against the whole group list and the rows are drawn through the
        // scoped one; without this the two disagree and a named file comes back as "no copies".
        #expect(tidy.contains("OrganizeScopeFilter.revealClearsScope(revealedPath: request.path"))
        // Inside the `outcome != .waiting` branch, so a still-scanning handoff does not thrash the
        // scope before it has an answer.
        let start = try #require(tidy.range(of: "if outcome != .waiting {"))
        let rest = tidy[start.upperBound...]
        let end = try #require(rest.range(of: "\n        }"))
        #expect(String(rest[..<end.lowerBound]).contains("revealClearsScope"),
                "the scope clear has moved outside the answered-outcome branch")
    }

    // MARK: The inbox root-swap is gone, and the path resolution is not

    @Test func theInboxIsOfferedAsAScopeShortcut() throws {
        let tidy = try Self.source("TidyView.swift")
        #expect(tidy.contains("OrganizeOverview.InboxShortcut"))
        #expect(tidy.contains("inboxShortcut: inboxShortcut"))
        let overview = try Self.source("OrganizeOverview.swift")
        #expect(overview.contains("Inbox (\\(shortcut.name))"),
                "the inbox offer no longer names the inbox folder")
    }

    // MARK: The destructive confirmation speaks the group's own vocabulary

    @Test func theRemovalConfirmationGetsItsWordsFromTidyRemovalPrompt() throws {
        // `TidyRemovalPrompt` is pure and fully tested, and would stay green if `apply` went back
        // to composing the sentence inline — which is exactly how a same-text copy came to be
        // called a "redundant copy" in the one dialog that precedes a delete.
        let tidy = try Self.source("TidyView.swift")
        let apply = try Self.body(of: "private func apply(_ group: DuplicateGroup) {", in: tidy)
        #expect(apply.contains("TidyRemovalPrompt.itemWord"))
        #expect(apply.contains("TidyRemovalPrompt.informativeText"))
        // And the literal it replaced is gone from that body. Comment lines are stripped first:
        // a scan that matches the doc comment explaining a removed string is a scan that can never
        // fail. The assertion above proves the haystack is non-empty either way.
        let code = apply.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("redundant cop"),
                "apply() is composing the removal wording inline again")
        #expect(!code.contains("older version"),
                "apply() is composing the removal wording inline again")
    }

    // MARK: A "clean" verdict needs a scan that covered the scope

    /// `OrganizeScopeFilter.scanCovers` is pure and fully tested next door, and the overview would
    /// go straight back to its bug the moment `overviewModel` stopped consulting it — a scoped count
    /// of zero rendering as *"Nothing to do in Legal. Every check that has run came back clean."*
    /// over a subtree nothing had opened.
    ///
    /// **Each lens is asserted by the predicate its own pass justifies**, because the two passes
    /// have different shapes and a shared one is wrong for at least one of them:
    ///
    /// - To File enumerates one folder one level deep → `looseFileScanCovers` (equality). Ancestry
    ///   here would call a provider-root scan "covering" `Legal` and reproduce the false clean.
    /// - Duplicates hashes a whole subtree → `scanCovers` (ancestry).
    /// - Names and Renames read the provider-wide taxonomy → no gate at all. A first pass of this
    ///   fix gated them on the filing folder and hid real findings; the negative below is what
    ///   stops that returning.
    @Test func eachScannedLensGatesOnThePredicateItsPassJustifies() throws {
        let tidy = try Self.source("TidyView.swift")
        let model = try Self.body(of: "var overviewModel: OverviewModel {", in: tidy)

        #expect(model.contains("OrganizeScopeFilter.looseFileScanCovers"),
                "To File no longer asks whether the enumerated folder was the subject")
        #expect(model.contains("scannedFolder: syncManager.filingScanFolder"))
        #expect(model.contains("OrganizeScopeFilter.scanCovers"),
                "Duplicates no longer asks whether its scan covered the subject")
        #expect(model.contains("scannedRoot: syncManager.duplicateScanRoot"))

        // **The subject is what the screen CLAIMS, and unscoped that is the provider root.** Written
        // as `scope?.path ?? providerRoot`: falling back to the scanned root instead would ask
        // whether each scan covered itself, which is how the unscoped half of this bug survived the
        // scoped fix — browse into a subfolder, rescan, and the whole tree reads "clean".
        #expect(model.contains("let subject = scope?.path ?? providerRoot"),
                "the overview's subject is no longer scope-or-provider-root")
        let code = Self.codeOnly(model)
        #expect(!code.contains("subject: scope?.path ?? syncManager.duplicateScanRoot"),
                "the scanned root is being used as the subject — that asks whether a scan covered itself")

        // Exactly ONE arm may consult the loose-file coverage flag — To File's. Comments are
        // stripped first: this file has already had a scan match the prose explaining a rule
        // rather than the rule, and the note above `filingCovers` names every lens.
        #expect(code.components(separatedBy: "!filingCovers").count - 1 == 1,
                "Names or Renames is gating on the filing folder again — their detectors read the provider-wide taxonomy, so that hides findings the scan does have")
        #expect(code.components(separatedBy: "!duplicatesCover").count - 1 == 1)
    }

    /// The pass-shape claim the gate above rests on, asserted against the code that makes it true
    /// rather than trusted: if the loose-file walk ever stops being one level deep, or the name and
    /// rename detectors stop being handed the provider root, the predicates chosen next door are
    /// the wrong ones and this says so.
    @Test func theOverviewsCoverageRulesMatchTheScansTheyDescribe() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sync/Sources/Sync/FileSyncManager+Filing.swift")
        let filing = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read FileSyncManager+Filing.swift — this scan would be vacuous")
        #expect(filing.contains("buildTree(url: folder, sortOption: .name, fileManager: fileManager, maxDepth: 1)"),
                "the loose-file walk is no longer one level deep — To File's equality rule may be wrong now")
        #expect(filing.contains("detectRiskyNames(in: taxonomy, root: providerRoot"),
                "names are no longer scanned provider-wide — they may need a coverage gate now")
        #expect(filing.contains("detectRenamePlans(in: taxonomy, root: providerRoot"),
                "rename plans are no longer scanned provider-wide — they may need a coverage gate now")
    }
}
