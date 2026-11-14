import Testing
import SwiftUI
@testable import Sync
@testable import FileExplorer

/// What `LensWorkspaceView` actually hands the overview. The render suite mounts
/// ``OrganizeOverview`` with its own sections, so it can't see whether the flags it is given are
/// true; this suite checks the flags and states `LensWorkspaceView` builds. Pure: no window.
@MainActor
@Suite struct OrganizeOverviewWiringTests {

/// These read the developer's live defaults, and are safe only because of the fixture.
/// `overviewModel` reaches the `@AppStorage`-backed `scope`, and a property read off the struct
/// takes `UserDefaults.standard`, which no `.defaultAppStorage` can intercept. The provider root is
/// `/root`, and ``OrganizeScope/init(path:providerRoot:)`` refuses a real persisted scope outside
/// it, so `scope` is nil and the subject is `/root`. **Never** give a fixture here a provider root
/// under the home.
    private func subject(_ manager: FileSyncManager) -> LensWorkspaceView {
        LensWorkspaceView(syncManager: manager, lens: .filing, providerName: "Projects",
                 scanTargetFolder: "/root", onFindDuplicates: {}, onFindFilingSuggestions: {},
                 providerRoot: "/root")
    }

    private func scanning(_ manager: FileSyncManager) -> Set<OrganizeLens> {
        Set(subject(manager).overviewModel.sections.filter(\.isScanning).map(\.lens))
    }

    // MARK: - What a zero means, and what it must never suppress

    /// Safe against live defaults for the reason `subject(_:)` gives: with a provider root of
    /// `/root`, `scope` is nil and the subject is `/root`.
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

/// Coverage decides what a zero means; it must never bury findings the scan really made.
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

/// The rail answers the coverage question the overview answers. `hasFoundDuplicates` alone can't:
/// it stays true once any scan has run. Both directions, so the rail can't just stop saying clean.
    @Test(arguments: [("/root/Photos", false), ("/root", true)])
    func theRailAndTheOverviewAgreeOnWhatTheScanCovered(scanRoot: String, covered: Bool) {
        let m = FileSyncManager()
        m.duplicateScanRoot = scanRoot
        m.hasFoundDuplicates = true
        m.duplicateGroups = []
        let rail: RailItemState = covered ? .clean : .notScanned
        let overview: OrganizeOverviewState = covered ? .clean : .notScanned
        #expect(subject(m).railCounts.state(.duplicates) == rail,
                covered ? "the rail stopped saying clean for a scan that covered the subject"
                        : "the rail called the whole tree checked on the strength of one subfolder")
        // The overview says the same thing about the same lens — that agreement is the point.
        #expect(duplicatesState(m) == overview)
    }

/// To File takes the one-level rule (its pass enumerates one folder's direct files), where the
/// recursive Duplicates answers for anything below its root.
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

    /// Renames (its plans and the risky names) rides the provider-wide taxonomy walk, so it is
    /// covered wherever the subject points; gating it would hide findings the scan really made.
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

/// Renames is clean only when both halves ran, the rename plans and the risky names, or "nothing
/// here" vouches for a list nothing looked at. Asserted on the rail and the overview together.
    @Test(arguments: [(true, false), (false, true)])
    func oneHalfAloneDoesNotCallRenamesClean(plans: Bool, names: Bool) {
        let m = FileSyncManager()
        if plans { m.filingScanFolder = "/root" }
        m.hasSuggestedFiling = plans
        m.hasScannedNames = names
        #expect(subject(m).railCounts.state(.renames) == .notScanned,
                plans ? "rename plans alone called the folded item clean — the names list was never computed"
                      : "a names-only pass called the whole folded item clean")
        #expect(renamesState(m) == .notScanned)
    }

    /// The name lifecycle still counts when it is the thing running: the condition covers both
    /// flags, not one in place of the other.
    @Test func aStandaloneNameScanStillMarksNames() {
        let m = FileSyncManager()
        m.isScanningNames = true
        // The Renames card hosts the names findings, so it is the card a standalone name scan
        // must mark.
        #expect(scanning(m).contains(.renames))
        #expect(!scanning(m).contains(.toFile), "a name scan is not the whole filing walk")
    }

