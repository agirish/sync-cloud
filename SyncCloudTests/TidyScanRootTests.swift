import Testing
import Foundation
import Sync
@testable import SyncCloud

/// The Tidy scan target follows where the pane is **browsing**, not just its comparison focus.
///
/// Column clicks move `PaneBrowsePath` and deliberately not the pane's focus (browsing must not
/// re-run the comparison), but every Tidy scan and the "Scan '<folder>'" offer read only the focus
/// root — so clicking through columns never moved the target, and the offer sat dead at the
/// provider root no matter what folder was selected. `PaneLogic.tidyScanRoot` is the join.
@Suite struct TidyScanRootTests {

    // MARK: The join

    @Test func browsingWalksTheTargetDownFromTheFocusRoot() {
        let root = "/Users/me/Documents"
        let browse = PaneBrowsePath(relativePath: "Finance/US")
        #expect(PaneLogic.tidyScanRoot(focusRootExpanded: root, browsePath: browse)
                == "/Users/me/Documents/Finance/US")
    }

    @Test func atRestTheFocusRootComesBackUntouched() {
        // Trailing slash kept on purpose: the browse join normalizes it away, so this passing
        // proves the at-rest path really returns early rather than round-tripping through the
        // join — deleting the `browsePath.isEmpty` guard fails here.
        let root = "/Users/me/Documents/"
        #expect(PaneLogic.tidyScanRoot(focusRootExpanded: root, browsePath: PaneBrowsePath()) == root)
    }

    @Test func aTrailingSlashRootJoinsWithoutDoublingTheSeparator() {
        let root = "/Users/me/Documents/"
        let browse = PaneBrowsePath(relativePath: "Scans")
        #expect(PaneLogic.tidyScanRoot(focusRootExpanded: root, browsePath: browse)
                == "/Users/me/Documents/Scans")
    }

    @Test func anEmptyRootNeverInventsATarget() {
        // Providers still resolving report an empty root; joining a browse trail onto it would
        // hand the scan an absolute path fabricated from folder names ("/Finance"). Every scan
        // action guards on `!root.isEmpty`, and this keeps that guard meaningful.
        let browse = PaneBrowsePath(relativePath: "Finance")
        #expect(PaneLogic.tidyScanRoot(focusRootExpanded: "", browsePath: browse) == "")
    }

    @Test func theFilesystemRootJoinsToAbsoluteChildren() {
        // "/" normalizes to "" inside the join, which is what makes "/" + "A" come out as "/A"
        // rather than "//A" — and at rest the guard hands "/" back verbatim instead of letting
        // that same normalization collapse it to "".
        let browse = PaneBrowsePath(relativePath: "A")
        #expect(PaneLogic.tidyScanRoot(focusRootExpanded: "/", browsePath: browse) == "/A")
        #expect(PaneLogic.tidyScanRoot(focusRootExpanded: "/", browsePath: PaneBrowsePath()) == "/")
    }

    // MARK: The call site

    /// A rule extracted for testability is one revert away from being unused: the join above stays
    /// green even if `ContentView` goes back to reading the bare focus root. Same conventions as
    /// `OrganizeScopeCallSiteTests` in FileExplorer — the scan names its file and fails if it
    /// cannot be read, and the body is bounded by its closing brace, not a character count.
    static let contentViewURL = URL(fileURLWithPath: #filePath)  // …/SyncCloudTests/<this>.swift
        .deletingLastPathComponent()                             // …/SyncCloudTests
        .deletingLastPathComponent()                             // repo root
        .appendingPathComponent("MacApp/ContentView.swift")

    @Test func theScanRootPropertyRoutesThroughTheBrowseAwareJoin() throws {
        let text = try #require(try? String(contentsOf: Self.contentViewURL, encoding: .utf8),
                                "cannot read ContentView.swift — this scan would be vacuous")
        let declaration = "var tidyScanRootExpanded: String {"
        let start = try #require(text.range(of: declaration),
                                 "\(declaration) is gone — this scan would be vacuous")
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for \(declaration)")
        let body = String(rest[..<end.lowerBound])
        #expect(body.contains("PaneLogic.tidyScanRoot"),
                "tidyScanRootExpanded no longer routes through the browse-aware join")
        // The PAIRING, not just the ingredients: a review found that asserting the two browse
        // paths merely appear leaves a flipped ternary — the right pane's root joined with the
        // LEFT pane's browse trail — passing every test in this file, since the pure-function
        // tests exercise one pane at a time. Pin each ternary whole, both sides in scan order.
        #expect(body.contains("tidyTargetIsRight ? currentRightPath : currentLeftPath"),
                "the focus root no longer follows the targeted pane (or the ternary flipped)")
        #expect(body.contains(
                    "tidyTargetIsRight ? syncManager.rightBrowsePath : syncManager.leftBrowsePath"),
                "the browse path no longer follows the targeted pane (or the ternary flipped)")
    }
}
