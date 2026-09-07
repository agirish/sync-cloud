import Events
import FileExplorer
import SwiftUI
import Sync

/// RD11's card, wired: what to show, and the four verbs behind it.
///
/// **Here rather than in `LensWorkspaceView` because this is where `Sync` and `FileExplorer` meet.**
/// `DocumentSurveyCardState` is deliberately made of plain values — counts, seconds, one worded
/// sentence — the same rule `OrganizeOverview` follows for `reclaimable`, so the translating has to
/// happen somewhere that can see both, and that is the app.
extension ContentView {

    /// The root a survey would cover: the scope when one is set, otherwise the lens's own root —
    /// the same expression `buildStorageLensAction` uses, for the same reason. A survey aimed at
    /// the pane root while a scope chip is up would read a tree the header says it is not showing.
    var documentSurveyRoot: URL? {
        let path = organizeScope?.path ?? lensScanRootExpanded
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// What the card shows, or nil to hide it.
    ///
    /// **Order matters, and running wins.** A survey in flight is the only state where the card is
    /// reporting something live; everything below it is a standing fact that will still be true a
    /// second from now.
    var documentSurveyCardState: DocumentSurveyCardState? {
        // 1. Running, or paused mid-run.
        if let progress = syncManager.documentSurveyProgress {
            switch progress.phase {
            case .reading:
                return .running(done: progress.completed, total: progress.total,
                                folder: progress.currentFolder,
                                secondsRemaining: progress.estimatedSecondsRemaining, pause: nil)
            case .paused(let reason):
                return .running(done: progress.completed, total: progress.total,
                                folder: progress.currentFolder,
                                secondsRemaining: progress.estimatedSecondsRemaining,
                                pause: .init(sentence: reason.sentence,
                                             resumesOnItsOwn: reason.resumesOnItsOwn))
            case .finishing:
                // No verb and no reason: merging and rebuilding is minutes of work with nothing to
                // pause, and a card offering Pause there would offer something that cannot happen.
                return .running(done: progress.completed, total: progress.total,
                                folder: nil, secondsRemaining: nil,
                                pause: .init(sentence: "Rebuilding folder memory…",
                                             resumesOnItsOwn: true))
            }
        }
        // 2. Just finished — the receipt, for as long as the report stands.
        if let report = syncManager.documentSurveyReport, report.isComplete {
            return .finished(summary: report.summary,
                             unreadableTypes: documentSurveyUnreadableTypes)
        }
        // 3. Unfinished progress on disk. **Offered, never resumed by itself** — RD11 decision 3.
        if let root = documentSurveyRoot,
           let resumable = syncManager.resumableDocumentSurvey(root: root) {
            return .interrupted(done: resumable.done, total: resumable.total)
        }
        // 4. Never surveyed here. Hidden entirely where there is no profile to survey against, or
        //    where a corpus already covers the tree — there the incremental *Update folder memory*
        //    is both correct and a click, so offering three hours beside it would be offering the
        //    worse of two answers.
        guard syncManager.filingFolderProfile != nil,
              syncManager.filingMemory?.folders.isEmpty ?? true else { return nil }
        return .offered(documents: documentSurveyPlannedCount)
    }

    /// Starts a survey: the walk, then the read.
    ///
    /// **The walk is what produces the count the offer card could not know**, so it runs first and
    /// its answer reaches the card before a single document is opened — which is exactly what the
    /// uncounted offer promises.
    func startDocumentSurveyAction() {
        guard let root = documentSurveyRoot else { return }
        Task { @MainActor in
            Logger.shared.info("Document survey: planning for \(root.path)")
            switch await syncManager.planDocumentSurvey(root: root) {
            case .failure(let refusal):
                syncManager.banner = .warning(refusal.sentence)
            case .success(let plan):
                documentSurveyPlannedCount = plan.total
                documentSurveyUnreadableTypes = plan.skippedUnreadableTypes
                guard plan.total > 0 else {
                    syncManager.banner = .success(
                        "Nothing to read — no document here is in a format this app can open.")
                    return
                }
                switch await syncManager.runDocumentSurvey(root: root, plan: plan) {
                case .failure(let refusal): syncManager.banner = .warning(refusal.sentence)
                case .success(let report):
                    syncManager.banner = report.isComplete ? .success(report.summary)
                                                           : .warning(report.summary)
                }
            }
        }
    }

    /// Carries on an interrupted survey, or resumes one the user paused.
    ///
    /// The two are one verb on purpose: from the card's side "Resume" means the same thing either
    /// way, and which machinery answers it is not the reader's problem.
    func resumeDocumentSurveyAction() {
        if syncManager.documentSurveyProgress != nil {
            Task { await syncManager.resumeDocumentSurvey() }
            return
        }
        startDocumentSurveyAction()
    }

    func pauseDocumentSurveyAction() {
        Task { await syncManager.pauseDocumentSurvey() }
    }

    func stopDocumentSurveyAction() {
        Task { await syncManager.stopDocumentSurvey() }
    }
}