/// An idle manager marks nothing: the floor under the assertions above.
    @Test func anIdleManagerMarksNothing() {
// Restructure included, so a hard-coded `false` flag is told apart.
        #expect(scanning(FileSyncManager()).isEmpty)
    }

/// Every lens's scanning flag belongs to its own pass: each pass alone lights exactly its lenses.
/// The filing walk marks Renames too, since `isScanningNames` is never true on that path, and
/// Restructure follows the folder survey.
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

/// The ledger counts exactly the lenses the host hands it countable sections for. `overviewModel`
/// emits no section for Rules, while ``OrganizeOverview/Ledger/countedLenses(runnablePasses:)``
/// filters on `carriesBadge` and a runnable pass. Counted with no section, the ratio never closes
/// ("4 of 5" forever); a section not counted gives two answers to "how many came back clean".
/// Asserted at the full runnable set, the only configuration where the two must match.
    @Test func theLedgerCountsExactlyTheLensesThatTakeCountableSections() {
        let emitted = Set(subject(FileSyncManager()).overviewModel.sections.map(\.lens))
        let counted = OrganizeOverview.Ledger
            .countedLenses(runnablePasses: Set(OrganizePass.allCases))
// The sets differ by name: Storage's section is deliberately not a check (a receipt has no
// clean/reporting answer).
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

/// The rail badge and the overview card describe a half-finished Renames scan the same way.
/// `findFilingSuggestions` publishes plans and risky names partway and sets `hasSuggestedFiling`
/// only at the end, so a mid-scan moment (or a Cancel there) has plans with the flag false.
/// Findings come first on both. One manager, because a pin on either alone can't see disagreement.
    @Test func aHalfFinishedScanIsReportedTheSameWayByTheRailAndTheOverview() throws {
        let m = FileSyncManager()
// Mid-scan exactly: the names half completed and both lists published, the filing half not yet
// (the order `FileSyncManager+Filing.findFilingSuggestions` sets them).
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

// The gate still decides what a zero means: nothing found half-run is "not scanned".
        m.renamePlans = []
        let empty = subject(m)
        #expect(empty.railCounts.state(.renames) == .notScanned)
        #expect(empty.overviewModel.sections.first { $0.lens == .renames }?.state == .notScanned)

// And both halves done with nothing found is clean, so the gate is discriminating.
        m.hasSuggestedFiling = true
        let done = subject(m)
        #expect(done.railCounts.state(.renames) == .clean)
        #expect(done.overviewModel.sections.first { $0.lens == .renames }?.state == .clean)
    }

    /// Rules takes no section at all, so it can never be reported as scanning or as unscanned.
    @Test func rulesTakesNoSection() {
        let sections = subject(FileSyncManager()).overviewModel.sections
        #expect(!sections.contains { $0.lens == .rules })
// Badge-carriers plus Storage, whose `.receipt` section reports something that isn't work.
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
                                 totalBytes: 214_600_000_000, fileCount: largest,
                                 staleCount: stale, reclaimCount: reclaim,
                                 reclaimableBytes: reclaim * 2_000_000)
    }

/// Never `.findings`: count-forward rendering on a lens with no verb that touches a file reads as a
/// to-do nobody can discharge.
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
        #expect(headline.contains("62 files"))
        #expect(headline.contains("318 untouched"))
        // Provenance: which tree, so a restored report can never be read under the wrong root.
        #expect(detail.contains("Documents"),
                "the receipt does not name the root it describes — a restored report would be read under whatever scope happens to be set")
        #expect(detail.hasPrefix("Analyzed"))
    }

