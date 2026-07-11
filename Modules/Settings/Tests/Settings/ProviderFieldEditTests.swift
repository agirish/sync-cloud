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
}
