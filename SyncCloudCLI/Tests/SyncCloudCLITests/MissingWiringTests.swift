import Testing
import ArgumentParser
@testable import SyncCloudCLI

/// `synccloud missing`'s shell half: registration and the spellings a script would type. The
/// behaviour lives in `MissingReporting` and is tested in Core.
@Suite struct MissingWiringTests {

    @Test func missingIsARegisteredSubcommand() throws {
        // The parsed TYPE: a bare word could parse as the default subcommand's positional, so a
        // deleted registration would stay green.
        #expect(try SyncCloudCommand.parseAsRoot(["missing"]) is Missing)
    }

    @Test func theFolderAndBothFlagsParse() throws {
        let bare = try #require(try SyncCloudCommand.parseAsRoot(["missing"]) as? Missing)
        #expect(bare.folder == nil)
        #expect(!bare.json)
        let full = try #require(try SyncCloudCommand.parseAsRoot(
            ["missing", "/tmp/Documents", "--json", "--profiles-dir", "/tmp/x"]) as? Missing)
        #expect(full.folder == "/tmp/Documents")
        #expect(full.json)
        #expect(full.profilesDir == "/tmp/x")
        #expect(full.year == nil)
        let year = try #require(try SyncCloudCommand.parseAsRoot(["missing", "--year", "2025"]) as? Missing)
        #expect(year.year == 2025)
        // A year is a number; a word is a usage error, not a report for no year.
        #expect(throws: (any Error).self) { _ = try SyncCloudCommand.parseAsRoot(["missing", "--year", "last"]) }
    }

    /// It lists and prints. A flag that fetched or moved anything would be a different tool.
    @Test func nothingThatWouldChangeAFileParses() {
        for flag in ["--fetch", "--apply", "--fix"] {
            #expect(throws: (any Error).self) { _ = try SyncCloudCommand.parseAsRoot(["missing", flag]) }
        }
    }
}
