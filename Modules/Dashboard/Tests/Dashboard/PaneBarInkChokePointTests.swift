import Foundation
import Testing
@testable import Dashboard

/// Every rung on the pane bar colours its glyph through `paneNavChrome`, and nothing else.
/// `PaneNavChrome` applies its own `.foregroundStyle` to the glyph, so a colour set further out (on
/// the `Button`, the label, an enclosing stack) is outranked and silently never arrives. A narrow
/// source scan: it finds one function by brace balancing, fails if it can't, and checks the
/// extracted body looks like the real function before trusting a token's absence from it.
@Suite struct PaneBarInkChokePointTests {

    /// `barItem` is the one place a rung is drawn. Colour belongs in `paneNavChrome(…, ink:)`.
    @Test func testNoRungSetsItsColourOutsideTheChrome() throws {
        let body = try Self.functionBody("private func barItem(")

        // Positive controls first: if the extraction returned something other than `barItem`, the
        // absence assertion below would pass for the wrong reason.
        #expect(body.contains("case .flexibleSpace:"), "the extracted body is not `barItem`")
        #expect(body.contains("paneNavChrome("), "the extracted body draws no rungs")
        #expect(body.count > 1_000, "the extracted body is implausibly short for `barItem`")

        // Code only, so a comment explaining this rule doesn't trip it.
        let stray = DashboardSource.codeOnly(body).components(separatedBy: ".foregroundStyle").count - 1
        #expect(stray == 0, """
                `barItem` sets a foreground style \(stray) time(s). `paneNavChrome` colours the \
                glyph itself and outranks anything set further out, so that colour will not \
                arrive — pass it as `paneNavChrome(…, ink:)` instead.
                """)
    }

    /// The same rule for the overflow menu's entries, the same controls drawn as menu items. A tint
    /// that silently failed here would be invisible to a test rendering the bar.
    @Test func testTheOverflowEntriesDoNotTintEither() throws {
        let body = try Self.functionBody("private func overflowEntry(")
        #expect(body.contains("case .space, .flexibleSpace:"), "the extracted body is not `overflowEntry`")
        #expect(body.count > 500, "the extracted body is implausibly short for `overflowEntry`")
        #expect(!DashboardSource.codeOnly(body).contains(".foregroundStyle"),
                "an overflow entry sets a foreground style — menu items take their colour from the menu, and `role: .destructive` is how a destructive one is marked")
    }

    // MARK: - Extraction

    /// The body of the function whose declaration starts with `signature`, by brace balancing. A
    /// fixed line window would either truncate the long `switch` in `barItem`, hiding what it
    /// missed, or run into the next function and fail on someone else's code.
    static func functionBody(_ signature: String) throws -> String {
        let source = try DashboardSource.read("DashboardViews.swift")
        let start = try #require(source.range(of: signature),
                                 "no function matching \(signature) — it was renamed, and this scan is now checking nothing")
        var depth = 0
        var started = false
        var body = ""
        for ch in source[start.lowerBound...] {
            if ch == "{" { depth += 1; started = true }
            if started { body.append(ch) }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return body }
            }
        }
        Issue.record("unbalanced braces after \(signature) — the extraction ran to end of file")
        return body
    }
}
