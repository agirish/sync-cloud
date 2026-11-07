import Events
import Foundation

/// The first survey of a tree: page one of every readable document, in the background, over hours.
///
/// ``resurveyFilingMemory(root:taxonomy:now:)`` is the incremental pass: tens of changed documents
/// in one batch. A first run is ~11,000 documents and hours, which needs somewhere to stop, a way
/// to report progress and a checkpoint to resume from. So this drives ``DocumentSurveyRun``, which
/// owns the reading, pausing and checkpoint; this file holds what needs the manager: the walk, the
/// refusals, the machine's conditions and the single write at the end.
extension FileSyncManager {

    /// What a document survey did, for the completion summary, which says what was not read as
    /// plainly as what was.
    public struct DocumentSurveyReport: Sendable, Equatable {
        /// The tree this describes. The receipt outlives the run and Organize's scope can move, so
        /// the card checks this to avoid showing the summary over a different folder.
        public let rootPath: String
        public let documentsRead: Int
        public let documentsBlank: Int
        public let documentsUnavailable: Int
        public let foldersLearned: Int
        /// Nil when it ran to the end; otherwise where it stopped, so the offer card can say what
        /// resuming would cost.
        public let stoppedAt: Int?
        public let plannedTotal: Int
        /// False when the rebuilt memory is identical to the one on disk
        /// (``FilingSurveyStore/write(corpus:memory:previousMemory:id:in:root:now:)``).
        public let changed: Bool

        public var isComplete: Bool { stoppedAt == nil }

        /// One sentence that names what was not read (`documentsUnavailable`) as well as what was,
        /// so a partial survey doesn't read as complete. Office formats the app can't open never
        /// reach a plan; the card names them from ``DocumentSurveyPlan/skippedUnreadableTypes``.
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

    /// Why a survey refused to start: each is a state where starting would waste hours or write
    /// over learned content, and none is the user's fault. `Error` only so it can be a `Result`'s
    /// failure; none is thrown. `sentence` is what a card shows.
    public enum DocumentSurveyRefusal: Error, Sendable, Equatable {
        case alreadyRunning
        /// The walk was cancelled (a provider switch, a quit). Not `alreadyRunning`, which would
        /// claim a survey is running when none is.
        case cancelled
        case landingInProgress
        case noProfileDirectory
        case noExtractor
        case noProfile
        /// The profile doesn't say which folder it describes (no `root`, or not absolute). A survey
        /// may read no other folder: what it learns is keyed relative to the folder it walks, so
        /// the pane's folder, the scope or `~` would each key the memory to the wrong tree.
        case noRecordedFolder
        /// The root couldn't be listed (permission, or briefly unreachable). The walk reports that
        /// as an empty tree, the same as one whose every document was deleted, so nothing may be
        /// inferred from it.
        case rootUnreadable
        /// `filing-corpus.json` is on disk and can't be read. Starting from empty would write the
        /// result over learned content.
        case corpusUnreadable
        /// A corpus already covers this tree; the incremental pass is the right one, and is quick.
        case alreadySurveyed
        /// The tree is bigger than the whole-tree probe budget and the user declined.
        case treeTooLargeAndDeclined
        case checkpointUnreadable
        case checkpointIsForAnotherRun
        /// Every document was read but the artifacts couldn't be written. Not a stopped success:
        /// nothing is left to read. The checkpoint is kept, so a retry costs the write, not the
        /// reading.
        case couldNotWrite
        /// *Start over* couldn't remove the unfinished progress. Nothing starts, because a new run
        /// would adopt it, which is resuming.
        case couldNotDiscardProgress
        /// The plan was made for a profile this Mac no longer uses (Setup saved a new one while it
        /// walked). Run, it would write hours of reading into the replaced profile; planned again,
        /// it reads into the one in use.
        case profileReplaced
        /// Stopped so a profile write could replace the profile it read
        /// (``FileSyncManager/stopDocumentSurveyBeforeReplacingProfile(savingFolder:)``). Progress
        /// is kept, and whoever stopped it restarts it on the new profile. Not a success, whose
        /// "Stopped after reading …" banner would sit over the reading carrying on.
        case stoppedForNewProfile
        /// Read Documents was asked of a source that has no survey of its own to read into.
        case noSourceSurvey
        /// The source's documents have been read already. A source has no Refresh yet.
        case sourceAlreadyRead
        /// The source's folders are being learned again. The learn retires the survey a reading
        /// would read into, and the reading would recreate its folder and date the new one.
        case learningFolders

