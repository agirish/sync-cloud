import Events
import Foundation

/// Re-deriving the filing memory from the tree as it stands now.
///
/// The scan already learns the folder *list* on every run — it walks the provider root and hands the
/// result to the router, so a folder created five minutes ago is a candidate destination
/// immediately. What it could not learn was what that folder is *for*: the memory was a static
/// artifact produced offline, and a folder created after that survey ranked on its name alone.
///
/// This closes it, and the cost is the point. See ``FilingSurvey`` for why only extraction is
/// expensive and how the corpus keeps it from being repeated.
extension FileSyncManager {

    /// What a re-survey did, in the terms the user cares about.
    public struct FilingSurveyReport: Sendable, Equatable {
        /// Folders that were new, or whose contents had moved, since the memory last learned them.
        public let foldersChanged: Int
        /// Documents whose page 1 was actually read. **Net of anything the provider withdrew
        /// part-way through the batch** — those were chosen for reading and never stamped, so
        /// counting them here would credit the survey with work it did not do.
        public let documentsRead: Int
        /// Documents that had only moved, so their tokens travelled with them instead.
        public let documentsRelocated: Int
        /// Documents that are no longer in the tree and have stopped counting.
        public let documentsDropped: Int
        /// Documents that needed reading but are not downloaded, so a later survey will do it.
        /// **Includes the ones withdrawn part-way through the batch**: availability is asked
        /// before the batch and the batch takes minutes, and a document evicted in between is in
        /// exactly this state by the time the pass ends.
        public let documentsUnavailable: Int
        /// Folders with learned content afterwards.
        public let foldersLearned: Int
        /// False when the rebuild came out identical — see ``FilingSurveyStore/write(corpus:memory:previousMemory:id:in:root:now:)``.
        public let changed: Bool

        public static let none = FilingSurveyReport(foldersChanged: 0, documentsRead: 0,
                                                    documentsRelocated: 0, documentsDropped: 0,
                                                    documentsUnavailable: 0, foldersLearned: 0,
                                                    changed: false)

