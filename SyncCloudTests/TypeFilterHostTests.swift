import Testing
import Foundation
@testable import SyncCloud

/// The host's half of Filter by Type. `ContentView` cannot be mounted in a test, so what it hands
/// the manager is read from the source, as `PaneSearchHostTests` does.
@MainActor
@Suite struct TypeFilterHostTests {

    /// The open folders reach the manager whatever the filter. Guarded on the filter, a filter
    /// turned on from none would run its first pass without the Columns stack, hide an open folder
    /// with no match, and the stack would close past it before the second pass could keep it.
    @Test func testOpenFoldersAreReportedWithNoFilterOn() throws {
        let source = try macAppFile("ContentView+TypeFilter.swift")
        let start = try #require(source.range(of: "func typeFilterOpenFolders(_ pane: PaneContext) -> Set<String> {"),
                                 "`typeFilterOpenFolders` is gone or renamed — re-aim this check")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"), "cannot find the end of `typeFilterOpenFolders`")
        let body = rest[..<end.lowerBound]
        #expect(!body.contains("TypeFilter"), "the open folders are reported only while a filter is on again")
        #expect(body.contains("columnDirectories"), "premise: this is the body that reads the stack")
    }

    /// A linked drill and a linked crumb prune the sibling's stack against its tree before its
    /// type filter, so a folder that filter hides is walked into rather than stopped short of.
    @Test func testMirroringPrunesAgainstTheSiblingsWholeFolder() throws {
        let source = try macAppFile("ContentView.swift")
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
