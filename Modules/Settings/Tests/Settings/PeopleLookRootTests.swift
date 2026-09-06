import Foundation
import Sync
import Testing
@testable import Settings

/// Where "Look for Names" reads from — and that it no longer depends on a scan having run.
///
/// The button was offered whenever a profile was loaded, which is every launch, but the root it
/// read was the last Filing scan's provider root, which exists only after a To File scan in the
/// same session. `look()` bailed silently on the nil, so the button did nothing for anyone who
/// opened Settings before running a scan — the user's report was "no longer seems to work", and
/// `~/sync-cloud.log` had one `People: read` line from the day the feature shipped and none in
/// the four weeks since. The profile's own root is the tree its folder paths are relative to,
/// and it is there whenever the profile is.
struct PeopleLookRootTests {

    /// The recorded root, tilde-expanded — the same resolution every other reader of the profile
    /// uses, so the folders the scanner appends to it are the folders the survey walked.
    ///
    /// Measured while mutation-testing this: `URL(fileURLWithPath:)` expands a leading `~` on its
    /// own, so dropping the explicit `expandingTildeInPath` is an equivalent program and this
    /// test cannot tell the two apart. It is kept for consistency with the other readers, not
    /// because the URL needs it. What the test DOES catch is a root that ignores the profile —
    /// the home directory, say — which fails both expectations.
    @Test func theLookRootIsTheProfilesOwnTree() {
        let profile = FolderProfile(profileId: "t", root: "~/Documents", folders: [:],
                                    personTokens: [])
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(PeopleList.lookRoot(for: profile).path == home + "/Documents")

        let absolute = FolderProfile(profileId: "t", root: "/Volumes/Archive/Docs", folders: [:],
                                     personTokens: [])
        #expect(PeopleList.lookRoot(for: absolute).path == "/Volumes/Archive/Docs")
    }

    /// The regression, pinned at the source: `PeopleList` takes no provider root from the engine
    /// and `look()` derives its root from the profile it already has. A behavioural test cannot
    /// press the button — `look()` is private and `@State` has no storage off-screen — so this
    /// asserts the shape that made the button dead is gone, bounded to the one declaration and
    /// failing loudly if that declaration moves.
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
        // And the caller of `filingLastProviderRoot` that fed it is gone from the tab.
        let tab = try #require(source.range(of: "struct PeopleSettingsTab: View {"))
        let tabDeclaration = String(source[tab.upperBound...].prefix(1_500))
        #expect(!tabDeclaration.contains("filingLastProviderRoot"),
                "the tab hands the last scan's root to the list again")
    }
}
