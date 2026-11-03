import Testing
import Foundation
@testable import SyncCloud

/// The host's half of Filter by Type (RD70). `ContentView` cannot be mounted in a test, so what it
/// hands the manager is read from the source, as `PaneSearchHostTests` does.
@MainActor
@Suite struct TypeFilterHostTests {

    /// The open folders reach the manager whatever the filter (G3). Guarded on the filter, a filter
    /// turned on from none ran its first pass without the Columns stack, hid an open folder with no
    /// match, and the stack closed past it before the second pass could keep it (GQ).
    @Test func testOpenFoldersAreReportedWithNoFilterOn() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView+TypeFilter.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read ContentView+TypeFilter.swift — this check is vacuous")
        let start = try #require(source.range(of: "func typeFilterOpenFolders(_ pane: PaneContext) -> Set<String> {"),
                                 "`typeFilterOpenFolders` is gone or renamed — re-aim this check")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"), "cannot find the end of `typeFilterOpenFolders`")
        let body = rest[..<end.lowerBound]
        #expect(!body.contains("TypeFilter"), "the open folders are reported only while a filter is on again")
        #expect(body.contains("columnDirectories"), "premise: this is the body that reads the stack")
    }

    /// A linked drill and a linked crumb prune the sibling's stack against its tree before its
    /// type filter (G4), so a folder that filter hides is walked into rather than stopped short of.
    @Test func testMirroringPrunesAgainstTheSiblingsWholeFolder() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacApp/ContentView.swift")
        let source = try #require(try? String(contentsOf: url, encoding: .utf8),
                                  "cannot read ContentView.swift — this check is vacuous")
        for signature in ["func applyColumnNavigation(_ path: PaneBrowsePath, isLeft: Bool) {",
                          "func navigateBothPanes(toCombinedPath combined: String, from isLeft: Bool) {"] {
            let start = try #require(source.range(of: signature), "\(signature) is gone — re-aim this check")
            let rest = source[start.upperBound...]
            let end = try #require(rest.range(of: "\n    }\n"))
            let body = rest[..<end.lowerBound]
            #expect(body.contains("otherIndex: syncManager.mirrorChildrenIndex(isLeft: !isLeft, treeRoot: otherRoot)"),
                    "\(signature) prunes the mirror against the sibling's filtered tree again")
        }
    }
}
