import Events
import Foundation

/// Re-deriving the filing memory from the tree as it stands now.
///
/// The scan learns the folder list on every run, so a new folder is a candidate at once. What it
/// can't learn is what a folder is for: that comes from the memory, and a folder created after the
/// last survey would rank on its name alone. This pass learns it, reading only what changed. See
/// ``FilingSurvey`` for why only extraction is expensive and how the corpus avoids repeating it.
extension FileSyncManager {

    /// What a re-survey did, in the terms the user cares about.
    public struct FilingSurveyReport: Sendable, Equatable {
        /// Folders that were new, or whose contents had moved, since the memory last learned them.
        public let foldersChanged: Int
        /// Documents whose page 1 was actually read, net of any the provider withdrew mid-batch:
        /// those were chosen but never stamped, and counting them would credit work not done.
        public let documentsRead: Int
        /// Documents that had only moved, so their tokens travelled with them instead.
        public let documentsRelocated: Int
        /// Documents that are no longer in the tree and have stopped counting.
        public let documentsDropped: Int
        /// Documents that needed reading but are not downloaded, so a later survey will do it.
        /// Includes those withdrawn mid-batch: availability is asked before a batch that takes
        /// minutes, and a document evicted in between ends in exactly this state.
        public let documentsUnavailable: Int
        /// Folders with learned content afterwards.
        public let foldersLearned: Int
        /// False when the rebuild came out identical — see ``FilingSurveyStore/write(corpus:memory:previousMemory:id:in:root:now:)``.
        public let changed: Bool

        public static let none = FilingSurveyReport(foldersChanged: 0, documentsRead: 0,
                                                    documentsRelocated: 0, documentsDropped: 0,
                                                    documentsUnavailable: 0, foldersLearned: 0,
                                                    changed: false)

