import Foundation
import Sync
import Testing
@testable import Settings

/// Where "Look for Names" reads from: the profile's own root, the tree its folder paths are
/// relative to, which exists whenever the profile does. The last Filing scan's provider root
/// exists only after a To File scan in the same session, so reading it would leave the button
/// silently doing nothing on most launches.
struct PeopleLookRootTests {

    /// The recorded root, tilde-expanded as every other reader of the profile does it, so the
    /// folders the scanner appends are the ones the survey walked. Fails if the root ignores the
    /// profile. `URL(fileURLWithPath:)` expands `~` itself, so dropping `expandingTildeInPath`
    /// passes too.
    @Test func theLookRootIsTheProfilesOwnTree() {
        let profile = FolderProfile(profileId: "t", root: "~/Documents", folders: [:],
                                    personTokens: [])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(PeopleList.lookRoot(for: profile).path == home + "/Documents")

        let absolute = FolderProfile(profileId: "t", root: "/Volumes/Archive/Docs", folders: [:],
                                     personTokens: [])
        #expect(PeopleList.lookRoot(for: absolute).path == "/Volumes/Archive/Docs")
    }

    /// Pinned at the source: `PeopleList` takes no provider root from the engine and `look()`
    /// derives its root from the profile. A test can't press the button (`look()` is private and
    /// `@State` has no storage off-screen), so this scans the one declaration, failing loudly if it
    /// moves.
    @Test func lookForNamesNoLongerWaitsOnAFilingScan() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Settings/SettingsView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read SettingsView.swift — this scan would be vacuous")
        let start = try #require(source.range(of: "struct PeopleList: View {"), "PeopleList is gone")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\nprivate struct PersonRow: View {"),
                               "PersonRow no longer follows PeopleList — the scan's bound is gone")
        let declaration = String(rest[..<end.lowerBound])

        #expect(!declaration.contains("providerRoot"),
                "PeopleList reads a provider root again — that is the scan-dependent value that left the button dead")
        #expect(declaration.contains("Self.lookRoot(for: profile)"),
                "look() no longer resolves its root from the profile")
        // And the tab doesn't feed it `filingLastProviderRoot`.
        let tab = try #require(source.range(of: "struct PeopleSettingsTab: View {"))
        let tabDeclaration = String(source[tab.upperBound...].prefix(1_500))
        #expect(!tabDeclaration.contains("filingLastProviderRoot"),
                "the tab hands the last scan's root to the list again")
    }
}
