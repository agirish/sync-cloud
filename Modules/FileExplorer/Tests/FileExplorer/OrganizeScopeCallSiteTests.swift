import Testing
import Foundation
@testable import FileExplorer
import Sync

/// The call sites. `OrganizeScopeFilter` and `ScopeChipLabel` are extracted for testability, and a
/// green predicate suite proves nothing if the view stops calling them.
///
/// These are source-level assertions, a blunt instrument that is not a behavioural test. Two habits
/// keep it honest: each check names the file it reads and fails if that file can't be found (so a
/// rename can't silently empty the haystack), and each asserts a string whose absence is exactly
/// the regression it guards, not merely that some related word appears.
@Suite struct OrganizeScopeCallSiteTests {

    /// The module's own source directory, located from this test file, since `swift test` does not
    /// promise a working directory.
    static let sourceDir: URL = {
        URL(fileURLWithPath: #filePath)                     // …/Tests/FileExplorer/<this>.swift
            .deletingLastPathComponent()                    // …/Tests/FileExplorer
            .deletingLastPathComponent()                    // …/Tests
            .deletingLastPathComponent()                    // …/FileExplorer (package)
            .appendingPathComponent("Sources/FileExplorer")
    }()

    static func source(_ name: String) throws -> String {
        let url = sourceDir.appendingPathComponent(name)
        // The non-vacuity guard: a missing file must fail, never yield an empty haystack in which
        // every `contains` answers false and every `!contains` answers true.
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(name) — the scan below would be vacuous")
        // `#require`, not `#expect`: a truncated file (a bad merge, a half-written checkout) would
        // record one issue and hand the short string on, after which every `contains` answers false
        // and every `!contains` true. One quiet issue against thirty green tests is the wrong
        // signal, so stop.
        try #require(text.count > 500, "\(name) is implausibly short — the scans below would be near-vacuous")
        return text
    }

    /// One declaration's body, bounded by its closing brace rather than a character count: a
    /// fixed-width window can run past a short body into the next member and answer about the wrong
    /// text. Fails loudly when the declaration is gone, so a rename can't silently empty the
    /// haystack.
    static func body(of declaration: String, in source: String) throws -> String {
        // Uniqueness, because `range(of:)` silently takes the first match: a second matching
        // declaration above the real one (a variant `body`, say) would have the scan read the decoy
        // and pass.
        //
        // Counted and searched over `codeOnly`, not the raw text. Counting raw text would count
        // prose, so a doc comment naming the member would fail a correct implementation; and
        // counting one text while searching another would let a decoy in a doc comment pass the
        // count yet still be what `range(of:)` finds first.
        //
        // `#require`, because with a decoy above the real declaration every downstream check would
        // fire with a message blaming production code that is fine. One true failure beats four
        // false ones.
        let code = Self.codeOnly(source)
        let occurrences = code.components(separatedBy: declaration).count - 1
        try #require(occurrences == 1,
                     "\(declaration) occurs \(occurrences)× in code — range(of:) would silently read the first")
        let start = try #require(code.range(of: declaration),
                                 "\(declaration) is gone — the scan below would be vacuous")
        let rest = code[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for \(declaration)")
        return String(rest[..<end.lowerBound])
    }

    /// The same text with whole-line `//` comments removed.
    ///
    /// Essential for the negative checks: a scan asserting that something is absent is the one a
    /// doc comment explaining the absence will falsify. ``body(of:in:)`` returns stripped text too;
    /// a positive check on the raw source is not confused by prose.
    ///
    /// Whole-line only, deliberately. Stripping a trailing `// …` after code would need a parser
    /// that understands string literals containing `//`, and one that got that wrong would silently
    /// shrink the haystack, which is worse than leaving those lines whole.
    static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: The scope is WRITTEN through its one owner

