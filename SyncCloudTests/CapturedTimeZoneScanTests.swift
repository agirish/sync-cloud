import Foundation
import Testing

/// No shipped source may hold a `DateFormatter` that captures the system time zone: one whose
/// `timeZone` is never set keeps the zone of its first format for the life of the process, so a
/// `static let` formatter goes on showing the old zone after a Date & Time change or a flight.
/// Keyed on the constructor, since such formatters can have names that say nothing about
/// formatting. In the app target because no package can see another, and the question is repo-wide.
@Suite struct CapturedTimeZoneScanTests {

    /// Files permitted to construct a bare `DateFormatter`, each for a stated reason. Anything else
    /// should use `Design.ZoneRefreshedFormatter`.
    private static let allowed: [String: String] = [
        "Modules/Design/Sources/Design/ZoneRefreshedFormatter.swift":
            "the shared type itself — this is the one place the rule is implemented",
        "Modules/Events/Sources/Events/Logger.swift":
            "Events is a leaf module that must not depend on Design, and its formatter answers a "
            + "different question (it writes and parses ~/sync-cloud.log). It carries its own "
            + "lock-guarded refresh; see LogTimestampFormatter",
        "Modules/FileExplorer/Sources/FileExplorer/EditorPDFFillSign.swift":
            "builds a FRESH formatter per placed date and sets timeZone explicitly — nothing is "
            + "captured; it needs the short style's own pattern, one set in System Settings included, "
            + "to widen its year (TE192), which a shared formatter cannot hand out",
        "Modules/FileExplorer/Sources/FileExplorer/RestructurePlanSheet.swift":
            "builds a FRESH formatter per call and sets timeZone explicitly — nothing is captured",
        "Modules/Sync/Sources/Sync/FilingArtifactStamp.swift":
            "a computed `static var`, so it builds a fresh formatter per access and sets timeZone",
    ]

    /// Every shipped `.swift` file, from the repo root: `Modules/*/Sources`, `MacApp`, and the CLI.
    /// Tests are excluded: a test may build a control formatter on a fixed zone to compute its
    /// expectations.
    private static func shippedSources() -> [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // …/SyncCloudTests
            .deletingLastPathComponent()      // repo root
        var found: [(String, String)] = []
        for area in ["Modules", "MacApp", "SyncCloudCLI"] {
            let base = root.appendingPathComponent(area)
            guard let walk = FileManager.default.enumerator(at: base,
                                                            includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                // Package sources only — never a package's own Tests, and never .build debris.
                guard !path.contains("/Tests/"), !path.contains("/.build/") else { continue }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                found.append((path, text))
            }
        }
        return found
    }

    /// Whether `source` constructs a bare `DateFormatter`. Matched on the identifier, not the
    /// substring: `ISO8601DateFormatter()` ends with `DateFormatter()` but is fixed to a stated zone
    /// (`SyncHistoryExporter` pins it to UTC), so it has nothing to capture. Allow-listing its file
    /// instead would also cover any real `DateFormatter` that file later grew.
    private static func constructsBareDateFormatter(_ source: String) -> Bool {
        let text = sourceCodeOnly(source)
        var search = text.startIndex..<text.endIndex
        while let hit = text.range(of: "DateFormatter()", range: search) {
            let boundary: Bool
            if hit.lowerBound == text.startIndex {
                boundary = true
            } else {
                let before = text[text.index(before: hit.lowerBound)]
                boundary = !(before.isLetter || before.isNumber || before == "_")
            }
            if boundary { return true }
            search = hit.upperBound..<text.endIndex
        }
        return false
    }

    @Test func noShippedFileBuildsItsOwnDateFormatter() {
        let sources = Self.shippedSources()
        // Positive control on the scan itself: a walk that finds nothing would pass silently.
        #expect(sources.count > 200, "the source walk came back suspiciously small — it is not reading the tree")
        #expect(sources.contains { $0.path == "Modules/Design/Sources/Design/ZoneRefreshedFormatter.swift" },
                "the walk did not reach the one file that is guaranteed to construct a DateFormatter")

        let offenders = sources
            .filter { Self.constructsBareDateFormatter($0.text) }
            .map(\.path)
            .filter { Self.allowed[$0] == nil }
            .sorted()

        #expect(offenders.isEmpty,
                "these files construct their own DateFormatter instead of using Design.ZoneRefreshedFormatter")
        for offender in offenders {
            Issue.record("captured-zone risk: \(offender)")
        }
    }

    /// The allow-list may not rot. Every entry must name a file that still exists and still
    /// constructs a formatter, or the exemption quietly covers whatever takes its place.
    @Test func everyAllowListEntryIsStillEarningIt() {
        let byPath = Dictionary(uniqueKeysWithValues: Self.shippedSources().map { ($0.path, $0.text) })
        for (path, reason) in Self.allowed.sorted(by: { $0.key < $1.key }) {
            guard let text = byPath[path] else {
                Issue.record("allow-listed file no longer exists: \(path) — \(reason)")
                continue
            }
            if !Self.constructsBareDateFormatter(text) {
                Issue.record("allow-listed file no longer constructs a DateFormatter: \(path) — drop the entry")
            }
        }
    }
}