        public var sentence: String {
            switch self {
            case .alreadyRunning: return "A survey is already running."
            case .cancelled: return "Stopped before it started."
            case .landingInProgress:
                return "A reorganization is landing — run this once the landing finishes."
            case .noProfileDirectory, .noProfile:
                return "This Mac has no folder survey yet. Run setup’s Folders step first."
            case .noExtractor: return "Nothing on this Mac can read document contents."
            case .noRecordedFolder:
                return "This Mac’s folder survey does not say which folder it describes, so there "
                    + "is no telling which documents to read. Nothing was surveyed — give "
                    + "folder-profile.json an absolute “root” first."
            case .rootUnreadable:
                return "That folder could not be read — permission denied, or it is not available "
                    + "right now. Nothing was surveyed."
            case .corpusUnreadable:
                return "filing-corpus.json is on disk but could not be read, so this would have "
                    + "written over what has been learned. Nothing was surveyed — move that file "
                    + "aside to survey from scratch."
            case .alreadySurveyed:
                return "These documents have been read already. Refresh reads only what has "
                    + "changed since."
            case .treeTooLargeAndDeclined: return "Not surveyed."
            case .checkpointUnreadable:
                return "There is unfinished progress on disk that could not be read. Move "
                    + "survey-progress.json aside to start again."
            case .checkpointIsForAnotherRun:
                return "The unfinished progress on disk is for a different folder."
            case .couldNotWrite:
                return "Every document was read, but what was learned could not be saved. "
                    + "Nothing was lost — carrying on tries the write again without re-reading."
            case .couldNotDiscardProgress:
                return "The unfinished progress could not be cleared, so nothing was started over. "
                    + "Move survey-progress.json aside to start again."
            case .profileReplaced:
                return "The folder survey changed while the reading was being set up. Nothing was read."
            case .stoppedForNewProfile:
                return "Stopped so the new folder survey could take over. Nothing has been lost — "
                    + "the reading carries on from here."
            case .noSourceSurvey:
                return "This source has no folder survey of its own yet. Learn its folders first."
            case .sourceAlreadyRead:
                return "This source’s documents have been read already."
            case .learningFolders:
                return "Its folders are being learned. Read its documents when that finishes."
            }
        }
    }

    /// The work a survey would do, worked out before anything is read.
    public struct DocumentSurveyPlan: Sendable, Equatable {
        /// The folder this plan walked (the profile's own), which its run reads from and records
        /// against. Carried in the plan so a run can't be handed one folder's plan and another
        /// folder to read.
        public let root: URL
        public let paths: [String]
        /// The whole walk, folders included, not just the documents. `buildMemory` writes each
        /// folder's `folderModified` from it, and ``FilingSurvey/staleFolders(tree:memory:)``
        /// compares that with the folder's mtime; without it, the next incremental survey would
        /// re-read the entire tree. Carried whole so a field added to `Tree` can't be dropped here.
        public let tree: FilingSurvey.Tree
        public var stamps: [String: FilingSurvey.Stamp] { tree.documents }
        public let salt: String
        public let profileId: String
        /// Documents this app can't open (`.docx`, `.pptx`, `.xlsx` and the rest), counted so the
        /// summary can say so: they can leave whole folders with no learned content.
        public let skippedUnreadableTypes: Int
        public var total: Int { paths.count }
        /// The source whose own survey this reads into (its ``SourceSurveyEntry/root``), or nil for
        /// the primary survey, the active profile's.
        public let sourceRoot: String?
        /// Documents in ``paths`` whose content isn't on this disk. A source's reading downloads
        /// them first and leaves them downloaded; the primary survey skips them. Counted only for a
        /// source, whose sheet states it; 0 otherwise.
        public let toDownload: Int
    }

    // MARK: - Working out what to do

