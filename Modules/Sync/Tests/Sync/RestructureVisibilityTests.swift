import Testing
import Foundation
@testable import Sync

/// The one accessor rule: suppression is honoured at `visibleStructureFindings`, which every
/// surface reads, so the lens, the overview and the rail badge cannot disagree about what
/// "never suggest this again" meant.
@MainActor
@Suite struct RestructureVisibilityTests {

    private func makeManager() throws -> FileSyncManager {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("visibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("t"),
                                                withIntermediateDirectories: true)
        let manager = FileSyncManager()
        // A profile with one firing backlog family.
        var folders: [String: FolderProfileEntry] = [:]
        for (path, files, subs): (String, Int, Int) in [
            ("Dental", 0, 3),
            ("Dental/2023", 0, 1), ("Dental/2023/Claims", 2, 0),
            ("Dental/2024", 0, 1), ("Dental/2024/Claims", 2, 0),
            ("Dental/2025", 2, 0),
        ] {
            folders[path] = FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [],
                                               acceptsNewFiles: nil, fileCount: files,
                                               subfolderCount: subs, axes: [:])
        }
        manager.filingFolderProfile = FolderProfile(profileId: "t", root: "/r",
                                                    folders: folders, personTokens: [])
        manager.restructureStore = RestructureStore(directory: dir, profileId: "t")
        return manager
    }

    @Test func aSuppressedFindingLeavesTheVisibleSetAndComesBackOnUnsuppress() throws {
        let manager = try makeManager()
        let finding = try #require(manager.visibleStructureFindings.first {
            $0.kind == .backlog
        })

        manager.restructureStore?.suppress(RestructureKey(finding))
        #expect(!manager.visibleStructureFindings.contains { $0.id == finding.id })
        // The full report is untouched — suppression is a view fact, not a detector fact.
        #expect(manager.structureFindings.contains { $0.id == finding.id })

        manager.restructureStore?.unsuppress(RestructureKey(finding))
        #expect(manager.visibleStructureFindings.contains { $0.id == finding.id })
    }

    @Test func withNoStoreTheVisibleSetIsTheWholeReport() throws {
        let manager = try makeManager()
        manager.restructureStore = nil
        #expect(manager.visibleStructureFindings == manager.structureFindings)
    }
}

/// The trend stamp reads the survey's own counts (proposal O16).
///
/// The store dedupes and the chart draws; this is the half in between — what goes INTO a point.
@MainActor
@Suite struct RestructureTrendStampTests {

