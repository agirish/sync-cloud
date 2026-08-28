import Testing
import ArgumentParser
@testable import SyncCloudCLI

/// `synccloud restructure`'s shell half: registration and the flags' spellings. The behaviour
/// lives in `RestructureReporting` and is tested in Core; this is only what ArgumentParser sees.
@Suite struct RestructureWiringTests {

    @Test func restructureIsARegisteredSubcommand() throws {
        // Assert the parsed TYPE, not merely that parsing succeeds: `--help` parses fine (as a
        // HelpCommand) whether or not the subcommand is registered, and a bare `restructure`
        // could someday parse as a default subcommand's positional — either way a deleted
        // registration stayed green. `is Restructure` is the claim.
        let parsed = try SyncCloudCommand.parseAsRoot(["restructure"])
        #expect(parsed is Restructure)
    }

    @Test func theDocumentedSpellingsParse() throws {
        #expect(throws: Never.self) {
            _ = try SyncCloudCommand.parseAsRoot(["restructure"])
        }
        #expect(throws: Never.self) {
            _ = try SyncCloudCommand.parseAsRoot(["restructure", "--json"])
        }
        #expect(throws: Never.self) {
            _ = try SyncCloudCommand.parseAsRoot(["restructure", "--json",
                                                  "--profiles-dir", "/tmp/x"])
        }
    }

    /// Report-only is a public promise (ROADMAP_V5 §13): the flags that would skip the
    /// person-reads-the-manifest invariants must not parse.
    @Test func applyAndPlanDoNotParse() {
        #expect(throws: (any Error).self) {
            _ = try SyncCloudCommand.parseAsRoot(["restructure", "--apply"])
        }
        #expect(throws: (any Error).self) {
            _ = try SyncCloudCommand.parseAsRoot(["restructure", "--plan"])
        }
    }
}