    /// The folder a survey covers: the profile's own, `~` expanded, or nil when the profile records
    /// none, which the plan refuses. The plan walks it and the card matches a report's `rootPath`
    /// against it as a string, so both use this one expression.
    public var documentSurveyFolder: URL? {
        filingFolderProfile?.recordedFolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Builds the plan, or says why there is nothing to plan.
    ///
    /// It walks the folder the profile was built from, never the one it is asked about. `root`
    /// is where the request came from (Organize's scope, or the pane's folder), named in the log
    /// when it differs. What a survey learns is keyed relative to the folder it walks and read back
    /// by the profile's folder paths, so any other folder would key the memory wrongly.
    ///
    /// Refuses where a corpus already covers the tree, rather than run for hours and be refused at
    /// the store; the incremental pass is right there. `FilingSurveyStore`'s refusals are the
    /// backstop.
    public func planDocumentSurvey(root requested: URL) async -> Result<DocumentSurveyPlan, DocumentSurveyRefusal> {
        guard !filingSurveyLifecycle.isRunning else { return .failure(.alreadyRunning) }
        guard !restructureLandingInProgress else { return .failure(.landingInProgress) }
        guard let directory = filingProfilesDirectory else { return .failure(.noProfileDirectory) }
        guard filingSnippetExtractor != nil else { return .failure(.noExtractor) }
        guard let profileId = filingProfileDirectoryId
                ?? filingMemory?.profileId ?? filingFolderProfile?.profileId,
              let profile = filingFolderProfile else {
            return .failure(.noProfile)
        }
        // A profile that doesn't say which folder it describes is refused, not guessed at: it
        // decodes as `~`, and reading the whole home folder would key the memory to the wrong tree.
        guard let root = documentSurveyFolder else {
            Logger.shared.warning("Document survey: the filing profile "
                                  + "\(Self.missingFolderPhrase(profile)), so there is no telling "
                                  + "which documents to read. Nothing was surveyed.")
            return .failure(.noRecordedFolder)
        }
        let askedAboutIt = PathBoundary.normalizedRoot(requested.path) == PathBoundary.normalizedRoot(root.path)
        Logger.shared.info("Document survey: planning for \(root.path), the folder this profile was "
                           + "built from" + (askedAboutIt ? "" : " — not \(requested.path), which it "
                                                           + "was asked about"))
        return await planDocumentSurvey(profileId: profileId, root: root, memory: filingMemory,
                                        directory: directory, sourceRoot: nil)
    }

    /// Plans Read Documents for a source's own survey (Google Drive's, say): the tree that survey
    /// was learned from, read into `profiles/<its id>/`, never the active profile.
    ///
    /// `sourceRoot` is the source's ``SourceSurveyEntry/root``. Same walk, refusals and checkpoint
    /// as the primary survey, except that cloud-only documents are counted, since this downloads
    /// them.
    public func planSourceDocumentSurvey(sourceRoot: String) async -> Result<DocumentSurveyPlan, DocumentSurveyRefusal> {
        guard !filingSurveyLifecycle.isRunning else { return .failure(.alreadyRunning) }
        guard let directory = filingProfilesDirectory else { return .failure(.noProfileDirectory) }
        guard filingSnippetExtractor != nil else { return .failure(.noExtractor) }
        guard !isLearningFolders(ofSource: sourceRoot) else { return .failure(.learningFolders) }
        guard let entry = SourceSurveyStore.entry(forRoot: sourceRoot, in: directory),
              let profileId = entry.profileId,
              let profile = sourceSurveyProfile(id: profileId) else {
            return .failure(.noSourceSurvey)
        }
        guard let rootPath = profile.recordedFolderPath else { return .failure(.noRecordedFolder) }
        Logger.shared.info("Document survey: planning for \(rootPath), the source survey '\(profileId)'")
        let planned = await planDocumentSurvey(profileId: profileId,
                                               root: URL(fileURLWithPath: rootPath, isDirectory: true),
                                               memory: sourceSurveyMemory(id: profileId),
                                               directory: directory, sourceRoot: entry.root)
        if case .failure(.alreadySurveyed) = planned { return .failure(.sourceAlreadyRead) }
        return planned
    }

    /// The walk and the count, for whichever survey `profileId` names.
    private func planDocumentSurvey(profileId: String, root: URL, memory: FilingMemory?,
                                    directory: URL, sourceRoot: String?) async -> Result<DocumentSurveyPlan, DocumentSurveyRefusal> {
        // Decoded off the main actor: on a surveyed tree the corpus is megabytes, and every
        // refused start reads it.
        let existing: FilingCorpus?
        switch await Task.detached(priority: .userInitiated, operation: {
            FilingSurveyStore.corpusRead(id: profileId, in: directory)
        }).value {
        case .unreadable: return .failure(.corpusUnreadable)
        case .absent: existing = nil
        case .loaded(let corpus):
            // A corpus with documents means the tree was surveyed. An empty one (left by a refusal
            // or a fresh profile) can be read into.
            guard corpus.isEmpty else { return .failure(.alreadySurveyed) }
            existing = corpus
        }

        // The ask-first every whole-tree pass makes: `~` or a whole volume can be a source.
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

        // **A root that couldn't be listed must never reach a merge.** `buildTree` reports it as
        // one unexplored marker and `flatten` skips it, leaving an empty tree that looks like
        // every document was deleted. The incremental pass has the same guard.
        if Self.isUnreadableRootMarker(walked, root: root) { return .failure(.rootUnreadable) }

        let flattenInput = walked
        let tree = await Task.detached(priority: .userInitiated) { FilingSurvey.flatten(flattenInput) }.value
        // A resumable checkpoint's salt wins over everything. With no corpus and no memory the
        // last branch mints a random salt, and `adoptCheckpoint` would refuse a checkpoint written
        // under another salt as another run's, so a first survey could never be resumed.
        let resumableSalt = DocumentSurveyCheckpointStore.read(id: profileId, in: directory)
            .checkpoint.flatMap { $0.rootPath == root.path ? $0.salt : nil }
        let salt = resumableSalt
            ?? (existing?.salt.isEmpty == false ? existing!.salt
                : (memory?.salt.isEmpty == false ? memory!.salt : Self.newSurveySalt()))
        let isAvailable = documentSurveyIsAvailable
        let (paths, unreadableTypes, toDownload) = await Task.detached(priority: .userInitiated) {
            let paths = FilingSurvey.documentsToRead(tree: tree, corpus: existing, memory: memory)
            return (paths,
                    tree.documents.keys.filter {
                        !FilingSurvey.readableExtensions.contains(($0 as NSString).pathExtension.lowercased())
                    }.count,
                    sourceRoot == nil ? 0
                        : paths.filter { !isAvailable(root.appendingPathComponent($0).path) }.count)
        }.value

        return .success(DocumentSurveyPlan(root: root, paths: paths, tree: tree, salt: salt,
                                           profileId: profileId,
                                           skippedUnreadableTypes: unreadableTypes,
                                           sourceRoot: sourceRoot, toDownload: toDownload))
    }

    /// The unfinished survey on disk that this root could carry on, if any, for the offer card that
    /// asks rather than resuming by itself.
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

    /// The unfinished reading of a source's own survey on disk, for its sheet to say what carrying
    /// on costs.
    public func resumableSourceDocumentSurvey(sourceRoot: String) -> (done: Int, total: Int)? {
        guard let directory = filingProfilesDirectory,
              let profileId = SourceSurveyStore.entry(forRoot: sourceRoot, in: directory)?.profileId,
              let root = sourceSurveyProfile(id: profileId)?.recordedFolderPath,
              case .loaded(let checkpoint) = DocumentSurveyCheckpointStore.read(id: profileId, in: directory),
              checkpoint.rootPath == URL(fileURLWithPath: root, isDirectory: true).path
        else { return nil }
        return checkpoint.progress
    }

    // MARK: - The machine's state, for the run to yield to

    /// What ``DocumentSurveyYield`` decides from. The scans are named here, in rail order, in the
    /// user's words, because the manager is what knows them.
    func documentSurveyConditions() -> DocumentSurveyConditions {
        var scans: [String] = []
        if filingScanLifecycle.isRunning { scans.append("To File") }
        if duplicateScanLifecycle.isRunning { scans.append("Duplicates") }
        if nameScanLifecycle.isRunning { scans.append("Names") }
        // **`filingSurveyLifecycle` is deliberately not here.** `runDocumentSurvey` holds it as
        // its own running flag, so listing it would make the survey yield to itself on the first
        // poll and never read a document. Nothing else can hold it meanwhile:
        // `planDocumentSurvey` and `resurveyFilingMemory` both refuse while it is set.
        _ = filingSurveyLifecycle
        if storageLensLifecycle.isRunning { scans.append("Storage") }
        if automationDryRunLifecycle.isRunning { scans.append("Rules") }
        // Read once, so all three values come from one snapshot.
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

    /// Reads the plan, then writes the corpus and memory once, at the end, for the folder the plan
    /// walked (``DocumentSurveyPlan/root``, the profile's own).
    ///
    /// ## Why the write is at the end
    ///
    /// The memory is a full rebuild (IDF is corpus-wide), and its bytes feed
    /// ``FilingProfileStore/fingerprint(id:in:)``, part of every cached classification's key.
    /// Writing it mid-survey would discard every cached cloud verdict once per checkpoint.
    ///
    /// ## Why the last steps leave this actor
    ///
    /// `merge`, `buildMemory` and `write` over ~11,000 documents would stall the window on the
    /// main actor. All three are pure of `FileManager`, `Date()` and defaults, so they run
    /// detached; only the publication comes back.
    ///
    /// ## Starting over
    ///
    /// `startingOver` is the card's *Start over*: the progress on disk is discarded before the run
    /// is built, so there is nothing to adopt. Otherwise the run adopts the checkpoint, which is
    /// *Resume*. If the progress can't be removed, nothing starts.
    @discardableResult
    public func runDocumentSurvey(plan: DocumentSurveyPlan, startingOver: Bool = false,
                                  now: Date = Date()) async -> Result<DocumentSurveyReport, DocumentSurveyRefusal> {
        let root = plan.root
        // Taken by whichever run starts next, refused or not, so it can't linger and pause a
        // later Start over nobody paused.
        let pauseToCarry = documentSurveyPauseToCarry
        documentSurveyPauseToCarry = nil
        guard !filingSurveyLifecycle.isRunning else { return .failure(.alreadyRunning) }
        guard let directory = filingProfilesDirectory else { return .failure(.noProfileDirectory) }
        guard let extractor = filingSnippetExtractor else { return .failure(.noExtractor) }
        // A learn started after the plan: it would trash the survey this reads into, mid-reading.
        if let source = plan.sourceRoot, isLearningFolders(ofSource: source) { return .failure(.learningFolders) }
        // The current id, asked the way the plan asked it (for a source, the id its entry names
        // now), so a survey learned again or forgotten meanwhile isn't read into.
        let currentId = plan.sourceRoot.map { SourceSurveyStore.entry(forRoot: $0, in: directory)?.profileId }
            ?? (filingProfileDirectoryId ?? filingMemory?.profileId ?? filingFolderProfile?.profileId)
        guard plan.profileId == currentId else {
            Logger.shared.info("Document survey: not started — it was planned for profile "
                               + "'\(plan.profileId)', which this Mac no longer uses")
            return .failure(.profileReplaced)
        }

        if startingOver {
            let dropped = DocumentSurveyCheckpointStore.read(id: plan.profileId, in: directory)
                .checkpoint?.progress
            do {
                try DocumentSurveyCheckpointStore.discard(id: plan.profileId, in: directory)
            } catch {
                Logger.shared.warning("Document survey: not started over — the unfinished progress "
                                      + "could not be removed: \(error.localizedDescription)")
                return .failure(.couldNotDiscardProgress)
            }
            Logger.shared.info("Document survey: starting over — "
                               + (dropped.map { "discarded progress at \($0.done) of \($0.total)" }
                                  ?? "there was no progress on disk"))
        }

        // Logged at every edge, since this runs for hours unwatched and `~/sync-cloud.log` is how
        // the app is debugged. Start, stop and outcome are logged here; pauses by
        // `DocumentSurveyRun`, once per reason rather than per poll. Per-document reads aren't.
        Logger.shared.info("Document survey: starting — \(plan.total) document(s) to read under "
                           + "\(root.lastPathComponent)")
        // Clear the previous run's receipt first: it outranks every card state but `running`, so a
        // stale one would show a finished summary over a run just interrupted.
        documentSurveyReport = nil
        // A waiver is for the run it was given in; a new one starts honouring every pause.
        documentSurveyOverride = DocumentSurveyOverride()
        let epoch = beginScan(\.filingSurveyLifecycle, status: "Reading your documents…")
        documentSurveySourceRoot = plan.sourceRoot
        defer {
            endScan(\.filingSurveyLifecycle)
            documentSurveySourceRoot = nil
        }

        let run = DocumentSurveyRun(
            profileId: plan.profileId, root: root, salt: plan.salt, plan: plan.paths,
            stamps: plan.stamps,
            environment: documentSurveyEnvironment(extractor: extractor,
                                                   fetch: plan.sourceRoot == nil ? nil : sourceDocumentFetch),
            directory: directory)

        // **Set the handle before the first await**, or a Setup Save landing while the checkpoint
        // is adopted finds no run to stop, and the run reads into the profile the Save replaced.
        // Stopped there, it ends before reading anything.
        documentSurveyRun = run
        defer {
            documentSurveyRun = nil
            let waiters = documentSurveyEndWaiters
            documentSurveyEndWaiters = [:]
            for waiter in waiters.values { waiter.resume(returning: true) }
        }

        if let refusal = await run.adoptCheckpoint() {
            switch refusal {
            case .checkpointUnreadable: return .failure(.checkpointUnreadable)
            case .checkpointIsForAnotherRun: return .failure(.checkpointIsForAnotherRun)
            }
        }

        // A Pause carried from the run a profile write stopped
        // (``stopDocumentSurveyBeforeReplacingProfile(savingFolder:)``).
        if pauseToCarry?.standardizedFileURL.path == root.standardizedFileURL.path {
            await run.pause()
            Logger.shared.info("Document survey: starts paused — it was paused when the folder survey "
                               + "it read was replaced")
        }

        let outcome = await run.run()

        // A stopped run keeps its checkpoint and writes nothing. The corpus is only written whole:
        // a partial one would make `surveyedRegion` cover just what was read, and every later
        // survey would skip the rest of the tree for good.
        guard outcome.isComplete else {
            Logger.shared.info("Document survey: stopped at \(outcome.stoppedAt ?? 0) of "
                               + "\(plan.total). Progress is on disk; carrying on reads only the "
                               + "rest.")
            documentSurveyProgress = nil
            // Only a stop made for a profile write has anyone waiting on it.
            if !documentSurveyEndWaiters.isEmpty { return .failure(.stoppedForNewProfile) }
            return .success(DocumentSurveyReport(
                rootPath: root.path,
                documentsRead: outcome.documentsRead, documentsBlank: outcome.documentsBlank,
                documentsUnavailable: outcome.documentsUnavailable,
                foldersLearned: (plan.sourceRoot == nil ? filingMemory : sourceSurveyMemory(id: plan.profileId))?
                    .folders.count ?? 0,
                stoppedAt: outcome.stoppedAt, plannedTotal: plan.total, changed: false))
        }

        _ = updateScan(\.filingSurveyLifecycle, epoch: epoch, status: "Saving what was learned…")

        let tree = plan.tree
        let previousMemory = plan.sourceRoot == nil ? filingMemory : sourceSurveyMemory(id: plan.profileId)
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
            Logger.shared.error("Document survey: every document was read and the artifacts could "
                                + "not be written — \(error.localizedDescription). The checkpoint "
                                + "is kept, so trying again costs the write and not the reading.")
            // The checkpoint is kept, so the next run retries the write without re-reading.
            documentSurveyProgress = nil
            return .failure(.couldNotWrite)
        }

        // **Only after the corpus write.** A crash between the two leaves a checkpoint beside a
        // complete corpus, and the next run finds the tree covered. The other order leaves neither.
        try? DocumentSurveyCheckpointStore.discard(id: profileId, in: directory)

        if let sourceRoot = plan.sourceRoot {
            recordSourceDocumentsRead(sourceRoot: sourceRoot, profileId: profileId,
                                      memory: written?.memory, documentsRead: outcome.documentsRead,
                                      in: directory, now: now)
        } else {
            filingSurveyedAt = now
            if let written, written.changed {
                filingMemory = written.memory
                filingArtifactFingerprint = FilingProfileStore.fingerprint(id: profileId, in: directory)
            }
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
        extractor: @escaping @Sendable (String) async -> String?,
        fetch: (@Sendable (String) async -> Void)?
    ) -> DocumentSurveyRun.Environment {
        // **`shouldPause` must be async.** The run is its own actor and the conditions are
        // `@Published` properties of this one; `MainActor.assumeIsolated` from the run's isolation
        // traps rather than hops. So the closure awaits a hop back here and reads the conditions
        // as one snapshot on the actor that owns them.
        return DocumentSurveyRun.Environment(
            readDocument: extractor,
            isAvailable: documentSurveyIsAvailable,
            fetch: fetch,
            shouldPause: { [weak self] in
                await self?.documentSurveyPause()
            },
            whilePaused: {
                // Polled, not pushed: a second's delay is invisible, and a poll can't miss an edge
                // the way a notification can.
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

    /// Why the running survey should not read now, with *Resume now*'s waiver applied.
    private func documentSurveyPause() -> DocumentSurveyPause? {
        documentSurveyOverride.pause(for: documentSurveyConditions())
    }

    /// Resume, and *Resume now*: one verb, two pauses.
    ///
    /// Paused by the person, it undoes their Pause and nothing more. A machine reason behind it was
    /// never on the card, so it isn't waived for them; the card then shows it, with its own
    /// *Resume now*. Paused for the machine, it reads through every cause in force now, until that
    /// cause clears (``DocumentSurveyOverride``).
    public func resumeDocumentSurvey() async {
        guard let run = documentSurveyRun else { return }
        if await run.isPausedByUser {
            await run.resume()
            return
        }
        let conditions = documentSurveyConditions()
        guard let shown = DocumentSurveyYield.pause(for: conditions) else { return }
        documentSurveyOverride.waive(conditions)
        Logger.shared.info("Document survey: Resume now — reading through “\(shown.sentence)” "
                           + "until it clears; anything new still pauses it.")
    }

    /// Stops the running survey at the next document boundary, keeping its progress.
    public func stopDocumentSurvey() async {
        await documentSurveyRun?.stop()
    }

    /// What ``stopDocumentSurveyBeforeReplacingProfile(savingFolder:)`` did.
    public enum DocumentSurveyStop: Equatable, Sendable {
        /// Nothing needed stopping: no run, a run the write can't strand, or one that had already
        /// read everything (its corpus is written, and the write carries it).
        case nothingStopped
        /// Stopped with documents still to read; the folder it read, for the caller to start again.
        case stopped(URL)
        /// Still inside one document when the wait ran out. The stop is withdrawn and the run reads
        /// on, so nothing is stranded; **the write must not go ahead over it.**
        case stillReading
    }

    /// Stops the running survey before a profile write replaces the profile it reads, and waits
    /// for it to end.
    ///
    /// A run reads into the profile it was planned for, so left running it would finish hours later
    /// into the replaced one. Stopped first, its progress is on disk before the write carries it
    /// across, and the restarted run reads only what is left.
    ///
    /// Nothing is stopped when the write can't replace the active profile (a hand-built one stays
    /// in use, and so does its reading), nor while a reorganization lands, which the write refuses.
    ///
    /// A Pause the person gave is carried over when the write is of the same folder: the restarted
    /// run starts paused. The wait is bounded (``documentSurveyStopWait``): a stop lands between
    /// documents, and a document whose text never comes would otherwise hold the Save for good.
    ///
    /// - Parameter savingFolder: the folder the write is of.
    public func stopDocumentSurveyBeforeReplacingProfile(savingFolder: URL) async -> DocumentSurveyStop {
        // A source's reading reads into its own survey, which no profile write replaces.
        guard let run = documentSurveyRun, documentSurveySourceRoot == nil,
              let directory = filingProfilesDirectory,
              !restructureLandingInProgress,
              FilingProfileStore.mayRepoint(activeId: FilingProfileStore.activeProfileId(in: directory),
                                            in: directory) else { return .nothingStopped }
        let root = run.root
        let sameFolder = root.standardizedFileURL.resolvingSymlinksInPath().path
            == savingFolder.standardizedFileURL.resolvingSymlinksInPath().path
        let pausedByPerson = await run.stopReportingUserPause()
        // Checked again after the hop: a run that ended during it has already released its waiters.
        if documentSurveyRun === run {
            let id = UUID()
            let limit = documentSurveyStopWait
            let ended = await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
                documentSurveyEndWaiters[id] = waiter
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: limit)
                    self?.documentSurveyEndWaiters.removeValue(forKey: id)?.resume(returning: false)
                }
            }
            if !ended {
                await run.withdrawStop()
                Logger.shared.warning("Document survey: still reading one document after "
                                      + "\(limit) — left reading, and the new folder survey was not "
                                      + "written over it")
                return .stillReading
            }
        }
        let unfinished = documentSurveyReport?.isComplete != true
        documentSurveyPauseToCarry = unfinished && pausedByPerson && sameFolder ? root : nil
        Logger.shared.info("Document survey: stopped so a new folder survey can replace the one it "
                           + "reads" + (!unfinished ? " — it had already read everything"
                                        : sameFolder ? " — it carries on in the new one"
                                                       + (pausedByPerson ? ", paused as it was" : "")
                                        : " — the new one is of another folder, so its progress "
                                          + "stays with the one it read"))
        return unfinished ? .stopped(root) : .nothingStopped
    }
}
