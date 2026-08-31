import Foundation
import Testing
@testable import FileExplorer

/// What the shipped words promise about the page strip, held against what the strip draws.
///
/// **Three texts described a UI element that does not exist.** Help, the release notes and the
/// published releases page all said the strip "gives every page a dot: grey until it has been
/// compared" — while `PageDiffState.dot` returns nil for `.pending` by documented design, so a page
/// awaiting its comparison carries no dot at all. Nothing failed: prose has no compiler, the three
/// copies drifted from a design that was reversed during the build, and the stale sentence was
/// still shipping in the app's own Help.
///
/// Source-level because the claim lives in prose, in two files no Swift test otherwise reads.
/// Written the way `BareKeyEquivalentScanTests` is: name what is scanned, fail loudly when a file
/// cannot be read, and keep a positive control so a rename cannot hollow the scan out.
@Suite struct PageStripCopyClaimTests {

    /// The repo root, derived from this file's own path.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // …/Modules/FileExplorer/Tests/FileExplorer
        .deletingLastPathComponent()   // …/Modules/FileExplorer/Tests
        .deletingLastPathComponent()   // …/Modules/FileExplorer
        .deletingLastPathComponent()   // …/Modules
        .deletingLastPathComponent()   // …/

    /// Every place the strip is described to a person: the in-app Help, the notes, and the page
    /// GitHub Pages serves. `MacApp/` is in no SPM package, so a sweep from here is the only test
    /// that reads it at all.
    private static let shippedTexts = [
        "MacApp/HelpBook.swift",
        "RELEASE_NOTES.md",
        "docs/releases.html",
        // The two Swift files that DESCRIBE the strip. Not user-facing, and here anyway: the first
        // pass at this fix corrected `PageStrip`'s doc and left the doc on the enum that owns the
        // rule still describing the reversed design, twenty lines above the code that contradicts
        // it. A doc comment is where the next reader learns the rule.
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

    /// The rule: nothing that describes the strip says a page is marked before it is compared.
    /// Prose and doc comments alike — the doc comment is where the next reader learns the rule.
    ///
    /// **"grey until" is the whole pattern, and the narrowness is the point.** All three shipped
    /// texts said "grey until it has been compared", and both stale doc comments said "grey until
    /// its diff lands" / "grey until it has found anything" — the claim is always the word
    /// *until*, because that is what makes it a promise about the waiting state. Banning "grey
    /// dot" outright would also ban the sentences that exist to say a grey dot is exactly what
    /// this strip does NOT draw, which is the rationale a reader most needs kept.
    @Test(arguments: shippedTexts) func nothingPromisesAPendingDot(_ file: String) throws {
        let text = try Self.read(file).lowercased()
        for claim in ["grey until", "gray until"] {
            #expect(!text.contains(claim),
                    "\(file) promises \"\(claim)\" — `PageDiffState.dot` draws NO dot while pending")
        }
    }

    /// The positive control. Without it the test above passes just as well on a file that stopped
    /// describing the strip at all — or on a path that no longer resolves.
    @Test(arguments: shippedTexts) func eachFileStillDescribesTheStrip(_ file: String) throws {
        let text = try Self.read(file)
        let anchor = try #require(Self.anchors[file], "no anchor recorded for \(file)")
        #expect(text.contains(anchor),
                "\(file) no longer contains \"\(anchor)\" — this suite is scanning the wrong text")
    }

    /// The code side of the same claim, so the prose above is pinned to a rule and not to a mood.
    /// `ComparePairViewingTests` owns `dot` in full; this asserts only the half the words promise.
    @Test func aPendingPageDrawsNoDot() {
        #expect(PageDiffState.pending.dot == nil)
        #expect(PageDiffState.same.dot != nil, "positive control: a resolved page does draw one")
    }
}
