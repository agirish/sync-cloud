import Events
import Foundation

/// The first survey of a tree: page one of every readable document, in the background, over hours.
///
/// **The sibling of ``resurveyFilingMemory(root:taxonomy:now:)``, and the one that comes first.**
/// That pass is incremental — it reads what changed since the last survey, which is tens of
/// documents, in one batch, on this actor's task. It cannot be the *first* run: the first run is
/// ~11,000 documents and about three hours, and a batch that size has nowhere to stop, no way to
/// report where it got to, and nothing to resume from.
///
/// So this drives ``DocumentSurveyRun``, which owns the reading, the pausing and the checkpoint;
/// what lives here is everything that needs the manager — the walk, the refusals, the machine's
/// conditions, and the single write at the end.
extension FileSyncManager {

    /// What a document survey did. Reported to the completion summary, which says what was **not**
    /// read as plainly as what was.
    public struct DocumentSurveyReport: Sendable, Equatable {
        /// The tree this describes.
        ///
        /// **Carried because the receipt outlives the run and Organize's scope can move under it.**
        /// Without it the card showed a completed survey's summary over whatever folder was
        /// selected next — a real answer about the wrong tree, which is worse than no answer.
        public let rootPath: String
        public let documentsRead: Int
        public let documentsBlank: Int
        public let documentsUnavailable: Int
        public let foldersLearned: Int
        /// Nil when it ran to the end; otherwise where it stopped, so the offer card can say what
        /// resuming would cost.
        public let stoppedAt: Int?
        public let plannedTotal: Int
        /// False when the rebuilt memory came out identical to the one already on disk — see
        /// ``FilingSurveyStore/write(corpus:memory:previousMemory:id:in:root:now:)``.
        public let changed: Bool

        public var isComplete: Bool { stoppedAt == nil }

        /// One sentence, and honest about both ends of it.
        ///
        /// **Names what was not read, not only what was.** `documentsUnavailable` is the count the
        /// rule was written for: a survey that reports only what it managed reads as complete when
        /// it was not. The Office formats this app cannot open are not counted here at all —
        /// they never reach a plan — so the completion card names them separately from
        /// ``DocumentSurveyPlan/skippedUnreadableTypes``.
        public var summary: String {
            guard isComplete else {
                return "Stopped after reading \(documentsRead) of \(plannedTotal) documents. "
                    + "Nothing has been lost — carrying on reads only the rest."
            }
            var parts = ["\(documentsRead) document\(documentsRead == 1 ? "" : "s") read"]
            if documentsBlank > 0 { parts.append("\(documentsBlank) had no readable text") }
            if documentsUnavailable > 0 {
                parts.append("\(documentsUnavailable) not downloaded yet, so left for a later pass")
            }
            return parts.joined(separator: ", ") + ". "
                + "\(foldersLearned) folder\(foldersLearned == 1 ? "" : "s") now have learned content."
        }
    }

    /// Why a survey refused to start. Every one of them is a state where starting would waste hours
    /// or destroy learned content, and none is the user's fault.
    /// Conforms to `Error` so it can be a `Result`'s failure — **and for no other reason.** None of
    /// these is thrown, and none is an error in the sense the user would recognise: each is a state
    /// where starting would waste hours or write over learned content, which is the survey doing
    /// its job rather than failing at it. `sentence` is what a card shows, and it says so.
    public enum DocumentSurveyRefusal: Error, Sendable, Equatable {
        case alreadyRunning
        /// The walk was cancelled — a provider switch, a quit. **Its own case because it was
        /// reported as `alreadyRunning`**, which put "A survey is already running" on screen for a
        /// survey that had just been cancelled and was running nowhere.
        case cancelled
        case landingInProgress
        case noProfileDirectory
        case noExtractor
        case noProfile
        /// The root could not be listed — permission, or briefly unreachable. **The walk reports
        /// that as an empty tree**, which is indistinguishable from a tree whose every document was
        /// deleted, so nothing may be inferred from it.
        case rootUnreadable
        /// `filing-corpus.json` is on disk and could not be read. Nothing may be inferred about the
        /// tree from that, and starting from empty would write the result over learned content.
        case corpusUnreadable
        /// A corpus already covers this tree. The *incremental* pass is the right one, and it is a
        /// click rather than three hours.
        case alreadySurveyed
        /// The tree is bigger than the whole-tree probe budget and the user declined.
        case treeTooLargeAndDeclined
        case checkpointUnreadable
        case checkpointIsForAnotherRun

