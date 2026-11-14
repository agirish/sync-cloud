import Testing
import Foundation
@testable import Sync

/// Which file the app means when a pane and the Differences table both hold a selection, so Space
/// never previews one file while the Info inspector shows another.
@Suite struct CurrentSelectionTests {

    // MARK: primaryPanePath

    struct PaneCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let left: Set<String>
        let right: Set<String>
        var singleSource = false
        let expected: String?
    }

    static let paneCases: [PaneCase] = [
        // Both are rarely populated at once, but a swap and a deferred cross-pane clear can both
        // leave them briefly overlapping.
        PaneCase(testDescription: "left wins over right", left: ["/a/zeta"], right: ["/a/alpha"], expected: "/a/zeta"),
        PaneCase(testDescription: "falls back to right when left is empty", left: [], right: ["/a/alpha"], expected: "/a/alpha"),
        // `Set.first` is arbitrary per hash seed, so resolving through it would preview a different
        // file each launch. Enough elements that seed order can't make this pass by chance.
        PaneCase(testDescription: "a multi-selection resolves to the alphabetically first path",
                 left: ["/a/mike", "/a/alpha", "/a/zulu", "/a/bravo", "/a/november"], right: [], expected: "/a/alpha"),
        // The single-source rail hides the right pane, so a selection left behind in it must not
        // surface. Both the rail's Space handler and the Info inspector rely on this.
        PaneCase(testDescription: "single source ignores the hidden right pane",
                 left: [], right: ["/a/alpha"], singleSource: true, expected: nil),
        PaneCase(testDescription: "single source still reads the left pane",
                 left: ["/a/zeta"], right: ["/a/alpha"], singleSource: true, expected: "/a/zeta"),
        PaneCase(testDescription: "no pane selection resolves to nil", left: [], right: [], expected: nil),
    ]

    @Test(arguments: paneCases)
    func primaryPanePath(_ c: PaneCase) {
        #expect(CurrentSelection.primaryPanePath(left: c.left, right: c.right, singleSource: c.singleSource) == c.expected)
    }

    // MARK: quickLookPath — the tie-break

    struct QuickLookCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let lastInteracted: SelectionSurface?
        let panePath: String?
        let differencesPath: String?
        let expected: String?
    }

    static let quickLookCases: [QuickLookCase] = [
        // The user last picked in a pane: Space previews the pane's file, which is also what the
        // Info inspector shows.
        QuickLookCase(testDescription: "the pane wins when it was touched last", lastInteracted: .pane,
                      panePath: "/pane/file.txt", differencesPath: "/diff/other.txt", expected: "/pane/file.txt"),
        // Working in the Differences table with a stale pane selection previews the row.
        QuickLookCase(testDescription: "Differences wins when it was touched last", lastInteracted: .differences,
                      panePath: "/pane/file.txt", differencesPath: "/diff/other.txt", expected: "/diff/other.txt"),
        // A surface can hold the token and be empty, since clearing a selection doesn't hand the
        // token away. Falling through keeps Space working instead of going dead.
        QuickLookCase(testDescription: "an empty Differences token holder falls through to the pane", lastInteracted: .differences,
                      panePath: "/pane/file.txt", differencesPath: nil, expected: "/pane/file.txt"),
        QuickLookCase(testDescription: "an empty pane token holder falls through to Differences", lastInteracted: .pane,
                      panePath: nil, differencesPath: "/diff/other.txt", expected: "/diff/other.txt"),
        // Before the session's first selection there is no token. A fresh window shows the panes,
        // so they are the default, not "preview nothing".
        QuickLookCase(testDescription: "no token yet prefers the panes", lastInteracted: nil,
                      panePath: "/pane/file.txt", differencesPath: "/diff/other.txt", expected: "/pane/file.txt"),
        // Nothing selected anywhere is the only case that previews nothing. Every caller turns it
        // into `.ignored`, which keeps Space available to text fields.
        QuickLookCase(testDescription: "nothing selected, no token", lastInteracted: nil,
                      panePath: nil, differencesPath: nil, expected: nil),
        QuickLookCase(testDescription: "nothing selected, pane token", lastInteracted: .pane,
                      panePath: nil, differencesPath: nil, expected: nil),
        QuickLookCase(testDescription: "nothing selected, Differences token", lastInteracted: .differences,
                      panePath: nil, differencesPath: nil, expected: nil),
    ]

    @Test(arguments: quickLookCases)
    func quickLookPath(_ c: QuickLookCase) {
        #expect(CurrentSelection.quickLookPath(lastInteracted: c.lastInteracted, panePath: c.panePath,
                                               differencesPath: c.differencesPath) == c.expected)
    }

    // MARK: - Following the selection with the panel already open

    struct FollowCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let showing: String?
        let followsPane: Bool
        let panePath: String?
        let expected: PreviewFollow
    }

    static let followCases: [FollowCase] = [
        // An open panel shows the current file, not a snapshot of the one current when Space was pressed.
        FollowCase(testDescription: "an open panel follows the pane selection",
                   showing: "/pane/old.txt", followsPane: true, panePath: "/pane/new.txt", expected: .retarget("/pane/new.txt")),
        // Deselecting leaves nothing to preview. Keeping the last file up is stale, and blanking it
        // leaves a window to dismiss by hand, so it closes, as Finder's does.
        FollowCase(testDescription: "clearing the selection closes the panel",
                   showing: "/pane/old.txt", followsPane: true, panePath: nil, expected: .close),
        // A selection change with no panel open never opens one: a preview nobody asked for is the
        // defect this guards against.
        FollowCase(testDescription: "a closed panel is never opened by a pane selection",
                   showing: nil, followsPane: true, panePath: "/pane/new.txt", expected: .stay),
        FollowCase(testDescription: "a closed panel is never opened by a selection elsewhere",
                   showing: nil, followsPane: false, panePath: "/pane/new.txt", expected: .stay),
        FollowCase(testDescription: "a closed panel stays closed when the pane clears",
                   showing: nil, followsPane: true, panePath: nil, expected: .stay),
        FollowCase(testDescription: "a closed panel stays closed when nothing is selected",
                   showing: nil, followsPane: false, panePath: nil, expected: .stay),
        // A preview a Differences row or the Info inspector put up is not the pane's to move. Both
        // selections can be live at once (why `quickLookPath` exists).
        FollowCase(testDescription: "a panel opened elsewhere is left alone by a pane click",
                   showing: "/diff/row.txt", followsPane: false, panePath: "/pane/new.txt", expected: .stay),
        FollowCase(testDescription: "clearing the pane selection does not close a Differences preview",
                   showing: "/diff/row.txt", followsPane: false, panePath: nil, expected: .stay),
        // Re-selecting the file already showing is not a change; otherwise every republish touching
        // the selection hands the panel the same URL, and `QLPreviewView` restarts its render each time.
        FollowCase(testDescription: "re-selecting the same file is not a move",
                   showing: "/pane/same.txt", followsPane: true, panePath: "/pane/same.txt", expected: .stay),
    ]

    @Test(arguments: followCases)
    func previewFollow(_ c: FollowCase) {
        #expect(CurrentSelection.previewFollow(showing: c.showing, followsPane: c.followsPane, panePath: c.panePath)
                == c.expected)
    }
}
