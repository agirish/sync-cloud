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
/// What the last plan found, and which tree it found it in.
///
/// **The root is the whole point.** These two numbers were plain `@State` with no idea what they
/// described, so after surveying one folder the offer card over a *different* folder quoted the
/// first one's document count — a specific, confident, wrong number in the sentence a person
/// decides on.
struct DocumentSurveyPlanFacts: Equatable {
    let rootPath: String
    let count: Int
    let unreadable: Int

    init(rootPath: String, documents: Int, unreadableTypes: Int) {
        self.rootPath = rootPath
        self.count = documents
        self.unreadable = unreadableTypes
    }

    /// The count, but only for the tree it was measured in.
    func documents(for path: String?) -> Int? { path == rootPath ? count : nil }
    func unreadableTypes(for path: String?) -> Int { path == rootPath ? unreadable : 0 }
}

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
                // Its own card state, not a pause. Rendered as one it read "paused at 7,558 of
                // 7,558 … Resumes on its own" over a survey that was not paused and could not be
                // resumed — and offered a Pause for something with nothing to pause.
                return .finishing(done: progress.completed)
            }
        }
        // 2. Just finished — the receipt, **for the tree it actually describes.**
        //    The report outlives the run and Organize's scope moves under it, so without the root
        //    check a completed survey's summary sat over whatever folder was selected next: a real
        //    answer about the wrong tree, which is worse than no answer at all.
        if let report = syncManager.documentSurveyReport, report.isComplete,
           report.rootPath == documentSurveyRoot?.path {
            return .finished(summary: report.summary,
                             unreadableTypes: documentSurveyPlan?.unreadableTypes(for: report.rootPath) ?? 0)
        }
        // 3. Unfinished progress on disk. **Offered, never resumed by itself** — RD11 decision 3.
        if let root = documentSurveyRoot,
           let resumable = syncManager.resumableDocumentSurvey(root: root) {
            return .interrupted(done: resumable.done, total: resumable.total)
        }
        // 4. Nothing to survey against at all — no profile, so no card.
        guard syncManager.filingFolderProfile != nil else { return nil }

        // 5. Already read: the settled receipt.
        //
        //    **Derived from what is on disk, not from this session's report.** The report exists
        //    only after a run in THIS launch, so a tree read last week — or read by the offline
        //    builder — had no receipt at all. That is how the card came to disappear completely
        //    once a memory existed, leaving Organize's overview silent about the reading while the
        //    "surveyed 3 days ago" line sat on Restructure's card and the refresh sat in a dropdown
        //    inside To File. `filingMemory` and `filingSurveyedAt` are both restored at launch,
        //    which is exactly how Storage's receipt survives one.
        //
        //    Cheap on purpose: the folder count and the stamp are already in memory. The document
        //    count is not — drawing it would mean parsing a 9,500-entry corpus for one line — so
        //    the card states what it knows and leaves out what it would have to pay for.
        if let folders = syncManager.filingMemory?.folders.count, folders > 0 {
            return .settled(folders: folders, lastRead: syncManager.filingSurveyedAt)
        }

        // 6. A profile, and nothing read yet. The count only where it belongs to THIS tree —
        //    see `DocumentSurveyPlanFacts`.
        return .offered(documents: documentSurveyPlan?.documents(for: documentSurveyRoot?.path))
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
                documentSurveyPlan = DocumentSurveyPlanFacts(
                    rootPath: root.path, documents: plan.total,
                    unreadableTypes: plan.skippedUnreadableTypes)
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
