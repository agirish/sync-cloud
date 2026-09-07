import Testing
import Foundation
@testable import SyncCloudCLICore
@testable import Sync

/// `synccloud restructure`'s core: discovery exactly where the app looks, a stable JSON format,
/// and failures that say what the lens would show (ROADMAP_V5 §13).
@Suite struct RestructureReportingTests {

    /// A profiles directory holding one active profile with one backlog family — enough for
    /// every detector path this command exercises without touching the machine's real survey.
    private func makeProfilesDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-restructure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("t"),
                                                withIntermediateDirectories: true)
        try Data("""
            { "schemaVersion": 1, "activeProfileId": "t" }
            """.utf8).write(to: dir.appendingPathComponent("profiles.json"))
        try Data("""
            {
              "schemaVersion": 1, "profileId": "t", "root": "~/Fixture",
              "folders": [
                { "path": "Dental", "fileCount": 0, "subfolderCount": 3, "anchors": [], "axes": {} },
                { "path": "Dental/2023", "fileCount": 0, "subfolderCount": 1, "anchors": [], "axes": {} },
                { "path": "Dental/2023/Claims", "fileCount": 4, "subfolderCount": 0, "anchors": [], "axes": {} },
                { "path": "Dental/2024", "fileCount": 0, "subfolderCount": 1, "anchors": [], "axes": {} },
                { "path": "Dental/2024/Claims", "fileCount": 2, "subfolderCount": 0, "anchors": [], "axes": {} },
                { "path": "Dental/2025", "fileCount": 2, "subfolderCount": 0, "anchors": [], "axes": {} },
                { "path": "Empty", "fileCount": 0, "subfolderCount": 0, "anchors": [], "axes": {} }
              ]
            }
            """.utf8).write(to: dir.appendingPathComponent("t/folder-profile.json"))
        return dir
    }

    @Test func theReportReadsTheActiveProfileWhereTheAppWould() throws {
        let output = try RestructureReporting.report(
            profilesDirectory: makeProfilesDirectory())
        #expect(output.profileId == "t")
        #expect(output.folderCount == 7)
        let backlog = try #require(output.findings.first { $0.kind == "backlog" })
        #expect(backlog.subject == "Dental/2025")
        #expect(backlog.scaffold == ["Claims"])
        #expect(backlog.looseFiles == 2)
        #expect(output.crowding.empty == ["Empty"])
    }

    @Test func aMissingIndexAndAMissingProfileFailDifferently() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-restructure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: RestructureReporting.Failure.noActiveProfile(directory: empty.path)) {
            try RestructureReporting.report(profilesDirectory: empty)
        }

        let dir = try makeProfilesDirectory()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("t/folder-profile.json"))
        #expect(throws: RestructureReporting.Failure.unreadableProfile(id: "t",
                                                                       directory: dir.path)) {
            try RestructureReporting.report(profilesDirectory: dir)
        }
    }

    /// The JSON format is a public surface: scripts parse it, so this test IS the format. A key
    /// that disappears from here disappeared from someone's pipeline.
    @Test func theJSONFormatIsStableAndSorted() throws {
        let output = try RestructureReporting.report(profilesDirectory: makeProfilesDirectory())
        let json = try RestructureReporting.renderJSON(output)
        #expect(json.contains("\"schemaVersion\" : 1"))
        #expect(json.contains("\"kind\" : \"backlog\""))
        #expect(json.contains("\"subject\" : \"Dental/2025\""))
        #expect(json.contains("\"crowding\""))
        // Round-trips through its own Codable, so a consumer can decode what we encode.
        let decoded = try JSONDecoder().decode(RestructureReporting.Output.self,
                                               from: Data(json.utf8))
        #expect(decoded == output)
    }

    @Test func theTextRenderingSummarisesWithoutDumpingPaths() throws {
        let output = try RestructureReporting.report(profilesDirectory: makeProfilesDirectory())
        let text = RestructureReporting.renderText(output)
        #expect(text.contains("[backlog] Dental/2025"))
        #expect(text.contains("scaffold Claims"))
        #expect(text.contains("1 empty"))
        #expect(!text.contains("Empty\n"), "the text summary counts crowding, --json lists it")
    }

    @Test func aTreeThatAgreesWithItselfSaysSoInsteadOfPrintingNothing() throws {
        let profile = FolderProfile(profileId: "quiet", root: "/r",
                                    folders: ["A": FolderProfileEntry(
                                        path: "A", role: nil, naming: nil, anchors: [],
                                        acceptsNewFiles: nil, fileCount: 3, subfolderCount: 2,
                                        axes: [:])],
                                    personTokens: [])
        let output = RestructureReporting.output(for: profile, id: "quiet")
        let text = RestructureReporting.renderText(output)
        #expect(text.contains("agrees with itself"))
    }

    /// Every `Detail` case flattens into the DTO — a new detector whose payload silently drops
    /// to bare kind/subject would pass every other test here.
    @Test func everyDetailCaseSurvivesTheFlattening() {
        let cases: [(StructureFinding.Detail, (RestructureReporting.Output.Finding) -> Bool)] = [
            (.backlog(scaffold: ["Claims"], looseFiles: 2), { $0.scaffold == ["Claims"] && $0.looseFiles == 2 }),
            (.shadowAxis(target: "2023", targetExists: true), { $0.target == "2023" && $0.targetExists == true }),
            (.echoName(counterpart: "A/B", relation: .sibling), { $0.counterpart == "A/B" && $0.relation == "sibling" }),
            (.echoName(counterpart: "A", relation: .parentChild), { $0.relation == "parentChild" }),
            (.mirroredInbox(destination: "A/B"), { $0.destination == "A/B" }),
            (.looseAboveSeries(looseFiles: 5, seriesFolders: 3), { $0.looseFiles == 5 && $0.seriesFolders == 3 }),
            (.looseBesideContainer(container: "A/B"), { $0.container == "A/B" }),
            (.duplicatedTaxonomy(counterpart: "A/B", matchedDocuments: 5),
             { $0.counterpart == "A/B" && $0.matchedDocuments == 5 }),
        ]
        for (detail, check) in cases {
            let finding = StructureFinding(kind: .ask, family: "F", subject: "F/S",
                                           detail: detail)
            #expect(check(RestructureReporting.finding(for: finding)),
                    "detail \(detail) did not survive flattening")
        }
    }
    /// The human formatter's branch order is a claim about meaning: duplicatedTaxonomy also
    /// carries a counterpart, and the bare-counterpart branch would print it as "echoes B" —
    /// the wrong claim, minus its evidence count.
    @Test func aDuplicatedTaxonomyRowSaysAlsoInNotEchoes() {
        let finding = StructureFinding(
            kind: .duplicatedTaxonomy, family: "Archive",
            subject: "Archive/Forms",
            detail: .duplicatedTaxonomy(counterpart: "Work/Acme/Forms", matchedDocuments: 5))
        let suffix = RestructureReporting.detailSuffix(RestructureReporting.finding(for: finding))
        #expect(suffix == " — 5 documents also in Work/Acme/Forms")
        #expect(!suffix.contains("echoes"))
    }
}
