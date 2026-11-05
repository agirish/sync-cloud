import Testing
@testable import Settings

/// Pins the normalization both provider text fields (Location path and name) run before
/// committing. Both ends trim all whitespace: a path stored with a pasted trailing space turns the
/// validity badge red and scans come back empty, with no hint why.
@Suite struct ProviderFieldEditTests {

    @Test func testTrailingSpaceIsTrimmed() {
        #expect(ProviderFieldEdit.normalized("/Users/me/Documents ") == "/Users/me/Documents")
    }

    @Test func testTrailingNewlineIsTrimmed() {
        #expect(ProviderFieldEdit.normalized("/Users/me/Documents\n") == "/Users/me/Documents")
    }

    @Test func testLeadingAndTrailingWhitespaceMixIsTrimmed() {
        #expect(ProviderFieldEdit.normalized(" \t/Users/me/Documents\r\n") == "/Users/me/Documents")
    }

    /// Interior spaces are part of real paths ("My Drive") and names; only the ends trim.
    @Test func testInteriorWhitespaceIsPreserved() {
        #expect(ProviderFieldEdit.normalized("/CloudStorage/GoogleDrive-x/My Drive/Documents")
            == "/CloudStorage/GoogleDrive-x/My Drive/Documents")
    }

    /// Whitespace-only input normalizes to empty, the "clear the override" sentinel both commit
    /// paths rely on.
    @Test func testWhitespaceOnlyNormalizesToEmpty() {
        #expect(ProviderFieldEdit.normalized("  \n\t") == "")
    }

    // MARK: - Unified commit model (item 5.3)
    //
    // Both provider fields commit on Return and on focus loss, through `shouldCommit`, the gate
    // `commitName` and `commitPath` share. Pinning it pins that a blur behaves like a Return: it
    // writes a real edit and skips an unchanged value, with the same rule for name and path.

    /// A changed value commits, on Return and on focus loss alike.
    @Test func testChangedValueCommits() {
        #expect(ProviderFieldEdit.shouldCommit(draft: "/Users/me/NewRoot", committed: "/Users/me/OldRoot"))
    }

    /// What makes commit-on-blur safe: leaving a field you never edited doesn't write.
    @Test func testUnchangedValueIsANoOp() {
        #expect(!ProviderFieldEdit.shouldCommit(draft: "/Users/me/Root", committed: "/Users/me/Root"))
    }

    /// An edit that only adds trailing whitespace normalizes back to the stored value, so it
    /// doesn't write either.
    @Test func testWhitespaceOnlyEditIsANoOp() {
        #expect(!ProviderFieldEdit.shouldCommit(draft: "/Users/me/Root  \n", committed: "/Users/me/Root"))
    }

    /// The same rule for the name field: an unchanged name blurs without committing…
    @Test func testUnchangedNameIsANoOp() {
        #expect(!ProviderFieldEdit.shouldCommit(draft: "My Drive", committed: "My Drive"))
    }

    /// …and a real rename commits, whether it arrived via Return or focus-loss.
    @Test func testChangedNameCommits() {
        #expect(ProviderFieldEdit.shouldCommit(draft: "Work Drive", committed: "My Drive"))
    }

    /// Clearing a name differs from the current display name, so it commits: that is how "empty
    /// clears the override" works, on blur as on Return.
    @Test func testClearingNameCommits() {
        #expect(ProviderFieldEdit.shouldCommit(draft: "   ", committed: "My Drive"))
    }
}
