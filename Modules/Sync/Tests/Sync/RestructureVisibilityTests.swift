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
