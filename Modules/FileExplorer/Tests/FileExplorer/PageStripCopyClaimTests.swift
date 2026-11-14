import Foundation
import Testing
@testable import FileExplorer

/// The shipped words about the page strip, held against what it draws: no text may say a page
/// carries a dot before it is compared (`PageDiffState.dot` is nil for `.pending`). A prose scan
/// like `BareKeyEquivalentScanTests`, failing loudly on an unreadable file, with a positive control.
@Suite struct PageStripCopyClaimTests {

    /// The repo root, derived from this file's own path.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // …/Modules/FileExplorer/Tests/FileExplorer
        .deletingLastPathComponent()   // …/Modules/FileExplorer/Tests
        .deletingLastPathComponent()   // …/Modules/FileExplorer
        .deletingLastPathComponent()   // …/Modules
        .deletingLastPathComponent()   // …/

    /// Every place the strip is described: in-app Help, the notes, and the Pages site. `MacApp/` is
    /// in no SPM package, so this is the only test that reads it.
    private static let shippedTexts = [
        "MacApp/HelpBook.swift",
        "RELEASE_NOTES.md",
        "docs/releases.html",
        // The two Swift files whose doc comments describe the strip. Not user-facing, but a doc
        // comment is where the next reader learns the rule.
        "Modules/FileExplorer/Sources/FileExplorer/VisualPairModes.swift",
        "Modules/FileExplorer/Sources/FileExplorer/ComparePairViewing.swift",
    ]

    /// The prose anchor each file must still carry, so a rename cannot hollow the scan out.
    private static let anchors = [
        "MacApp/HelpBook.swift": "strip under the panes",
        "RELEASE_NOTES.md": "strip under the panes",
        "docs/releases.html": "strip under the panes",
        "Modules/FileExplorer/Sources/FileExplorer/VisualPairModes.swift": "struct PageStrip",
        "Modules/FileExplorer/Sources/FileExplorer/ComparePairViewing.swift": "enum PageDiffState",
    ]

    private static func read(_ relative: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relative)
        return try #require(try? String(contentsOf: url, encoding: .utf8),
                            "cannot read \(url.path) — this check would be vacuous")
    }

    /// Nothing that describes the strip says a page is marked before it is compared. Narrow on
    /// purpose: "until" makes it a promise about waiting; banning "grey dot" would ban the
    /// sentences saying the strip doesn't draw one.
    @Test(arguments: shippedTexts) func nothingPromisesAPendingDot(_ file: String) throws {
        let text = try Self.read(file).lowercased()
        for claim in ["grey until", "gray until"] {
            #expect(!text.contains(claim),
                    "\(file) promises \"\(claim)\" — `PageDiffState.dot` draws NO dot while pending")
        }
    }

    /// The positive control: without it the test above passes on a file that stopped describing the
    /// strip, or on a path that no longer resolves.
    @Test(arguments: shippedTexts) func eachFileStillDescribesTheStrip(_ file: String) throws {
        let text = try Self.read(file)
        let anchor = try #require(Self.anchors[file], "no anchor recorded for \(file)")
        #expect(text.contains(anchor),
                "\(file) no longer contains \"\(anchor)\" — this suite is scanning the wrong text")
    }

    /// The code side of the same claim, so the prose is pinned to a rule. `ComparePairViewingTests`
    /// owns `dot` in full; this asserts only the half the words promise.
    @Test func aPendingPageDrawsNoDot() {
        #expect(PageDiffState.pending.dot == nil)
        #expect(PageDiffState.same.dot != nil, "positive control: a resolved page does draw one")
    }
}
