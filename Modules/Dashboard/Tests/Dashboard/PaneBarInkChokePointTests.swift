import Foundation
import Testing
@testable import Dashboard

/// **Every rung on the pane bar colours its glyph through `paneNavChrome`, and nothing else.**
///
/// This exists because the same mistake shipped twice in this one function inside two days, and
/// both times it was silent. `PaneNavChrome` applies its own `.foregroundStyle` directly to the
/// glyph, so a colour set anywhere further out — on the `Button`, on the label, on an enclosing
/// stack — is outranked and never arrives. Nothing fails: no build error, no layout change, no
/// accessibility difference. The glyph simply stays the colour it already was.
///
/// The two instances were the Delete rung (a red trash that painted no red pixels) and the Search
/// rung (a live-query tint that painted none either, and turned out to be guarding an unreachable
/// state). Both were caught by counting pixels, one control at a time. This catches the *shape*, so
/// the third one fails at the point it is written rather than whenever someone thinks to render it.
///
/// A source scan, deliberately, and a narrow one: it reads a single function and asserts a single
/// token is absent from it. The guards that make that honest are here rather than assumed — it
/// locates the function by brace balancing, fails if it cannot find it, and checks that the body it
/// extracted contains what a real `barItem` must contain before drawing any conclusion from what it
/// does not contain.
@Suite struct PaneBarInkChokePointTests {

    /// `barItem` is the one place a rung is drawn. Colour belongs in `paneNavChrome(…, ink:)`.
    @Test func testNoRungSetsItsColourOutsideTheChrome() throws {
        let body = try Self.functionBody("private func barItem(")

        // The positive control FIRST: if the extraction silently returned something that is not
        // `barItem`, the absence assertion below would pass for the wrong reason forever.
        #expect(body.contains("case .flexibleSpace:"), "the extracted body is not `barItem`")
        #expect(body.contains("paneNavChrome("), "the extracted body draws no rungs")
        #expect(body.count > 1_000, "the extracted body is implausibly short for `barItem`")

        // CODE only. The first draft counted the token in prose too and fired on the comment that
        // explains this very rule — a guard that cannot survive being documented is not a guard.
        let stray = Self.codeOnly(body).components(separatedBy: ".foregroundStyle").count - 1
        #expect(stray == 0, """
                `barItem` sets a foreground style \(stray) time(s). `paneNavChrome` colours the \
                glyph itself and outranks anything set further out, so that colour will not \
                arrive — pass it as `paneNavChrome(…, ink:)` instead.
                """)
    }

    /// The same rule for the overflow menu's entries, which are the same controls drawn as menu
    /// items — and, for every bar arranged before a control shipped, the ONLY place that control
    /// appears. A tint that silently failed here would be invisible to a test rendering the bar.
    @Test func testTheOverflowEntriesDoNotTintEither() throws {
        let body = try Self.functionBody("private func overflowEntry(")
        #expect(body.contains("case .space, .flexibleSpace:"), "the extracted body is not `overflowEntry`")
        #expect(body.count > 500, "the extracted body is implausibly short for `overflowEntry`")
        #expect(!Self.codeOnly(body).contains(".foregroundStyle"),
                "an overflow entry sets a foreground style — menu items take their colour from the menu, and `role: .destructive` is how a destructive one is marked")
    }

    /// `source` with `//` comments removed, so prose about a token is not mistaken for a use of it.
    ///
    /// Truncating at `//` would also cut a string literal containing one (a URL). That is acceptable
    /// here and worth naming: this is used only to decide whether a token is ABSENT, and the failure
    /// direction of over-truncating is a missed occurrence on a line that both contains a `//` inside
    /// a string and sets a foreground style after it. No line in this file does; if one ever does,
    /// the positive controls above still prove the body was extracted, and the cost is one silent
    /// case rather than a false alarm on every comment.
    static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }

    // MARK: - Extraction

    /// The body of the function whose declaration starts with `signature`, by brace balancing.
    ///
    /// Balanced rather than line-counted: `barItem` is a long `switch` with nested closures, and a
    /// fixed window would either truncate it (making an absence assertion vacuous over the part it
    /// missed) or run past its end into the next function (making it fail on someone else's code).
    static func functionBody(_ signature: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)                 // …/Tests/Dashboard/<this>.swift
            .deletingLastPathComponent()                          // …/Tests/Dashboard
            .deletingLastPathComponent()                          // …/Tests
            .deletingLastPathComponent()                          // …/Dashboard
            .appendingPathComponent("Sources/Dashboard/DashboardViews.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read DashboardViews.swift — this scan would be vacuous")
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
