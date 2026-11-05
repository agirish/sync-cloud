import SwiftUI
import Sync
import Events
import FileExplorer

/// "Find duplicates of this" on a pane row: the workspace switch, the decision about whether the
/// results on screen already answer the question, and the reveal request handed to the Duplicates
/// lens. Kept out of `ContentView` so the decision can be tested; what the lens does with the
/// request is `DuplicateReveal`'s, in FileExplorer.
///
/// Stateless: it holds bindings and closures over `ContentView`'s state, so a fresh one per use
/// is fine.
@MainActor
struct DuplicateRevealCoordinator {
    let syncManager: FileSyncManager
    @Binding var selectedWorkspace: Workspace
    /// See ``DuplicateReviewCoordinator/organizeLens`` — a lens inside Organize needs both halves.
    @Binding var organizeLens: OrganizeLens?
    /// The request the Duplicates lens is showing. App-level state so it survives the workspace
    /// switch that is about to happen.
    @Binding var revealRequest: DuplicateRevealRequest?

    /// The absolute, tilde-expanded folder the pane on this side is showing, the root a scan would
    /// walk. A closure because the live `@AppStorage`/`@State` it reads can change between building
    /// the coordinator and calling it.
    let paneRoot: @MainActor (_ isLeft: Bool) -> String
    /// Starts a Find Duplicates scan of `root`.
    let startScan: @MainActor (URL) -> Void

    /// What to do about a request for `filePath`, given what the Duplicates lens is holding.
    enum Decision: Equatable {
        /// The results on screen already cover this file — reveal against them, no scan.
        case revealInExistingResults
        /// A scan is already running. Hand over the request and let it resolve when the results
        /// land, rather than restarting a scan that is most of the way through the same work.
        case waitForRunningScan
        /// Nothing current covers this file — scan `root` first.
        case scanThenReveal(root: String)
    }

    /// The decision, as a pure function of the scan state.
    ///
    /// "Current" means the existing results cover this file, not that a scan has ever run: a
    /// completed scan of `~/Documents` would answer "no duplicates" for a file in `~/Projects`
    /// without having looked. `duplicateScanRoot` is published only on completion, so containment
    /// under it (`PathBoundary`) is the test.
    ///
    /// The scan root is `paneRoot` when it contains the file, since a wider root finds more, and
    /// otherwise the file's own folder: a pane can be re-rooted while a menu is open, and a root
    /// that doesn't contain the file can't answer.
    static func decide(
        filePath: String,
        paneRoot: String,
        scannedRoot: String?,
        isScanning: Bool
    ) -> Decision {
        if isScanning { return .waitForRunningScan }
        if let scannedRoot, PathBoundary.contains(filePath, under: scannedRoot) {
            return .revealInExistingResults
        }
        if !paneRoot.isEmpty, PathBoundary.contains(filePath, under: paneRoot) {
            return .scanThenReveal(root: paneRoot)
        }
        return .scanThenReveal(root: (filePath as NSString).deletingLastPathComponent)
    }

    /// Opens Duplicates on this file and reveals its group, scanning first when nothing current
    /// covers it. The request is set for every decision, a scan included: the lens resolves it when
    /// results land, so without it a first use, with no scan yet, would reveal nothing.
    func findDuplicates(of node: FileNode, isLeft: Bool) {
        guard !node.isDirectory else { return }
        apply(decision: Self.decide(filePath: node.id,
                                    paneRoot: paneRoot(isLeft),
                                    scannedRoot: syncManager.duplicateScanRoot,
                                    isScanning: syncManager.isFindingDuplicates),
              path: node.id)
    }

    /// The same ask from a surface that has only a path: the `notScanned` empty state's recovery
    /// button, whose original request is already consumed. The root is the file's own folder, which
    /// is what the button promises to scan and always contains the file.
    func findDuplicates(ofPath path: String) {
        apply(decision: Self.decide(filePath: path,
                                    paneRoot: (path as NSString).deletingLastPathComponent,
                                    scannedRoot: syncManager.duplicateScanRoot,
                                    isScanning: syncManager.isFindingDuplicates),
              path: path)
    }

    private func apply(decision: Decision, path: String) {
        Logger.shared.info("User requested duplicates of \(path) — \(decision)")
        selectedWorkspace = .filing
        organizeLens = .duplicates
        if case .scanThenReveal(let root) = decision, !root.isEmpty {
            // The request records the completed-scan root as it is now, so the lens waits until
            // the scan started below publishes. `isScanning` alone isn't enough: it flips only
            // after the scan task awaits the previous one, and a resolve in that window would
            // answer from the old results and consume the request.
            revealRequest = DuplicateRevealRequest(
                path: path,
                awaitsScanReplacing: .init(root: syncManager.duplicateScanRoot))
            startScan(URL(fileURLWithPath: root))
        } else {
            revealRequest = DuplicateRevealRequest(path: path)
        }
    }
}
