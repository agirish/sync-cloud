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

    /// The folder a survey covers: the profile's own, whatever the pane shows or Organize is scoped
    /// to — nil when the profile records none, which the survey refuses.
    ///
    /// **The card's receipt, resume offer and count all describe this folder**, because it is the
    /// only one a survey reads: what it learns is keyed by paths relative to the folder it walks,
    /// and read back by the profile's. This used to be the scope, else the pane's current folder,
    /// so a first reading set off with the pane on another source, or inside one subfolder, read
    /// that instead and recorded it under the profile's name.
    var documentSurveyRoot: URL? { syncManager.documentSurveyFolder }

    /// Where a survey is asked from: the scope when one is set, otherwise the lens's own root —
    /// the expression `buildStorageLensAction` uses. **It decides nothing about what is read**; the
    /// plan walks ``documentSurveyRoot`` and names this in the log when it is somewhere else.
    private var documentSurveyAskedFrom: URL? {
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
        // Shared with Activity's Running row (TE228), so the two say the same — `finishing` is its
        // own state, not a pause: rendered as one it read "paused at 7,558 of 7,558 … Resumes on its
        // own" over a survey that was not paused and could not be resumed.
        if let progress = syncManager.documentSurveyProgress { return .live(progress) }
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

    /// Starts the survey on a folder setup has just learned.
    ///
    /// **It moves the Organize scope to that folder first**, so the lenses answer about the tree
    /// setup just learned. The reading itself covers the profile's folder whatever the scope says,
    /// and setup only calls this when the profile it wrote is the one in use — which makes that
    /// folder this one.
    func startDocumentSurvey(learnedRoot: URL) {
        organizeScopePath = learnedRoot.path
        startDocumentSurvey(.read)
    }

    /// The card's primary verb while it offers to read: *Read My Documents*, or — over a count of
    /// nothing readable — *Look Again*, which only counts (``DocumentSurveyStarter/mode(for:)``).
    func startDocumentSurveyAction() {
        startDocumentSurvey(DocumentSurveyStarter.mode(for: documentSurveyCardState))
    }

    /// The interrupted card's *Start over*, once the card has asked: the progress on disk is
    /// discarded and every document is read again. Through the same walk as a first start, so the
    /// plan, the count and the refusals are one path.
    func startDocumentSurveyOverAction() {
        startDocumentSurvey(.startOver)
    }

    private func startDocumentSurvey(_ mode: DocumentSurveyStarter.Mode) {
        // Asked even when the profile names no folder: the plan's refusal says why on the banner.
        guard let asked = documentSurveyAskedFrom ?? documentSurveyRoot else { return }
        Task { @MainActor in
            let outcome = await DocumentSurveyStarter.start(
                manager: syncManager, askedFrom: asked, mode: mode,
                planned: { documentSurveyPlan = $0 })
            if let banner = outcome.banner { syncManager.banner = banner }
        }
    }

    /// Carries on an interrupted survey, resumes one the user paused, or — *Resume now* — reads
    /// through a pause the machine asked for.
    ///
    /// One verb on purpose: from the card's side "Resume" means the same thing every way, and
    /// which machinery answers it is not the reader's problem.
    func resumeDocumentSurveyAction() {
        if syncManager.documentSurveyProgress != nil {
            Task { await syncManager.resumeDocumentSurvey() }
            return
        }
        startDocumentSurvey(.read)
    }

    func pauseDocumentSurveyAction() {
        Task { await syncManager.pauseDocumentSurvey() }
    }

    func stopDocumentSurveyAction() {
        Task { await syncManager.stopDocumentSurvey() }
    }
}

/// Starting a survey — the walk, then the read — apart from the view, so a test can run it.
///
/// **The walk is what produces the count the offer card could not know**, so it runs first and its
/// answer reaches the card before a single document is opened — which is exactly what the uncounted
/// offer promises.
@MainActor
enum DocumentSurveyStarter {