        public var sentence: String {
            switch self {
            case .alreadyRunning: return "A survey is already running."
            case .cancelled: return "Stopped before it started."
            case .landingInProgress:
                return "A reorganisation is landing — run this once the landing finishes."
            case .noProfileDirectory, .noProfile:
                return "This Mac has no folder survey yet. Run setup's Folders step first."
            case .noExtractor: return "Nothing on this Mac can read document contents."
            case .rootUnreadable:
                return "That folder could not be read — permission denied, or it is not available "
                    + "right now. Nothing was surveyed."
            case .corpusUnreadable:
                return "filing-corpus.json is on disk but could not be read, so this would have "
                    + "written over what has been learned. Nothing was surveyed — move that file "
                    + "aside to survey from scratch."
            case .alreadySurveyed:
                return "These documents have been read already. Update folder memory reads only "
                    + "what has changed since."
            case .treeTooLargeAndDeclined: return "Not surveyed."
            case .checkpointUnreadable:
                return "There is unfinished progress on disk that could not be read. Move "
                    + "survey-progress.json aside to start again."
            case .checkpointIsForAnotherRun:
                return "The unfinished progress on disk is for a different folder."
            }
        }
    }

    /// The work a survey would do, worked out before anything is read.
    public struct DocumentSurveyPlan: Sendable, Equatable {
        public let paths: [String]
        /// **The whole walk, not just the documents.** An earlier draft carried only the document
        /// stamps and handed `buildMemory` an empty `folders` map — and that is not a cosmetic
        /// loss. `folderModified` is written into every memory entry from this, and
        /// ``FilingSurvey/staleFolders(tree:memory:)`` compares it against the folder's mtime to
        /// decide what the NEXT incremental survey has to re-read. Absent, every entry gets `nil`,
        /// every folder compares unequal, and the first `resurveyFilingMemory` after a three-hour
        /// survey re-reads the entire tree. Nothing fails; it is just slow, for ever.
        ///
        /// Carrying the `Tree` whole rather than the two fields it needs, so a third field added to
        /// it later cannot be silently dropped here again.
        public let tree: FilingSurvey.Tree
        public var stamps: [String: FilingSurvey.Stamp] { tree.documents }
        public let salt: String
        public let profileId: String
        /// Documents in the tree this app cannot open — `.docx`, `.pptx`, `.xlsx` and the rest.
        ///
        /// **Counted so the summary can say so.** On the reference tree these are 816 of 11,835
        /// files and they leave 143 of 2,306 folders with no content at all: the largest single gap
        /// in a derived survey, and one that a summary reporting only what it read would hide.
        public let skippedUnreadableTypes: Int
        public var total: Int { paths.count }
    }

    // MARK: - Working out what to do

