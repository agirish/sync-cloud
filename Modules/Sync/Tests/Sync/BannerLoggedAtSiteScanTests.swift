import Foundation
import Testing

/// Every banner marked `.loggedAtSite` has its site's own WARN or ERROR line beside it.
///
/// The mark lowers the banner's copy in the log to INFO, on the promise that the site already
/// wrote the fault at WARN or ERROR with more than the banner says. A mark with no such line
/// would quietly take a fault out of the Activity Log's Warnings. Read from the source because
/// most of these sites are reached only through a race or a refusal no test can stage cheaply.
///
/// "Beside" is the 12 lines above the mark and the 4 below it, which holds every site's line today
/// (the per-item Duplicates reporters log just above their banner; the review
/// coordinator just below). `PaneToolResult` is the one exception: it carries a PDF tool's or
/// Save as PDF's ending, and each tool writes its own line for every ending.
@Suite struct BannerLoggedAtSiteScanTests {
    static let sourceTrees = ["MacApp", "Modules/Sync/Sources", "Modules/FileExplorer/Sources",
                              "Modules/Dashboard/Sources", "Modules/Settings/Sources"]
    static let exempt: Set<String> = [
        "Modules/Sync/Sources/Sync/OperationBanner.swift",      // the enum itself
        "Modules/Sync/Sources/Sync/FileSyncManager.swift",       // the mirror's switch
        "Modules/FileExplorer/Sources/FileExplorer/PaneToolResult.swift",
    ]

    /// The marks in `text` with no WARN or ERROR log call beside them, by line number.
    static func unbacked(_ text: String) -> [Int] {
        let lines = text.components(separatedBy: "\n")
        let logCall = try! NSRegularExpression(pattern: #"(Logger\.shared|logger)\.(warning|error)\("#)
        return lines.indices.compactMap { i in
            guard lines[i].contains("log: .loggedAtSite") else { return nil }
            let window = lines[max(0, i - 12)...min(lines.count - 1, i + 4)].joined(separator: "\n")
            let range = NSRange(window.startIndex..., in: window)
            return logCall.firstMatch(in: window, range: range) == nil ? i + 1 : nil
        }
    }

    @Test func everyLoggedAtSiteBannerHasItsSitesWarningOrError() throws {
        var marks = 0
        var offenders: [String] = []
        for tree in Self.sourceTrees {
            let dir = LogBufferReadScanTests.root.appendingPathComponent(tree)
            let files = (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? [])
                .filter { $0.hasSuffix(".swift") }
            for file in files {
                let path = "\(tree)/\(file)"
                guard !Self.exempt.contains(path),
                      let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) else { continue }
                marks += text.components(separatedBy: "log: .loggedAtSite").count - 1
                offenders += Self.unbacked(text).map { "\(path):\($0)" }
            }
        }
        #expect(marks >= 20, "the scan found \(marks) marks — it has stopped reading the sources")
        #expect(offenders.isEmpty, "\(offenders) mark a banner as logged at its site with no WARN or ERROR line beside it")
    }

    /// Positive control: a mark with its line passes, a bare one doesn't.
    @Test func theScanTellsABackedMarkFromABareOne() {
        #expect(Self.unbacked("Logger.shared.warning(\"x\")\nbanner = .warning(\"x\", log: .loggedAtSite)").isEmpty)
        #expect(Self.unbacked("Logger.shared.info(\"x\")\nbanner = .warning(\"x\", log: .loggedAtSite)") == [2])
    }
}
