import Testing
import Foundation
@testable import Sync

/// The in-repo Restructure fixtures, decoded by the real decoder: the reference tree (the flagship
/// family is cut from it) and the 6 Aug oracle. Lifted from the live
/// profile and a real reorg log: folder names and counts only, no file names, no content. They let
/// CI pin every detector's count on a real tree without a machine-pinned suite, so a count that
/// moves on a fixture moves for a reason someone has to write down.
@Suite struct RestructureFixturesTests {

    static func profile(named name: String) throws -> FolderProfile {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                 subdirectory: "Fixtures"))
        return try JSONDecoder().decode(FolderProfile.self, from: Data(contentsOf: url))
    }

    /// The flagship family, `Finance/US/Income Tax` at every depth: its 235 folders cut from the
    /// reference tree, entry for entry, and decoded by the real decoder.
    static func flagshipProfile() throws -> FolderProfile {
        let url = try #require(Bundle.module.url(forResource: "restructure-reference-tree",
                                                 withExtension: "json", subdirectory: "Fixtures"))
        var tree = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let folders = try #require(tree["folders"] as? [[String: Any]])
        let family = "Finance/US/Income Tax"
        tree["folders"] = folders.filter {
            guard let path = $0["path"] as? String else { return false }
            return path == family || path.hasPrefix(family + "/")
        }
        tree["profileId"] = "fixture-flagship"
        return try JSONDecoder().decode(FolderProfile.self, from: JSONSerialization.data(withJSONObject: tree))
    }

    /// The 6 Aug oracle: the two families the 6 Aug run brought into agreement, reconstructed
    /// pre-rename (`profile`), with the log's four `rename-dir` operations (`expected`).
    static func oracle() throws -> (object: [String: Any], profile: FolderProfile) {
        let url = try #require(Bundle.module.url(forResource: "restructure-immigration-oracle",
                                                 withExtension: "json", subdirectory: "Fixtures"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let profile = try JSONDecoder().decode(
            FolderProfile.self, from: JSONSerialization.data(withJSONObject: try #require(object["profile"])))
        return (object, profile)
    }

    // MARK: The flagship family

    @Test func theShapeDetectorFindsTheFlagshipFamilyInItsFixture() throws {
        let profile = try Self.flagshipProfile()
        let findings = StructureDivergence.findings(in: profile)
        let flagship = try #require(findings.first { $0.family == "Finance/US/Income Tax" })
        #expect(flagship.kind == .shape)
        // Three vouched schemes out of seventeen siblings — the number the detector's own doc
        // calibrates its silence bar against.
        #expect(flagship.schemes.count == 3)
        // On both drop paths the subtitle counts the whole family: 11 vouched + 5 unvouched drift
        // + 1 with no vocabulary at all (`CA State`, 3 files, 0 folders) = 17.
        #expect(flagship.memberCount == 17)
        #expect(flagship.drift.count == 5)
        #expect(flagship.shapeless == ["CA State"])
    }
}