        /// One line, and honest about both ends of it: the case that costs nothing says so, and the
        /// case that left work undone says that too rather than reporting only what it managed.
        public var summary: String {
            guard changed || documentsRead > 0 || documentsUnavailable > 0 else {
                return "Folder memory is up to date."
            }
            var parts = ["\(foldersChanged) folder\(foldersChanged == 1 ? "" : "s") changed"]
            parts.append("\(documentsRead) document\(documentsRead == 1 ? "" : "s") read")
            if documentsRelocated > 0 { parts.append("\(documentsRelocated) followed a move") }
            if documentsDropped > 0 { parts.append("\(documentsDropped) left the tree") }
            if documentsUnavailable > 0 { parts.append("\(documentsUnavailable) not downloaded yet") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Re-derives the filing memory for `root`, reading only what changed since the last survey.
    ///
    /// `taxonomy` is the walk the caller already did — the Filing scan walks the whole provider, so
    /// handing that array over makes the staleness pass cost **nothing at all**. Omit it and the
    /// survey walks for itself.
    ///
    /// Returns ``FilingSurveyReport/none`` when the machine has no filing artifacts to update or no
    /// extractor to read with: both are the ordinary state for anyone whose tree was never surveyed,
    /// and neither is an error.
    /// `now` is the instant the survey stamps the corpus's `surveyedAt` with — injected, not read
    /// from a clock (`docs/flaky-tests.md` mechanism 5), and published as
    /// ``FileSyncManager/filingSurveyedAt`` when the write lands.
    @discardableResult
    public func resurveyFilingMemory(root: URL, taxonomy: [FileNode]? = nil,
                                     now: Date = Date()) async -> FilingSurveyReport {
        guard !filingSurveyLifecycle.isRunning else { return .none }
        guard let directory = filingProfilesDirectory else {
            Logger.shared.info("No filing profile directory — nothing to re-survey")
            return .none
        }
        // A survey with nothing to read cannot learn anything, and reporting "0 documents read" as
        // success would be indistinguishable from a tree that genuinely had not changed.
        guard let extractor = filingSnippetExtractor else {
            Logger.shared.warning("No content extractor — the folder memory cannot be re-surveyed")
            return .none
        }
        // **The folder the artifacts were read from wins over the field inside them.**
        // ``FilingProfileStore/active(in:)`` decides identity by directory and logs the
        // disagreement; the app hands that id over as ``FileSyncManager/filingProfileDirectoryId``
        // and already keys the roster, the tag store and the fingerprint on it. This pass used to
        // key on `profileId` — a field that decodes to `"default"` when a hand-built profile simply
        // omits it — and that value drives BOTH ends of the pass: the corpus it reads, the memory
        // it overwrites, and the fingerprint it republishes. A tree read from `work/` therefore had
        // its re-survey merged into `default/`'s corpus and written there, where nothing reads it,
        // while the fingerprint was rehashed against that folder and turned the verdict cache off
        // for every file. The corpus and memory refusals below are keyed on it too, so they stat
        // the wrong files, find nothing, and wave the pass through.
        //
        // The field remains the fallback, for a caller that never set the directory id — every test
        // predating this, and any future non-app host.
        guard let profileId = filingProfileDirectoryId
                ?? filingMemory?.profileId ?? filingFolderProfile?.profileId else {
            Logger.shared.info("No filing profile on this machine — nothing to re-survey")
            return .none
        }

        let epoch = beginScan(\.filingSurveyLifecycle, status: "Looking for new folders…")
        defer { endScan(\.filingSurveyLifecycle) }

        let walked: [FileNode]
        if let taxonomy {
            walked = taxonomy
        } else {
            // **The same ask-first the other whole-tree passes make.** "Update folder memory" is
            // one click in Organize, and the sidebar has made promoting `~` or a whole volume to
            // a source a one-click act too — this was the one Organize-reachable whole-tree walk
            // left unbounded after the four gates landed. Reuses `.filing`: the memory belongs to
            // the Filing feature, and the prompt should name what the user knows.
            let probe = NodeBudget(wholeTreeProbeBudget)
            var tree = await Self.buildTree(url: root, sortOption: .name,
                                            fileManager: fileManager, maxDepth: nil, budget: probe)
            if Task.isCancelled { return .none }
            if probe.didStopADescent {
                let preflight = LargeWalkPreflight(pass: .filing, rootPath: root.path,
                                                   probeLimit: probe.limit)
                guard largeWalkConfirmer(preflight) else {
                    Logger.shared.info("Folder memory: “\(preflight.rootName)” holds more than \(preflight.probeLimit) entries — not re-surveyed")
                    return .none
                }
                tree = await Self.buildTree(url: root, sortOption: .name,
                                            fileManager: fileManager, maxDepth: nil)
                if Task.isCancelled { return .none }
            }
            walked = tree
        }
        if Task.isCancelled { return .none }
        // **A root that could not be listed must never reach the merge.** `buildTree` reports a
        // permission-denied or briefly-unreachable root as a single unexplored marker; `flatten`
        // skips it, and what comes out the other side is an EMPTY tree — indistinguishable from a
        // tree whose every document was deleted. The merge would then drop the whole corpus, and
        // `write` would atomically replace both artifacts with empty ones and publish them. That is
        // months of page-1 reads gone, top-1 routing back to a fraction of what it was, and no
        // error anywhere: the pass reports "0 documents read" and looks like an unchanged tree.
        //
        // Recovery is not a second click either — the surveyed *region* is derived from the corpus
        // that was just emptied, so the next run would re-survey the entire tree unscoped,
        // including branches the original survey deliberately left out.
        //
        // The rename pass, the risky-name scan and the name normalizer have all carried this guard
        // since they were written. This one writes a file, and did not.
        if Self.isUnreadableRootMarker(walked, root: root) {
            Logger.shared.warning("Folder memory: could not read \(root.lastPathComponent) — "
                                  + "permission denied or unavailable. Nothing was re-surveyed, and "
                                  + "the memory already on disk was left exactly as it was.")
            return .none
        }
        let tree = FilingSurvey.flatten(walked)
        let previousMemory = filingMemory
        let stale = FilingSurvey.staleFolders(tree: tree, memory: previousMemory)

        // The salt binds the corpus to the memory: every stored identifier is hashed under it, so a
        // corpus written under one salt cannot contribute to a memory written under another. Prefer
        // what is already on disk, in that order, and mint one only for a tree that has neither.
        // **An unreadable corpus must not be treated as an absent one.** Absent means "never
        // surveyed" and starting from empty is right; unreadable says nothing about the tree, and
        // starting from empty there means this pass merges whatever it happened to read into
        // nothing and writes the result over the memory. With the display asleep or files
        // offloaded that is a near-empty memory over megabytes of learned content, and the moved
        // fingerprint throws away every cached classification with it — the same harm the
        // unreadable-ROOT guard above refuses, arriving through the corpus door.
        //
        // Refusing costs a survey; continuing costs the survey history. The file itself is left
        // exactly as it is, so it can be inspected or removed by hand.
        // **The same refusal for the memory, which reaches the merge as a plain nil.**
        // `FilingProfileStore.decode` answers nil for an unreadable `filing-memory.json` exactly as
        // it does for an absent one, so `previousMemory` is nil, `memory != previousMemory` is
        // trivially true, and `write` atomically replaces a file this process never read — an
        // atomic write needs permission on the DIRECTORY, not on the file, so the bytes are
        // destroyed rather than protected.
        //
        // Mitigated in substance and still refused: the fingerprint already returns nil for an
        // unreadable component so the cache is off, and a readable corpus makes the rebuild
        // faithful — but a read failure is not evidence about what the file holds, which is the
        // whole law the corpus guard above states. Asked only when nothing was loaded, so an
        // ordinary launch pays nothing for it.
        if previousMemory == nil,
           FilingProfileStore.isPresentButUnreadable(
               at: FilingSurveyStore.memoryURL(id: profileId, in: directory)) {
            Logger.shared.warning("Folder memory: filing-memory.json is on disk but could not be "
                                  + "read, so this pass would have written a rebuilt memory over a "
                                  + "file it never opened. Nothing was re-surveyed and both files "
                                  + "were left exactly as they are — move filing-memory.json aside "
                                  + "to rebuild it from scratch.")
            return .none
        }

        let existing: FilingCorpus?
        switch FilingSurveyStore.corpusRead(id: profileId, in: directory) {
        case .unreadable:
            Logger.shared.warning("Folder memory: filing-corpus.json is on disk but could not be "
                                  + "read, so this pass would have started from an empty corpus and "
                                  + "written the result over what has been learned. Nothing was "
                                  + "re-surveyed and both files were left exactly as they are — "
                                  + "move filing-corpus.json aside to survey from scratch.")
            return .none
        case .absent:
            existing = nil
        case .loaded(let corpus):
            existing = corpus
        }
        let salt = existing?.salt.isEmpty == false ? existing!.salt
            : (previousMemory?.salt.isEmpty == false ? previousMemory!.salt : Self.newSurveySalt())
        var corpus = existing ?? FilingCorpus(profileId: profileId, salt: salt)
        if corpus.salt != salt {
            // A corpus whose salt disagrees with the memory's would silently contribute identifiers
            // nothing can match. Start it again rather than mixing two hash spaces.
            Logger.shared.warning("Filing corpus salt does not match the memory's — rebuilding it")
            corpus = FilingCorpus(profileId: profileId, salt: salt)
        }

        // **Say what was left outside the survey's scope, by name.** A branch nothing was ever
        // surveyed in is skipped deliberately (see ``FilingSurvey/surveyedRegion(corpus:memory:)``),
        // and a survey that reports only what it did read is indistinguishable from one that
        // covered the tree. Named at the top level, which is the granularity a person can act on.
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
        let toRead = candidates.filter { filingDocumentIsAvailable(root.appendingPathComponent($0).path) }
        let unavailable = candidates.count - toRead.count
        if unavailable > 0 {
            // Named rather than folded into the "read" count: these are documents the survey chose
            // not to learn from, and a survey that reports only what it managed to do reads as
            // complete when it was not.
            Logger.shared.info("\(unavailable) document(s) are not downloaded — left for a later survey")
        }
        let relocated = FilingSurvey.relocations(tree: tree, corpus: corpus).count
        // The same predicate `merge` and `relocations` decide by, so the report cannot claim a drop
        // the merge did not make: a document under a folder the walk never entered is not dropped
        // and is not news.
        let dropped = corpus.documents.keys.filter { tree.showsGone($0) }.count - relocated

        var read: [String: FilingCorpusDocument] = [:]
        // Documents chosen for this batch that stopped being downloaded before their result was
        // stamped. Declared out here because the REPORT is built from the pre-batch counts and has
        // to be corrected by it — see below.
        var evictedMidRead = 0
        if !toRead.isEmpty {
            updateScan(\.filingSurveyLifecycle, epoch: epoch,
                       status: "Reading \(toRead.count) new or changed document\(toRead.count == 1 ? "" : "s")…")
            let absolute = toRead.map { root.appendingPathComponent($0).path }
            let text = await Self.extractSnippets(for: absolute, using: extractor)
            if Task.isCancelled { return .none }
            for path in toRead {
                guard let stamp = tree.documents[path] else { continue }
                // Absent text is a document that was opened and gave up nothing — recorded as blank
                // so the next survey does not open it again. That is the whole reason a blank entry
                // exists rather than the path simply being left out.
                let page = text[root.appendingPathComponent(path).path] ?? ""
                // **A blank stamp is permanent, so it is only earned by a file that was there.**
                // Availability was asked before the batch and the batch takes minutes; a file the
                // provider evicts in between extracts as `""`, and the stamp that records it is
                // keyed on size and mtime, neither of which moves when the content comes back. So
                // the write-off would never invalidate — the exact outcome `isAvailable` exists to
                // prevent, arrived at through the door of a stale answer. Re-asked only for the
                // blank ones (one lstat apiece, and a survey's blanks are a handful), because a
                // document that produced text plainly had its content on disk.
                if page.isEmpty,
                   !filingDocumentIsAvailable(root.appendingPathComponent(path).path) {
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

        updateScan(\.filingSurveyLifecycle, epoch: epoch, status: "Rebuilding folder memory…")
        let merged = FilingSurvey.merge(corpus: corpus, tree: tree, read: read)
        let memory = FilingSurvey.buildMemory(corpus: merged, folderModified: tree.folders,
                                              profileId: profileId)
        var wrote = false
        do {
            wrote = try FilingSurveyStore.write(corpus: merged, memory: memory,
                                                previousMemory: previousMemory, id: profileId,
                                                in: directory, root: root.path, now: now)
        } catch {
            Logger.shared.error("Couldn't write the re-surveyed folder memory: \(error.localizedDescription)")
            return .none
        }
        // The stamp moved even when nothing else did — that is §4.1's whole point: "last surveyed"
        // answers when the survey LOOKED, and the guard above already returned on a failed write.
        filingSurveyedAt = now
        if wrote {
            // Publishing the memory drops the router's prepared index, so the next scan builds it
            // from the folders learned here. The fingerprint moves with the bytes, which is what
            // keeps cached classifications from replaying answers composed against the old tree.
            filingMemory = memory
            filingArtifactFingerprint = FilingProfileStore.fingerprint(id: profileId, in: directory)
        }
        // **Both counts are corrected by the mid-read evictions, in opposite directions.** They
        // are derived from `toRead`/`candidates`, which were fixed BEFORE the batch ran, so a
        // document withheld part-way through was counted as read — its page 1 never was — and was
        // excluded from the unavailable column, which is precisely what it became. Wrong twice,
        // and `summary` is the user-facing sentence built from them: a survey that left work
        // undone read as one that had covered the tree. The `continue` that skips the stamp
        // reached only a `Logger.info`, which nothing in the report can see.
        let report = FilingSurveyReport(foldersChanged: stale.count,
                                        documentsRead: toRead.count - evictedMidRead,
                                        documentsRelocated: relocated,
                                        documentsDropped: max(0, dropped),
                                        documentsUnavailable: unavailable + evictedMidRead,
                                        foldersLearned: memory.folders.count, changed: wrote)
        Logger.shared.info("Folder memory re-surveyed — \(report.summary) "
                           + "\(report.foldersLearned) folder(s) now have learned content.")
        filingSurveyReport = report
        completeScan(\.filingSurveyLifecycle, root: root)
        return report
    }

    /// A fresh salt for a tree that has never been surveyed. 16 bytes of hex, the same shape the
    /// offline builder mints.
    static func newSurveySalt() -> String {
        HexEncoding.string((0..<16).map { _ in UInt8.random(in: 0...255) })
    }
}