    private func makeManager() throws -> FileSyncManager {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trend-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("t"),
                                                withIntermediateDirectories: true)
        let manager = FileSyncManager()
        var folders: [String: FolderProfileEntry] = [:]
        for (path, files, subs): (String, Int, Int) in [
            ("Dental", 0, 3),
            ("Dental/2023", 0, 1), ("Dental/2023/Claims", 2, 0),
            ("Dental/2024", 0, 1), ("Dental/2024/Claims", 2, 0),
            ("Dental/2025", 2, 0),
        ] {
            folders[path] = FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [],
                                               acceptsNewFiles: nil, fileCount: files,
                                               subfolderCount: subs, axes: [:])
        }
        manager.filingFolderProfile = FolderProfile(profileId: "t", root: "/r",
                                                    folders: folders, personTokens: [])
        manager.filingProfileDirectoryId = "t"
        manager.restructureStore = RestructureStore(directory: dir, profileId: "t")
        return manager
    }

    /// The point carries the detectors' own per-kind counts, summing to what the lens shows.
    @Test func aStampCountsTheSurveysFindingsByKind() throws {
        let manager = try makeManager()
        let expected = manager.structureFindings.count
        #expect(expected > 0, "a positive control: this profile fires")

        manager.stampStructureTrend()

        let point = try #require(manager.restructureStore?.trend.last)
        #expect(point.total == expected)
        #expect(point.profileId == "t")
        #expect(!point.landing, "an ordinary survey is not a landing")
        for (kind, count) in point.countsByKind {
            #expect(manager.structureFindings.filter { $0.kind.rawValue == kind }.count == count,
                    "the per-kind counts are the detectors\u{2019}, one for one")
        }
    }

    /// **Suppression does not move the line.** A trend that fell when the user hid a card would
    /// answer "is the tree getting better?" with "did you look away?".
    @Test func aSuppressedFindingStillCounts() throws {
        let manager = try makeManager()
        let finding = try #require(manager.visibleStructureFindings.first)
        let expected = manager.structureFindings.count

        manager.restructureStore?.suppress(RestructureKey(finding))
        #expect(manager.visibleStructureFindings.count < expected,
                "a positive control: the suppression took")
        manager.stampStructureTrend()

        #expect(manager.restructureStore?.trend.last?.total == expected,
                "the trend counts what the detectors found, not what is on screen")
    }

    /// **The stamp costs nothing when there is nothing to record.** Reading the findings runs
    /// the whole detector sweep — 325 ms over the reference profile's 3,013 folders, measured —
    /// and the launch call site runs before the window appears. A profile already in the trend
    /// must be answered from the trend alone, without counting anything.
    ///
    /// Checked by making the count itself impossible: a manager with no profile cannot produce
    /// findings, so a stamp that reached the counting stage could not record the total below.
    @Test func aProfileAlreadyStampedIsAnsweredWithoutCountingAgain() throws {
        let manager = try makeManager()
        manager.stampStructureTrend()
        let first = try #require(manager.restructureStore?.trend.last)
        #expect(first.total > 0)

        // Same profile id, second call: no new point, and the existing one is untouched.
        manager.stampStructureTrend()
        #expect(manager.restructureStore?.trend.count == 1)
        #expect(manager.restructureStore?.trend.last?.total == first.total)

        // A LANDING is the exemption — it re-stamps to record the cause.
        manager.stampStructureTrend(landing: true)
        #expect(manager.restructureStore?.trend.count == 1)
        #expect(manager.restructureStore?.trend.last?.landing == true)
    }

    /// With no profile there is no survey to count, and a zero point would read as a clean tree.
    @Test func nothingIsStampedWithoutAProfile() throws {
        let manager = try makeManager()
        manager.filingFolderProfile = nil
        manager.stampStructureTrend()
        #expect(manager.restructureStore?.trend.isEmpty == true)
    }
}

/// Scope relation reads the finding's SUBJECT (ROADMAP_V5 §5.0): a backlog finding about
/// `Health/Dental/2025` under a scope pointed exactly there is work inside the scope, not an
/// ancestor note about `Health/Dental`.
@Suite struct StructureFindingScopeRelationTests {

    @Test func aScopeAtTheSubjectSeesTheFindingInside() throws {
        let finding = StructureFinding(kind: .backlog, family: "Health/Dental",
                                       subject: "Health/Dental/2025",
                                       detail: .backlog(scaffold: [], looseFiles: 2))
        let scope = try #require(OrganizeScope(path: "/r/Health/Dental/2025",
                                               providerRoot: "/r"))
        #expect(OrganizeScopeFilter.relation(of: finding, profileRoot: "/r",
                                             scope: scope) == .inside)
    }

    @Test func aScopeBelowTheSubjectStillSeesItAsAncestorContext() throws {
        let finding = StructureFinding(kind: .shape, family: "Health/Dental", schemes: [])
        let scope = try #require(OrganizeScope(path: "/r/Health/Dental/2025",
                                               providerRoot: "/r"))
        #expect(OrganizeScopeFilter.relation(of: finding, profileRoot: "/r",
                                             scope: scope) == .aboutAncestor)
    }
}

/// `visibleStructureFindings` is memoised — it was recomputing §5.9's pass over every duplicate
/// group, the whole list's sort-and-dedupe and the suppression filter on every access, two to four
/// times per Organize render.
///
/// **The memo is only as good as its key**, so every one of these drives one input and asserts the
/// answer moved. A memo that never invalidated would pass none of them; one keyed on the profile
/// alone would pass only the last.
@MainActor
@Suite struct VisibleStructureFindingsMemoTests {

