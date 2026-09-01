import Testing
import SwiftUI
@testable import Sync
@testable import FileExplorer

/// What `LensWorkspaceView` actually hands the overview.
///
/// **The gap this fills is the reason two of the five `isScanning` arms were wrong.** The render
/// suite mounts ``OrganizeOverview`` directly and supplies its own sections, so it can assert what
/// the *view* does with a scanning flag and never whether the flag it is given is true. `LensWorkspaceView`
/// built those flags, nothing read them for the whole life of the field — `isScanning` existed on
/// the section before the overview was rebuilt and the old view never referenced it — and the
/// moment they became load-bearing, two arms were quietly reporting the wrong thing.
///
/// Pure: a manager with flags set, no window, no render.
@MainActor
@Suite struct OrganizeOverviewWiringTests {

    /// **These read the developer's live defaults, and that is safe only because of what they
    /// assert.** `overviewModel` reaches `scope`, which is `@AppStorage`-backed, and a property read
    /// off the struct rather than through a mounted hierarchy takes `UserDefaults.standard` — no
    /// `.defaultAppStorage` can intercept it. Writing a scratch scope to pin it would mean writing
    /// this machine's own domain, which is off limits.
    ///
    /// It held originally because every assertion was about `isScanning`, which is computed from
    /// the manager's lifecycle flags alone and cannot vary with a scope. The coverage tests below
    /// *do* assert states that a scope would change, and they are safe for a second, narrower
    /// reason: **this fixture's provider root is `/root`**, a real persisted scope points under the
    /// user's home, and ``OrganizeScope/init(path:providerRoot:)`` refuses a path outside its root —
    /// so `scope` resolves to nil here whatever the machine has stored, and the subject is `/root`.
    /// A test added here whose fixture uses a provider root under the home would lose that.
    private func subject(_ manager: FileSyncManager) -> LensWorkspaceView {
        LensWorkspaceView(syncManager: manager, lens: .filing, providerName: "Projects",
                 scanTargetFolder: "/root", onFindDuplicates: {}, onFindFilingSuggestions: {},
                 providerRoot: "/root")
    }

    private func scanning(_ manager: FileSyncManager) -> Set<OrganizeLens> {
        Set(subject(manager).overviewModel.sections.filter(\.isScanning).map(\.lens))
    }

    // MARK: - What a zero means, and what it must never suppress

    /// **These three are safe to assert against live defaults even though `overviewModel` reads the
    /// `@AppStorage` scope**, because the fixture's provider root is `/root`: a real persisted scope
    /// points somewhere under the user's home, `OrganizeScope(path:providerRoot:)` refuses a path
    /// outside its root, and `scope` is therefore reliably nil here. The subject is then `/root`.
    private func duplicatesState(_ manager: FileSyncManager) -> OrganizeOverviewState? {
        subject(manager).overviewModel.sections.first { $0.lens == .duplicates }?.state
    }

    private func group(at path: String) -> DuplicateGroup {
        func copy(_ p: String, keeper: Bool) -> DuplicateCopy {
            DuplicateCopy(id: p, name: (p as NSString).lastPathComponent, isDirectory: false,
                          size: 10, itemCount: 1, modificationDate: nil, uniqueItemCount: 0,
                          depth: 2, isRecommendedKeeper: keeper)
        }
        return DuplicateGroup(matchType: .identical, name: "x.pdf", isDirectory: false,
                              copies: [copy(path, keeper: true), copy(path + ".dup", keeper: false)],
                              reclaimableBytes: 10)
    }