/// The headline reads the tree's totals, not the lists' lengths, which are capped at 20 rows.
    @Test func storagesHeadlineCountsTheTreeNotTheCappedLists() {
        func entry(_ n: String, _ b: Int) -> StorageEntry {
            StorageEntry(path: "/root/\(n)", name: n, bytes: b, modified: Date(timeIntervalSince1970: 0))
        }
        let capped = (0..<20).map { entry("f\($0)", 2_000_000) }
        let m = FileSyncManager()
        m.storageLensReport = StorageLensReport(
            treemap: [], largest: capped, stale: capped, reclaimCandidates: capped,
            totalBytes: 900_000_000_000,
            fileCount: 640, staleCount: 318, reclaimCount: 77, reclaimableBytes: 154_000_000)
        m.storageLensRoot = URL(fileURLWithPath: "/root")

        guard case .receipt(let headline, _)? = storageState(m) else {
            Issue.record("Storage's overview section is not a receipt")
            return
        }
        #expect(headline.contains("640 files"), "\(headline)")
        #expect(headline.contains("318 untouched"), "\(headline)")
        #expect(headline.contains("\(FileSyncManager.formatBytes(154_000_000)) reclaimable"), "\(headline)")
        #expect(!headline.contains("20 "), "the headline still counts the capped lists: \(headline)")
        #expect(headline == LensWorkspaceView.storageReceiptHeadline(m.storageLensReport!))
    }

/// A report saved without the totals decodes with none, not totals filled in from the capped
/// lists, and the headline gives the size it knows and asks for a rescan.
    @Test func aStorageReportFromBeforeTheTotalsAsksForARescan() throws {
        let entry = "{\"path\":\"/r/a\",\"name\":\"a\",\"bytes\":300}"
        let twenty = Array(repeating: entry, count: 20).joined(separator: ",")
        let json = "{\"treemap\":[],\"largest\":[\(twenty)],\"stale\":[\(twenty)],"
            + "\"reclaimCandidates\":[\(twenty)],\"totalBytes\":900000000000}"
        let report = try JSONDecoder().decode(StorageLensReport.self, from: Data(json.utf8))
        let headline = LensWorkspaceView.storageReceiptHeadline(report)
        #expect(headline == "\(FileSyncManager.formatBytes(900_000_000_000)) total · rescan for the counts")
        #expect(!headline.contains("20"), "the headline counted the capped lists: \(headline)")
    }

/// The ledger's denominator does not move for Storage, in either state: `countedLenses` gates on
/// `carriesBadge`, and a receipt is not a check that reported.
    @Test func theLedgerIgnoresStorageInEveryState() {
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

/// A never-analyzed Storage reaches the stranded route: it is in no `OrganizePass`, so its Analyze
/// verb comes from `strandedActions`. If Storage gains a pass, this fails rather than leaving a
/// second button. `OverviewCardConsistencyTests.aNeverAnalyzedStorageTakesACardAndNotAFootnote`
/// pins what it draws.
    @Test func aNeverAnalyzedStorageIsStrandedWithNoPassToOfferIt() {
        let sections = subject(FileSyncManager()).overviewModel.sections
        let overview = OrganizeOverview(
            sections: sections, scopeLabel: nil, accent: .blue,
            ledger: OrganizeOverview.Ledger(),
            runnablePasses: Set(OrganizePass.allCases),
            onOpen: { _ in }, onRun: { _ in })

        #expect(sections.first { $0.lens == .storage }?.state == .notScanned)
        #expect(overview.strandedUnscanned.contains { $0.lens == .storage },
                "Storage is not stranded, so the card carrying its Analyze button never draws")
        #expect(!overview.pendingPasses.flatMap(\.lenses).contains(.storage),
                "a pass now claims Storage — its verb belongs on that card, not on the footer line")
        #expect(OrganizePass(producing: .storage) == nil,
                "Storage gained a pass; `offersPassRun` will now mint a run button beside the storage-specific one")
    }