        /// One line, honest at both ends: the case that costs nothing says so, and a pass that left
        /// work undone says that too rather than reporting only what it managed.
        public var summary: String {
            guard changed || documentsRead > 0 || documentsUnavailable > 0 else {
                return "Everything learned here is up to date."
            }
            var parts = ["\(foldersChanged) folder\(foldersChanged == 1 ? "" : "s") changed"]
            parts.append("\(documentsRead) document\(documentsRead == 1 ? "" : "s") read")
            if documentsRelocated > 0 { parts.append("\(documentsRelocated) followed a move") }
            if documentsDropped > 0 { parts.append("\(documentsDropped) left the tree") }
            if documentsUnavailable > 0 { parts.append("\(documentsUnavailable) not downloaded yet") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Why a profile has no ``FolderProfile/recordedFolderPath``, as the middle of a log sentence:
    /// it records no folder, or it records a relative one. Refresh and the document survey both
    /// refuse such a profile, and say so in these words.
    static func missingFolderPhrase(_ profile: FolderProfile?) -> String {
        profile?.recordedRoot.map { "names “\($0)” as its folder, which is not an absolute path" }
            ?? "does not record which folder it describes"
    }

    /// Re-derives the filing memory, reading only what changed since the last survey.
    ///
    /// It surveys the folder the profile was built from, never the one it is asked about. `root` is
    /// where the request came from (Organize passes the pane's source); it is only named in the log
    /// when it differs, and decides whether `taxonomy` describes the profile's folder.
    ///
    /// `taxonomy` is the walk the caller already did: the Filing scan walks the whole provider, so
    /// handing it over makes the staleness pass free. Omit it, or pass a walk of another folder, and
    /// the survey walks for itself.
    ///
    /// Returns ``FilingSurveyReport/none`` when there are no filing artifacts to update or no
    /// extractor: the ordinary state for a tree never surveyed, not an error. `now` stamps the
    /// corpus's `surveyedAt`, injected rather than read from a clock (`docs/flaky-tests.md`, "Tests
    /// racing a real-time window"), and is published as ``FileSyncManager/filingSurveyedAt`` once
    /// the write lands.
    @discardableResult
    public func resurveyFilingMemory(root requested: URL, taxonomy: [FileNode]? = nil,
                                     now: Date = Date()) async -> FilingSurveyReport {
        guard !filingSurveyLifecycle.isRunning else { return .none }
        // A survey a cut-off re-derive left behind is being carried in, off the main actor, just
        // after launch (`finishInterruptedSurveyReplay`). A Refresh then could read the corpus as
        // absent while the replay writes one, then write over it.
        guard surveyReplaysInFlight == 0 else {
            Logger.shared.info("Refresh refused — a survey left by an earlier reorganisation is still being "
                + "read back; run it again in a moment")
            return .none
        }
        // The other direction of the landing guard: a landing refuses to start while this runs,
        // and this must not start while a landing is suspended in its re-derive, or it walks a
        // half-reshaped tree and writes memory and fingerprint over the landing's own writes. One
        // mutator at a time, in both orders.
        guard !restructureLandingInProgress else {
            Logger.shared.info("Refresh refused — a reorganisation is landing; "
                + "run it again once the landing finishes")
            return .none
        }
        guard let directory = filingProfilesDirectory else {
            Logger.shared.info("No filing profile directory — nothing to re-survey")
            return .none
        }
        // A survey with nothing to read can't learn anything, and "0 documents read" would look
        // like a tree that hadn't changed.
        guard let extractor = filingSnippetExtractor else {
            Logger.shared.warning("No content extractor — what was learned cannot be refreshed")
            return .none
        }
        // The folder the artifacts were read from wins over the `profileId` field inside them.
        // ``FilingProfileStore/active(in:)`` decides identity by directory, and the app hands it over
        // as ``FileSyncManager/filingProfileDirectoryId``, the key of the roster, tag store and
        // fingerprint. The field decodes to `"default"` when a hand-built profile omits it, and this
        // id picks the corpus read, the memory overwritten, the fingerprint republished and the
        // files the refusals below stat; keyed on the field, a tree read from `work/` would be
        // merged into `default/` and turn the verdict cache off. The field is only the fallback
        // for a caller that never sets the directory id (tests, a non-app host).
        guard let profileId = filingProfileDirectoryId
                ?? filingMemory?.profileId ?? filingFolderProfile?.profileId else {
            Logger.shared.info("No filing profile on this machine — nothing to re-survey")
            return .none
        }
        // The profile's own folder, whatever the pane shows. The corpus and memory are keyed by
        // paths relative to that folder, so surveying any other folder would read every learned
        // document as gone, read its own in their place and record it as the memory's root: with
        // the left source on Home, one click would rebuild the `~/Documents` memory from `~`.
        // Restructure's re-derive walks `profile.root` for the same reason.
        //
        // A profile that records no folder is refused, not guessed at: a file without `root`
        // decodes as `~`, and surveying the whole home folder is the same harm. So is a root that
        // isn't absolute once `~` is expanded, which would resolve against the working directory.
        guard let folder = filingFolderProfile?.recordedFolderPath else {
            Logger.shared.warning("Refresh: the filing profile "
                                  + "\(Self.missingFolderPhrase(filingFolderProfile)), so there is no "
                                  + "telling which tree its memory belongs to. Nothing was "
                                  + "re-surveyed, and both files were left exactly as they are.")
            return .none
        }
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        // Spelling only, no disk: this runs on the main actor and decides only a log line and
        // whether a handed-over walk is of this folder, so a miss costs a walk, never a wrong answer.
        let askedAboutIt = PathBoundary.normalizedRoot(requested.path) == PathBoundary.normalizedRoot(root.path)
        Logger.shared.info("Refresh: surveying \(root.path), the folder this profile was built from"
                           + (askedAboutIt ? "" : " — not \(requested.path), which it was asked about"))

        let epoch = beginScan(\.filingSurveyLifecycle, status: "Looking for new folders…")
        defer { endScan(\.filingSurveyLifecycle) }

        let walked: [FileNode]
        if let taxonomy, askedAboutIt {
            walked = taxonomy
        } else {
            // The same ask-first the other whole-tree passes make: Refresh is one click, and a
            // source can be `~` or a whole volume. Reuses `.filing`, since the memory belongs to the
            // Filing feature and the prompt should name what the user knows.
            let probe = NodeBudget(wholeTreeProbeBudget)
            var tree = await Self.buildTree(url: root, sortOption: .name,
                                            fileManager: fileManager, maxDepth: nil, budget: probe)
            if Task.isCancelled { return .none }
            if probe.didStopADescent {
                let preflight = LargeWalkPreflight(pass: .filing, rootPath: root.path,
                                                   probeLimit: probe.limit)
                guard largeWalkConfirmer(preflight) else {
                    Logger.shared.info("Refresh: “\(preflight.rootName)” holds more than \(preflight.probeLimit) entries — not re-surveyed")
                    return .none
                }
                tree = await Self.buildTree(url: root, sortOption: .name,
                                            fileManager: fileManager, maxDepth: nil)
                if Task.isCancelled { return .none }
            }
            walked = tree
        }
        if Task.isCancelled { return .none }
        // A root that couldn't be listed must never reach the merge. `buildTree` reports a
        // permission-denied or briefly unreachable root as one unexplored marker, which `flatten`
        // skips, leaving an empty tree that looks like every document was deleted. The merge would
        // drop the whole corpus and `write` would replace both artifacts with empty ones: months of
        // page-1 reads gone, with no error. Nor would a second click recover it, since the surveyed
        // region is derived from the emptied corpus and the next run would survey the whole tree
        // unscoped. The rename pass, risky-name scan and name normalizer carry the same guard.
        if Self.isUnreadableRootMarker(walked, root: root) {
            Logger.shared.warning("Refresh: could not read \(root.lastPathComponent) — "
                                  + "permission denied or unavailable. Nothing was re-surveyed, and "
                                  + "the memory already on disk was left exactly as it was.")
            return .none
        }
        let previousMemory = filingMemory
        let isAvailable = filingDocumentIsAvailable
        let witness = filingResurveyOffMainWitness
        // The heavy steps run off this actor, in two hops with the snippet read between them:
        // flattening, decoding a corpus of megabytes and building the memory can hold the window for
        // over a second. Every refusal is in the first hop, in order, and neither hop touches `self`.
        guard let prepared = await Task.detached(priority: .userInitiated, operation: {
            let prepared = Self.prepareResurvey(walked: walked, root: root, previousMemory: previousMemory,
                                                profileId: profileId, directory: directory,
                                                isAvailable: isAvailable)
            witness?()   // after the decode, so a test sees where the heavy step ran, not just a hop
            return prepared
        }).value else { return .none }
        if Task.isCancelled { return .none }
        let tree = prepared.tree
        let salt = prepared.salt
        let toRead = prepared.toRead
        let stale = prepared.stale
        let unavailable = prepared.unavailable
        let relocated = prepared.relocated
        let dropped = prepared.dropped

        var read: [String: FilingCorpusDocument] = [:]
        // Documents chosen for this batch that stopped being downloaded before they were stamped.
        // Declared here because the report, built from the pre-batch counts, is corrected by it.
        var evictedMidRead = 0
        if !toRead.isEmpty {
            updateScan(\.filingSurveyLifecycle, epoch: epoch,
                       status: "Reading \(toRead.count) new or changed document\(toRead.count == 1 ? "" : "s")…")
            let absolute = toRead.map { root.appendingPathComponent($0).path }
            let text = await Self.extractSnippets(for: absolute, using: extractor)
            if Task.isCancelled { return .none }
            for path in toRead {
                guard let stamp = tree.documents[path] else { continue }
                // Absent text is a document that was opened and gave up nothing, recorded as blank
                // so the next survey doesn't open it again.
                let page = text[root.appendingPathComponent(path).path] ?? ""
                // A blank stamp is permanent, so only a file that was there earns it. A file the
                // provider evicts mid-batch extracts as `""`, and its stamp is keyed on size and
                // mtime, neither of which moves when the content returns, so the write-off would
                // never be undone. Availability is re-asked for the blank ones only (one lstat each,
                // and blanks are few); a document that produced text plainly was on disk.
                if page.isEmpty,
                   !isAvailable(root.appendingPathComponent(path).path) {
                    evictedMidRead += 1
                    continue
                }
                read[path] = FilingSurvey.document(fromPage1: page, stamp: stamp, salt: salt)
            }
            if evictedMidRead > 0 {
                Logger.shared.info("\(evictedMidRead) document(s) stopped being downloaded while the "
                                   + "survey was reading — not stamped, left for a later survey")
            }
        }

        updateScan(\.filingSurveyLifecycle, epoch: epoch, status: "Saving what was learned…")
        let corpus = prepared.corpus
        let readDocuments = read
        let rootPath = root.path
        let memory: FilingMemory
        let wrote: Bool
        let fingerprint: String?
        do {
            (memory, wrote, fingerprint) = try await Task.detached(priority: .userInitiated) {
                let merged = FilingSurvey.merge(corpus: corpus, tree: tree, read: readDocuments)
                let memory = FilingSurvey.buildMemory(corpus: merged, folderModified: tree.folders,
                                                      profileId: profileId)
                witness?()   // after the build: the step that held the window for over a second
                let wrote = try FilingSurveyStore.write(corpus: merged, memory: memory,
                                                        previousMemory: previousMemory, id: profileId,
                                                        in: directory, root: rootPath, now: now)
                // Taken here, from the bytes just written, rather than back on the main actor.
                return (memory, wrote,
                        wrote ? FilingProfileStore.fingerprint(id: profileId, in: directory) : nil)
            }.value
        } catch {
            Logger.shared.error("Couldn't save what the re-survey learned: \(error.localizedDescription)")
            return .none
        }
        // The stamp moves even when nothing else did: "last surveyed" says when the survey looked,
        // and a failed write already returned above.
        filingSurveyedAt = now
        if wrote {
            // Publishing the memory drops the router's prepared index, so the next scan builds it
            // from the folders learned here. The fingerprint moves with the bytes, so cached
            // classifications never replay answers composed against the old tree.
            filingMemory = memory
            filingArtifactFingerprint = fingerprint
        }
        // Both counts are corrected for mid-read evictions, in opposite directions: they come
        // from `toRead`, fixed before the batch ran, so a document withdrawn mid-batch would count
        // as read and not as unavailable, and `summary` would report a survey that left work
        // undone as one that covered the tree.
        let report = FilingSurveyReport(foldersChanged: stale.count,
                                        documentsRead: toRead.count - evictedMidRead,
                                        documentsRelocated: relocated,
                                        documentsDropped: max(0, dropped),
                                        documentsUnavailable: unavailable + evictedMidRead,
                                        foldersLearned: memory.folders.count, changed: wrote)
        Logger.shared.info("Refresh finished — \(report.summary) "
                           + "\(report.foldersLearned) folder(s) now have learned content.")
        filingSurveyReport = report
        completeScan(\.filingSurveyLifecycle, root: root)
        return report
    }

    /// What the first hop of ``resurveyFilingMemory(root:taxonomy:now:)`` hands back: the walk
    /// flattened, the corpus to merge into, and what to read.
    struct ResurveyPreparation: Sendable {
        let tree: FilingSurvey.Tree
        let stale: Set<String>
        let corpus: FilingCorpus
        let salt: String
        let toRead: [String]
        let unavailable: Int
        let relocated: Int
        let dropped: Int
    }

    /// The re-survey's first hop, off the main actor: flatten, decode the corpus, decide what to
    /// read. nil is a refusal, already logged (an unreadable memory or corpus, or a folder with no
    /// documents while the corpus remembers some), and nothing has been written.
    nonisolated static func prepareResurvey(walked: [FileNode], root: URL,
                                            previousMemory: FilingMemory?, profileId: String,
                                            directory: URL,
                                            isAvailable: (String) -> Bool) -> ResurveyPreparation? {
        let tree = FilingSurvey.flatten(walked)
        let stale = FilingSurvey.staleFolders(tree: tree, memory: previousMemory)

        // The salt binds the corpus to the memory: every stored identifier is hashed under it, so a
        // corpus under one salt can't contribute to a memory under another. Prefer what is on disk,
        // in that order, and mint one only for a tree that has neither.
        //
        // An unreadable corpus or memory must not be treated as absent. Absent means "never
        // surveyed", where starting empty is right; unreadable says nothing about the tree, and
        // starting empty would merge whatever this pass read into nothing and write it over
        // megabytes of learned content (likely with the display asleep or files offloaded), and
        // the moved fingerprint would drop every cached classification. Refusing costs a survey;
        // continuing costs the history. The file is left as it is, to inspect or remove by hand.
        //
        // The memory needs its own check: `FilingProfileStore.decode` answers nil for an unreadable
        // `filing-memory.json` as for an absent one, and an atomic write needs permission only on
        // the directory, so `write` would replace a file this process never read. Asked only when
        // nothing was loaded, so an ordinary launch pays nothing.
        if previousMemory == nil,
           FilingProfileStore.isPresentButUnreadable(
               at: FilingSurveyStore.memoryURL(id: profileId, in: directory)) {
            Logger.shared.warning("Refresh: filing-memory.json is on disk but could not be "
                                  + "read, so this pass would have written a rebuilt memory over a "
                                  + "file it never opened. Nothing was re-surveyed and both files "
                                  + "were left exactly as they are — move filing-memory.json aside "
                                  + "to rebuild it from scratch.")
            return nil
        }

        let existing: FilingCorpus?
        switch FilingSurveyStore.corpusRead(id: profileId, in: directory) {
        case .unreadable:
            Logger.shared.warning("Refresh: filing-corpus.json is on disk but could not be "
                                  + "read, so this pass would have started from an empty corpus and "
                                  + "written the result over what has been learned. Nothing was "
                                  + "re-surveyed and both files were left exactly as they are — "
                                  + "move filing-corpus.json aside to survey from scratch.")
            return nil
        case .absent:
            existing = nil
        case .loaded(let corpus):
            existing = corpus
        }
        // A folder with no documents at all is not evidence that every one was deleted. The guard
        // above catches a root that couldn't be listed; this one a root listed empty, which merges
        // into the same harm. The likeliest cause is iCloud's Desktop & Documents being turned
        // off, which leaves a new, empty `~/Documents` in place of the tree. A tree whose documents
        // really were all deleted is refused too, which costs a click.
        if tree.documents.isEmpty, let existing, !existing.isEmpty {
            Logger.shared.warning("Refresh: \(root.path) holds no documents, while what was learned "
                                  + "there remembers \(existing.documents.count). Nothing was "
                                  + "re-surveyed, and both files were left exactly as they are.")
            return nil
        }
        let salt = existing?.salt.isEmpty == false ? existing!.salt
            : (previousMemory?.salt.isEmpty == false ? previousMemory!.salt : newSurveySalt())
        var corpus = existing ?? FilingCorpus(profileId: profileId, salt: salt)
        if corpus.salt != salt {
            // A corpus whose salt disagrees with the memory's would contribute identifiers nothing
            // can match. Start it again rather than mix two hash spaces.
            Logger.shared.warning("Filing corpus salt does not match the memory's — rebuilding it")
            corpus = FilingCorpus(profileId: profileId, salt: salt)
        }

        // Name what was left outside the survey's scope. A branch never surveyed is skipped on
        // purpose (``FilingSurvey/surveyedRegion(corpus:memory:)``), and a survey reporting only
        // what it read looks like one that covered the tree. Named at the top level, the
        // granularity a person can act on.
        let region = FilingSurvey.surveyedRegion(corpus: corpus, memory: previousMemory)
        if !region.isEmpty {
            let outside = Set(tree.documents.keys
                .filter { FilingSurvey.readableExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .filter { !FilingSurvey.isInScope($0, region: region) }
                .map { $0.split(separator: "/").first.map(String.init) ?? "" })
            if !outside.isEmpty {
                Logger.shared.info("Outside the surveyed region, so not read: "
                                   + outside.sorted().joined(separator: ", ")
                                   + " — nothing has ever been surveyed there")
            }
        }
        let candidates = FilingSurvey.documentsToRead(tree: tree, corpus: corpus,
                                                      memory: previousMemory)
        let toRead = candidates.filter { isAvailable(root.appendingPathComponent($0).path) }
        let unavailable = candidates.count - toRead.count
        if unavailable > 0 {
            // Named rather than folded into the "read" count: a survey that reports only what it
            // managed reads as complete when it wasn't.
            Logger.shared.info("\(unavailable) document(s) are not downloaded — left for a later survey")
        }
        let relocated = FilingSurvey.relocations(tree: tree, corpus: corpus).count
        // The predicate `merge` and `relocations` decide by, so the report can't claim a drop the
        // merge didn't make: a document under a folder the walk never entered is not dropped.
        let dropped = corpus.documents.keys.filter { tree.showsGone($0) }.count - relocated
        return ResurveyPreparation(tree: tree, stale: stale, corpus: corpus, salt: salt,
                                   toRead: toRead, unavailable: unavailable, relocated: relocated,
                                   dropped: dropped)
    }

    /// A fresh salt for a tree that has never been surveyed. 16 bytes of hex, the same shape the
    /// offline builder mints.
    nonisolated static func newSurveySalt() -> String {
        HexEncoding.string((0..<16).map { _ in UInt8.random(in: 0...255) })
    }
}
