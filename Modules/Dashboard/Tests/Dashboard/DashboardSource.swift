import Foundation
import Testing

/// Source text for the scans in this target: this package's own files, or the app's in `MacApp/`,
/// which is in no SPM package. A read fails, rather than letting a scan pass over nothing, when the
/// file can't be read or reads implausibly short.
enum DashboardSource {

    private static let packageDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // …/Modules/Dashboard/Tests/Dashboard
        .deletingLastPathComponent()   // …/Modules/Dashboard/Tests
        .deletingLastPathComponent()   // …/Modules/Dashboard

    /// `Sources/Dashboard/<file>`. `codeOnly` cuts every line at its first `//`, so a comment
    /// quoting a scanned spelling can't satisfy the scan.
    static func read(_ file: String, codeOnly: Bool = false, atLeast minimum: Int = 500) throws -> String {
        let text = try contents(of: packageDir.appendingPathComponent("Sources/Dashboard/\(file)"),
                                atLeast: minimum)
        return codeOnly ? Self.codeOnly(text) : text
    }

    /// `MacApp/<name>`, from the repo root.
    static func app(_ name: String) throws -> String {
        let root = packageDir.deletingLastPathComponent().deletingLastPathComponent()
        return try contents(of: root.appendingPathComponent("MacApp/\(name)"), atLeast: 500)
    }

    /// Every line cut at its first `//`, so prose about a token isn't mistaken for a use of it. It
    /// also cuts a string literal holding `//` (a URL), which could hide a use later on that same
    /// line. Acceptable: the cost is one silent case, where keeping comments would be a false alarm
    /// on every one.
    static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }

    private static func contents(of url: URL, atLeast minimum: Int) throws -> String {
        let text = try #require(try? String(contentsOf: url, encoding: .utf8),
                                "cannot read \(url.path) — the scan would pass vacuously")
        try #require(text.count > minimum, "\(url.lastPathComponent) read as \(text.count) characters — truncated?")
        return text
    }
}