/// Restructure's card summarises its backlog rather than sampling it: the first three findings of
/// an unsorted list can be one subtree three times. `StructureBacklogTallyTests` pins the line.
    @Test func restructureSummarisesItsBacklogRatherThanSamplingIt() throws {
        let model = try Self.overviewModelCode()
        #expect(model.contains("StructureBacklogTally(scoped).breakdown"),
                "the Restructure arm does not build a breakdown — its card has nothing to summarise")
// `body(of:)` strips comments and `\\.headline` appears nowhere else here, so this needle is
// exactly the sampling expression.
        #expect(!model.contains("\\.headline"),
                "the three-of-fifty-three sample is back")
        Self.expectTheRowDrawingArmsStillDraw(model)
    }

/// The monospaced `examples` slot holds identifiers, so Renames' and Restructure's whole-list
/// summaries go in the blurb. What each says is pinned by the two tally suites.
    @Test func noLensPutsProseInTheExampleSlot() throws {
        let model = try Self.overviewModelCode()
// Keyed on the composition, not the sentence, which is copy that may be reworded.
        #expect(model.contains("renameParts.joined"),
                "the Renames arm no longer composes its breakdown into the blurb")
// The tally's own words must not reach the detail slot; both needles are unique to the arm.
        #expect(!model.contains("tally.breakdown"),
                "the rename tally is back in the monospaced slot it was moved out of")
        #expect(model.contains("tally.headerBreakdown"),
                "the blurb dropped the shorter form — the skips are not among the names worth changing")
        Self.expectTheRowDrawingArmsStillDraw(model)
    }

    /// The Overview's Duplicates examples count folders as folders, and versions as versions, as
    /// the card they open does. One rule, read by both: the rule's values, and both readers.
    @Test func theOverviewCountsAFolderGroupInFolders() throws {
        #expect(DuplicateGroupCard.memberCount(2, isDirectory: true) == "2 folders")
        #expect(DuplicateGroupCard.memberCount(1, isDirectory: true) == "1 folder")
        #expect(DuplicateGroupCard.memberCount(2, isDirectory: false) == "2 copies")
        #expect(DuplicateGroupCard.memberCount(1, isDirectory: false) == "1 copy")
        let model = try Self.overviewModelCode()
        #expect(model.contains("DuplicateGroupCard.memberCount($0.copies.count, isDirectory: $0.isDirectory, matchType: $0.matchType)"),
                "the Overview's Duplicates examples no longer read the card's member-count rule")
        // A version group's members are versions, on the card and in the Overview alike.
        #expect(DuplicateGroupCard.memberCount(3, isDirectory: false, matchType: .versions) == "3 versions")
        #expect(DuplicateGroupCard.memberCount(1, isDirectory: false, matchType: .versions) == "1 version")
        #expect(DuplicateGroupCard.memberCount(3, isDirectory: false, matchType: .identical) == "3 copies")
        let card = try SourceText.fileExplorer("DuplicateGroupCard.swift")
        #expect(card.contains("return Self.memberCount(n, isDirectory: group.isDirectory, matchType: group.matchType)"),
                "the card's version subtitle no longer reads the shared rule")
        #expect(!model.contains("copies.count) copies"), "the Overview says copies for folders again")
    }

    private static func overviewModelCode() throws -> String {
        try SourceText.body(of: "var overviewModel: OverviewModel {",
                            in: try SourceText.fileExplorer("LensWorkspaceView.swift"))
    }

    /// Non-vacuity for both guards above: the arms that should still draw rows do, so a `body(of:)`
    /// that silently returned "" (or a renamed declaration) can't satisfy every `!contains`.
    private static func expectTheRowDrawingArmsStillDraw(_ model: String) {
        #expect(model.contains("copies"), "Duplicates stopped drawing its rows too")
        #expect(model.contains("s.fileName"), "To File stopped drawing its rows too")
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