    enum Mode: Equatable {
        /// Read the documents, carrying on from any progress on disk.
        case read
        /// Discard the progress on disk, then read every document.
        case startOver
        /// Count again and stop — *Look Again*.
        case recountOnly
    }

    /// What a press of the card's primary does from `state`.
    ///
    /// **Look Again only counts** (review L2, his call 2026-10-27). It promised "Count the documents
    /// here again" and ran the whole reading straight after the count, hours of it with no cost
    /// shown. A count that now finds documents puts the card back on Read My Documents, with its
    /// estimate.
    static func mode(for state: DocumentSurveyCardState?) -> Mode {
        state == .offered(documents: 0) ? .recountOnly : .read
    }

    /// What a start came to.
    enum Outcome: Equatable {
        case refused(FileSyncManager.DocumentSurveyRefusal)
        case nothingToRead
        /// *Look Again*'s answer: this many documents to read, and none read.
        case counted(Int)
        case ran(FileSyncManager.DocumentSurveyReport)
        /// Stopped so Setup's new profile could take the reading over; Setup starts it again.
        case handedOver

        /// The banner it is told on, or nil for one that says nothing.
        var banner: OperationBanner? {
            switch self {
            case .refused(let refusal): return .warning(refusal.sentence)
            case .nothingToRead:
                return .success("Nothing to read — no document here is in a format this app can open.")
            case .counted: return nil   // the card says it, with its estimate
            case .ran(let report):
                return report.isComplete ? .success(report.summary) : .warning(report.summary)
            case .handedOver: return nil
            }
        }
    }

    /// Plans, hands `planned` the count, and reads unless `mode` only counts.
    ///
    /// **A plan made for a profile Setup has since replaced is made again** (review M4): the walk
    /// takes a while, a Save beside it writes a new profile, and the run refuses a plan for the old
    /// one rather than read into it. Once, because the second plan is of the profile in use.
    ///
    /// **And only for the same folder** (review, 2026-10-27). A plan always walks the profile's own
    /// folder, so after a Save of another folder — Read Documents off — planning again read that
    /// folder instead: hours on documents nobody asked to have read.
    static func start(manager: FileSyncManager, askedFrom: URL, mode: Mode,
                      planned: (DocumentSurveyPlanFacts) -> Void) async -> Outcome {
        var overtaken: URL?
        while true {
            let plan: FileSyncManager.DocumentSurveyPlan
            switch await manager.planDocumentSurvey(root: askedFrom) {
            case .failure(let refusal):
                Logger.shared.info("Document survey: not started — \(refusal.sentence)")
                return .refused(refusal)
            case .success(let made): plan = made
            }
            if let overtaken, overtaken.standardizedFileURL.path != plan.root.standardizedFileURL.path {
                Logger.shared.info("Document survey: not started — the profile now in use is of "
                                   + "\(plan.root.path), not \(overtaken.path), the folder it was asked to read")
                return .refused(.profileReplaced)
            }
            planned(DocumentSurveyPlanFacts(rootPath: plan.root.path, documents: plan.total,
                                            unreadableTypes: plan.skippedUnreadableTypes))
            guard plan.total > 0 else { return .nothingToRead }
            if mode == .recountOnly {
                Logger.shared.info("Document survey: Look Again counted \(plan.total) document(s) "
                                   + "to read — nothing read until Read My Documents is pressed")
                return .counted(plan.total)
            }
            switch await manager.runDocumentSurvey(plan: plan, startingOver: mode == .startOver) {
            case .success(let report): return .ran(report)
            case .failure(.stoppedForNewProfile): return .handedOver
            case .failure(.profileReplaced) where overtaken == nil:
                overtaken = plan.root
                Logger.shared.info("Document survey: planning again for the profile now in use")
            case .failure(let refusal): return .refused(refusal)
            }
        }
    }
}
