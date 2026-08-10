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

    private func subject(_ manager: FileSyncManager) -> TidyView {
        TidyView(syncManager: manager, lens: .filing, providerName: "Projects",
                 scanTargetFolder: "/root", onFindDuplicates: {}, onFindFilingSuggestions: {},
                 providerRoot: "/root")
    }

    private func scanning(_ manager: FileSyncManager) -> Set<OrganizeLens> {
        Set(subject(manager).overviewModel.sections.filter(\.isScanning).map(\.lens))
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
        #expect(scanning(m) == Set(OrganizePass.file.lenses))
    }

    /// The name lifecycle still counts when it is the thing running — the fix widened the condition
    /// rather than swapping one flag for another.
    @Test func aStandaloneNameScanStillMarksNames() {
        let m = FileSyncManager()
        m.isScanningNames = true
        #expect(scanning(m).contains(.names))
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
            #expect(scanning(m) == Set(pass.lenses),
                    "\(pass.rawValue) running marked \(scanning(m)) — expected \(Set(pass.lenses))")
        }
    }

    /// Rules takes no section at all, so it can never be reported as scanning or as unscanned.
    @Test func rulesTakesNoSection() {
        let sections = subject(FileSyncManager()).overviewModel.sections
        #expect(!sections.contains { $0.lens == .rules })
        #expect(sections.count == OrganizeLens.allCases.filter(\.carriesBadge).count)
    }
}
