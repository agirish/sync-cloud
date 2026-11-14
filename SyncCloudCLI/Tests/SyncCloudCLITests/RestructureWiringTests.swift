import Testing
import ArgumentParser
@testable import SyncCloudCLI

/// `synccloud restructure`'s shell half: registration and the flags' spellings. The behaviour
/// lives in `RestructureReporting` and is tested in Core; this is only what ArgumentParser sees.
@Suite struct RestructureWiringTests {

    @Test func restructureIsARegisteredSubcommand() throws {
        // The parsed TYPE, not merely a parse: a bare `restructure` could parse as the default
        // subcommand's positional, so a deleted registration would stay green.
        let parsed = try SyncCloudCommand.parseAsRoot(["restructure"])
        #expect(parsed is Restructure)
    }

    @Test func theDocumentedSpellingsParse() throws {
        #expect(throws: Never.self) {
            _ = try SyncCloudCommand.parseAsRoot(["restructure", "--json"])
        }
        #expect(throws: Never.self) {
            _ = try SyncCloudCommand.parseAsRoot(["restructure", "--json",
                                                  "--profiles-dir", "/tmp/x"])
        }
    }

    /// Report-only is a public promise: the flags that would skip the person-reads-the-manifest
    /// invariants must not parse.
    @Test func applyAndPlanDoNotParse() {
        #expect(throws: (any Error).self) {
            _ = try SyncCloudCommand.parseAsRoot(["restructure", "--apply"])
        }
        #expect(throws: (any Error).self) {
            _ = try SyncCloudCommand.parseAsRoot(["restructure", "--plan"])
        }
    }
}