    /// Builds the plan, or says why there is nothing to plan.
    ///
    /// **Refuses where a corpus already covers the tree.** A survey that runs for three hours and
    /// is then refused at the store has wasted the three hours; and where a corpus exists, the
    /// incremental pass is both correct and a click. `FilingSurveyStore`'s own refusals stay as the
    /// backstop, which is what makes this check's absence a bug rather than a disaster.
    public func planDocumentSurvey(root: URL) async -> Result<DocumentSurveyPlan, DocumentSurveyRefusal> {
        guard !filingSurveyLifecycle.isRunning else { return .failure(.alreadyRunning) }
        guard !restructureLandingInProgress else { return .failure(.landingInProgress) }
        guard let directory = filingProfilesDirectory else { return .failure(.noProfileDirectory) }
        guard filingSnippetExtractor != nil else { return .failure(.noExtractor) }
        guard let profileId = filingProfileDirectoryId
                ?? filingMemory?.profileId ?? filingFolderProfile?.profileId else {
            return .failure(.noProfile)
        }

        let existing: FilingCorpus?
        switch FilingSurveyStore.corpusRead(id: profileId, in: directory) {
        case .unreadable: return .failure(.corpusUnreadable)
        case .absent: existing = nil
        case .loaded(let corpus):
            // A corpus with documents in it means this tree has been surveyed. An EMPTY one is the
            // shape a previous refusal or a fresh profile leaves, and re-reading is right there.
            guard corpus.isEmpty else { return .failure(.alreadySurveyed) }
            existing = corpus
        }

        // The same ask-first every whole-tree pass makes: promoting `~` or a volume to a source is
        // one click, and this is the walk that would then cover it.
        let probe = NodeBudget(wholeTreeProbeBudget)
        var walked = await Self.buildTree(url: root, sortOption: .name,
                                          fileManager: fileManager, maxDepth: nil, budget: probe)
        if Task.isCancelled { return .failure(.cancelled) }
        if probe.didStopADescent {
            let preflight = LargeWalkPreflight(pass: .filing, rootPath: root.path,
                                               probeLimit: probe.limit)
            guard largeWalkConfirmer(preflight) else { return .failure(.treeTooLargeAndDeclined) }
            walked = await Self.buildTree(url: root, sortOption: .name,
                                          fileManager: fileManager, maxDepth: nil)
            if Task.isCancelled { return .failure(.cancelled) }
        }

        // **A root that could not be listed must never reach a merge.** `buildTree` reports a
        // permission-denied or briefly-unreachable root as a single unexplored marker and `flatten`
        // skips it, so what comes out is an EMPTY tree — indistinguishable from a tree whose every
        // document was deleted. The incremental pass has carried this guard since it was written;
        // this one writes the same two files.
        if Self.isUnreadableRootMarker(walked, root: root) { return .failure(.rootUnreadable) }

        let tree = FilingSurvey.flatten(walked)
        // **A resumable checkpoint's salt wins over everything, and forgetting that made resume
        // impossible.** With no corpus and no memory the last branch mints a RANDOM salt, so a
        // resume planned a different salt from the one the checkpoint was written under,
        // `adoptCheckpoint` refused it as another run's, and the user was told their progress
        // belonged to a different folder. On a fresh machine — the only machine that runs a first
        // survey — that was every resume.
        let resumableSalt = DocumentSurveyCheckpointStore.read(id: profileId, in: directory)
            .checkpoint.flatMap { $0.rootPath == root.path ? $0.salt : nil }
        let salt = resumableSalt
            ?? (existing?.salt.isEmpty == false ? existing!.salt
                : (filingMemory?.salt.isEmpty == false ? filingMemory!.salt : Self.newSurveySalt()))
        let paths = FilingSurvey.documentsToRead(tree: tree, corpus: existing, memory: filingMemory)
        let unreadableTypes = tree.documents.keys.filter {
            !FilingSurvey.readableExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }.count

        return .success(DocumentSurveyPlan(paths: paths, tree: tree, salt: salt,
                                           profileId: profileId,
                                           skippedUnreadableTypes: unreadableTypes))
    }

    /// The unfinished survey on disk, if there is one this root could carry on — for the offer card
    /// that asks rather than resuming by itself (RD11 decision 3).
    public func resumableDocumentSurvey(root: URL) -> (done: Int, total: Int)? {
        guard let directory = filingProfilesDirectory,
              let profileId = filingProfileDirectoryId
                ?? filingMemory?.profileId ?? filingFolderProfile?.profileId,
              case .loaded(let checkpoint) = DocumentSurveyCheckpointStore.read(id: profileId,
                                                                                in: directory),
              checkpoint.rootPath == root.path
        else { return nil }
        return checkpoint.progress
    }

    // MARK: - The machine's state, for the run to yield to

    /// What ``DocumentSurveyYield`` decides from. The six lifecycles are named here, in rail order,
    /// because the words belong to the user and `Sync` is where the manager knows them.
    func documentSurveyConditions() -> DocumentSurveyConditions {
        var scans: [String] = []
        if filingScanLifecycle.isRunning { scans.append("To File") }
        if duplicateScanLifecycle.isRunning { scans.append("Duplicates") }
        if nameScanLifecycle.isRunning { scans.append("Names") }
        // **`filingSurveyLifecycle` is deliberately NOT here, and leaving it in was a deadlock.**
        // `runDocumentSurvey` takes that very lifecycle for the duration — it is the survey's own
        // running flag — so counting it as a scan to stand aside for made the survey yield to
        // itself on the first poll, before opening a single document, and stay there for ever. The
        // card would have read "paused while folder memory runs" under a survey that was the thing
        // running. Nothing else can hold it at the same time: `planDocumentSurvey` and
        // `resurveyFilingMemory` both refuse to start while it is set.
        _ = filingSurveyLifecycle
        if storageLensLifecycle.isRunning { scans.append("Storage") }
        if automationDryRunLifecycle.isRunning { scans.append("Rules") }
        // Read ONCE. Three calls would be three snapshots taken at three instants, which is the
        // exact incoherence `DocumentSurveyConditions` exists to prevent one level up.
        let machine = machineConditions?() ?? .unknown
        return DocumentSurveyConditions(
            isVerifying: isVerifyAllRunning,
            activeFileOperations: activeFileOperationsCount,
            runningScans: scans,
            displayAsleep: machine.displayAsleep,
            heat: machine.heat,
            lowPowerMode: machine.lowPowerMode)
    }

