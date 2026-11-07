import Testing
@testable import Settings

/// Pins the normalization both provider text fields (Location path and name) run before
/// committing. Both ends trim all whitespace: a path stored with a pasted trailing space turns the
/// validity badge red and scans come back empty, with no hint why.
@Suite struct ProviderFieldEditTests {

    /// Spaces, newlines and a mix trim at both ends. Interior spaces are part of real paths
    /// ("My Drive") and names, so they stay. Whitespace-only input normalizes to empty, the "clear
    /// the override" sentinel both commit paths rely on.
    @Test(arguments: [
        ("/Users/me/Documents ", "/Users/me/Documents"),
        ("/Users/me/Documents\n", "/Users/me/Documents"),
        (" \t/Users/me/Documents\r\n", "/Users/me/Documents"),
        ("/CloudStorage/GoogleDrive-x/My Drive/Documents", "/CloudStorage/GoogleDrive-x/My Drive/Documents"),
        ("  \n\t", ""),
    ])
    func testNormalizedTrimsOnlyTheEnds(input: String, normalized: String) {
        #expect(ProviderFieldEdit.normalized(input) == normalized)
    }

    // MARK: - Unified commit model (item 5.3)
    //
    // Both provider fields commit on Return and on focus loss, through `shouldCommit`, the gate
    // `commitName` and `commitPath` share. Pinning it pins that a blur behaves like a Return: it
    // writes a real edit and skips an unchanged value, with the same rule for name and path.

    /// A changed value commits, on Return and on focus loss alike; leaving a field you never
    /// edited doesn't write, which is what makes commit-on-blur safe. An edit that only adds
    /// trailing whitespace normalizes back to the stored value, so it doesn't write either. The
    /// same rule holds for the name field. Clearing a name differs from the current display name,
    /// so it commits: that is how "empty clears the override" works, on blur as on Return.
    @Test(arguments: [
        ("/Users/me/NewRoot", "/Users/me/OldRoot", true),   // a changed path
        ("/Users/me/Root", "/Users/me/Root", false),        // an unchanged path
        ("/Users/me/Root  \n", "/Users/me/Root", false),    // a whitespace-only edit
        ("My Drive", "My Drive", false),                    // an unchanged name
        ("Work Drive", "My Drive", true),                   // a real rename
        ("   ", "My Drive", true),                          // clearing a name
    ])
    func testShouldCommitOnlyARealEdit(draft: String, committed: String, commits: Bool) {
        #expect(ProviderFieldEdit.shouldCommit(draft: draft, committed: committed) == commits)
    }
}
