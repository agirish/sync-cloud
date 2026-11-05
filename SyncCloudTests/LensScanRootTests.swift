import Testing
import Foundation
import Sync
@testable import SyncCloud

/// The lens scan target follows where the pane is browsing, not just its comparison focus. Column
/// clicks move `PaneBrowsePath` and not the focus (browsing must not re-run the comparison), so
/// reading only the focus root would leave every lens scan and the "Scan '<folder>'" offer stuck at
/// the provider root. `PaneLogic.lensScanRoot` is the join.
@Suite struct LensScanRootTests {

    // MARK: The join

    @Test func browsingWalksTheTargetDownFromTheFocusRoot() {
        let root = "/Users/me/Documents"
        let browse = PaneBrowsePath(relativePath: "Finance/US")
        #expect(PaneLogic.lensScanRoot(focusRootExpanded: root, browsePath: browse)
                == "/Users/me/Documents/Finance/US")
    }

    @Test func atRestTheFocusRootComesBackUntouched() {
        // Trailing slash kept on purpose: the browse join normalizes it away, so this proves the
        // at-rest path returns early. Deleting the `browsePath.isEmpty` guard must fail it.
        let root = "/Users/me/Documents/"
        #expect(PaneLogic.lensScanRoot(focusRootExpanded: root, browsePath: PaneBrowsePath()) == root)
    }

    @Test func aTrailingSlashRootJoinsWithoutDoublingTheSeparator() {
        let root = "/Users/me/Documents/"
        let browse = PaneBrowsePath(relativePath: "Scans")
        #expect(PaneLogic.lensScanRoot(focusRootExpanded: root, browsePath: browse)
                == "/Users/me/Documents/Scans")
    }

    @Test func anEmptyRootNeverInventsATarget() {
        // Providers still resolving report an empty root; joining a browse trail onto it would
        // hand the scan an absolute path fabricated from folder names ("/Finance"). Every scan
        // action guards on `!root.isEmpty`, and this keeps that guard meaningful.
        let browse = PaneBrowsePath(relativePath: "Finance")
        #expect(PaneLogic.lensScanRoot(focusRootExpanded: "", browsePath: browse) == "")
    }

    @Test func theFilesystemRootJoinsToAbsoluteChildren() {
        // "/" normalizes to "" inside the join, so "/" + "A" is "/A", not "//A"; at rest the guard
        // hands "/" back verbatim rather than letting that normalization collapse it to "".
        let browse = PaneBrowsePath(relativePath: "A")
        #expect(PaneLogic.lensScanRoot(focusRootExpanded: "/", browsePath: browse) == "/A")
        #expect(PaneLogic.lensScanRoot(focusRootExpanded: "/", browsePath: PaneBrowsePath()) == "/")
    }

    // MARK: The call site

    /// A rule extracted for testability is one revert from unused: the join stays green even if
    /// `ContentView` reads the bare focus root. As in FileExplorer's `OrganizeScopeCallSiteTests`,
    /// the scan names its file, fails if it can't read it, and bounds the body by its closing brace.
    static let contentViewURL = URL(fileURLWithPath: #filePath)  // …/SyncCloudTests/<this>.swift
        .deletingLastPathComponent()                             // …/SyncCloudTests
        .deletingLastPathComponent()                             // repo root
        .appendingPathComponent("MacApp/ContentView.swift")

    @Test func theScanRootPropertyRoutesThroughTheBrowseAwareJoin() throws {
        let text = try #require(try? String(contentsOf: Self.contentViewURL, encoding: .utf8),
                                "cannot read ContentView.swift — this scan would be vacuous")
        let declaration = "var lensScanRootExpanded: String {"
        let start = try #require(text.range(of: declaration),
                                 "\(declaration) is gone — this scan would be vacuous")
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "no closing brace for \(declaration)")
        let body = String(rest[..<end.lowerBound])
        #expect(body.contains("PaneLogic.lensScanRoot"),
                "lensScanRootExpanded no longer routes through the browse-aware join")
        // The pairing, not just the ingredients: a flipped ternary (the right pane's root with the
        // left pane's browse trail) would pass the pure-function tests, which see one pane at a
        // time. Each ternary is pinned whole, both sides in order.
        #expect(body.contains("lensTargetIsRight ? currentRightPath : currentLeftPath"),
                "the focus root no longer follows the targeted pane (or the ternary flipped)")
        #expect(body.contains(
                    "lensTargetIsRight ? syncManager.rightBrowsePath : syncManager.leftBrowsePath"),
                "the browse path no longer follows the targeted pane (or the ternary flipped)")
        // The presentation gate too, whole with its argument. In Tree the stack is parked state the
        // pane doesn't draw, and joining it would scan a folder the pane isn't showing.
        // `paneDrawsColumns` takes `isLeft`, the negation of `lensTargetIsRight`; without the `!`
        // it would ask the other pane, which no pure-function test above can see.
        #expect(body.contains("paneDrawsColumns(isLeft: !lensTargetIsRight)"),
                "the scan target no longer asks the TARGETED pane whether it draws columns")
        #expect(body.contains(": PaneBrowsePath()"),
                "a Tree pane's scan target no longer drops the parked column stack")
    }
}