    // MARK: - Running it

    /// Reads the plan, then writes the corpus and memory **once**, at the end.
    ///
    /// ## Why the write is where it is
    ///
    /// The memory is a full rebuild — IDF is corpus-wide, so a partial one weighs a new folder's
    /// anchors on a different denominator from its neighbours' — and its bytes are hashed into
    /// ``FilingProfileStore/fingerprint(id:in:)``, which is part of every cached classification's
    /// key. Writing it mid-survey would not merely be wasted work: it would discard every cached
    /// cloud verdict, once per checkpoint.
    ///
    /// ## Why the last steps leave this actor
    ///
    /// `FileSyncManager` is `@MainActor`, and `merge`, `buildMemory` and `write` over ~11,000
    /// documents are the three expensive steps in the pass. Run here they stall the window at
    /// exactly the moment the user is most likely to be watching it. All three are already pure of
    /// `FileManager`, `Date()` and defaults — deliberately so — which is what lets them run
    /// detached. Only the publication comes back.
    @discardableResult
    public func runDocumentSurvey(root: URL, plan: DocumentSurveyPlan,
                                  now: Date = Date()) async -> Result<DocumentSurveyReport, DocumentSurveyRefusal> {
        guard !filingSurveyLifecycle.isRunning else { return .failure(.alreadyRunning) }
        guard let directory = filingProfilesDirectory else { return .failure(.noProfileDirectory) }
        guard let extractor = filingSnippetExtractor else { return .failure(.noExtractor) }

        // **Logged at every edge, because this runs for hours with nobody watching.**
        // `~/sync-cloud.log` is how this app is debugged, and a pass that wrote one line at the end
        // would leave "it seemed to stop" with nothing to read. Start, every pause and its reason,
        // and the stop all land here; the per-document reads deliberately do not, which would be
        // 7,558 lines.
        Logger.shared.info("Document survey: starting — \(plan.total) document(s) to read under "
                           + "\(root.lastPathComponent)")
        let epoch = beginScan(\.filingSurveyLifecycle, status: "Reading your documents…")
        defer { endScan(\.filingSurveyLifecycle) }

        let run = DocumentSurveyRun(
            profileId: plan.profileId, root: root, salt: plan.salt, plan: plan.paths,
            stamps: plan.stamps,
            environment: documentSurveyEnvironment(extractor: extractor),
            directory: directory)

        if let refusal = await run.adoptCheckpoint() {
            switch refusal {
            case .checkpointUnreadable: return .failure(.checkpointUnreadable)
            case .checkpointIsForAnotherRun: return .failure(.checkpointIsForAnotherRun)
            }
        }

        documentSurveyRun = run
        defer { documentSurveyRun = nil }

        let outcome = await run.run()

        // A stopped run keeps its checkpoint and writes nothing: the corpus is only ever written
        // whole, and a partial one would make `surveyedRegion` cover just what was read — which
        // makes every future survey skip the rest of the tree, silently and permanently.
        guard outcome.isComplete else {
            Logger.shared.info("Document survey: stopped at \(outcome.stoppedAt ?? 0) of "
                               + "\(plan.total). Progress is on disk; carrying on reads only the "
                               + "rest.")
            documentSurveyProgress = nil
            return .success(DocumentSurveyReport(
                rootPath: root.path,
                documentsRead: outcome.documentsRead, documentsBlank: outcome.documentsBlank,
                documentsUnavailable: outcome.documentsUnavailable,
                foldersLearned: filingMemory?.folders.count ?? 0,
                stoppedAt: outcome.stoppedAt, plannedTotal: plan.total, changed: false))
        }

        _ = updateScan(\.filingSurveyLifecycle, epoch: epoch, status: "Rebuilding folder memory…")

        let tree = plan.tree
        let previousMemory = filingMemory
        let profileId = plan.profileId
        let salt = plan.salt
        let read = outcome.read
        let rootPath = root.path

        // The three expensive steps, off this actor. Nothing in here touches `self`.
        let written: (memory: FilingMemory, changed: Bool)?
        do {
            written = try await Task.detached(priority: .utility) {
                let corpus = FilingSurvey.merge(corpus: FilingCorpus(profileId: profileId, salt: salt),
                                                tree: tree, read: read)
                let memory = FilingSurvey.buildMemory(corpus: corpus, folderModified: tree.folders,
                                                      profileId: profileId)
                let changed = try FilingSurveyStore.write(corpus: corpus, memory: memory,
                                                          previousMemory: previousMemory,
                                                          id: profileId, in: directory,
                                                          root: rootPath, now: now)
                return (memory, changed)
            }.value
        } catch {
            Logger.shared.error("Couldn't write the surveyed folder memory: \(error.localizedDescription)")
            // The checkpoint is deliberately left: everything read is still on disk, so the next
            // run resumes rather than re-reading three hours of documents to reach the same failure.
            documentSurveyProgress = nil
            return .success(DocumentSurveyReport(
                rootPath: root.path,
                documentsRead: outcome.documentsRead, documentsBlank: outcome.documentsBlank,
                documentsUnavailable: outcome.documentsUnavailable,
                foldersLearned: previousMemory?.folders.count ?? 0,
                stoppedAt: plan.total, plannedTotal: plan.total, changed: false))
        }

        // **Only now.** The checkpoint outlives the corpus write by design: a crash between the two
        // leaves a resumable checkpoint beside a complete corpus, and the next run finds the tree
        // already covered. The other order leaves neither.
        try? DocumentSurveyCheckpointStore.discard(id: profileId, in: directory)

        filingSurveyedAt = now
        if let written, written.changed {
            filingMemory = written.memory
            filingArtifactFingerprint = FilingProfileStore.fingerprint(id: profileId, in: directory)
        }
        documentSurveyProgress = nil
        completeScan(\.filingSurveyLifecycle, root: root)

        let report = DocumentSurveyReport(
            rootPath: root.path,
            documentsRead: outcome.documentsRead, documentsBlank: outcome.documentsBlank,
            documentsUnavailable: outcome.documentsUnavailable,
            foldersLearned: written?.memory.folders.count ?? 0,
            stoppedAt: nil, plannedTotal: plan.total, changed: written?.changed ?? false)
        Logger.shared.info("Document survey finished — \(report.summary)")
        if plan.skippedUnreadableTypes > 0 {
            Logger.shared.info("\(plan.skippedUnreadableTypes) document(s) are in formats this app "
                               + "cannot open (Word, PowerPoint, Excel) and were never read.")
        }
        documentSurveyReport = report
        return .success(report)
    }

