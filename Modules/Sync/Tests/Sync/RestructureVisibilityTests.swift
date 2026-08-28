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