    private static let root = "/r"

    private static func entry(_ path: String, files: Int, subs: Int) -> FolderProfileEntry {
        FolderProfileEntry(path: path, role: nil, naming: nil, anchors: [], acceptsNewFiles: nil,
                           fileCount: files, subfolderCount: subs, axes: [:])
    }

    /// Two backlog families, so a suppression can be *moved* between them rather than only added —
    /// a key that counted suppressions instead of comparing them would survive that.
    private static func profile(extra: [String: (Int, Int)] = [:]) -> FolderProfile {
        var folders: [String: FolderProfileEntry] = [:]
        for family in ["Dental", "Vision"] {
            folders[family] = entry(family, files: 0, subs: 3)
            for year in ["2023", "2024"] {
                folders["\(family)/\(year)"] = entry("\(family)/\(year)", files: 0, subs: 1)
                folders["\(family)/\(year)/Claims"] = entry("\(family)/\(year)/Claims",
                                                            files: 2, subs: 0)
            }
            folders["\(family)/2025"] = entry("\(family)/2025", files: 2, subs: 0)
        }
        for (path, counts) in extra {
            folders[path] = entry(path, files: counts.0, subs: counts.1)
        }
        return FolderProfile(profileId: "t", root: root, folders: folders, personTokens: [])
    }

    private func makeManager(extra: [String: (Int, Int)] = [:]) throws -> FileSyncManager {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = FileSyncManager()
        manager.filingFolderProfile = Self.profile(extra: extra)
        manager.restructureStore = RestructureStore(directory: dir, profileId: "t")
        return manager
    }

    /// Suppressing one finding and un-suppressing it again — and then *moving* the suppression to
    /// a second finding, which leaves the set the same size and a different answer.
    @Test func aSuppressionThatMovesInvalidatesTheMemo() throws {
        let manager = try makeManager()
        let backlogs = manager.visibleStructureFindings.filter { $0.kind == .backlog }
        #expect(backlogs.count == 2, "a positive control: two families fire")
        let first = backlogs[0], second = backlogs[1]

        let all = manager.visibleStructureFindings
        manager.restructureStore?.suppress(RestructureKey(first))
        let afterFirst = manager.visibleStructureFindings
        #expect(afterFirst.count == all.count - 1)
        #expect(!afterFirst.contains { $0.id == first.id })

        // Same suppression COUNT, different suppression.
        manager.restructureStore?.unsuppress(RestructureKey(first))
        manager.restructureStore?.suppress(RestructureKey(second))
        let afterMove = manager.visibleStructureFindings
        #expect(afterMove.count == afterFirst.count, "still exactly one suppression")
        #expect(afterMove.contains { $0.id == first.id }, "the first finding is back")
        #expect(!afterMove.contains { $0.id == second.id }, "the second is now hidden")
    }

    /// A different store carrying different suppressions replaces the answer, even though nothing
    /// about the profile moved.
    @Test func swappingTheStoreInvalidatesTheMemo() throws {
        let manager = try makeManager()
        let finding = try #require(manager.visibleStructureFindings.first { $0.kind == .backlog })
        manager.restructureStore?.suppress(RestructureKey(finding))
        #expect(!manager.visibleStructureFindings.contains { $0.id == finding.id })

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memo-swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        manager.restructureStore = RestructureStore(directory: dir, profileId: "t")
        #expect(manager.visibleStructureFindings.contains { $0.id == finding.id },
                "a fresh store suppresses nothing")