    /// A scan of one browsed subfolder must not be allowed to call the whole tree clean. Unscoped
    /// the overview says "Nothing to do here. Every check that has run came back clean." — about
    /// everything — so its subject is the provider root, and `/root/Photos` does not cover it.
    @Test func aSubfolderScanDoesNotLetTheOverviewCallTheWholeTreeClean() {
        let m = FileSyncManager()
        m.duplicateScanRoot = "/root/Photos"
        m.hasFoundDuplicates = true
        m.duplicateGroups = []
        #expect(duplicatesState(m) == .notScanned,
                "a scan of one subfolder was reported as a clean bill for the whole tree")
    }

    /// The other direction, so the guard above cannot be "never clean": a scan of the tree's top
    /// with nothing found is a real clean bill.
    @Test func aScanOfTheWholeTreeStillReportsClean() {
        let m = FileSyncManager()
        m.duplicateScanRoot = "/root"
        m.hasFoundDuplicates = true
        m.duplicateGroups = []
        #expect(duplicatesState(m) == .clean)
    }

    /// **Coverage decides what a ZERO means — it must never suppress findings the scan really
    /// made.** Groups found under `/root/Photos` are real wherever the subject is pointed, and an
    /// uncovered-therefore-notScanned arm would bury them. This is the same error as gating Names
    /// on the filing folder, and it was live in the first draft of the subject fix.
    @Test func anUncoveredScanStillShowsTheFindingsItDidMake() {
        let m = FileSyncManager()
        m.duplicateScanRoot = "/root/Photos"
        m.hasFoundDuplicates = true
        m.duplicateGroups = [group(at: "/root/Photos/x.pdf")]
        guard case .findings(let count, _, _) = duplicatesState(m) else {
            Issue.record("real findings were hidden: \(String(describing: duplicatesState(m)))")
            return
        }
        #expect(count == 1)
    }

    /// **The rail must answer the coverage question the overview answers**, or the two surfaces
    /// disagree about the same lens on the same screen — the rail drawing its quiet "checked,
    /// nothing here" badge beside an overview row saying the lens never ran. The rail's `scanned`
    /// set read `hasFoundDuplicates` alone, which stays true forever once any scan has run.
    @Test func theRailDoesNotCallALensCleanForASubtreeItsScanNeverCovered() {
        let m = FileSyncManager()
        m.duplicateScanRoot = "/root/Photos"
        m.hasFoundDuplicates = true
        m.duplicateGroups = []
        #expect(subject(m).railCounts.state(.duplicates) == .notScanned,
                "the rail called the whole tree checked on the strength of one subfolder")
        // The overview says the same thing about the same lens — that agreement is the point.
        #expect(duplicatesState(m) == .notScanned)
    }

    /// Both directions, so the rail cannot simply have stopped saying clean.
    @Test func theRailStillSaysCleanWhenTheScanCoveredTheSubject() {
        let m = FileSyncManager()
        m.duplicateScanRoot = "/root"
        m.hasFoundDuplicates = true
        m.duplicateGroups = []
        #expect(subject(m).railCounts.state(.duplicates) == .clean)
        #expect(duplicatesState(m) == .clean)
    }

    /// **To File takes the one-level rule, and this is the only behavioural test of it.** Its pass
    /// enumerates the direct files of one folder, so a scan of the provider root cannot answer for
    /// anything below it — where Duplicates, being recursive, could.
    @Test func toFileNeedsTheExactFolderWhileDuplicatesAcceptsAnAncestor() {
        let m = FileSyncManager()
        m.filingScanFolder = "/root/TODO"
        m.hasSuggestedFiling = true
        m.duplicateScanRoot = "/root/TODO"
        m.hasFoundDuplicates = true

        // Subject is `/root` (no scope resolves against this fixture's provider root).
        #expect(subject(m).railCounts.state(.toFile) == .notScanned,
                "a one-level scan of TODO was allowed to answer for the whole tree")
        #expect(subject(m).railCounts.state(.duplicates) == .notScanned)

        // Now the pass really did enumerate the subject's own loose files.
        m.filingScanFolder = "/root"
        #expect(subject(m).railCounts.state(.toFile) == .clean)
    }

    /// Names and Renames ride the provider-wide taxonomy walk, so they are covered wherever the
    /// subject points — gating them would hide findings the scan genuinely made.
    @Test func namesAndRenamesAreNeverGatedByTheFilingFolder() {
        let m = FileSyncManager()
        m.filingScanFolder = "/root/TODO"
        m.hasSuggestedFiling = true
        m.hasScannedNames = true
        #expect(subject(m).railCounts.state(.renames) == .clean)
    }

    private func renamesState(_ manager: FileSyncManager) -> OrganizeOverviewState? {
        subject(manager).overviewModel.sections.first { $0.lens == .renames }?.state
    }

    /// **The folded Renames item is clean only when BOTH of its halves ran** — the rename plans
    /// (filing walk) and the risky names (`detectRiskyNames`, run on that walk only when a name
    /// ruleset is supplied). A filing scan without the names half computed half the card's list;
    /// "nothing here" would vouch for a list nothing looked at, so the honest answer underclaims.
    /// Asserted on the rail AND the overview, because the agreement is the point — this is the
    /// state where the two used to split, the rail saying clean beside a card that never said it.
    @Test func aFilingScanWithoutTheNamesHalfDoesNotCallRenamesClean() {
        let m = FileSyncManager()
        m.filingScanFolder = "/root"
        m.hasSuggestedFiling = true    // rename plans computed; hasScannedNames stays false
        #expect(subject(m).railCounts.state(.renames) == .notScanned,
                "rename plans alone called the folded item clean — the names list was never computed")
        #expect(renamesState(m) == .notScanned)
    }

    /// And the mirror half, so the rule is "both", not "the rename half".
    @Test func aNamesOnlyPassDoesNotCallRenamesClean() {
        let m = FileSyncManager()
        m.hasScannedNames = true       // risky names computed clean; the plans never were
        #expect(subject(m).railCounts.state(.renames) == .notScanned,
                "a names-only pass called the whole folded item clean")
        #expect(renamesState(m) == .notScanned)
    }

    /// **The filing walk marks every lens it answers.**
    ///
    /// The risky-name half rode `isScanningNames` alone, which is never true on this path: the
    /// filing scan reaches names through `detectRiskyNames`, and that function calls `completeScan`
    /// without ever calling `beginScan` — the name lifecycle is begun only by `scanNames`, which
    /// has no caller in the app at all. So during one walk To File said "rescanning" and the
    /// backlog beside it showed a stale count in confident bold, from the same republish.
    @Test func theFilingWalkMarksEveryLensItAnswers() {
        let m = FileSyncManager()
        m.isSuggestingFiles = true
        #expect(scanning(m) == Set(OrganizePass.file.lenses))
    }

    /// The name lifecycle still counts when it is the thing running — the fix widened the condition
    /// rather than swapping one flag for another.
    @Test func aStandaloneNameScanStillMarksNames() {
        let m = FileSyncManager()
        m.isScanningNames = true
        // Post-fold the Renames card hosts the names findings, so it is the card a standalone
        // name scan must mark — the claim the old Names card carried, on its new home.
        #expect(scanning(m).contains(.renames))
        #expect(!scanning(m).contains(.toFile), "a name scan is not the whole filing walk")
    }

    /// **Restructure follows the folder survey**, which is its pass.
    ///
    /// It was hard-coded `false` — defensible while nothing read it, since Restructure runs no walk
    /// of its own — and wrong the moment the row grew an "Update folder memory" button: the button
    /// stayed live and the count stayed bold for the whole survey it had just started, while the
    /// menu item running the identical action is `.disabled` for exactly that period.
    @Test func restructureFollowsTheFolderSurvey() {
        let m = FileSyncManager()
        #expect(!scanning(m).contains(.restructure))
        m.filingSurveyLifecycle.isRunning = true
        #expect(scanning(m).contains(.restructure))
    }

    /// Duplicates follows its own hashing pass, and nothing else does.
    @Test func duplicatesFollowsItsOwnScan() {
        let m = FileSyncManager()
        m.isFindingDuplicates = true
        #expect(scanning(m) == [.duplicates])
    }

    /// An idle manager marks nothing — the floor that keeps the assertions above from passing on a
    /// model that simply reports everything as busy.
    @Test func anIdleManagerMarksNothing() {
        #expect(scanning(FileSyncManager()).isEmpty)
    }

    /// Every lens's scanning flag belongs to **its own pass**, checked one pass at a time.
    ///
    /// The generalisation of the two defects above: each was a lens reporting from a lifecycle that
    /// was not the one behind it. Driving each pass in isolation and asserting exactly its lenses
    /// light up is the shape that catches the next one.
    @Test func eachPassMarksExactlyItsOwnLenses() {
        for pass in OrganizePass.allCases {
            let m = FileSyncManager()
            switch pass {
            case .file: m.isSuggestingFiles = true
            case .duplicates: m.isFindingDuplicates = true
            case .folderMemory: m.filingSurveyLifecycle.isRunning = true
            }
            let expected = Set(pass.lenses)
            #expect(scanning(m) == expected,
                    "\(pass.rawValue) running marked \(scanning(m)) — expected \(expected)")
        }
    }

    /// Rules takes no section at all, so it can never be reported as scanning or as unscanned.
    /// **The ledger counts exactly the lenses the host hands it sections for.**
    ///
    /// Two independent expressions decide that today and nothing tied them together: this switch
    /// returns `nil` for Rules and for the folded Names lens, while
    /// ``OrganizeOverview/Ledger/countedLenses(runnablePasses:)`` filters on `carriesBadge` and
    /// `isFoldedIntoRenames`. They agree by coincidence of authorship, and either direction of
    /// drift is a defect this screen has already shipped once in another form:
    ///
    /// - **Counted with no section** — `checksRun` can never reach `checksTotal`, so the ratio
    ///   stands open forever. That is exactly the "4 of 5 permanently" defect the runnable-pass
    ///   narrowing was added to fix, arriving through a different door.
    /// - **A section that is not counted** — the rows and the footer describe a check the ledger
    ///   refuses to count, so one screen gives two answers to "how many came back clean". Rendered
    ///   during review, from a fixture that supplied the folded lens by hand.
    ///
    /// Asserted at the full runnable set, because that is the only configuration in which the two
    /// are meant to be equal; narrowing is the ledger's own business and is covered separately.
    @Test func theLedgerCountsExactlyTheLensesThatTakeCountableSections() {
        let emitted = Set(subject(FileSyncManager()).overviewModel.sections.map(\.lens))
        let counted = OrganizeOverview.Ledger
            .countedLenses(runnablePasses: Set(OrganizePass.allCases))
        // **The two sets are no longer equal, and the difference is named rather than tolerated.**
        // This asserted plain equality while every section was a check the ledger counted. Storage
        // emits a section that is deliberately NOT a check — a receipt has no clean/reporting
        // answer to contribute, and counting it would make the meter read "4 of 5" forever from
        // the first analysis onward. So the invariant becomes: every section is either counted, or
        // it is one of the known uncounted kinds, and nothing is counted without a section.
        #expect(emitted.subtracting(counted) == [.storage],
                "a lens takes a section the ledger does not count, and it is not Storage — either it belongs in the meter or its exemption needs stating here")
        #expect(counted.subtracting(emitted).isEmpty,
                "the ledger counts a lens that emits no section — the meter's denominator includes a check the page never shows")
        // Non-vacuity: an equality between two empty sets would satisfy the lines above.
        #expect(!emitted.isEmpty)
        #expect(!counted.isEmpty)
    }

    // MARK: - The half-scanned Renames cell, on both surfaces at once

    private static func plan(_ relativePath: String) -> RenamePlan {
        RenamePlan(folderPath: "/root/\(relativePath)", relativePath: relativePath,
                   scheme: .position,
                   steps: [RenameStep(currentPath: "/root/\(relativePath)/4. Apr 2021.pdf",
                                      currentName: "4. Apr 2021.pdf",
                                      proposedName: "04. Apr 2021.pdf",
                                      kind: .tidied, reason: "Padded to two digits")],
                   skips: [])
    }

    /// **The rail badge and the overview card must not describe the same cell differently** — and
    /// for this one cell they did.
    ///
    /// `findFilingSuggestions` publishes the rename plans and the risky names partway through its
    /// walk and sets `hasSuggestedFiling` only at the very end. So there is a real, reachable
    /// state — every mid-scan moment, and permanently for anyone who hits Cancel there — with
    /// plans on the manager, the names half finished, and the filing flag still false. The rail
    /// answers findings-first and badged them; the overview asked the completion flags first and
    /// called the lens never-scanned over the top of work it was already showing a number for.
    ///
    /// Both surfaces are asked here, from ONE manager, because the defect was disagreement: a
    /// pin on either alone would have stayed green through it.
    @Test func aHalfFinishedScanIsReportedTheSameWayByTheRailAndTheOverview() throws {
        let m = FileSyncManager()
        // Mid-scan exactly: the names half completed and both lists published, the filing half
        // not yet. (`hasScannedNames`/`hasSuggestedFiling` are the flags the walk sets, in this
        // order — see `FileSyncManager+Filing.findFilingSuggestions`.)
        m.renamePlans = [Self.plan("Bills"), Self.plan("Statements")]
        m.riskyNames = []
        m.hasScannedNames = true
        m.hasSuggestedFiling = false

        let view = subject(m)
        #expect(view.railCounts[.renames] == 2, "the badge counts the published plans")
        #expect(view.railCounts.state(.renames) == .reporting(2),
                "the rail reports findings ahead of the completion gate")

        let section = try #require(view.overviewModel.sections.first { $0.lens == .renames })
        if case .findings(let count, let headline, _) = section.state {
            #expect(count == 2, "the overview counts the same published plans the badge does")
            #expect(headline == "2 folders")
        } else {
            Issue.record("the overview said \(section.state) about findings the badge is showing")
        }

        // The gate still decides what a ZERO means — the direction that must NOT be lost. Same
        // manager, same half-finished flags, nothing found: now both surfaces say "not scanned",
        // which is a different answer from `.clean` and the one a half-run pass has earned.
        m.renamePlans = []
        let empty = subject(m)
        #expect(empty.railCounts.state(.renames) == .notScanned)
        #expect(empty.overviewModel.sections.first { $0.lens == .renames }?.state == .notScanned)

        // And with both halves done and nothing found, both say clean — so the assertion above
        // discriminates the gate rather than agreeing with every state.
        m.hasSuggestedFiling = true
        let done = subject(m)
        #expect(done.railCounts.state(.renames) == .clean)
        #expect(done.overviewModel.sections.first { $0.lens == .renames }?.state == .clean)
    }

    @Test func rulesTakesNoSection() {
        let sections = subject(FileSyncManager()).overviewModel.sections
        #expect(!sections.contains { $0.lens == .rules })
        // **Badge-carriers PLUS Storage**, and the addition is deliberate rather than a widening
        // of the old rule. Rules takes no section because there is nothing about a standing
        // configuration for a landing page to report. Storage has something to report — it just
        // is not work — so it takes a section and that section is a `.receipt`.
        #expect(sections.count == OrganizeLens.railItems.filter(\.carriesBadge).count + 1)
        #expect(sections.contains { $0.lens == .storage })
    }

    // MARK: - Storage's card is a receipt, not a backlog

    private func storageState(_ manager: FileSyncManager) -> OrganizeOverviewState? {
        subject(manager).overviewModel.sections.first { $0.lens == .storage }?.state
    }

    private static func report(largest: Int = 62, stale: Int = 318,
                               reclaim: Int = 4) -> StorageLensReport {
        func entry(_ n: String, _ b: Int) -> StorageEntry {
            StorageEntry(path: "/root/\(n)", name: n, bytes: b,
                         modified: Date(timeIntervalSince1970: 0))
        }
        return StorageLensReport(treemap: [],
                                 largest: (0..<largest).map { entry("big\($0)", 3_000_000) },
                                 stale: (0..<stale).map { entry("old\($0)", 1_000_000) },
                                 reclaimCandidates: (0..<reclaim).map { entry("r\($0)", 2_000_000) },
                                 totalBytes: 214_600_000_000)
    }

    /// **Never `.findings`, and that is the whole reason `.receipt` exists.**
    ///
    /// `.findings` renders count-forward — a pill, examples, and a way in captioned with the count
    /// — which on a lens with no verb that touches a file reads as a to-do nobody can discharge.
    /// That is the exact misread `carriesBadge` refuses on the rail; a `.findings` state here would
    /// let it back in through the landing page.
    @Test func storageReportsAReceiptRatherThanFindings() {
        let m = FileSyncManager()
        m.storageLensReport = Self.report()
        m.storageLensRoot = URL(fileURLWithPath: "/root/Documents")

        let state = storageState(m)
        guard case .receipt(let headline, let detail)? = state else {
            Issue.record("Storage's overview section is \(String(describing: state)), not a receipt")
            return
        }
        // The standing facts, not a single count to act on.
        #expect(headline.contains("total"))
        #expect(headline.contains("62 large"))
        #expect(headline.contains("318 untouched"))
        // Provenance: which tree, so a RESTORED report can never be read under the wrong root.
        #expect(detail.contains("Documents"),
                "the receipt does not name the root it describes — a restored report would be read under whatever scope happens to be set")
        #expect(detail.hasPrefix("Analyzed"))
    }

    /// Before an analysis it says it has not looked, rather than reporting an empty report.
    @Test func storageSaysNotScannedBeforeItHasRun() {
        #expect(storageState(FileSyncManager()) == .notScanned)
    }

    /// **The ledger's denominator does not move**, in either state — which is the claim SL4 rests
    /// on and the reason no ledger code was written for it.
    ///
    /// `countedLenses` gates on `carriesBadge`, so a badgeless Storage never enters `checksTotal`;
    /// a receipt is likewise not a "check that reported". Asserted in BOTH states because the
    /// failure would be asymmetric — a section that counted only once it had something to say would
    /// leave the meter reading "4 of 5" from the moment the first analysis finished.
    @Test func theLedgerIgnoresStorageInEveryState() {
        let counted = OrganizeOverview.Ledger.countedLenses(runnablePasses: Set(OrganizePass.allCases))
        #expect(!counted.contains(.storage))
        #expect(!counted.contains(.rules))
        #expect(counted.count == 4)

        let before = OrganizeOverview.Ledger.derived(
            from: subject(FileSyncManager()).overviewModel.sections,
            runnablePasses: Set(OrganizePass.allCases), reclaimable: nil, scopeFolders: nil)
        let m = FileSyncManager()
        m.storageLensReport = Self.report()
        let after = OrganizeOverview.Ledger.derived(
            from: subject(m).overviewModel.sections,
            runnablePasses: Set(OrganizePass.allCases), reclaimable: nil, scopeFolders: nil)
        #expect(before.checksTotal == 4)
        #expect(after.checksTotal == 4)
        #expect(before.checksRun == after.checksRun,
                "analyzing storage moved the checks-run count — the report is being counted as a check that reported")
    }

    /// **A never-analyzed Storage is stranded, and stranded is where it would have had no verb.**
    ///
    /// Every other unscanned lens reaches a scan from the landing page: it is either covered by a
    /// pass card (`pendingPasses`) or gets a run button beside its footer line. Storage is in no
    /// `OrganizePass`, so `OrganizePass(producing: .storage)` is nil and BOTH routes answer nothing
    /// — the line read "Storage — not scanned" with nothing to click, the only dead end on the
    /// screen, on the one lens whose entire state is "you have not looked yet".
    ///
    /// Pinned here rather than in pixels because the shape is what matters: if Storage ever stops
    /// being stranded (someone gives it a pass), the footer stops being where its verb belongs and
    /// this fails rather than leaving a second button somewhere nobody looks.
    @Test func aNeverAnalyzedStorageIsStrandedWithNoPassToOfferIt() {
        let sections = subject(FileSyncManager()).overviewModel.sections
        let overview = OrganizeOverview(
            sections: sections, scopeLabel: nil, accent: .blue,
            ledger: OrganizeOverview.Ledger(),
            runnablePasses: Set(OrganizePass.allCases),
            onOpen: { _ in }, onRun: { _ in })

        #expect(sections.first { $0.lens == .storage }?.state == .notScanned)
        #expect(overview.strandedUnscanned.contains { $0.lens == .storage },
                "Storage is not on the stranded line, so the Analyze button added there never draws")
        #expect(!overview.pendingPasses.flatMap(\.lenses).contains(.storage),
                "a pass now claims Storage — its verb belongs on that card, not on the footer line")
        #expect(OrganizePass(producing: .storage) == nil,
                "Storage gained a pass; `offersPassRun` will now mint a run button beside the storage-specific one")
    }

    /// The receipt's day-word, which is the one piece of the card that is arithmetic.
    @Test func theReceiptNamesADayRatherThanADuration() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(LensWorkspaceView.receiptDay(now, now: now) == "today")
        #expect(LensWorkspaceView.receiptDay(now.addingTimeInterval(-86_400), now: now) == "yesterday")
        // Inside the week: a weekday name, which is what someone matches against their own memory.
        let threeDays = LensWorkspaceView.receiptDay(now.addingTimeInterval(-3 * 86_400), now: now)
        #expect(!threeDays.hasPrefix("on "), "a day inside the week rendered as a date: \(threeDays)")
        #expect(threeDays != "today" && threeDays != "yesterday")
        // Beyond it, a date — "Tuesday" three weeks on is worse than useless.
        let month = LensWorkspaceView.receiptDay(now.addingTimeInterval(-30 * 86_400), now: now)
        #expect(month.hasPrefix("on "), "a month-old analysis rendered as a weekday: \(month)")
    }
}
