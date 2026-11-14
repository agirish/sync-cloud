import Testing
import SwiftUI
import Foundation
import FileExplorer
import Sync
@testable import SyncCloud

/// The app half of "Find duplicates of this": whether the results on screen already answer the
/// question, and what the handoff does to the window. A switch that hands over no request lands
/// the user on whatever Duplicates was showing, so the request is checked too.
@MainActor
@Suite struct DuplicateRevealCoordinatorTests {

    // MARK: The decision

    /// `(file, the pane's root, the root last scanned, a scan running, the decision)`.
    @Test(arguments: [
        // Results scanned from an ancestor of the file already cover it: no rescan.
        ("/Users/u/Projects/app/a.txt", "/Users/u/Projects", "/Users/u/Projects", false,
         DuplicateRevealCoordinator.Decision.revealInExistingResults),
        // "A scan has run" is not "this file was looked at". A completed scan of a sibling folder
        // says nothing about this file, and revealing against it would answer "no duplicates of X"
        // from results that never saw X.
        ("/Users/u/Projects/a.txt", "/Users/u/Projects", "/Users/u/Documents", false,
         .scanThenReveal(root: "/Users/u/Projects")),
        // The boundary rule, which a plain `hasPrefix` would get wrong: `/Users/u/Projects-old` is
        // not inside `/Users/u/Projects`.
        ("/Users/u/Projects-old/a.txt", "/Users/u/Projects-old", "/Users/u/Projects", false,
         .scanThenReveal(root: "/Users/u/Projects-old")),
        // No scan has ever run, the common first use. The pane's own folder is the root, as the
        // "Find Duplicates" button scans: a duplicate is relational, so a wider root finds more
        // than the file's own folder would.
        ("/Users/u/Projects/a.txt", "/Users/u/Projects", nil, false, .scanThenReveal(root: "/Users/u/Projects")),
        // A scan already running is waited for rather than restarted: it is most of the way
        // through the same work, and `DuplicateReveal.outcome` answers `.waiting` until it publishes.
        ("/Users/u/Projects/a.txt", "/Users/u/Projects", nil, true, .waitForRunningScan),
        // The fallback. Nothing guarantees the pane's folder contains the row's file (a pane can be
        // re-rooted while a menu is open), and a scan that doesn't contain the file can't answer.
        // The file's own folder keeps the request answerable; an empty pane root likewise.
        ("/Users/u/Elsewhere/a.txt", "/Users/u/Projects", nil, false, .scanThenReveal(root: "/Users/u/Elsewhere")),
        ("/Users/u/Elsewhere/a.txt", "", nil, false, .scanThenReveal(root: "/Users/u/Elsewhere")),
    ] as [(String, String, String?, Bool, DuplicateRevealCoordinator.Decision)])
    func theDecisionReadsWhatTheResultsOnScreenCover(file: String, paneRoot: String, scannedRoot: String?,
                                                     isScanning: Bool,
                                                     expected: DuplicateRevealCoordinator.Decision) {
        #expect(DuplicateRevealCoordinator.decide(filePath: file, paneRoot: paneRoot,
                                                  scannedRoot: scannedRoot, isScanning: isScanning) == expected)
    }

    // MARK: The handoff

    /// Drives the real entry point, from `node`'s row or, with `path`, the recovery entry that
    /// takes only a path, and reads back everything it is supposed to move.
    private func handoff(
        node: FileNode? = nil, path: String? = nil, isLeft: Bool = true, manager: FileSyncManager,
        paneRoot: @escaping (Bool) -> String = { _ in "/Users/u/Projects" }
    ) -> (workspace: Workspace, lens: OrganizeLens?, request: DuplicateRevealRequest?,
          scanned: [URL]) {
        var workspace = Workspace.compare
        // Starts on a different lens from the one the handoff must select, so a coordinator that
        // set only the workspace fails here instead of passing on a value already correct.
        var lens: OrganizeLens? = .toFile
        var request: DuplicateRevealRequest?
        var scanned: [URL] = []
        let coordinator = DuplicateRevealCoordinator(
            syncManager: manager,
            selectedWorkspace: Binding(get: { workspace }, set: { workspace = $0 }),
            organizeLens: Binding(get: { lens }, set: { lens = $0 }),
            revealRequest: Binding(get: { request }, set: { request = $0 }),
            paneRoot: paneRoot,
            startScan: { scanned.append($0) })
        if let path { coordinator.findDuplicates(ofPath: path) }
        if let node { coordinator.findDuplicates(of: node, isLeft: isLeft) }
        return (workspace, lens, request, scanned)
    }

    /// Both halves of the destination: Duplicates is a lens of Organize, not a workspace.
    private func expectLandsOnDuplicates(_ result: (workspace: Workspace, lens: OrganizeLens?,
                                                    request: DuplicateRevealRequest?, scanned: [URL]),
                                         sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(result.workspace == .filing, sourceLocation: sourceLocation)
        #expect(result.lens == .duplicates, sourceLocation: sourceLocation)
    }

    private static func file(_ path: String) -> FileNode {
        FileNode(id: path, name: (path as NSString).lastPathComponent,
                 isDirectory: false, children: nil)
    }

    /// The switch and the request. A switch that hands over no request drops the user on whatever
    /// Duplicates was already showing, which reads as the answer to a question they didn't ask.
    @Test func theHandoffSwitchesWorkspaceAndNamesTheFile() {
        let manager = FileSyncManager.scratch()
        manager.duplicateScanRoot = "/Users/u/Projects"
        let result = handoff(node: Self.file("/Users/u/Projects/a.txt"), manager: manager)
        expectLandsOnDuplicates(result)
        #expect(result.request?.path == "/Users/u/Projects/a.txt")
        #expect(result.scanned.isEmpty, "rescanned results that already covered the file")
        // Answered from the results on screen, so no snapshot: it would wait for a completion
        // that never comes.
        #expect(result.request?.awaitsScanReplacing == nil)
    }

    /// The request is set even when a scan has to run first, the common first-use path. Setting it
    /// only on the no-scan branch would make "no scan yet" silently reveal nothing, in exactly the
    /// case a new user meets.
    @Test func aScanIsStartedAndTheRequestStillStands() {
        let result = handoff(node: Self.file("/Users/u/Projects/a.txt"),
                             manager: FileSyncManager.scratch())
        expectLandsOnDuplicates(result)
        #expect(result.request?.path == "/Users/u/Projects/a.txt")
        #expect(result.scanned.map(\.path) == ["/Users/u/Projects"])
        // It remembers the completed-scan root as it stood (none here), so the lens waits until
        // the scan started above publishes: `isScanning` flips one hop too late to be the whole
        // answer. See `DuplicateRevealRequest.awaitsScanReplacing`.
        #expect(result.request?.awaitsScanReplacing == .init(root: nil))
    }

    /// The stale root travels on the request when one exists, so `outcome` can tell "my scan has
    /// not landed" from "no scan is running" during the start window.
    @Test func aScanStartingRequestSnapshotsTheStaleRoot() {
        let manager = FileSyncManager.scratch()
        manager.duplicateScanRoot = "/Users/u/Elsewhere"
        let result = handoff(node: Self.file("/Users/u/Projects/a.txt"), manager: manager)
        #expect(result.scanned.map(\.path) == ["/Users/u/Projects"])
        #expect(result.request?.awaitsScanReplacing == .init(root: "/Users/u/Elsewhere"))
    }

    /// The `notScanned` empty state's recovery button: only a path survives to it (its request was
    /// consumed), and its caption promises "scan the folder this file is in". The path entry must
    /// scan exactly that folder. The focused root may not contain the file after a handoff from the
    /// other pane, and the button would loop its own failure.
    @Test func theRecoveryEntryScansTheFilesOwnFolder() {
        let result = handoff(path: "/Users/u/Right/Photos/a.txt", manager: FileSyncManager.scratch(),
                             paneRoot: { _ in "/Users/u/UnrelatedPaneRoot" })
        #expect(result.scanned.map(\.path) == ["/Users/u/Right/Photos"],
                "the caption promises the file's own folder, and only that folder always contains the file")
        #expect(result.request?.path == "/Users/u/Right/Photos/a.txt")
        #expect(result.request?.awaitsScanReplacing != nil)
    }

    /// A folder never reaches the handoff: a folder overlap group is a different unit.
    @Test func aFolderChangesNothing() {
        let folder = FileNode(id: "/Users/u/Projects", name: "Projects",
                              isDirectory: true, children: [])
        let result = handoff(node: folder, manager: FileSyncManager.scratch())
        #expect(result.workspace == .compare, "a folder switched the workspace")
        #expect(result.request == nil)
        #expect(result.scanned.isEmpty)
    }

    /// The row's own side decides the scan root, not the focused pane. A right-click doesn't
    /// necessarily move focus, so aiming at `lensTargetIsRight`'s pane could scan another provider
    /// and answer about the wrong tree.
    @Test func theScanIsAimedAtTheRowsOwnSide() {
        var sides: [Bool] = []
        _ = handoff(node: Self.file("/Users/u/Right/a.txt"), isLeft: false, manager: FileSyncManager.scratch(),
                    paneRoot: { isLeft in
                        sides.append(isLeft)
                        return isLeft ? "/Users/u/Left" : "/Users/u/Right"
                    })
        #expect(sides == [false], "the handoff asked the wrong pane for its root")
    }
}