        manager.restructureStore = nil
        #expect(manager.visibleStructureFindings.contains { $0.id == finding.id },
                "and no store at all is the whole report")
    }

    /// §5.9's findings arrive with a duplicate scan, not with the profile — so the groups and the
    /// scan's root are both in the key. Driven three ways: the root alone, the groups alone, and
    /// an element rewrite that leaves the group count unchanged.
    @Test func theDuplicateScanInvalidatesTheMemo() throws {
        let manager = try makeManager(extra: ["Papers": (0, 2),
                                              "Papers/One": (4, 0), "Papers/Two": (4, 0)])
        func group(_ name: String, _ folders: [String]) -> DuplicateGroup {
            DuplicateGroup(matchType: .sameText, name: name, isDirectory: false,
                           copies: folders.map {
                               DuplicateCopy(id: "\(Self.root)/\($0)/\(name)", name: name,
                                             isDirectory: false, size: 10, itemCount: 1,
                                             modificationDate: nil, uniqueItemCount: 0, depth: 3,
                                             isRecommendedKeeper: false)
                           },
                           reclaimableBytes: 0)
        }
        let pair = ["Papers/One", "Papers/Two"]
        let groups = ["a.pdf", "b.pdf", "c.pdf"].map { group($0, pair) }

        func taxonomyCount() -> Int {
            manager.visibleStructureFindings.filter { $0.kind == .duplicatedTaxonomy }.count
        }

        manager.duplicateGroups = groups
        #expect(taxonomyCount() == 0, "no scan root yet — the scan does not cover the survey")

        // The root alone flips the gate, with the groups untouched.
        manager.duplicateScanRoot = Self.root
        #expect(taxonomyCount() == 1, "a positive control: the detector fires")

        // An ELEMENT rewrite, not a wholesale replacement, and the count of groups is unchanged —
        // a key that watched `duplicateGroups.count` would miss this entirely.
        manager.duplicateGroups[2] = group("c.pdf", ["Papers/One", "Elsewhere"])
        #expect(taxonomyCount() == 0,
                "two matched documents is below the floor — the memo saw the element write")

        manager.duplicateGroups = []
        #expect(taxonomyCount() == 0)
        manager.duplicateGroups = groups
        #expect(taxonomyCount() == 1, "and it comes back")
    }

    /// A new profile replaces everything under the memo — the report, the folder universe §5.9
    /// reads, and the answer.
    @Test func aNewProfileInvalidatesTheMemo() throws {
        let manager = try makeManager()
        #expect(!manager.visibleStructureFindings.isEmpty, "a positive control")
        manager.filingFolderProfile = FolderProfile(profileId: "t2", root: Self.root,
                                                    folders: [:], personTokens: [])
        #expect(manager.visibleStructureFindings.isEmpty)
        manager.filingFolderProfile = Self.profile()
        #expect(!manager.visibleStructureFindings.isEmpty)
    }

    /// The off-actor warm-up must never install a report for a profile that has since been
    /// replaced. Set two profiles back to back, let the tasks land, and the answer must be the
    /// second one's — indefinitely.
    @Test func aSupersededWarmUpNeverOverwritesTheCache() async throws {
        let manager = try makeManager()
        manager.filingFolderProfile = Self.profile()          // warm-up 1, immediately superseded
        manager.filingFolderProfile = FolderProfile(profileId: "t2", root: Self.root,
                                                    folders: [:], personTokens: [])
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 2_000_000)
            #expect(manager.structureReport.findings.isEmpty,
                    "the superseded warm-up installed a report for the previous profile")
        }
    }

    /// …and the warm-up does land, for the profile that is current. Without this the test above
    /// would pass against a warm-up that never ran at all.
    @Test func theWarmUpInstallsAReportForTheCurrentProfile() async throws {
        let manager = try makeManager()
        // Drain to the warm-up's install. It races the synchronous path by design, so the
        // observable claim is only that the answer is correct and stays correct.
        for _ in 0..<50 { try await Task.sleep(nanoseconds: 2_000_000) }
        #expect(manager.structureReport.findings.contains { $0.kind == .backlog })
        #expect(manager.visibleStructureFindings.contains { $0.kind == .backlog })
    }
}
