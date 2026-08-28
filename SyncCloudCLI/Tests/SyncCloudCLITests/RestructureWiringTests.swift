import Testing
import ArgumentParser
@testable import SyncCloudCLI

/// `synccloud restructure`'s shell half: registration and the flags' spellings. The behaviour
/// lives in `RestructureReporting` and is tested in Core; this is only what ArgumentParser sees.
@Suite struct RestructureWiringTests {

    @Test func restructureIsARegisteredSubcommand() throws {
        let command = try SyncCloudCommand.parseAsRoot(["restructure", "--help"])
        // --help throws CleanExit before returning a command, so reaching here at all would be
        // a parse failure; the throw is the pass.
        _ = command
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