    /// `setScope` must not carry its own copy of the normalization. Two spellings of one rule over
    /// the persisted ``OrganizeScopeDefaults/pathKey``, on two shapes of provider root, would agree
    /// only by luck, and disagreeing means two encodings of the global view on a key the user can't
    /// inspect.
    ///
    /// Scoped to `setScope`'s own body: the file legitimately calls
    /// `OrganizeScope(path:providerRoot:)` elsewhere to ask a question (`targetWouldClearScope`),
    /// and a file-wide ban would fail that.
    @Test func theScopeWriteRoutesThroughTheOneNormalizer() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        let body = try Self.body(of: "private func setScope(_ path: String?) {", in: view)
        #expect(body.contains("OrganizeScope.normalizedPath(path, providerRoot: providerRoot)"),
                "setScope no longer asks the one owner for the stored form")
        // Comments are already stripped by `body`, so a doc explaining the absence can't falsify
        // this.
        #expect(!body.contains("OrganizeScope(path:"),
                "setScope has grown its own copy of the normalization again")
        // Non-vacuity: the body must still be the write, not some emptied stub.
        #expect(body.contains("scopePathRaw ="))
    }

    // MARK: The predicate is actually called

    /// The body of the `.filter { … }` closure assigned to `family`, or nil if there isn't one.
    ///
    /// Brace-counted, not a fixed-length window: the switch arms are short, so a window from the
    /// family's name can run into the next arm and find its `OrganizeScopeFilter.matches` instead.
    /// Removing `rows.duplicates`' scope test must fail the check, and those rows feed Trash-all.
    static func filterClosure(assignedTo family: String, in body: String) -> String? {
        guard let assign = body.range(of: family + " = ") else { return nil }
        let tail = body[assign.upperBound...]
        guard let open = tail.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < tail.endIndex {
            if tail[index] == "{" { depth += 1 }
            if tail[index] == "}" {
                depth -= 1
                if depth == 0 { return String(tail[tail.index(after: open)..<index]) }
            }
            index = tail.index(after: index)
        }
        return nil
    }

    /// Every row family the lenses act on is narrowed, asserted per family inside the one builder
    /// that produces them, not by counting calls anywhere in the file. A file-wide count is met by
    /// calls unrelated to the rows, so call sites could vanish while it stayed green.
    /// `rows.duplicates` (Trash-all) and `rows.filing` (move files) feed batch destructive buttons,
    /// and either acting outside the scoped folder is the failure this feature exists to prevent.
    @Test func everyScopedRowFamilyIsNarrowedInsideTheRowsBuilder() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        let body = try Self.body(of: "private var filteredRows: FilteredRows {", in: view)

        /// The row families and the filter each one's assignment must carry. `structure` uses
        /// `relation` because it sorts findings three ways (inside / about-an-ancestor / outside)
        /// rather than keeping or dropping them.
        let scoped: [(family: String, filter: String)] = [
            ("rows.duplicates", "OrganizeScopeFilter.matches"),   // the Trash-all button acts on these
            ("rows.filing", "OrganizeScopeFilter.matches"),       // the move-files button acts on these
            ("rows.renames", "OrganizeScopeFilter.matches"),
            ("rows.risky", "OrganizeScopeFilter.matches"),
        ]
        for entry in scoped {
            let predicate = try #require(Self.filterClosure(assignedTo: entry.family, in: body),
                                         "\(entry.family) is gone from filteredRows, or no longer assigned a filter — this scan no longer checks it")
            #expect(predicate.contains(entry.filter),
                    "\(entry.family) is no longer narrowed by the scope — its predicate is:\n\(predicate)")
        }

        // Restructure has a different shape, so it gets its own check: it sorts each finding three
        // ways (inside the scope, about an ancestor of it, or outside), so the filter sits above
        // the appends instead of inside a `filter {}`. Sliced from the case label so both
        // destinations are in one window with the call that chose them.
        let restructureStart = try #require(body.range(of: "case .filing where organizeLens == .restructure:"),
                                            "the restructure arm is gone from filteredRows")
        let restructure = String(body[restructureStart.upperBound...].prefix(600))
        #expect(restructure.contains("OrganizeScopeFilter.relation"),
                "restructure findings are no longer sorted by their relation to the scope")
        #expect(restructure.contains("rows.structure.append"))
        #expect(restructure.contains("rows.structureAboutAncestor.append"),
                "the about-an-ancestor destination is gone, so those findings are silently dropped or mis-filed")

        // The absence is part of the rule. Rules are configuration rather than findings, so
        // `appliedScope(for: .rules)` is always nil and a scope test there would read like a live
        // narrowing that can never fire. Pinning it keeps that a decision.
        let rulesStart = try #require(body.range(of: "rows.rules ="))
        let rulesWindow = String(body[rulesStart.upperBound...].prefix(160))
        #expect(!rulesWindow.contains("OrganizeScopeFilter"),
                "rows.rules has grown a scope filter that can never fire")
    }

    @Test func restructureRoutesThroughFilteredRowsRatherThanTheManager() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        // `restructureContent()` must take `rows` rather than reading
        // `syncManager.structureFindings` directly, where no filter can reach it.
        #expect(view.contains("restructureContent(rows:"))
        #expect(view.contains("RestructureLens(findings: rows.structure"))
        #expect(view.contains("aboutAncestor: rows.structureAboutAncestor"))
    }

    @Test func theScopeChipIsDrawnFromLensSummaryNotFromOneArm() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        // Drawn inside `organizeSummary`, the chip would reach only the filing apparatus and some
        // lenses would render without it, so it must be hoisted above the switch in `lensSummary`.
        let summary = try #require(view.range(of: "private func lensSummary(rows: FilteredRows,"),
                                   "lensSummary is gone — this scan would be vacuous")
        let organizeSummary = try #require(view.range(of: "private func organizeSummary(rows:"))
        // Storage honours the scope chip like the rest, so this looks for the bare draw; the
        // position is what this test is about.
        let chipDraw = try #require(view.range(of: "scopeChip(folderCount: scopeFolders)"),
                                    "the scope chip is no longer drawn from lensSummary")
        #expect(chipDraw.lowerBound > summary.lowerBound)
        #expect(chipDraw.lowerBound < organizeSummary.lowerBound,
                "the scope chip has drifted into organizeSummary, which two lenses never reach")
    }

    @Test func theChipViewIsTheOneTheTestsRender() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        // `OrganizeScopeChipTests` renders `ScopeChipLabel`. If LensWorkspaceView inlined its own
        // chip, those pixel assertions would be measuring a view nothing shows.
        #expect(view.contains("ScopeChipLabel("))
    }

    // MARK: The badges and the overview are scoped too

    @Test func railCountsAreScoped() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        let start = try #require(view.range(of: "var railCounts: RailCounts {"),
                                 "railCounts is gone — this scan would be vacuous")
        let rest = view[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for railCounts")
        let body = String(rest[..<end.lowerBound])

        // Each scoped badge, by name: a bare `body.contains("OrganizeScopeFilter.matches")` still
        // passes when one lens alone drops the scope, leaving its badge reporting the global count
        // beside a scoped list.
        //
        // Each asks `appliedScope(for:)` with its own lens. Rules does not apply the scope
        // (``OrganizeLens/isScoped``), so reading the selected lens's `scope` once at the top would
        // go nil the moment Rules is selected and lift the scope off every other badge.
        let scoped: [(String, String)] = [
            ("toFile", "syncManager.filingSuggestions.count {\n                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .toFile)) }"),
            ("duplicates", "syncManager.duplicateGroups.count {\n                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .duplicates)) }"),
            // The risky names are scoped as what they present as: they appear in the Renames list,
            // so scoping them by anything else would give the Renames badge two subjects.
            ("names", "syncManager.riskyNames.count {\n                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .renames)) }"),
            ("renames", "syncManager.renamePlans.count {\n                OrganizeScopeFilter.matches($0, scope: appliedScope(for: .renames)) }"),
        ]
        for (lens, call) in scoped {
            #expect(body.contains(call),
                    "the \(lens) badge is counting the global list again — a number beside a list it does not describe")
        }
        // Restructure counts through `relation` rather than `matches`, and `.inside` only: an
        // ancestor finding is shown in the lens but is not work in this subtree. And plan-bearing
        // kinds only: a badge you can't drive to zero is a badge people stop reading.
        #expect(body.contains("OrganizeScopeFilter.relation(of: $0, profileRoot: profileRoot,\n                                                    scope: appliedScope(for: .restructure)) == .inside"),
                "the restructure badge is unscoped, or counting ancestor findings as work in the scope")
        #expect(body.contains("$0.kind.carriesPlan"),
                "the restructure badge is counting kinds that carry no plan — an Ask or a hand-off inflates a number nobody can drive to zero")
        #expect(!body.contains("case .restructure: return 0"),
                "the restructure badge is hard-wired to 0 again")
        // Rules counts the whole list and must not grow a scope test: `appliedScope(for: .rules)`
        // is always nil (`OrganizeLens.isScoped`), so a call here would be a narrowing that can
        // never fire.
        #expect(body.contains("rules: syncManager.automationRules.count,"),
                "the rules badge is no longer the plain count of the one global list")
        // Over the code, not the prose: `railCounts` has a comment explaining why there is no
        // `appliedScope(for: .rules)` call, which a raw scan would match. Plus a positive check
        // that the stripping left something, so a stripper that ate the body can't make this pass
        // vacuously.
        let code = Self.codeOnly(body)
        #expect(code.contains("rules: syncManager.automationRules.count,"),
                "stripping comments emptied the body — this check would be vacuous")
        #expect(!code.contains("appliedScope(for: .rules)"),
                "an inert scope call has been added to the rules badge")
    }

    /// The counts are resolved once and handed to both consumers, as `FilteredRows` does for the
    /// rows, rather than re-running the scoped passes for each.
    @Test func theRailCountsAreResolvedOncePerRender() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        #expect(view.contains("let counts = railCounts"))
        #expect(view.contains("state: counts.state"),
                "the width arithmetic is recomputing the rail's states instead of reading the resolved counts")
        // And the render reads the same accessor as the width model. Restating the rule at the rail
        // item agrees only until one copy changes; then the arithmetic sizes a rail that is not
        // drawn, the divergence `OrganizeRailMetrics` exists to stop. The accessor is `state(_:)`:
        // a rail item's dress is three states (a badge, a 4pt dot, or nothing), each with its own
        // width.
        //
        // Both halves match the assignment, not the bare call, so the comment at the call site
        // explaining why the restated form is wrong can't trip the scan.
        #expect(view.contains("state: counts.state(item)"),
                "the rail item is restating the state rule instead of calling the accessor the width model uses")
        #expect(!view.contains("let badge = item.badge("),
                "the rail item is back to deriving its badge independently of the width model")
        #expect(!view.contains("private var railBadgeCount"),
                "railBadgeCount is back — that is the second independent pass over all six lists")
        // And the per-render profile walk behind the chip's folder count is resolved with them.
        #expect(view.contains("let scopeFolders = scopeFolderCount"))
    }

    /// "Show them again" counts and forgets only what the lens's own scope can show, in both
    /// lenses. The manager's scoped accessors are asserted in Sync by
    /// `showingKeptGroupsAgainTouchesOnlyThisFolder` and
    /// `showingHiddenFindingsAgainStaysInTheLensScope`; this pins that the views ask them, with the
    /// scope the rows are narrowed by, rather than forgetting every folder's keys.
    @Test func showThemAgainIsScopedInBothLenses() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        // Count, forget and rescan one folder: the deeper of the scan root and the scope.
        #expect(view.contains("OrganizeAim.keptSeparateFolder(scannedRoot: syncManager.duplicateScanRoot,\n"
                              + "                                       scope: appliedScope(for: .duplicates))"))
        #expect(view.contains("syncManager.keptSeparateKeys(under: keptSeparateFolder).count"))
        let again = try Self.body(of: "private func showKeptSeparateAgain()", in: view)
        #expect(again.contains("syncManager.forgetKeptSeparateGroups(under: folder)"))
        #expect(again.contains("syncManager.startFindDuplicates(root: URL(fileURLWithPath: folder),"),
                "Show them again rescans a folder other than the one it forgot under")
        #expect(!Self.codeOnly(again).contains("onFindDuplicates()"),
                "Show them again hands the rescan to the scope-or-pane scan again")
        #expect(!Self.codeOnly(view).contains("ignoredDuplicateKeys.count"),
                "a kept-separate count is reading every key again, not this folder's")
        #expect(view.contains("hiddenCount: syncManager.hiddenStructureFindings(\n"
                              + "                            in: appliedScope(for: .restructure)).count"))
        #expect(view.contains("{ syncManager.showHiddenStructureFindings(\n"
                              + "                                in: appliedScope(for: .restructure)) }"))
        #expect(!Self.codeOnly(view).contains("unsuppressAll()"),
                "Show them again is clearing every hidden key again, in scope or not")
        // Read once per list, outside the GeometryReader that re-runs on every frame of a drag.
        let list = try Self.body(of: "private func groupList(dupGroups: [DuplicateGroup]) -> some View",
                                 in: view)
        let geometry = try #require(list.range(of: "GeometryReader { geo in"))
        let read = try #require(list.range(of: "let kept = keptSeparateCount"))
        #expect(read.lowerBound < geometry.lowerBound,
                "the kept-separate count is read inside the per-frame GeometryReader closure")
        #expect(list.contains("keptSeparateRow(kept: kept)"))
    }

    /// The pure count rule is called with the rail's selection. `theOfMCountsFollowTheRail` asserts
    /// `StorageSection.counts(in:section:matching:)` directly and stays green if the view passes
    /// `nil`, which would have the numbers describe all three lists.
    ///
    /// - Note: The declaration returns `(filtered: Int, total: Int)?`: before a report there is no
    ///   honest N or M, which `LensHeaderReadoutTests` pins. This scan must track that spelling,
    ///   since a signature it can't find fails the `#require` in ``body(of:in:)``.
    @Test func theStorageCountsAreAskedAboutTheSelectedSection() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        let body = try Self.body(of: "private var storageCounts: (filtered: Int, total: Int)? {", in: view)
        #expect(body.contains("section: storageSection"),
                "storageCounts is not passing the rail's selection, so \"N of M\" describes lists the page is not showing")
        #expect(body.contains("StorageSection.counts(in: report"),
                "storageCounts has stopped using the shared rule and is summing lists itself again")
    }

    @Test func theOverviewNamesTheScopeAndNotTheLastScannedFolder() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        #expect(view.contains("scopeLabel: scope?.name"))
        // The thing it must not go back to: the root one lens happened to walk.
        #expect(!view.contains(
            "scopeLabel: syncManager.filingScanFolder.map { ($0 as NSString).lastPathComponent }"))
    }

    // MARK: The two defects the installed build turned up

    @Test func theReaimButtonSaysItCLEARSTheScopeAtTheProviderRoot() throws {
        // Scoped to Legal with the pane at the provider root, the button clears the scope and
        // widens to the whole tree, so its words must say so ("Organize Everything") rather than
        // promise to narrow to "Documents". A wrong label over a right action is what a green suite
        // is least likely to catch.
        let view = try Self.source("LensWorkspaceView.swift")
        #expect(view.contains("private var reaimClearsScope: Bool"))
        #expect(view.contains("reaimClearsScope ? \"Organize Everything\""))
        // And the promise must be swapped with the label. `movedTitle` short-circuits both (see the
        // Storage test below), so the swap is gated on its absence.
        #expect(view.contains(".help(movedTitle == nil && reaimClearsScope"))
    }

    @Test func storagesMovedButtonSaysAnalyzeNotOrganize() throws {
        // Storage shares `rescanButton` but none of the scope semantics: its `reaim` is a plain
        // re-analyze, so its moved button must say "Analyze", not `Organize "X"` or "clears the
        // scope". The browse-aware scan target surfaces the moved state on every column click.
        let view = try Self.source("LensWorkspaceView.swift")
        let storage = try Self.body(of: "private var reanalyzeStorageButton: some View {",
                                    in: view)
        #expect(storage.contains("movedTitle: \"Analyze"),
                "Storage's moved button is back on the shared Organize wording")
        // And the override must win in the shared button, label and help both: an ignored
        // movedTitle would leave the call site looking fixed while the render lies.
        let button = try Self.body(of: "private func rescanButton(", in: view)
        #expect(button.contains("if let movedTitle {"))
        #expect(button.contains(".help(movedTitle == nil && reaimClearsScope"))
    }

    @Test func theHeaderAsksOrganizeAimWhereOrganizeIsPointed() throws {
        // `OrganizeAim`'s tests say nothing if `targetMoved` spells the precedence itself again.
        // `OrganizeAimTests` owns the rule; this owns the fact that the header asks it.
        let view = try Self.source("LensWorkspaceView.swift")
        let moved = try Self.body(of: "private func targetMoved(", in: view)
        #expect(moved.contains("OrganizeAim.paneMovedAway("),
                "targetMoved has stopped delegating — the precedence is back inside the view, where no test reaches it")
        #expect(!moved.contains("?? scannedRoot"),
                "targetMoved is spelling the subject chain again beside the one it delegates to")

        // Who passes the fallback rung is the cross-workspace rule. Organize's two re-aim buttons
        // do, because unscoped Organize answers about the whole tree; Storage does not, because it
        // owns no scope and its button re-analyzes rather than re-aims. With the fallback,
        // Storage's "Analyze X" would fire on a condition about somebody else's subject.
        //
        // The rung is the anchor, the folder an unscoped pass enumerates. The account root would
        // make a freshly launched pane at its landing folder read as moved away, drawing the
        // prominent re-aim button on every launch.
        #expect(try Self.body(of: "private var filingTargetMoved: Bool {", in: view)
            .contains("rootFallback: providerAnchor"),
                "Organize's filing button no longer treats an unscoped, unscanned workspace as aimed at the whole tree")
        #expect(!(try Self.body(of: "private var reanalyzeStorageButton: some View {", in: view))
            .contains("rootFallback"),
                "Storage's re-analyze button took Organize's root fallback — it owns no scope to be moved off")
    }

    @Test func theTwoFilingGatesReadOneMember() throws {
        // `lensActions` draws the control and `hasRowTwoActions` decides whether row 2 gets its
        // hairline; a `@ViewBuilder` can't be asked whether it drew anything, so the second mirrors
        // the first's conditions. They must read the same member, not two copies of one expression,
        // or a divider can end up beside a missing control. Asserted in each call site's own body,
        // since a file-wide count also counts doc comments that mention the member.
        let view = try Self.source("LensWorkspaceView.swift")
        let actions = try Self.body(of: "private func lensActions(rows: FilteredRows)", in: view)
        let rowTwo = try Self.body(of: "private var hasRowTwoActions: Bool {", in: view)
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
        // outside it. The render tests see an empty header band on To File before a scan, but an
        // empty band is also what a missing intro card gives, so they can't tell a stand-down with
        // reason from one without. This is the half they can't see: the two conditions must stay
        // the same condition.
        let view = try Self.source("LensWorkspaceView.swift")

        // The gate is a named member (`showsFilingSetupCard`), because the cloud spend row also
        // needs to know whether the card is on screen. So the chain is followed rather than the
        // literal: `filingContent` switches on `filingContentState(…)`, which answers `.setup` from
        // its `showsSetup` argument (pinned by `FilingNotScannedHereTests`), fed by that member,
        // which is still `!hasSuggestedFiling`.
        let content = try Self.body(of: "private func filingContent(", in: view)
        #expect(content.contains("showsSetup: showsFilingSetupCard"),
                "filingContent's intro gate is no longer showsFilingSetupCard — filingIntroOwnsInvitation is now describing a state that does not exist")
        #expect(content.contains("case .setup: filingIntroState"),
                "filingContent no longer renders the setup card the stand-down defers to")
        let showsCard = try Self.body(of: "private var showsFilingSetupCard: Bool {", in: view)
        #expect(showsCard.contains("!syncManager.hasSuggestedFiling"),
                "showsFilingSetupCard no longer tracks the scan flag — the gate and the stand-down have drifted apart")

        let owns = try Self.body(of: "private var filingIntroOwnsInvitation: Bool {", in: view)
        #expect(owns.contains("organizeLens == .toFile"),
                "the stand-down is no longer keyed on To File — the lens whose intro it defers to")
        #expect(owns.contains("!syncManager.hasSuggestedFiling"),
                "the stand-down no longer tracks filingContent's own pre-scan condition")

        // And the routing that makes To File the right key: `contentCard` sends only that rail item
        // to `filingContent`. If another reached it, a second lens would grow an intro card the
        // stand-down doesn't know about.
        let card = try Self.body(of: "private func contentCard(rows: FilteredRows,", in: view)
        #expect(card.contains("if showingOverview {"))
        #expect(card.contains("} else if organizeLens == .restructure {"))
        #expect(card.contains("filingContent(filing: rows.filing, counts: counts)"),
                "contentCard no longer routes the remaining .filing item to filingContent — re-derive which lens owns an intro")
    }

    @Test func anEmptyScopedListBlamesTheScopeAndNotTheSearch() throws {
        // The Rules lens under a scope, with no search running, must not blame the search ("The
        // current search hides all 1 rule", with Clear Search): wrong cause, and an action that
        // can't fix it.
        let view = try Self.source("LensWorkspaceView.swift")
        #expect(view.contains("private func scopeHidesAllState"))
        #expect(view.contains("private func searchHidesAllState"))
        // The chooser resolves the cause before wording the sentence: a live query owns the
        // emptiness, then a live type filter, then the scope. The exact predicate, including why
        // the filter needs `scopedTotal > 0`, is pinned in `LensSearchKeyTests`; this suite cares
        // that the scope arm still exists.
        #expect(view.contains("if scopedTotal == 0, let scope {"),
                "an empty scope no longer gets the scope's own sentence")
        // And the scoped state must state the outside total and offer the clearing action, so "0
        // here" can't read as "0 anywhere".
        #expect(view.contains("elsewhere in the tree"))
        #expect(view.contains("\"Organize Everything\""))
    }

    // MARK: Every number beside a scoped list describes THAT list

    /// The readouts beside a scoped list quote the scoped total, as the badges do. A global total
    /// there (for `Legal`, "3 of 722", "Identical (620)", or the search hiding "all 722 duplicate
    /// groups") is a number the user can see about a list they can't.
    @Test func theNofMDenominatorIsTheScopedList() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        let body = try Self.body(of: "private func lensTrailing(rows: FilteredRows, counts: RailCounts) -> some View {",
                                 in: view)
        for global in ["syncManager.duplicateGroups.count", "syncManager.riskyNames.count",
                       "syncManager.renamePlans.count", "syncManager.filingSuggestions.count",
                       "syncManager.automationRules.count"] {
            #expect(!body.contains(global),
                    "the N-of-M readout is quoting the global \(global) beside a scoped list")
        }
        // Non-vacuity: it must be reading the resolved scoped tally.
        #expect(body.contains("counts.duplicates"))
        #expect(body.contains("counts.toFile"))
    }

    @Test func theDuplicateFilterMenuCountsWithinTheScope() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        #expect(view.contains("Self.filterCounts(syncManager.duplicateGroups, scope: scope)"),
                "the filter menu is counting the whole tree beside a scoped lens")
        let body = try Self.body(
            of: "private static func filterCounts(_ groups: [DuplicateGroup],", in: view)
        #expect(body.contains("where OrganizeScopeFilter.matches(group, scope: scope)"))
        // The search must still not narrow these: a badge reading zero for a filter that would
        // reveal rows is why this counts the unsearched list.
        #expect(!body.contains("q.matches"))
    }

    @Test func theEmptyStatesQuoteTheScopedTotal() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        // No call site may pass a bare global count as the searched-over denominator.
        #expect(!view.contains("noMatchesState(total:"),
                "a caller still passes one undifferentiated total")
        // The backlog's is `counts[.renames]`, not `counts.renames`: its list holds the folder
        // plans and the folded to-fix names, and the subscript is the one expression that counts
        // both, so the empty state and the badge above it show the same number.
        for scoped in ["scopedTotal: counts.duplicates",
                       "scopedTotal: counts[.renames]", "scopedTotal: counts.toFile",
                       "scopedTotal: counts.rules"] {
            #expect(view.contains(scoped), "missing \(scoped) — that lens still quotes the tree")
        }
        // And the scope's own message counts what is elsewhere: the global total minus what is
        // here.
        #expect(view.contains("scopeHidesAllState(total: globalTotal - scopedTotal"))
    }

    // MARK: A count is claimed only where it can be supported

    @Test func theScopeFolderCountTreatsZeroAsUnknown() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        let body = try Self.body(of: "private var scopeFolderCount: Int? {", in: view)
        // A scope the profile knows about always counts at least itself, so zero can only mean "not
        // in the survey", and "Legal · 0 folders" would read as empty.
        #expect(body.contains("return inside > 0 ? inside : nil"),
                "an unsurveyed scope renders as a zero folder count again")
    }

    /// Gated on the right predicate, which is not the same claim as gated. The filing pass
    /// enumerates one folder's direct files, so it can answer only about that folder; an ancestry
    /// test would let a provider-root scan claim "Inbox (TODO) — 0 loose files" while TODO held
    /// fifty. `looseFileScanCovers` is the rule for exactly this pass, as `OrganizeScope`'s doc
    /// says.
    @Test func theInboxCountIsGatedOnTheScanHavingCoveredIt() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        let body = try Self.body(of: "private var inboxShortcut: OrganizeOverview.InboxShortcut? {",
                                 in: view)
        #expect(body.contains("OrganizeScopeFilter.looseFileScanCovers(subject: inbox, scannedFolder: scanned)"),
                "the inbox offer decides coverage by ancestry, so a scan above the inbox claims a zero it never counted")
        #expect(!Self.codeOnly(body).contains("PathBoundary.contains(inbox, under:"),
                "the ancestry test is still in this member")
        #expect(body.contains("let loose = covered"),
                "the count is not gated on the scan having covered the inbox")
    }

    /// And the predicate answers the two cases the call site depends on, so the scan above is not
    /// only pinning a spelling.
    @Test func looseFileScanCoverageIsEqualityNotAncestry() {
        #expect(OrganizeScopeFilter.looseFileScanCovers(subject: "/p/TODO", scannedFolder: "/p/TODO"))
        #expect(!OrganizeScopeFilter.looseFileScanCovers(subject: "/p/TODO", scannedFolder: "/p"),
                "a one-level scan of the parent claimed to have counted the inbox's loose files")
    }

    @Test func restructuresCleanStateGetsTheScopedFolderCount() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        #expect(view.contains("folderCount: scope == nil"),
                "restructure's clean state is quoting the whole survey under a scope")
        #expect(view.contains("isScoped: scope != nil"))
    }

    // MARK: The overview pays for nothing it does not read

    @Test func theOverviewDoesNotResolveRowsItNeverReads() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        let body = try Self.body(of: "private var filteredRows: FilteredRows {", in: view)
        // The compound condition is a named member, `overviewIsOnScreen`, because three readers
        // need it: these rows, the query (the overview answers none), and the "N of M". Spelled out
        // at each, it would be three chances to ask a different question.
        #expect(body.contains("guard !overviewIsOnScreen else { return rows }"),
                "the overview is parsing a query and scoping the filing queue for a value nothing reads")
        #expect(view.contains("private var overviewIsOnScreen: Bool { showingOverview && effectiveLens == .filing }"),
                "overviewIsOnScreen is no longer the compound question this guard needs")
        // Not `showingOverview` alone: that means "no rail item selected", not "the overview
        // renders", since the overview is drawn only from contentCard's `.filing` arm. Guarding on
        // it alone starves the Duplicates apparatus of its rows (see DuplicateRevealLandingTests).
        #expect(!body.contains("guard !showingOverview else"),
                "the guard is back to the condition that emptied the duplicates list")
    }

    // MARK: No apply-all button may render a zero

    /// Every apply-all button gates on having something to apply. Their callers gate on the global
    /// list (`!syncManager.renamePlans.isEmpty`) while the rows they get are narrowed, so the two
    /// disagree whenever a scope empties a lens the tree still has entries for, and an unguarded
    /// button renders a prominent, enabled "Rename 0 files".
    ///
    /// A source scan, because these are private `@ViewBuilder`s on a view a test can't drive.
    /// Bounded by each declaration's closing brace, and failing if a declaration can't be found at
    /// all.
    @Test func everyApplyAllButtonGuardsAgainstAnEmptyList() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        let expected: [(decl: String, guardText: String)] = [
            ("private func fixAllButton(_ risky: [RiskyName]) -> some View {", "if !risky.isEmpty {"),
            ("private func fileAllButton(_ filing: [FilingSuggestion]) -> some View {", "if !batch.isEmpty {"),
            ("private func applyAllButton(_ groups: [DuplicateGroup]) -> some View {", "if !batch.isEmpty {"),
            // Counts files, not plans: a plan whose steps are all applied is still a plan, so
            // `!plans.isEmpty` would leave the same zero-labelled button standing.
            ("private func renameAllButton(_ plans: [RenamePlan]) -> some View {", "if files > 0 {"),
        ]
        for (decl, guardText) in expected {
            let start = try #require(view.range(of: decl), "\(decl) is gone — this scan is vacuous")
            let rest = view[start.upperBound...]
            let end = try #require(rest.range(of: "\n    }"), "no closing brace for \(decl)")
            let body = String(rest[..<end.lowerBound])
            #expect(body.contains(guardText),
                    "\(decl) has no empty-list guard — it can render an apply button labelled 0")
        }
    }

    // MARK: A pointed question is not answered through somebody else's scope

    @Test func theDuplicateRevealClearsAScopeThatWouldHideIt() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        // The outcome is resolved against the whole group list and the rows are drawn through the
        // scoped one; without this the two disagree and a named file comes back as "no copies".
        #expect(view.contains("OrganizeScopeFilter.revealClearsScope(revealedPath: request.path"))
        // Inside the `outcome != .waiting` branch, so a still-scanning handoff doesn't thrash the
        // scope before it has an answer.
        let start = try #require(view.range(of: "if outcome != .waiting {"))
        let rest = view[start.upperBound...]
        let end = try #require(rest.range(of: "\n        }"))
        #expect(String(rest[..<end.lowerBound]).contains("revealClearsScope"),
                "the scope clear has moved outside the answered-outcome branch")
    }

    // MARK: The inbox root-swap is gone, and the path resolution is not

    @Test func theInboxIsOfferedAsAScopeShortcut() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        #expect(view.contains("OrganizeOverview.InboxShortcut"))
        #expect(view.contains("inboxShortcut: inboxShortcut"))
        let overview = try Self.source("OrganizeOverview.swift")
        #expect(overview.contains("Inbox (\\(shortcut.name))"),
                "the inbox offer no longer names the inbox folder")
    }

    // MARK: The destructive confirmation speaks the group's own vocabulary

    @Test func theRemovalConfirmationGetsItsWordsFromDuplicateRemovalPrompt() throws {
        // `DuplicateRemovalPrompt` is pure and tested, and would stay green if `apply` composed the
        // sentence inline again, where a same-text copy could be called a "redundant copy" in the
        // one dialog that precedes a delete.
        let view = try Self.source("LensWorkspaceView.swift")
        let apply = try Self.body(of: "private func apply(_ group: DuplicateGroup) {", in: view)
        #expect(apply.contains("DuplicateRemovalPrompt.itemWord"))
        #expect(apply.contains("DuplicateRemovalPrompt.informativeText"))
        // And the replaced literal is gone from that body. Comment lines are stripped first: a scan
        // that matches the doc comment explaining a removed string can never fail. The assertion
        // above proves the haystack is non-empty either way.
        let code = apply.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("redundant cop"),
                "apply() is composing the removal wording inline again")
        #expect(!code.contains("older version"),
                "apply() is composing the removal wording inline again")
    }

    /// The same rule for the batch dialog, the one that trashes every recommended group at once.
    @Test func theBatchConfirmationGetsItsWordsFromDuplicateRemovalPromptToo() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        let apply = try Self.body(of: "private func applyRecommended(_ groups: [DuplicateGroup]) {",
                                  in: view)
        #expect(apply.contains("DuplicateRemovalPrompt.batchMessageText"))
        #expect(apply.contains("DuplicateRemovalPrompt.batchInformativeText"))
        // Comments stripped before searching, so a doc line quoting the old wording can't keep this
        // green.
        let code = Self.codeOnly(apply)
        #expect(!code.contains("redundant cop"),
                "applyRecommended() is composing the removal wording inline again")
        #expect(!code.contains("group\\(groups.count == 1"),
                "applyRecommended() is pluralizing the group count inline again")
    }

    // MARK: A "clean" verdict needs a scan that covered the scope

    /// `OrganizeScopeFilter.scanCovers` is pure and tested next door, and the overview would
    /// regress the moment `overviewModel` stopped consulting it: a scoped count of zero would
    /// render as "Nothing to do in Legal. Every check that has run came back clean." over a subtree
    /// nothing had opened.
    ///
    /// Each lens is asserted by the predicate its own pass justifies, because the passes have
    /// different shapes:
    ///
    /// - To File enumerates one folder one level deep → `looseFileScanCovers` (equality). Ancestry
    ///   would call a provider-root scan "covering" `Legal` and report a false clean.
    /// - Duplicates hashes a whole subtree → `scanCovers` (ancestry).
    /// - Risky names and Renames read the provider-wide taxonomy → no gate at all. Gating them on
    ///   the filing folder would hide real findings; the negative below stops that.
    @Test func eachScannedLensGatesOnThePredicateItsPassJustifies() throws {
        let view = try Self.source("LensWorkspaceView.swift")
        // The rule lives in `passCoverage` because the rail asks it too, so the two surfaces can't
        // disagree.
        let coverage = try Self.body(of: "func passCoverage(for scope: OrganizeScope?)", in: view)

        #expect(coverage.contains("OrganizeScopeFilter.looseFileScanCovers"),
                "To File no longer asks whether the enumerated folder was the subject")
        #expect(coverage.contains("scannedFolder: syncManager.filingScanFolder"))
        #expect(coverage.contains("OrganizeScopeFilter.scanCovers"),
                "Duplicates no longer asks whether its scan covered the subject")
        #expect(coverage.contains("scannedRoot: syncManager.duplicateScanRoot"))

        // The subject is what the screen claims, and unscoped that is the source's anchor:
        // `scope?.path ?? providerAnchor`. Falling back to the scanned root would ask whether each
        // scan covered itself, so browsing into a subfolder and rescanning would make the whole
        // tree read "clean".
        //
        // The anchor, not the root, since a source's root can sit above the folder it opens at: an
        // unscoped filing scan enumerates the landing folder, and `looseFileScanCovers` compares by
        // equality, so the account root would report a completed pass as never run, on every cloud
        // source.
        #expect(coverage.contains("let subject = scope?.path ?? providerAnchor"),
                "the coverage subject is no longer scope-or-anchor")
        #expect(!Self.codeOnly(coverage).contains("syncManager.duplicateScanRoot\n"),
                "the scanned root is being used as the subject — that asks whether a scan covered itself")

        // Both readers consult it.
        let model = try Self.body(of: "var overviewModel: OverviewModel {", in: view)
        #expect(model.contains("passCoverage(for: scope)"))
        let rail = try Self.body(of: "var railCounts: RailCounts {", in: view)
        #expect(rail.contains("passCoverage(for: appliedScope(for: .toFile)).filing"),
                "the rail's To File badge stopped asking whether the scan covered its subject")
        #expect(rail.contains("passCoverage(for: appliedScope(for: .duplicates)).duplicates"),
                "the rail's Duplicates badge stopped asking whether the scan covered its subject")
        let code = Self.codeOnly(model)

        // Exactly one arm may consult the loose-file coverage flag: To File's. Comments are
        // stripped first, because the note above `filingCovers` names every lens.
        #expect(code.components(separatedBy: "!filingCovers").count - 1 == 1,
                "Names or Renames is gating on the filing folder again — their detectors read the provider-wide taxonomy, so that hides findings the scan does have")
        #expect(code.components(separatedBy: "!duplicatesCover").count - 1 == 1)
    }

    /// The pass-shape claim the gate above rests on, checked against the code that makes it true:
    /// if the loose-file walk stops being one level deep, or the name and rename detectors stop
    /// being handed the provider root, the predicates chosen next door are wrong and this says so.
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
