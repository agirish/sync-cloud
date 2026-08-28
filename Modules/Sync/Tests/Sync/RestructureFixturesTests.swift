import Testing
import Foundation
@testable import Sync

/// The three in-repo Restructure fixtures, decoded by the real decoder (ROADMAP_V5 §5.8).
///
/// Lifted from the live profile and the 6 Aug reorg log on 2026-08-28 — folder names and counts
/// only, no file names, no content. Their job is to let CI pin every detector's count on a real
/// tree without a machine-pinned suite: a count that moves on a fixture moves for a reason someone
/// has to write down.
@Suite struct RestructureFixturesTests {

    static func profile(named name: String) throws -> FolderProfile {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                 subdirectory: "Fixtures"))
        return try JSONDecoder().decode(FolderProfile.self, from: Data(contentsOf: url))
    }

    // MARK: The flagship family

    /// `Finance/US/Income Tax`, every depth: 17 direct members, 24 distinct child names, and the
    /// one shape finding the live tree produces. Numbers re-verified against the live profile on
    /// 2026-08-28 before lifting.
    @Test func theFlagshipFixtureDecodesAndHoldsTheFamily() throws {
        let profile = try Self.profile(named: "restructure-flagship")
        #expect(profile.folders.count == 235)

        let members = profile.folders.keys
            .filter { $0.hasPrefix("Finance/US/Income Tax/") && $0.filter { $0 == "/" }.count == 3 }
        #expect(members.count == 17)

        let childNames = Set(profile.folders.keys
            .filter { $0.filter { $0 == "/" }.count == 4 }
            .map { ($0 as NSString).lastPathComponent })
        #expect(childNames.count == 24)
    }

    @Test func theShapeDetectorFindsTheFlagshipFamilyInItsFixture() throws {
        let profile = try Self.profile(named: "restructure-flagship")
        let findings = StructureDivergence.findings(in: profile)
        let flagship = try #require(findings.first { $0.family == "Finance/US/Income Tax" })
        #expect(flagship.kind == .shape)
        // Three vouched schemes out of seventeen siblings — the number the detector's own doc
        // calibrates its silence bar against.
        #expect(flagship.schemes.count == 3)
    }

    // MARK: The reference tree

    /// The whole 3,013-folder tree, structural fields only. **This is the doc's "keep this number
    /// current" sentence made executable**: the shipped shape detector returns exactly one finding
    /// on the real tree, and a second one appearing (or that one vanishing) on a re-lift is a
    /// change someone has to explain, not a count to update in passing.
    @Test func theReferenceTreeHoldsExactlyOneShapeFinding() throws {
        let profile = try Self.profile(named: "restructure-reference-tree")
        #expect(profile.folders.count == 3013)

        let findings = StructureDivergence.findings(in: profile)
        #expect(findings.map(\.family) == ["Finance/US/Income Tax"])
    }

    // MARK: The 6 Aug oracle

    /// The two families the 6 Aug run brought into agreement, reconstructed pre-rename, with the
    /// log's four `rename-dir` operations as the expected output. §5.4's proof consumes this: the
    /// mapping `Application → Petition` under H-1B (and the reverse under H-4) must derive exactly
    /// these operations with these `filesCarried`, and no `move-file`.
    @Test func theOracleFixtureDecodesAndItsSourcesCarryTheLoggedCounts() throws {
        let url = try #require(Bundle.module.url(forResource: "restructure-immigration-oracle",
                                                 withExtension: "json", subdirectory: "Fixtures"))
        let object = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)) as? [String: Any])

        let expected = try #require(object["expected"] as? [[String: Any]])
        #expect(expected.count == 4)
        #expect(expected.allSatisfy { $0["action"] as? String == "rename-dir" })

        // The embedded profile decodes with the real decoder, exactly as the fixtures above do.
        let profileData = try JSONSerialization.data(withJSONObject: object["profile"] as Any)
        let profile = try JSONDecoder().decode(FolderProfile.self, from: profileData)
        #expect(profile.folders.count == 157)

        // Every expected rename's source exists pre-rename, is gone post-rename, and carries the
        // logged file count — the invariant the reconstruction (and its two patched counts) exists
        // to hold.
        for op in expected {
            let src = try #require(op["src"] as? String)
            let dst = try #require(op["dst"] as? String)
            let carried = try #require(op["filesCarried"] as? Int)
            let entry = try #require(profile.folders[src], "missing pre-rename source \(src)")
            #expect(entry.fileCount == carried)
            #expect(profile.folders[dst] == nil, "post-rename name \(dst) must not pre-exist")
        }
    }
}
