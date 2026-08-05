import Testing
import SwiftUI
import Foundation
import FileExplorer
import Sync
@testable import SyncCloud

/// The app half of "Find duplicates of this": whether the results on screen already answer the
/// question, and what the handoff does to the window.
///
/// The reason, not just the container. "The workspace switched" is necessary and nowhere near
/// sufficient — a switch that hands over no request lands the user on whatever Duplicates happened
/// to be showing, which is the failure this feature exists to avoid.
@MainActor
@Suite struct DuplicateRevealCoordinatorTests {

    // MARK: The decision

    /// Results scanned from an ancestor of the file already cover it — no rescan.
    @Test func aCompletedScanCoveringTheFileIsUsedAsIs() {
        #expect(DuplicateRevealCoordinator.decide(
            filePath: "/Users/u/Projects/app/a.txt", paneRoot: "/Users/u/Projects",
            scannedRoot: "/Users/u/Projects", isScanning: false) == .revealInExistingResults)
    }

    /// **"A scan has run" is not "this file was looked at".** A completed scan of a sibling folder
    /// says nothing about this file, and revealing against it would answer "no duplicates of X"
    /// from results that never saw X — the most confident possible way to be wrong.
    @Test func aCompletedScanOfSomewhereElseDoesNotCountAsCurrent() {
        #expect(DuplicateRevealCoordinator.decide(
            filePath: "/Users/u/Projects/a.txt", paneRoot: "/Users/u/Projects",
            scannedRoot: "/Users/u/Documents", isScanning: false)
                == .scanThenReveal(root: "/Users/u/Projects"))
    }

    /// The boundary rule, which a plain `hasPrefix` would get wrong: `/Users/u/Projects-old` is not
    /// inside `/Users/u/Projects`.
    @Test func aSiblingSharingAStringPrefixIsNotCovered() {
        #expect(DuplicateRevealCoordinator.decide(
            filePath: "/Users/u/Projects-old/a.txt", paneRoot: "/Users/u/Projects-old",
            scannedRoot: "/Users/u/Projects", isScanning: false)
                == .scanThenReveal(root: "/Users/u/Projects-old"))
    }

    /// No scan has ever run — the common first use. The pane's own folder is the root, which is
    /// what the shipped "Find Duplicates" button scans: a duplicate is relational, so a wider root
    /// finds more than the file's own folder would.
    @Test func noScanAtAllScansThePanesFolder() {
        #expect(DuplicateRevealCoordinator.decide(
            filePath: "/Users/u/Projects/a.txt", paneRoot: "/Users/u/Projects",
            scannedRoot: nil, isScanning: false) == .scanThenReveal(root: "/Users/u/Projects"))
    }

    /// A scan already running is waited for rather than restarted: it is most of the way through
    /// the same work, and `DuplicateReveal.outcome` answers `.waiting` until it publishes.
    @Test func aRunningScanIsWaitedForNotRestarted() {
        #expect(DuplicateRevealCoordinator.decide(
            filePath: "/Users/u/Projects/a.txt", paneRoot: "/Users/u/Projects",
            scannedRoot: nil, isScanning: true) == .waitForRunningScan)
    }

    /// **The fallback.** Nothing structurally guarantees the pane's folder contains the row's file
    /// — a pane can be re-rooted while a menu is open — and a scan that does not contain the file
    /// is one that cannot answer the question. The file's own folder keeps the request answerable.
    @Test func aPaneRootThatDoesNotContainTheFileFallsBackToItsFolder() {
        #expect(DuplicateRevealCoordinator.decide(
            filePath: "/Users/u/Elsewhere/a.txt", paneRoot: "/Users/u/Projects",
            scannedRoot: nil, isScanning: false)
                == .scanThenReveal(root: "/Users/u/Elsewhere"))
    }

    @Test func anEmptyPaneRootFallsBackToTheFilesFolder() {
        #expect(DuplicateRevealCoordinator.decide(
            filePath: "/Users/u/Elsewhere/a.txt", paneRoot: "", scannedRoot: nil,
            isScanning: false) == .scanThenReveal(root: "/Users/u/Elsewhere"))
    }

    // MARK: The handoff

    /// Drives the real entry point and reads back everything it is supposed to move.
    private func handoff(
        node: FileNode, isLeft: Bool = true, manager: FileSyncManager,
        paneRoot: String = "/Users/u/Projects"
    ) -> (workspace: Workspace, request: DuplicateRevealRequest?, scanned: [URL]) {
        var workspace = Workspace.compare
        var request: DuplicateRevealRequest?
        var scanned: [URL] = []
        let coordinator = DuplicateRevealCoordinator(
            syncManager: manager,
            selectedWorkspace: Binding(get: { workspace }, set: { workspace = $0 }),
            revealRequest: Binding(get: { request }, set: { request = $0 }),
            paneRoot: { _ in paneRoot },
            startScan: { scanned.append($0) })
        coordinator.findDuplicates(of: node, isLeft: isLeft)
        return (workspace, request, scanned)
    }

    private static func file(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent,
                 isDirectory: false, children: nil)
    }

    /// **The switch AND the request.** A workspace switch that hands over no request drops the
    /// user on whatever Duplicates was already showing, which reads as the answer to a question
    /// they did not ask.
    @Test func theHandoffSwitchesWorkspaceAndNamesTheFile() {
        let manager = FileSyncManager()
        manager.duplicateScanRoot = "/Users/u/Projects"
        let result = handoff(node: Self.file("/Users/u/Projects/a.txt"), manager: manager)
        #expect(result.workspace == .duplicates)
        #expect(result.request?.path == "/Users/u/Projects/a.txt")
        #expect(result.scanned.isEmpty, "rescanned results that already covered the file")
    }

    /// **The request is set even when a scan has to run first** — that is the common first-use
    /// path. Setting it only on the no-scan branch would make "no scan yet" reveal nothing at all,
    /// silently, in exactly the case a new user meets.
    @Test func aScanIsStartedAndTheRequestStillStands() {
        let result = handoff(node: Self.file("/Users/u/Projects/a.txt"),
                             manager: FileSyncManager())
        #expect(result.workspace == .duplicates)
        #expect(result.request?.path == "/Users/u/Projects/a.txt")
        #expect(result.scanned.map(\.path) == ["/Users/u/Projects"])
    }

    /// A folder never reaches the handoff — a folder overlap group is a different unit.
    @Test func aFolderChangesNothing() {
        let folder = FileNode(id: "/Users/u/Projects", name: "Projects",
                              isDirectory: true, children: [])
        let result = handoff(node: folder, manager: FileSyncManager())
        #expect(result.workspace == .compare, "a folder switched the workspace")
        #expect(result.request == nil)
        #expect(result.scanned.isEmpty)
    }

    /// **The row's own side decides the scan root, not the focused pane.** A right-click does not
    /// necessarily move focus, so aiming at `tidyTargetIsRight`'s pane would scan a different
    /// provider from the one the row is in and answer about the wrong tree.
    @Test func theScanIsAimedAtTheRowsOwnSide() {
        var sides: [Bool] = []
        var workspace = Workspace.compare
        var request: DuplicateRevealRequest?
        let coordinator = DuplicateRevealCoordinator(
            syncManager: FileSyncManager(),
            selectedWorkspace: Binding(get: { workspace }, set: { workspace = $0 }),
            revealRequest: Binding(get: { request }, set: { request = $0 }),
            paneRoot: { isLeft in
                sides.append(isLeft)
                return isLeft ? "/Users/u/Left" : "/Users/u/Right"
            },
            startScan: { _ in })
        coordinator.findDuplicates(of: Self.file("/Users/u/Right/a.txt"), isLeft: false)
        #expect(sides == [false], "the handoff asked the wrong pane for its root")
    }
}
