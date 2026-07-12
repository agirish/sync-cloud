import Testing
@testable import Settings

/// Pins the normalization both provider text fields (Location path and name) run before
/// committing. The path field previously trimmed only newlines, so a path pasted with a
/// trailing space was stored verbatim: the validity badge went red and scans returned empty
/// with no visual hint of why.
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

    /// Interior spaces are part of real paths ("My Drive") and names — only the ends trim.
    @Test func testInteriorWhitespaceIsPreserved() {
        #expect(ProviderFieldEdit.normalized("/CloudStorage/GoogleDrive-x/My Drive/Documents")
            == "/CloudStorage/GoogleDrive-x/My Drive/Documents")
    }

    /// Whitespace-only input normalizes to empty — the "clear the override" sentinel both
    /// commit paths rely on.
    @Test func testWhitespaceOnlyNormalizesToEmpty() {
        #expect(ProviderFieldEdit.normalized("  \n\t") == "")
    }

    // MARK: - Unified commit model (item 5.3)
    //
    // Both provider fields (name and Location path) now commit through the same two triggers:
    // Return AND focus-loss. `shouldCommit` is the shared gate both `commitName` and `commitPath`
    // consult, so pinning it here pins that a blur behaves identically to a Return: it writes a
    // real edit and no-ops an unchanged value. There is no field-specific branch — the same rule
    // governs the name and the path, which is exactly the parity 5.3 asked for.

    /// A changed value commits — this is the Return path AND the focus-loss path, since both
    /// triggers route through the same commit function that consults `shouldCommit`.
    @Test func testChangedValueCommits() {
        #expect(ProviderFieldEdit.shouldCommit(draft: "/Users/me/NewRoot", committed: "/Users/me/OldRoot"))
    }

    /// The core no-op guarantee that makes blur-to-commit safe: tabbing/clicking away from a
    /// field you never edited must not write. Identical value in and out → no commit.
    @Test func testUnchangedValueIsANoOp() {
        #expect(!ProviderFieldEdit.shouldCommit(draft: "/Users/me/Root", committed: "/Users/me/Root"))
    }

    /// A blur where the only difference is trailing whitespace normalizes back to the stored
    /// value, so it too is a no-op — the field can lose focus repeatedly without churning writes.
    @Test func testWhitespaceOnlyEditIsANoOp() {
        #expect(!ProviderFieldEdit.shouldCommit(draft: "/Users/me/Root  \n", committed: "/Users/me/Root"))
    }

    /// Same rule governs the name field: an unchanged name blurs without committing…
    @Test func testUnchangedNameIsANoOp() {
        #expect(!ProviderFieldEdit.shouldCommit(draft: "My Drive", committed: "My Drive"))
    }

    /// …and a real rename commits, whether it arrived via Return or focus-loss.
    @Test func testChangedNameCommits() {
        #expect(ProviderFieldEdit.shouldCommit(draft: "Work Drive", committed: "My Drive"))
    }

    /// Clearing a name to empty differs from the current display name, so it commits — that's
    /// how the "empty clears the override" reset flows, and it fires on blur just as on Return.
    @Test func testClearingNameCommits() {
        #expect(ProviderFieldEdit.shouldCommit(draft: "   ", committed: "My Drive"))
    }
}
