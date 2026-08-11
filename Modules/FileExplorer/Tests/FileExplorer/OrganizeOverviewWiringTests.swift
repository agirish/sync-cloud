import Testing
import SwiftUI
@testable import Sync
@testable import FileExplorer

/// What `TidyView` actually hands the overview.
///
/// **The gap this fills is the reason two of the five `isScanning` arms were wrong.** The render
/// suite mounts ``OrganizeOverview`` directly and supplies its own sections, so it can assert what
/// the *view* does with a scanning flag and never whether the flag it is given is true. `TidyView`
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
    private func subject(_ manager: FileSyncManager) -> TidyView {
        TidyView(syncManager: manager, lens: .filing, providerName: "Projects",
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
        #expect(subject(m).railCounts.state(.names) == .clean)
        #expect(subject(m).railCounts.state(.renames) == .clean)
    }

    /// **The filing walk marks all three of its lenses**, Names included.
    ///
    /// Names rode `isScanningNames` alone, which is never true on this path: the filing scan reaches
    /// names through `detectRiskyNames`, and that function calls `completeScan` without ever calling
    /// `beginScan` — the name lifecycle is begun only by `scanNames`, which has no caller in the
    /// app at all. So during one walk To File and Renames said "rescanning" and Names sat beside
    /// them showing a stale count in confident bold, from the same republish.
    @Test func theFilingWalkMarksAllThreeOfItsLenses() {
        let m = FileSyncManager()
        m.isSuggestingFiles = true
        // Names is folded into Renames (P10), so its findings have no section of their own —
        // but the walk still covers it, and its scanning claim rides the Renames card.
        #expect(OrganizePass.file.lenses.contains(.names),
                "the walk no longer covers names — the fold's premise is gone")
        #expect(scanning(m) == Set(OrganizePass.file.lenses.filter { !$0.isFoldedIntoRenames }))
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
            let expected = Set(pass.lenses.filter { !$0.isFoldedIntoRenames })
            #expect(scanning(m) == expected,
                    "\(pass.rawValue) running marked \(scanning(m)) — expected \(expected)")
        }
    }

    /// Rules takes no section at all, so it can never be reported as scanning or as unscanned.
    @Test func rulesTakesNoSection() {
        let sections = subject(FileSyncManager()).overviewModel.sections
        #expect(!sections.contains { $0.lens == .rules })
        // Rail items only: the folded Names lens takes no section either (its findings ride
        // the Renames card), so the sections are the badge-carrying RAIL items.
        #expect(sections.count == OrganizeLens.railItems.filter(\.carriesBadge).count)
    }
}