    /// The run's environment, wired to this manager.
    private func documentSurveyEnvironment(
        extractor: @escaping @Sendable (String) async -> String?
    ) -> DocumentSurveyRun.Environment {
        // Captured as a `@Sendable` closure hopping back to the actor rather than reading `self`
        // from the run's isolation — the conditions are six published properties and must be read
        // as one snapshot, on the actor that owns them.
        // **`shouldPause` is async, and that is a correctness requirement rather than a style.**
        // The run is its own actor; the conditions are six `@Published` properties owned by this
        // one. Reading them synchronously from there is not possible safely —
        // `MainActor.assumeIsolated` inside the run's isolation traps rather than hopping — so the
        // hop is explicit and awaited, and the six are read as one snapshot on the actor that owns
        // them.
        return DocumentSurveyRun.Environment(
            readDocument: extractor,
            isAvailable: { FilingSurvey.isAvailable($0) },
            shouldPause: { [weak self] in
                guard let conditions = await self?.documentSurveyConditions() else { return nil }
                return DocumentSurveyYield.pause(for: conditions)
            },
            whilePaused: {
                // Polled rather than pushed: a survey that resumes within a second of the condition
                // clearing is indistinguishable from one that resumes instantly, and a poll cannot
                // miss an edge the way a notification can.
                try? await Task.sleep(for: .seconds(1))
            },
            now: { Date() },
            publish: { progress in
                Task { @MainActor [weak self] in self?.documentSurveyProgress = progress }
            })
    }

    /// Pauses the running survey, if there is one.
    public func pauseDocumentSurvey() async {
        await documentSurveyRun?.pause()
    }

    /// Resumes a survey the user paused.
    public func resumeDocumentSurvey() async {
        await documentSurveyRun?.resume()
    }

    /// Stops the running survey at the next document boundary, keeping its progress.
    public func stopDocumentSurvey() async {
        await documentSurveyRun?.stop()
    }
}
