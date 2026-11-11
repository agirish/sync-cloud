import Events
import FileExplorer
import SwiftUI
import Sync

/// The document survey card, wired: what it shows, and the four verbs behind it. In the app, not
/// `LensWorkspaceView`, because `DocumentSurveyCardState` is plain values (counts, seconds, one
/// sentence), so the translating happens where `Sync` and `FileExplorer` are both visible.
///
/// `DocumentSurveyPlanFacts`: what the last plan found, and which tree it found it in. The root
/// keeps the offer card over another folder from quoting this folder's document count.
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
    /// to; nil when the profile records none, which the survey refuses.
    ///
    /// The card's receipt, resume offer and count all describe this folder, because it is the only
    /// one a survey reads: what it learns is keyed by paths relative to the folder it walks, and
    /// read back by the profile's.
    var documentSurveyRoot: URL? { syncManager.documentSurveyFolder }

    /// Where a survey is asked from: the scope when one is set, otherwise the lens's root, as in
    /// `buildStorageLensAction`. It decides nothing about what is read: the plan walks
    /// ``documentSurveyRoot`` and logs this when it is somewhere else.
    private var documentSurveyAskedFrom: URL? {
        let path = organizeScope?.path ?? lensScanRootExpanded
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// What the card shows, or nil to hide it.
    ///
    /// Order matters, and running wins: a survey in flight is the only live state; everything
    /// below it is a standing fact.
    var documentSurveyCardState: DocumentSurveyCardState? {
        // 1. Running, or paused mid-run. Shared with Activity's Running row, so the two say the
        // same; `finishing` is its own state, not a pause. A source's own reading (Google
        // Drive's) shows on To File's strip, not on this card, which is the primary survey's.
        if let progress = syncManager.documentSurveyProgress, syncManager.documentSurveySourceRoot == nil {
            return .live(progress)
        }
        // 2. Just finished: the receipt, only for the tree it describes. The report outlives
        //    the run and Organize's scope moves under it; a real answer about the wrong tree is
        //    worse than none.
        if let report = syncManager.documentSurveyReport, report.isComplete,
           report.rootPath == documentSurveyRoot?.path {
            return .finished(summary: report.summary,
                             unreadableTypes: documentSurveyPlan?.unreadableTypes(for: report.rootPath) ?? 0)
        }
        // 3. Unfinished progress on disk. Offered, never resumed by itself.
        if let root = documentSurveyRoot,
           let resumable = syncManager.resumableDocumentSurvey(root: root) {
            return .interrupted(done: resumable.done, total: resumable.total)
        }
        // 4. No profile, so nothing to survey against and no card.
        guard syncManager.filingFolderProfile != nil else { return nil }

        // 5. Already read: the settled receipt, derived from what is on disk, not from this
        //    session's report, which exists only after a run in this launch. `filingMemory` and
        //    `filingSurveyedAt` are both restored at launch, so a tree read last week or by the
        //    offline builder still gets its receipt.
        //
        //    Cheap on purpose: the folder count and the stamp are already in memory. The document
        //    count is not (it would mean parsing the whole corpus for one line), so it is left out.
        if let folders = syncManager.filingMemory?.folders.count, folders > 0 {
            return .settled(folders: folders, lastRead: syncManager.filingSurveyedAt)
        }

        // 6. A profile, and nothing read yet. The count only where it belongs to this tree
        //    (see `DocumentSurveyPlanFacts`).
        return .offered(documents: documentSurveyPlan?.documents(for: documentSurveyRoot?.path))
    }

    /// Starts the survey on a folder setup has just learned.
    ///
    /// Moves the Organize scope to that folder first, so the lenses answer about it. The reading
    /// covers the profile's folder whatever the scope says, and setup calls this only when the
    /// profile it wrote is the one in use, which makes that folder this one.
    func startDocumentSurvey(learnedRoot: URL) {
        organizeScopePath = learnedRoot.path
        startDocumentSurvey(.read)
    }

    /// The card's primary verb while it offers to read: *Read My Documents*, or, over a count of
    /// nothing readable, *Look Again*, which only counts (``DocumentSurveyStarter/mode(for:)``).
    func startDocumentSurveyAction() {
        startDocumentSurvey(DocumentSurveyStarter.mode(for: documentSurveyCardState))
    }

    /// The interrupted card's *Start over*, once the card has asked: discards the progress on disk
    /// and reads every document again, through the same walk as a first start.
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

    /// Carries on an interrupted survey, resumes one the user paused, or (*Resume now*) reads
    /// through a pause the machine asked for. One verb, because to the reader "Resume" means the
    /// same thing every way.
    func resumeDocumentSurveyAction() {
        if syncManager.documentSurveyProgress != nil, syncManager.documentSurveySourceRoot == nil {
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

/// Starting a survey (the walk, then the read) apart from the view, so a test can run it. The walk
/// produces the count the offer card lacks, so it runs first and reaches the card before any
/// document is opened.
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
    /// Look Again only counts, as its label promises; the reading can take hours and the card
    /// shows its cost first. A count that finds documents puts the card back on Read My Documents,
    /// with its estimate.
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
            case .refused(let refusal): return .refusal(refusal.sentence, log: .warn)
            case .nothingToRead:
                return .success("Nothing to read — no document here is in a format this app can open.")
            case .counted: return nil   // the card says it, with its estimate
            case .ran(let report):
                return report.isComplete ? .success(report.summary) : .warning(report.summary, log: .warn)
            case .handedOver: return nil
            }
        }
    }

    /// Plans, hands `planned` the count, and reads unless `mode` only counts.
    ///
    /// A plan made for a profile Setup has since replaced is made again, once: a Save during the
    /// walk writes a new profile, and the run refuses a plan for the old one. Only for the same
    /// folder: a plan walks the profile's own folder, so after a Save of another folder, planning
    /// again would spend hours reading documents nobody asked to have read.
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
