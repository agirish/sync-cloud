import SwiftUI
import Sync
import Events
import FileExplorer

/// "Find duplicates of this" on a pane row: the workspace switch, the decision about whether the
/// results on screen already answer the question, and the reveal request handed to the Duplicates
/// lens.
///
/// Extracted from `ContentView` for the reason `DuplicateReviewCoordinator` was — everything in
/// `ContentView` itself is untestable (`MacApp/` is in no SPM package and its `body` needs a
/// window), and this is the half of the handoff that decides something. What the *lens* then does
/// with the request is decided in `DuplicateReveal`, over in FileExplorer.
///
/// Stateless, like its sibling: it holds bindings and closures over `ContentView`'s state, so a
/// fresh one per use is equivalent to the methods it replaced.
@MainActor
struct DuplicateRevealCoordinator {
    let syncManager: FileSyncManager
    @Binding var selectedWorkspace: Workspace
    /// The request the Duplicates lens is showing. App-level state so it survives the workspace
    /// switch that is about to happen.
    @Binding var revealRequest: DuplicateRevealRequest?

    /// The absolute, tilde-expanded folder the pane on this side is showing — the root a scan for
    /// that source would walk. A closure because it is derived from live `@AppStorage`/`@State`
    /// that moves between the coordinator being built and being called.
    let paneRoot: @MainActor (_ isLeft: Bool) -> String
    /// Starts a Find Duplicates scan of `root`.
    let startScan: @MainActor (URL) -> Void

    /// What to do about a request for `filePath`, given what the Duplicates workspace is holding.
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
    /// **"Current" means the existing results actually cover this file, not that a scan has ever
    /// run.** `duplicateScanRoot` is published only on completion, so a non-nil root is a
    /// completed scan — but a completed scan of `~/Documents` says nothing about a file in
    /// `~/Projects`, and revealing against it would answer "no duplicates of X" from results that
    /// never looked. Containment against the scanned root is the honest test, and it is the same
    /// `PathBoundary` math the rest of this feature uses.
    ///
    /// **The scan root falls back to the file's own folder.** `paneRoot` is normally an ancestor
    /// of the row's file and is the right root — it is what the shipped "Find Duplicates" button
    /// scans, and a duplicate is relational, so a wider root finds more. But nothing structurally
    /// guarantees containment (a pane can be re-rooted while a menu is open), and a scan that does
    /// not contain the file is one that cannot answer the question. Falling back keeps the request
    /// answerable; it does not silently widen it.
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
    /// covers it.
    ///
    /// The request is set for EVERY decision, including the one that starts a scan: it is what the
    /// lens resolves against when results land, so setting it only on the no-scan path would make
    /// the common first-use case — no scan yet — reveal nothing at all.
    func findDuplicates(of node: FileNode, isLeft: Bool) {
        guard !node.isDirectory else { return }
        let decision = Self.decide(filePath: node.id,
                                   paneRoot: paneRoot(isLeft),
                                   scannedRoot: syncManager.duplicateScanRoot,
                                   isScanning: syncManager.isFindingDuplicates)
        Logger.shared.info("User requested duplicates of \(node.id) — \(decision)")
        selectedWorkspace = .duplicates
        revealRequest = DuplicateRevealRequest(path: node.id)
        if case .scanThenReveal(let root) = decision, !root.isEmpty {
            startScan(URL(fileURLWithPath: root))
        }
    }
}
